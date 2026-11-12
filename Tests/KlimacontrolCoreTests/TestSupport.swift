import Foundation
import MideaKit
import Synchronization
@testable import KlimacontrolCore
import XCTest

// Gemeinsame Hilfen der Kern-Tests: Warten auf Bedingungen, Fakes (Anlage, Einstellungen, Plattform), Torschranke für
// "hängende" Antworten und die Basisklasse `CoreTestCase` mit Temp-Ordner und Controller-Bau.

/// Warten auf eine Bedingung statt fester Pausen (Rechner sind unterschiedlich schnell). Fragt alle 5 ms nach; nach
/// `timeout` schlägt der Test mit `what` fehl, statt zu hängen.
extension XCTestCase {
    @MainActor
    func waitUntil(_ what: String = "Bedingung", timeout: TimeInterval = 5,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return XCTFail("Zeitlimit \(timeout) s: \(what)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lässt bereits eingereihte `@MainActor`-Aufgaben (z. B. späte Rückrufe) laufen, bevor ein "ist unverändert"
    /// geprüft wird. Eine Bedingung gibt es dafür nicht: gewartet wird auf etwas, das nicht passieren soll.
    @MainActor
    func drainMainActor() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }
}

extension ACController {
    /// Kein Befehl unterwegs und nichts gesammelt (Debounce) – Grundlage von `settle`/`waitUntil` in den Tests.
    var isIdleForTests: Bool { !busy && debounce.isEmpty }
}

/// Einstellungen im RAM – die Kern-Tests nutzen sie statt UserDefaults. Echte UserDefaults nur in
/// `testWorksWithRealUserDefaults` (eigene, danach entfernte Suite); Schlüsselbund und echte Dateien nie.
final class MemorySettings: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

@MainActor
final class SpyPlatform: PlatformServices {
    var awake: [Bool] = []
    var discarded: [URL] = []
    func keepAwake(_ on: Bool) { awake.append(on) }
    func discard(_ url: URL) throws { discarded.append(url) }
}

/// Einmal-Torschranke: `wait()` hängt, bis `open()` aufgerufen wurde (danach kehrt es sofort zurück). Ersetzt feste
/// Verzögerungen in nachgebildeten Antworten: der Test bestimmt, wann die Antwort kommt.
final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// Wert, den ein Rückruf auf einem anderen Thread setzt und der Test liest.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func set(_ value: Value) { mutex.withLock { $0 = value } }
    func mutate(_ body: (inout Value) -> Void) { mutex.withLock { body(&$0) } }
}

/// Nachgebildete Anlage: merkt sich Befehle, kann Fehler werfen und Antworten zurückhalten (`refreshGate`).
/// Der Kern ruft sie von anderen Threads als dem Test; aller veränderliche Zustand liegt darum im `Mutex`.
final class FakeDevice: ACDevice, Sendable {
    private struct State {
        var connectionMode: ConnectionMode = .auto
        var connectionPath: ConnectionPath? = .lan
        var beep = true
        var current = ACState()
        var failUpdates = false
        var updateError: (any Error)?
        var updates = 0
        var refreshes = 0
        var refreshGate: AsyncGate?
        var refreshError: (any Error)?
        var soundCalls: [Bool] = []
        var disconnected = false
        var backoffResets = 0
        var lastDiagnosticsFull: Bool?
        var commands: [String] = []
        var acceptSilent = true
        var acceptRate = true
        var acceptIECO = true
        var capabilities: ACCapabilities?
        var capabilityReads = 0
    }
    private let box = Mutex(State())

    private subscript<T: Sendable>(_ path: WritableKeyPath<State, T>) -> T {
        get { box.withLock { $0[keyPath: path] } }
        set { box.withLock { $0[keyPath: path] = newValue } }
    }

    var connectionMode: ConnectionMode { get { self[\.connectionMode] } set { self[\.connectionMode] = newValue } }
    var connectionPath: ConnectionPath? { get { self[\.connectionPath] } set { self[\.connectionPath] = newValue } }
    var beep: Bool { get { self[\.beep] } set { self[\.beep] = newValue } }
    var current: ACState { get { self[\.current] } set { self[\.current] = newValue } }
    var failUpdates: Bool { get { self[\.failUpdates] } set { self[\.failUpdates] = newValue } }
    /// Fehler für abgelehnte Stellbefehle (Standard: „nicht übernommen“).
    var updateError: (any Error)? { get { self[\.updateError] } set { self[\.updateError] = newValue } }
    var updates: Int { get { self[\.updates] } set { self[\.updates] = newValue } }
    var refreshes: Int { get { self[\.refreshes] } set { self[\.refreshes] = newValue } }
    /// Gesetzt: Abfragen lesen ihren Stand, warten dann aber, bis das Tor geöffnet wird (ersetzt eine feste Verzögerung).
    var refreshGate: AsyncGate? { get { self[\.refreshGate] } set { self[\.refreshGate] = newValue } }
    /// Jede Abfrage scheitert mit diesem Fehler (Verbindungstests).
    var refreshError: (any Error)? { get { self[\.refreshError] } set { self[\.refreshError] = newValue } }
    var soundCalls: [Bool] { get { self[\.soundCalls] } set { self[\.soundCalls] = newValue } }
    var disconnected: Bool { get { self[\.disconnected] } set { self[\.disconnected] = newValue } }
    var backoffResets: Int { get { self[\.backoffResets] } set { self[\.backoffResets] = newValue } }
    var lastDiagnosticsFull: Bool? { get { self[\.lastDiagnosticsFull] } set { self[\.lastDiagnosticsFull] = newValue } }
    /// Befehle in Ankunftsreihenfolge („fan 40“, „turbo aus“, „silent an“ …) – für die Lüfter-Zonen-Tests.
    var commands: [String] { get { self[\.commands] } set { self[\.commands] = newValue } }
    /// „Leise außen“ wie die echte Anlage übernehmen (nur beim Kühlen/Heizen).
    var acceptSilent: Bool { get { self[\.acceptSilent] } set { self[\.acceptSilent] = newValue } }
    /// Leistung begrenzen; `acceptRate` = false wie die PortaSplit bei 75 %.
    var acceptRate: Bool { get { self[\.acceptRate] } set { self[\.acceptRate] = newValue } }
    /// iECO übernehmen; false = die Anlage meldet iECO unverändert zurück (z. B. beim Lüften).
    var acceptIECO: Bool { get { self[\.acceptIECO] } set { self[\.acceptIECO] = newValue } }
    /// Gemeldete Fähigkeiten (nil = keine Antwort) und Zahl der Abfragen.
    var capabilities: ACCapabilities? { get { self[\.capabilities] } set { self[\.capabilities] = newValue } }
    var capabilityReads: Int { get { self[\.capabilityReads] } set { self[\.capabilityReads] = newValue } }

    func refresh() async throws -> ACState {
        let (error, snapshot, gate) = box.withLock { s in
            s.refreshes += 1
            return (s.refreshError, s.current, s.refreshGate)
        }
        if let error { throw error }
        if let gate { await gate.wait() }
        return snapshot
    }
    func refreshFast(extras: Bool) async throws -> ACState { try await refresh() }
    func diagnostics(full: Bool) async throws -> Diagnostics {
        self[\.lastDiagnosticsFull] = full
        return Diagnostics()
    }
    func rawGroups(_ groups: [UInt8]) async throws -> [UInt8: Data] { [:] }
    func resetBackoff() { box.withLock { $0.backoffResets += 1 } }
    func identifier() async throws -> String? { "fake" }
    func update(_ change: @escaping @Sendable (inout ACState) -> Void) async throws -> ACState {
        try box.withLock { s in
            s.updates += 1
            if s.failUpdates { throw s.updateError ?? MideaError.commandNotApplied(s.current) }
            let before = s.current
            change(&s.current)
            var parts = ["fan \(s.current.fanSpeed)"]
            if before.turbo != s.current.turbo { parts.append("turbo \(s.current.turbo ? "an" : "aus")") }
            if before.eco != s.current.eco { parts.append("eco \(s.current.eco ? "an" : "aus")") }
            s.commands.append(parts.joined(separator: " "))
            return s.current
        }
    }
    func setOutdoorSilent(_ on: Bool) async throws -> ACState {
        try box.withLock { s in
            s.commands.append("silent \(on ? "an" : "aus")")
            // Wie `PortaSplitDevice`: nicht übernommen → Fehler mit dem echten Stand.
            guard s.acceptSilent else { throw MideaError.commandNotApplied(s.current) }
            s.current.outSilent = on
            return s.current
        }
    }
    func setSelfClean(_ on: Bool) async throws -> ACState { current }
    func setIECO(_ on: Bool) async throws -> ACState {
        try box.withLock { s in
            s.commands.append("ieco \(on ? "an" : "aus")")
            guard s.acceptIECO else { throw MideaError.commandNotApplied(s.current) }
            s.current.ieco = on
            return s.current
        }
    }
    func readCapabilities() async throws -> ACCapabilities? {
        box.withLock { s in
            s.capabilityReads += 1
            // Wie `PortaSplitDevice`: spätere Zustände tragen die Fähigkeiten mit.
            s.current.capabilities = s.capabilities
            return s.capabilities
        }
    }
    func setSound(_ on: Bool) async throws -> ACState {
        try box.withLock { s in
            s.soundCalls.append(on)
            if s.failUpdates { throw MideaError.commandNotApplied(s.current) }
            return s.current
        }
    }
    func setRate(_ percent: Int) async throws -> ACState {
        try box.withLock { s in
            guard s.acceptRate else { throw MideaError.commandNotApplied(s.current) }
            s.current.ratePercent = percent
            return s.current
        }
    }
    func toggleDisplay() async throws -> ACState { current }
    func apply(_ scene: ACScene) async throws -> ACState {
        box.withLock { s in
            s.current.power = scene.powerOn
            s.current.targetTemperature = scene.tempC
            return s.current
        }
    }
    func disconnect() { self[\.disconnected] = true }
}

/// Basis der Controller-Tests: eigener Temp-Ordner, Einstellungen im RAM, Fake-Plattform und Fake-Anlage.
/// Unterklassen ersetzen bei Bedarf `makeAccounts()` (Midea-Konto) und ergänzen `makeController()`.
@MainActor
class CoreTestCase: XCTestCase {
    var dir: URL!
    var settings: MemorySettings!
    var platform: SpyPlatform!
    var fake: FakeDevice!

    static let token = String(repeating: "ab", count: 64)
    static let key = String(repeating: "cd", count: 32)
    static let config = DeviceConfig(name: "Test", ip: "192.168.1.40", port: 6444, deviceId: 42, token: token, key: key)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = MemorySettings()
        platform = SpyPlatform()
        fake = FakeDevice()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Midea-Konto ohne Schlüsselbund. Standard: kein Konto gespeichert, jede Anmeldung gelingt.
    func makeAccounts() -> CloudAccountStore {
        CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
    }

    /// Controller mit Fake-Anlage, ohne Abfrageschleife. Die Prüfung der Zugangsdaten in der Einrichtung meldet einen
    /// Fehler, falls ein Test sie unerwartet auslöst (sonst ginge sie ans echte Netz).
    func makeController() -> ACController {
        let device = fake!
        let c = ACController(appVersion: "test", settings: settings, paths: CorePaths(directory: dir), platform: platform,
                             accounts: makeAccounts(), makeDevice: { _, _, _ in device }, autostart: false)
        c.setup.probe = CredentialProbe { _ in XCTFail("keine echte Anmeldung in Tests"); return MideaError.timeout }
        c.debounceDelay = .milliseconds(50)
        c.zoneGap = 0.2
        return c
    }

    /// Controller mit eingerichteter Anlage; die Abfrageschleife wird angehalten, Zustand einmal gelesen.
    func makeConnected() async throws -> ACController {
        let c = makeController()
        try c.adopt(Self.config)
        c.stop()
        await c.refresh()
        XCTAssertNotNil(c.state)
        return c
    }

    /// Wartet, bis WLAN-, Subnetz- und Cloud-Suche fertig sind (sie laufen in einer Task).
    func scanDone(_ s: SetupFlow) async throws {
        try await waitUntil("Suche fertig", timeout: 2) { !(s.scanning || s.cloudScanning || s.subnetScanning) }
    }
}
