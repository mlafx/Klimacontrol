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
    public func showNotice(_ message: UserMessage) {
        noticeTask?.cancel()
        noticeMessage = message
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
