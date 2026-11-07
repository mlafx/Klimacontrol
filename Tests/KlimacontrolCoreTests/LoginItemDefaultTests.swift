import XCTest
@testable import KlimacontrolCore

final class LoginItemDefaultTests: XCTestCase {
    func testDecisionTable() {
        typealias D = LoginItemDefault
        for installed in [false, true] {
            XCTAssertEqual(D.decide(applied: true, installed: installed), .none)
        }
        XCTAssertEqual(D.decide(applied: false, installed: true), .register)
        XCTAssertEqual(D.decide(applied: false, installed: false), .wait)
    }

    func testInstalledLocation() {
        let home = "/Users/x"
        let yes = ["/Applications/Klimacontrol.app", "/Users/x/Applications/Klimacontrol.app",
                   "/Applications/Tools/Klimacontrol.app"]
        let no = ["/Volumes/Klimacontrol/Klimacontrol.app",
                  "/private/var/folders/ab/T/AppTranslocation/1234/d/Klimacontrol.app",
                  "/Users/x/Library/Caches/Klimacontrol-build/app/Klimacontrol.app",
                  "/Applications.bak/Klimacontrol.app", "/Users/y/Applications/Klimacontrol.app"]
        for p in yes { XCTAssertTrue(LoginItemDefault.isInstalledLocation(p, home: home), p) }
        for p in no { XCTAssertFalse(LoginItemDefault.isInstalledLocation(p, home: home), p) }
        XCTAssertFalse(LoginItemDefault.isInstalledLocation("/Users/x/Applications/Klimacontrol.app", home: ""))
    }
}
