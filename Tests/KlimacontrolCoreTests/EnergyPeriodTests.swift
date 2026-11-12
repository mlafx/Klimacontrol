import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Verbrauch je Tag, Woche und Monat aus `verlauf.sqlite`: Grenzen in Ortszeit, Zählerstände an den Grenzen,
/// Lücken, Rücksprünge, Sommerzeit. Alle Zeiten in Europe/Berlin, damit der Test auf jedem Rechner gleich läuft.
final class EnergyPeriodTests: XCTestCase {
    var dir: URL!
    var savedZone: TimeZone!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-energy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedZone = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
    }

    override func tearDownWithError() throws {
        NSTimeZone.default = savedZone
        try? FileManager.default.removeItem(at: dir)
    }

    private func local(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    struct Row {
        var time: Date
        var watts: Double? = 600
        var kWh: Double?
        var raw: Int?
    }

    /// Zeilen alle 5 min (unter der Lückengrenze von 10 min) von `from` bis `to`; der Zähler steigt je Zeile um 0,05 kWh (= 600 W).
    private func rows(from: Date, to: Date, startKWh: Double = 100, step: TimeInterval = 300) -> [Row] {
        var out: [Row] = []
        var t = from
        var i = 0
        while t <= to {
            out.append(Row(time: t, kWh: startKWh + Double(i) * 0.05))
            t = t.addingTimeInterval(step)
            i += 1
        }
        return out
    }

    /// Datenbank mit fest vorgegebenen Zeilen; `binarySince` = Merker „Zähler binär ab“ (0 = alle Zeilen binär).
    private func makeDB(_ rows: [Row], binarySince: Int = 0, name: String = "verlauf.sqlite") throws -> HistoryDB {
        let url = dir.appendingPathComponent(name)
        _ = HistoryDB(url: url)
        let c = try SQLiteConnection(url: url, mode: .readWrite, busyTimeout: 1000)
        try c.transaction {
            try c.query("INSERT OR REPLACE INTO meta (name, wert) VALUES (?, ?)",
                        [.text("zaehler_binaer_ab"), .text(String(binarySince))])
            for r in rows {
                try c.query("INSERT OR REPLACE INTO verlauf (zeit, leistung_w, gesamt_kwh, zaehler_roh) VALUES (?, ?, ?, ?)",
                            [.integer(HistoryDB.unix(r.time)), r.watts.map { .real($0) }, r.kWh.map { .real($0) },
                             r.raw.map { .integer($0) }])
            }
        }
        return HistoryDB(url: url)
    }

    func testDaysWithCompleteBoundaries() throws {
        let db = try makeDB(rows(from: local(11, 1, 23, 50), to: local(11, 4, 12, 0)))
        let now = local(11, 4, 12, 0)
        let p = db.energyPeriods(.day, count: 3, now: now)
        XCTAssertEqual(p.map(\.start), [local(11, 2), local(11, 3), local(11, 4)])
        XCTAssertEqual(p.map(\.end), [local(11, 3), local(11, 4), local(11, 5)])
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 14.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p[1].kWh), 14.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p[0].measuredKWh), 14.4, accuracy: 0.01)
        XCTAssertEqual(p.map(\.complete), [true, true, true])
        XCTAssertEqual(p.map(\.current), [false, false, true])
        XCTAssertEqual(try XCTUnwrap(p[2].kWh), 7.25, accuracy: 0.001, "laufender Tag: bis zur letzten Zeile")
        XCTAssertEqual(p[0].id, p[0].start)
    }

    func testPeriodsBeforeFirstPointAreOmitted() throws {
        let db = try makeDB(rows(from: local(11, 2, 23, 50), to: local(11, 4, 12, 0)))
        let p = db.energyPeriods(.day, count: 14, now: local(11, 4, 12, 0))
        XCTAssertEqual(p.first?.start, local(11, 2), "der Tag, in den der erste Punkt fällt, ist der älteste")
        XCTAssertEqual(p.count, 3)
        let empty = try makeDB([], name: "leer.sqlite").energyPeriods(.day, count: 14, now: local(11, 4))
        XCTAssertEqual(empty, [])
    }

    func testGapAtBoundaryIsIncomplete() throws {
        let db = try makeDB(rows(from: local(11, 2, 7, 0), to: local(11, 3, 23, 55)))
        let p = db.energyPeriods(.day, count: 3, now: local(11, 4, 0, 30))
        XCTAssertEqual(p.count, 3)
        XCTAssertFalse(p[0].complete, "kein Stand vor Mitternacht: erste Zeile danach, unsicher")
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 10.15, accuracy: 0.001)
        XCTAssertTrue(p[1].complete)
        XCTAssertEqual(try XCTUnwrap(p[1].kWh), 14.4, accuracy: 0.001)
        XCTAssertTrue(p[2].current)
        XCTAssertNil(p[2].kWh, "im laufenden Tag noch keine Zeile")
        XCTAssertNil(p[2].measuredKWh)
    }

    func testCounterResetGivesNilButKeepsMeasurement() throws {
        var r = rows(from: local(11, 2, 23, 50), to: local(11, 4, 0, 10))
        for i in r.indices where r[i].time >= local(11, 3, 12, 0) { r[i].kWh = (r[i].kWh ?? 0) - 50 }
        let p = try makeDB(r).energyPeriods(.day, count: 2, now: local(11, 4, 0, 10))
        XCTAssertNil(p[0].kWh)
        XCTAssertEqual(try XCTUnwrap(p[0].measuredKWh), 14.4, accuracy: 0.01)
        XCTAssertEqual(p[0].shownKWh, p[0].measuredKWh)
        XCTAssertTrue(p[0].fromMeasurement)
    }

    func testRoundingJitterIsNotAReset() throws {
        var r = rows(from: local(11, 2, 23, 50), to: local(11, 3, 23, 55))
        r[r.count - 1].kWh = (r[r.count - 1].kWh ?? 0) - 0.01
        let p = try makeDB(r).energyPeriods(.day, count: 2, now: local(11, 4, 0, 10))
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 14.39, accuracy: 0.001)
    }

    func testImplausibleJumpGivesNil() throws {
        var r = rows(from: local(11, 2, 23, 50), to: local(11, 3, 23, 55))
        for i in r.indices where r[i].time >= local(11, 3, 12, 0) { r[i].kWh = (r[i].kWh ?? 0) + 500 }
        let p = try makeDB(r).energyPeriods(.day, count: 2, now: local(11, 4, 0, 10))
        XCTAssertNil(p[0].kWh, "Zuwachs über der Leistung, die die Anlage aufnehmen kann")
        XCTAssertNotNil(p[0].measuredKWh)
    }

    func testWeekStartsOnMonday() throws {
        let db = try makeDB(rows(from: local(10, 25, 23, 50), to: local(11, 4, 12, 0)))
        let p = db.energyPeriods(.week, count: 2, now: local(11, 4, 12, 0))
        XCTAssertEqual(p.map(\.start), [local(10, 26), local(11, 2)])
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 100.8, accuracy: 0.001)
        XCTAssertEqual(p.map(\.current), [false, true])
        XCTAssertEqual(UIText.energyPeriodLabel(p[0], kind: .week), "KW 44")
        XCTAssertEqual(UIText.energyPeriodLabel(p[1], kind: .week), "KW 45")
    }

    func testMonth() throws {
        let first = local(10, 31, 23, 50)
        let now = local(11, 7, 12, 0)
        let db = try makeDB(rows(from: first, to: now))
        let p = db.energyPeriods(.month, count: 2, now: now)
        XCTAssertEqual(p.map(\.start), [local(10, 1), local(11, 1)])
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 0.05, accuracy: 0.001, "nur zwei Zeilen im Oktober")
        XCTAssertFalse(p[0].complete, "der Oktober beginnt vor dem Verlauf")
        let steps = now.timeIntervalSince(local(10, 31, 23, 55)) / 300
        XCTAssertEqual(try XCTUnwrap(p[1].kWh), steps * 0.05, accuracy: 0.001)
        XCTAssertTrue(p[1].current)
    }

    /// Der 25. 10. 2026 hat 25 Stunden: der Zeitraum ist länger, nicht verschoben.
    func testDayWithRepeatedHour() throws {
        let start = local(10, 25), end = local(10, 26)
        XCTAssertEqual(end.timeIntervalSince(start), 25 * 3600)
        let now = end.addingTimeInterval(3600)
        let db = try makeDB(rows(from: start.addingTimeInterval(-300), to: now))
        let p = db.energyPeriods(.day, count: 2, now: now)
        XCTAssertEqual(p.map(\.start), [start, end])
        XCTAssertEqual(p[0].end, end)
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 15.0, accuracy: 0.001)
        XCTAssertTrue(p[0].complete)
    }

    func testDayWithMissingHour() throws {
        let start = local(3, 29), end = local(3, 30)
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        let now = end.addingTimeInterval(3600)
        let db = try makeDB(rows(from: start.addingTimeInterval(-300), to: now))
        let p = db.energyPeriods(.day, count: 2, now: now)
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 13.8, accuracy: 0.001)
    }

    /// Vor dem Merker „Zähler binär ab“ gilt nur `zaehler_roh` × 0,01 kWh; `gesamt_kwh` ist dort verfälscht.
    func testRowsBeforeBinaryMarkerUseRawCounter() throws {
        var r = rows(from: local(11, 2, 23, 50), to: local(11, 3, 23, 55))
        for i in r.indices {
            r[i].raw = 10_000 + i * 5
            r[i].kWh = 9_999
        }
        let marker = HistoryDB.unix(local(12, 1))
        let p = try makeDB(r, binarySince: marker).energyPeriods(.day, count: 2, now: local(11, 4, 0, 10))
        XCTAssertEqual(try XCTUnwrap(p[0].kWh), 14.4, accuracy: 0.001)
    }

    @MainActor
    func testStoreForwardsToDatabase() throws {
        let db = try makeDB(rows(from: local(11, 2, 23, 50), to: local(11, 4, 12, 0)))
        let store = HistoryStore(db: db, log: HistoryLog(url: dir.appendingPathComponent("verlauf.csv")), importExisting: false)
        let now = local(11, 4, 12, 0)
        XCTAssertEqual(store.energyPeriods(.day, count: 3, now: now),
                       db.energyPeriods(.day, count: 3, now: now))
    }

    // MARK: Katalog

    func testCatalogTexts() {
        XCTAssertEqual(UIOptions.energyKinds.map(\.label), ["Tage", "Wochen", "Monate"])
        XCTAssertEqual(UIOptions.energyKinds.map(\.count), [14, 8, 12])
        XCTAssertEqual(UIOptions.energyKindDefault, .day)
        XCTAssertEqual(UIText.energyTitle, "Verbrauch")
        XCTAssertEqual(UIText.energyHelp, "Verbrauch laut Zähler der Anlage. Die Kosten rechnen mit dem Strompreis aus den Einstellungen, auch für frühere Zeiträume.")
        XCTAssertEqual(UIText.energyLegend, "Uhr: Zeitraum läuft noch · blasser Balken: ca., aus Messwerten geschätzt, Zähler unbekannt · …: Lücke im Verlauf. Mit der Maus über einen Balken fahren zeigt Verbrauch und Kosten.")
        XCTAssertEqual(UIText.energyNoData, "Noch zu wenig Daten – der Verbrauch füllt sich, sobald der Verlauf Zählerstände enthält.")

        let day = EnergyPeriod(start: local(11, 2), end: local(11, 3), kWh: 4.2, measuredKWh: 4.1, complete: true, current: false)
        XCTAssertEqual(UIText.energyPeriodLabel(day, kind: .day), "Mo 2.11.")
        XCTAssertEqual(UIText.energyPeriodName(day, kind: .day), "Montag, 2. November")
        XCTAssertEqual(UIText.energyTooltip(day, kind: .day, price: 0.30), "Montag, 2. November: 4,20 kWh · 1,26 € (Zähler der Anlage)")
        XCTAssertEqual(UIText.energyCost(day, price: 0.30), "1,26 €")

        var measured = day
        measured.kWh = nil
        measured.complete = false
        XCTAssertEqual(UIText.energyTooltip(measured, kind: .day, price: 0.30),
                       "Montag, 2. November: ca. 4,10 kWh · ca. 1,23 € (aus Messwerten, Zähler unbekannt) · unvollständig (Lücke im Verlauf)")
        XCTAssertEqual(UIText.energyCost(measured, price: 0.30), "ca. 1,23 €")

        var running = day
        running.current = true
        XCTAssertEqual(UIText.energyTooltip(running, kind: .day, price: 0.30),
                       "Montag, 2. November: 4,20 kWh · 1,26 € (Zähler der Anlage) · noch nicht abgeschlossen")

        let none = EnergyPeriod(start: local(11, 2), end: local(11, 3), kWh: nil, measuredKWh: nil, complete: false, current: false)
        XCTAssertEqual(UIText.energyTooltip(none, kind: .day, price: 0.30), "Montag, 2. November: keine Daten · unvollständig (Lücke im Verlauf)")
        XCTAssertEqual(UIText.energyCost(none, price: 0.30), "–")

        let week = EnergyPeriod(start: local(11, 2), end: local(11, 9), kWh: 30, measuredKWh: nil, complete: true, current: false)
        XCTAssertEqual(UIText.energyPeriodLabel(week, kind: .week), "KW 45")
        XCTAssertEqual(UIText.energyPeriodName(week, kind: .week), "Kalenderwoche 45 (2.11. – 8.11.)")
        let month = EnergyPeriod(start: local(11, 1), end: local(12, 1), kWh: 30, measuredKWh: nil, complete: true, current: false)
        XCTAssertEqual(UIText.energyPeriodLabel(month, kind: .month), "Nov. 2026")
        XCTAssertEqual(UIText.energyPeriodName(month, kind: .month), "November 2026")

        XCTAssertEqual(UIText.energySummary([day, week], price: 0.30), "Summe 34,20 kWh · 10,26 €")
        XCTAssertEqual(UIText.energySummary([day, measured], price: 0.30), "Summe 8,30 kWh · 2,49 € · teils aus Messwerten")
        XCTAssertEqual(UIText.energySummary([none], price: 0.30), "Summe –")
    }
}
