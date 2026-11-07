import Foundation
import MideaKit

/// Ergebnis einer Prüfung von Zugangsdaten an der Anlage. Nur `rejected` heißt „Token oder Schlüssel passen nicht“;
/// alles andere sagt nichts über die Zugangsdaten.
enum CredentialCheck: Sendable {
    /// Die Anlage nimmt Token und Schlüssel an.
    case accepted
    /// Die Anlage lehnt Token oder Schlüssel ab. Ein falscher Schlüssel zeigt sich schon bei der Anmeldung; ein
    /// Krypto-Fehler danach ist ein Lesefehler, keine Ablehnung.
    case rejected(any Error)
    /// Eine andere Verbindung hält die Anlage (sie nimmt nur eine gleichzeitig an).
    case busy(any Error)
    /// Keine verwertbare Antwort: nicht erreichbar, Zeitüberschreitung, unlesbare Antwort. Eine abgewiesene
    /// Verbindung gehört hierher, nicht zu `busy` – sie spricht eher für eine alte Adresse.
    case noAnswer(any Error)

    init(_ failure: (any Error)?) {
        guard let failure else { self = .accepted; return }
        if let e = failure as? MideaError {
            switch e {
            case .authenticationFailed: self = .rejected(failure)
            case .busy, .commandNotApplied: self = .busy(failure)
            case .allPathsFailed(let paths) where paths.contains(where: { $0.reason == .busy }): self = .busy(failure)
            case .crypto, .protocolError, .timeout, .connectionFailed, .invalidResponse, .refused, .unreachable,
                 .outcomeUnknown, .allPathsFailed:
                self = .noAnswer(failure)
            }
        } else if case .tokenRejected? = failure as? MideaCloud.CloudError {
            self = .rejected(failure)
        } else {
            self = .noAnswer(failure)
        }
    }

    /// Der Fehler hinter dem Ergebnis; nil = angenommen.
    var error: (any Error)? {
        switch self {
        case .accepted: return nil
        case .rejected(let e), .busy(let e), .noAnswer(let e): return e
        }
    }

    var isRejected: Bool { if case .rejected = self { return true } else { return false } }
}

/// Prüft Zugangsdaten an einer Adresse: Anmeldung an der Anlage nur im WLAN und eine Abfrage, danach sofort trennen.
/// Ändert nichts an der Anlage. Eine Prüfung für Einrichtung, Sicherung und „Adresse neu suchen“; Tests geben einen
/// eigenen Versuch vor.
@MainActor
struct CredentialProbe {
    /// Ein Versuch: nil = angenommen, sonst der Fehler.
    let attempt: (DeviceConfig) async -> (any Error)?

    init(_ attempt: @escaping (DeviceConfig) async -> (any Error)?) {
        self.attempt = attempt
    }

    func check(_ cfg: DeviceConfig) async -> CredentialCheck {
        CredentialCheck(await attempt(cfg))
    }

    /// Über eine Geräte-Fabrik, ohne Cloud-Weg. `quiet`: Verbindungsfehler nicht zusätzlich vom Gerät protokollieren
    /// (die Einrichtung zeigt sie selbst an).
    static func device(_ make: @escaping ACDeviceFactory, quiet: Bool) -> CredentialProbe {
        CredentialProbe { cfg in
            do {
                let probe = try make(cfg, .lan, nil)
                if quiet, let real = probe as? PortaSplitDevice { real.quietErrors = true }
                defer { probe.disconnect() }
                _ = try await probe.refresh()
                return nil
            } catch {
                return error
            }
        }
    }
}
