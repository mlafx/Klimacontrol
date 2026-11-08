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

    /// Wie `Updates.TestFeedOverride` unter Windows: nur Loopback mit gültigem Port.
    func testTestFeedOverrideOnlyLoopback() {
        XCTAssertEqual(AppUpdate.testFeedOverride("http://127.0.0.1:8765/updateinfo-mac.xml"),
                       "http://127.0.0.1:8765/updateinfo-mac.xml")
        XCTAssertEqual(AppUpdate.testFeedOverride("http://127.0.0.1:65535/a/b-c_d.xml"), "http://127.0.0.1:65535/a/b-c_d.xml")
        for bad in [nil, "", "http://127.0.0.1:0/x.xml", "http://127.0.0.1:65536/x.xml", "http://127.0.0.1/x.xml",
                    "https://127.0.0.1:8765/x.xml", "http://localhost:8765/x.xml", "http://127.0.0.2:8765/x.xml",
                    "http://127.0.0.1:8765/x.xml?y=1", "http://127.0.0.1:8765@evil.example.com/x.xml",
                    " http://127.0.0.1:8765/x.xml", AppUpdate.feedMac] {
            XCTAssertNil(AppUpdate.testFeedOverride(bad), String(describing: bad))
        }
        XCTAssertEqual(AppUpdate.testFeedVariable, "KLIMACONTROL_UPDATE_TEST_FEED")
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

    func testReleaseScriptSignsUpdateFilesLast() throws {
        let script = try String(contentsOf: root.appendingPathComponent("tools/make_release.py"), encoding: .utf8)
        XCTAssertTrue(script.contains("--verify"))
        XCTAssertTrue(script.contains("updateinfo-mac-beta.xml"))
        XCTAssertTrue(script.contains("FIRST_AUTO_INSTALL_VERSION = \"1.1.0.0\""))
        XCTAssertEqual(AppUpdate.firstAutoInstallVersion, "1.1.0.0")
    }

    func testReleaseScriptWritesUpdateinfoFiles() throws {
        let script = try String(contentsOf: root.appendingPathComponent("tools/make_release.py"), encoding: .utf8)
        XCTAssertTrue(script.contains("\"updateinfo-mac.xml\"") && script.contains("\"updateinfo-win.xml\""))
    }

    /// Öffentlicher Ed25519-Schlüssel: 32 Byte, Base64 in einer Zeile (so erwarten ihn Sparkle und WinSparkle).
    func testPublicKeyFileHoldsAnEd25519PublicKey() throws {
        let key = try String(contentsOf: root.appendingPathComponent("tools/UPDATE_PUBLIC_KEY"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "tools/UPDATE_PUBLIC_KEY")
        XCTAssertFalse(key.contains("\n"))
    }

    func testMacBuildScriptHardensUpdates() throws {
        let script = try String(contentsOf: root.appendingPathComponent("tools/build_app.sh"), encoding: .utf8)
        for needle in ["<key>SUVerifyUpdateBeforeExtraction</key><true/>", "<key>SURequireSignedFeed</key><true/>",
                       "<key>CFBundleDevelopmentRegion</key><string>en</string>",
                       "<key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>",
                       "de.lproj/InfoPlist.strings", "en.lproj/InfoPlist.strings",
                       "<key>SUFeedURL</key><string>\(AppUpdate.feedMac)</string>"] {
            XCTAssertTrue(script.contains(needle), needle)
        }
    }
}
