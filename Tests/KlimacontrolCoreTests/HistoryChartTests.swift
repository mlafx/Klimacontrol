import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Rechnungen für die Verlaufsgraphen: Modus je Punkt (auch gemittelt), Modus-Band, geglättete Außentemperatur,
/// Zeitachse, Verbrauch (Durchschnitt, Werte über den Balken) und Kennzahlenzeile.
final class HistoryChartTests: XCTestCase {
    var dir: URL!
    var savedZone: TimeZone!
    let t0 = Date(timeIntervalSince1970: 1_762_300_800)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-chart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedZone = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
    }

    override func tearDownWithError() throws {
        NSTimeZone.default = savedZone
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(_ seconds: Double, outdoor: Double? = nil, on: Bool = true,
                        mode: OperationalMode? = .heat) -> HistorySample {
        HistorySample(time: t0.addingTimeInterval(seconds), power: 100, indoor: 21, outdoor: outdoor, target: 22,
                      on: on, mode: mode)
    }

    // MARK: Modus

    func testModeOnlyWhileRunning() {
        XCTAssertEqual(sample(0, mode: .cool).mode, .cool)
        XCTAssertNil(sample(0, on: false, mode: .cool).mode, "aus = kein Modus")
        XCTAssertEqual(HistorySample.mode(stored: "Kühlen"), .cool)
        XCTAssertNil(HistorySample.mode(stored: ""))
        XCTAssertNil(HistorySample.mode(stored: nil))
        XCTAssertNil(HistorySample.mode(stored: "Unbekannt"))
    }

    func testSamplesCarryPredominantModePerWindow() throws {
        let url = dir.appendingPathComponent("verlauf.sqlite")
        _ = HistoryDB(url: url)
        let c = try SQLiteConnection(url: url, mode: .readWrite, busyTimeout: 1000)
        // Fenster 1 (0–99 s): 3 × Heizen, 1 × Kühlen → Heizen. Fenster 2 (100–199 s): aus. Fenster 3: Kühlen und aus.
        let rows: [(Int, Int, String?)] = [(0, 1, "Heizen"), (10, 1, "Heizen"), (20, 1, "Kühlen"), (30, 1, "Heizen"),
                                           (100, 0, "Heizen"), (110, 0, nil),
                                           (200, 1, "Kühlen"), (210, 0, "Heizen"), (220, 0, "Heizen")]
        let base = HistoryDB.unix(t0) / 100 * 100
        try c.transaction {
            for (dt, on, mode) in rows {
                try c.query("INSERT INTO verlauf (zeit, ein, modus, leistung_w) VALUES (?, ?, ?, ?)",
                            [.integer(base + dt), .integer(on), mode.map { .text($0) }, .real(100)])
            }
        }
        let db = HistoryDB(url: url)
        let start = Date(timeIntervalSince1970: Double(base))
        let s = db.samples(since: start, maxPoints: 3, now: start.addingTimeInterval(300))
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.map(\.mode), [.heat, nil, .cool])
        XCTAssertEqual(s.map(\.on), [true, false, true])
        let dense = db.samples(since: start, maxPoints: 1000, now: start.addingTimeInterval(300))
        XCTAssertEqual(dense.prefix(4).map(\.mode), [.heat, .heat, .cool, .heat])
    }

    func testModeRuns() {
        let gap = 180.0
        let data = [sample(0, mode: .heat), sample(60, mode: .heat), sample(120, mode: .cool),
                    sample(180, on: false), sample(240, mode: .cool),
                    // Lücke über 180 s: Lauf endet beim letzten eigenen Punkt.
                    sample(300, mode: .cool), sample(900, mode: .cool), sample(960, mode: .cool)]
        let runs = HistorySample.modeRuns(data, gapLimit: gap)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        XCTAssertEqual(runs, [
            .init(mode: .heat, start: at(0), end: at(120)),
            .init(mode: .cool, start: at(120), end: at(180)),
            .init(mode: .cool, start: at(240), end: at(300)),
            .init(mode: .cool, start: at(900), end: at(960)),
        ])
        XCTAssertTrue(HistorySample.modeRuns([], gapLimit: gap).isEmpty)
        XCTAssertTrue(HistorySample.modeRuns([sample(0)], gapLimit: gap).isEmpty, "ein Punkt hat keine Dauer")
        XCTAssertTrue(HistorySample.modeRuns([sample(0, on: false), sample(60, on: false)], gapLimit: gap).isEmpty)
    }

    // MARK: Außentemperatur glätten

    func testSmoothedOutdoorAveragesNeighbours() {
        // Fühler springt zwischen 5 und 6 °C.
        let data = (0..<10).map { sample(Double($0) * 60, outdoor: $0 % 2 == 0 ? 5 : 6) }
        let s = HistorySample.smoothedOutdoor(data, span: 240, gapLimit: 180)
        XCTAssertEqual(s.count, data.count)
        XCTAssertEqual(s.map(\.time), data.map(\.time), "Zeiten bleiben")
        // Mitte: 5 Punkte (±120 s) → 5,4 bzw. 5,6.
        XCTAssertEqual(s[4].outdoor ?? 0, (5 + 6 + 5 + 6 + 5) / 5, accuracy: 1e-9)
        XCTAssertEqual(s[5].outdoor ?? 0, (6 + 5 + 6 + 5 + 6) / 5, accuracy: 1e-9)
        // Rand: nur vorhandene Nachbarn (0, 60, 120 s).
        XCTAssertEqual(s[0].outdoor ?? 0, (5 + 6 + 5) / 3, accuracy: 1e-9)
        XCTAssertEqual(s[9].outdoor ?? 0, (6 + 5 + 6) / 3, accuracy: 1e-9)
        XCTAssertEqual(s[3].power, data[3].power, "übrige Werte bleiben")
        XCTAssertEqual(s[3].mode, data[3].mode)
    }

    func testSmoothedOutdoorDoesNotBridgeGaps() {
        let data = [sample(0, outdoor: 0), sample(60, outdoor: 0), sample(1000, outdoor: 10), sample(1060, outdoor: 10)]
        let s = HistorySample.smoothedOutdoor(data, span: 3000, gapLimit: 180)
        XCTAssertEqual(s.map(\.outdoor), [0, 0, 10, 10])
    }

    func testSmoothedOutdoorEdgeCases() {
        XCTAssertTrue(HistorySample.smoothedOutdoor([], span: 600, gapLimit: 180).isEmpty)
        let one = [sample(0, outdoor: 7.5)]
        XCTAssertEqual(HistorySample.smoothedOutdoor(one, span: 600, gapLimit: 180), one)
        // Punkte ohne Außenwert fallen weg, der Rest wird über sie hinweg gemittelt (keine Zeitlücke).
        let mixed = [sample(0, outdoor: 4), sample(30), sample(60, outdoor: 6)]
        let s = HistorySample.smoothedOutdoor(mixed, span: 600, gapLimit: 180)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.map(\.outdoor), [5, 5])
    }

    func testSmoothingSpanFollowsRange() {
        XCTAssertEqual(HistorySample.outdoorSmoothingSpan(range: 3600), 600)
        XCTAssertEqual(HistorySample.outdoorSmoothingSpan(range: 6 * 3600), 600)
        XCTAssertEqual(HistorySample.outdoorSmoothingSpan(range: 7 * 86400), 4 * 1008)
    }

    // MARK: Achsen

    func testExtendedBelowKeepsGrid() throws {
        let a = try XCTUnwrap(ChartAxis.power([900]))
        let e = a.extendedBelow(fraction: 0.1)
        XCTAssertEqual(e.max, a.max)
        XCTAssertEqual(e.ticks, a.ticks)
        XCTAssertEqual((0 - e.min) / (e.max - e.min), 0.1, accuracy: 1e-9)
        XCTAssertEqual(a.extendedBelow(fraction: 0), a)
        XCTAssertEqual(a.extendedBelow(fraction: 1), a)
    }

    func testHeadroom() throws {
        let a = try XCTUnwrap(ChartAxis.power([6]))
        XCTAssertEqual(a.max, 6)
        let h = a.withHeadroom(above: 6, fraction: 0.25)
        XCTAssertEqual(h.max, 8)
        XCTAssertEqual([h.first, h.step], [a.first, a.step], "Gitter bleibt im selben Raster")
        XCTAssertEqual(a.withHeadroom(above: 1, fraction: 0.25), a, "genug Platz: unverändert")
        XCTAssertEqual(a.withHeadroom(above: .nan, fraction: 0.25), a)
    }

    func testTimeTicksOnRoundLocalTimesInsideThePlot() throws {
        let cal = Calendar.current
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 17, minute: 52)))
        let end = start.addingTimeInterval(6 * 3600)  // 23:52
        let ticks = ChartAxis.timeTicks(domain: start...end, range: 6 * 3600, plotWidth: 400, labelHalfWidth: 16)
        // 18:00 liegt 8 min nach dem Anfang (≈ 9 pt): Die Beschriftung ragte links hinaus.
        XCTAssertEqual(ticks.map { cal.component(.hour, from: $0) }, [19, 20, 21, 22, 23])
        XCTAssertTrue(ticks.allSatisfy { cal.component(.minute, from: $0) == 0 })
        // Rechts ebenso: Endet die Achse 23:05, läge 23:00 bei 394 pt und würde zu „…“ gekürzt.
        let tight = ChartAxis.timeTicks(domain: start...start.addingTimeInterval(313 * 60), range: 6 * 3600,
                                        plotWidth: 400, labelHalfWidth: 16)
        XCTAssertEqual(tight.map { cal.component(.hour, from: $0) }, [19, 20, 21, 22])
    }

    func testTimeTickSteps() throws {
        let cal = Calendar.current
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 0, minute: 30)))
        XCTAssertEqual(ChartAxis.timeStepMinutes(range: 3600), 10)
        XCTAssertEqual(ChartAxis.timeStepMinutes(range: 6 * 3600), 60)
        XCTAssertEqual(ChartAxis.timeStepMinutes(range: 86400), 240)
        XCTAssertEqual(ChartAxis.timeStepMinutes(range: 7 * 86400), 1440)
        let hour = ChartAxis.timeTicks(domain: start...start.addingTimeInterval(3600), range: 3600, plotWidth: 0)
        XCTAssertEqual(hour.map { cal.component(.minute, from: $0) }, [30, 40, 50, 0, 10, 20, 30])
        let day = ChartAxis.timeTicks(domain: start...start.addingTimeInterval(86400), range: 86400, plotWidth: 0)
        XCTAssertEqual(day.map { cal.component(.hour, from: $0) }, [4, 8, 12, 16, 20, 0])
        let week = ChartAxis.timeTicks(domain: start...start.addingTimeInterval(7 * 86400), range: 7 * 86400, plotWidth: 0)
        XCTAssertEqual(week.count, 7)
        XCTAssertTrue(week.allSatisfy { cal.component(.hour, from: $0) == 0 && cal.component(.minute, from: $0) == 0 })
        XCTAssertTrue(ChartAxis.timeTicks(domain: start...start, range: 3600, plotWidth: 400).isEmpty)
    }

    func testTimeTicksAcrossDaylightSavingEnd() throws {
        let cal = Calendar.current
        // 25.10.2026: 03:00 Sommerzeit → 02:00 Winterzeit (Europe/Berlin).
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 22)))
        let ticks = ChartAxis.timeTicks(domain: start...start.addingTimeInterval(86400), range: 86400, plotWidth: 0)
        XCTAssertTrue(ticks.allSatisfy { cal.component(.hour, from: $0) % 4 == 0 && cal.component(.minute, from: $0) == 0 })
        XCTAssertEqual(Set(ticks).count, ticks.count)
    }

    // MARK: Verbrauch

    private func period(_ day: Int, kWh: Double?, measured: Double? = nil, current: Bool = false) -> EnergyPeriod {
        let start = t0.addingTimeInterval(Double(day) * 86400)
        return EnergyPeriod(start: start, end: start.addingTimeInterval(86400), kWh: kWh, measuredKWh: measured,
                            complete: true, current: current)
    }

    func testEnergyAverageLeavesOutCurrentAndEmpty() {
        let periods = [period(0, kWh: 2), period(1, kWh: nil, measured: 4), period(2, kWh: nil),
                       period(3, kWh: 9, current: true)]
        XCTAssertEqual(UIText.energyAverage(periods), 3)
        XCTAssertNil(UIText.energyAverage([period(0, kWh: 5, current: true)]))
        XCTAssertNil(UIText.energyAverage([]))
        Localizer.withLanguage(.de) {
            XCTAssertEqual(UIText.energyAverageText(periods), "Durchschnitt 3,00 kWh")
        }
        Localizer.withLanguage(.en) {
            XCTAssertEqual(UIText.energyAverageText(periods), "Average " + Fmt.kwh(3))
        }
    }

    func testEnergyBarValue() {
        Localizer.withLanguage(.de) {
            XCTAssertEqual(UIText.energyBarValue(period(0, kWh: 4.24), barCount: 14), "4,2")
            XCTAssertEqual(UIText.energyBarValue(period(0, kWh: 123.4), barCount: 12), "123")
            XCTAssertEqual(UIText.energyBarValue(period(0, kWh: 9.96), barCount: 12), "10")
            XCTAssertEqual(UIText.energyBarValue(period(0, kWh: nil, measured: 1.05), barCount: 8), "1,1")
            XCTAssertEqual(UIText.energyBarValue(period(0, kWh: 3, current: true), barCount: 8), "3,0", "auch der laufende")
            XCTAssertNil(UIText.energyBarValue(period(0, kWh: nil), barCount: 8))
            XCTAssertNil(UIText.energyBarValue(period(0, kWh: 4), barCount: UIOptions.energyValuesMaxBars + 1))
        }
        XCTAssertEqual(UIOptions.energyValuesMaxBars, 14)
        XCTAssertLessThanOrEqual(UIOptions.energyChoice(.day).count, UIOptions.energyValuesMaxBars)
    }

    func testChartStatsLine() {
        let s = HistoryStats(avgWatts: 229, peakWatts: 767, kWh: 1.1)
        Localizer.withLanguage(.de) {
            let parts = UIText.chartStats(s, price: 0.3, currency: "€")
            XCTAssertEqual(parts.map(\.text).joined(separator: " · "), "Mittel 229 W · Spitze 767 W · 1,10 kWh · 0,33 €")
            XCTAssertEqual(parts[0].help, L.Charts.Tile.avgHelp)
            XCTAssertTrue(parts[3].help.contains("0,30 €"))
        }
        Localizer.withLanguage(.en) {
            let parts = UIText.chartStats(s, price: 0.3, currency: "€")
            XCTAssertEqual(parts.map(\.text).first, "Average 229 W")
            XCTAssertEqual(parts[1].text, "Peak 767 W")
        }
    }

    func testNewChartTexts() {
        Localizer.withLanguage(.de) {
            XCTAssertEqual(L.Charts.Series.outdoor, "Außen")
            XCTAssertEqual(L.Charts.hoverOutdoor(outdoor: "5,2°"), "Außen 5,2°")
            XCTAssertEqual(L.Settings.Appearance.TemperatureCombined.title, "Außentemperatur im Temperaturgraphen zeigen")
        }
        Localizer.withLanguage(.en) {
            XCTAssertEqual(L.Charts.Series.outdoor, "Outdoor")
            XCTAssertEqual(L.Settings.Appearance.TemperatureCombined.title, "Show outdoor temperature in the temperature chart")
        }
    }
}
