import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// App-Timer (nächstes Vorkommen, verpasst ≠ nicht erreichbar, Ergebnis-Hook), Tagesverbrauch je Anlage,
/// Ausdünnen in Stufen, Export in Ortszeit, letzter Stand aus dem Verlauf.
@MainActor
final class TimerEnergyTests: CoreTestCase {
    /// Eingerichtet, Abfrageschleife angehalten (kein Zustand gelesen).
    func makeAdopted() throws -> ACController {
        let c = makeController()
        try c.adopt(Self.config)
        c.stop()
        return c
    }

    /// Wartet, bis ein ausgelöster Timer-Befehl fertig ist und der Kern ruhig ist.
    func settle(_ c: ACController) async throws {
        try await waitUntil("Timer-Befehl fertig, Kern ruhig") { c.timerFireTask == nil && c.isIdleForTests }
    }

    private func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0, from base: Date) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: base)
        c.hour = hour
        c.minute = minute
        c.second = 0
        return cal.date(byAdding: .day, value: dayOffset, to: cal.date(from: c)!)!
    }

    // MARK: Timer

    /// Ein Picker-Datum von vor drei Tagen wird auf das nächste Vorkommen der Uhrzeit gelegt.
    func testOldPickerDateMeansNextOccurrence() {
        let c = makeController()
        let now = at(22, 30, from: Date(timeIntervalSince1970: 1_800_000_000))
        c.setOnTimer(at: at(7, 0, dayOffset: -3, from: now), now: now)
        XCTAssertEqual(c.onAt, at(7, 0, dayOffset: 1, from: now), "morgen 07:00")
        c.setOnTimer(at: at(23, 15, dayOffset: -3, from: now), now: now)
        XCTAssertEqual(c.onAt, at(23, 15, from: now), "heute 23:15")
        XCTAssertEqual(ACController.timerLabel(c.onAt!, now: now), "heute 23:15")
        c.setOnTimer(hour: 6, minute: 5, now: now)
        XCTAssertEqual(ACController.timerLabel(c.onAt!, now: now), "morgen 06:05")
        XCTAssertLessThanOrEqual(c.onAt!.timeIntervalSince(now), 86400, "nie mehr als 24 h voraus")
    }

    /// Nie versucht und zu alt = „verpasst“, nicht „Anlage nicht erreichbar“.
    func testOverdueUntriedTimerIsMissedNotUnreachable() throws {
        let c = try makeAdopted()
        var results: [TimerOutcome] = []
        c.onTimerResult = { results.append($0) }
        let now = Date()
        c.setOffTimer(in: 1, now: now.addingTimeInterval(-20 * 60))
        c.checkTimers(now: now)
        XCTAssertNil(c.offAt)
        guard case .missed(false, _)? = c.lastTimerResult else { return XCTFail("\(String(describing: c.lastTimerResult))") }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(c.notice?.contains("verpasst") ?? false, c.notice ?? "")
        XCTAssertFalse(c.notice?.contains("nicht erreichbar") ?? true)
        XCTAssertEqual(fake.updates, 0, "verpasst → kein Befehl")
    }

    /// Versucht, nicht angenommen und dann zu alt = „nicht erreichbar“; Wiederholungen ohne vorab angezeigten Zustand.
    func testTriedTimerFailsAsUnreachableAfterGrace() async throws {
        fake.current.power = true
        let c = try makeAdopted()
        await c.refresh()
        let due = Date().addingTimeInterval(-60)
        c.setOffTimer(in: 1, now: due.addingTimeInterval(-60))
        fake.failUpdates = true
        c.checkTimers(now: due.addingTimeInterval(30))
        try await settle(c)
        XCTAssertNotNil(c.offAt, "bleibt für den nächsten Versuch")
        XCTAssertEqual(c.state?.power, true, "nach dem Fehlschlag wieder der echte Zustand")
        c.checkTimers(now: due.addingTimeInterval(45))
        try await settle(c)
        XCTAssertEqual(c.state?.power, true, "Wiederholung zeigt nichts vorab an (kein Flackern)")
        c.checkTimers(now: due.addingTimeInterval(6 * 60))
        XCTAssertNil(c.offAt)
        guard case .failed(false, _, .unreachable)? = c.lastTimerResult else {
            return XCTFail("\(String(describing: c.lastTimerResult))")
        }
    }

    /// Ein verpasster Aus-Timer hält den fälligen Ein-Timer nicht auf; Erfolg wird gemeldet.
    func testTimersAreHandledSeparatelyAndSuccessIsReported() async throws {
        let c = try makeAdopted()
        await c.refresh()
        var results: [TimerOutcome] = []
        c.onTimerResult = { results.append($0) }
        let now = Date()
        c.setOffTimer(in: 1, now: now.addingTimeInterval(-30 * 60))
        c.setOnTimer(at: now.addingTimeInterval(1), now: now)
        c.checkTimers(now: now.addingTimeInterval(2))
        try await settle(c)
        XCTAssertNil(c.offAt)
        XCTAssertNil(c.onAt)
        XCTAssertTrue(fake.current.power)
        XCTAssertEqual(results.count, 2)
        guard case .missed(false, _) = results[0], case .executed(true, _, _) = results[1] else { return XCTFail("\(results)") }
        XCTAssertTrue(results[1].message.contains("eingeschaltet"))
    }

    /// Nach dem ersten Versuch von Hand geschaltet: Die Wiederholung schaltet nicht zurück.
    func testTimerRetryRespectsManualSwitch() async throws {
        let c = try makeAdopted()
        await c.refresh()
        let due = Date().addingTimeInterval(-60)
        c.setOnTimer(at: due, now: due.addingTimeInterval(-1))
        c.onAt = due
        fake.failUpdates = true
        c.checkTimers(now: due.addingTimeInterval(5))
        try await settle(c)
        XCTAssertNotNil(c.onAt, "erster Versuch gescheitert – Timer bleibt")
        fake.failUpdates = false
        fake.current.power = true // die Anlage hatte doch geschaltet, nur die Antwort fehlte
        await c.refresh()
        let before = fake.updates
        c.setPower(false) // der Nutzer will sie aus
        try await waitUntil("Aus-Befehl angekommen, Kern ruhig") { self.fake.updates > before && c.isIdleForTests }
        let updates = fake.updates
        c.checkTimers(now: due.addingTimeInterval(20))
        try await settle(c)
        XCTAssertNil(c.onAt, "Timer beendet")
        XCTAssertFalse(fake.current.power, "nicht wieder eingeschaltet")
        XCTAssertEqual(fake.updates, updates, "kein weiterer Befehl")
    }

    /// Der erste Versuch kam an (nur die Antwort fehlte): Die Wiederholung erkennt das am Zustand.
    func testTimerRetryRecognizesThatFirstAttemptArrived() async throws {
        let c = try makeAdopted()
        await c.refresh()
        let due = Date().addingTimeInterval(-60)
        c.onAt = due
        fake.failUpdates = true
        c.checkTimers(now: due.addingTimeInterval(5))
        try await settle(c)
        fake.failUpdates = false
        fake.current.power = true
        await c.refresh()
        let updates = fake.updates
        c.checkTimers(now: due.addingTimeInterval(20))
        try await settle(c)
        XCTAssertNil(c.onAt)
        guard case .executed(true, _, _)? = c.lastTimerResult else { return XCTFail("\(String(describing: c.lastTimerResult))") }
        XCTAssertEqual(fake.updates, updates, "nicht noch einmal gesendet")
    }

    /// Verpasst beim Start, bevor die Oberfläche ihren Rückruf gesetzt hat: Die Mitteilung kommt nach.
    func testMissedTimerOnLoadReachesLateHook() {
        settings.values[SettingsKey.timerOnAt] = Date().addingTimeInterval(-86400).timeIntervalSince1970
        let c = makeController()
        var results: [TimerOutcome] = []
        c.onTimerResult = { results.append($0) }
        XCTAssertEqual(results.count, 1)
        guard case .missed(true, _)? = results.first else { return XCTFail("\(results)") }
    }

    func testStopReleasesKeepAwake() throws {
        let c = try makeAdopted()
        c.setOffTimer(in: 30)
        platform.awake = []
        c.stop()
        XCTAssertEqual(platform.awake.last, false)
    }

    // MARK: Sommerzeit

    /// Lesbarer Export ohne Zone: Die doppelte Stunde am Ende der Sommerzeit geht beim Einlesen nicht verloren.
    /// Feste Zone und festes Datum, damit der Test auf jedem Rechner läuft (Ende der Sommerzeit 25.10.2026, 01:00 UTC).
    func testReadableImportKeepsRepeatedHourAtDSTEnd() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let end = Date(timeIntervalSince1970: 1_792_890_000)
        XCTAssertEqual(tz.secondsFromGMT(for: end.addingTimeInterval(-60)), 7200, "Sommerzeit davor")
        XCTAssertEqual(tz.secondsFromGMT(for: end), 3600, "Normalzeit danach")
        let f = HistoryLog.readableFormatter(timeZone: tz)
        let first = end.addingTimeInterval(-1800), second = end.addingTimeInterval(1800)
        let text = f.string(from: second)
        XCTAssertEqual(text, "2026-10-25 02:30:00")
        XCTAssertEqual(f.string(from: first), text, "gleiche Ortszeit zweimal")
        let read = try XCTUnwrap(f.date(from: text))
        XCTAssertEqual(HistoryLog.resolveRepeatedHour(read, text: text, after: end.addingTimeInterval(1700), formatter: f),
                       second)
        XCTAssertEqual(HistoryLog.resolveRepeatedHour(read, text: text, after: end.addingTimeInterval(-1900), formatter: f),
                       first, "ohne Rücksprung bleibt es das erste Vorkommen")
        XCTAssertEqual(HistoryLog.resolveRepeatedHour(read, text: text, after: nil, formatter: f), first,
                       "erste Zeile: erstes Vorkommen")
        let plainText = "2026-10-25 04:00:00"
        let plainRead = try XCTUnwrap(f.date(from: plainText))
        XCTAssertEqual(HistoryLog.resolveRepeatedHour(plainRead, text: plainText, after: nil, formatter: f), plainRead,
                       "eindeutige Zeit bleibt")
    }

    func testStaleTimerOnLoadIsReportedAsMissed() {
        settings.values[SettingsKey.timerOnAt] = Date().addingTimeInterval(-86400).timeIntervalSince1970
        let c = makeController()
        XCTAssertNil(c.onAt)
        guard case .missed(true, _)? = c.lastTimerResult else { return XCTFail("\(String(describing: c.lastTimerResult))") }
    }

    func testTimerWithoutSetupFailsWithSetupHint() {
        let c = makeController()
        let now = Date()
        c.setOffTimer(in: 1, now: now.addingTimeInterval(-60))
        c.checkTimers(now: now)
        guard case .failed(false, _, .noDevice)? = c.lastTimerResult else { return XCTFail() }
        XCTAssertTrue(c.notice?.contains("keine Anlage eingerichtet") ?? false)
    }

    // MARK: Tagesverbrauch

    /// Stand kurz vor Mitternacht aus dem Verlauf → „ab Mitternacht“; Rücksprung → neue Zählung.
    func testDayStartFromHistoryAndCounterReset() throws {
        let c = try makeAdopted()
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        var s = ACState()
        s.totalEnergyKWh = 99 // vor der binären Lesart BCD-verfälscht: zählt nicht, nur `zaehler_roh`
        var fields = HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: midnight)
        fields[HistoryDB.columns.firstIndex(of: "zaehler_roh")!] = "5000" // 50,00 kWh
        c.history.db.insert(time: midnight.addingTimeInterval(-300), fields: fields)
        s.totalEnergyKWh = 52
        c.state = s
        c.rememberDayStart(now: now)
        let e = try XCTUnwrap(c.todayEnergy(now: now))
        XCTAssertTrue(e.fromMidnight)
        XCTAssertNil(e.sinceLabel)
        XCTAssertEqual(e.kWh, 2, accuracy: 0.0001)
        XCTAssertEqual(c.storedDayStart()?.device, 42, "Tagesbeginn gehört zur Anlage")

        s.totalEnergyKWh = 3
        c.state = s
        c.rememberDayStart(now: now)
        let r = try XCTUnwrap(c.todayEnergy(now: now))
        XCTAssertEqual(r.kWh, 0, accuracy: 0.0001)
        XCTAssertFalse(r.fromMidnight)
        XCTAssertNotNil(r.sinceLabel, "zeigt „seit HH:MM“")

        c.forgetEnergyDayStart()
        XCTAssertEqual(c.storedDayStart()?.day, "", "nur ein Merker bleibt")
        XCTAssertEqual(c.storedDayStart()?.device, 42, "Merker nennt die bisherige Anlage")
    }

    func testOtherDeviceAfterResetDoesNotUseOldHistory() throws {
        let c = try makeAdopted()
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        let old = ACState()
        var fields = HistoryLog.fields(state: old, diagnostics: Diagnostics(), time: midnight)
        fields[HistoryDB.columns.firstIndex(of: "zaehler_roh")!] = "50000" // 500,00 kWh der alten Anlage
        c.history.db.insert(time: midnight.addingTimeInterval(-300), fields: fields)
        c.forgetEnergyDayStart()
        try c.adopt(DeviceConfig(name: "Neu", ip: "192.168.1.40", port: 6444, deviceId: 111122223333555,
                                 token: Self.token, key: Self.key))
        c.stop()
        var s = ACState()
        s.totalEnergyKWh = 700
        c.state = s
        c.rememberDayStart(now: now)
        let e = try XCTUnwrap(c.todayEnergy(now: now))
        XCTAssertEqual(e.kWh, 0, accuracy: 0.0001, "neue Anlage zählt ab jetzt, nicht gegen den Zähler der alten")
        XCTAssertFalse(e.fromMidnight)
    }

    func testOtherDeviceStartsNewDay() throws {
        let c = try makeAdopted()
        let now = Date()
        settings.values[SettingsKey.energyDayStart] = "\(ACController.dayString(now));10;7;0;1"
        var s = ACState()
        s.totalEnergyKWh = 500
        c.state = s
        c.rememberDayStart(now: now)
        XCTAssertEqual(c.storedDayStart()?.kWh, 500)
        XCTAssertEqual(c.todayKWh ?? -1, 0, accuracy: 0.0001)
    }

    /// Zähler weit über der gemessenen Leistung bei lückenlosem Verlauf → unplausibel.
    func testTodayKWhIsHiddenWhenCounterDoesNotMatchMeasurements() throws {
        let c = try makeAdopted()
        let now = Date()
        let since = now.addingTimeInterval(-3600)
        for t in stride(from: 0.0, through: 3600, by: 10) {
            var s = ACState()
            s.power = true
            s.powerWatts = 1000
            let time = since.addingTimeInterval(t)
            c.history.db.insert(time: time, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: time))
        }
        XCTAssertEqual(c.plausibility(counterKWh: 1.1, since: since, now: now), true)
        XCTAssertEqual(c.plausibility(counterKWh: 3, since: since, now: now), false)
        XCTAssertEqual(c.plausibility(counterKWh: 0.2, since: since, now: now), false, "Zähler unter der Messung")
    }

    // MARK: Verlauf

    /// Ältere Zeilen werden gröber, nicht gelöscht; der Verbrauch bleibt erhalten.
    func testTieredCompactionKeepsEnergy() {
        let db = HistoryDB(url: dir.appendingPathComponent("verlauf.sqlite"))
        let base = Calendar.current.startOfDay(for: Date().addingTimeInterval(-40 * 86400))
        for t in stride(from: 0.0, to: 7200, by: 10) {
            var s = ACState()
            s.power = true
            s.powerWatts = t < 3600 ? 400 : 800
            let time = base.addingTimeInterval(t)
            db.insert(time: time, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: time))
        }
        // Schlusszeile (Anlage aus), damit auch das letzte Fenster eine Dauer hat.
        var off = ACState()
        off.powerWatts = 0
        let end = base.addingTimeInterval(7200)
        db.insert(time: end, fields: HistoryLog.fields(state: off, diagnostics: Diagnostics(), time: end))
        let before = db.stats(since: base.addingTimeInterval(-1)).kWh ?? 0
        XCTAssertEqual(before, 1.2, accuracy: 0.01)
        db.compactAll()
        let rows = db.samples(since: base.addingTimeInterval(-1), maxPoints: 1_000_000)
        XCTAssertEqual(rows.count, 9, "15-Minuten-Raster (8 Fenster + Schlusszeile)")
        XCTAssertEqual(db.stats(since: base.addingTimeInterval(-1)).kWh ?? 0, before, accuracy: 0.01)
        db.compactAll() // zweiter Lauf ab Merker: nichts ändert sich
        XCTAssertEqual(db.samples(since: base.addingTimeInterval(-1), maxPoints: 1_000_000).count, 9)
    }

    /// Export in Ortszeit; lesbarer Export mit deutschen Spalten und Dezimalkomma lässt sich wieder einlesen.
    func testExportLocalTimeAndReadableRoundTrip() throws {
        let db = HistoryDB(url: dir.appendingPathComponent("verlauf.sqlite"))
        let t = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970) - 600))
        var s = ACState()
        s.power = true
        s.indoorTemperature = 25.5
        s.powerWatts = 640
        db.insert(time: t, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: t))

        let plain = dir.appendingPathComponent("export.csv")
        try db.exportCSV(to: plain)
        let line = try String(contentsOf: plain, encoding: .utf8).split(separator: "\n")[1]
        XCTAssertTrue(line.hasPrefix(HistoryLog.isoString(t)))
        if Calendar.current.timeZone.secondsFromGMT(for: t) != 0 { XCTAssertFalse(line.prefix(25).contains("Z"), String(line)) }

        let sub = dir.appendingPathComponent("lesbar")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let readable = sub.appendingPathComponent("verlauf-lesbar.csv")
        try db.exportCSV(to: readable, from: t.addingTimeInterval(-1), until: nil, readable: true)
        let text = try String(contentsOf: readable, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Zeit (Ortszeit);"))
        XCTAssertTrue(text.contains(";25,5;"), text)

        let copy = HistoryDB(url: sub.appendingPathComponent("kopie.sqlite"))
        copy.importCSVOnce(from: [readable])
        let back = copy.samples(since: t.addingTimeInterval(-1), maxPoints: 100)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.time, t)
        XCTAssertEqual(back.first?.indoor, 25.5)
        XCTAssertEqual(back.first?.power, 640)
    }

    /// Ein nicht lesbares File lässt den Import offen (nächster Start versucht es erneut).
    func testImportStaysOpenWhileAFileIsUnreadable() throws {
        let db = HistoryDB(url: dir.appendingPathComponent("verlauf.sqlite"))
        let unreadable = dir.appendingPathComponent("verlauf-z.csv")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        db.importCSVOnce(from: [unreadable])
        let t = Date().addingTimeInterval(-900)
        let file = dir.appendingPathComponent("verlauf-a.csv")
        try (HistoryLog.header + "\(HistoryLog.isoString(t));1;Kühlen;22;24;30;60;0;0;;500;1\n")
            .write(to: file, atomically: true, encoding: .utf8)
        db.importCSVOnce(from: [file])
        XCTAssertEqual(db.samples(since: t.addingTimeInterval(-1), maxPoints: 100).count, 1)
    }

    func testRotationNeverOverwritesAndNeverFailsSilently() throws {
        let url = dir.appendingPathComponent("verlauf.csv")
        for _ in 0..<2 {
            try "zeit;alt\n".write(to: url, atomically: true, encoding: .utf8)
            HistoryLog(url: url).append(state: ACState(), diagnostics: Diagnostics(), now: Date())
        }
        let rotated = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("verlauf-bis-") }
        XCTAssertEqual(rotated.count, 2, "\(rotated)")
    }

    /// Unsinnige Zeiten stürzen nicht ab.
    func testNonFiniteDatesDoNotCrash() {
        let db = HistoryDB(url: dir.appendingPathComponent("verlauf.sqlite"))
        _ = db.stats(since: Date(timeIntervalSince1970: .infinity))
        _ = db.stats(since: Date(timeIntervalSince1970: -.infinity), now: Date(timeIntervalSince1970: .nan))
        _ = db.samples(since: Date(timeIntervalSince1970: .nan), maxPoints: -5, now: Date(timeIntervalSince1970: .infinity))
        db.compact(before: Date(timeIntervalSince1970: .infinity), from: Date(timeIntervalSince1970: -.infinity))
    }

    /// Startanzeige: letzter bekannter Zustand mit Zeit aus dem Verlauf.
    func testLastKnownStateFromHistory() {
        let store = HistoryStore(db: HistoryDB(url: dir.appendingPathComponent("verlauf.sqlite")),
                                 log: HistoryLog(url: dir.appendingPathComponent("verlauf.csv")), importExisting: false)
        XCTAssertNil(store.lastKnown())
        XCTAssertNil(store.lastSample())
        var s = ACState()
        s.power = true
        s.mode = .heat
        s.targetTemperature = 21.5
        s.indoorTemperature = 19
        s.powerWatts = 700
        let t = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))
        store.add(s, now: t)
        let last = store.lastKnown()
        XCTAssertEqual(last?.at, t)
        XCTAssertEqual(last?.state.mode, .heat)
        XCTAssertEqual(last?.state.targetTemperature, 21.5)
        XCTAssertEqual(last?.state.power, true)
        XCTAssertEqual(store.lastSample()?.power, 700)
    }
}
