import Foundation
import Synchronization

/// Schritt beim Verbinden mit der Anlage (für die Schrittzeile der Startanzeige):
/// Anlage suchen (TCP-Verbindung) · Anmelden (Handshake mit Token/Schlüssel) · Werte lesen.
public enum ConnectPhase: Sendable, Equatable {
    case searching, handshake, reading
}

/// Weg zur Anlage. `PortaSplitDevice` ruft ihn nur aus seiner seriellen Queue auf (blockierend).
protocol FrameTransport: AnyObject {
    var quietErrors: Bool { get set }
    /// Sendet einen Geräterahmen; liefert alle Antwortrahmen (mindestens die mit ID `expect`, falls angegeben).
    func send(_ frame: Data, retries: Int, expect: UInt8?) throws -> [Data]
    /// Genau ein Versuch auf dem aktuellen Weg: ohne Wiederholung, ohne Rückfall auf einen anderen Weg und ohne
    /// den Weg zu sperren (für optionale Abfragen und Umschaltbefehle).
    func sendSingle(_ frame: Data, expect: UInt8?) throws -> [Data]
    /// Spätester Zeitpunkt für den laufenden Auftrag; nil = ohne Gesamtlimit.
    func setDeadline(_ deadline: Date?)
    /// Nach einer Pause: WLAN trennt (die Anlage nimmt nur eine Verbindung an).
    func idle()
    func disconnect()
    /// Der letzte Fehler kam, nachdem der Rahmen schon gesendet war (ob er ankam, ist offen).
    var failedAfterWrite: Bool { get }
}

extension FrameTransport {
    func send(_ frame: Data, expect: UInt8? = nil) throws -> [Data] { try send(frame, retries: 2, expect: expect) }
    func send(_ frame: Data, retries: Int) throws -> [Data] { try send(frame, retries: retries, expect: nil) }
    func sendSingle(_ frame: Data, expect: UInt8?) throws -> [Data] { try send(frame, retries: 0, expect: expect) }
    func setDeadline(_ deadline: Date?) {}
    var failedAfterWrite: Bool { false }
}

extension LANClient: FrameTransport {
    func idle() { disconnect() }
    func setDeadline(_ deadline: Date?) { self.deadline = deadline }
}

/// Brücke für die synchronen Wege (`FrameTransport` läuft blockierend auf der seriellen Queue von
/// `PortaSplitDevice`): führt asynchrone Arbeit aus und wartet auf das Ergebnis. Die Arbeit selbst blockiert
/// keinen Thread (URLSession meldet sich per Rückruf); nur der aufrufende Queue-Thread wartet.
/// Nie aus einer Swift-Task heraus aufrufen – dort direkt `await` benutzen (sonst wartet ein Thread des
/// kooperativen Pools auf eine Task desselben Pools).
func awaitBlocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = BlockingResult<T>()
    Task.detached {
        let r: Result<T, any Error>
        do { r = .success(try await body()) } catch { r = .failure(error) }
        box.set(r)
    }
    return try box.wait().get()
}

/// Ergebnisfach für `awaitBlocking` (Semaphore sorgt für Sichtbarkeit; Lock nur der Ordnung halber).
private final class BlockingResult<T>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<T, any Error>?

    func set(_ r: Result<T, any Error>) {
        lock.lock(); result = r; lock.unlock()
        done.signal()
    }

    func wait() -> Result<T, any Error> {
        done.wait()
        lock.lock(); defer { lock.unlock() }
        return result!
    }
}

/// Wie die App die Anlage erreicht. Für alte gespeicherte Werte („ble“, „blePreferred“) liefert
/// `ConnectionMode(rawValue:)` nil; Leser fallen dann auf `.auto` zurück.
public enum ConnectionMode: String, CaseIterable, Sendable {
    case auto, lan, cloud

    /// Protokoll und Datenbank (deutsch); Anzeige über `title` im Kern (`DisplayNames.swift`).
    public var label: String {
        switch self {
        case .auto: return "Automatisch (WLAN zuerst)"
        case .lan: return "Nur WLAN"
        case .cloud: return "Nur Cloud (unterwegs)"
        }
    }

    /// Gespeicherten Wert lesen; Unbekanntes (auch „ble“) wird `.auto`.
    public init(stored: String?) {
        self = stored.flatMap(ConnectionMode.init(rawValue:)) ?? .auto
    }
}

/// Tatsächlich genutzter Weg. `rawValue` ist deutsch für Protokoll und Datenbank; Anzeige über `title` im Kern (`DisplayNames.swift`).
public enum ConnectionPath: String, Sendable {
    case lan = "WLAN", cloud = "Cloud"

    /// Name fürs Protokoll in der Sprache der Oberfläche (`rawValue` bleibt für Datenbank und Vergleiche).
    var logName: String {
        switch self {
        case .lan: LogText.t("log.path.lan", "WLAN")
        case .cloud: LogText.t("log.path.cloud", "Cloud")
        }
    }
}


/// Ein gescheiterter Weg in „Automatisch“: typisierter Grund für die Auswertung, `text` für Fehlerzeile und Protokoll.
public struct PathFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Anlage laut Midea-Cloud aus oder ohne Strom (3123). `nextCheck` („in 5 min“) während des Cloud-Rückzugs.
        case applianceOffline(nextCheck: String?)
        case refused
        case timeout
        case unreachable
        case busy
        /// Cloud-Fehler; `code` ist der Midea-Code (nur bei Antworten der Cloud).
        case cloud(CloudErrorKind, code: Int?)
        case other
    }

    public let path: ConnectionPath
    public let reason: Reason
    public let text: String

    public init(path: ConnectionPath, reason: Reason, text: String) {
        self.path = path
        self.reason = reason
        self.text = text
    }

    static var errorWord: String { LogText.t("kit.generic.error", "Fehler") }

    static var noPathText: String { LogText.t("reason.noPath", "kein Weg zur Anlage verfügbar") }

    public var isApplianceOffline: Bool {
        if case .applianceOffline = reason { return true }
        return false
    }

    /// Midea-Code für die Klammer am Ende der Meldung (drei- bis fünfstellig wie 3004), sonst nil.
    public var code: String? {
        guard case .cloud(_, let code?) = reason, (100...99_999).contains(code) else { return nil }
        return String(code)
    }

    static func offline(nextCheck: String?) -> PathFailure {
        PathFailure(path: .cloud, reason: .applianceOffline(nextCheck: nextCheck),
                    text: nextCheck.map { LogText.t("reason.applianceOff", "Anlage ausgeschaltet oder ohne Strom (laut Midea-Cloud) – nächste Prüfung {next}", ["next": $0]) }
                        ?? LogText.t("reason.applianceOffline", "Anlage offline laut Cloud (3123)"))
    }

    /// Grund und Kurztext eines Fehlers auf Weg `path`.
    static func from(_ error: any Error, path: ConnectionPath) -> PathFailure {
        if let c = error as? MideaCloud.CloudError {
            switch c {
            case .api(3123, _): return offline(nextCheck: nil)
            case .api(let code, _):
                return PathFailure(path: path, reason: .cloud(c.kind, code: code),
                                   text: "\(DeviceConfig.cleanText(c.message, fallback: Self.errorWord)) (\(code))")
            case .network: return PathFailure(path: path, reason: .cloud(.network, code: nil), text: LogText.t("reason.cloud.unreachable", "Cloud nicht erreichbar"))
            case .noToken: return PathFailure(path: path, reason: .cloud(.noToken, code: nil), text: c.errorDescription ?? Self.errorWord)
            default:
                return PathFailure(path: path, reason: .cloud(c.kind, code: nil),
                                   text: "\(DeviceConfig.cleanText(c.message, fallback: Self.errorWord)) (\(c.code))")
            }
        }
        guard let m = error as? MideaError else { return PathFailure(path: path, reason: .other, text: Self.errorWord) }
        switch m {
        case .timeout: return PathFailure(path: path, reason: .timeout, text: LogText.t("reason.timeout", "antwortet nicht"))
        case .unreachable: return PathFailure(path: path, reason: .unreachable, text: LogText.t("reason.unreachable", "nicht erreichbar"))
        case .refused: return PathFailure(path: path, reason: .refused, text: NetSocket.refusedText)
        case .busy: return PathFailure(path: path, reason: .busy, text: m.errorDescription ?? Self.errorWord)
        case .connectionFailed(let s): return PathFailure(path: path, reason: .other, text: s)
        default: return PathFailure(path: path, reason: .other, text: m.errorDescription ?? Self.errorWord)
        }
    }
}

/// Wählt den Weg: Automatisch = WLAN zuerst, bei Verbindungsfehlern die Cloud.
///
/// Sperren und Rückzug (alles nur auf der Geräte-Queue, Uhr über `now` für Tests):
/// - Ein nicht-letzter Weg (WLAN) wird nach einem Fehler `retryInterval` lang übersprungen. Scheitert er beim
///   Nachprüfen erneut, während danach ein späterer Weg (Cloud) antwortet, verdoppelt sich seine Wartezeit bis
///   `maxRetryInterval` – sonst hinge unterwegs jede zweite Abfrage 5 s im WLAN-Verbindungsversuch.
/// - Scheitern alle Wege und der letzte aus einem anderen Grund als „Anlage offline“ (Cloud 3123, also Netz-
///   oder Anmeldefehler), fallen alle Sperren: die nächste Abfrage beginnt wieder mit WLAN. Ohne Internet wäre
///   die Anlage sonst bis zu 60 s nicht steuerbar, obwohl WLAN längst wieder ginge.
/// - Meldet die Cloud 3123, ist die Anlage aus oder stromlos: die Cloud wird `cloudOfflineInterval` lang nicht
///   erneut gefragt (sonst 2.880 Anfragen am Tag an Midea für nichts); die WLAN-Sperre bleibt.
///
/// `@unchecked Sendable`: `mode`/`path` liegen im `Mutex`; alles andere (Sperren, Wege, `now`) benutzt nur die
/// serielle Queue von `PortaSplitDevice`, die das Objekt dafür in ihre Blöcke mitnimmt.
final class AutoTransport: FrameTransport, @unchecked Sendable {
    private let lan: (any FrameTransport)?
    private let cloud: (any FrameTransport)?
    private struct Shared {
        var mode: ConnectionMode
        var path: ConnectionPath?
    }
    private let shared: Mutex<Shared>
    /// Threadsicher lesbar (die App fragt vom Hauptthread, während die Queue evtl. lange auf eine Antwort wartet).
    var mode: ConnectionMode {
        get { shared.withLock { $0.mode } }
        set { shared.withLock { $0.mode = newValue } }
    }
    private(set) var path: ConnectionPath? {
        get { shared.withLock { $0.path } }
        set { shared.withLock { $0.path = newValue } }
    }
    /// Letzter Fehlschlag je Weg (nur auf der Geräte-Queue benutzt).
    private var failedAt: [ConnectionPath: Date] = [:]
    /// Aktuelle Wartezeit je Weg bis zum nächsten Versuch; fehlt der Eintrag, gilt `retryInterval`.
    private var retryIntervals: [ConnectionPath: TimeInterval] = [:]
    /// Wege, deren Ausfall schon im Protokoll steht (eine Zeile je Ausfall, nicht je Abfrage).
    private var reportedDown: Set<ConnectionPath> = []
    /// Bis wann die Cloud nach „Anlage offline“ (3123) nicht erneut gefragt wird.
    private var cloudOfflineUntil: Date?
    private var failedMode: ConnectionMode?
    static let retryInterval: TimeInterval = 60
    static let maxRetryInterval: TimeInterval = 300
    static let cloudOfflineInterval: TimeInterval = 300
    var now: () -> Date = Date.init

    init(lan: (any FrameTransport)?, cloud: (any FrameTransport)? = nil, mode: ConnectionMode) {
        self.lan = lan
        self.cloud = cloud
        self.shared = Mutex(Shared(mode: mode, path: nil))
    }

    var quietErrors: Bool {
        get { lan?.quietErrors ?? cloud?.quietErrors ?? false }
        set { lan?.quietErrors = newValue; cloud?.quietErrors = newValue }
    }

    /// Alle Sperren aufheben (manuelles „Jetzt aktualisieren“): WLAN-Sperre, Cloud-Rückzug, Wartezeiten.
    func resetBackoff() {
        failedAt = [:]
        retryIntervals = [:]
        reportedDown = []
        cloudOfflineUntil = nil
    }

    static var noLANText: String { LogText.t("reason.noLan", "keine WLAN-Zugangsdaten – einmal mit dem Konto einrichten") }
    static var noCloudText: String { LogText.t("reason.noCloud", "Cloud nicht eingerichtet – einmal mit dem Midea-Konto anmelden") }

    func send(_ frame: Data, retries: Int, expect: UInt8?) throws -> [Data] {
        let mode = self.mode
        // Jeder Moduswechsel (auch über „Nur Cloud“ zurück zu „Automatisch“) gibt gesperrte Wege sofort frei.
        if failedMode != mode { resetBackoff(); failedMode = mode }
        switch mode {
        case .lan:
            guard let lan else { throw MideaError.connectionFailed(Self.noLANText) }
            return try use(.lan) { try lan.send(frame, retries: retries, expect: expect) }
        case .cloud:
            guard let cloud else { throw MideaError.connectionFailed(Self.noCloudText) }
            // Auch „Nur Cloud“ fragt eine ausgeschaltete Anlage nicht alle 30 s bei Midea nach.
            if let next = cloudOfflineNextCheck(at: now()) { throw MideaError.allPathsFailed([.offline(nextCheck: next)]) }
            do {
                return try use(.cloud) { try cloud.send(frame, retries: retries, expect: expect) }
            } catch {
                noteCloudOffline(error)
                throw error
            }
        case .auto:
            return try withFallback(frame, retries, expect, [(.lan, lan), (.cloud, cloud)])
        }
    }

    /// Geordnete Kette: bevorzugter Weg zuerst, bei Fehler der nächste verfügbare. Jeder Weg außer dem letzten
    /// wird nach einem Fehler erst nach seiner Wartezeit wieder versucht; nur der letzte Weg wiederholt.
    private func withFallback(_ frame: Data, _ retries: Int, _ expect: UInt8?,
                              _ all: [(ConnectionPath, (any FrameTransport)?)]) throws -> [Data] {
        let avail: [(ConnectionPath, any FrameTransport)] = all.compactMap { p, t in t.map { (p, $0) } }
        guard !avail.isEmpty else { throw MideaError.connectionFailed(PathFailure.noPathText) }
        let current = now()
        var failures: [PathFailure] = []
        /// Wege, die in dieser Abfrage schon zum wiederholten Mal scheiterten (Kandidaten fürs Verdoppeln).
        var repeated: [ConnectionPath] = []
        var lastOffline = false
        for (i, (p, t)) in avail.enumerated() {
            let isLast = i == avail.count - 1
            // Kürzlich ausgefallen und es gibt noch einen späteren Weg: erst gar nicht versuchen.
            if !isLast, let f = failedAt[p], current.timeIntervalSince(f) < interval(p) { continue }
            // Anlage laut Cloud aus: Midea in Ruhe lassen, Grund trotzdem nennen.
            if p == .cloud, let next = cloudOfflineNextCheck(at: current) {
                failures.append(.offline(nextCheck: next))
                lastOffline = true
                continue
            }
            do {
                let frames = try use(p) { try t.send(frame, retries: isLast ? retries : 0, expect: expect) }
                failedAt[p] = nil
                retryIntervals[p] = nil
                reportedDown.remove(p)
                if p == .cloud { cloudOfflineUntil = nil }
                for r in repeated { retryIntervals[r] = min(Self.maxRetryInterval, interval(r) * 2) }
                return frames
            } catch {
                let failure = PathFailure.from(error, path: p)
                failures.append(failure)
                if failedAt[p] != nil { repeated.append(p) }
                failedAt[p] = now()
                if !isLast, reportedDown.insert(p).inserted { AppLog.write(LogText.t("log.transport.pathDown", "{path} nicht erreichbar – nächster Weg", ["path": p.logName])) }
                if isLast { lastOffline = failure.isApplianceOffline }
                noteCloudOffline(error)
                // Ein Stellbefehl, der schon hinausging, wird nicht still über den nächsten Weg wiederholt.
                if !isLast, Self.isControl(frame), t.failedAfterWrite { throw error }
            }
        }
        // Letzter Weg nicht an „Anlage offline“ gescheitert (Netz, Anmeldung, Sonstiges): Sperren aufheben,
        // damit die nächste Abfrage wieder mit WLAN beginnt (siehe Typkommentar).
        // Wartezeiten mit zurücksetzen, sonst dauert die nächste Sperre 300 statt 60 s.
        // Nur der WLAN-Weg wird freigegeben – die Cloud bremst sich selbst (MideaCloudSession mit eigenem Rückzug).
        if !lastOffline { failedAt[.lan] = nil; retryIntervals[.lan] = nil; reportedDown.remove(.lan) }
        // Alle Wege gescheitert: jeden mit Grund nennen, damit sichtbar ist, dass der Rückfall lief.
        throw MideaError.allPathsFailed(failures)
    }

    /// Ein Versuch auf dem Weg, der gerade benutzt wird (bzw. dem ersten nicht gesperrten): kein Rückfall, keine
    /// Sperre, keine Wiederholung. Ein Fehler hier (z. B. optionale Abfrage 0xB1/Gruppe 4 läuft in die
    /// Zeitüberschreitung) schaltet so nicht den ganzen Weg auf die Cloud um.
    func sendSingle(_ frame: Data, expect: UInt8?) throws -> [Data] {
        let mode = self.mode
        if failedMode != mode { resetBackoff(); failedMode = mode }
        let p: ConnectionPath
        switch mode {
        case .lan: p = .lan
        case .cloud: p = .cloud
        case .auto:
            if let current = path { p = current }
            else if lan != nil, failedAt[.lan].map({ now().timeIntervalSince($0) >= interval(.lan) }) ?? true { p = .lan }
            else { p = cloud != nil ? .cloud : .lan }
        }
        guard let t = p == .lan ? lan : cloud else {
            throw MideaError.connectionFailed(p == .lan ? Self.noLANText : Self.noCloudText)
        }
        if p == .cloud, let next = cloudOfflineNextCheck(at: now()) { throw MideaError.allPathsFailed([.offline(nextCheck: next)]) }
        return try use(p) { try t.sendSingle(frame, expect: expect) }
    }

    func setDeadline(_ deadline: Date?) { lan?.setDeadline(deadline); cloud?.setDeadline(deadline) }

    private func interval(_ p: ConnectionPath) -> TimeInterval { retryIntervals[p] ?? Self.retryInterval }

    /// Steuerrahmen (Nachrichtentyp 0x02 an Byte 9), im Unterschied zu Abfragen.
    static func isControl(_ frame: Data) -> Bool {
        frame.count > 9 && frame[frame.startIndex + 9] == FrameType.control.rawValue
    }

    /// Cloud-Fehler 3123 bzw. „Automatisch“ mit einem Weg, auf dem die Cloud die Anlage als aus meldet.
    static func isApplianceOffline(_ error: (any Error)?) -> Bool {
        if case .api(3123, _)? = error as? MideaCloud.CloudError { return true }
        if case .allPathsFailed(let f)? = error as? MideaError { return f.contains(where: \.isApplianceOffline) }
        return false
    }

    /// Nach Cloud-Fehler 3123 den Rückzug starten.
    private func noteCloudOffline(_ error: any Error) {
        if case .api(3123, _)? = error as? MideaCloud.CloudError {
            cloudOfflineUntil = now().addingTimeInterval(Self.cloudOfflineInterval)
        }
    }

    /// Wann die Cloud wieder gefragt wird („in 5 min“), solange der Rückzug läuft; sonst nil.
    private func cloudOfflineNextCheck(at current: Date) -> String? {
        guard let until = cloudOfflineUntil, current < until else { return nil }
        let minutes = Int((until.timeIntervalSince(current) / 60).rounded(.up))
        return until.timeIntervalSince(current) < 60 ? "in weniger als 1 min" : "in \(minutes) min"
    }

    private func use(_ p: ConnectionPath, _ body: () throws -> [Data]) throws -> [Data] {
        let frames = try body()
        if path != p {
            AppLog.write(LogText.t("log.transport.via", "Verbindung über {path}", ["path": p.logName]))
            // Weg gewechselt: WLAN freigeben (die Anlage nimmt nur eine Verbindung an). Die Cloud hält nichts
            // lokal offen.
            if path == .lan { lan?.disconnect() }
        }
        path = p
        return frames
    }

    func idle() { lan?.idle(); cloud?.idle() }

    func disconnect() { lan?.disconnect(); cloud?.disconnect(); path = nil }
}
