#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Synchronization

/// Zustand der Cloud-Sitzung eines Kontos (für Oberfläche/Diagnose).
public struct CloudSessionStatus: Sendable, Equatable {
    /// Angemeldet bzw. Sitzung wiederhergestellt.
    public var active: Bool
    /// Zugang, über den gerade gesprochen wird.
    public var kind: CloudKind?
    /// Gestoppt, bis der Nutzer handelt (Text nach „Was ist passiert. Was tun.“); nil = nicht gestoppt.
    public var stoppedReason: String?
    /// Neuanmeldung frühestens dann wieder (Rückzug); nil = sofort möglich.
    public var pausedUntil: Date?
    /// Anmeldungen seit Programmstart (Diagnose, Tests).
    public var logins: Int
}

/// Eine Cloud-Sitzung je Konto: hält die angemeldete Sitzung, zählt Fehler und zieht sich zurück.
///
/// Regeln:
/// - Gespeicherte Sitzung (Schlüsselbund) zuerst; ist der Schlüsselbund gesperrt, **keine** Neuanmeldung.
/// - Nach einem Sitzungsfehler (abgelaufen, Schlüssel passt nicht) oder nach 2 unklaren Antworten in Folge wird die
///   Sitzung verworfen und **höchstens einmal je Vorgang** neu angemeldet. Netzfehler (kein Internet, HTTP 5xx,
///   Zeitbudget) sagen nichts über die Sitzung und behalten sie.
/// - Gleichzeitige Vorgänge teilen sich eine laufende Anmeldung.
/// - Jede Anmeldung eines Zugangs sperrt dessen nächste Anmeldung für die Rückzugszeit (60 s, nach Fehlschlag
///   verdoppelt bis 30 min). In der Rückzugszeit gibt es keine Netzanfrage, nur einen schnellen Fehler.
/// - Falsches Passwort (3101/3102) bzw. Anlage nicht im Konto stoppt den Zugang, bis der Nutzer handelt
///   (`userActed()`, neue Zugangsdaten, „Cloud-Konto entfernen“). So entsteht keine Anmeldeschleife, die das Konto sperrt.
/// - „Anlage offline“ (3123) ist eine gültige Antwort: Sitzung bleibt, kein Fehlerzähler.
public actor MideaCloudSession {
    public static let backoffStart: TimeInterval = 60
    public static let backoffMax: TimeInterval = 30 * 60
    /// Gespeicherte Sitzungen, die älter sind, werden nicht mehr benutzt (Ablauf).
    public static let sessionMaxAge: TimeInterval = 30 * 24 * 3600
    /// Eine frische Anmeldung gilt so lange als Passwortprüfung (Einrichtung: Liste → Prüfung ohne zweite Anmeldung).
    static let verifiedWindow: TimeInterval = 5 * 60
    /// Zeitbudget für einen Befehl über die Cloud (inkl. Anmeldung), passend zum WLAN-Budget.
    public static let commandBudget: TimeInterval = 12

    public nonisolated let account: String
    nonisolated let password: String
    private let makeAPI: @Sendable (CloudKind) -> any MideaCloudAPI
    private let now: @Sendable () -> Date

    private struct KindState {
        var nextLoginAt = Date.distantPast
        var backoff = MideaCloudSession.backoffStart
        var stopped: MideaCloud.CloudError?
    }

    private var api: (any MideaCloudAPI)?
    private var restored = false
    private var freshLoginAt: Date?
    private var failures = 0
    private var kinds: [CloudKind: KindState] = [:]
    /// Anlagen-ID je (Zugang, Geräte-ID).
    private var applianceIds: [String: String] = [:]
    private var logins = 0
    /// Automatische Anmeldungen (ohne festen Zugang) frühestens dann – auch der Wechsel auf den anderen Zugang
    /// umgeht den Rückzug nicht (Neuanmeldung höchstens einmal je Rückzugszeit).
    private var autoLoginAt = Date.distantPast
    /// Laufende Anmeldung; weitere Vorgänge warten darauf, statt sich selbst anzumelden.
    private var pendingLogin: (id: UUID, task: Task<any MideaCloudAPI, any Error>)?

    init(account: String, password: String, now: @escaping @Sendable () -> Date = { Date() },
         makeAPI: (@Sendable (CloudKind) -> any MideaCloudAPI)? = nil) {
        let acc = account.trimmingCharacters(in: .whitespacesAndNewlines)
        self.account = acc
        self.password = password
        self.now = now
        self.makeAPI = makeAPI ?? { makeCloudAPI($0, account: acc, password: password) }
    }

    // MARK: Gemeinsame Sitzungen (eine je Konto und Passwort)

    private static let registry = Mutex<[String: MideaCloudSession]>([:])

    /// Die Sitzung dieses Kontos. Ein anderes Passwort ergibt eine neue Sitzung (Nutzer hat gehandelt).
    public static func shared(account: String, password: String) -> MideaCloudSession {
        let key = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return registry.withLock { registry in
            if let s = registry[key], s.password == password { return s }
            let s = MideaCloudSession(account: account, password: password)
            registry[key] = s
            return s
        }
    }

    /// Sitzung eines Kontos im Speicher vergessen (neue Zugangsdaten gespeichert).
    public static func forget(account: String) {
        let key = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        registry.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Alle Sitzungen im Speicher vergessen („Cloud-Konto entfernen“).
    public static func forgetAll() {
        registry.withLock { $0.removeAll() }
    }

    // MARK: Zustand

    public var status: CloudSessionStatus {
        let t = now()
        let stopped = CloudKind.allCases.compactMap { kinds[$0]?.stopped }
        let allStopped = stopped.count == CloudKind.allCases.count
        let paused = CloudKind.allCases.compactMap { k -> Date? in
            guard let s = kinds[k], s.stopped == nil, s.nextLoginAt > t else { return nil }
            return s.nextLoginAt
        }.min()
        return CloudSessionStatus(active: api != nil, kind: api?.kind,
                                  stoppedReason: allStopped ? stopped.first?.errorDescription : nil,
                                  pausedUntil: api == nil ? paused : nil, logins: logins)
    }

    /// Der Nutzer hat gehandelt (Einrichtung, „Erneut versuchen“, neue Zugangsdaten): Stopp und Rückzug aufheben.
    public func userActed() {
        kinds = [:]
        failures = 0
        autoLoginAt = .distantPast
    }

    // MARK: Öffentliche Vorgänge

    /// Prüft Konto und Anlage (Einrichtung). Eine Anmeldung der letzten 5 min mit diesem Passwort zählt als Prüfung;
    /// sonst wird wirklich angemeldet (eine gespeicherte Sitzung beweist das Passwort nicht).
    public func verify(deviceId: UInt64, allowSingleFallback: Bool) async throws {
        userActed()
        if let at = freshLoginAt, now().timeIntervalSince(at) < Self.verifiedWindow, api != nil {
            _ = try await run(deviceId: deviceId, needsControl: false) { api in
                try await self.resolveAppliance(api: api, deviceId: deviceId, allowSingleFallback: allowSingleFallback)
            }
            return
        }
        discard(clearStore: false)
        _ = try await run(deviceId: deviceId, needsControl: false, forceLogin: true) { api in
            try await self.resolveAppliance(api: api, deviceId: deviceId, allowSingleFallback: allowSingleFallback)
        }
    }

    /// Einen Geräterahmen über die Cloud senden (mit festem Zeitbudget).
    public func send(_ frame: Data, deviceId: UInt64, allowSingleFallback: Bool = false) async throws -> [Data] {
        try await run(deviceId: deviceId, needsControl: true) { api in
            let id = try await self.resolveAppliance(api: api, deviceId: deviceId, allowSingleFallback: allowSingleFallback)
            return try await api.transparentSend(frame, deviceId: deviceId, applianceId: id)
        }
    }

    /// Anlagen des Kontos über einen bestimmten Zugang.
    public func appliances(kind: CloudKind) async throws -> [CloudAppliance] {
        try await run(deviceId: nil, kind: kind, needsControl: false) { api in
            try await api.listAppliancesRaw().compactMap(MideaCloud.parseAppliance)
        }
    }

    /// Token und Schlüssel für die udpid über einen bestimmten Zugang.
    func token(kind: CloudKind, udpid: String, applianceId: UInt64) async throws -> (String, String)? {
        let pair: [String]? = try await run(deviceId: nil, kind: kind, needsControl: false) { api in
            try await api.token(udpid: udpid, applianceId: applianceId).map { [$0.0, $0.1] }
        }
        return pair.map { ($0[0], $0[1]) }
    }

    // MARK: Kern

    private func run<T: Sendable>(deviceId: UInt64?, kind: CloudKind? = nil, needsControl: Bool, forceLogin: Bool = false,
                                  _ op: (any MideaCloudAPI) async throws -> T) async throws -> T {
        var (current, loggedIn) = try await ensure(deviceId: deviceId, kind: kind, needsControl: needsControl,
                                                   forceLogin: forceLogin)
        do {
            let r = try await op(current)
            failures = 0
            return r
        } catch {
            guard try handleFailure(error, loggedInNow: loggedIn) else { throw error }
        }
        if let newer = api, newer !== current, kind == nil || newer.kind == kind, !needsControl || newer.canControl {
            // Ein anderer Vorgang hat inzwischen neu angemeldet: dessen Sitzung benutzen, nicht verwerfen.
            current = newer
            loggedIn = true
        } else {
            AppLog.write("Cloud-Sitzung ungültig – melde einmal neu an (\(AppLog.mask(account)))")
            discard(clearStore: true)
            (current, loggedIn) = try await ensure(deviceId: deviceId, kind: kind, needsControl: needsControl, forceLogin: true)
        }
        do {
            let r = try await op(current)
            failures = 0
            return r
        } catch {
            _ = try handleFailure(error, loggedInNow: true)
            throw error
        }
    }

    /// Wertet einen Fehler aus. true = Sitzung verwerfen und einmal neu anmelden; false = Fehler weiterreichen.
    private func handleFailure(_ error: any Error, loggedInNow: Bool) throws -> Bool {
        // Abbruch (Zeitbudget, Task beendet) und Netzfehler sagen nichts über die Sitzung.
        guard let c = error as? MideaCloud.CloudError else { return false }
        switch c.kind {
        case .network:
            return false
        case .applianceOffline:
            failures = 0
            return false
        case .wrongCredentials, .notInAccount, .accountLocked:
            if let k = api?.kind { stop(k, c) }
            discard(clearStore: c.kind == .wrongCredentials)
            return false
        case .sessionExpired:
            failures += 1
            return !loggedInNow
        case .paused, .keychainLocked:
            return false
        default:
            failures += 1
            return !loggedInNow && failures >= 2
        }
    }

    /// Sitzung bereitstellen: im Speicher, sonst aus dem Schlüsselbund, sonst anmelden (mit Rückzug).
    private func ensure(deviceId: UInt64?, kind: CloudKind?, needsControl: Bool,
                        forceLogin: Bool) async throws -> (any MideaCloudAPI, Bool) {
        if !forceLogin, let api, kind == nil || api.kind == kind, !needsControl || api.canControl {
            return (api, false)
        }
        // Läuft schon eine Anmeldung, deren Ergebnis abwarten; passt es, zählt es auch für diesen Vorgang. Hat
        // inzwischen ein anderer Wartender die nächste gestartet, auch auf diese warten statt selbst anzumelden.
        var waited: Set<UUID> = []
        while let pending = pendingLogin, waited.insert(pending.id).inserted {
            _ = try? await pending.task.value
            if let api, freshLoginAt != nil, kind == nil || api.kind == kind, !needsControl || api.canControl {
                return (api, true)
            }
        }
        if !forceLogin, api == nil, let r = try restoreFromStore(deviceId: deviceId, kind: kind, needsControl: needsControl) {
            return (r, false)
        }
        let id = UUID()
        let task = Task { try await self.login(deviceId: deviceId, kind: kind, needsControl: needsControl) }
        pendingLogin = (id, task)
        defer { if pendingLogin?.id == id { pendingLogin = nil } }
        return (try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }, true)
    }

    private func restoreFromStore(deviceId: UInt64?, kind: CloudKind?, needsControl: Bool) throws -> (any MideaCloudAPI)? {
        let saved: CloudSession?
        do { saved = try CloudSessionStore.lookup(account: account, deviceId: deviceId) } catch {
            AppLog.error("Cloud: Schlüsselbund nicht lesbar – keine Neuanmeldung (\(error.localizedDescription))")
            throw MideaCloud.CloudError.keychainLocked
        }
        guard let s = saved, let k = s.kind, kind == nil || kind == k, kinds[k]?.stopped == nil else { return nil }
        guard now().timeIntervalSince(s.savedAt) < Self.sessionMaxAge else {
            AppLog.write("Cloud-Sitzung abgelaufen (älter als 30 Tage) – wird nicht mehr benutzt")
            return nil
        }
        let candidate = makeAPI(k)
        guard candidate.restore(s), !needsControl || candidate.canControl else { return nil }
        api = candidate
        restored = true
        if let deviceId = s.deviceId, !s.applianceId.isEmpty { applianceIds[cacheKey(k, deviceId)] = s.applianceId }
        AppLog.write("Cloud-Sitzung wiederverwendet (\(k.rawValue)) – keine neue Anmeldung")
        return candidate
    }

    private func login(deviceId: UInt64?, kind: CloudKind?, needsControl: Bool) async throws -> any MideaCloudAPI {
        let order = kind.map { [$0] } ?? CloudKind.allCases
        var lastError: (any Error)?
        var pausedUntil: Date?
        if kind == nil {
            let t = now()
            if t < autoLoginAt { throw MideaCloud.CloudError.paused(until: autoLoginAt) }
            autoLoginAt = t.addingTimeInterval(Self.backoffStart)
        }
        for k in order {
            var st = kinds[k] ?? KindState()
            if let stopped = st.stopped { lastError = lastError ?? stopped; continue }
            let t = now()
            if t < st.nextLoginAt { pausedUntil = min(pausedUntil ?? st.nextLoginAt, st.nextLoginAt); continue }
            let candidate = makeAPI(k)
            logins += 1
            do {
                try await candidate.login()
                st.backoff = Self.backoffStart
                st.nextLoginAt = now().addingTimeInterval(st.backoff)
                kinds[k] = st
                if needsControl, !candidate.canControl {
                    lastError = MideaCloud.CloudError.sessionKeys("Sitzungsschlüssel fehlen")
                    continue
                }
                api = candidate
                restored = false
                freshLoginAt = now()
                failures = 0
                persist(candidate, deviceId: deviceId)
                AppLog.write("Cloud-Anmeldung (\(k.rawValue)) erfolgreich für \(AppLog.mask(account))")
                return candidate
            } catch {
                st.nextLoginAt = now().addingTimeInterval(st.backoff)
                if Task.isCancelled || error is CancellationError {
                    // Abbruch durch das Zeitbudget ist kein Anmeldefehler: Rückzug nicht verdoppeln, anderen Zugang
                    // nicht mehr versuchen.
                    kinds[k] = st
                    throw error
                }
                st.backoff = min(Self.backoffMax, st.backoff * 2)
                kinds[k] = st
                if let c = error as? MideaCloud.CloudError, [.wrongCredentials, .accountLocked].contains(c.kind) {
                    stop(k, c)
                }
                AppLog.write("Cloud \(k.rawValue): \(error.localizedDescription)")
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw MideaCloud.CloudError.paused(until: pausedUntil ?? now())
    }

    private func stop(_ k: CloudKind, _ error: MideaCloud.CloudError) {
        var st = kinds[k] ?? KindState()
        guard st.stopped == nil else { return }
        st.stopped = error
        kinds[k] = st
        AppLog.error("Cloud \(k.rawValue) gestoppt bis zur nächsten Anmeldung in den Einstellungen: \(error.localizedDescription)")
    }

    private func discard(clearStore: Bool) {
        api = nil
        restored = false
        freshLoginAt = nil
        if clearStore { CloudSessionStore.clear() }
    }

    private func persist(_ api: any MideaCloudAPI, deviceId: UInt64?) {
        let id = deviceId.flatMap { applianceIds[cacheKey(api.kind, $0)] } ?? ""
        guard var s = api.makeSession(account: account, applianceId: id) else { return }
        s.deviceId = id.isEmpty ? nil : deviceId
        s.savedAt = now()
        CloudSessionStore.save(s)
    }

    private func cacheKey(_ k: CloudKind, _ deviceId: UInt64) -> String { "\(k.rawValue)|\(deviceId)" }

    /// Anlagen-ID im Konto (einmal je Zugang/Anlage, danach aus dem Speicher bzw. der gespeicherten Sitzung).
    private func resolveAppliance(api: any MideaCloudAPI, deviceId: UInt64, allowSingleFallback: Bool) async throws -> String {
        let key = cacheKey(api.kind, deviceId)
        if let id = applianceIds[key] { return id }
        let id = try CloudControlClient.pickAppliance(try await api.listAppliancesRaw(), deviceId: deviceId,
                                                      allowSingleFallback: allowSingleFallback)
        applianceIds[key] = id
        persist(api, deviceId: deviceId)
        return id
    }

    static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// Wartet höchstens `seconds` auf `body`; danach Abbruch (Netzanfragen werden mit abgebrochen).
func withTimeBudget<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MideaCloud.CloudError.network("keine Antwort innerhalb von \(Int(seconds)) s")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

/// Steuerung über die Midea-Cloud. Damit ist die Anlage auch von unterwegs erreichbar – langsam und über
/// Mideas Server, daher nur als letzter Weg. Dünne Hülle um die gemeinsame `MideaCloudSession` des Kontos.
public final class CloudControlClient: Sendable {
    public let account: String
    private let deviceId: UInt64
    private let allowSingleFallback: Bool
    let session: MideaCloudSession

    static let appKey = NetHomePlusClient.appKey

    /// `allowSingleFallback`: die einzige Klimaanlage im Konto auch bei anderer Geräte-ID nehmen (nur Einrichtung).
    public init(account: String, password: String, deviceId: UInt64, allowSingleFallback: Bool = false) {
        self.account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceId = deviceId
        self.allowSingleFallback = allowSingleFallback
        self.session = MideaCloudSession.shared(account: account, password: password)
    }

    /// Alte Signatur; `serialSuffix` wird nicht benutzt.
    public convenience init(account: String, password: String, deviceId: UInt64, serialSuffix: String) {
        self.init(account: account, password: password, deviceId: deviceId)
    }

    /// Prüft Konto und Anlage (Einrichtung, Einstellungen); wartet ohne einen Thread zu blockieren.
    public func verifyLogin() async throws {
        try await session.verify(deviceId: deviceId, allowSingleFallback: allowSingleFallback || deviceId == 0)
    }

    public func status() async -> CloudSessionStatus { await session.status }

    /// Blockierend für den CloudTransport (ruft aus der AutoTransport-Queue, nie vom Hauptthread).
    func sendBlocking(_ frame: Data) throws -> [Data] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let session = self.session, deviceId = self.deviceId, fallback = allowSingleFallback
        return try awaitBlocking {
            try await withTimeBudget(MideaCloudSession.commandBudget) {
                try await session.send(frame, deviceId: deviceId, allowSingleFallback: fallback)
            }
        }
    }

    /// Deutet der Fehler auf eine abgelaufene/ungültige Sitzung hin (dann lohnt eine Neuanmeldung)?
    /// Betriebsfehler wie „Anlage offline“ (3123) gehören ausdrücklich nicht dazu.
    static func isSessionError(_ e: MideaCloud.CloudError) -> Bool {
        switch e {
        case .sessionKeys, .incompleteLogin: return true
        case .api(let code, let msg):
            if [3004, 3106, 40002, 44005].contains(code) { return true }
            let m = msg.lowercased()
            return m.contains("token") || m.contains("session") || m.contains("sign")
                || m.contains("not login") || m.contains("unauthorized")
        default: return false
        }
    }

    // MARK: - Gemeinsame Hilfen (auch von den Cloud-Clients und Tests genutzt)

    /// data_key = AES-ECB-Entschlüsselung des Access-Token mit key = md5(appKey) als Hex, erste 16 Zeichen. (NetHome Plus)
    static func deriveDataKey(accessTokenHex: String, appKey: String) throws -> Data {
        let md5hex = MideaCrypto.md5(Data(appKey.utf8)).hex
        let key = Data(md5hex.prefix(16).utf8)
        guard let token = Data(hex: accessTokenHex) else {
            throw MideaCloud.CloudError.sessionKeys("Zugangsschlüssel unlesbar")
        }
        return try MideaCrypto.decryptECB(key: key, token)
    }

    static func encryptString(_ s: String, dataKey: Data) throws -> String {
        try MideaCrypto.encryptECB(key: dataKey, Data(s.utf8)).hex
    }

    static func decryptString(_ hex: String, dataKey: Data) throws -> String {
        guard let d = Data(hex: hex) else {
            throw MideaCloud.CloudError.badReply("Antwort der Anlage unlesbar")
        }
        return String(decoding: try MideaCrypto.decryptECB(key: dataKey, d), as: UTF8.self)
    }

    /// Rahmen ↔ CSV aus signed Bytes (wie midea_beautiful _encode_as_csv / _decode_from_csv).
    static func csv(_ data: Data) -> String {
        data.map { String(Int(Int8(bitPattern: $0))) }.joined(separator: ",")
    }

    /// nil, wenn ein Eintrag keine Zahl von -128 bis 255 ist (nie still 0).
    static func fromCSV(_ s: String) -> Data? {
        var out = Data()
        for part in s.split(separator: ",") {
            guard let v = Int(part.trimmingCharacters(in: .whitespacesAndNewlines)), (-128...255).contains(v) else { return nil }
            out.append(UInt8(truncatingIfNeeded: v))
        }
        return out
    }

    /// Anlage aus der Kontoliste wählen: gleiche Geräte-ID. Die einzige Anlage im Konto nur, wenn das
    /// ausdrücklich erlaubt ist (Einrichtung) oder die Geräte-ID fehlt (0) – und nur, wenn sie eine Klimaanlage ist.
    static func pickAppliance(_ listAny: Any?, deviceId: UInt64, allowSingleFallback: Bool = false) throws -> String {
        let list = listAny as? [[String: Any]] ?? []
        for item in list where MideaCloud.applianceId(of: item) == "\(deviceId)" {
            AppLog.write("Cloud: Anlage gefunden (id \(deviceId))")
            return "\(deviceId)"
        }
        if allowSingleFallback || deviceId == 0, list.count == 1, let only = list.first,
           let id = MideaCloud.applianceId(of: only), MideaCloud.parseType("\(only["type"] ?? "")") == 0xAC {
            AppLog.write("Cloud: einzige Klimaanlage im Konto verwendet (id \(id))")
            return id
        }
        throw MideaCloud.CloudError.notInAccount
    }
}

/// V2-Paket für den Cloud-Versand: wie lokal, aber der Geräterahmen bleibt im Klartext
/// (die Cloud-Schicht verschlüsselt alles). Antwort = Paket ohne 40-Byte-Kopf.
enum CloudPacket {
    static func encode(deviceId: UInt64, frame: Data, date: Date = Date()) -> Data {
        var header = Data([0x5A, 0x5A, 0x01, 0x11, 0x00, 0x00, 0x20, 0x00])
        header.append(Data(count: 4))
        header.append(V2Packet.timestamp(date))
        withUnsafeBytes(of: deviceId.littleEndian) { header.append(contentsOf: $0) }
        header.append(Data(count: 12))
        var packet = header + frame
        let length = packet.count + 16
        packet[4] = UInt8(length & 0xFF)
        packet[5] = UInt8(length >> 8 & 0xFF)
        return packet + MideaCrypto.sign(packet)
    }

    /// Antwort: 40-Byte-Kopf abschneiden, der innere Geräterahmen bleibt übrig (0xAA … per Längenbyte lesbar).
    static func decode(_ data: Data) -> Data? {
        guard data.count >= 56 else { return nil }
        let inner = Data(data[40...])
        guard inner.first == 0xAA, inner.count > Int(inner[1]) else { return nil }
        return inner.prefix(Int(inner[1]) + 1)
    }
}

/// Cloud als FrameTransport (blockierend; AutoTransport ruft aus seiner Queue). Wiederholung, Neuanmeldung und
/// Rückzug regelt allein `MideaCloudSession` – hier wird nicht wiederholt (ein Befehl wie „Display umschalten“
/// darf nicht doppelt ankommen), und die Sitzung bleibt bei Fehlern erhalten.
final class CloudTransport: FrameTransport {
    /// Wird vom Hauptthread gesetzt und auf der Geräte-Queue gelesen – darum im `Mutex`.
    var quietErrors: Bool {
        get { quiet.withLock { $0 } }
        set { quiet.withLock { $0 = newValue } }
    }
    private let quiet = Mutex(false)
    private let client: CloudControlClient

    init(client: CloudControlClient) { self.client = client }

    /// Fehler werden hier nicht protokolliert: der Grund wandert in die Zusammenfassung von `AutoTransport`.
    func send(_ frame: Data, retries: Int, expect: UInt8?) throws -> [Data] {
        try client.sendBlocking(frame)
    }

    func idle() {} // Cloud-Sitzung bleibt angemeldet
    func disconnect() {} // die Sitzung gehört dem Konto, nicht dieser Verbindung
}
