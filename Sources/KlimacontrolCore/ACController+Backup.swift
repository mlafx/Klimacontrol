import Foundation
import MideaKit

/// Sicherung der Zugangsdaten (und Szenen): einlesen mit Prüfung an der Anlage, als Datei sichern.
extension ACController {
    /// Liest eine Sicherung ein und prüft sie vorher:
    /// - Gehört sie zu einer anderen Anlage als der eingerichteten, wirft sie `BackupImportError.otherDevice`
    ///   (außer `allowOtherDevice`).
    /// - Ist die Anlage im WLAN erreichbar, meldet sich der Kern mit Token und Schlüssel an; lehnt die Anlage sie ab,
    ///   wirft sie `BackupImportError.rejected` und die bisherige Einrichtung bleibt. Ist die Anlage nicht erreichbar,
    ///   wird übernommen und `verified == false` gemeldet.
    /// - Die bisherige `device.json` wandert vorher in den Papierkorb (nie überschrieben).
    /// - Vorhandene Szenen werden nur mit `replaceScenes` ersetzt; ohne vorhandene Szenen werden die der Sicherung
    ///   übernommen.
    public func importBackupChecked(from url: URL, replaceScenes: Bool = false,
                                    allowOtherDevice: Bool = false) async throws -> BackupImportResult {
        let (cfg, imported) = try readBackup(url, allowOtherDevice: allowOtherDevice)
        var verified: Bool?
        if cfg.hasLAN {
            let check = await checkExclusively(cfg)
            if case .rejected(let error) = check {
                AppLog.error(L.Log.Backup.rejected(error: error.localizedDescription))
                throw BackupImportError.rejected
            }
            if case .accepted = check { verified = true } else { verified = false }
        }
        return try installBackup(cfg, scenes: imported, replaceScenes: replaceScenes, verified: verified)
    }

    func readBackup(_ url: URL, allowOtherDevice: Bool) throws -> (DeviceConfig, [ACScene]) {
        let cfg = try DeviceConfig.fromBackup(url).validated()
        let imported = (try? ACScene.fromBackup(url)) ?? []
        if !allowOtherDevice, let current = config, current.deviceId != 0, cfg.deviceId != 0, current.deviceId != cfg.deviceId {
            throw BackupImportError.otherDevice(backup: cfg.name, current: current.name)
        }
        return (cfg, imported)
    }

    func installBackup(_ cfg: DeviceConfig, scenes imported: [ACScene], replaceScenes: Bool,
                       verified: Bool?) throws -> BackupImportResult {
        // Bisherige Einrichtung nicht überschreiben, sondern beiseitelegen (Papierkorb bzw. umbenennen).
        if let old = DeviceConfig.load(from: paths.config), old != cfg {
            do { try platform.discard(paths.config) } catch {
                AppLog.error(L.Log.Backup.notSetAside(error: error.localizedDescription))
                throw error
            }
        }
        try adopt(cfg)
        setCredentialsBackedUp(true)
        var result = BackupImportResult(verified: verified)
        if !imported.isEmpty {
            if scenes.isEmpty || replaceScenes {
                scenes = imported
                saveScenes()
                result.scenesImported = imported.count
            } else {
                result.scenesSkipped = imported.count
            }
        }
        clearConnectionError()
        AppLog.write(L.Log.Backup.restored(
            name: cfg.name, ip: cfg.ip,
            verified: verified.map { $0 ? L.Log.Backup.verified : L.Log.Backup.unverified } ?? "",
            skipped: result.scenesSkipped > 0 ? L.Log.Backup.scenesSkipped(count: String(result.scenesSkipped)) : ""))
        return result
    }

    /// Zugangsdaten + Szenen als Datei sichern (gleiches Format wie beim Einlesen, nur für den eigenen Benutzer
    /// lesbar). Liegt das Ziel in einem Cloud-Ordner, steht danach ein Hinweis in `notice`. Ohne Einrichtung wirft sie.
    public func exportBackup(to url: URL) throws {
        guard let cfg = config else { throw BackupImportError.nothingToExport }
        try cfg.exportBackup(to: url, scenes: scenes)
        setCredentialsBackedUp(true)
        AppLog.write(L.Log.Backup.exported(file: url.lastPathComponent))
        if Self.isCloudSynced(url) {
            showNotice(UIText.cloudFolderNotice)
        }
    }

    static func isCloudSynced(_ url: URL) -> Bool {
        UIText.isCloudFolder(path: url.standardizedFileURL.path)
    }

    /// Wie `probe.check`, aber ohne zweite Verbindung neben der eigenen (die Anlage nimmt nur eine an): laufende
    /// Befehle abwarten (höchstens 15 s), eigene Verbindung trennen und die Abfrage bis zum Ende anhalten.
    func checkExclusively(_ cfg: DeviceConfig) async -> CredentialCheck {
        probing += 1
        defer {
            probing -= 1
            if probing == 0 { runPendingRefresh() }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while inFlight > 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        device?.disconnect()
        return await probe.check(cfg)
    }
}

/// Ergebnis von `importBackupChecked`.
public struct BackupImportResult: Equatable, Sendable {
    /// true = an der Anlage geprüft, false = Anlage nicht erreichbar (ungeprüft übernommen), nil = Sicherung ohne
    /// WLAN-Zugang (nur Cloud).
    public var verified: Bool?
    /// Aus der Sicherung übernommene Szenen.
    public var scenesImported = 0
    /// Szenen der Sicherung, die nicht übernommen wurden, weil schon Szenen da sind (`replaceScenes` = false).
    public var scenesSkipped = 0

    public init(verified: Bool?, scenesImported: Int = 0, scenesSkipped: Int = 0) {
        self.verified = verified
        self.scenesImported = scenesImported
        self.scenesSkipped = scenesSkipped
    }
}

public enum BackupImportError: Error, LocalizedError, Equatable {
    /// Die Sicherung gehört zu einer anderen Anlage als der eingerichteten.
    case otherDevice(backup: String, current: String)
    /// Die Anlage hat Token und Schlüssel der Sicherung abgelehnt; die bisherige Einrichtung bleibt.
    case rejected
    /// Es ist noch keine Anlage eingerichtet, also gibt es nichts zu sichern.
    case nothingToExport

    public var errorDescription: String? {
        switch self {
        case .otherDevice(let backup, let current):
            return L.Message.Backup.otherDevice(backup: backup, current: current)
        case .rejected:
            return L.Message.Backup.rejected
        case .nothingToExport:
            return L.Message.Backup.nothingToExport
        }
    }
}
