import Foundation
@testable import KlimacontrolBridge
@testable import KlimacontrolCore
import MideaKit
import XCTest

private final class QuietPlatform: PlatformServices {
    func keepAwake(_ on: Bool) {}
    func discard(_ url: URL) throws {}
}

private final class MemoryStore: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// `kc_set_locale`, `kc_strings_json` und die Befehle `language`/`currency`.
@MainActor
final class BridgeLocaleTests: XCTestCase {
    private var dir: URL!
    private var controllers: [ACController] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-locale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.stop() }
        controllers = []
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeController() -> ACController {
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        let c = ACController(appVersion: "test", settings: MemoryStore(), paths: CorePaths(directory: dir),
                             platform: QuietPlatform(), accounts: accounts,
                             makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
        controllers.append(c)
        return c
    }

    private func store(language: String? = nil) -> MemoryStore {
        let s = MemoryStore()
        if let language { s.values[SettingsKey.language] = language }
        return s
    }

    private let usJSON = """
        {"uiLanguage": "en-US", "format": {"localeIdentifier": "en_US", "decimalSeparator": ".", \
        "groupingSeparator": ",", "uses24HourClock": false, "amSymbol": "AM", "pmSymbol": "PM", \
        "dayMonthPattern": "MM/dd"}}
        """

    func testSetLocaleConfiguresLanguageAndFormat() {
        XCTAssertNil(applyLocale(usJSON, settings: store()))
        XCTAssertEqual(Localizer.language, .en)
        XCTAssertEqual(FormatProfile.current, .unitedStates)
    }

    func testStoredChoiceWins() {
        XCTAssertNil(applyLocale(#"{"uiLanguage": "en-US", "format": null}"#.replacingOccurrences(of: "null", with: usFormat),
                                 settings: store(language: "de")))
        XCTAssertEqual(Localizer.language, .de)
        Localizer.resetForTesting()
        _ = applyLocale(#"{"uiLanguage": "de-AT"}"#, settings: store(language: "en"))
        XCTAssertEqual(Localizer.language, .en)
        Localizer.resetForTesting()
        _ = applyLocale(#"{"uiLanguage": "de-CH"}"#, settings: store(language: "system"))
        XCTAssertEqual(Localizer.language, .de)
    }

    private var usFormat: String {
        #"{"localeIdentifier": "en_US", "decimalSeparator": ".", "groupingSeparator": ",", "uses24HourClock": false, "amSymbol": "AM", "pmSymbol": "PM", "dayMonthPattern": "MM/dd"}"#
    }

    func testUnreadableLocale() {
        for text in ["kein JSON", "{}", #"{"uiLanguage": 5}"#] {
            let message = applyLocale(text, settings: store())
            XCTAssertTrue(message?.hasSuffix("(bad-locale)") == true, text)
            XCTAssertFalse(Localizer.isConfigured, text)
        }
        XCTAssertTrue(applyLocale(nil, settings: store())?.hasSuffix("(bad-locale)") == true)
    }

    func testIncompleteFormat() {
        let partial = applyLocale(#"{"uiLanguage": "en-GB", "format": {"decimalSeparator": "."}}"#, settings: store())
        XCTAssertTrue(partial?.hasSuffix("(bad-format)") == true)
        XCTAssertEqual(Localizer.language, .en)
        XCTAssertEqual(FormatProfile.current, .germany)
        Localizer.resetForTesting()
        XCTAssertTrue(applyLocale(#"{"uiLanguage": "en-GB"}"#, settings: store())?.hasSuffix("(bad-format)") == true)
        XCTAssertEqual(FormatProfile.current, .germany)
    }

    func testLanguageOnlyOnceFormatAlways() {
        XCTAssertNil(applyLocale(usJSON, settings: store()))
        let german = """
            {"uiLanguage": "de-DE", "format": {"localeIdentifier": "de_DE", "decimalSeparator": ",", \
            "groupingSeparator": ".", "uses24HourClock": true, "amSymbol": "AM", "pmSymbol": "PM", \
            "dayMonthPattern": "dd.MM."}}
            """
        XCTAssertNil(applyLocale(german, settings: store()))
        XCTAssertEqual(Localizer.language, .en)
        XCTAssertEqual(FormatProfile.current, .germany)
    }

    private struct Strings: Decodable {
        let language: String
        let pseudo: Bool
        let strings: [String: JSONValue]
    }

    func testStringsJSON() throws {
        try Localizer.withLanguage(.en) {
            let s = try JSONDecoder().decode(Strings.self, from: Data(stringsJSON().utf8))
            XCTAssertEqual(s.language, "en")
            XCTAssertFalse(s.pseudo)
            XCTAssertEqual(s.strings["settings.language.title"], .string("Language"))
            guard case .object(let minutes)? = s.strings["common.minutes"] else { return XCTFail("keine Mehrzahl") }
            XCTAssertNotNil(minutes["one"])
            XCTAssertNotNil(minutes["other"])
        }
        try Localizer.withLanguage(.en, pseudo: true) {
            let s = try JSONDecoder().decode(Strings.self, from: Data(stringsJSON().utf8))
            XCTAssertTrue(s.pseudo)
            guard case .string(let title)? = s.strings["settings.language.title"] else { return XCTFail("kein Text") }
            XCTAssertTrue(title.hasPrefix("⟦"), title)
        }
    }

    func testLanguageAndCurrencyCommands() {
        let c = makeController()
        XCTAssertNil(handleCommand(#"{"cmd":"language","value":"en"}"#, on: c))
        XCTAssertEqual(c.languageChoice, .en)
        XCTAssertTrue(handleCommand(#"{"cmd":"language","value":"fr"}"#, on: c)?.hasSuffix("(language-fr)") == true)
        XCTAssertTrue(handleCommand(#"{"cmd":"language","value":1}"#, on: c)?.hasSuffix("(param-value)") == true)
        XCTAssertNil(handleCommand(#"{"cmd":"currency","value":"CHF"}"#, on: c))
        XCTAssertEqual(c.currency, "CHF")
        XCTAssertTrue(handleCommand(#"{"cmd":"currency","value":"EURO"}"#, on: c)?.hasSuffix("(currency)") == true)
        XCTAssertTrue(handleCommand(#"{"cmd":"currency","value":true}"#, on: c)?.hasSuffix("(param-value)") == true)
    }

    func testUpdateCommandsAndSnapshot() {
        let c = makeController()
        var json = snapshotJSON(c)
        XCTAssertTrue(json.contains(#""updateAutoInstall":true"#))
        XCTAssertTrue(json.contains(#""updateInterval":"daily""#))
        XCTAssertTrue(json.contains(#""updateCheckInterval":86400"#))
        XCTAssertNil(handleCommand(#"{"cmd":"updateAutoInstall","on":false}"#, on: c))
        XCTAssertFalse(c.updateAutoInstall)
        XCTAssertNil(handleCommand(#"{"cmd":"updateInterval","value":"weekly"}"#, on: c))
        XCTAssertEqual(c.updateInterval, .weekly)
        XCTAssertTrue(handleCommand(#"{"cmd":"updateAutoInstall","on":1}"#, on: c)?.hasSuffix("(param-on)") == true)
        XCTAssertTrue(handleCommand(#"{"cmd":"updateAutoInstall"}"#, on: c)?.hasSuffix("(param-on)") == true)
        XCTAssertTrue(handleCommand(#"{"cmd":"updateInterval","value":"monthly"}"#, on: c)?.hasSuffix("(param-value)") == true)
        XCTAssertTrue(handleCommand(#"{"cmd":"updateInterval","value":7}"#, on: c)?.hasSuffix("(param-value)") == true)
        XCTAssertEqual(c.updateInterval, .weekly)
        XCTAssertFalse(c.updateAutoInstall)
        json = snapshotJSON(c)
        XCTAssertTrue(json.contains(#""updateAutoInstall":false"#))
        XCTAssertTrue(json.contains(#""updateInterval":"weekly""#))
        XCTAssertTrue(json.contains(#""updateCheckInterval":604800"#))
        XCTAssertTrue(json.contains(#""installNow":"Jetzt installieren""#))
        XCTAssertTrue(json.contains(#""reminderSeconds":86400"#))
    }

    func testSnapshotCarriesLanguageAndCurrency() {
        let c = makeController()
        c.languageChoice = .en
        c.currency = "CHF"
        let json = snapshotJSON(c)
        XCTAssertTrue(json.contains(#""language":"en""#))
        XCTAssertTrue(json.contains(#""currency":"CHF""#))
    }
}
