import Foundation
@testable import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Einrichtung: Fortschritt der Subnetzsuche, veraltete Auswahl, Prüffehler-Arten, weniger Anmeldungen,
/// Abschluss ohne Konto, Meldungstexte. Ohne Netz, ohne Schlüsselbund (Konto-Speicher nachgebildet).
@MainActor
final class SetupTests: CoreTestCase {
    var savedCreds: CloudCredentials?
    var lanFound: [DiscoveredDevice] = []
    var cloudFound: [CloudAppliance] = []
    var cloudScans = 0

    static let lan = DiscoveredDevice(ip: "192.168.1.40", port: 6444, deviceId: 1, sn: "SN1", name: "Wohnzimmer", type: 0xAC, version: 3)
    static let other = DiscoveredDevice(ip: "192.168.1.57", port: 6444, deviceId: 9, sn: "SN9", name: "Luftentfeuchter", type: 0xA1, version: 3)

    override func setUp() async throws {
        try await super.setUp()
        savedCreds = nil
        lanFound = []
        cloudFound = []
        cloudScans = 0
    }

    override func makeAccounts() -> CloudAccountStore {
        CloudAccountStore(
            load: { [unowned self] in savedCreds },
            save: { [unowned self] in savedCreds = $0 },
            clear: { [unowned self] in savedCreds = nil },
            verify: { _, _ in })
    }

    override func makeController() -> ACController {
        let c = super.makeController()
        c.setup.discover = { [unowned self] _ in lanFound }
        c.setup.discoverSubnet = { _ in [] }
        c.setup.listCloud = { [unowned self] _, _ in cloudScans += 1; return cloudFound }
        return c
    }

    func fillManual(_ c: ACController) {
        c.setup.choose(.manual)
        c.setup.manual.ip = "192.168.1.40"
        c.setup.manual.deviceId = "1"
        c.setup.manual.token = Self.token
        c.setup.manual.key = Self.key
    }

    // MARK: Fortschritt der Subnetzsuche

    func testLateSubnetProgressDoesNotStick() async throws {
        let c = makeController()
        let lateProgress = Locked<(@Sendable (Int, Int) -> Void)?>(nil)
        c.setup.discoverSubnet = { progress in
            progress(10, 254)
            lateProgress.set(progress)
            return []
        }
        c.setup.scanSubnet()
        try await scanDone(c.setup)
        // Rückruf nach dem Ende der Suche, von einem anderen Thread (wie aus der Hintergrundqueue).
        let late = try XCTUnwrap(lateProgress.value)
        await withCheckedContinuation { done in
            DispatchQueue.global().async { late(200, 254); done.resume() }
        }
        await drainMainActor()
        XCTAssertNil(c.setup.subnetProgress, "später Rückruf setzt keinen Fortschritt mehr")
        XCTAssertTrue(c.setup.error?.contains("254 Adressen") == true, c.setup.error ?? "")
        XCTAssertEqual(c.setup.issue, .nothingFound)
        XCTAssertTrue(c.setup.issue?.showsNetworkHelp == true)
    }

    // MARK: Auswahl

    func testSelectionFollowsDiscoveredList() async throws {
        let c = makeController()
        lanFound = [Self.lan]
        c.setup.scan()
        try await scanDone(c.setup)
        XCTAssertEqual(c.setup.selected, Self.lan)
        lanFound = []
        c.setup.scan()
        try await scanDone(c.setup)
        XCTAssertTrue(c.setup.discovered.isEmpty)
        XCTAssertNil(c.setup.selected, "Anlage nicht mehr gefunden → keine Auswahl")
        XCTAssertFalse(c.setup.canConnect(account: "a@example.com", password: "pw"))
    }

    func testCloudScanWithoutAirConditionerOffersNothing() async throws {
        let c = makeController()
        cloudFound = [CloudAppliance(deviceId: 5, name: "Entfeuchter", type: 0xA1, online: true)]
        c.setup.scanCloud(account: "a@example.com", password: "pw")
        try await scanDone(c.setup)
        XCTAssertTrue(c.setup.discovered.isEmpty, "Nicht-Klimaanlagen sind nicht wählbar")
        XCTAssertNil(c.setup.selected)
        XCTAssertEqual(c.setup.issue, .notAirConditioner)
        XCTAssertTrue(c.setup.error?.contains("Entfeuchter") == true, c.setup.error ?? "")
    }

    // MARK: Cloud-Liste

    func testRepeatedCloudScanReusesList() async throws {
        let c = makeController()
        cloudFound = [CloudAppliance(deviceId: 2, name: "Schlafzimmer", type: 0xAC, online: true)]
        c.setup.scanCloud(account: "a@example.com", password: "pw")
        try await scanDone(c.setup)
        c.setup.scanCloud(account: " A@example.com ", password: "pw")
        try await scanDone(c.setup)
        XCTAssertEqual(cloudScans, 1, "zweiter Klick ohne neue Anmeldung")
        c.setup.scanCloud(account: "a@example.com", password: "anders")
        try await scanDone(c.setup)
        XCTAssertEqual(cloudScans, 2, "anderes Passwort → neue Anmeldung")
        c.setup.now = { Date().addingTimeInterval(SetupFlow.reuseSeconds + 1) }
        c.setup.scanCloud(account: "a@example.com", password: "anders")
        try await scanDone(c.setup)
        XCTAssertEqual(cloudScans, 3, "nach Ablauf wieder frisch")
    }

    // MARK: Prüffehler-Arten

    func testCheckDistinguishesRejectedBusyAndUnreachable() async {
        let c = makeController()
        fillManual(c)
        var result: (any Error)? = MideaError.busy(.unknown)
        c.setup.probe = CredentialProbe { _ in result }

        let r1 = await c.setup.checkManual()
        XCTAssertFalse(r1)
        XCTAssertNil(c.setup.manualCheckOK, "belegt ist keine Ablehnung")
        XCTAssertEqual(c.setup.issue, .busy)
        XCTAssertFalse(c.setup.error?.contains("nimmt diese Zugangsdaten nicht an") == true)

        result = MideaError.timeout
        let r2 = await c.setup.checkManual()
        XCTAssertFalse(r2)
        XCTAssertNil(c.setup.manualCheckOK)
        XCTAssertEqual(c.setup.issue, .unreachable)

        result = MideaError.refused
        let r3 = await c.setup.checkManual()
        XCTAssertFalse(r3)
        XCTAssertNil(c.setup.manualCheckOK)
        XCTAssertEqual(c.setup.issue, .unreachable, "abgewiesen ohne Beleg für „belegt“: Adresse prüfen")
        XCTAssertTrue(c.setup.error?.contains("weist die Verbindung ab") == true, c.setup.error ?? "")

        result = MideaError.authenticationFailed("x")
        let r4 = await c.setup.checkManual()
        XCTAssertFalse(r4)
        XCTAssertEqual(c.setup.manualCheckOK, false)
        XCTAssertEqual(c.setup.issue, .rejected)

        result = nil
        let r5 = await c.setup.checkManual()
        XCTAssertTrue(r5)
        XCTAssertEqual(c.setup.manualCheckOK, true)
        XCTAssertNil(c.setup.error)
        XCTAssertNil(c.setup.issue)
    }

    // MARK: Verbinden ohne zweite Anmeldung nach „Prüfen“

    func testManualConnectAfterFreshCheckOffersLANOnlyAndBackup() async {
        let c = makeController()
        fillManual(c)
        var handshakes = 0
        c.setup.probe = CredentialProbe { _ in handshakes += 1; return nil }
        let r6 = await c.setup.checkManual()
        XCTAssertTrue(r6)
        let r7 = await c.setup.connectManual()
        XCTAssertTrue(r7)
        XCTAssertEqual(handshakes, 1, "eben geprüft → keine zweite Anmeldung")
        let done = c.setup.completion
        XCTAssertEqual(done?.path, .manual)
        XCTAssertEqual(done?.suggestLANOnly, true)
        XCTAssertEqual(done?.offerBackup, true)
        XCTAssertTrue(done?.note.contains("Nur WLAN") == true)
        XCTAssertNotEqual(c.connectionMode, .lan, "nur vorschlagen, nicht still setzen")
        c.setup.applySuggestedMode()
        XCTAssertEqual(c.connectionMode, .lan)
        XCTAssertEqual(c.setup.completion?.suggestLANOnly, false)
        XCTAssertEqual(c.setup.completion?.offerBackup, true)
        c.setup.dismissCompletion()
        XCTAssertNil(c.setup.completion)
        c.stop()
    }

    func testOldCheckIsRepeatedBeforeConnect() async {
        let c = makeController()
        fillManual(c)
        var handshakes = 0
        c.setup.probe = CredentialProbe { _ in handshakes += 1; return nil }
        let r8 = await c.setup.checkManual()
        XCTAssertTrue(r8)
        c.setup.now = { Date().addingTimeInterval(SetupFlow.reuseSeconds + 1) }
        let r9 = await c.setup.connectManual()
        XCTAssertTrue(r9)
        XCTAssertEqual(handshakes, 2, "altes Prüfergebnis zählt nicht")
        c.stop()
    }

    // MARK: Texte

    func testNothingFoundTextDependsOnPath() async throws {
        let c = makeController()
        c.setup.choose(.manual)
        c.setup.scan()
        try await scanDone(c.setup)
        let text = c.setup.error ?? ""
        XCTAssertEqual(c.setup.issue, .nothingFound)
        XCTAssertFalse(text.contains("Cloud"), "ohne Konto keine Cloud-Suche: \(text)")
        XCTAssertFalse(text.contains("Schritt 1"))
        XCTAssertTrue(text.contains("Gast-WLAN"), text)
        #if os(macOS)
        XCTAssertTrue(text.contains("Lokales Netzwerk"), text)
        #endif

        c.setup.choose(.account)
        c.setup.scan()
        try await scanDone(c.setup)
        XCTAssertTrue(c.setup.error?.contains("Cloud") == true)

        c.setup.scan(ip: "192.168.1.99")
        try await scanDone(c.setup)
        XCTAssertTrue(c.setup.error?.contains("192.168.1.99") == true, c.setup.error ?? "")
    }

    func testFieldProblemsAvoidJargon() {
        var m = ManualCredentials()
        XCTAssertEqual(m.problems["token"], "0 von 128 Zeichen.")
        XCTAssertEqual(m.problems["key"], "0 von 64 Zeichen.")
        m.key = String(repeating: "x", count: 64)
        XCTAssertTrue(m.problems["key"]?.contains("0–9 und a–f") == true)
        for text in m.problems.values { XCTAssertFalse(text.contains("Hex"), text) }
    }

    func testMessagesFollowPatternWithSmallCode() {
        let login = SetupFlow.describe(MideaCloud.CloudError.api(3101, "password error"), context: .account)
        XCTAssertEqual(login.issue, .accountLogin)
        XCTAssertTrue(login.text.hasSuffix("(Code 3101)"), login.text)
        let net = SetupFlow.describe(MideaCloud.CloudError.network("offline"), context: .cloudSearch)
        XCTAssertEqual(net.issue, .network)
        let hex = SetupFlow.describe(ConfigError.invalidHex, context: .manual)
        XCTAssertEqual(hex.issue, .invalidInput)
        XCTAssertFalse(hex.text.contains("Hex"), hex.text)
        for e: any Error in [MideaError.timeout, MideaError.authenticationFailed("x"), MideaError.protocolError("y"), MideaError.busy(.unknown)] {
            let d = SetupFlow.describe(e, context: .manual)
            XCTAssertFalse(d.text.contains("Handshake") || d.text.contains("Protokollfehler"), d.text)
        }
        let rejected = SetupFlow.describe(MideaCloud.CloudError.tokenRejected, context: .account)
        XCTAssertEqual(rejected.issue, .rejected)
        XCTAssertTrue(rejected.text.contains("genau diesem Konto"), rejected.text)
        let paused = SetupFlow.describe(MideaCloud.CloudError.notInAccount, context: .account)
        XCTAssertEqual(paused.issue, .cloud)
        XCTAssertTrue(paused.text.hasSuffix("(Code -1004)"), paused.text)
        let busyPath = MideaError.allPathsFailed([PathFailure(path: .lan, reason: .busy(.otherApp), text: "belegt")])
        XCTAssertEqual(SetupFlow.describe(busyPath, context: .manual).issue, .busy)
        let unreachable = SetupFlow.describe(MideaError.unreachable("Zeitüberschreitung beim Verbinden mit 192.168.1.40"),
                                             context: .manual)
        XCTAssertEqual(unreachable.issue, .unreachable)
        XCTAssertTrue(unreachable.text.contains("Zeitüberschreitung"), unreachable.text)
    }

    // MARK: Zurücksetzen

    func testResetClearsAndDropsLateResults() async throws {
        let c = makeController()
        lanFound = [Self.lan]
        let gate = AsyncGate()
        let oldRoundDone = Locked(false)
        c.setup.discover = { [unowned self] _ in
            await gate.wait()
            oldRoundDone.set(true)
            return lanFound
        }
        fillManual(c)
        c.setup.scan()
        c.setup.reset()
        gate.open() // die Suche der alten Runde liefert erst jetzt, nach dem Zurücksetzen
        try await waitUntil("alte Suche geliefert") { oldRoundDone.value }
        await drainMainActor()
        XCTAssertTrue(c.setup.discovered.isEmpty, "Ergebnis der alten Runde verworfen")
        XCTAssertNil(c.setup.selected)
        XCTAssertNil(c.setup.path)
        XCTAssertEqual(c.setup.manual, ManualCredentials())
        XCTAssertNil(c.setup.error)
    }
}
