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

/// Felder für das Hauptfenster wie am Mac: geglättete Außenlinie, Kennzahlenzeile, Skala der Solltemperatur,
/// Zeitachse je Zeitraum und Gewichte der Graphenhöhen. Alles kommt aus dem Kern.
@MainActor
final class BridgeChartFieldsTests: XCTestCase {
    private var dir: URL!
    private var controller: ACController!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-\(UUID().uuidString)")
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

    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotJSON(controller).utf8)) as? [String: Any])
    }

    private func options() throws -> [String: Any] { try XCTUnwrap(json()["options"] as? [String: Any]) }

    private func object(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(encode(value, fallback: "null").utf8))
    }

    // MARK: Verlauf

    func testHistoryCarriesTheSmoothedOutdoorLineOfTheRange() throws {
        let t0 = Date(timeIntervalSince1970: 1_793_700_000)
        // Fühler springt zwischen 5 und 6 °C, ein Punkt ohne Außenwert, danach eine Lücke über der Grenze des Zeitraums.
        var samples = (0..<10).map {
            HistorySample(time: t0.addingTimeInterval(Double($0) * 60), power: 400, indoor: 24, outdoor: $0 % 2 == 0 ? 5 : 6,
                          target: 23, on: true, mode: .cool)
        }
        samples.insert(HistorySample(time: t0.addingTimeInterval(570), power: nil, indoor: 24, outdoor: nil, target: nil,
                                     on: false), at: 10)
        samples.append(HistorySample(time: t0.addingTimeInterval(5000), power: nil, indoor: 24, outdoor: 9, target: nil,
                                     on: false))
        let range = 3600.0
        let dtos = historyDTOs(samples, range: range)
        XCTAssertEqual(dtos.map(\.t), samples.map(\.time.timeIntervalSince1970))
        let smooth = HistorySample.smoothedOutdoor(samples, range: range)
        XCTAssertEqual(dtos.compactMap(\.outdoorSmooth), smooth.compactMap(\.outdoor))
        XCTAssertNil(dtos[10].outdoorSmooth, "ohne Außenwert keine geglättete Zahl")
        XCTAssertEqual(dtos[4].outdoorSmooth ?? 0, 5.5, accuracy: 1e-9, "±5 min um 4 min: Punkte 0…9")
        XCTAssertEqual(dtos[11].outdoorSmooth, 9, "nach der Lücke nicht gemittelt")
        XCTAssertEqual(dtos[3].outdoor, 6, "Messwert bleibt")

        let encoded = try XCTUnwrap(try object(dtos) as? [[String: Any]])
        XCTAssertNil(encoded[10]["outdoorSmooth"], "fehlt statt null")
        XCTAssertEqual((encoded[0]["outdoorSmooth"] as? NSNumber)?.doubleValue ?? 0, smooth[0].outdoor ?? 0, accuracy: 1e-9)
    }

    func testSmoothingSpanAndGapFollowTheRange() {
        let t0 = Date(timeIntervalSince1970: 1_793_700_000)
        let data = (0..<40).map {
            HistorySample(time: t0.addingTimeInterval(Double($0) * 1008), power: nil, indoor: nil,
                          outdoor: Double($0 % 3), target: nil, on: false)
        }
        let week = 7 * 86400.0
        XCTAssertEqual(HistorySample.smoothedOutdoor(data, range: week),
                       HistorySample.smoothedOutdoor(data, span: HistorySample.outdoorSmoothingSpan(range: week),
                                                     gapLimit: UIOptions.chartGapThreshold(range: week)))
    }

    func testStatsCarryTheLineUnderThePowerChart() throws {
        var s = HistoryStats()
        s.avgWatts = 229
        s.peakWatts = 767
        s.kWh = 1.1
        let dto = StatsDTO(s, price: 0.3, currency: "€")
        XCTAssertEqual(dto.avgWatts, 229)
        XCTAssertEqual(dto.kWh, 1.1)
        XCTAssertEqual(dto.line.map(\.text), ["Mittel 229 W", "Spitze 767 W", "1,10 kWh", "0,33 €"])
        XCTAssertEqual(dto.line.map(\.help), UIText.chartStats(s, price: 0.3, currency: "€").map(\.help))
        let empty = StatsDTO(HistoryStats(), price: 0.3, currency: "CHF")
        XCTAssertEqual(empty.line.map(\.text), ["Mittel –", "Spitze –", "–", "–"])
        XCTAssertTrue(empty.line[3].help.contains("CHF"))
    }

    // MARK: Skala der Solltemperatur

    func testTemperatureScaleOptions() throws {
        let scale = try XCTUnwrap(options()["temperatureScale"] as? [String: Any])
        XCTAssertEqual((scale["min"] as? NSNumber)?.doubleValue, UIOptions.temperatureMin)
        XCTAssertEqual((scale["max"] as? NSNumber)?.doubleValue, UIOptions.temperatureMax)
        let labels = try XCTUnwrap(scale["labels"] as? [[String: Any]])
        XCTAssertEqual(labels.compactMap { ($0["value"] as? NSNumber)?.doubleValue }, UIText.temperatureScaleLabels)
        XCTAssertEqual(labels.compactMap { $0["text"] as? String }, ["16°", "25°", "30°"])
        XCTAssertEqual(labels.compactMap { ($0["fraction"] as? NSNumber)?.doubleValue },
                       UIText.temperatureScaleLabels.map(UIText.temperatureScaleFraction))
        let emphasized = try XCTUnwrap(scale["emphasized"] as? [[String: Any]])
        XCTAssertEqual(emphasized.compactMap { ($0["value"] as? NSNumber)?.doubleValue }, UIText.temperatureScaleEmphasized)
        XCTAssertEqual((emphasized.first?["fraction"] as? NSNumber)?.doubleValue ?? 0, 4.0 / 14, accuracy: 1e-12)
        XCTAssertTrue(emphasized.allSatisfy { $0["text"] == nil })
    }

    func testScaleRoomFollowsTheRoomTemperature() throws {
        XCTAssertNil(try json()["scaleRoom"], "ohne Zustand keine Marke")
        var s = ACState()
        s.power = true
        s.indoorTemperature = 23
        controller.state = s
        var room = try XCTUnwrap(json()["scaleRoom"] as? [String: Any])
        XCTAssertEqual((room["value"] as? NSNumber)?.doubleValue, 23)
        XCTAssertEqual((room["fraction"] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual(room["text"] as? String, "Raum 23,0°")
        s.indoorTemperature = 12.46
        controller.state = s
        room = try XCTUnwrap(json()["scaleRoom"] as? [String: Any])
        XCTAssertEqual((room["fraction"] as? NSNumber)?.doubleValue, 0, "unter 16° am linken Rand")
        XCTAssertEqual(room["text"] as? String, "Raum 12,5°")
        s.indoorTemperature = nil
        controller.state = s
        XCTAssertNil(try json()["scaleRoom"], "ohne Raumtemperatur keine Marke")
    }

    // MARK: Zeitachse und Graphenhöhen

    func testRangesCarryTheirTimeAxisStep() throws {
        let chart = try XCTUnwrap(options()["chart"] as? [String: Any])
        let ranges = try XCTUnwrap(chart["ranges"] as? [[String: Any]])
        XCTAssertEqual(ranges.count, UIOptions.chartRanges.count)
        for (r, core) in zip(ranges, UIOptions.chartRanges) {
            XCTAssertEqual(r["label"] as? String, core.label)
            XCTAssertEqual(r["tickMinutes"] as? Int, ChartAxis.timeStepMinutes(range: core.seconds), core.label)
            XCTAssertEqual((r["tickLabelHalfWidth"] as? NSNumber)?.doubleValue,
                           ChartAxis.timeLabelHalfWidth(range: core.seconds), core.label)
        }
        XCTAssertEqual(ranges.compactMap { $0["tickMinutes"] as? Int }, [10, 60, 240, 1440])
        // Die Auffrischungs-Auswahl nutzt weiter ihr eigenes, kleineres Objekt.
        let refresh = try XCTUnwrap((options()["refresh"] as? [String: Any])?["choices"] as? [[String: Any]])
        XCTAssertNil(refresh.first?["tickMinutes"])
    }

    func testWindowCarriesTheChartWeights() throws {
        let w = try XCTUnwrap(options()["window"] as? [String: Any])
        XCTAssertEqual(w["chartWeights"] as? [String: Double], ["power": 3, "temperature": 3, "outdoor": 2])
        XCTAssertEqual(MainWindowLayout.chartWeights, [3, 3, 2])
    }
}
