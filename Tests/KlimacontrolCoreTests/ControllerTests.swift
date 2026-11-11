import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// ACController: Gerätewechsel, gesammelte Befehle, Schlüsselbund-Fehler, Sicherung einlesen,
/// Adresse neu suchen, Startanzeige, Meldungstexte. Fassen weder Schlüsselbund noch Netz noch echte Dateien an.
@MainActor
final class ControllerTests: CoreTestCase {
    var savedCreds: CloudCredentials?
    var saveFails = false
    var sessionCleared = 0

    override func setUp() async throws {
        try await super.setUp()
        savedCreds = nil
        saveFails = false
        sessionCleared = 0
    }

    override func makeAccounts() -> CloudAccountStore {
        CloudAccountStore(
            load: { [unowned self] in savedCreds },
            save: { [unowned self] in
                if saveFails { throw CloudAccountError.notSaved }
                savedCreds = $0
            },
            clear: { [unowned self] in savedCreds = nil },
            verify: { _, _ in },
            clearSession: { [unowned self] in sessionCleared += 1 })
    }

    override func makeController() -> ACController {
        let c = super.makeController()
        c.noticeSeconds = 60
        return c
    }

    var configURL: URL { dir.appendingPathComponent("device.json") }

    // MARK: Neu einrichten / Adresse neu suchen

    func testForgetDeviceTrashesFileUnchangedAndClearsOnlySession() async throws {
        let c = try await makeConnected()
        c.forgetDevice()
        XCTAssertEqual(platform.discarded, [configURL])
        XCTAssertEqual(DeviceConfig.load(from: configURL)?.token, Self.config.token, "Datei unverändert beiseitegelegt")
        XCTAssertEqual(sessionCleared, 1)
        XCTAssertNil(c.config)
        XCTAssertEqual(c.connectionState, .notConfigured)
    }

    func testRelocateAdoptsNewAddressAfterSuccessfulCheck() async throws {
        let c = try await makeConnected()
        c.locate = { _ in (ip: "192.168.1.77", port: 6444) }
        var checked: [String] = []
        c.probe = CredentialProbe { cfg in checked.append(cfg.ip); return nil }
        let ok = await c.relocate()
        XCTAssertTrue(ok)
        XCTAssertEqual(checked, ["192.168.1.77"])
        XCTAssertEqual(c.config?.ip, "192.168.1.77")
        XCTAssertEqual(c.config?.token, Self.config.token, "Zugangsdaten bleiben")
        XCTAssertEqual(DeviceConfig.load(from: configURL)?.ip, "192.168.1.77")
        c.stop()
    }

    func testRelocateKeepsAddressWhenHandshakeFails() async throws {
        let c = try await makeConnected()
        c.locate = { _ in (ip: "192.168.1.77", port: 6444) }
        c.probe = CredentialProbe { _ in MideaError.authenticationFailed("falsch") }
        let ok = await c.relocate()
        XCTAssertFalse(ok)
        XCTAssertEqual(c.config?.ip, Self.config.ip)
        XCTAssertEqual(DeviceConfig.load(from: configURL)?.ip, Self.config.ip)
        XCTAssertNotNil(c.notice)
        XCTAssertTrue(c.relocateMessage?.contains("nicht an") ?? false, c.relocateMessage ?? "")
    }

    /// Eine ungültige Adresse aus der Suche endet nicht stumm: Rückmeldung am Ort der Aktion und als Hinweis.
    func testRelocateReportsInvalidAddress() async throws {
        let c = try await makeConnected()
        c.locate = { _ in (ip: "999.1.1.1", port: 6444) }
        var probed = false
        c.probe = CredentialProbe { _ in probed = true; return nil }
        let ok = await c.relocate()
        XCTAssertFalse(ok)
        XCTAssertFalse(probed)
        XCTAssertEqual(c.relocateMessage, L.Message.Relocate.invalid(ip: "999.1.1.1"))
        XCTAssertNotNil(c.notice)
        XCTAssertEqual(c.config?.ip, Self.config.ip)
        c.stop()
    }

    /// Belegt oder keine Antwort unter der neuen Adresse ist keine Ablehnung: Rat „erneut versuchen“, nicht
    /// „neu einrichten“.
    func testRelocateBusyIsNotTreatedAsRejection() async throws {
        let c = try await makeConnected()
        c.locate = { _ in (ip: "192.168.1.77", port: 6444) }
        c.probe = CredentialProbe { _ in MideaError.busy(.unknown) }
        let ok = await c.relocate()
        XCTAssertFalse(ok)
        let text = try XCTUnwrap(c.relocateMessage)
        XCTAssertTrue(text.contains("erneut"), text)
        XCTAssertFalse(text.contains("neu ein"), text)
        c.stop()
    }

    /// Eine Sicherung wird mit eigener Verbindung geprüft – vorher trennt der Kern seine (nur eine gleichzeitig).
    func testBackupCheckDisconnectsOwnConnectionFirst() async throws {
        let c = try await makeConnected()
        let url = dir.appendingPathComponent("sicherung.json")
        try Self.config.exportBackup(to: url, scenes: [])
        fake.disconnected = false
        var disconnectedBeforeCheck = false
        c.probe = CredentialProbe { [fake] _ in disconnectedBeforeCheck = fake!.disconnected; return nil }
        let r = try await c.importBackupChecked(from: url)
        XCTAssertEqual(r.verified, true)
        XCTAssertTrue(disconnectedBeforeCheck)
        c.stop()
    }

    /// „Leistung begrenzen“ nicht übernommen: Anzeige zeigt den echten Wert der Anlage, nicht den gewünschten.
    func testRateNotAppliedShowsRealValue() async throws {
        fake.current.ratePercent = 100
        let c = try await makeConnected()
        fake.acceptRate = false
        c.setRate(75)
        XCTAssertEqual(c.state?.ratePercent, 75, "sofort angezeigt")
        try await waitUntil("echter Wert zurück") { c.state?.ratePercent == 100 }
        XCTAssertNotNil(c.notice)
        c.stop()
    }

    func testRelocateNotFound() async throws {
        let c = try await makeConnected()
        let ok = await c.relocate() // Standard ohne autostart: findet nichts, kein Netz
        XCTAssertFalse(ok)
        XCTAssertNotNil(c.notice)
        XCTAssertFalse(c.relocating)
    }

    // MARK: Gerätewechsel

    func testQueryOfForgottenDeviceIsDiscarded() async throws {
        let c = makeController()
        try c.adopt(Self.config)
        c.stop()
        let gate = AsyncGate()
        fake.refreshGate = gate
        let query = Task { await c.refreshOnce() }
        try await waitUntil("Abfrage läuft") { self.fake.refreshes == 1 }
        c.forgetDevice()
        gate.open()
        let ran = await query.value
        XCTAssertFalse(ran, "verworfen ist kein Erfolg")
        XCTAssertNil(c.state)
        XCTAssertNil(c.lastUpdate)
    }

    func testCommandDoesNotBreakCloudLogin() async throws {
        let c = try await makeConnected()
        c.update { $0.power = true } // Stellbefehl während der Anmeldung zählt nicht als Einrichtungswechsel
        let err = await c.cloudLogin(account: "a@example.com", password: "pw")
        XCTAssertNil(err)
        XCTAssertEqual(c.cloudAccount, "a@example.com")
    }

    // MARK: Gesammelte Befehle

    func testDebouncedFailureRestoresOrigin() async throws {
        let c = try await makeConnected()
        let start = c.state?.targetTemperature
        fake.failUpdates = true
        c.nudgeTemperature(by: 1)
        c.nudgeTemperature(by: 1)
        try await waitUntil("gesammelter Befehl abgelehnt, Kern ruhig") { self.fake.updates >= 1 && c.isIdleForTests }
        XCTAssertEqual(c.state?.targetTemperature, start, "zurück auf den Stand vor dem ersten Klick")
    }

    func testQueryDuringDebounceWindowIsDiscarded() async throws {
        let c = try await makeConnected()
        let start = c.state?.targetTemperature ?? 22
        c.nudgeTemperature(by: 1)
        let ran = await c.refreshOnce()
        XCTAssertFalse(ran)
        XCTAssertEqual(c.state?.targetTemperature, min(30, max(16, (start + 1).rounded())), "kein Flackern")
        c.stop()
    }

    func testImmediateFanCancelsCollectedFan() async throws {
        let c = try await makeConnected()
        c.setFan(40, now: false)
        c.setFan(FanSpeed.auto.rawValue, now: true)
        // Geprüft wird, dass der verworfene Wert NICHT mehr kommt; dafür muss die Entprellzeit ablaufen.
        try await Task.sleep(for: c.debounceDelay * 3)
        XCTAssertEqual(fake.current.fanSpeed, FanSpeed.auto.rawValue, "der gesammelte Wert überschreibt Auto nicht")
    }

    // MARK: Schlüsselbund

    func testCloudLoginFailsWhenAccountNotSaved() async throws {
        let c = try await makeConnected()
        saveFails = true
        let err = await c.cloudLogin(account: "a@example.com", password: "pw")
        XCTAssertNotNil(err)
        XCTAssertNil(c.cloudAccount)
    }

    // MARK: Sicherung

    func testImportOfOtherDeviceIsRefused() async throws {
        let c = try await makeConnected()
        var other = Self.config
        other.deviceId = 99
        other.name = "Andere"
        let url = dir.appendingPathComponent("andere.json")
        try other.exportBackup(to: url, scenes: [])
        do {
            _ = try await c.importBackupChecked(from: url)
            XCTFail("andere Anlage muss abgelehnt werden")
        } catch let e as BackupImportError {
            XCTAssertEqual(e, .otherDevice(backup: "Andere", current: Self.config.name))
        }
        XCTAssertEqual(c.config?.deviceId, Self.config.deviceId)
        XCTAssertTrue(platform.discarded.isEmpty)
    }

    func testImportKeepsScenesAndTrashesOldFile() async throws {
        let c = try await makeConnected()
        c.saveCurrentAsScene(named: "Eigene")
        var newer = Self.config
        newer.ip = "192.168.1.60"
        let url = dir.appendingPathComponent("b.json")
        try newer.exportBackup(to: url, scenes: [ACScene(id: "x", name: "Fremd", powerOn: true, mode: 2, tempC: 22, fan: 50,
                                                         swing: false, eco: false, anion: false, outdoorSilent: false,
                                                         selfClean: false)])
        c.probe = CredentialProbe { _ in nil }
        let r = try await c.importBackupChecked(from: url)
        XCTAssertEqual(r.verified, true)
        XCTAssertEqual(r.scenesSkipped, 1)
        XCTAssertEqual(c.scenes.map(\.name), ["Eigene"])
        XCTAssertEqual(platform.discarded, [configURL], "bisherige Einrichtung beiseitegelegt")
        XCTAssertTrue(c.credentialsBackedUp)
        c.stop()
    }

    /// Unlesbare Szenen in einer Sicherung verschwinden nicht still: lesbare werden übernommen, der Rest gemeldet.
    func testImportReportsUnreadableScenes() async throws {
        let c = try await makeConnected()
        let url = dir.appendingPathComponent("szenen-kaputt.json")
        let good = ACScene(id: "g", name: "Gut", powerOn: true, mode: 2, tempC: 22, fan: 50, swing: false, eco: false,
                           anion: false, outdoorSilent: false, selfClean: false)
        try Self.config.exportBackup(to: url, scenes: [good])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var scenes = try XCTUnwrap(json["scenes"] as? [Any])
        scenes.append(["id": "k", "name": "Kaputt"])
        json["scenes"] = scenes
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        c.probe = CredentialProbe { _ in nil }
        let r = try await c.importBackupChecked(from: url)
        XCTAssertEqual(r.scenesImported, 1)
        XCTAssertEqual(r.scenesUnreadable, 1)
        XCTAssertEqual(c.scenes.map(\.name), ["Gut"])
        XCTAssertEqual(c.notice, L.Message.Backup.scenesUnreadable)
        c.stop()
    }

    func testImportRejectedByDeviceKeepsSetup() async throws {
        let c = try await makeConnected()
        var newer = Self.config
        newer.ip = "192.168.1.61"
        let url = dir.appendingPathComponent("c.json")
        try newer.exportBackup(to: url, scenes: [])
        c.probe = CredentialProbe { _ in MideaError.authenticationFailed("abgelehnt") }
        do {
            _ = try await c.importBackupChecked(from: url)
            XCTFail("abgelehnte Sicherung darf nichts ersetzen")
        } catch let e as BackupImportError {
            XCTAssertEqual(e, .rejected)
        }
        XCTAssertEqual(c.config?.ip, Self.config.ip)
    }

    func testExportMarksBackedUpAndAdoptResets() async throws {
        let c = try await makeConnected()
        XCTAssertFalse(c.credentialsBackedUp)
        try c.exportBackup(to: dir.appendingPathComponent("s.json"))
        XCTAssertTrue(c.credentialsBackedUp)
        try c.adopt(Self.config)
        XCTAssertFalse(c.credentialsBackedUp)
        c.stop()
    }

    func testExportWithoutSetupThrows() {
        let c = makeController()
        XCTAssertThrowsError(try c.exportBackup(to: dir.appendingPathComponent("leer.json")))
    }

    // MARK: Startanzeige / Aktualität

    func testConnectPhaseAndSlowFlag() async throws {
        let c = makeController()
        try c.adopt(Self.config)
        c.stop()
        c.connectSlowSeconds = 0.05
        let gate = AsyncGate()
        fake.refreshGate = gate
        let query = Task { await c.refreshOnce() }
        try await waitUntil("Verbinden dauert länger als üblich") { c.connectSlow }
        XCTAssertEqual(c.connectPhase, .searching)
        XCTAssertEqual(c.connectionState, .connecting)
        gate.open()
        _ = await query.value
        XCTAssertNil(c.connectPhase)
        XCTAssertFalse(c.connectSlow)
        XCTAssertEqual(c.connectionState, .live)
    }

    func testStaleSinceAfterConnectionError() async throws {
        let c = try await makeConnected()
        XCTAssertNil(c.staleSince)
        let last = c.lastUpdate
        fake.refreshError = MideaError.timeout
        await c.refresh()
        XCTAssertEqual(c.staleSince, last)
        XCTAssertEqual(c.connectionState, .noConnection)
    }

    func testDeviceOffIsTyped() async throws {
        let c = try await makeConnected()
        fake.refreshError = MideaCloud.CloudError.api(3123, "offline")
        await c.refresh()
        XCTAssertTrue(c.deviceOffNotice)
        XCTAssertEqual(c.connectionState, .deviceOff)
        XCTAssertEqual(c.messageDetail?.code, "3123")
    }

    // MARK: Abfrage, Stopp, Signalton

    func testRefreshDuringCommandRunsAfterwards() async throws {
        let c = try await makeConnected()
        let before = fake.refreshes
        c.inFlight = 1
        let ran = await c.refreshOnce()
        XCTAssertFalse(ran)
        XCTAssertTrue(c.refreshPending)
        c.inFlight = 0
        _ = before
    }

    func testStopPreventsPollingRestart() async throws {
        let c = try await makeConnected()
        c.restartPolling()
        XCTAssertTrue(c.pollTask?.isCancelled ?? true, "nach stop() startet keine Abfrage mehr")
    }

    func testFailedSoundRestoresDeviceBeep() async throws {
        let c = try await makeConnected()
        fake.failUpdates = true
        fake.beep = false // das Gerät setzt das Bit vor dem Senden
        c.setSound(false)
        try await waitUntil("Gerät wieder auf der gespeicherten Einstellung") { self.fake.beep }
        XCTAssertTrue(c.beep)
        XCTAssertTrue(fake.beep, "Gerät wieder auf der gespeicherten Einstellung")
    }

    // MARK: Meldungen

    func testUserMessages() {
        let lanDown = PathFailure(path: .lan, reason: .timeout, text: "antwortet nicht")
        let cloudCode = PathFailure(path: .cloud, reason: .cloud(.sessionExpired, code: 3004), text: "token expired (3004)")
        let m = UserMessage.from(MideaError.allPathsFailed([lanDown, cloudCode]))
        XCTAssertEqual(m.what, "Keine Verbindung zur Anlage.")
        XCTAssertEqual(m.code, "3004", "Midea-Code des Cloud-Wegs klein am Ende")
        XCTAssertFalse(m.text.contains("WLAN:"), "Rohtext nur im Detail")
        XCTAssertEqual(m.detail, "Keine Verbindung zur Anlage: WLAN: antwortet nicht · Cloud: token expired (3004)")
        XCTAssertNil(UserMessage.from(MideaError.allPathsFailed([lanDown])).code)
        let off = PathFailure(path: .cloud, reason: .applianceOffline(nextCheck: Date()), text: "Anlage ausgeschaltet")
        XCTAssertTrue(UserMessage.isDeviceOff(MideaError.allPathsFailed([lanDown, off])))
        XCTAssertFalse(UserMessage.isDeviceOff(MideaError.allPathsFailed([lanDown, cloudCode])))
        XCTAssertFalse(UserMessage.isDeviceOff(MideaError.connectionFailed("Anlage ausgeschaltet (3123)")), "kein Textvergleich")
        XCTAssertEqual(UserMessage.from(MideaError.allPathsFailed([lanDown, off])).code, "3123")
        XCTAssertEqual(UserMessage.from(MideaError.allPathsFailed([lanDown, off]) as any Error).code, "3123")
        XCTAssertTrue(UserMessage.from(MideaError.outcomeUnknown("Die Anlage antwortet nicht.")).what.contains("unklar"))
        for e: MideaError in [.refused, .unreachable("x"), .outcomeUnknown("x"), .allPathsFailed([lanDown])] {
            XCTAssertTrue(ACController.isConnectionError(e), "\(e)")
        }
        XCTAssertFalse(ACController.isConnectionError(MideaError.commandNotApplied(ACState())))
        let hex = UserMessage.from(ConfigError.invalidHex).text
        XCTAssertFalse(hex.contains("Hex"))
        XCTAssertTrue(UserMessage.from(MideaCloud.CloudError.api(9999, "x")).text.hasSuffix("(9999)"))
    }

    // MARK: Prüfung der Zugangsdaten, Abhängigkeiten, Aufräumen

    func testCredentialCheckKeepsRejectedBusyAndNoAnswerApart() {
        func kind(_ e: (any Error)?) -> String {
            switch CredentialCheck(e) {
            case .accepted: "ok"
            case .rejected: "abgelehnt"
            case .busy: "belegt"
            case .noAnswer: "keine Antwort"
            }
        }
        XCTAssertEqual(kind(nil), "ok")
        XCTAssertEqual(kind(MideaError.authenticationFailed("x")), "abgelehnt")
        XCTAssertEqual(kind(MideaCloud.CloudError.tokenRejected), "abgelehnt")
        XCTAssertEqual(kind(MideaError.busy(.unknown)), "belegt")
        XCTAssertEqual(kind(MideaError.allPathsFailed([PathFailure(path: .lan, reason: .busy(.otherApp), text: "belegt")])), "belegt")
        XCTAssertEqual(kind(MideaError.refused), "keine Antwort", "abgewiesen ist ohne Beleg nicht „belegt“")
        XCTAssertEqual(kind(MideaError.timeout), "keine Antwort")
        XCTAssertEqual(kind(MideaError.crypto(1)), "keine Antwort", "Lesefehler ist keine Ablehnung")
    }

    /// „Einrichtung unvollständig“ hat wie jede Verbindungsmeldung auch die Teile in `messageDetail`.
    func testIncompleteSetupFillsMessageDetail() throws {
        let deps = CoreDependencies(settings: settings, paths: CorePaths(directory: dir), platform: platform,
                                    accounts: CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in }),
                                    makeDevice: { _, _, _ in throw ConfigError.invalidHex })
        let c = ACController(appVersion: "test", dependencies: deps, autostart: false)
        try c.adopt(Self.config)
        c.stop()
        XCTAssertEqual(c.messageDetail?.what, "Die Einrichtung der Anlage ist unvollständig.")
        XCTAssertEqual(c.message, c.messageDetail?.text)
        XCTAssertEqual(c.connectionState, .noConnection)
    }

    /// Zeitstempel und Timer laufen über die Uhr aus `CoreDependencies`.
    func testInjectedClockIsUsed() async throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let device = fake!
        let deps = CoreDependencies(settings: settings, paths: CorePaths(directory: dir), platform: platform,
                                    accounts: CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in }),
                                    makeDevice: { _, _, _ in device }, now: { fixed })
        let c = ACController(appVersion: "test", dependencies: deps, autostart: false)
        try c.adopt(Self.config)
        c.stop()
        await c.refresh()
        XCTAssertEqual(c.lastUpdate, fixed)
        c.setOffTimer(in: 30)
        XCTAssertEqual(c.offAt, fixed.addingTimeInterval(30 * 60))
    }

    /// Abfrage- und Timer-Schleife halten den Controller nicht fest, während sie schlafen.
    func testLoopsDoNotKeepControllerAlive() async throws {
        weak var released: ACController?
        do {
            let c = makeController()
            try c.adopt(Self.config)
            c.startTimerLoop()
            c.setOffTimer(in: 30)
            try await waitUntil("erste Abfrage") { c.lastUpdate != nil && c.timerTask != nil }
            released = c
        }
        try await waitUntil("Controller freigegeben") { released == nil }
    }

    /// Wird ein Timer neu gesetzt, bevor die Befehle fälliger Timer hinausgehen, geht kein veralteter Befehl mehr
    /// hinaus; der noch fällige Timer bleibt stehen und schaltet in der nächsten Runde.
    func testResettingATimerCancelsPendingTimerCommands() async throws {
        let c = try await makeConnected()
        fake.current.power = true
        let now = Date()
        c.setOffTimer(in: 1, now: now.addingTimeInterval(-61))
        let updatesBefore = fake.updates
        c.checkTimers(now: now)
        XCTAssertNotNil(c.timerFireTask)
        c.setOnTimer(at: now.addingTimeInterval(3600), now: now)
        try await waitUntil("Abbruch abgeschlossen") { c.timerFireTask == nil }
        XCTAssertEqual(fake.updates, updatesBefore, "kein Befehl nach dem Abbruch")
        XCTAssertNotNil(c.offAt, "Aus-Timer bleibt für die nächste Runde")
        c.checkTimers(now: now.addingTimeInterval(1))
        try await waitUntil("Timer ausgeführt") { c.offAt == nil }
        XCTAssertFalse(fake.current.power)
    }
}
