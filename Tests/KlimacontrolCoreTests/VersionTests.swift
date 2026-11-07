import Foundation
import XCTest

/// `VERSION` ist die einzige Quelle der Versionsnummer (build_app.sh, LIESMICH, ZIP, Info.plist). Der oberste
/// CHANGELOG-Eintrag muss dieselbe Version tragen, sonst wird eine Fassung ohne passenden Eintrag gebaut.
final class VersionTests: XCTestCase {
    func testChangelogHeadMatchesVersionFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("tools/VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression), "VERSION: \(version)")
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let head = try XCTUnwrap(changelog.split(separator: "\n").first { $0.hasPrefix("## [") && !$0.hasPrefix("## [Unreleased]") },
                                 "kein Versionseintrag im CHANGELOG")
        XCTAssertTrue(head.hasPrefix("## [\(version)]"), "CHANGELOG-Kopf „\(head)“ passt nicht zu VERSION \(version)")
    }
}
