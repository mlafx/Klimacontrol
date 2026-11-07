import Foundation
import XCTest
@testable import MideaKit

/// Wächter der Testisolation: Schlägt einer dieser Tests fehl, würde der Testlauf echte Daten anfassen.
final class TestIsolationTests: XCTestCase {
    /// Der Prozess erkennt sich als Testlauf (Prozessname `…xctest`/`…PackageTests`, XCTest-Umgebung).
    func testProcessIsDetectedAsTestRun() {
        XCTAssertTrue(TestEnvironment.isRunningTests, "Prozess \(ProcessInfo.processInfo.processName) nicht als Test erkannt")
    }

    /// Geheimnisse nur im Speicher – nie der echte Schlüsselbund bzw. die Anmeldeinformationsverwaltung.
    func testSecretsAreInMemory() {
        XCTAssertTrue(SecretStore.backend is InMemoryKeychain, "\(type(of: SecretStore.backend))")
    }

    /// Protokoll nie im echten Ablageordner (~/Library/Application Support/Klimacontrol bzw. %LOCALAPPDATA%\Klimacontrol).
    func testLogIsNotTheRealLog() {
        let real = DeviceConfig.supportDirectory.standardizedFileURL.path
        let log = AppLog.url.deletingLastPathComponent().standardizedFileURL.path
        XCTAssertNotEqual(log, real, "Protokoll zeigt auf den echten Ordner")
        XCTAssertFalse(log.hasPrefix(real + "/"), log)
        if let env = ProcessInfo.processInfo.environment["KLIMACONTROL_LOG_DIR"], !env.isEmpty {
            XCTAssertEqual(log, URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL.path)
        }
    }

    /// `redirect(to:)` lenkt um und `nil` führt zurück auf den Test-Standard (nicht auf den echten Ordner).
    func testRedirectRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = AppLog.url
        AppLog.redirect(to: dir)
        XCTAssertEqual(AppLog.url.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        AppLog.redirect(to: nil)
        XCTAssertEqual(AppLog.url, before)
    }
}
