import Foundation
@testable import KlimacontrolCore
import XCTest

/// Währung, Sprachwahl, Beta-Kanal und Preisgrenze.
@MainActor
final class SettingsLocaleTests: CoreTestCase {
    func testValidCurrency() {
        for ok in ["€", "CHF", "$", "kr", "zł", "£", "₿"] { XCTAssertEqual(ACController.validCurrency(ok), ok) }
        XCTAssertEqual(ACController.validCurrency(" € "), "€")
        for bad in ["", "   ", "EURO", "1€", "€1", "C F", "€.", "-"] { XCTAssertNil(ACController.validCurrency(bad), bad) }
        XCTAssertNil(ACController.validCurrency(nil))
    }

    func testCurrencyDefaultAndPersistence() {
        let c = makeController()
        XCTAssertEqual(c.currency, "€")
        c.currency = "CHF"
        XCTAssertEqual(settings.values["currency"] as? String, "CHF")
        XCTAssertEqual(makeController().currency, "CHF")
        c.currency = "12"
        XCTAssertEqual(c.currency, "CHF")
        settings.values["currency"] = "EURO"
        XCTAssertEqual(makeController().currency, "€")
    }

    func testLanguageChoicePersistence() {
        let c = makeController()
        XCTAssertEqual(c.languageChoice, .system)
        c.languageChoice = .en
        XCTAssertEqual(settings.values["language"] as? String, "en")
        XCTAssertEqual(makeController().languageChoice, .en)
        settings.values["language"] = "fr"
        XCTAssertEqual(makeController().languageChoice, .system)
        XCTAssertEqual(Localizer.language, .de)
    }

    func testBetaChannel() {
        let c = makeController()
        XCTAssertFalse(c.updateBetaChannel)
        c.updateBetaChannel = true
        XCTAssertEqual(settings.values["updateBetaChannel"] as? Bool, true)
        XCTAssertTrue(makeController().updateBetaChannel)
    }

    func testPriceLimit() {
        XCTAssertEqual(UIOptions.priceMax, 1000)
        XCTAssertEqual(ACController.validPrice(1000), 1000)
        XCTAssertNil(ACController.validPrice(1000.01))
        XCTAssertEqual(ACController.validPrice(10.5), 10.5)
        XCTAssertNil(ACController.validPrice(-0.01))
        let c = makeController()
        c.pricePerKWh = 250
        XCTAssertEqual(settings.values["pricePerKWh"] as? Double, 250)
    }

    func testHintsInBothLanguages() {
        XCTAssertEqual(ACController.priceHint, "Der Strompreis muss zwischen 0 und 1000 je kWh liegen. Bitte korrigieren. (price)")
        Localizer.withLanguage(.en) {
            XCTAssertEqual(ACController.priceHint, "The electricity price must be between 0 and 1000 per kWh. Please correct it. (price)")
            XCTAssertTrue(ACController.currencyHint.hasSuffix("(currency)"))
        }
        XCTAssertTrue(ACController.currencyHint.hasSuffix("(currency)"))
    }
}
