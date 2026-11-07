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

/// `kc_energy_json` und `options.energy`: Aufbau des JSON, Fehler bei unbekannter Art oder Anzahl.
@MainActor
final class BridgeEnergyTests: XCTestCase {
    private var dir: URL!
    private var controller: ACController!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-energy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        controller = ACController(appVersion: "test", settings: NoSettings(), paths: CorePaths(directory: dir),
                                  platform: NoPlatform(), accounts: accounts,
                                  makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
        controller.stop()
    }

    override func tearDown() async throws {
        controller.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testPeriodsAreListedWithFinishedTexts() throws {
        var s = ACState()
        s.power = true
        s.powerWatts = 600
        let now = Date()
        for back in [120.0, 60.0] {
            let t = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) - back)
            controller.history.db.insert(time: t, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: t))
        }
        let o = try object(energyJSON(controller, kind: "week", count: 3))
        XCTAssertEqual(o["kind"] as? String, "week")
        let periods = try XCTUnwrap(o["periods"] as? [[String: Any]])
        let last = try XCTUnwrap(periods.last)
        XCTAssertEqual(last["current"] as? Bool, true)
        XCTAssertTrue((last["label"] as? String)?.hasPrefix("KW ") ?? false, "\(last)")
        XCTAssertTrue((last["name"] as? String)?.hasPrefix("Kalenderwoche ") ?? false)
        XCTAssertTrue((last["tooltip"] as? String)?.hasSuffix("noch nicht abgeschlossen") ?? false, "\(last)")
        XCTAssertNotNil(last["costText"] as? String)
        XCTAssertNotNil(last["complete"] as? Bool)
        let start = try XCTUnwrap(last["start"] as? Double), end = try XCTUnwrap(last["end"] as? Double)
        XCTAssertLessThan(start, now.timeIntervalSince1970)
        XCTAssertGreaterThan(end, now.timeIntervalSince1970)
        XCTAssertGreaterThan(try XCTUnwrap(last["measuredKWh"] as? Double), 0)
        XCTAssertTrue((o["summary"] as? String)?.hasPrefix("Summe ") ?? false)
        XCTAssertLessThanOrEqual(periods.count, 3)
    }

    func testEmptyHistoryGivesEmptyList() throws {
        let o = try object(energyJSON(controller, kind: "day", count: 14))
        XCTAssertEqual((o["periods"] as? [Any])?.count, 0)
        XCTAssertEqual(o["summary"] as? String, "Summe –")
    }

    func testUnknownKindOrCountIsAnError() throws {
        for (kind, count) in [("year", 5), (nil, 5), ("day", 0), ("day", -1), ("day", 61)] as [(String?, Int)] {
            let o = try object(energyJSON(controller, kind: kind, count: count))
            XCTAssertNotNil(o["error"] as? String, "\(String(describing: kind)) \(count)")
            XCTAssertNil(o["periods"])
        }
        XCTAssertEqual(try object(energyJSON(controller, kind: "year", count: 5))["error"] as? String,
                       "Unbekannte Art des Verbrauchs (day, week, month).")
    }

    func testCFunctionHandlesNullAndUnstartedCore() throws {
        let p = kc_energy_json(nil, 5)
        defer { kc_free(p) }
        XCTAssertNotNil(try object(String(cString: p))["error"])
    }

    func testOptionsCarryTheCatalog() throws {
        let snapshot = try object(snapshotJSON(controller))
        let energy = try XCTUnwrap((snapshot["options"] as? [String: Any])?["energy"] as? [String: Any])
        let kinds = try XCTUnwrap(energy["kinds"] as? [[String: Any]])
        XCTAssertEqual(kinds.compactMap { $0["id"] as? String }, ["day", "week", "month"])
        XCTAssertEqual(kinds.compactMap { $0["label"] as? String }, ["Tage", "Wochen", "Monate"])
        XCTAssertEqual(kinds.compactMap { $0["count"] as? Int }, [14, 8, 12])
        XCTAssertEqual(energy["defaultKind"] as? String, "day")
        XCTAssertEqual(energy["title"] as? String, "Verbrauch")
        XCTAssertEqual(energy["help"] as? String, UIText.energyHelp)
        XCTAssertEqual(energy["legend"] as? String, UIText.energyLegend)
        XCTAssertEqual(energy["noData"] as? String, UIText.energyNoData)
    }
}
