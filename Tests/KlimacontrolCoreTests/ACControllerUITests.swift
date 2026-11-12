import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Gemeinsame Oberflächen-Logik im Kern (ACController+UI), „Jetzt aktualisieren“, Diagnose-Umfang und WAL-Checkpoint.
@MainActor
final class ACControllerUITests: CoreTestCase {
    /// Controller mit eingerichteter Anlage, Abfrageschleife angehalten, Zustand einmal gelesen.
    override func makeConnected() async throws -> ACController {
        let c = try await super.makeConnected()
        fake.commands = []
        return c
    }

    /// Lüfter-Zonen brauchen Kühlen oder Heizen und eine eingeschaltete Anlage.
    func makeCooling(fan: Int, turbo: Bool = false, silent: Bool? = false) async throws -> ACController {
        fake.current.power = true
        fake.current.mode = .cool
        fake.current.fanSpeed = fan
        fake.current.turbo = turbo
        fake.current.outSilent = silent
        return try await makeConnected()
    }

    /// Wartet, bis `commands` Befehle an der nachgebildeten Anlage angekommen sind und der Kern nichts mehr sammelt
    /// oder sendet (statt fester Pausen). `commands: 0` heißt „nichts gesendet“: gewartet wird, bis der Kern ruhig ist
    /// (auch gesammelte und verschobene Befehle sind dann gesendet oder verworfen).
    func settle(_ c: ACController, commands n: Int) async throws {
        try await waitUntil("\(n) Befehl(e) angekommen, Kern ruhig") { self.fake.commands.count >= n && c.isIdleForTests }
    }

    // MARK: Zieltext

    func testGoalLineCoversEveryBranch() {
        let c = makeController()
        XCTAssertEqual(c.goalLine, "", "ohne Zustand leer")
        var s = ACState()
        s.power = true
        s.mode = .heat
        s.targetTemperature = 23
        s.indoorTemperature = 21.3
        c.state = s
        XCTAssertEqual(c.goalLine, "Heizt · noch 1,7° bis zum Ziel")
        s.indoorTemperature = 22.7
        c.state = s
        XCTAssertEqual(c.goalLine, "Heizt · Ziel erreicht", "innerhalb von 0,4° gilt das Ziel als erreicht")
        s.mode = .cool
        s.indoorTemperature = 25.5
        c.state = s
        XCTAssertEqual(c.goalLine, "Kühlt · noch 2,5° bis zum Ziel")
        s.indoorTemperature = 22.1
        c.state = s
        XCTAssertEqual(c.goalLine, "Kühlt · Ziel erreicht")
        s.mode = .fan
        c.state = s
        XCTAssertEqual(c.goalLine, "Lüftet · Raum 22,1°")
        s.mode = .dry
        c.state = s
        XCTAssertEqual(c.goalLine, "Entfeuchtet · Raum 22,1°", "Trocknen hat kein Temperaturziel – Raum statt „Ziel erreicht“")
        s.mode = .auto
        s.indoorTemperature = 19.0
        c.state = s
        XCTAssertEqual(c.goalLine, "Regelt automatisch · Raum 19,0°", "Auto regelt selbst – nie „Ziel erreicht“")
        s.indoorTemperature = nil
        c.state = s
        XCTAssertEqual(c.goalLine, "Regelt automatisch", "ohne Raumtemperatur nur das Verb")
        var d = Diagnostics()
        d.defrost = true
        c.diagnostics = d
        XCTAssertEqual(c.goalLine, "Taut gerade ab")
        s.selfClean = true
        c.state = s
        XCTAssertEqual(c.goalLine, "Selbstreinigung läuft", "Selbstreinigung geht vor Abtauen")
    }

    func testStatusLine() {
        let c = makeController()
        XCTAssertEqual(c.statusLine, "")
        var s = ACState()
        s.power = true
        s.mode = .cool
        s.indoorTemperature = 24.46
        c.state = s
        XCTAssertEqual(c.statusLine, "Kühlt · Raum 24,5°")
        c.connectionPath = .lan
        XCTAssertEqual(c.statusLine, "Kühlt · Raum 24,5° · über WLAN")
        s.power = false
        s.indoorTemperature = nil
        c.state = s
        c.connectionPath = .cloud
        XCTAssertEqual(c.statusLine, "Aus · Raum – · über Cloud")
    }

    // MARK: Lüfter-Zonen

    func testFanZonesOnlyWhenCoolingOrHeating() async throws {
        let c = try await makeCooling(fan: 40)
        XCTAssertTrue(c.fanZonesAvailable)
        c.setFanQuiet()
        try await settle(c, commands: 2)
        XCTAssertEqual(fake.commands.count, 2)
        fake.commands = []
        fake.current.mode = .fan
        await c.refresh()
        XCTAssertFalse(c.fanZonesAvailable)
        c.setFanQuiet()
        c.setFanTurbo()
        try await settle(c, commands: 0)
        XCTAssertTrue(fake.commands.isEmpty, "ohne Zonen passiert nichts")
        c.stop()
    }

    func testFanZonesFollowCapabilities() async throws {
        fake.capabilities = ACCapabilities(raw: [0x021A: [2], 0x00CD: [1]])   // Turbo nicht gemeldet, „Leise außen“ ja
        let c = try await makeCooling(fan: 40)
        XCTAssertEqual(c.fanZones, UIOptions.FanZones(quiet: true, turbo: false))
        XCTAssertTrue(c.fanZonesAvailable)
        c.setFanTurbo()
        c.setTurbo(true)
        try await settle(c, commands: 0)
        XCTAssertTrue(fake.commands.isEmpty, "ohne Turbo-Fähigkeit keine Turbo-Zone und kein Turbo")
        c.setFanQuiet()
        try await settle(c, commands: 2)
        XCTAssertEqual(fake.commands.sorted(), ["fan 1", "silent an"])
        c.stop()
    }

    func testTurboOnlyWhileCoolingByCapabilities() async throws {
        fake.capabilities = ACCapabilities(raw: [0x021A: [0]])   // Turbo nur beim Kühlen
        let c = try await makeCooling(fan: 100, turbo: true)
        XCTAssertTrue(c.fanZones.turbo)
        c.setMode(.heat)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.current.mode, .heat)
        XCTAssertFalse(fake.current.turbo, "Turbo gibt es laut Fähigkeiten beim Heizen nicht")
        XCTAssertEqual(c.fanZones, UIOptions.FanZones(quiet: true, turbo: false))
        c.stop()
    }

    func testEcoRefusedWithoutCapability() async throws {
        fake.capabilities = ACCapabilities(raw: [0x0212: [0]])
        let c = try await makeCooling(fan: 40)
        c.setEco(true)
        try await settle(c, commands: 0)
        XCTAssertTrue(fake.commands.isEmpty)
        c.stop()
    }

    func testQuietZoneSetsFanAndSilent() async throws {
        let c = try await makeCooling(fan: 100, turbo: true)
        c.setFanQuiet()
        try await settle(c, commands: 2)
        XCTAssertEqual(fake.commands.sorted(), ["fan 1 turbo aus", "silent an"], "ein Lüfterbefehl (1 % + Turbo aus) und „Leise außen“")
        XCTAssertEqual(fake.current.fanSpeed, 1)
        XCTAssertFalse(fake.current.turbo)
        XCTAssertEqual(fake.current.outSilent, true)
        fake.commands = []
        c.zoneSentAt = .distantPast
        c.setFanQuiet()
        try await settle(c, commands: 0)
        XCTAssertTrue(fake.commands.isEmpty, "schon „Leise außen · 1 %“ – nichts senden")
        c.stop()
    }

    func testQuietZoneSendsOnlyWhatIsMissing() async throws {
        let c = try await makeCooling(fan: 1, silent: false)
        c.setFanQuiet()
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["silent an"], "Lüfter steht schon auf 1 % → nur „Leise außen“")
        c.stop()
    }

    func testTurboZoneSetsFanTurboAndLeavesQuiet() async throws {
        let c = try await makeCooling(fan: 1, silent: true)
        fake.current.eco = true
        await c.refresh()
        fake.commands = []
        c.setFanTurbo()
        try await settle(c, commands: 2)
        XCTAssertEqual(fake.commands.sorted(), ["fan 100 turbo an eco aus", "silent aus"])
        XCTAssertEqual(fake.current.fanSpeed, 100)
        XCTAssertTrue(fake.current.turbo)
        XCTAssertFalse(fake.current.eco)
        XCTAssertEqual(fake.current.outSilent, false)
        fake.commands = []
        c.zoneSentAt = .distantPast
        c.setFanTurbo()
        try await settle(c, commands: 0)
        XCTAssertTrue(fake.commands.isEmpty, "schon Turbo · 100 % – nichts senden")
        c.stop()
    }

    func testLeavingTurboIsOneCombinedCommand() async throws {
        let c = try await makeCooling(fan: 100, turbo: true)
        c.setFan(80, now: true)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["fan 80 turbo aus"], "Turbo aus im selben Befehl, nicht als zweiter")
        XCTAssertFalse(fake.current.turbo)
        c.stop()
    }

    func testLeavingTurboWhileDraggingStillTurnsTurboOff() async throws {
        let c = try await makeCooling(fan: 100, turbo: true)
        // Beim Ziehen zeigt der Zustand den gesammelten Wert schon vor dem Senden – Turbo muss trotzdem mit dem
        // zuletzt gesammelten Befehl ausgehen.
        c.setFan(90, now: false)
        c.setFan(80, now: false)
        c.setFan(70, now: false)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["fan 70 turbo aus"], "nur der letzte Wert, aber mit Turbo aus")
        XCTAssertFalse(fake.current.turbo)
        // Nächste Bewegung nach dem Senden: kein Turbo-Rest mehr im Befehl.
        fake.commands = []
        c.setFan(60, now: true)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["fan 60"])
        c.stop()
    }

    func testLeavingQuietTurnsSilentOffOnceAndRespectsLock() async throws {
        let c = try await makeCooling(fan: 1, silent: true)
        fake.acceptSilent = false // die Anlage antwortet erst später – der Zustand bleibt vorerst „Leise außen“
        c.setFan(40, now: false)
        c.setFan(50, now: false)
        try await settle(c, commands: 2)
        XCTAssertEqual(fake.commands, ["silent aus", "fan 50"], "„Leise außen“ nur einmal aus (2-s-Sperre), dann der letzte Wert")
        c.stop()
    }

    func testRapidZoneClicksSendOnlyTheLast() async throws {
        let c = try await makeCooling(fan: 40)
        c.setFanQuiet()
        c.setFanTurbo()
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["fan 100 turbo an"], "der letzte Klick gilt, gemessen am Stand davor")
        XCTAssertEqual(fake.current.outSilent, false)
        c.stop()
    }

    func testSecondZoneSwitchWaitsForGapInsteadOfBeingDropped() async throws {
        let c = try await makeCooling(fan: 40)
        c.zoneGap = 0.4
        c.setFanQuiet()
        try await settle(c, commands: 2)
        XCTAssertEqual(fake.commands.sorted(), ["fan 1", "silent an"])
        fake.commands = []
        let start = Date()
        c.setFanTurbo()
        try await settle(c, commands: 2)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.25, "zweiter Zonen-Wechsel wartet den Abstand ab")
        XCTAssertEqual(fake.commands, ["silent aus", "fan 100 turbo an"], "verschoben, nicht verschluckt")
        XCTAssertTrue(fake.current.turbo)
        c.stop()
    }

    func testDraggingThroughQuietAndBackSendsOnlyFinalValue() async throws {
        let c = try await makeCooling(fan: 40)
        c.setFanQuiet(now: false)
        c.setFan(45, now: false)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["fan 45"], "kurz in der Zone gewesen: kein „Außengerät leise“ an und wieder aus")
        XCTAssertEqual(fake.current.outSilent, false)
        c.stop()
    }

    func testSilentFromTileStaysWhenFanMoves() async throws {
        let c = try await makeCooling(fan: 40, silent: true)
        c.setFan(60, now: true)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["fan 60"], "per Kachel gesetzt, Lüfter war nicht in der Zone: bleibt an")
        XCTAssertEqual(fake.current.outSilent, true)
        c.stop()
    }

    func testRejectedSilentShowsNoticeButFanStillGoes() async throws {
        let c = try await makeCooling(fan: 40)
        fake.acceptSilent = false
        c.setFanQuiet()
        try await settle(c, commands: 2)
        try await waitUntil("Hinweis zu „Außengerät leise“") { c.notice != nil }
        XCTAssertEqual(fake.commands, ["fan 1", "silent an"])
        XCTAssertEqual(c.state?.fanSpeed, 1)
        XCTAssertEqual(c.state?.outSilent, false, "zeigt den echten Stand")
        XCTAssertTrue(c.notice?.contains("Außengerät leise") ?? false)
        c.stop()
    }

    // MARK: Modus

    func testModeChangeDropsWhatTheNewModeCannotDo() async throws {
        let c = try await makeCooling(fan: 40, silent: true)
        fake.current.eco = true
        await c.refresh()
        fake.commands = []
        c.setMode(.fan)
        try await settle(c, commands: 2)
        XCTAssertEqual(fake.commands.first, "silent aus", "erst „Außengerät leise“ aus, dann der Modus")
        XCTAssertEqual(fake.current.mode, .fan)
        XCTAssertFalse(fake.current.eco)
        XCTAssertEqual(fake.current.outSilent, false)
        XCTAssertNil(c.notice, "kein falscher Hinweis „nicht übernommen“")
        c.stop()
    }

    func testModeChangeToHeatTurnsEcoOff() async throws {
        let c = try await makeCooling(fan: 40)
        fake.current.eco = true
        await c.refresh()
        fake.commands = []
        c.setMode(.heat)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.current.mode, .heat)
        XCTAssertFalse(fake.current.eco, "Eco gibt es nur beim Kühlen")
        XCTAssertTrue(fake.current.power)
        c.stop()
    }

    func testEcoRefusedOutsideCooling() async throws {
        let c = try await makeCooling(fan: 40)
        fake.current.mode = .heat
        await c.refresh()
        fake.commands = []
        c.setEco(true)
        try await settle(c, commands: 0)
        XCTAssertTrue(fake.commands.isEmpty)
        c.stop()
    }

    func testSetFanRejectsInvalidValues() async throws {
        let c = try await makeCooling(fan: 40)
        c.setFan(0, now: true)
        c.setFan(101, now: true)
        c.setFan(-5, now: true)
        c.setFan(FanSpeed.auto.rawValue, now: true)
        try await settle(c, commands: 1)
        XCTAssertEqual(fake.commands, ["fan \(FanSpeed.auto.rawValue)"], "nur 1–100 oder Auto")
        c.stop()
    }

    // MARK: Jetzt aktualisieren, Fenster sichtbar, Diagnose-Umfang

    func testRefreshNowResetsBackoff() async throws {
        let c = try await makeConnected()
        let before = fake.refreshes
        await c.refreshNow()
        XCTAssertEqual(fake.backoffResets, 1)
        XCTAssertEqual(fake.refreshes, before + 1)
        await c.refresh()
        XCTAssertEqual(fake.backoffResets, 1, "die normale Abfrage hebt keine Sperre auf")
        c.stop()
    }

    func testWindowBecomingVisibleResetsBackoff() async throws {
        let c = try await makeConnected()
        c.setUIVisible("main", true)
        XCTAssertEqual(fake.backoffResets, 1, "aus dem Hintergrund sichtbar → sofort wieder WLAN probieren")
        c.setUIVisible("menu", true)
        XCTAssertEqual(fake.backoffResets, 1, "war schon sichtbar → nichts")
        c.setUIVisible("main", false)
        c.setUIVisible("menu", false)
        XCTAssertEqual(fake.backoffResets, 1)
        c.setUIVisible("main", true)
        XCTAssertEqual(fake.backoffResets, 2)
        c.stop()
    }

    func testDiagnosticsFullOnlyWhenVisible() async throws {
        let c = try await makeConnected()
        XCTAssertEqual(fake.lastDiagnosticsFull, false, "für den Verlauf ohne Zusatzabfrage")
        c.diagnosticsVisible = true
        await c.refresh()
        XCTAssertEqual(fake.lastDiagnosticsFull, true, "sichtbare Diagnose liest alles")
        c.stop()
    }

    // MARK: Verlauf: WAL-Checkpoint

    func testCheckpointTruncatesWAL() throws {
        let url = dir.appendingPathComponent("verlauf.sqlite")
        let db = HistoryDB(url: url)
        let now = Date()
        for i in 0..<500 {
            var s = ACState()
            s.power = true
            s.powerWatts = 500
            let t = now.addingTimeInterval(-Double(i) * 10)
            db.insert(time: t, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: t))
        }
        let wal = url.path + "-wal"
        func walSize() -> Int { (try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0 }
        XCTAssertGreaterThan(walSize(), 0, "vor dem Checkpoint steht alles in der WAL-Datei")
        db.checkpoint()
        XCTAssertEqual(walSize(), 0, "danach ist sie leer oder weg")
        XCTAssertEqual(db.samples(since: now.addingTimeInterval(-6000), maxPoints: 100_000).count, 500, "Daten bleiben")

        let store = HistoryStore(db: db, log: HistoryLog(url: dir.appendingPathComponent("verlauf.csv")), importExisting: false)
        store.add(ACState(), now: now.addingTimeInterval(60))
        XCTAssertGreaterThan(walSize(), 0)
        store.close()
        XCTAssertEqual(walSize(), 0, "close() übernimmt die WAL-Datei")
    }

    func testStopCheckpointsHistory() async throws {
        let c = try await makeConnected()
        let wal = dir.appendingPathComponent("verlauf.sqlite").path + "-wal"
        c.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0
        XCTAssertEqual(size, 0)
    }
}
