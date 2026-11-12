import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

@MainActor
final class KlimacontrolCoreTests: CoreTestCase {
    var savedCreds: CloudCredentials?
    /// Gesetzt: die Prüfung beim Anmelden wartet auf dieses Tor (ersetzt eine feste Verzögerung).
    var verifyGate: AsyncGate?
    var verifyFails = false
    /// Aufrufe von `CloudAccountStore.clearSession` (statt die echte Sitzung im Schlüsselbund zu löschen).
    var sessionClears = 0

    override func setUp() async throws {
        try await super.setUp()
        savedCreds = nil
        verifyGate = nil
        verifyFails = false
        sessionClears = 0
    }

    override func makeAccounts() -> CloudAccountStore {
        CloudAccountStore(
            load: { [unowned self] in savedCreds },
            save: { [unowned self] in savedCreds = $0 },
            clear: { [unowned self] in savedCreds = nil },
            verify: { [unowned self] _, _ in
                if let verifyGate { await verifyGate.wait() }
                if verifyFails { throw MideaCloud.CloudError.api(-1, "falsches Passwort") }
            },
            clearSession: { [unowned self] in sessionClears += 1 })
    }

    // MARK: Formatierung

    func testFormatsGerman() {
        XCTAssertEqual(Fmt.temp(21.46), "21,5°")
        XCTAssertEqual(Fmt.temp(nil), "–")
        XCTAssertEqual(Fmt.target(21.6), "22°")
        XCTAssertEqual(Fmt.watts(812.4), "812 W")
        XCTAssertEqual(Fmt.kwh(1.234), "1,23 kWh")
        XCTAssertEqual(Fmt.money(0.5, currency: "€"), "0,50 €")
        XCTAssertEqual(ACController.pad(7, 2), "07")
        XCTAssertEqual(ACController.pad(2026, 4), "2026")
    }

    func testDescribeChange() {
        var a = ACState()
        a.power = false
        var b = a
        b.power = true
        b.targetTemperature = 23
        b.eco = !a.eco
        let text = Fmt.change(from: a, to: b)
        XCTAssertTrue(text.hasPrefix("ein"), text)
        XCTAssertTrue(text.contains("Soll 23°"), text)
        XCTAssertTrue(text.contains("Eco"), text)
        XCTAssertEqual(Fmt.change(from: a, to: a), "")
    }

    // MARK: Einstellungen

    func testSettingsAreClampedAndPersisted() {
        let c = makeController()
        XCTAssertEqual(c.refreshSeconds, 30)
        c.refreshSeconds = 0
        XCTAssertEqual(c.refreshSeconds, 1)
        c.refreshSeconds = 5000
        XCTAssertEqual(c.refreshSeconds, 600)
        XCTAssertEqual(settings.values[SettingsKey.refreshSeconds] as? Int, 600)

        c.pricePerKWh = -1
        XCTAssertEqual(c.pricePerKWh, 0.30, "negativer Preis wird ignoriert")
        c.pricePerKWh = .nan
        XCTAssertEqual(c.pricePerKWh, 0.30)
        c.pricePerKWh = 0.42
        XCTAssertEqual(settings.values[SettingsKey.pricePerKWh] as? Double, 0.42)

        c.displayName = "Schlaf\nzimmer"
        XCTAssertEqual(c.displayName, "Schlafzimmer", "Steuerzeichen raus")
        c.connectionMode = .lan
        let again = makeController()
        XCTAssertEqual(again.displayName, "Schlafzimmer")
        XCTAssertEqual(again.connectionMode, .lan)
        XCTAssertEqual(again.refreshSeconds, 600)
    }

    func testStoredValuesOutOfRangeAreClampedOnLoad() {
        settings.values[SettingsKey.refreshSeconds] = 0
        settings.values[SettingsKey.pricePerKWh] = 1001.0
        let c = makeController()
        XCTAssertEqual(c.refreshSeconds, 1)
        XCTAssertEqual(c.pricePerKWh, 0.30)
    }

    /// Ein gespeicherter Bluetooth-Weg (Bluetooth gibt es nicht mehr) wird beim Laden „Automatisch“.
    func testStoredBluetoothModeLoadsAsAuto() {
        for old in ["ble", "blePreferred"] {
            settings.values[SettingsKey.connectionMode] = old
            XCTAssertEqual(makeController().connectionMode, .auto, old)
        }
    }

    /// Echte UserDefaults (eigene Suite) – Typumwandlung Int/Double wie auf dem System.
    func testWorksWithRealUserDefaults() throws {
        let suite = "klimacontrol-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let noCloud = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        let c = ACController(appVersion: "test", settings: defaults, paths: CorePaths(directory: dir), platform: platform,
                             accounts: noCloud, autostart: false)
        c.refreshSeconds = 12
        c.pricePerKWh = 0.35
        let again = ACController(appVersion: "test", settings: defaults, paths: CorePaths(directory: dir), platform: platform,
                                 accounts: noCloud, autostart: false)
        XCTAssertEqual(again.refreshSeconds, 12)
        XCTAssertEqual(again.pricePerKWh, 0.35)
    }

    // MARK: Stellbefehle

    func testUpdateShowsImmediatelyAndConfirms() async throws {
        let c = try await makeConnected()
        await c.send { $0.targetTemperature = 25 }
        XCTAssertEqual(c.state?.targetTemperature, 25)
        XCTAssertEqual(fake.updates, 1)
        XCTAssertNil(c.message)
        XCTAssertFalse(c.busy)
    }

    func testFailedUpdateRollsBackAndRereads() async throws {
        let c = try await makeConnected()
        let before = c.state?.targetTemperature
        fake.failUpdates = true
        let refreshesBefore = fake.refreshes
        let ok = await c.send { $0.targetTemperature = 29 }
        XCTAssertFalse(ok)
        XCTAssertEqual(c.state?.targetTemperature, before, "zurück auf den Ausgangsstand")
        XCTAssertEqual(fake.refreshes, refreshesBefore + 1, "danach frisch gelesen (busy blockiert das nicht mehr)")
        XCTAssertNotNil(c.notice, "abgelehnter Befehl ist ein Hinweis")
        XCTAssertNil(c.message, "… und kein Verbindungsfehler")
        XCTAssertFalse(c.lastRefreshFailed)
    }

    // MARK: Verbindungsfehler und Hinweise

    func testRefreshTimeoutIsAConnectionErrorUntilTheNextSuccess() async throws {
        let c = try await makeConnected()
        // Nur Zeilen nach einer eigenen Markierung zählen – das Fenster von `tail` verschiebt sich mit jeder Zeile.
        let marker = "Testmarke \(UUID().uuidString)"
        AppLog.write(marker)
        let reconnects = {
            (AppLog.tail(1000).components(separatedBy: marker).last ?? "")
                .components(separatedBy: "Verbindung wieder da").count - 1
        }
        let before = reconnects()
        XCTAssertEqual(before, 0)
        fake.refreshError = MideaError.timeout
        await c.refresh()
        XCTAssertEqual(c.message, UserMessage.from(MideaError.timeout).text)
        XCTAssertTrue(c.lastRefreshFailed)
        XCTAssertFalse(c.deviceOffNotice)
        XCTAssertNil(c.notice)

        fake.refreshError = nil
        await c.refresh()
        XCTAssertFalse(c.lastRefreshFailed)
        XCTAssertNil(c.message)
        XCTAssertEqual(reconnects(), before + 1, "nach einem Fehler steht „Verbindung wieder da“ im Protokoll")
        await c.refresh()
        XCTAssertEqual(reconnects(), before + 1, "… aber nur nach einem Fehler")
    }

    func testDeviceOffNoticeIsAQuietConnectionState() async throws {
        let c = try await makeConnected()
        fake.refreshError = MideaError.allPathsFailed([
            PathFailure(path: .lan, reason: .unreachable, text: "nicht erreichbar"),
            PathFailure(path: .cloud, reason: .applianceOffline(nextCheck: Date(timeIntervalSince1970: 300)),
                        text: "Anlage ausgeschaltet oder ohne Strom (laut Midea-Cloud) – nächste Prüfung um 00:05"),
        ])
        await c.refresh()
        XCTAssertTrue(c.deviceOffNotice)
        XCTAssertTrue(c.lastRefreshFailed)
        XCTAssertNotNil(c.message)
        fake.refreshError = nil
        await c.refresh()
        XCTAssertFalse(c.deviceOffNotice)
    }

    func testOutdoorSilentRejectedIsANotice() async throws {
        fake.current.power = true
        fake.current.mode = .fan
        fake.acceptSilent = false
        let c = try await makeConnected()
        c.setOutdoorSilent(true)
        try await waitUntil("Hinweis „Außengerät leise“") { c.notice != nil }
        XCTAssertEqual(c.notice?.contains("Außengerät leise"), true)
        XCTAssertNil(c.message)
        XCTAssertFalse(c.lastRefreshFailed)
    }

    func testIECONotAppliedNamesTheMode() async throws {
        fake.current.power = true
        fake.current.mode = .heat
        fake.current.ieco = false
        fake.acceptIECO = false
        let c = try await makeConnected()
        c.setIECO(true)
        try await waitUntil("Hinweis zu iECO") { c.notice != nil }
        XCTAssertEqual(c.notice, "Die Anlage hat „iECO“ im Modus „Heizen“ nicht übernommen. In diesem Modus nimmt die "
                       + "Anlage den Schalter nicht an. Wähle einen anderen Modus und versuche es erneut. (not-in-mode)")
        XCTAssertEqual(c.state?.ieco, false, "zeigt den echten Stand")
        XCTAssertEqual(fake.commands, ["ieco an"])
        XCTAssertNil(c.message)
    }

    func testCapabilitiesAreReadOnceAndGateIECO() async throws {
        fake.current.power = true
        fake.current.mode = .heat
        fake.capabilities = ACCapabilities(raw: [0x00E3: [1]])   // iECO nur beim Kühlen
        let c = try await makeConnected()
        XCTAssertEqual(fake.capabilityReads, 1)
        XCTAssertEqual(c.state?.capabilities?.iecoCool, true)
        XCTAssertFalse(c.availability(.ieco).enabled, "Heizen ohne ieco_heat")
        await c.refresh()
        XCTAssertEqual(fake.capabilityReads, 1, "nur einmal je Anlage")
        var s = try XCTUnwrap(c.state)
        s.mode = .cool
        c.state = s
        XCTAssertTrue(c.availability(.ieco).enabled)
        XCTAssertTrue(fake.commands.isEmpty, "nur gelesen, nichts gestellt")
    }

    func testNoticeDisappearsByItselfOrWithTheNextCommand() async throws {
        let c = try await makeConnected()
        c.noticeSeconds = 0.2
        fake.failUpdates = true
        await c.send { $0.targetTemperature = 24 }
        XCTAssertNotNil(c.notice)
        try await waitUntil("Hinweis verschwindet von selbst") { c.notice == nil }

        c.noticeSeconds = 10
        await c.send { $0.targetTemperature = 24 }
        XCTAssertNotNil(c.notice)
        fake.failUpdates = false
        await c.send { $0.targetTemperature = 23 }
        XCTAssertNil(c.notice, "der nächste Befehl räumt den Hinweis weg")
        XCTAssertNil(c.message)
    }

    func testTimeoutOnCommandWithWorkingRefreshIsANotice() async throws {
        let c = try await makeConnected()
        fake.failUpdates = true
        fake.updateError = MideaError.timeout
        await c.send { $0.targetTemperature = 24 }
        XCTAssertNil(c.message, "die Abfrage danach klappte – kein Verbindungsfehler stehen lassen")
        XCTAssertFalse(c.lastRefreshFailed)
        XCTAssertEqual(c.notice, UserMessage.from(MideaError.timeout).text)
    }

    func testStaleRefreshDoesNotOverwriteNewCommand() async throws {
        let c = try await makeConnected()
        fake.current.targetTemperature = 20
        let gate = AsyncGate()
        fake.refreshGate = gate // die Abfrage liest den alten Stand und hängt, bis das Tor aufgeht
        let refreshesBefore = fake.refreshes
        let refresh = Task { await c.refresh() }
        try await waitUntil("Abfrage läuft") { self.fake.refreshes > refreshesBefore }
        fake.refreshGate = nil
        await c.send { $0.targetTemperature = 26 }
        gate.open()
        await refresh.value
        XCTAssertEqual(c.state?.targetTemperature, 26, "Ergebnis der älteren Abfrage verworfen")
    }

    func testDebounceSendsOnlyLastValue() async throws {
        let c = try await makeConnected()
        let start = c.state?.targetTemperature ?? 0
        c.nudgeTemperature(by: 1)
        c.nudgeTemperature(by: 1)
        c.nudgeTemperature(by: 1)
        try await waitUntil("gesammelter Befehl gesendet") { self.fake.updates >= 1 && c.isIdleForTests }
        XCTAssertEqual(fake.updates, 1)
        XCTAssertEqual(fake.current.targetTemperature, min(30, (start + 3).rounded()))
    }

    func testSoundSettingOnlyAfterSuccess() async throws {
        let c = try await makeConnected()
        fake.failUpdates = true
        c.setSound(false)
        try await waitUntil("abgelehnter Signalton-Befehl") { self.fake.soundCalls.count == 1 && c.isIdleForTests }
        XCTAssertTrue(c.beep, "Anlage hat abgelehnt → Einstellung bleibt")
        fake.failUpdates = false
        c.setSound(false)
        try await waitUntil("Signalton aus übernommen") { !c.beep }
        XCTAssertEqual(settings.values[SettingsKey.beep] as? Bool, false)
    }

    func testRateSnapsToSupportedSteps() async throws {
        let c = try await makeConnected()
        c.setRate(80)
        try await waitUntil("Leistungsgrenze gesendet") { self.fake.current.ratePercent == 75 && c.isIdleForTests }
        XCTAssertEqual(fake.current.ratePercent, 75)
    }

    // MARK: App-Timer

    func testOnTimerInThePastMeansTomorrow() {
        let c = makeController()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        c.setOnTimer(at: now.addingTimeInterval(-3600), now: now)
        XCTAssertEqual(c.onAt, Calendar.current.date(byAdding: .day, value: 1, to: now.addingTimeInterval(-3600)))
        XCTAssertEqual(platform.awake.last, true, "laufender Timer hält den Rechner wach")

        c.setOnTimer(at: nil, now: now)
        XCTAssertNil(c.onAt)
        XCTAssertNil(settings.values[SettingsKey.timerOnAt])
        XCTAssertEqual(platform.awake.last, false)
    }

    func testOffTimerFiresAndClearsOnlyAfterSuccess() async throws {
        let c = try await makeConnected()
        fake.current.power = true
        let now = Date()
        c.setOffTimer(in: 30, now: now.addingTimeInterval(-1800))
        fake.failUpdates = true
        let updatesBefore = fake.updates
        c.checkTimers(now: now)
        try await waitUntil("Timer-Befehl abgelehnt") { self.fake.updates > updatesBefore && c.isIdleForTests }
        XCTAssertNotNil(c.offAt, "Anlage offline → Timer bleibt für den nächsten Versuch")

        fake.failUpdates = false
        c.checkTimers(now: now.addingTimeInterval(10))
        try await waitUntil("Timer ausgeführt") { c.offAt == nil }
        XCTAssertNil(c.offAt)
        XCTAssertFalse(fake.current.power)
    }

    /// Ohne gesetzten Timer läuft keine Timer-Schleife; sie schläft bis zur Fälligkeit, dann alle 10 s.
    func testTimerLoopOnlyRunsWhileATimerIsSet() {
        let c = makeController()
        c.startTimerLoop()
        defer { c.stop() }
        XCTAssertNil(c.timerTask, "kein Timer → keine Schleife")
        let now = Date()
        c.setOffTimer(in: 30, now: now)
        XCTAssertNotNil(c.timerTask)
        XCTAssertEqual(c.nextTimerWait(now: now) ?? 0, ACController.timerMaxSleep, "lange hin → höchstens 5 min")
        XCTAssertEqual(c.nextTimerWait(now: now.addingTimeInterval(30 * 60 - 42)) ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(c.nextTimerWait(now: now.addingTimeInterval(30 * 60 + 1)), ACController.timerRetry,
                       "fällig, aber noch nicht angenommen → Wiederholung")
        c.setOnTimer(at: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(c.nextTimerWait(now: now) ?? 0, 60, accuracy: 0.001, "der frühere Timer zählt")
        c.setOffTimer(in: nil)
        c.setOnTimer(at: nil)
        XCTAssertNil(c.timerTask, "letzter Timer gelöscht → Schleife beendet")
        XCTAssertNil(c.nextTimerWait())
    }

    func testStaleTimerIsDiscardedOnLoad() {
        settings.values[SettingsKey.timerOnAt] = Date().addingTimeInterval(-3 * 86400).timeIntervalSince1970
        settings.values[SettingsKey.timerOffAt] = Date().addingTimeInterval(600).timeIntervalSince1970
        let c = makeController()
        XCTAssertNil(c.onAt, "Tage alter Ein-Timer schaltet beim Start nicht mehr ein")
        XCTAssertNotNil(c.offAt)
        XCTAssertNil(settings.values[SettingsKey.timerOnAt])
    }

    func testTimerWithoutDeviceIsDroppedWithMessage() {
        let c = makeController()
        let now = Date()
        c.setOffTimer(in: 1, now: now.addingTimeInterval(-60))
        c.checkTimers(now: now)
        XCTAssertNil(c.offAt)
        XCTAssertNotNil(c.notice, "nicht ausgeführter Timer ist ein Hinweis, kein Verbindungsfehler")
        XCTAssertNil(c.message)
    }

    // MARK: Tagesverbrauch

    func testDayStartIsOnePerDayAndMigrates() {
        let c = makeController()
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(c.dayStart(for: day1))
        settings.values["dayStart-" + ACController.dayString(day1)] = 11.0
        XCTAssertEqual(c.dayStart(for: day1), 11.0, "Wert aus früherer Fassung übernommen")
        settings.values[SettingsKey.energyDayStart] = "\(ACController.dayString(day1));12.5"
        XCTAssertEqual(c.dayStart(for: day1), 12.5)
        XCTAssertNil(c.dayStart(for: day1.addingTimeInterval(86400)), "neuer Tag → neuer Startwert")
        settings.values[SettingsKey.energyDayStart] = "kaputt"
        XCTAssertEqual(c.dayStart(for: day1), 11.0)
    }

    func testTodayKWhFromCounter() async throws {
        fake.current.totalEnergyKWh = 100
        let c = try await makeConnected()
        XCTAssertEqual(c.todayKWh, 0)
        // Tagesbeginn vor 2 h (sonst wären 1,5 kWh in Sekunden über der größten möglichen Leistung: unplausibel).
        let now = Date()
        settings.values[SettingsKey.energyDayStart] = "\(ACController.dayString(now));100;42;\(Int(now.timeIntervalSince1970) - 7200);0"
        fake.current.totalEnergyKWh = 101.5
        await c.refresh()
        XCTAssertEqual(c.todayKWh ?? 0, 1.5, accuracy: 0.0001)
    }

    // MARK: Szenen

    func testScenesSaveMatchApplyDelete() async throws {
        let c = try await makeConnected()
        let off = ACScene(id: "1", name: "Aus", powerOn: false, mode: 1, tempC: 22, fan: 102, swing: false, eco: false,
                          anion: false, outdoorSilent: false, selfClean: false)
        c.saveCurrentAsScene(named: "  Abend\n ")
        XCTAssertEqual(c.scenes.count, 1)
        XCTAssertEqual(c.scenes[0].name, "Abend")
        XCTAssertTrue(c.isActive(c.scenes[0]), "gerade gespeichert = aktiv")
        XCTAssertEqual(ACScene.load(from: dir.appendingPathComponent("szenen.json")).count, 1)
        XCTAssertEqual(c.isActive(off), !(c.state?.power ?? true))

        c.apply(off)
        try await waitUntil("Szene angewendet") { !self.fake.current.power && c.isIdleForTests }
        XCTAssertFalse(fake.current.power)
        c.deleteScene(c.scenes[0])
        XCTAssertTrue(c.scenes.isEmpty)
        c.saveCurrentAsScene(named: "   ")
        XCTAssertTrue(c.scenes.isEmpty, "leerer Name wird nicht gespeichert")
    }

    func testSceneSanitizing() {
        let bad = ACScene(id: "x", name: "a\u{0}\u{1b}[2Jb", powerOn: true, mode: 99, tempC: 1e300, fan: 5000, swing: false,
                          eco: false, anion: false, outdoorSilent: false, selfClean: false).sanitized
        XCTAssertEqual(bad.tempC, 30)
        XCTAssertEqual(bad.fan, 100)
        XCTAssertEqual(bad.mode, OperationalMode.auto.rawValue)
        XCTAssertFalse(bad.name.unicodeScalars.contains { $0.value < 32 })
        XCTAssertEqual(ACScene(id: "y", name: "", powerOn: true, mode: 1, tempC: .nan, fan: 102, swing: false, eco: false,
                               anion: false, outdoorSilent: false, selfClean: false).sanitized.tempC, 24)
    }

    // MARK: Einrichtung und Backup

    func testIPv4Validation() {
        XCTAssertTrue(DeviceConfig.isIPv4("192.168.1.40"))
        XCTAssertTrue(DeviceConfig.isIPv4("10.0.0.1"))
        for bad in ["192.168.2", "192.168.1.256", "a.b.c.d", "1.2.3.4; rm", "١.٢.٣.٤", "+1.2.3.4", "01.2.3.4", "1..2.3", "-0.1.2.3", ""] {
            XCTAssertFalse(DeviceConfig.isIPv4(bad), bad)
        }
    }

    func testInvalidIPIsRejectedWithoutNetwork() {
        let c = makeController()
        c.setup.scan(ip: "keine-ip")
        XCTAssertFalse(c.setup.scanning)
        XCTAssertNotNil(c.setup.error)
    }

    func testCanConnectNeedsSelectionAndCredentials() {
        let c = makeController()
        XCTAssertFalse(c.setup.canConnect(account: "a@example.com", password: "x"), "ohne gewählte Anlage")
    }

    func testAdoptRejectsInvalidConfig() {
        let c = makeController()
        var cfg = Self.config
        cfg.token = "zz"
        XCTAssertThrowsError(try c.adopt(cfg))
        cfg = Self.config
        cfg.ip = "evil.example.com"
        XCTAssertThrowsError(try c.adopt(cfg))
        XCTAssertNil(c.config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("device.json").path))
    }

    func testBackupRoundTripIsPrivate() async throws {
        let c = try await makeConnected()
        c.saveCurrentAsScene(named: "Nacht")
        let url = dir.appendingPathComponent("backup.json")
        try c.exportBackup(to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let other = makeController()
        _ = try await other.importBackupChecked(from: url)
        XCTAssertEqual(other.config?.token, Self.token)
        XCTAssertEqual(other.scenes.map(\.name), ["Nacht"])
        other.stop()
    }

    func testCloudSyncedPathIsDetected() {
        XCTAssertTrue(ACController.isCloudSynced(URL(fileURLWithPath: "/Users/x/Library/CloudStorage/OneDrive-Personal/b.json")))
        XCTAssertTrue(ACController.isCloudSynced(URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/b.json")))
        XCTAssertFalse(ACController.isCloudSynced(URL(fileURLWithPath: "/Users/x/Documents/b.json")))
    }

    func testForgetDeviceResetsEverythingAndKeepsFileForTrash() async throws {
        let c = try await makeConnected()
        c.setOffTimer(in: 30)
        c.forgetDevice()
        XCTAssertEqual(platform.discarded, [dir.appendingPathComponent("device.json")])
        let left = DeviceConfig.load(from: dir.appendingPathComponent("device.json"))
        XCTAssertEqual(left?.token, Self.token, "device.json geht unverändert in den Papierkorb (rückgängig machbar)")
        XCTAssertEqual(left?.key, Self.key)
        XCTAssertEqual(sessionClears, 1, "Cloud-Sitzung nur über die (hier nachgebildete) Konto-Ablage verworfen")
        XCTAssertNil(c.config)
        XCTAssertNil(c.state)
        XCTAssertNil(c.offAt)
        XCTAssertNil(c.connectionPath)
        XCTAssertTrue(fake.disconnected)
    }

    // MARK: Cloud

    func testCloudLoginStoresAccountAndLogoutResetsMode() async throws {
        let c = try await makeConnected()
        let err = await c.cloudLogin(account: " a@example.com ", password: "geheim")
        XCTAssertNil(err)
        XCTAssertEqual(savedCreds?.account, "a@example.com")
        XCTAssertEqual(c.cloudAccount, "a@example.com")
        c.connectionMode = .cloud
        c.cloudLogout()
        XCTAssertNil(savedCreds)
        XCTAssertNil(c.cloudAccount)
        XCTAssertEqual(c.connectionMode, .auto)
        c.stop()
    }

    func testCloudLoginFailureStoresNothing() async throws {
        let c = try await makeConnected()
        verifyFails = true
        let err = await c.cloudLogin(account: "a@example.com", password: "falsch")
        XCTAssertNotNil(err)
        XCTAssertNil(savedCreds)
        XCTAssertNil(c.cloudAccount)
    }

    func testCloudLoginRaceWithForget() async throws {
        let c = try await makeConnected()
        let gate = AsyncGate()
        verifyGate = gate // die Prüfung hängt, bis die Anmeldung zweimal versucht und die Anlage vergessen ist
        let login = Task { await c.cloudLogin(account: "a@example.com", password: "pw") }
        // Warten, bis die erste Anmeldung wirklich läuft – feste Wartezeiten sind unter Windows zu knapp.
        try await waitUntil("erste Anmeldung läuft") { c.cloudLoginRunning }
        let second = await c.cloudLogin(account: "a@example.com", password: "pw")
        XCTAssertEqual(second, "Anmeldung läuft bereits.")
        c.forgetDevice()
        gate.open()
        let err = await login.value
        XCTAssertNotNil(err, "Einrichtung hat sich geändert")
        XCTAssertNil(savedCreds, "nichts gespeichert")
        XCTAssertNil(c.config, "„Vergessen“ wird nicht rückgängig gemacht")
    }

    // MARK: Verlauf

    func testHistoryCSVAppendThrottles() throws {
        let log = HistoryLog(url: dir.appendingPathComponent("verlauf.csv"))
        var s = ACState()
        s.power = true
        s.targetTemperature = 23
        let now = Date()
        log.append(state: s, diagnostics: Diagnostics(), now: now)
        log.append(state: s, diagnostics: Diagnostics(), now: now.addingTimeInterval(5)) // < 30 s: keine zweite Zeile
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(HistoryLog.header))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testHistoryRotatesOnNewHeader() throws {
        let url = dir.appendingPathComponent("verlauf.csv")
        try "zeit;alt\n2026-01-01T00:00:00Z;1\n".write(to: url, atomically: true, encoding: .utf8)
        HistoryLog(url: url).append(state: ACState(), diagnostics: Diagnostics())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("verlauf-bis-") }, "\(files)")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix(HistoryLog.header))
    }

    private func makeDB() -> HistoryDB { HistoryDB(url: dir.appendingPathComponent("verlauf.sqlite")) }

    /// Zeile wie aus der Abfrage: nur Leistung (und Ein) gesetzt.
    private func insert(_ db: HistoryDB, at t: Date, watts: Double, on: Bool = true) {
        var s = ACState()
        s.power = on
        s.powerWatts = watts
        db.insert(time: t, fields: HistoryLog.fields(state: s, diagnostics: Diagnostics(), time: t))
    }

    func testHistoryCSVImportOnceAndExportRoundTrip() throws {
        let t = HistoryLog.isoString(Date().addingTimeInterval(-600))
        let rows = "\(t);1;Kühlen;23;25.5;31;60;0;0;;640;12.5\n"
            + "\(HistoryLog.isoString(Date().addingTimeInterval(-300)));0;Kühlen;22;21;10.0;102;0;0;;0;12.6\n"
        try (HistoryLog.header + rows).write(to: dir.appendingPathComponent("verlauf.csv"), atomically: true, encoding: .utf8)
        let db = makeDB()
        let files = HistoryLog(url: dir.appendingPathComponent("verlauf.csv")).existingFiles()
        db.importCSVOnce(from: files)
        db.importCSVOnce(from: files) // zweites Mal: nichts doppelt
        let samples = db.samples(since: Date().addingTimeInterval(-3600), maxPoints: 100_000)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].target, 23)
        XCTAssertEqual(samples[0].indoor, 25.5)
        XCTAssertEqual(samples[0].power, 640)
        XCTAssertNil(samples[1].outdoor, "10,0 °C im Aus-Zustand ist ein Platzhalter")
        XCTAssertNil(samples[1].target)

        let out = dir.appendingPathComponent("export.csv")
        try db.exportCSV(to: out)
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(lines[0]) + "\n", HistoryLog.header)
        XCTAssertTrue(lines[1].hasPrefix("\(t);1;Kühlen;23;25.5;31;60;0;0;;640;12.5;"), String(lines[1]))
    }

    func testHistoryStoreAddsAtMostEvery10sAndWindowThinsOut() {
        let store = HistoryStore(db: makeDB(), log: HistoryLog(url: dir.appendingPathComponent("verlauf.csv")),
                                 importExisting: false)
        let now = Date()
        for i in 0..<2000 { insert(store.db, at: now.addingTimeInterval(-Double(i) * 1.8), watts: 100) }
        let w = store.window(3600, now: now)
        XCTAssertLessThanOrEqual(w.count, 602)
        XCTAssertGreaterThan(w.count, 400)
        XCTAssertTrue(zip(w, w.dropFirst()).allSatisfy { $0.time < $1.time }, "sortiert")
        let rev = store.revision
        store.add(ACState(), now: now.addingTimeInterval(1))
        store.add(ACState(), now: now.addingTimeInterval(3))
        XCTAssertEqual(store.revision, rev + 1, "Live-Punkte höchstens alle 10 s")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.log.url.path), "CSV nur auf Wunsch")
    }

    func testHistoryCompactsOldRowsAndStatsUseAllRows() {
        let db = makeDB()
        let now = Date()
        // 2 Tage alle 10 s mit 1.000 W.
        for s in stride(from: 2 * 86400.0, through: 0, by: -10) { insert(db, at: now.addingTimeInterval(-s), watts: 1000) }
        db.compact(before: now.addingTimeInterval(-HistoryDB.denseSpan), from: .distantPast)
        let all = db.samples(since: now.addingTimeInterval(-3 * 86400), maxPoints: 1_000_000)
        let old = all.filter { $0.time < now.addingTimeInterval(-HistoryDB.denseSpan) }
        XCTAssertEqual(Double(old.count), 86400 / 60, accuracy: 2, "ältere Zeilen im Minutenraster")
        XCTAssertEqual(Double(all.count - old.count), 8641, accuracy: 1, "letzte 24 h bleiben im 10-s-Raster")
        // Kennzahlen aus allen Zeilen – auch über die 7-Tage-Ansicht, deren Graphenpunkte weit auseinanderliegen.
        let week = db.stats(since: now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(week.kWh ?? 0, 48, accuracy: 0.1)
        XCTAssertEqual(week.peakWatts, 1000)
        XCTAssertEqual(week.avgWatts, 1000)
        XCTAssertEqual(db.stats(since: now.addingTimeInterval(-3600)).kWh ?? 0, 1, accuracy: 0.01)
    }

    func testHistoryImportMapsColumnsByNameAndSkipsBrokenLines() throws {
        // Ältere Datei: andere Spaltenfolge, weniger Spalten, Windows-Zeilenenden, kaputte Zeilen und Werte.
        let t = Date().addingTimeInterval(-900)
        let text = "zeit;leistung_w;ein;soll_c\r\n"
            + "\(HistoryLog.isoString(t));500;1;22\r\n"
            + "keine Zeit;1;1;1\r\n"
            + "\r\n"
            + "\(HistoryLog.isoString(t.addingTimeInterval(60)));abc;1\r\n"
        try text.write(to: dir.appendingPathComponent("verlauf-bis-2026-01-01.csv"), atomically: true, encoding: .utf8)
        let db = makeDB()
        db.importCSVOnce(from: HistoryLog(url: dir.appendingPathComponent("verlauf.csv")).existingFiles())
        let s = db.samples(since: t.addingTimeInterval(-1), maxPoints: 100_000)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].power, 500)
        XCTAssertEqual(s[0].target, 22)
        XCTAssertTrue(s[0].on)
        XCTAssertNil(s[1].power, "unlesbarer Wert wird NULL, nicht 0")
    }

    func testHistoryDBSurvivesBrokenAndUnopenableFiles() throws {
        let url = dir.appendingPathComponent("verlauf.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        let db = HistoryDB(url: url)
        XCTAssertTrue(db.isOpen, "kaputte Datei beiseitegelegt, neue angelegt")
        insert(db, at: Date(), watts: 100)
        XCTAssertEqual(db.samples(since: Date().addingTimeInterval(-60)).count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("verlauf.sqlite.defekt-") }, "\(files)")

        // Ordner statt Datei: nicht zu öffnen – alle Aufrufe laufen ins Leere, nichts stürzt ab.
        let blocked = dir.appendingPathComponent("ordner.sqlite")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let none = HistoryDB(url: blocked)
        XCTAssertFalse(none.isOpen)
        insert(none, at: Date(), watts: 1)
        none.compactAll()
        none.importCSVOnce(from: [])
        XCTAssertTrue(none.samples(since: .distantPast).isEmpty)
        XCTAssertNil(none.stats(since: .distantPast).kWh)
        XCTAssertThrowsError(try none.exportCSV(to: dir.appendingPathComponent("x.csv")))
    }

    func testHistoryStatsAverageIsTimeWeightedAndCompactionCatchesUp() {
        let db = makeDB()
        let now = Date()
        // 5 Tage alt, alle 10 s: liegt außerhalb der 3 Tage, die das stündliche Ausdünnen ansieht.
        let base = now.addingTimeInterval(-5 * 86400)
        for s in stride(from: 0.0, to: 3600, by: 10) { insert(db, at: base.addingTimeInterval(s), watts: 100) }
        db.compactAll()
        XCTAssertEqual(Double(db.samples(since: base.addingTimeInterval(-1), maxPoints: 1_000_000, now: now).count), 60,
                       accuracy: 1)
        // Danach 1 h lang 10-s-Punkte mit 1.000 W: dichte Zeilen dürfen den Mittelwert nicht verzerren.
        let recent = now.addingTimeInterval(-3600)
        for s in stride(from: 0.0, through: 3600, by: 10) { insert(db, at: recent.addingTimeInterval(s), watts: 1000) }
        let st = db.stats(since: base.addingTimeInterval(-1))
        XCTAssertEqual(st.avgWatts ?? 0, 550, accuracy: 20, "je Stunde gleich viel Gewicht")
        XCTAssertEqual(st.peakWatts, 1000)
    }

    func testBackgroundPollsAtMost30sUntilAWindowIsVisible() async throws {
        let c = try await makeConnected()
        c.refreshSeconds = 5
        XCTAssertTrue(c.background)
        XCTAssertEqual(c.effectiveRefreshSeconds, 30)
        c.setUIVisible("main", true)
        XCTAssertEqual(c.effectiveRefreshSeconds, 5)
        c.setUIVisible("menu", true)
        c.setUIVisible("main", false)
        XCTAssertEqual(c.effectiveRefreshSeconds, 5, "Menüleisten-Fenster zählt als sichtbar")
        c.setUIVisible("menu", false)
        XCTAssertEqual(c.effectiveRefreshSeconds, 30)
        XCTAssertEqual(c.refreshSeconds, 5, "gespeicherte Einstellung bleibt")
        c.refreshSeconds = 120
        XCTAssertEqual(c.effectiveRefreshSeconds, 120)
        c.stop()
    }

    func testNearestSample() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let data = [0.0, 10, 20, 40].map { HistorySample(time: t0.addingTimeInterval($0), power: $0, indoor: nil, outdoor: nil,
                                                          target: nil, on: true) }
        XCTAssertEqual(HistorySample.nearest(in: data, to: t0.addingTimeInterval(-5))?.power, 0)
        XCTAssertEqual(HistorySample.nearest(in: data, to: t0.addingTimeInterval(14))?.power, 10)
        XCTAssertEqual(HistorySample.nearest(in: data, to: t0.addingTimeInterval(31))?.power, 40)
        XCTAssertEqual(HistorySample.nearest(in: data, to: t0.addingTimeInterval(99))?.power, 40)
        XCTAssertNil(HistorySample.nearest(in: [], to: t0))
    }
}
