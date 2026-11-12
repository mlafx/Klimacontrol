import XCTest
import MideaKit
@testable import KlimacontrolCore

/// Fehlercode der Anlage: Protokollzeile bei jedem Wechsel (einmal), Spalte im Verlauf.
@MainActor
final class ErrorCodeTests: CoreTestCase {
    private func count(_ needle: String) -> Int {
        AppLog.tail(2000).components(separatedBy: needle).count - 1
    }

    private func set(_ c: ACController, code: Int, watts: Double? = nil) {
        var s = c.state ?? ACState()
        s.errorCode = code
        s.powerWatts = watts
        c.state = s
    }

    func testLogsEachChangeOnce() async throws {
        let c = try await makeConnected()
        set(c, code: 0)
        let raised = "Fehlercode der Anlage: 77"
        let cleared = "Fehlercode 77 der Anlage nicht mehr gemeldet"
        let before = (count(raised), count(cleared))

        var d = Diagnostics()
        d.compressorHz = 42
        c.diagnostics = d
        set(c, code: 77, watts: 812)
        set(c, code: 77, watts: 900)
        set(c, code: 77, watts: 950)
        XCTAssertEqual(count(raised), before.0 + 1, "nur der Wechsel wird geschrieben")
        XCTAssertTrue(AppLog.tail(2000).contains("Fehlercode der Anlage: 77 (Leistung 812 W, Verdichter 42 Hz)"))

        set(c, code: 0)
        set(c, code: 0)
        XCTAssertEqual(count(cleared), before.1 + 1)
    }

    func testRowCarriesErrorCode() {
        var s = ACState()
        s.errorCode = 25
        XCTAssertEqual(HistoryRow(state: s, diagnostics: Diagnostics(), time: Date())["fehlercode"], .int(25))
        s.errorCode = 0
        XCTAssertEqual(HistoryRow(state: s, diagnostics: Diagnostics(), time: Date())["fehlercode"], .int(0), "0 = keiner")
        let empty = HistoryRow(time: Date(), fields: ["x"])
        XCTAssertNil(empty["fehlercode"], "leer = unbekannt")
    }

    func testDatabaseRoundTripAndMigration() throws {
        let url = dir.appendingPathComponent("verlauf.sqlite")
        let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 300).rounded(.down))
        do {
            let old = try SQLiteConnection(url: url, mode: .readWrite, busyTimeout: 1000)
            try old.exec("CREATE TABLE verlauf (zeit INTEGER PRIMARY KEY, ein NUMERIC, zaehler_roh NUMERIC)")
            try old.query("INSERT INTO verlauf (zeit, ein, zaehler_roh) VALUES (?, 1, 5)", [.integer(HistoryDB.unix(t0))])
        }
        let db = HistoryDB(url: url)
        XCTAssertTrue(db.isOpen)
        var s = ACState()
        s.errorCode = 25
        let t1 = t0.addingTimeInterval(60)
        db.insert(time: t1, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: t1))
        let out = dir.appendingPathComponent("e.csv")
        try db.exportCSV(to: out, from: nil, until: nil, readable: false)
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix(";fehlercode"))
        XCTAssertTrue(lines[1].hasSuffix(";"), "alte Zeile: Fehlercode unbekannt")
        XCTAssertTrue(lines[2].hasSuffix(";25"))
    }
}
