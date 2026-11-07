import Foundation
import MideaKit

/// Midea-Konto für den Cloud-Weg (Steuerung unterwegs).
extension ACController {
    /// Meldet sich einmal mit dem MSmartHome-Konto an, prüft es und legt es im Geheimnisspeicher ab.
    /// Erfolg → nil, sonst die Fehlermeldung. Das Passwort steht nie im Protokoll.
    public func cloudLogin(account: String, password: String) async -> String? {
        guard !cloudLoginRunning else { return L.Message.Account.running }
        guard let cfg = config, cfg.deviceId != 0 else {
            return L.Message.Account.noId
        }
        let creds = CloudCredentials(account: account.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        guard !creds.account.isEmpty, !password.isEmpty else { return L.Message.Account.missingInput }
        cloudLoginRunning = true
        defer { cloudLoginRunning = false }
        let startGeneration = configGeneration
        let startAccount = cloudAccount
        do {
            try await accounts.verify(creds, cfg)
        } catch {
            AppLog.error("Cloud-Login fehlgeschlagen: \(error.localizedDescription)")
            return UserMessage.from(error).text
        }
        // Inzwischen eine andere Anlage eingerichtet, vergessen oder abgemeldet? Dann nichts übernehmen.
        // (Stellbefehle zählen hier nicht – nur Einrichtungswechsel.)
        guard configGeneration == startGeneration, config == cfg, cloudAccount == startAccount else {
            return L.Message.Account.setupChanged
        }
        do { try accounts.save(creds) } catch {
            AppLog.error("Cloud-Konto nicht gespeichert: \(error.localizedDescription)")
            return UserMessage.from(error).text
        }
        cloudAccount = creds.account
        connectionMode = UIText.modeAfterAccountLogin(connectionMode)
        use(cfg) // Gerät mit Cloud-Weg neu aufbauen
        clearConnectionError()
        return nil
    }

    /// Entfernt Cloud-Konto und gespeicherte Sitzung und baut das Gerät ohne Cloud-Weg neu auf.
    public func cloudLogout() {
        accounts.clear()
        cloudAccount = nil
        if connectionMode == .cloud { connectionMode = .auto }
        if let cfg = config { use(cfg) }
        AppLog.write("Cloud-Konto entfernt")
    }
}
