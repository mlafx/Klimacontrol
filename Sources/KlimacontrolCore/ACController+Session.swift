import Foundation
import MideaKit

/// Einrichtung wechseln: Gerät zu einer Einrichtung aufbauen, neue Einrichtung übernehmen, „Neu einrichten“.
extension ACController {
    /// Baut die Verbindung zu einer (neuen) Einrichtung auf und startet die Abfrage.
    func use(_ cfg: DeviceConfig) {
        config = cfg
        generation += 1
        configGeneration += 1
        cancelAllDebounce()
        device?.disconnect()
        connectionPath = nil
        deviceIdentifier = nil
        relocation.reset()
        do {
            device = try makeDevice(cfg, connectionMode, accounts.load())
            device?.beep = beep
            let gen = configGeneration
            device?.onPhase = { [weak self] phase in
                Task { @MainActor in self?.devicePhase(phase, configGeneration: gen) }
            }
        } catch {
            device = nil
            showConnectionError(UserMessage(what: "Die Einrichtung der Anlage ist unvollständig.",
                                            todo: "Lies eine Sicherung ein oder richte die Anlage neu ein.",
                                            code: UserMessage.from(error).code, detail: error.localizedDescription))
            AppLog.error("Anlage nicht nutzbar: \(error.localizedDescription)")
        }
        restartPolling()
        guard let current = device else { return }
        Task {
            let id = try? await current.identifier()
            if device === current { deviceIdentifier = id }
        }
    }

    /// Einrichtung zurücksetzen (neue Anlage). Die Datei `device.json` wandert **unverändert** (mit Token und
    /// Schlüssel) in den Papierkorb bzw. wird unter Windows umbenannt – so bleibt „neu einrichten“ umkehrbar.
    /// Die Cloud-Sitzung gilt nur für diese Anlage und wird verworfen, das Konto bleibt. Router-/IP-Wechsel: `relocate()`.
    public func forgetDevice() {
        stopDevice()
        do { try platform.discard(paths.config) } catch { AppLog.error("Einrichtung nicht entfernt: \(error.localizedDescription)") }
        accounts.clearSession()
        setCredentialsBackedUp(false)
        forgetEnergyDayStart()
        setup.reset()
        lastKnown = nil
        endConnectPhase()
        config = nil
        state = nil
        diagnostics = nil
        deviceIdentifier = nil
        connectionPath = nil
        lastUpdate = nil
        nextRefresh = nil
        clearConnectionError()
        clearNotice()
        if offAt != nil || onAt != nil {
            AppLog.write("App-Timer gelöscht (keine Anlage mehr eingerichtet)")
            cancelTimerFire()
            offAt = nil
            onAt = nil
            persistTimers()
        }
        AppLog.write("Einrichtung zurückgesetzt")
    }

    func stopDevice() {
        generation += 1
        configGeneration += 1
        pollTask?.cancel()
        cancelAllDebounce()
        device?.disconnect()
        device = nil
    }

    /// Neue Einrichtung prüfen, speichern und übernehmen (Sicherung, Midea-Konto, Zugangsdaten). Die neuen
    /// Zugangsdaten gelten als noch nicht gesichert (`credentialsBackedUp`).
    func adopt(_ cfg: DeviceConfig) throws {
        let checked = try cfg.validated()
        try checked.save(to: paths.config)
        setCredentialsBackedUp(false)
        use(checked)
    }

    /// Einrichtung nur über die Cloud (Anlage aus oder nicht im WLAN): Konto prüfen (Anlage muss im Konto sein),
    /// Konto im Geheimnisspeicher ablegen, Weg „Automatisch“. WLAN-Zugang lässt sich später per Suche ergänzen.
    func adoptCloud(_ device: DiscoveredDevice, account: String, password: String) async throws {
        let creds = CloudCredentials(account: account, password: password)
        let cfg = try DeviceConfig(name: device.name, ip: "", port: 0, deviceId: device.deviceId, token: "", key: "").validated()
        try await accounts.verify(creds, cfg)
        try accounts.save(creds) // zuerst: ohne gespeichertes Konto ist eine reine Cloud-Einrichtung unbenutzbar
        try cfg.save(to: paths.config)
        cloudAccount = creds.account
        if connectionMode == .lan { connectionMode = .auto }
        use(cfg)
        AppLog.write("Anlage über die Cloud eingerichtet: \(cfg.name) (id \(cfg.deviceId))")
    }
}

extension ACController: SetupSink {}
