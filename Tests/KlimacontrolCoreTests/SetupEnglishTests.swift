import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

@MainActor
final class SetupEnglishTests: XCTestCase {
    override func tearDown() {
        Localizer.resetForTesting()
        super.tearDown()
    }

    private func en<T>(_ body: () -> T) -> T { Localizer.withLanguage(.en, body) }

    func testNothingFound() {
        en {
            XCTAssertTrue(SetupFlow.nothingFoundText(target: "192.168.1.40", asked: nil, path: .account)
                .hasPrefix("No air conditioner responds at 192.168.1.40."))
            XCTAssertTrue(SetupFlow.nothingFoundText(target: "192.168.1.40", asked: nil, path: .manual)
                .hasSuffix("Otherwise choose “Search network”."))
            let asked = SetupFlow.nothingFoundText(target: nil, asked: 254, path: .manual)
            XCTAssertTrue(asked.hasPrefix("No air conditioner found on the network (254 addresses queried)."))
            XCTAssertTrue(asked.contains(SetupFlow.networkHint))
            XCTAssertTrue(asked.hasSuffix("(shown in your router’s device list)."))
            XCTAssertTrue(SetupFlow.nothingFoundText(target: nil, asked: nil, path: .account)
                .hasSuffix("search the Cloud with the account from step 1, or enter the IP address."))
        }
    }

    func testDeviceAndCloudMessages() {
        en {
            let refused = SetupFlow.describeDevice(.refused, context: .manual)
            XCTAssertTrue(refused.text.hasPrefix("No connection to the air conditioner (The air conditioner refuses"), refused.text)
            XCTAssertFalse(refused.text.contains("Die "))
            XCTAssertEqual(SetupFlow.describeDevice(.timeout, context: .manual).text,
                           "The air conditioner is not responding. Is it on and connected to the same Wi-Fi? Then try again.")
            XCTAssertEqual(SetupFlow.describeCloud(.api(3101, "x"), context: .account).text,
                           "The email or password is incorrect. Use the sign-in details of the MSmartHome app. (Code 3101)")
            XCTAssertTrue(SetupFlow.describeCloud(.api(9999, "x"), context: .account).text.hasSuffix("(Code 9999)"))
            XCTAssertTrue(SetupFlow.describeCloud(.api(3123, "x"), context: .account).text.hasSuffix("(Code 3123)"))
            XCTAssertEqual(SetupFlow.describeCloud(.api(42, "Boom"), context: .account).text,
                           "Midea reports an error: Boom. Try again later. (Code 42)")
            XCTAssertEqual(SetupFlow.describe(ConfigError.invalidHex, context: .manual).text,
                           "The token or key is incomplete. Enter 128 and 64 characters (0–9, a–f).")
            XCTAssertEqual(SetupFlow.describe(ConfigError.unsupportedVersion(2), context: .manual).text,
                           "Protocol version V2 is not supported (V3 only). Check your entries.")
        }
    }

    func testFieldProblemsAndPaste() {
        en {
            XCTAssertEqual(ManualCredentials().problems["token"], "0 of 128 characters.")
            var c = ManualCredentials()
            c.key = "xyz"
            XCTAssertEqual(c.problems["key"], "3 of 64 characters. Only 0–9 and a–f are allowed.")
            let text = "192.168.1.40 " + String(repeating: "a", count: 128) + " " + String(repeating: "b", count: 64)
            XCTAssertEqual(SetupFlow.parseCredentials(text, into: ManualCredentials())?.found, "Token, Key, Address")
        }
    }

    func testCompletionNotes() {
        en {
            XCTAssertEqual(SetupFlow.completionNote(cloudOnly: true),
                           "Set up via the Midea Cloud: commands go through Midea until the air conditioner responds on Wi-Fi.")
            XCTAssertTrue(SetupFlow.completionNoteManual.hasSuffix("Recommended connection: “Wi-Fi only”."))
        }
    }
}
