import Foundation
import XCTest
@testable import KlimacontrolCore

/// Werte, an denen installierte Fassungen ab 1.1.0.0 ihre Updates finden und erkennen. Die Erwartungen stehen fest im
/// Test (Stand 1.1.0.0) und werden nicht aus den Dateien abgeleitet; reine Textprüfungen, laufen auch unter Windows.
final class ReleaseProtectionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func expect(_ source: String, contains needle: String, _ point: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(source.contains(needle), "D1 verletzt: \(point) – installierte Fassungen ab 1.1.0.0 bekämen keine Updates mehr", file: file, line: line)
    }

    private let appId = "{1EAA2BD1-F86E-420F-A62C-4057C87B34F8}"

    func testUpdateAddresses() throws {
        let base = "https://github.com/mlafx/Klimacontrol/releases/latest/download/"
        XCTAssertEqual(AppUpdate.feedMac, base + "updateinfo-mac.xml", "D1 verletzt: Mac-Update-Adresse")
        XCTAssertEqual(AppUpdate.feedWindows, base + "updateinfo-win.xml", "D1 verletzt: Windows-Update-Adresse")
        expect(try text("tools/build_app.sh"), contains: "<key>SUFeedURL</key><string>\(base)updateinfo-mac.xml</string>", "SUFeedURL in build_app.sh")
    }

    func testBetaNeverUnderLatest() {
        XCTAssertTrue(AppUpdate.feedMacBeta.contains("/releases/download/beta/"), "D1 verletzt: Beta-Adresse")
        XCTAssertFalse(AppUpdate.feedMacBeta.contains("/latest/"), "D1 verletzt: Beta-Adresse darf nicht unter latest liegen")
    }

    func testMacBundleIdentity() throws {
        let script = try text("tools/build_app.sh")
        expect(script, contains: "<key>CFBundleIdentifier</key><string>de.mlafx.klimacontrol</string>", "Bundle-ID")
        expect(script, contains: "APP=\"$SCRATCH/app/Klimacontrol.app\"", "App-Name")
        expect(script, contains: "<key>CFBundleExecutable</key><string>Klimacontrol</string>", "CFBundleExecutable")
        expect(script, contains: "<key>LSMinimumSystemVersion</key><string>15.0</string>", "Mindest-macOS")
    }

    func testPublicUpdateKey() throws {
        let key = try text("tools/UPDATE_PUBLIC_KEY").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(key, "+BjQ/31cXG1oK19Edl/gMbT5337ej7Vor7tJdLl/Vxo=", "D1 verletzt: öffentlicher Update-Schlüssel – installierte Fassungen ab 1.1.0.0 bekämen keine Updates mehr")
    }

    func testWindowsInstaller() throws {
        let iss = try text("windows/installer/Klimacontrol.iss")
        expect(iss, contains: "AppId={\(appId)", "Windows-AppId")
        expect(iss, contains: "DefaultDirName={localappdata}\\Programs\\Klimacontrol", "Windows-Ordner")
        expect(iss, contains: "PrivilegesRequired=lowest", "Windows ohne Administratorrechte")
        expect(iss, contains: "MinVersion=10.0", "Windows-Mindestsystem 10.0")
        expect(iss, contains: "ArchitecturesAllowed=x64compatible", "Windows-Architektur")
    }

    func testWinSparkleIdentity() throws {
        let updates = try text("windows/KlimacontrolTray/Updates.cs")
        expect(updates, contains: "RegistryPath = @\"Software\\Klimacontrol\\WinSparkle\"", "WinSparkle-Registrypfad")
        expect(updates, contains: "SetupAppId = \"\(appId)\"", "SetupAppId in Updates.cs")
    }

    func testReleaseScriptNamesAndFlags() throws {
        let script = try text("tools/make_release.py")
        expect(script, contains: "\"updateinfo-mac.xml\"", "Name der Mac-Update-Datei")
        expect(script, contains: "\"updateinfo-win.xml\"", "Name der Windows-Update-Datei")
        expect(script, contains: "\"appcast-mac.xml\": \"updateinfo-mac.xml\"", "alter Name der Mac-Update-Datei (Fassungen 1.0.x)")
        expect(script, contains: "\"appcast-windows.xml\": \"updateinfo-win.xml\"", "alter Name der Windows-Update-Datei (Fassungen 1.0.x)")
        expect(script, contains: "BETA_FEED = \"updateinfo-mac-beta.xml\"", "Name der Beta-Update-Datei")
        expect(script, contains: "\"--latest\"", "stabiles Release als latest")
        // Im stabilen Zweig von publish_plan darf kein --prerelease stehen.
        let start = try XCTUnwrap(script.range(of: "plan = [base + [\"create\", f\"v{tag}\", \"--repo\", GH_REPO, \"--target\", \"main\""), "D1 verletzt: stabiler Zweig von publish_plan fehlt")
        let line = script[start.lowerBound...].components(separatedBy: "\n").prefix(2).joined()
        XCTAssertFalse(line.contains("--prerelease"), "D1 verletzt: stabiler Zweig mit --prerelease – installierte Fassungen ab 1.1.0.0 bekämen keine Updates mehr")
        XCTAssertTrue(line.contains("--latest"))
    }
}
