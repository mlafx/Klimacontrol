import Foundation
@testable import KlimacontrolBridge
@testable import KlimacontrolCore
import MideaKit
import XCTest

private final class NoPlatform: PlatformServices {
    func keepAwake(_ on: Bool) {}
    func discard(_ url: URL) throws {}
}

private final class NoSettings: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Gegenrichtung zu `VertragTests` (C#): Jedes Feld, das die Bridge wirklich sendet, steht im Muster, das die
/// Windows-Oberfläche streng liest. Sonst wäre ein umbenanntes Feld in Bridge.swift überall grün und die Oberfläche
/// läse still den Standardwert.
@MainActor
final class BridgeContractTests: XCTestCase {
    static let muster = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../windows/KlimacontrolTray.Tests/Vertrag/bridge-muster.json").standardizedFileURL

    func testEverySnapshotFieldIsInTheContractSample() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        let c = ACController(appVersion: "test", settings: NoSettings(), paths: CorePaths(directory: dir),
                             platform: NoPlatform(), accounts: accounts,
                             makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
        defer { c.stop() }
        try c.adopt(DeviceConfig(name: "net_ac_1A2B", ip: "192.168.1.40", port: 6444, deviceId: 111122223333444,
                                 token: String(repeating: "ab", count: 64), key: String(repeating: "cd", count: 32)))
        var s = ACState()
        s.power = true
        s.mode = .cool
        s.indoorTemperature = 25.5
        s.outdoorTemperature = 29
        s.powerWatts = 410
        s.totalEnergyKWh = 123.45
        s.outSilent = false
        s.ratePercent = 100
        c.state = s

        let real = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotJSON(c).utf8)) as? [String: Any])
        let sample = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.muster)) as? [String: Any])
        let snapshot = try XCTUnwrap(sample["snapshot"] as? [String: Any])
        var missing: [String] = []
        Self.collectMissing(real, in: snapshot, path: "snapshot", into: &missing)
        XCTAssertEqual(missing, [], "Von der Bridge gesendet, im Muster (bridge-muster.json) nicht")
    }

    /// `kc_history_json` und `kc_history_stats_json` gegen `history` und `stats` im Muster.
    func testHistoryAndStatsFieldsAreInTheContractSample() throws {
        let t0 = Date(timeIntervalSince1970: 1_762_358_395)
        let samples = [
            HistorySample(time: t0, power: 410, indoor: 25.5, outdoor: 29, target: 24, on: true, mode: .cool),
            HistorySample(time: t0.addingTimeInterval(60), power: 400, indoor: 25.4, outdoor: 28.5, target: 24, on: true,
                          mode: .cool),
        ]
        var stats = HistoryStats()
        stats.avgWatts = 350.5
        stats.peakWatts = 620
        stats.kWh = 2.4
        let history = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(encode(historyDTOs(samples, range: 3600), fallback: "[]").utf8)) as? [[String: Any]])
        let statsReal = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(encode(StatsDTO(stats, price: 0.3, currency: "€"), fallback: "{}").utf8)) as? [String: Any])
        XCTAssertNotNil(history.first?["outdoorSmooth"])
        XCTAssertEqual((statsReal["line"] as? [Any])?.count, 4)

        let sample = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.muster)) as? [String: Any])
        var missing: [String] = []
        Self.collectMissing(["history": history, "stats": statsReal],
                            in: ["history": sample["history"] as Any, "stats": sample["stats"] as Any],
                            path: "", into: &missing)
        XCTAssertEqual(missing, [], "Von der Bridge gesendet, im Muster (bridge-muster.json) nicht")
    }

    /// Listen von Objekten: Jeder Schlüssel eines gesendeten Eintrags muss in einem Eintrag der Musterliste stehen.
    private static func collectMissing(_ real: [String: Any], in sample: [String: Any], path: String,
                                       into missing: inout [String]) {
        for (key, value) in real {
            guard let other = sample[key] else { missing.append("\(path).\(key)"); continue }
            if let inner = value as? [String: Any], let otherInner = other as? [String: Any] {
                collectMissing(inner, in: otherInner, path: "\(path).\(key)", into: &missing)
            } else if let items = value as? [[String: Any]], !items.isEmpty, let otherItems = other as? [[String: Any]] {
                let merged = otherItems.reduce(into: [String: Any]()) { all, item in
                    all.merge(item) { first, _ in first }
                }
                for item in items { collectMissing(item, in: merged, path: "\(path).\(key)[]", into: &missing) }
            }
        }
        missing = Array(Set(missing)).sorted()
    }
}
