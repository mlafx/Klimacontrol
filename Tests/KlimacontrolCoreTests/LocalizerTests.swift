import Foundation
@testable import KlimacontrolCore
import XCTest

final class LocalizerTests: XCTestCase {
    override func tearDown() {
        Localizer.resetForTesting()
        super.tearDown()
    }

    func testResolve() {
        for preferred in ["de", "de-DE", "de_AT", "DE-ch"] {
            XCTAssertEqual(Localizer.resolve(preferred: [preferred]), .de, preferred)
        }
        XCTAssertEqual(Localizer.resolve(preferred: ["en-US"]), .en)
        XCTAssertEqual(Localizer.resolve(preferred: ["fr-FR", "de-DE"]), .en)
        XCTAssertEqual(Localizer.resolve(preferred: []), .en)
        XCTAssertEqual(Localizer.resolve(preferred: ["deu"]), .en)
    }

    func testLanguageChoice() {
        XCTAssertEqual(LanguageChoice(stored: "fr"), .system)
        XCTAssertEqual(LanguageChoice(stored: nil), .system)
        XCTAssertEqual(LanguageChoice(stored: "en"), .en)
        XCTAssertEqual(LanguageChoice.de.resolve(preferred: ["en"]), .de)
        XCTAssertEqual(LanguageChoice.en.resolve(preferred: ["de"]), .en)
        XCTAssertEqual(LanguageChoice.system.resolve(preferred: ["de-AT"]), .de)
        XCTAssertEqual(LanguageChoice.system.label, "Systemsprache")
        XCTAssertEqual(LanguageChoice.de.label, "Deutsch")
        XCTAssertEqual(LanguageChoice.en.label, "English")
    }

    func testDefaultIsGermanUntilConfigured() {
        Localizer.resetForTesting()
        XCTAssertEqual(Localizer.language, .de)
        XCTAssertFalse(Localizer.isConfigured)
        XCTAssertEqual(L.Settings.Language.title, "Sprache")
    }

    func testConfigureOnlyOnce() {
        XCTAssertTrue(Localizer.configure(.en, pseudo: false))
        XCTAssertEqual(Localizer.language, .en)
        XCTAssertFalse(Localizer.configure(.de, pseudo: false))
        XCTAssertEqual(Localizer.language, .en)
    }

    func testWithLanguageRestores() {
        Localizer.configure(.en, pseudo: false)
        Localizer.withLanguage(.de) { XCTAssertEqual(Localizer.language, .de) }
        XCTAssertEqual(Localizer.language, .en)
        XCTAssertTrue(Localizer.isConfigured)
    }

    func testTextsInBothLanguages() {
        Localizer.withLanguage(.de) { XCTAssertEqual(L.Settings.Language.title, "Sprache") }
        Localizer.withLanguage(.en) {
            XCTAssertEqual(L.Settings.Language.title, "Language")
            XCTAssertEqual(L.Settings.Price.invalid,
                           "The electricity price must be between 0 and 1000 per kWh. Please correct it. (price)")
        }
    }

    func testPlaceholders() {
        Localizer.withLanguage(.de) {
            XCTAssertEqual(L.WhatsNew.title(version: "1.2.0.0"), "Neu in Klimacontrol 1.2.0.0")
            XCTAssertTrue(L.Settings.Language.unknown(value: "fr").hasSuffix("(language-fr)"))
        }
        Localizer.withLanguage(.en) {
            XCTAssertEqual(L.WhatsNew.title(version: "1.2.0.0"), "New in Klimacontrol 1.2.0.0")
            XCTAssertTrue(L.Settings.Language.unknown(value: "fr").hasSuffix("(language-fr)"))
        }
    }

    func testPlural() {
        Localizer.withLanguage(.de) {
            XCTAssertEqual(L.Common.minutes(count: 1), "1 Minute")
            XCTAssertEqual(L.Common.minutes(count: 2), "2 Minuten")
            XCTAssertEqual(L.Common.minutes(count: 0), "0 Minuten")
        }
        Localizer.withLanguage(.en) {
            XCTAssertEqual(L.Common.minutes(count: 1), "1 minute")
            XCTAssertEqual(L.Common.minutes(count: 5), "5 minutes")
        }
    }

    func testFill() {
        XCTAssertEqual(Localizer.fill("{a} und {b} {a}", ["a": "x", "b": "y"]), "x und y x")
        XCTAssertEqual(Localizer.fill("{a} {c}", ["a": "x"]), "x {c}")
    }

    func testFallbackToEnglishAndUnknownKey() throws {
        let json = """
        {"strings":{"t.onlyEn":{"localizations":{"en":{"stringUnit":{"value":"Hello"}}}}}}
        """
        let table = try StringTable(catalogJSON: json)
        XCTAssertNil(table.raw("t.onlyEn", .de))
        XCTAssertEqual(table.value("t.onlyEn", .de), .text("Hello"))
        XCTAssertNil(table.value("t.none", .de))
        XCTAssertEqual(Localizer.text("gibt.esNicht"), "gibt.esNicht")
        XCTAssertThrowsError(try StringTable(catalogJSON: "kein json"))
    }

    func testPseudo() {
        XCTAssertEqual(Localizer.pseudo("Fan"), "⟦Fåñ~⟧")
        XCTAssertEqual(Localizer.pseudo("Off {count}"), "⟦Öff {count}~⟧")
        Localizer.withLanguage(.en, pseudo: true) {
            XCTAssertEqual(L.Settings.Language.title, Localizer.pseudo("Language"))
            XCTAssertEqual(L.Common.minutes(count: 2), "⟦2 mïñütés~~⟧")
        }
        Localizer.withLanguage(.de, pseudo: true) {
            XCTAssertEqual(L.Settings.Language.title, Localizer.pseudo("Language"))
        }
    }

    func testTableUsesActiveLanguage() {
        Localizer.withLanguage(.en) {
            let table = Localizer.table()
            XCTAssertEqual(table["settings.language.title"], .text("Language"))
            XCTAssertEqual(table["common.minutes"], .plural(["one": "{count} minute", "other": "{count} minutes"]))
            XCTAssertEqual(table.count, StringsData.allKeys.count)
        }
    }
}
