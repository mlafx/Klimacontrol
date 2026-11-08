import Foundation
import MideaKit
import Observation

/// Einrichtung einer Anlage, unabhängig von der Oberfläche. Zuerst wählt man den Weg (`path`):
/// - **Midea-Konto:** 1. Konto (E-Mail, Passwort – nur eingegeben, nie hier gespeichert), 2. Anlage finden: im WLAN
///   (Broadcast, gezielt per IP oder Adresse für Adresse im Subnetz) oder in der Cloud, wenn sie im WLAN nicht
///   antwortet (z. B. ausgeschaltet), 3. Token über das Konto holen und übernehmen (Cloud-Fund: nur Cloud-Weg).
/// - **Zugangsdaten:** Adresse, Anlagen-ID, Token und Schlüssel selbst eingeben (`manual`), prüfen, übernehmen – ohne
///   Konto (SetupFlow+Manual.swift).
/// - **Sicherung:** Sicherung einlesen (`ACController.importBackupChecked`).
/// Meldungen folgen dem Muster „Was ist passiert. Was tun. (Code)“ (SetupFlow+Manual.swift, `describe`).
@MainActor
@Observable
public final class SetupFlow {
    /// Funde der Suche. Fehlt die gewählte Anlage danach, wird die Auswahl aufgehoben; ist sie noch da, zeigt
    /// `selected` auf den aktuellen Eintrag (z. B. WLAN statt Cloud).
    public private(set) var discovered: [DiscoveredDevice] = [] { didSet { refreshSelection() } }
    /// Gewählte Anlage für Schritt 3. Bei genau einem Fund wird sie von selbst gewählt.
    public var selected: DiscoveredDevice?
    public private(set) var scanning = false
    public private(set) var cloudScanning = false
    /// Subnetz-Scan läuft; `subnetProgress` = (gesendete, alle Adressen) für die Anzeige „37 von 254“.
    public private(set) var subnetScanning = false
    public private(set) var subnetProgress: (Int, Int)?
    public internal(set) var busy = false
    /// Meldung für die Anzeige; nil = alles gut. Setzt man sie auf nil, verschwindet auch `issue`.
    public var error: String? { didSet { if error == nil { issue = nil } } }
    /// Art der letzten Meldung, damit die Oberfläche passende Knöpfe zeigen kann (z. B. Freigabe „Lokales Netzwerk“).
    public internal(set) var issue: SetupIssue?
    /// Gewählter Weg; nil = Startseite „Wie möchtest du verbinden?“.
    public var path: SetupPath? { didSet { if path != oldValue { error = nil; manualCheckOK = nil; completion = nil } } }
    /// Eingaben des Wegs „Zugangsdaten“ (Oberflächen binden ihre Felder direkt daran).
    public var manual = ManualCredentials() { didSet { if manual != oldValue { manualCheckOK = nil; manualCheckedAt = nil } } }
    /// Ergebnis von „Prüfen“: nil = noch nicht geprüft, seitdem geändert oder die Prüfung kam nicht bis zur Anlage
    /// (belegt, keine Antwort – dann steht der Grund in `error`); false = die Anlage lehnt Token/Schlüssel ab.
    public internal(set) var manualCheckOK: Bool?
    /// Nach gelungener Einrichtung: was die Oberfläche noch anbieten soll (Weg „Nur WLAN“, Sicherung). nil = nichts.
    public internal(set) var completion: SetupCompletion?

    /// Übernimmt die fertige Einrichtung (der Kern).
    @ObservationIgnored weak var sink: (any SetupSink)?
    /// Suche im WLAN (Ziel-IP oder Broadcast) – austauschbar, damit Tests ohne Netz laufen.
    @ObservationIgnored var discover: (String) async throws -> [DiscoveredDevice] = { try await Discovery.scan(target: $0) }
    /// Subnetz-Scan (jede Adresse einzeln) mit Fortschritts-Rückruf – austauschbar wie `discover`.
    @ObservationIgnored var discoverSubnet: (@escaping @Sendable (Int, Int) -> Void) async throws -> [DiscoveredDevice] = {
        try await Discovery.scanSubnet(progress: $0)
    }
    /// Anlagen des Midea-Kontos (Konto, Passwort) – austauschbar wie `discover`.
    @ObservationIgnored var listCloud: (String, String) async throws -> [CloudAppliance] = MideaCloud.listAppliances
    /// Anmeldung an der Anlage (prüft Token und Schlüssel, ändert nichts) – austauschbar wie `discover`.
    @ObservationIgnored var probe: CredentialProbe
    /// Uhr – austauschbar für Tests (Zwischenspeicher der Cloud-Suche, Prüfergebnis).
    @ObservationIgnored var now: () -> Date

    /// Zählt Neustarts (`reset`, neue Suche); späte Ergebnisse einer alten Runde werden verworfen.
    @ObservationIgnored var generation = 0
    @ObservationIgnored private var subnetRun = 0
    /// Ergebnis der letzten Cloud-Suche, damit ein zweiter Klick keine neue Anmeldung bei Midea braucht.
    @ObservationIgnored private var cloudCache: (key: Int, at: Date, list: [CloudAppliance])?
    /// So lange gilt eine Cloud-Liste bzw. ein gelungenes „Prüfen“ (Sekunden).
    static let reuseSeconds: TimeInterval = 120
    @ObservationIgnored var manualCheckedAt: Date?

    init(now: @escaping () -> Date = Date.init, probe: CredentialProbe? = nil) {
        self.now = now
        self.probe = probe ?? .device(CoreDependencies.portaSplit, quiet: true)
    }

    /// Schritt 3 ist möglich, sobald eine Anlage gewählt und Konto + Passwort (Schritt 1) eingegeben sind.
    public func canConnect(account: String, password: String) -> Bool {
        selected != nil && !busy && !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// Alles auf Anfang (z. B. nach „Neu einrichten“ oder nach dem Übernehmen): Funde, Auswahl, Eingaben, Meldungen.
    /// Laufende Suchen liefern danach nichts mehr ab.
    public func reset() {
        generation += 1
        discovered = []
        selected = nil
        manual = ManualCredentials()
        manualCheckOK = nil
        manualCheckedAt = nil
        error = nil
        path = nil
        completion = nil
        cloudCache = nil
        subnetProgress = nil
    }

    /// Hinweis nach der Einrichtung schließen (gesehen bzw. erledigt).
    public func dismissCompletion() { completion = nil }

    /// Den vorgeschlagenen Weg „Nur WLAN“ übernehmen (nur, wenn er vorgeschlagen wurde).
    public func applySuggestedMode() {
        guard let c = completion, c.suggestLANOnly else { return }
        sink?.connectionMode = .lan
        completion = SetupCompletion(path: c.path, suggestLANOnly: false, offerBackup: c.offerBackup, note: c.note)
    }

    func fail(_ text: String, _ kind: SetupIssue) {
        error = text
        issue = kind
    }

    func fail(_ error: any Error, context: SetupFlow.Context = .general) {
        let d = Self.describe(error, context: context)
        fail(d.text, d.issue)
    }

    /// Sucht Anlagen im WLAN (Broadcast) oder gezielt an einer IP.
    public func scan(ip: String? = nil) {
        guard !scanning else { return }
        let target = ip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !target.isEmpty, !DeviceConfig.isIPv4(target) {
            fail(L.Setup.invalidIp(target: target), .invalidInput)
            return
        }
        scanning = true
        error = nil
        let gen = generation
        Task {
            defer { scanning = false }
            do {
                let found = try await discover(target.isEmpty ? "255.255.255.255" : target)
                guard gen == generation else { return }
                mergeLAN(found, nothingFound: Self.nothingFoundText(target: target.isEmpty ? nil : target, asked: nil, path: path))
            } catch {
                guard gen == generation else { return }
                fail(error)
            }
        }
    }

    /// Fragt jede Adresse des eigenen Netzes einzeln – hilft, wenn der Broadcast der WLAN-Suche nicht zugestellt wird.
    public func scanSubnet() {
        guard !subnetScanning else { return }
        subnetScanning = true
        subnetProgress = nil
        error = nil
        subnetRun += 1
        let run = subnetRun, gen = generation
        let total = TotalBox()
        Task {
            defer { if run == subnetRun { subnetScanning = false; subnetProgress = nil } }
            do {
                let found = try await discoverSubnet { sent, all in
                    total.set(all)
                    // Späte Rückrufe (nach dem Ende oder aus einer alten Runde) ändern die Anzeige nicht mehr.
                    Task { @MainActor in
                        guard self.subnetScanning, self.subnetRun == run else { return }
                        self.subnetProgress = (sent, all)
                    }
                }
                guard gen == generation else { return }
                mergeLAN(found, nothingFound: Self.nothingFoundText(target: nil, asked: total.value, path: path))
            } catch {
                guard gen == generation else { return }
                fail(error)
            }
        }
    }

    /// WLAN-Funde übernehmen: nur Klimaanlagen; Cloud-Funde bleiben, außer dieselbe Anlage hat jetzt im WLAN
    /// geantwortet (dann gilt der WLAN-Eintrag); genau ein Fund wird gewählt.
    private func mergeLAN(_ found: [DiscoveredDevice], nothingFound: String) {
        let lan = found.filter { $0.isAirConditioner }
        let lanIds = Set(lan.map(\.deviceId))
        discovered = lan + discovered.filter { $0.isCloudOnly && !lanIds.contains($0.deviceId) }
        if discovered.count == 1 { selected = discovered.first }
        if discovered.isEmpty {
            if found.isEmpty {
                fail(nothingFound, .nothingFound)
            } else {
                fail(L.Setup.NotAirConditioner.lan(names: found.map(\.name).joined(separator: ", ")), .notAirConditioner)
            }
        }
    }

    /// Auswahl an die aktuellen Funde anpassen: gleiche Anlagen-ID → aktueller Eintrag, fehlt sie → keine Auswahl.
    private func refreshSelection() {
        guard let s = selected else { return }
        let current = discovered.first { $0.deviceId == s.deviceId }
        if current != s { selected = current }
    }

    /// Sucht die Anlagen des Midea-Kontos in der Cloud (wie die MSmartHome-App) – findet sie auch, wenn sie
    /// ausgeschaltet ist oder nicht im selben WLAN. WLAN-Funde bleiben bevorzugt. Wählbar sind nur Klimaanlagen
    /// (und Geräte ohne Typangabe). Ein zweiter Klick mit demselben Konto innerhalb von 2 min meldet sich nicht neu an.
    public func scanCloud(account: String, password: String) {
        let acc = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cloudScanning, !acc.isEmpty, !password.isEmpty else { return }
        cloudScanning = true
        error = nil
        let gen = generation
        var hasher = Hasher()
        hasher.combine(acc.lowercased())
        hasher.combine(password)
        let key = hasher.finalize()
        Task {
            defer { cloudScanning = false }
            do {
                let list: [CloudAppliance]
                if let c = cloudCache, c.key == key, now().timeIntervalSince(c.at) < Self.reuseSeconds {
                    list = c.list
                } else {
                    list = try await listCloud(acc, password)
                    cloudCache = (key, now(), list)
                }
                guard gen == generation else { return }
                mergeCloud(list)
            } catch {
                cloudCache = nil
                guard gen == generation else { return }
                fail(error, context: .cloudSearch)
            }
        }
    }

    private func mergeCloud(_ list: [CloudAppliance]) {
        let ac = list.filter { $0.isAirConditioner || $0.type == 0 }
        let lanIds = Set(discovered.filter { !$0.isCloudOnly }.map(\.deviceId))
        let cloud = ac.map(DiscoveredDevice.init(cloud:)).filter { !lanIds.contains($0.deviceId) }
        discovered = discovered.filter { !$0.isCloudOnly } + cloud
        if selected == nil || selected?.isCloudOnly == true, cloud.count == 1, discovered.count == 1 {
            selected = cloud.first
        }
        if ac.isEmpty {
            if list.isEmpty {
                fail(L.Setup.noApplianceInAccount, .cloud)
            } else {
                fail(L.Setup.NotAirConditioner.account(names: list.map(\.name).joined(separator: ", ")), .notAirConditioner)
            }
        }
    }

    /// Token über das Midea-Konto holen, an der Anlage prüfen und übernehmen. Erfolg → true.
    /// Cloud-Fund (Anlage im WLAN nicht erreichbar): nur das Konto prüfen und den Cloud-Weg einrichten.
    public func connect(account: String, password: String) async -> Bool {
        guard let device = selected, let sink, canConnect(account: account, password: password) else { return false }
        busy = true
        error = nil
        completion = nil
        defer { busy = false }
        do {
            let acc = account.trimmingCharacters(in: .whitespacesAndNewlines)
            if device.isCloudOnly {
                try await sink.adoptCloud(device, account: acc, password: password)
                completion = SetupCompletion(path: .account, suggestLANOnly: false, offerBackup: false,
                                             note: Self.completionNote(cloudOnly: true))
            } else {
                try sink.adopt(try await MideaCloud.fetchConfig(for: device, account: acc, password: password))
                completion = SetupCompletion(path: .account, suggestLANOnly: false, offerBackup: false,
                                             note: Self.completionNote(cloudOnly: false))
            }
            return true
        } catch {
            fail(error, context: .account)
            return false
        }
    }
}

/// Was die Einrichtung vom Kern braucht: fertige Einrichtung übernehmen, Verbindungsweg lesen bzw. setzen.
@MainActor
protocol SetupSink: AnyObject {
    var connectionMode: ConnectionMode { get set }
    /// Prüfen, speichern und übernehmen (Midea-Konto mit WLAN-Zugang, Zugangsdaten).
    func adopt(_ cfg: DeviceConfig) throws
    /// Nur über die Cloud einrichten (Anlage im WLAN nicht erreichbar).
    func adoptCloud(_ device: DiscoveredDevice, account: String, password: String) async throws
}

/// Größte gemeldete Gesamtzahl der Subnetzsuche (Rückrufe kommen aus einer Hintergrundqueue).
/// `@unchecked Sendable`: `total` wird nur unter `lock` gelesen und geschrieben.
final class TotalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int?
    func set(_ n: Int) { lock.lock(); total = max(total ?? 0, n); lock.unlock() }
    var value: Int? { lock.lock(); defer { lock.unlock() }; return total }
}
