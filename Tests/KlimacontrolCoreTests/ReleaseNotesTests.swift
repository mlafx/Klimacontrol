import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

@MainActor
final class ReleaseNotesTests: CoreTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testEmbeddedChangelogMatchesFile() throws {
        let file = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        XCTAssertEqual(ReleaseNotes.changelog, file,
                       "Der eingebettete CHANGELOG weicht von CHANGELOG.md ab. Neu erzeugen: python3 tools/sync_release_notes.py")
    }

    private let sample = """
    # Changelog

    Einleitung.

    ## [1.0.1.2] – in Arbeit

    ### Hinzugefügt
    - **Neu:** Erster `Punkt`,
      der in der nächsten Zeile weitergeht.
    - Mac: Nur am Mac.
    - Windows: Nur unter Windows.
    - Mit Unterpunkten:
      - Eins
      - Zwei

    ### Behoben
    - Windows: Nur Windows.

    ## [1.0.1.1] – 2026-11-07

    ### Geändert
    - Alt.

    ## [1.0.0.0] – 2026-11-05
    Erste öffentliche Fassung.

    ### Hinzugefügt
    - Alles.
    """

    func testParseSectionsContinuationsAndMarkdown() {
        let notes = ReleaseNotes.parse(sample)
        XCTAssertEqual(notes.map(\.version), ["1.0.1.2", "1.0.1.1", "1.0.0.0"])
        XCTAssertNil(notes[0].date)
        XCTAssertEqual(notes[1].date, "2026-11-07")
        XCTAssertEqual(notes[0].sections.map(\.title), ["Hinzugefügt", "Behoben"])
        XCTAssertEqual(notes[0].sections[0].items, [
            "Neu: Erster Punkt, der in der nächsten Zeile weitergeht.",
            "Mac: Nur am Mac.",
            "Windows: Nur unter Windows.",
            "Mit Unterpunkten:\n– Eins\n– Zwei",
        ])
        XCTAssertEqual(notes[2].sections.map(\.title), ["", "Hinzugefügt"], "Absatz ohne Überschrift ist ein Abschnitt ohne Titel")
        XCTAssertEqual(notes[2].sections[0].items, ["Erste öffentliche Fassung."])
    }

    func testPlatformFilter() {
        let notes = ReleaseNotes.parse(sample)
        let mac = ReleaseNotes.notes(notes, for: .mac)
        XCTAssertEqual(mac[0].sections.map(\.title), ["Hinzugefügt"], "„Behoben“ hat am Mac keine Punkte")
        XCTAssertEqual(mac[0].sections[0].items.count, 3)
        XCTAssertEqual(mac[0].sections[0].items[1], "Nur am Mac.")
        let win = ReleaseNotes.notes(notes, for: .windows)
        XCTAssertEqual(win[0].sections.map(\.title), ["Hinzugefügt", "Behoben"])
        XCTAssertEqual(win[0].sections[0].items[1], "Nur unter Windows.")
        XCTAssertEqual(win[0].sections[1].items, ["Nur Windows."])
    }

    func testPending() {
        let notes = ReleaseNotes.parse(sample)
        func versions(_ seen: String?, _ current: String = "1.0.1.2", used: Bool = true) -> [String] {
            WhatsNew.pending(lastSeen: seen, current: current, usedBefore: used, notes: notes).map(\.version)
        }
        XCTAssertEqual(versions("1.0.1.2"), [], "gleiche Version")
        XCTAssertEqual(versions(nil, used: false), [], "frische Installation")
        XCTAssertEqual(versions(nil), ["1.0.1.2"], "Update ohne Merker: nur die laufende Version")
        XCTAssertEqual(versions("1.0.1.1"), ["1.0.1.2"])
        XCTAssertEqual(versions("1.0.0.0"), ["1.0.1.2", "1.0.1.1"], "Sprung über mehrere Versionen, neueste zuerst")
        XCTAssertEqual(versions("0.9.0.0", "1.0.1.1"), ["1.0.1.1", "1.0.0.0"], "höhere Abschnitte bleiben draußen")
        XCTAssertEqual(versions("1.0.1.0", "1.0.9.0"), [], "für die laufende Version gibt es keinen Abschnitt")
        XCTAssertEqual(versions("1.0.1.2", "1.0.1.2"), [])
        XCTAssertEqual(versions(nil, "test"), [], "keine Versionsnummer")
        XCTAssertEqual(versions("1.0.1.9", "1.0.1.2"), [], "Rückschritt zeigt nichts")
    }

    private func controller(version: String, seen: String?, configured: Bool) throws -> ACController {
        if let seen { settings.set(seen, forKey: SettingsKey.lastSeenVersion) }
        if configured { try Self.config.save(to: CorePaths(directory: dir).config) }
        let device = fake!
        let c = ACController(appVersion: version, settings: settings, paths: CorePaths(directory: dir), platform: platform,
                             accounts: makeAccounts(), makeDevice: { _, _, _ in device }, autostart: false)
        return c
    }

    func testControllerShowsAndDismisses() throws {
        let current = try XCTUnwrap(ReleaseNotes.parse(ReleaseNotes.changelog).first).version
        let c = try controller(version: current, seen: "1.0.0.0", configured: true)
        XCTAssertEqual(c.whatsNew.first?.version, current)
        XCTAssertEqual(settings.object(forKey: SettingsKey.lastSeenVersion) as? String, "1.0.0.0", "bis OK bleibt der alte Merker")
        c.dismissWhatsNew()
        XCTAssertTrue(c.whatsNew.isEmpty)
        XCTAssertEqual(settings.object(forKey: SettingsKey.lastSeenVersion) as? String, current)
        let again = try controller(version: current, seen: nil, configured: true)
        XCTAssertTrue(again.whatsNew.isEmpty, "nach OK nicht wieder")
    }

    func testFreshInstallRemembersVersionSilently() throws {
        let current = try XCTUnwrap(ReleaseNotes.parse(ReleaseNotes.changelog).first).version
        let c = try controller(version: current, seen: nil, configured: false)
        XCTAssertTrue(c.whatsNew.isEmpty)
        XCTAssertEqual(settings.object(forKey: SettingsKey.lastSeenVersion) as? String, current)
    }

    func testUpdateFromBuildWithoutMarkerShowsCurrentVersion() throws {
        let current = try XCTUnwrap(ReleaseNotes.parse(ReleaseNotes.changelog).first).version
        let c = try controller(version: current, seen: nil, configured: true)
        XCTAssertEqual(c.whatsNew.map(\.version), [current])
    }

    func testRealChangelogHasMacItemsForCurrentVersion() throws {
        let version = try String(contentsOf: root.appendingPathComponent("tools/VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = try XCTUnwrap(ReleaseNotes.parse(ReleaseNotes.changelog).first { $0.version == version })
        let mac = try XCTUnwrap(ReleaseNotes.notes([note], for: .mac).first)
        XCTAssertFalse(mac.sections.flatMap(\.items).isEmpty)
    }

    func testInProgressInEnglish() {
        XCTAssertNil(ReleaseNotes.parse("## [1.2.0.0] – in progress\n### Added\n- A.").first?.date)
        XCTAssertEqual(ReleaseNotes.parse("## [1.2.0.0] – 2026-12-01\n### Added\n- A.").first?.date, "2026-12-01")
    }

    func testPendingWithBetas() {
        let notes = ReleaseNotes.parse(sample)
        func versions(_ seen: String?, _ current: String, used: Bool = true) -> [String] {
            WhatsNew.pending(lastSeen: seen, current: current, usedBefore: used, notes: notes).map(\.version)
        }
        XCTAssertEqual(versions("1.0.1.1", "1.0.1.2b1"), ["1.0.1.2"])
        XCTAssertEqual(versions("1.0.1.2b1", "1.0.1.2b2"), [])
        XCTAssertEqual(versions("1.0.1.2b2", "1.0.1.2"), [])
        XCTAssertEqual(versions(nil, "1.0.1.2b1", used: false), [])
    }

    private var englishSample: String {
        "## [1.0.1.2] – in progress\n\n### Added\n- English item.\n"
    }

    func testMergedFallsBackToGerman() throws {
        let merged = ReleaseNotes.merged(german: ReleaseNotes.parse(sample), english: ReleaseNotes.parse(englishSample), hint: "H")
        XCTAssertEqual(merged.map(\.version), ["1.0.1.2", "1.0.1.1", "1.0.0.0"])
        XCTAssertEqual(merged[0].sections.map(\.title), ["Added"])
        XCTAssertEqual(merged[1].sections[0].title, "")
        XCTAssertEqual(merged[1].sections[0].items, ["H"])
        XCTAssertEqual(merged[1].sections[1].title, "Geändert")
    }

    func testHintSurvivesPlatformFilter() {
        let merged = ReleaseNotes.merged(german: ReleaseNotes.parse(sample), english: [], hint: "H")
        let mac = ReleaseNotes.notes(merged, for: .mac)
        XCTAssertEqual(mac.first?.sections.first?.items, ["H"])
    }

    func testEmbeddedEnglishChangelogMatchesFile() throws {
        let url = root.appendingPathComponent("CHANGELOG.en.md")
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
            XCTAssertEqual(ReleaseNotes.changelogEnglish, file, "Neu erzeugen: python3 tools/sync_release_notes.py")
        } else {
            XCTAssertEqual(ReleaseNotes.changelogEnglish, "")
        }
    }

    func testWhatsNewFollowsLanguage() {
        Localizer.withLanguage(.en) {
            let english = ReleaseNotes.all(for: .en)
            XCTAssertEqual(english.map(\.version), ReleaseNotes.parse(ReleaseNotes.changelog).map(\.version))
            if ReleaseNotes.changelogEnglish.isEmpty {
                for note in english {
                    XCTAssertEqual(note.sections.first?.items.first, "Release notes for this version are available in German only.")
                }
            }
        }
    }
}
