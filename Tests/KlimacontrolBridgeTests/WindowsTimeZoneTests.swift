#if os(Windows)
import Foundation
@testable import KlimacontrolBridge
import XCTest

final class WindowsTimeZoneTests: XCTestCase {
    func testWindowsIDMapsToIANA() {
        XCTAssertEqual(ianaTimeZone(forWindowsID: "W. Europe Standard Time"), "Europe/Berlin")
        XCTAssertNil(ianaTimeZone(forWindowsID: "Keine Zone"))
    }

    func testCalendarFollowsSystemZone() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        let iana = try XCTUnwrap(applyWindowsTimeZone())
        XCTAssertEqual(Calendar.current.timeZone.identifier, iana)
        XCTAssertNotEqual(Calendar.current.timeZone.identifier, "GMT")
    }
}
#endif
