import Foundation
import XCTest
@testable import KlimacontrolCore

/// Feed, Suchintervall und öffentlicher Schlüssel stehen an drei Stellen (Kern für Windows, Info.plist aus
/// build_app.sh für Sparkle, tools/UPDATE_PUBLIC_KEY) – sie müssen zusammenpassen.
final class AppUpdateTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testFeedsPointToLatestReleaseOverHTTPS() {
        for feed in [AppUpdate.feedMac, AppUpdate.feedWindows] {
            XCTAssertTrue(feed.hasPrefix(AppUpdate.repository + "/releases/latest/download/"), feed)
            XCTAssertTrue(feed.hasPrefix("https://"), feed)
        }
        XCTAssertTrue(AppUpdate.feedMac.hasSuffix("/updateinfo-mac.xml"))
        XCTAssertTrue(AppUpdate.feedWindows.hasSuffix("/updateinfo-win.xml"))
        XCTAssertNotEqual(AppUpdate.feedMac, AppUpdate.feedWindows)
        XCTAssertEqual(AppUpdate.checkInterval, 86_400, "Standard: einmal am Tag")
    }

    func testBetaFeed() {
        XCTAssertEqual(AppUpdate.feedMacBeta, "https://github.com/mlafx/Klimacontrol/releases/download/beta/updateinfo-mac-beta.xml")
        XCTAssertFalse(AppUpdate.feedMacBeta.contains("/latest/"))
        XCTAssertEqual(AppUpdate.feedMac(beta: false), AppUpdate.feedMac)
        XCTAssertEqual(AppUpdate.feedMac(beta: true), AppUpdate.feedMacBeta)
        XCTAssertEqual(AppUpdate.feedMac, "https://github.com/mlafx/Klimacontrol/releases/latest/download/updateinfo-mac.xml")
    }

    func testMacBuildScriptUsesTheSameFeedIntervalAndKey() throws {
        let script = try String(contentsOf: root.appendingPathComponent("tools/build_app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("<key>SUFeedURL</key><string>\(AppUpdate.feedMac)</string>"))
        XCTAssertTrue(script.contains("<key>SUScheduledCheckInterval</key><integer>\(AppUpdate.checkInterval)</integer>"))
        XCTAssertTrue(script.contains("<key>SUEnableAutomaticChecks</key><true/>"))
        XCTAssertTrue(script.contains("<key>SUAutomaticallyUpdate</key><true/>"))
        XCTAssertTrue(script.contains("<key>SUAllowsAutomaticUpdates</key><true/>"))
        XCTAssertTrue(script.contains("<key>SUPublicEDKey</key><string>$UPDATE_KEY</string>"))
        XCTAssertTrue(script.contains("tools/UPDATE_PUBLIC_KEY"))
    }

    func testReleaseScriptMarksUpdatesCritical() throws {
        XCTAssertTrue(AppUpdate.installsAutomatically)
        let script = try String(contentsOf: root.appendingPathComponent("tools/make_release.py"), encoding: .utf8)
        XCTAssertTrue(script.contains("FIRST_AUTO_INSTALL_VERSION = \"\(AppUpdate.firstAutoInstallVersion)\""))
        let macStart = try XCTUnwrap(script.range(of: "updateinfo-mac.xml\").write_text"))
        let winStart = try XCTUnwrap(script.range(of: "updateinfo-win.xml\").write_text"))
        let critical = "<sparkle:criticalUpdate sparkle:version=\\\"{FIRST_AUTO_INSTALL_VERSION}\\\"></sparkle:criticalUpdate>"
        let macPart = String(script[macStart.lowerBound..<winStart.lowerBound])
        let winPart = String(script[winStart.lowerBound...])
        XCTAssertTrue(macPart.contains(critical), "Mac-Appcast")
        XCTAssertTrue(winPart.contains("extra_item=WINDOWS_CRITICAL"), "Windows: jedes Update kritisch")
        XCTAssertTrue(script.contains("WINDOWS_CRITICAL = \"\\n      <sparkle:criticalUpdate></sparkle:criticalUpdate>\""))
    }

    func testReleaseScriptWritesOnlyUpdateinfoFiles() throws {
        let script = try String(contentsOf: root.appendingPathComponent("tools/make_release.py"), encoding: .utf8)
        XCTAssertTrue(script.contains("\"updateinfo-mac.xml\"") && script.contains("\"updateinfo-win.xml\""))
        XCTAssertFalse(script.contains("\"appcast-"))
    }

    /// Öffentlicher Ed25519-Schlüssel: 32 Byte, Base64 in einer Zeile (so erwarten ihn Sparkle und WinSparkle).
    func testPublicKeyFileHoldsAnEd25519PublicKey() throws {
        let key = try String(contentsOf: root.appendingPathComponent("tools/UPDATE_PUBLIC_KEY"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "tools/UPDATE_PUBLIC_KEY")
        XCTAssertFalse(key.contains("\n"))
    }
}
