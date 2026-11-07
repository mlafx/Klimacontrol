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

    func testEmbeddedCatalogMatchesFile() throws {
        let file = try String(contentsOf: root.appendingPathComponent("l10n/Localizable.xcstrings"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        XCTAssertEqual(StringsData.catalog, file,
                       "Der eingebettete Katalog weicht von l10n/Localizable.xcstrings ab. Neu erzeugen: python3 tools/sync_strings.py")
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
