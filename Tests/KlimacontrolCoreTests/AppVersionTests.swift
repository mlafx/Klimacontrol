@testable import KlimacontrolCore
import XCTest

final class AppVersionTests: XCTestCase {
    func testParse() throws {
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.2.0.0")).numbers, [1, 2, 0, 0])
        XCTAssertNil(AppVersion("1.2.0.0")?.beta)
        XCTAssertEqual(AppVersion("1.2")?.numbers, [1, 2, 0, 0])
        XCTAssertEqual(AppVersion("1.2.0.0b1")?.beta, 1)
        XCTAssertEqual(AppVersion("1.2.0.0b12")?.beta, 12)
        XCTAssertEqual(AppVersion("01.2"), AppVersion("1.2"))
    }

    func testRejects() {
        for text in ["", "test", "1.2.0.0.1", "1..2", "1.2.0.0b", "1.2.0.0b0", "v1.2.0.0", "1.2.0.0-beta1", " 1.2",
                     "1.2.0.0B1", "1.2b1.0"] {
            XCTAssertNil(AppVersion(text), "„\(text)“")
        }
    }

    func testOrder() throws {
        let texts = ["1.0.0.0", "1.1.0.0", "1.2.0.0b1", "1.2.0.0b2", "1.2.0.0b10", "1.2.0.0", "1.2.0.1", "1.10.0.0"]
        let versions = try texts.map { try XCTUnwrap(AppVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) { XCTAssertLessThan(a, b, "\(a) < \(b)") }
    }

    func testDescriptionAndBase() throws {
        let beta = try XCTUnwrap(AppVersion("1.2b3"))
        XCTAssertEqual(beta.description, "1.2.0.0b3")
        XCTAssertEqual(beta.base.description, "1.2.0.0")
        XCTAssertTrue(beta.isBeta)
        let stable = try XCTUnwrap(AppVersion("1.2"))
        XCTAssertEqual(stable.description, "1.2.0.0")
        XCTAssertFalse(stable.isBeta)
    }
}
