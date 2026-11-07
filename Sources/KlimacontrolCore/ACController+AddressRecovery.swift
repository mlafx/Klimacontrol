import Foundation
import MideaKit

/// Automatische Adresssuche: zählt WLAN-Ausfälle in Folge (Fehler oder Rückfall auf die Cloud trotz WLAN-Einrichtung)
/// und gibt die Suche nach `failuresNeeded` frei – höchstens alle `interval`.
struct RelocationTrigger {
    static let failuresNeeded = 3
    static let interval: TimeInterval = 10 * 60

    /// Nur in der laufenden App (Tests suchen nicht von selbst).
    let enabled: Bool
    private(set) var failures = 0
    /// Letzter Start von „Adresse neu suchen“ (von Hand oder automatisch).
    var lastRun = Date.distantPast

    init(enabled: Bool) { self.enabled = enabled }

    mutating func reset() { failures = 0 }

    /// Ergebnis einer Abfrage bzw. eines Befehls; true = jetzt die Adresse suchen.
    mutating func note(lanDown: Bool, searching: Bool, now: Date) -> Bool {
        guard lanDown else { failures = 0; return false }
        failures += 1
        guard enabled, failures >= Self.failuresNeeded, !searching,
              now.timeIntervalSince(lastRun) >= Self.interval else { return false }
        failures = 0
        return true
    }
}

/// „Adresse neu suchen“ (Router-/IP-Wechsel), von Hand oder nach wiederholten WLAN-Fehlern.
extension ACController {
    /// Sucht die eingerichtete Anlage über ihre Anlagen-ID im WLAN (Broadcast, dann Subnetz). Hat sie eine neue
    /// Adresse, meldet sich der Kern dort mit dem gespeicherten Token an; erst wenn das gelingt, wird die neue
    /// Adresse gespeichert und genutzt. Token und Schlüssel bleiben. Rückgabe true = Anlage gefunden und erreichbar
    /// (auch unter der alten Adresse). Fehler stehen danach als Hinweis in `notice`.
    @discardableResult
    public func relocate() async -> Bool {
        guard let cfg = config, cfg.deviceId != 0, !cfg.token.isEmpty, !cfg.key.isEmpty else {
            relocateDone("Für die Suche fehlen die ID der Anlage oder die Zugangsdaten. Richte die Anlage über die Suche "
                         + "im WLAN ein.")
            return false
        }
        guard !relocating else { return false }
        relocating = true
        defer { relocating = false }
        relocation.lastRun = now()
        let startConfig = configGeneration
        AppLog.write("Suche die Anlage (id \(cfg.deviceId)) im WLAN …")
        let found: (ip: String, port: UInt16)?
        do { found = try await locate(cfg.deviceId) } catch {
            AppLog.error("Suche nach der Anlage fehlgeschlagen: \(error.localizedDescription)")
            found = nil
        }
        guard configGeneration == startConfig, config == cfg else { return false }
        guard let found else {
            relocateDone("Die Anlage wurde im WLAN nicht gefunden. Prüfe, ob sie Strom hat und mit dem WLAN verbunden ist. "
                         + "Die Zugangsdaten bleiben unverändert.")
            return false
        }
        if found.ip == cfg.ip {
            AppLog.write("Anlage weiter unter \(cfg.ip)")
            await refreshNow()
            relocateDone(lastRefreshFailed
                ? "Die Anlage ist weiter unter \(cfg.ip), antwortet aber gerade nicht. Versuche es in einer Minute erneut."
                : "Die Anlage ist weiter unter \(cfg.ip) erreichbar.", notice: lastRefreshFailed)
            return !lastRefreshFailed
        }
        var candidate = cfg
        candidate.ip = found.ip
        if found.port != 0 { candidate.port = found.port }
        guard let checked = try? candidate.validated() else { return false }
        let check = await checkExclusively(checked)
        if let error = check.error {
            AppLog.error("Anlage unter \(found.ip) gefunden, Anmeldung gescheitert: \(error.localizedDescription)")
            if check.isRejected {
                relocateDone("Unter der neuen Adresse \(found.ip) antwortet ein Gerät, es nimmt die gespeicherten Zugangsdaten "
                             + "aber nicht an. Lies eine Sicherung ein oder richte die Anlage neu ein.")
            } else {
                relocateDone(UserMessage(what: "Die Anlage ist unter der neuen Adresse \(found.ip), die Anmeldung dort "
                                       + "klappte gerade nicht.",
                                       todo: "Versuche es in einer Minute erneut (Einstellungen › Anlage › Adresse neu suchen).",
                                       code: UserMessage.from(error).code).text)
            }
            return false
        }
        guard configGeneration == startConfig, config == cfg else { return false }
        do { try checked.save(to: paths.config) } catch {
            AppLog.error("Neue Adresse nicht gespeichert: \(error.localizedDescription)")
            relocateDone("Die neue Adresse der Anlage konnte nicht gespeichert werden. Details stehen im Protokoll.")
            return false
        }
        AppLog.write("Anlage jetzt unter \(checked.ip) (vorher \(cfg.ip))")
        use(checked)
        relocateDone("Die Anlage hat eine neue Adresse (\(checked.ip)) und ist wieder verbunden.")
        return true
    }

    /// Ergebnis von „Adresse neu suchen“: Text für die Rückmeldung am Ort der Aktion (beide Oberflächen) und
    /// – bei Fehlern oder einer neuen Adresse – als Hinweis.
    func relocateDone(_ text: String, notice: Bool = true) {
        relocateMessage = text
        if notice { showNotice(text) }
    }

    /// Nach jeder Abfrage bzw. jedem Befehl: WLAN-Ausfall mitzählen und ggf. die Adresssuche starten. Zählt nur bei
    /// WLAN-Einrichtung und ohne „Nur Cloud“; „Anlage aus“ ist kein WLAN-Ausfall.
    func noteLANResult(failed: Bool = false) {
        guard let cfg = config, cfg.hasLAN, connectionMode != .cloud else { relocation.reset(); return }
        let lanDown = (failed || connectionPath == .cloud) && !deviceOffNotice
        guard relocation.note(lanDown: lanDown, searching: relocating, now: now()) else { return }
        Task { await relocate() }
    }
}
