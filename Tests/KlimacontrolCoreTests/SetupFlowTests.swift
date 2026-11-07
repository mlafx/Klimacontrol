import Foundation
@testable import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Einrichtung (SetupFlow) ohne Netz: WLAN-Suche und Cloud-Suche sind nachgebildet.
@MainActor
final class SetupFlowTests: CoreTestCase {
    var savedCreds: CloudCredentials?
    var verified: [(String, UInt64)] = []
    var lanFound: [DiscoveredDevice] = []
    var subnetFound: [DiscoveredDevice] = []
    var cloudFound: [CloudAppliance] = []
    var scans = 0
    var subnetScans = 0
    var cloudScans = 0
    /// Gesetzt: die Subnetzsuche liefert ihr Ergebnis erst, wenn das Tor aufgeht (Fortschritt vorher sichtbar).
    var subnetGate: AsyncGate?

    static let lan = DiscoveredDevice(ip: "192.168.1.40", port: 6444, deviceId: 1, sn: "SN1", name: "Wohnzimmer", type: 0xAC, version: 3)
    static let other = DiscoveredDevice(ip: "192.168.1.57", port: 6444, deviceId: 9, sn: "SN9", name: "Luftentfeuchter", type: 0xA1, version: 3)
    static let cloud1 = CloudAppliance(deviceId: 1, name: "Wohnzimmer", type: 0xAC, online: true)
    static let cloud2 = CloudAppliance(deviceId: 2, name: "Schlafzimmer", type: 0xAC, online: false)

    override func setUp() async throws {
        try await super.setUp()
        savedCreds = nil
        verified = []
        lanFound = []
        subnetFound = []
        cloudFound = []
        scans = 0
        subnetScans = 0
        cloudScans = 0
        subnetGate = nil
    }

    override func makeAccounts() -> CloudAccountStore {
        CloudAccountStore(
            load: { [unowned self] in savedCreds },
            save: { [unowned self] in savedCreds = $0 },
            clear: { [unowned self] in savedCreds = nil },
            verify: { [unowned self] creds, cfg in verified.append((creds.account, cfg.deviceId)) })
    }

    override func makeController() -> ACController {
        let c = super.makeController()
        c.setup.discover = { [unowned self] _ in scans += 1; return lanFound }
        c.setup.discoverSubnet = { [unowned self] progress in
            subnetScans += 1
            progress(32, 254)
            progress(254, 254)
            if let subnetGate { await subnetGate.wait() }
            return subnetFound
        }
        c.setup.listCloud = { [unowned self] _, _ in cloudScans += 1; return cloudFound }
        return c
    }

    func testSubnetScanMergesLikeLANScan() async throws {
        let c = makeController()
        subnetFound = [Self.other, Self.lan]
        let gate = AsyncGate()
        subnetGate = gate
        c.setup.scanSubnet()
        XCTAssertTrue(c.setup.subnetScanning)
        c.setup.scanSubnet() // läuft schon – kein zweiter Start
        // Fortschritt kommt über den Rückruf an, bevor das Ergebnis da ist (das Tor hält das Ergebnis zurück).
        try await waitUntil("Fortschritt 254 von 254") { c.setup.subnetProgress?.0 == 254 }
        XCTAssertEqual(c.setup.subnetProgress?.1, 254)
        gate.open()
        try await scanDone(c.setup)
        XCTAssertEqual(subnetScans, 1)
        XCTAssertEqual(scans, 0, "kein Broadcast nebenbei")
        XCTAssertNil(c.setup.subnetProgress, "nach dem Lauf kein Fortschritt mehr")
        XCTAssertEqual(c.setup.discovered, [Self.lan], "nur Klimaanlagen")
        XCTAssertEqual(c.setup.selected, Self.lan, "genau ein Fund wird gewählt")
        XCTAssertNil(c.setup.error)

        // Cloud-Fund einer anderen Anlage bleibt stehen, derselbe wird durch den WLAN-Eintrag ersetzt.
        cloudFound = [Self.cloud1, Self.cloud2]
        c.setup.scanCloud(account: "a@example.com", password: "pw")
        try await scanDone(c.setup)
        XCTAssertEqual(c.setup.discovered.map(\.deviceId), [1, 2])
        subnetFound = [Self.lan]
        c.setup.scanSubnet()
        try await scanDone(c.setup)
        XCTAssertEqual(c.setup.discovered.map(\.deviceId), [1, 2])
        XCTAssertFalse(c.setup.discovered[0].isCloudOnly)
        XCTAssertTrue(c.setup.discovered[1].isCloudOnly)

        // Nichts gefunden: Hinweis nennt die Zahl der Adressen und die Cloud-Suche (Schritt 1).
        subnetFound = []
        let d = makeController()
        d.setup.scanSubnet()
        try await scanDone(d.setup)
        XCTAssertTrue(d.setup.error?.contains("254 Adressen") == true, d.setup.error ?? "")
        XCTAssertTrue(d.setup.error?.contains("Schritt 1") == true)
        XCTAssertFalse(d.setup.error?.contains("Schritt 2") == true, "Konto ist jetzt Schritt 1")

        // Fehler der Suche landet in `error`.
        d.setup.discoverSubnet = { _ in throw MideaError.connectionFailed("Kein aktives Netz gefunden") }
        d.setup.scanSubnet()
        try await scanDone(d.setup)
        XCTAssertTrue(d.setup.error?.contains("Kein aktives Netz") == true, d.setup.error ?? "")
        XCTAssertTrue(d.setup.discovered.isEmpty)
    }

    func testScanFiltersAirConditionersAndSelectsSingleHit() async throws {
        let c = makeController()
        lanFound = [Self.other, Self.lan]
        c.setup.scan()
        try await scanDone(c.setup)
        XCTAssertEqual(c.setup.discovered, [Self.lan], "nur Klimaanlagen")
        XCTAssertEqual(c.setup.selected, Self.lan, "genau ein Fund wird gewählt")
        XCTAssertNil(c.setup.error)
        XCTAssertEqual(scans, 1)

        lanFound = [Self.other]
        c.setup.scan()
        try await scanDone(c.setup)
        XCTAssertTrue(c.setup.discovered.isEmpty)
        XCTAssertTrue(c.setup.error?.contains("keine Klimaanlage") == true, c.setup.error ?? "")
        XCTAssertTrue(c.setup.error?.contains("Luftentfeuchter") == true)

        lanFound = []
        c.setup.scan()
        try await scanDone(c.setup)
        XCTAssertTrue(c.setup.error?.contains("Cloud") == true, "leeres Ergebnis nennt die Cloud-Suche: \(c.setup.error ?? "")")
    }

    func testCloudScanAppendsAndKeepsLANPreferred() async throws {
        let c = makeController()
        lanFound = [Self.lan]
        c.setup.scan()
        try await scanDone(c.setup)
        cloudFound = [Self.cloud1, Self.cloud2]
        c.setup.scanCloud(account: " a@example.com ", password: "pw")
        try await scanDone(c.setup)
        XCTAssertEqual(cloudScans, 1)
        XCTAssertEqual(c.setup.discovered.map(\.deviceId), [1, 2])
        XCTAssertEqual(c.setup.discovered[0], Self.lan, "gleiche deviceId → der WLAN-Eintrag bleibt")
        XCTAssertTrue(c.setup.discovered[1].isCloudOnly)
        XCTAssertEqual(c.setup.discovered[1].cloudOnline, false)
        XCTAssertEqual(c.setup.selected, Self.lan, "Auswahl bleibt beim WLAN-Fund")

        // Ohne Konto/Passwort läuft keine Cloud-Suche.
        c.setup.scanCloud(account: "", password: "pw")
        c.setup.scanCloud(account: "a@example.com", password: "")
        try await scanDone(c.setup)
        XCTAssertEqual(cloudScans, 1)
    }

    func testLANScanReplacesSelectedCloudHit() async throws {
        let c = makeController()
        cloudFound = [Self.cloud1]
        c.setup.scanCloud(account: "a@example.com", password: "pw")
        try await scanDone(c.setup)
        XCTAssertEqual(c.setup.discovered.count, 1)
        XCTAssertTrue(c.setup.selected?.isCloudOnly == true, "einziger Cloud-Fund wird gewählt")

        lanFound = [Self.lan]
        c.setup.scan()
        try await scanDone(c.setup)
        XCTAssertEqual(c.setup.discovered, [Self.lan], "WLAN-Eintrag ersetzt den Cloud-Fund derselben Anlage")
        XCTAssertEqual(c.setup.selected, Self.lan)
        XCTAssertFalse(c.setup.selected?.isCloudOnly ?? true)
    }

    func testConnectWithCloudHitAdoptsCloudOnlyConfig() async throws {
        let c = makeController()
        c.connectionMode = .lan
        cloudFound = [Self.cloud2]
        c.setup.scanCloud(account: "a@example.com", password: "pw")
        try await scanDone(c.setup)
        XCTAssertTrue(c.setup.canConnect(account: "a@example.com", password: "pw"))
        let ok = await c.setup.connect(account: " a@example.com ", password: "pw")
        XCTAssertTrue(ok, c.setup.error ?? "")
        XCTAssertEqual(verified.map(\.0), ["a@example.com"], "Konto geprüft (Anlage muss im Konto sein)")
        XCTAssertEqual(verified.first?.1, 2)
        XCTAssertEqual(savedCreds?.account, "a@example.com")
        XCTAssertEqual(c.cloudAccount, "a@example.com")
        XCTAssertEqual(c.connectionMode, .auto, "„Nur WLAN“ wird „Automatisch“, sonst käme die Cloud nie dran")
        let cfg = DeviceConfig.load(from: dir.appendingPathComponent("device.json"))
        XCTAssertEqual(cfg?.ip, "")
        XCTAssertEqual(cfg?.deviceId, 2)
        XCTAssertEqual(cfg?.name, "Schlafzimmer")
        XCTAssertEqual(cfg?.hasLAN, false)
        XCTAssertEqual(c.config, cfg)
        XCTAssertFalse(c.setup.busy)
        c.stop()
    }

    func testInvalidIPFailsWithoutNetwork() async throws {
        let c = makeController()
        c.setup.scan(ip: "192.168.2")
        XCTAssertFalse(c.setup.scanning)
        XCTAssertTrue(c.setup.error?.contains("keine IP-Adresse") == true, c.setup.error ?? "")
        await drainMainActor()
        XCTAssertEqual(scans, 0, "kein Netzaufruf")
    }

    // MARK: Weg „Zugangsdaten“ (ohne Midea-Konto)


    func testManualCredentialsAreValidatedPerField() {
        var m = ManualCredentials()
        XCTAssertFalse(m.isComplete)
        XCTAssertEqual(m.problems["token"], "0 von 128 Zeichen.")
        m.ip = "192.168.1.40"; m.deviceId = "111122223333555"
        m.token = String(Self.token.dropLast()); m.key = Self.key
        XCTAssertEqual(m.problems.keys.sorted(), ["token"])
        // Leerzeichen und Zeilenumbrüche (beim Einfügen) zählen nicht mit.
        m.token = String(Self.token.prefix(64)) + "\n " + String(Self.token.suffix(64))
        XCTAssertTrue(m.isComplete)
        m.port = "0"
        XCTAssertNotNil(m.problems["port"])
    }

    func testPasteRecognizesBackupJSONAndFreeText() {
        let c = makeController()
        let json = #"{"devices":[{"deviceId":111122223333555,"discoveredName":"net_ac_1A2B","ip":"192.168.1.40","key":"\#(Self.key)","port":6444,"token":"\#(Self.token)","version":3}]}"#
        XCTAssertEqual(c.setup.pasteCredentials(json), "Adresse, Port, Anlagen-ID, Token, Schlüssel")
        XCTAssertTrue(c.setup.manual.isComplete)
        XCTAssertEqual(c.setup.manual.name, "net_ac_1A2B")

        c.setup.manual = ManualCredentials()
        XCTAssertEqual(c.setup.pasteCredentials("token: \(Self.token)\nkey: \(Self.key)"), "Token, Schlüssel")
        XCTAssertTrue(c.setup.manual.tokenValid && c.setup.manual.keyValid)
        XCTAssertNil(c.setup.pasteCredentials("nichts Brauchbares"))
        XCTAssertNotNil(c.setup.error)
    }

    func testSearchHitPrefillsManualFields() {
        let c = makeController()
        c.setup.useForManual(Self.lan)
        XCTAssertEqual(c.setup.manual.ip, "192.168.1.40")
        XCTAssertEqual(c.setup.manual.port, "6444")
        XCTAssertEqual(c.setup.manual.deviceId, "1")
        XCTAssertEqual(c.setup.manual.name, "Wohnzimmer")
    }

    func testManualCheckAndConnectWithoutAccount() async throws {
        let c = makeController()
        var handshakes = 0
        var accept = false
        c.setup.probe = CredentialProbe { _ in handshakes += 1; return accept ? nil : MideaError.authenticationFailed("abgelehnt") }
        c.setup.choose(.manual)
        c.setup.manual.ip = "192.168.1.40"
        c.setup.manual.deviceId = "1"
        c.setup.manual.token = Self.token
        c.setup.manual.key = Self.key

        let first = await c.setup.checkManual()
        XCTAssertFalse(first)
        XCTAssertEqual(c.setup.manualCheckOK, false)
        XCTAssertNotNil(c.setup.error)
        XCTAssertNil(c.config, "abgelehnte Zugangsdaten werden nicht gespeichert")

        accept = true
        let second = await c.setup.checkManual()
        XCTAssertTrue(second)
        XCTAssertEqual(c.setup.manualCheckOK, true)
        c.setup.manual.key = String(Self.key.reversed())
        XCTAssertNil(c.setup.manualCheckOK, "geänderte Eingabe = ungeprüft")

        let connected = await c.setup.connectManual()
        XCTAssertTrue(connected)
        XCTAssertEqual(c.config?.ip, "192.168.1.40")
        XCTAssertEqual(c.config?.deviceId, 1)
        XCTAssertEqual(c.config?.token, Self.token)
        XCTAssertTrue(c.config?.hasLAN == true)
        XCTAssertNil(savedCreds, "kein Midea-Konto gespeichert")
        XCTAssertTrue(verified.isEmpty, "keine Cloud-Anmeldung")
        XCTAssertEqual(handshakes, 3)
        XCTAssertNotNil(DeviceConfig.load(from: dir.appendingPathComponent("device.json")))
    }

    func testManualConnectWithIncompleteInputFailsWithoutHandshake() async {
        let c = makeController()
        var handshakes = 0
        c.setup.probe = CredentialProbe { _ in handshakes += 1; return nil }
        c.setup.manual.ip = "192.168.1.40"
        let connected = await c.setup.connectManual()
        XCTAssertFalse(connected)
        XCTAssertEqual(c.setup.error, "Anlagen-ID als Zahl (steht nach der Suche schon da).")
        XCTAssertEqual(handshakes, 0)
        XCTAssertNil(c.config)
    }

    func testChoosingAPathResetsErrorAndCheck() {
        let c = makeController()
        c.setup.error = "alt"
        c.setup.choose(.manual)
        XCTAssertEqual(c.setup.path, .manual)
        XCTAssertNil(c.setup.error)
        c.setup.choose(nil)
        XCTAssertNil(c.setup.path)
    }
}
