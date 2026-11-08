import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Protokoll- und Fehlertexte aus MideaKit: Schlüssel und deutscher Text im Code müssen mit dem Katalog übereinstimmen.
final class LogTextTests: XCTestCase {
    override func tearDown() {
        Localizer.resetForTesting()
        super.tearDown()
    }

    private func kitSources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/MideaKit")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try files.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    func testEveryKeyInMideaKitIsInTheCatalogWithTheGermanTextOfTheCode() throws {
        let pattern = try NSRegularExpression(pattern: #"LogText\.t\(\s*"([^"]+)",\s*"((?:[^"\\]|\\.)*)""#)
        var seen = Set<String>()
        for (name, text) in try kitSources() where name != "LogText.swift" {
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(m.range(at: 1), in: text)!])
                let german = String(text[Range(m.range(at: 2), in: text)!])
                seen.insert(key)
                XCTAssertTrue(key.hasPrefix("log.") || key.hasPrefix("kit.") || key.hasPrefix("reason."), "\(name): \(key)")
                guard case .text(let catalogDE)? = Localizer.catalog.raw(key, .de) else {
                    XCTFail("\(name): Schlüssel \(key) fehlt im Katalog (deutsch)")
                    continue
                }
                XCTAssertEqual(catalogDE, german, "\(name): deutscher Text zu \(key) weicht vom Katalog ab")
                guard case .text(let catalogEN)? = Localizer.catalog.raw(key, .en) else {
                    XCTFail("\(name): Schlüssel \(key) fehlt im Katalog (englisch)")
                    continue
                }
                XCTAssertEqual(placeholders(catalogEN), placeholders(german), key)
            }
        }
        XCTAssertGreaterThan(seen.count, 100)
    }

    func testNoGermanLogTextIsLeftOutsideLogText() throws {
        let call = try NSRegularExpression(pattern: #"AppLog\.(write|error|debug)\(\s*""#)
        for (name, text) in try kitSources() {
            for m in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let rest = String(text[Range(m.range, in: text)!.upperBound...].prefix(60))
                XCTAssertTrue(rest.hasPrefix("→") || rest.hasPrefix("←") || rest.hasPrefix("Cloud"),
                              "\(name): Protokolltext am Katalog vorbei: \(rest)")
            }
        }
    }

    func testTextsFollowTheLanguageOnceTheTranslatorIsInstalled() {
        Localizer.withLanguage(.en) {
            XCTAssertEqual(LogText.t("log.transport.via", "Verbindung über {path}", ["path": "Wi-Fi"]), "Connection via Wi-Fi")
        }
        Localizer.withLanguage(.de) {
            XCTAssertEqual(LogText.t("log.transport.via", "Verbindung über {path}", ["path": "WLAN"]), "Verbindung über WLAN")
        }
        Localizer.withLanguage(.en) {
            XCTAssertEqual(LogText.t("log.unknown.key", "Deutscher Text {a}", ["a": "x"]), "Deutscher Text x")
        }
    }

    func testWithoutTranslatorTheGermanTextIsUsed() {
        LogText.install(nil)
        defer { Localizer.installLogTranslator() }
        XCTAssertEqual(LogText.t("log.transport.via", "Verbindung über {path}", ["path": "WLAN"]), "Verbindung über WLAN")
    }

    func testPseudoLanguageMarksLogTexts() {
        Localizer.withLanguage(.en, pseudo: true) {
            XCTAssertTrue(LogText.t("log.transport.via", "Verbindung über {path}", ["path": "WLAN"]).contains("⟦"))
        }
    }

    private func placeholders(_ text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            names.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return Set(names).sorted()
    }
}
