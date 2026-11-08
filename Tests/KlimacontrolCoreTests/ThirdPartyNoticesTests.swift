import XCTest
@testable import KlimacontrolCore

/// Die Hinweise in der App und in THIRD_PARTY_NOTICES.md müssen übereinstimmen, und jeder Lizenztext muss vollständig sein.
final class ThirdPartyNoticesTests: XCTestCase {
    func testNoticesAreCompleteAndMatchTheMarkdownFile() throws {
        try Localizer.withLanguage(.de) { try checkNoticesAgainstMarkdown() }
    }

    private func checkNoticesAgainstMarkdown() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let md = try String(contentsOf: root.appendingPathComponent("docs/THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        XCTAssertEqual(Set(ThirdPartyNotices.all.map(\.id)).count, ThirdPartyNotices.all.count, "IDs eindeutig")
        for n in ThirdPartyNotices.all {
            XCTAssertTrue(md.contains(n.name) && md.contains(n.url), "\(n.name) fehlt in THIRD_PARTY_NOTICES.md")
            for c in n.copyright {
                XCTAssertTrue(md.contains(c), "Vermerk fehlt in der Datei: \(c)")
                if n.license != "Public Domain" { XCTAssertTrue(n.licenseText.contains(c), "Vermerk fehlt im Lizenztext: \(c)") }
            }
            switch n.license {
            case "MIT":
                XCTAssertTrue(n.licenseText.hasPrefix("MIT License") || n.licenseText.hasPrefix("The MIT License (MIT)")
                              || n.licenseText.hasPrefix("Copyright (c)"), n.name)
                XCTAssertTrue(n.licenseText.contains("Permission is hereby granted, free of charge"))
                // Zeilenumbrüche je nach Projekt verschieden (z. B. Expat), darum Leerraum vereinheitlicht prüfen.
                let flat = n.licenseText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                XCTAssertTrue(flat.contains("shall be included in all copies or substantial portions of the Software."), n.name)
            case "Apache-2.0", "Apache-2.0 WITH Swift-exception":
                XCTAssertTrue(n.licenseText.contains("Apache License"))
                XCTAssertTrue(n.licenseText.contains("END OF TERMS AND CONDITIONS"))
                if n.id == "swift-crypto" {
                    XCTAssertTrue(n.licenseText.contains("NOTICE (Swift Crypto)"), "Apache 2.0 verlangt die NOTICE-Datei")
                }
                if n.license.hasSuffix("Swift-exception") {
                    XCTAssertTrue(n.licenseText.contains("Runtime Library Exception to the Apache 2.0 License"))
                }
            case "Unicode-3.0":
                XCTAssertTrue(n.licenseText.hasPrefix("UNICODE LICENSE V3"))
                XCTAssertTrue(n.licenseText.contains("this copyright and permission notice appear with all copies"))
            default:
                XCTAssertFalse(n.licenseText.isEmpty)
            }
        }
        XCTAssertTrue(md.contains(ThirdPartyNotices.trademarkNote.prefix(40)))
    }

    /// Jeder Lizenztext steht wörtlich in THIRD_PARTY_NOTICES.md, und die Windows-Laufzeiten sind als „nur Windows“ vermerkt.
    func testLicenseTextsAppearVerbatimInTheMarkdownFile() throws {
        try Localizer.withLanguage(.de) { try checkLicenseTexts() }
    }

    func testEnglishNoticesAreComplete() throws {
        try Localizer.withLanguage(.en) {
            for n in ThirdPartyNotices.all {
                XCTAssertFalse(n.usage.isEmpty, n.id)
                XCTAssertFalse(n.usage.hasPrefix("notices."), "Text fehlt: \(n.id)")
                let german = Localizer.text("notices.\(ThirdPartyNotice.keyName(n.id)).usage", language: .de)
                XCTAssertNotEqual(n.usage, german, n.id)
                XCTAssertTrue(["All", "Mac only", "Windows only"].contains(n.platforms), n.platforms)
                for c in n.copyright { XCTAssertFalse(c.contains("gemeinfrei"), c) }
            }
            XCTAssertEqual(ThirdPartyNotices.all.first { $0.id == "sparkle" }?.platforms, "Mac only")
            XCTAssertTrue(ThirdPartyNotices.trademarkNote.hasPrefix("Klimacontrol is not a Midea product"))
            let json = try JSONEncoder().encode(ThirdPartyNotices.all)
            let list = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
            XCTAssertEqual(list.first?["platforms"] as? String, "All")
            XCTAssertNotNil(list.first?["usage"] as? String)
            XCTAssertNotNil(list.first?["licenseText"] as? String)
        }
    }

    private func checkLicenseTexts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let md = try String(contentsOf: root.appendingPathComponent("docs/THIRD_PARTY_NOTICES.md"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        for n in ThirdPartyNotices.all {
            XCTAssertTrue(md.contains("```\n" + n.licenseText + "\n```"), "Lizenztext von \(n.name) weicht in THIRD_PARTY_NOTICES.md ab")
            XCTAssertTrue(md.contains("## \(n.name)\n\nQuelle: \(n.url)  \nLizenz: \(n.license)  \nPlattform: \(n.platforms)\n"),
                          "Kopf von \(n.name) weicht ab")
        }
        for id in ["swift-crypto", "sqlite", "swift-runtime", "icu", "dotnet"] {
            XCTAssertEqual(ThirdPartyNotices.all.first { $0.id == id }?.platforms, "nur Windows", id)
        }
        XCTAssertEqual(ThirdPartyNotices.all.first { $0.id == "winsparkle" }?.platforms, "nur Windows")
        XCTAssertEqual(ThirdPartyNotices.all.first { $0.id == "expat" }?.platforms, "nur Windows")
        XCTAssertEqual(ThirdPartyNotices.all.first { $0.id == "sparkle" }?.platforms, "nur Mac")
    }
}
