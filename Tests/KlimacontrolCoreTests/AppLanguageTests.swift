import XCTest
@testable import KlimacontrolCore

final class AppLanguageTests: XCTestCase {
    func testChoiceFromAppleLanguages() {
        XCTAssertEqual(LanguageChoice(appleLanguages: nil), .system)
        XCTAssertEqual(LanguageChoice(appleLanguages: []), .system)
        XCTAssertEqual(LanguageChoice(appleLanguages: ["de"]), .de)
        XCTAssertEqual(LanguageChoice(appleLanguages: ["de-DE", "en"]), .de)
        XCTAssertEqual(LanguageChoice(appleLanguages: ["en-GB"]), .en)
        XCTAssertEqual(LanguageChoice(appleLanguages: ["fr"]), .system)
        XCTAssertEqual(LanguageChoice(appleLanguages: ["deutsch"]), .system)
    }

    func testAppleLanguagesValues() {
        XCTAssertNil(LanguageChoice.system.appleLanguages)
        XCTAssertEqual(LanguageChoice.de.appleLanguages, ["de"])
        XCTAssertEqual(LanguageChoice.en.appleLanguages, ["en"])
    }

    func testRoundTrip() {
        for choice in LanguageChoice.allCases {
            XCTAssertEqual(LanguageChoice(appleLanguages: choice.appleLanguages), choice)
        }
    }
}
