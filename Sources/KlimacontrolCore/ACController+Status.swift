import Foundation
import MideaKit

/// Verbindungszustand, Verbindungsfehler (`message`), Hinweise (`notice`) und Startanzeige (Verbindungsschritte).
extension ACController {
    /// Die angezeigten Werte sind nicht live (Verbindungsfehler oder „Anlage aus“): Zeitpunkt der letzten
    /// gelungenen Abfrage. nil = Werte aktuell bzw. noch keine Werte.
    public var staleSince: Date? {
        guard state != nil, lastRefreshFailed || deviceOffNotice else { return nil }
        return lastUpdate
    }

    /// Verbindungszustand für Statuspunkt, Statuszeile und Startanzeige – typisiert statt am Meldungstext.
    public var connectionState: ConnectionState {
        if config == nil { return .notConfigured }
        if connectPhase != nil { return .connecting }
        if deviceOffNotice { return .deviceOff }
        if lastRefreshFailed { return .noConnection }
        return state == nil ? .connecting : .live
    }

    /// Verbindungs-/Zeitüberschreitungs-/Anmelde-/Cloud-Fehler – alles andere (nicht übernommen, Protokoll) ist ein Hinweis.
    static func isConnectionError(_ error: any Error) -> Bool {
        if let e = error as? MideaError {
            switch e {
            case .connectionFailed, .refused, .unreachable, .allPathsFailed, .outcomeUnknown, .timeout, .authenticationFailed,
                 .busy:
                return true
            case .crypto, .protocolError, .invalidResponse, .commandNotApplied:
                return false
            }
        }
        return error is MideaCloud.CloudError
    }

    /// Ausführliches Protokoll für diese Sitzung ein- oder ausschalten und das Umschalten selbst protokollieren.
    public func setDetailedLog(_ on: Bool) {
        guard on != detailedLog || on != AppLog.debugEnabled else { return }
        AppLog.debugEnabled = on
        detailedLog = on
        AppLog.write(L.Log.Settings.detailedLog(state: on ? L.Log.Common.on : L.Log.Common.off))
    }

    /// Dezenter Dauerhinweis, solange das ausführliche Protokoll an ist; nil sonst.
    public var detailedLogNotice: String? { detailedLog ? L.Main.DetailedLog.notice : nil }

    /// Verbindungsfehler setzen: Text und Teile der Meldung, Fehlerfarbe für Punkt und Symbol.
    func showConnectionError(_ m: UserMessage, deviceOff: Bool = false) {
        message = m.text
        messageDetail = m
        lastRefreshFailed = true
        deviceOffNotice = deviceOff
    }

    /// Verbindungsfehler wegklicken (Bridge „dismissMessage“): nimmt auch Punkt und Symbol die Fehlerfarbe.
    public func clearConnectionError() {
        if message != nil { message = nil }
        if messageDetail != nil { messageDetail = nil }
        if lastRefreshFailed { lastRefreshFailed = false }
        if deviceOffNotice { deviceOffNotice = false }
    }

    /// Hinweis anzeigen (auch für Fehler der Oberfläche, z. B. Export gescheitert); er verschwindet nach
    /// `noticeSeconds` von selbst, ein neuer Hinweis startet die Zeit neu. Text nach dem Muster „Was ist passiert.
    /// Was tun.“
    public func showNotice(_ text: String) { showNotice(UserMessage(what: text, todo: "")) }

    /// Wie `showNotice(_:)` mit Text und Code getrennt (der Code steht klein am Ende).
    public func showNotice(_ message: UserMessage) { showNotice(message, persistent: false) }

    /// `persistent`: bleibt stehen, bis der Nutzer ihn wegklickt oder ein Befehl ihn ersetzt (kein Ablauf nach
    /// `noticeSeconds`).
    public func showNotice(_ message: UserMessage, persistent: Bool) {
        noticeTask?.cancel()
        noticeTask = nil
        noticeMessage = message
        guard !persistent else { return }
        noticeTask = Task { [weak self, seconds = noticeSeconds] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.noticeMessage = nil
        }
    }

    public func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        if noticeMessage != nil { noticeMessage = nil }
    }

    /// Ergebnis von `SettingsFileCheck.run` nach dem Start melden (Bridge nach `kc_init`): Protokollzeile in der Sprache
    /// der Oberfläche und, wenn die Einstellungen zurückgesetzt wurden, ein Hinweis ohne Ablaufzeit.
    /// `fileName` = Name der geprüften Datei (für das Protokoll).
    public func reportSettingsFileCheck(_ outcome: SettingsFileCheck.Outcome, fileName: String) {
        switch outcome {
        case .missing, .empty, .valid:
            return
        case .readFailed(let error):
            AppLog.error(L.Log.Settings.unreadable(file: fileName, error: error))
        case .movedAside(let aside), .copiedAside(let aside):
            AppLog.error(L.Log.Settings.damaged(file: aside))
            showNotice(UserMessage(what: L.Message.settingsReset(file: aside), todo: ""), persistent: true)
        case .asideFailed(let error):
            AppLog.error(L.Log.Settings.asideFailed(file: fileName, error: error))
            showNotice(UserMessage(what: L.Message.settingsResetLost, todo: ""), persistent: true)
        }
    }

    // MARK: Startanzeige (Verbindungsschritte)

    func beginConnectPhase() {
        guard connectPhase == nil else { return }
        connectPhase = .searching
        scheduleConnectSlow()
    }

    func endConnectPhase() {
        connectSlowTask?.cancel()
        connectSlowTask = nil
        if connectPhase != nil { connectPhase = nil }
        if connectSlow { connectSlow = false }
    }

    func scheduleConnectSlow() {
        connectSlowTask?.cancel()
        connectSlowTask = Task { [weak self, seconds = connectSlowSeconds] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, connectPhase != nil else { return }
            connectSlow = true
        }
    }

    /// Schritt vom Gerät; gilt nur, solange der Kern gerade verbindet und das Gerät noch das aktuelle ist.
    func devicePhase(_ phase: ConnectPhase, configGeneration gen: Int) {
        guard gen == configGeneration, connectPhase != nil, connectPhase != phase else { return }
        connectPhase = phase
    }
}
