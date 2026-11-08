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
            relocateDone(L.Message.Relocate.missingData)
            return false
        }
        guard !relocating else { return false }
        relocating = true
        defer { relocating = false }
        relocation.lastRun = now()
        let startConfig = configGeneration
        AppLog.write(L.Log.Relocate.searching(id: String(cfg.deviceId)))
        let found: (ip: String, port: UInt16)?
        do { found = try await locate(cfg.deviceId) } catch {
            AppLog.error(L.Log.Relocate.searchFailed(error: error.localizedDescription))
            found = nil
        }
        guard configGeneration == startConfig, config == cfg else { return false }
        guard let found else {
            relocateDone(L.Message.Relocate.notFound)
            return false
        }
        if found.ip == cfg.ip {
            AppLog.write(L.Log.Relocate.unchanged(ip: cfg.ip))
            await refreshNow()
            relocateDone(lastRefreshFailed
                ? L.Message.Relocate.sameNoReply(ip: cfg.ip)
                : L.Message.Relocate.sameOk(ip: cfg.ip), notice: lastRefreshFailed)
            return !lastRefreshFailed
        }
        var candidate = cfg
        candidate.ip = found.ip
        if found.port != 0 { candidate.port = found.port }
        guard let checked = try? candidate.validated() else { return false }
        let check = await checkExclusively(checked)
        if let error = check.error {
            AppLog.error(L.Log.Relocate.loginFailed(ip: found.ip, error: error.localizedDescription))
            if check.isRejected {
                relocateDone(L.Message.Relocate.rejected(ip: found.ip))
            } else {
                relocateDone(UserMessage(what: L.Message.Relocate.LoginFailed.what(ip: found.ip),
                                       todo: L.Message.Relocate.LoginFailed.todo,
                                       code: UserMessage.from(error).code).text)
            }
            return false
        }
        guard configGeneration == startConfig, config == cfg else { return false }
        do { try checked.save(to: paths.config) } catch {
            AppLog.error(L.Log.Relocate.notSaved(error: error.localizedDescription))
            relocateDone(L.Message.Relocate.saveFailed)
            return false
        }
        AppLog.write(L.Log.Relocate.moved(ip: checked.ip, old: cfg.ip))
        use(checked)
        relocateDone(L.Message.Relocate.moved(ip: checked.ip))
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
