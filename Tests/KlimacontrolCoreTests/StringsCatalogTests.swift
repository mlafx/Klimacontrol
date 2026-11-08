import Foundation
@testable import KlimacontrolCore
import XCTest

final class StringsCatalogTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private let placeholder = try! NSRegularExpression(pattern: #"\{([a-z][A-Za-z0-9]*)\}"#)
    private let keyPattern = try! NSRegularExpression(pattern: #"^[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*)+$"#)

    private func table() throws -> StringTable { try StringTable(catalogJSON: StringsData.catalog) }

    private func names(_ text: String) -> [String] {
        var seen: [String] = []
        let ns = text as NSString
        for m in placeholder.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private func strings(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap((object as? [String: Any])?["strings"] as? [String: Any], url.lastPathComponent)
    }

    private func partFiles() throws -> [URL] {
        let dir = root.appendingPathComponent("l10n/parts")
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEmbeddedCatalogMatchesFile() throws {
        var expected = try strings(root.appendingPathComponent("l10n/Localizable.xcstrings"))
        for part in try partFiles() { expected.merge(try strings(part)) { first, _ in first } }
        let embedded = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(StringsData.catalog.utf8)) as? [String: Any])?["strings"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: embedded).isEqual(to: expected),
                      "Der eingebettete Katalog weicht vom Hauptkatalog und den Teilen unter l10n/parts ab. Neu erzeugen: python3 tools/sync_strings.py")
    }

    func testNoDuplicateKeysAcrossParts() throws {
        var owner: [String: String] = [:]
        let files = [root.appendingPathComponent("l10n/Localizable.xcstrings")] + (try partFiles())
        for file in files {
            for key in try strings(file).keys {
                if let first = owner[key] {
                    XCTFail("\(key): doppelt in \(first) und \(file.lastPathComponent)")
                } else {
                    owner[key] = file.lastPathComponent
                }
            }
        }
    }

    func testCatalogDecodesWithAllKeys() throws {
        let t = try table()
        XCTAssertEqual(Set(t.keys), Set(StringsData.allKeys))
        XCTAssertEqual(StringsData.allKeys, StringsData.allKeys.sorted())
    }

    func testEveryKeyHasGermanAndEnglish() throws {
        let t = try table()
        for key in StringsData.allKeys {
            let de = try XCTUnwrap(t.raw(key, .de), key)
            let en = try XCTUnwrap(t.raw(key, .en), key)
            switch (de, en) {
            case (.text, .text), (.plural, .plural): break
            default: XCTFail("\(key): Art unterscheidet sich zwischen de und en")
            }
        }
    }

    func testSignaturesMatchCatalog() throws {
        let t = try table()
        for key in StringsData.allKeys {
            var perLanguage: [Set<String>] = []
            var signature: [String] = []
            for language in AppLanguage.allCases {
                switch try XCTUnwrap(t.raw(key, language), key) {
                case .text(let s):
                    perLanguage.append(Set(names(s)))
                    if language == .en { signature = names(s) }
                case .plural(let cases):
                    for s in cases.values { perLanguage.append(Set(names(s))) }
                    if language == .en {
                        signature = ["count"] + names(try XCTUnwrap(cases["other"], key)).filter { $0 != "count" }
                    }
                }
            }
            XCTAssertEqual(StringsData.signatures[key], signature, key)
            XCTAssertEqual(Set(perLanguage).count, 1, "\(key): Platzhalter unterscheiden sich")
        }
    }

    func testKeysFollowSchema() {
        let keys = StringsData.allKeys
        for key in keys {
            let range = NSRange(location: 0, length: (key as NSString).length)
            XCTAssertNotNil(keyPattern.firstMatch(in: key, range: range), key)
            for other in keys where other != key {
                XCTAssertFalse(other.hasPrefix(key + "."), "\(key) ist Präfix von \(other)")
            }
        }
    }
}
