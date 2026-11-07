import Foundation
@testable import KlimacontrolCore
import XCTest

/// Darstellung (Reiter „Darstellung“): Standard = heutiges Aussehen, Themen, robustes Lesen, Speichern/Laden.
@MainActor
final class AppearanceTests: CoreTestCase {

    // MARK: Standard und Themen

    func testStandardIsTodaysLook() {
        let a = Appearance.standard
        XCTAssertEqual(a, Appearance())
        XCTAssertEqual(a.theme, .standard)
        XCTAssertEqual(a.scheme, .system)
        XCTAssertEqual(a.accent, .byMode)
        XCTAssertEqual(a.background, .glass)
        XCTAssertEqual(a.glow, 0)
        XCTAssertEqual(a.size, .normal)
        XCTAssertEqual(a.digits, .normal)
        XCTAssertEqual(a.hero, .target)
        XCTAssertEqual(a.scope, .all)
        XCTAssertFalse(a.lively || a.weather || a.reduceMotion || a.alwaysOnTop)
        XCTAssertEqual(a.menuBarText, .iconTarget)
        XCTAssertEqual(a.menuBarColored, Appearance.platformColoredIcon, "Mac einfarbig, Windows farbig wie bisher")
        XCTAssertFalse(a.menuBarAnimated)
        XCTAssertEqual(Appearance.preset(.standard), .standard)
        XCTAssertEqual(Appearance.MenuBarText.allCases, [.iconOnly, .iconTarget, .iconRoom, .roomTarget])
    }

    func testPresetsDifferAndStayInRange() {
        var seen: [Appearance] = []
        for theme in Appearance.Theme.allCases {
            let p = Appearance.preset(theme)
            XCTAssertEqual(p.theme, theme)
            XCTAssertEqual(p, p.clamped(), "\(theme) außerhalb der Grenzen")
            XCTAssertFalse(seen.contains(p), "\(theme) gleicht einem anderen Thema")
            seen.append(p)
            XCTAssertFalse(theme.label.isEmpty)
        }
        let contrast = Appearance.preset(.contrast)
        XCTAssertEqual(contrast.transparency, 0)
        XCTAssertEqual(contrast.background, .matte)
        XCTAssertEqual(Appearance.preset(.night).scheme, .dark)
        XCTAssertGreaterThan(Appearance.preset(.neon).glow, 0)
        XCTAssertEqual(Appearance.preset(.minimal).accent, .custom)
    }

    func testApplyingThemeKeepsLayout() {
        var a = Appearance.standard
        a.size = .large
        a.hero = .room
        a.scope = .simple
        a.reduceMotion = true
        a.alwaysOnTop = true
        a.menuBarText = .roomTarget
        a.menuBarAnimated = true
        let n = a.applying(.neon)
        XCTAssertEqual(n.theme, .neon)
        XCTAssertEqual(n.glow, Appearance.preset(.neon).glow)
        XCTAssertEqual(n.size, .large)
        XCTAssertEqual(n.hero, .room)
        XCTAssertEqual(n.scope, .simple)
        XCTAssertTrue(n.reduceMotion && n.alwaysOnTop && n.menuBarAnimated)
        XCTAssertEqual(n.menuBarText, .roomTarget)
        // Reduzierte Bewegung schaltet den lebendigen Hintergrund des Neon-Themas ab.
        XCTAssertTrue(n.lively)
        XCTAssertFalse(n.livelyActive(systemReduceMotion: false))
        var m = n
        m.reduceMotion = false
        XCTAssertTrue(m.livelyActive(systemReduceMotion: false))
        XCTAssertFalse(m.livelyActive(systemReduceMotion: true))
        XCTAssertFalse(m.weatherActive(systemReduceMotion: false))
    }

    // MARK: Robustes Lesen

    func testRoundTrip() {
        var a = Appearance.preset(.night)
        a.hero = .room
        a.blur = 7.5
        XCTAssertEqual(Appearance.decode(a.json), a)
    }

    func testDecodingMissingUnknownAndWrongFields() {
        XCTAssertEqual(Appearance.decode("{}"), .standard)
        XCTAssertEqual(Appearance.decode("kaputt"), .standard)
        XCTAssertEqual(Appearance.decode("[1,2]"), .standard)
        XCTAssertEqual(Appearance.decode("42"), .standard)
        let a = Appearance.decode(#"""
            {"theme":"gibtsnicht","scheme":"dark","accent":7,"blur":"viel","lively":1,"weather":true,
             "menuBarText":"roomTarget","neuesFeld":{"x":1},"digits":null}
            """#)
        XCTAssertEqual(a.theme, .standard)
        XCTAssertEqual(a.scheme, .dark)
        XCTAssertEqual(a.accent, .byMode)
        XCTAssertEqual(a.blur, Appearance.standard.blur)
        XCTAssertFalse(a.lively)
        XCTAssertTrue(a.weather)
        XCTAssertEqual(a.menuBarText, .roomTarget)
        XCTAssertEqual(a.digits, .normal)
    }

    func testDecodingClampsNumbers() {
        let a = Appearance.decode(#"{"transparency":3,"blur":-5,"glow":1.5}"#)
        XCTAssertEqual(a.transparency, 0.95)
        XCTAssertEqual(a.blur, 0)
        XCTAssertEqual(a.glow, 1)
        var b = Appearance.standard
        b.blur = .nan
        b.glow = .infinity
        XCTAssertEqual(b.clamped().blur, Appearance.standard.blur)
        XCTAssertEqual(b.clamped().glow, Appearance.standard.glow)
    }

    func testPartialPatchKeepsBase() {
        let base = Appearance.preset(.neon)
        let a = Appearance.decode(#"{"blur":12,"scheme":"falsch"}"#, base: base)
        XCTAssertEqual(a.blur, 12)
        XCTAssertEqual(a.scheme, base.scheme)
        XCTAssertEqual(a.glow, base.glow)
        XCTAssertEqual(Appearance.decode("kaputt", base: base), base)
    }

    // MARK: Controller: Speichern und Laden

    func testControllerStartsWithStandardAndPersists() {
        let c = makeController()
        XCTAssertEqual(c.appearance, .standard)
        var a = c.appearance
        a.scope = .simple
        a.glow = 0.5
        c.setAppearance(a)
        XCTAssertEqual(c.appearance, a)
        XCTAssertNotNil(settings.values[SettingsKey.appearance] as? String)
        XCTAssertEqual(makeController().appearance, a)
    }

    func testControllerClampsThemeAndReset() {
        let c = makeController()
        var a = c.appearance
        a.size = .compact
        a.transparency = 5
        c.setAppearance(a)
        XCTAssertEqual(c.appearance.transparency, 0.95)
        c.applyTheme(.contrast)
        XCTAssertEqual(c.appearance.theme, .contrast)
        XCTAssertEqual(c.appearance.transparency, 0)
        XCTAssertEqual(c.appearance.size, .compact, "Thema ändert die Größe nicht")
        XCTAssertEqual(makeController().appearance, c.appearance)
        c.resetAppearance()
        XCTAssertEqual(c.appearance, .standard)
        XCTAssertNil(settings.values[SettingsKey.appearance], "Standard wird nicht gespeichert")
        XCTAssertEqual(makeController().appearance, .standard)
    }

    func testBrokenStoredValueLoadsStandard() {
        settings.values[SettingsKey.appearance] = "{nicht json"
        XCTAssertEqual(makeController().appearance, .standard)
        settings.values[SettingsKey.appearance] = 17
        XCTAssertEqual(makeController().appearance, .standard)
        settings.values[SettingsKey.appearance] = Data(#"{"hero":"room"}"#.utf8)
        XCTAssertEqual(makeController().appearance.hero, .room)
    }

    func testRealUserDefaults() throws {
        let suite = "klimacontrol-appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let noCloud = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        func make() -> ACController {
            ACController(appVersion: "test", settings: defaults, paths: CorePaths(directory: dir),
                         platform: SpyPlatform(), accounts: noCloud, autostart: false)
        }
        make().applyTheme(.night)
        XCTAssertEqual(make().appearance, Appearance.preset(.night))
    }

}
