import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Dateiformate des Verlaufs: Kopfzeilen, Felder, technischer und lesbarer Export, Import zurück, unbekannte Werte,
/// doppelte Stunde am Ende der Sommerzeit. Die Literale halten den Stand vor dem Umbau fest – sie dürfen sich nur
/// mit einer bewussten Formatänderung (und Migration) ändern.
final class HistoryTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Festgehaltene Formate

    static let technicalHeader = "zeit;ein;modus;soll_c;innen_c;aussen_c;luefter;eco;turbo;aussen_leise;leistung_w;"
        + "gesamt_kwh;verdichter_hz;verdichter_soll_hz;strom_a;spannung_v;verdichter_w;t1;t2;t3;t4;tp;eev;"
        + "luefter_innen_upm;luefter_aussen_upm;kondensatpumpe;abtauen;zaehler_roh;fehlercode\n"

    static let readableHeader = "Zeit (Ortszeit);Eingeschaltet (1/0);Modus;Soll (°C);Innen (°C);Außen (°C);Lüfter (%);"
        + "Eco (1/0);Turbo (1/0);Außen leise (1/0);Leistung (W);Zähler gesamt (kWh);Verdichter (Hz);"
        + "Verdichter Soll (Hz);Strom (A);Spannung (V);Verdichter (W);T1 Innenluft (°C);T2 Wärmetauscher innen (°C);"
        + "T3 Wärmetauscher außen (°C);T4 Außenluft (°C);Tp Heißgas (°C);Expansionsventil (Schritte);"
        + "Lüfter innen (U/min);Lüfter außen (U/min);Kondensatpumpe (1/0);Abtauen (1/0);Zähler roh;Fehlercode\n"

    /// Spalten aus AGENTS.md Anhang B in der Reihenfolge der Datei.
    static let columnsAppendixB = ["zeit", "ein", "modus", "soll_c", "innen_c", "aussen_c", "luefter", "eco", "turbo",
                                   "aussen_leise", "leistung_w", "gesamt_kwh", "verdichter_hz", "verdichter_soll_hz",
                                   "strom_a", "spannung_v", "verdichter_w", "t1", "t2", "t3", "t4", "tp", "eev",
                                   "luefter_innen_upm", "luefter_aussen_upm", "kondensatpumpe", "abtauen",
                                   "zaehler_roh", "fehlercode"]

    /// Zustand und Diagnose mit einem Wert in fast jeder Spalte (Außen leise und Abtauen bleiben unbekannt).
    static func fullRow() -> (ACState, Diagnostics) {
        var s = ACState()
        s.power = true
        s.mode = .heat
        s.targetTemperature = 21.5
        s.indoorTemperature = 19
        s.outdoorTemperature = -3.5
        s.fanSpeed = 60
        s.eco = false
        s.turbo = true
        s.outSilent = nil
        s.powerWatts = 640
        s.totalEnergyKWh = 1234.56
        var d = Diagnostics()
        d.compressorHz = 45
        d.compressorTargetHz = 50
        d.currentA = 3
        d.voltageV = 230
        d.compressorPowerW = 600
        d.t1IndoorAir = 21.5
        d.t2IndoorCoil = 30.25
        d.t3OutdoorCoil = -1
        d.t4OutdoorAir = -3.5
        d.tpDischarge = 70
        d.eevOpening = 300
        d.indoorFanRpm = 900
        d.outdoorFanRpm = 800
        d.condensatePump = false
        d.defrost = nil
        d.raw[4] = [0, 0, 0, 0, 0x00, 0x01, 0xE2, 0x40] // 123456 Schritte
        s.errorCode = 25
        return (s, d)
    }

    /// Felder hinter der Zeit, wie `verlauf.csv` sie schreibt (Swift-Zahlen, „21.5“, „19.0“).
    static let fullFields = "1;Heizen;21.5;19.0;-3.5;60;0;1;;640.0;1234.56;45;50;3;230;600;21.5;30.25;-1.0;-3.5;70;300;"
        + "900;800;0;;123456;25"
    /// Dieselbe Zeile im technischen Export (Zahlen, wie SQLite sie ausgibt: ganze Werte ohne „.0“).
    static let fullTechnical = "1;Heizen;21.5;19;-3.5;60;0;1;;640;1234.56;45;50;3;230;600;21.5;30.25;-1;-3.5;70;300;"
        + "900;800;0;;123456;25"
    /// Und im lesbaren Export (Dezimalkomma).
    static let fullReadable = "1;Heizen;21,5;19;-3,5;60;0;1;;640;1234,56;45;50;3;230;600;21,5;30,25;-1;-3,5;70;300;"
        + "900;800;0;;123456;25"
    /// Leerer Zustand: nur, was `ACState` immer kennt; alles andere bleibt leer.
    static let emptyTechnical = "0;Kühlen;22;;;102;0;0;;;;;;;;;;;;;;;;;;;;0"

    private func makeDB(_ name: String = "verlauf.sqlite") -> HistoryDB { HistoryDB(url: dir.appendingPathComponent(name)) }

    /// Ganze Sekunden: die Datenbank speichert Unix-Sekunden.
    private func wholeSecond(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + offset).rounded(.down))
    }

    private func export(_ db: HistoryDB, readable: Bool, name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try db.exportCSV(to: url, from: nil, until: nil, readable: readable)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Kopfzeilen

    func testHeadersMatchPreviousVersionLiterally() {
        XCTAssertEqual(HistoryLog.header, Self.technicalHeader)
        XCTAssertEqual(HistoryLog.readableHeader, Self.readableHeader)
        XCTAssertEqual(HistoryDB.columns, Self.columnsAppendixB, "Anhang B, gleiche Reihenfolge")
    }

    func testEveryReadableNameMapsBackToItsColumn() {
        let technical = Self.technicalHeader.dropLast().split(separator: ";").map(String.init)
        let readable = Self.readableHeader.dropLast().split(separator: ";").map(String.init)
        XCTAssertEqual(readable.count, technical.count)
        XCTAssertEqual(readable.map(HistoryLog.technicalName), technical)
        XCTAssertEqual(technical.map(HistoryLog.technicalName), technical, "technische Namen bleiben")
        XCTAssertEqual(HistoryLog.technicalName("unbekannt"), "unbekannt")
    }

    // MARK: Felder und Export

    func testFieldsOfFullRowMatchPreviousFormat() {
        let (s, d) = Self.fullRow()
        let t = wholeSecond(-600)
        XCTAssertEqual(HistoryLog.fields(state: s, diagnostics: d, time: t).joined(separator: ";"),
                       HistoryLog.isoString(t) + ";" + Self.fullFields)
    }

    func testCSVFileLineMatchesPreviousFormat() throws {
        let (s, d) = Self.fullRow()
        let t = wholeSecond(-600)
        let log = HistoryLog(url: dir.appendingPathComponent("verlauf.csv"))
        log.append(state: s, diagnostics: d, now: t)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text, Self.technicalHeader + HistoryLog.isoString(t) + ";" + Self.fullFields + "\n")
    }

    func testTechnicalExportRoundTrip() throws {
        let (s, d) = Self.fullRow()
        let t1 = wholeSecond(-600), t2 = wholeSecond(-300)
        let db = makeDB()
        db.insert(time: t1, fields: HistoryLog.fields(state: s, diagnostics: d, time: t1))
        db.insert(time: t2, fields: HistoryLog.fields(state: ACState(), diagnostics: Diagnostics(), time: t2))
        let text = try export(db, readable: false, name: "technisch.csv")
        XCTAssertEqual(text, Self.technicalHeader
                       + HistoryLog.isoString(t1) + ";" + Self.fullTechnical + "\n"
                       + HistoryLog.isoString(t2) + ";" + Self.emptyTechnical + "\n")

        let copy = makeDB("kopie.sqlite")
        copy.importCSVOnce(from: [dir.appendingPathComponent("technisch.csv")])
        XCTAssertEqual(try export(copy, readable: false, name: "zurueck.csv"), text, "Export → Import → Export")
    }

    func testReadableExportRoundTrip() throws {
        let (s, d) = Self.fullRow()
        let t1 = wholeSecond(-600), t2 = wholeSecond(-300)
        let db = makeDB()
        db.insert(time: t1, fields: HistoryLog.fields(state: s, diagnostics: d, time: t1))
        db.insert(time: t2, fields: HistoryLog.fields(state: ACState(), diagnostics: Diagnostics(), time: t2))
        let technical = try export(db, readable: false, name: "technisch.csv")
        let text = try export(db, readable: true, name: "lesbar.csv")
        XCTAssertEqual(text, Self.readableHeader
                       + HistoryLog.readableTime(t1) + ";" + Self.fullReadable + "\n"
                       + HistoryLog.readableTime(t2) + ";" + Self.emptyTechnical + "\n")

        let copy = makeDB("kopie.sqlite")
        copy.importCSVOnce(from: [dir.appendingPathComponent("lesbar.csv")])
        XCTAssertEqual(try export(copy, readable: false, name: "zurueck.csv"), technical,
                       "lesbarer Export liest sich zu denselben Werten zurück")
    }

    func testUnknownValuesStayEmpty() throws {
        let t = wholeSecond(-60)
        let db = makeDB()
        db.insert(time: t, fields: HistoryLog.fields(state: ACState(), diagnostics: Diagnostics(), time: t))
        let samples = db.samples(since: t.addingTimeInterval(-1), maxPoints: 100)
        XCTAssertEqual(samples.count, 1)
        XCTAssertNil(samples[0].power)
        XCTAssertNil(samples[0].indoor)
        XCTAssertNil(samples[0].outdoor)
        let last = try XCTUnwrap(db.lastRow())
        XCTAssertNil(last.outSilent)
        XCTAssertNil(last.watts)
        XCTAssertNil(last.totalKWh)

        // Leere, nur aus Leerzeichen bestehende und unlesbare Felder werden NULL, nie 0.
        let file = dir.appendingPathComponent("verlauf-leer.csv")
        try ("zeit;leistung_w;innen_c;gesamt_kwh;modus\n" + "\(HistoryLog.isoString(t));;  ;abc;\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let copy = makeDB("kopie.sqlite")
        copy.importCSVOnce(from: [file])
        XCTAssertEqual(try export(copy, readable: false, name: "leer.csv"),
                       Self.technicalHeader + HistoryLog.isoString(t) + ";" + String(repeating: ";", count: 27) + "\n")
    }

    // MARK: Spaltentabelle und Datenbank

    /// Schreiben und Lesen je Spalte passen zusammen: Felder einer Zeile ergeben wieder dieselbe Zeile.
    func testRowFieldsParseBackToSameRow() {
        let (s, d) = Self.fullRow()
        let row = HistoryRow(state: s, diagnostics: d, time: wholeSecond(0))
        XCTAssertEqual(HistoryRow(time: row.time, fields: row.fields), row)
        XCTAssertEqual(row["modus"], .text("Heizen"))
        XCTAssertEqual(row["soll_c"], .real(21.5))
        XCTAssertEqual(row["luefter"], .int(60))
        XCTAssertEqual(row["ein"], .int(1))
        XCTAssertNil(row["aussen_leise"], "unbekannt")
        XCTAssertNil(row["zeit"], "Zeit ist keine Wertespalte")
        XCTAssertEqual(HistoryRow(time: row.time, fields: ["x", "1"]).values.compactMap { $0 }, [.int(1)],
                       "fehlende Felder sind unbekannt")
    }

    /// Eine ältere Tabelle mit weniger Spalten bekommt die fehlenden dazu; vorhandene Zeilen bleiben.
    func testOlderTableGetsMissingColumns() throws {
        let url = dir.appendingPathComponent("verlauf.sqlite")
        let t = wholeSecond(-120)
        do {
            let old = try SQLiteConnection(url: url, mode: .readWrite, busyTimeout: 1000)
            try old.exec("CREATE TABLE verlauf (zeit INTEGER PRIMARY KEY, ein NUMERIC, leistung_w NUMERIC)")
            try old.query("INSERT INTO verlauf (zeit, ein, leistung_w) VALUES (?, 1, 500)", [.integer(HistoryDB.unix(t))])
        }
        let db = HistoryDB(url: url)
        XCTAssertTrue(db.isOpen)
        let (s, d) = Self.fullRow()
        let t2 = wholeSecond(-60)
        db.insert(time: t2, fields: HistoryLog.fields(state: s, diagnostics: d, time: t2))
        let text = try export(db, readable: false, name: "export.csv")
        XCTAssertEqual(text, Self.technicalHeader
                       + HistoryLog.isoString(t) + ";1;;;;;;;;;500;;;;;;;;;;;;;;;;;;\n"
                       + HistoryLog.isoString(t2) + ";" + Self.fullTechnical + "\n")
    }

    /// SQLite-Fehler kommen typisiert mit Code an; kaputte Dateien werden als solche erkannt.
    func testSQLiteErrorsAreTyped() throws {
        let folder = dir.appendingPathComponent("ordner.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SQLiteConnection(url: folder, mode: .readWrite, busyTimeout: 0)) { error in
            XCTAssertEqual((error as? HistoryDBError)?.code, 14, "SQLITE_CANTOPEN")
        }
        let broken = dir.appendingPathComponent("kaputt.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: broken)
        let c = try SQLiteConnection(url: broken, mode: .readWrite, busyTimeout: 0)
        XCTAssertThrowsError(try c.exec("SELECT * FROM sqlite_master")) { error in
            XCTAssertEqual((error as? HistoryDBError)?.isBrokenFile, true, "\(error)")
        }
        let ok = try SQLiteConnection(url: dir.appendingPathComponent("leer.sqlite"),
                                      mode: .readWrite, busyTimeout: 0)
        XCTAssertThrowsError(try ok.query("SELECT * FROM fehlt")) { error in
            XCTAssertEqual((error as? HistoryDBError)?.code, 1, "SQLITE_ERROR")
            XCTAssertTrue("\(error)".contains("fehlt"), "\(error)")
        }
    }

    // MARK: Sommerzeit

    /// Am Ende der Sommerzeit kommt eine Ortszeit-Stunde zweimal vor. Lesbarer Export und Import zurück behalten beide.
    func testReadableRoundTripKeepsRepeatedHourAtDSTEnd() throws {
        // Feste Ortszeit mit Sommerzeit, damit der Test überall läuft (im Windows-Testprozess setzt keine Bridge die Zone).
        let saved = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        defer { NSTimeZone.default = saved }
        let tz = Calendar.current.timeZone
        let start = Date()
        var end: Date?
        for hour in 1...(24 * 370) {
            let t = start.addingTimeInterval(Double(hour) * 3600)
            if tz.secondsFromGMT(for: t) < tz.secondsFromGMT(for: t.addingTimeInterval(-3600)) {
                var lo = t.addingTimeInterval(-3600), hi = t
                while hi.timeIntervalSince(lo) > 1 {
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    if tz.secondsFromGMT(for: mid) == tz.secondsFromGMT(for: hi) { hi = mid } else { lo = mid }
                }
                end = Date(timeIntervalSince1970: hi.timeIntervalSince1970.rounded(.down))
                break
            }
        }
        guard let end else { throw XCTSkip("Zeitzone ohne Sommerzeit (\(tz.identifier))") }
        let db = makeDB()
        var s = ACState()
        s.power = true
        // Alle 10 min von 1,5 h vor bis 1,5 h nach dem Ende der Sommerzeit – die Stunde davor und danach heißen gleich.
        let times = stride(from: -5400.0, through: 5400, by: 600).map { end.addingTimeInterval($0) }
        for (i, t) in times.enumerated() {
            s.powerWatts = Double(100 + i)
            db.insert(time: t, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: t))
        }
        let readable = try export(db, readable: true, name: "lesbar.csv")
        let local = readable.split(separator: "\n").dropFirst().map { $0.prefix(19) }
        XCTAssertLessThan(Set(local).count, local.count, "Ortszeiten wiederholen sich")

        let copy = makeDB("kopie.sqlite")
        copy.importCSVOnce(from: [dir.appendingPathComponent("lesbar.csv")])
        XCTAssertEqual(try export(copy, readable: false, name: "zurueck.csv"),
                       try export(db, readable: false, name: "technisch.csv"))
        let back = copy.samples(since: times[0].addingTimeInterval(-1), maxPoints: 1_000_000, now: times.last!)
        XCTAssertEqual(back.map(\.time), times)
        XCTAssertEqual(back.map(\.power), times.indices.map { Double(100 + $0) })
    }

    /// Unter Windows liefert `TimeZone.current` GMT; die Ortszeit kommt nur über `Calendar.current` richtig an.
    func testSourcesUseCalendarTimeZoneNotTimeZoneCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var hits: [String] = []
        for target in ["MideaKit", "KlimacontrolCore", "KlimacontrolBridge"] {
            let dir = root.appendingPathComponent("Sources").appendingPathComponent(target)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                for line in text.split(separator: "\n")
                where line.contains("TimeZone.current") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    hits.append("\(target)/\(name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(hits, [], "Calendar.current.timeZone statt TimeZone.current")
    }
}
