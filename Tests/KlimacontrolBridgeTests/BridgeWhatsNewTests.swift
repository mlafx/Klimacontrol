import Foundation
@testable import KlimacontrolBridge
@testable import KlimacontrolCore
import MideaKit
import XCTest

private final class QuietPlatform: PlatformServices {
    func keepAwake(_ on: Bool) {}
    func discard(_ url: URL) throws {}
}

private final class MemoryStore: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Schnappschuss-Feld `whatsNew` und Befehl `dismissWhatsNew`.
@MainActor
final class BridgeWhatsNewTests: XCTestCase {
    func testSnapshotCarriesWhatsNewUntilDismissed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = CorePaths(directory: dir)
        try DeviceConfig(name: "net_ac_1A2B", ip: "192.168.1.40", port: 6444, deviceId: 111122223333444,
                         token: String(repeating: "ab", count: 64), key: String(repeating: "cd", count: 32)).save(to: paths.config)
        let version = try XCTUnwrap(ReleaseNotes.parse(ReleaseNotes.changelog).first).version
        let store = MemoryStore()
        store.set("1.0.0.0", forKey: SettingsKey.lastSeenVersion)
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        let c = ACController(appVersion: version, settings: store, paths: paths, platform: QuietPlatform(), accounts: accounts,
                             makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
        defer { c.stop() }

        func news() throws -> [String: Any]? {
            let data = Data(snapshotJSON(c).utf8)
            return try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["whatsNew"] as? [String: Any]
        }
        let shown = try XCTUnwrap(news())
        XCTAssertEqual(shown["title"] as? String, "Neu in Klimacontrol \(version)")
        XCTAssertEqual(shown["ok"] as? String, "OK")
        let first = try XCTUnwrap((shown["versions"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["version"] as? String, version)
        XCTAssertEqual(first["heading"] as? String, "Version \(version)")
        XCTAssertFalse(try XCTUnwrap(first["sections"] as? [[String: Any]]).isEmpty)

        try runCommand(try XCTUnwrap(CommandArgs(json: #"{"cmd":"dismissWhatsNew"}"#)), c)
        XCTAssertNil(try news())
        XCTAssertEqual(store.object(forKey: SettingsKey.lastSeenVersion) as? String, version)
    }
}
