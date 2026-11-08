import Foundation
@testable import KlimacontrolCore
import XCTest

/// Deutscher und englischer CHANGELOG müssen ab 1.2.0.0 dieselbe Form haben.
final class ChangelogParityTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    /// Ab 1.2.0.0 muss der englische CHANGELOG existieren.
    static func skipOrFail(root: URL) throws {
        let text = try String(contentsOf: root.appendingPathComponent("tools/VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = AppVersion(text), let first = AppVersion("1.2.0.0"), v >= first {
            XCTFail("CHANGELOG.en.md fehlt, ist aber ab 1.2.0.0 Pflicht")
        }
    }

    private func loadBoth() throws -> (german: [ReleaseNote], english: [ReleaseNote]) {
        let en = root.appendingPathComponent("CHANGELOG.en.md")
        guard FileManager.default.fileExists(atPath: en.path) else {
            try ChangelogParityTests.skipOrFail(root: root)
            throw XCTSkip("CHANGELOG.en.md fehlt noch")
        }
        let german = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        return (ReleaseNotes.parse(german), ReleaseNotes.parse(try String(contentsOf: en, encoding: .utf8)))
    }

    func testEnglishVersionsExistInGerman() throws {
        let (german, english) = try loadBoth()
        for note in english {
            let de = try XCTUnwrap(german.first { $0.version == note.version }, "\(note.version) fehlt deutsch")
            XCTAssertEqual(de.date, note.date, note.version)
        }
    }

    func testSameShapeFrom1200() throws {
        let (german, english) = try loadBoth()
        let titles = ["Hinzugefügt": "Added", "Geändert": "Changed", "Behoben": "Fixed", "Entfernt": "Removed", "": ""]
        func prefix(_ item: String) -> String {
            ["Mac:", "Windows:"].first { item.hasPrefix($0) } ?? ""
        }
        let first = try XCTUnwrap(AppVersion("1.2.0.0"))
        for de in german where (AppVersion(de.version) ?? first) >= first {
            let en = try XCTUnwrap(english.first { $0.version == de.version }, "\(de.version) fehlt englisch")
            XCTAssertEqual(de.sections.count, en.sections.count, de.version)
            for (a, b) in zip(de.sections, en.sections) {
                XCTAssertEqual(titles[a.title], b.title, "\(de.version) \(a.title)")
                XCTAssertEqual(a.items.count, b.items.count, "\(de.version) \(a.title)")
                for (x, y) in zip(a.items, b.items) { XCTAssertEqual(prefix(x), prefix(y), "\(de.version): \(x)") }
            }
        }
    }
}
