import Foundation
import MideaKit

/// Was der Kern von außen bekommt: Ablage der Einstellungen und Dateien, Dienste des Betriebssystems, Bau der Anlage,
/// Midea-Konto und Uhr. Die laufende App nimmt die Standardwerte; Tests ersetzen einzelne Teile (Speicher im RAM,
/// Temp-Ordner, nachgebildete Anlage, gestellte Uhr).
@MainActor
public struct CoreDependencies {
    public var settings: any SettingsStore
    public var paths: CorePaths
    public var platform: any PlatformServices
    /// Midea-Konto (Standard: Geheimnisspeicher des Systems).
    public var accounts: CloudAccountStore
    /// Baut das Gerät zu einer Einrichtung (Standard: `PortaSplitDevice`).
    public var makeDevice: ACDeviceFactory
    /// Uhr für Zeitstempel, Timer und Fristen. Gewartet wird trotzdem in echter Zeit.
    public var now: () -> Date

    public init(settings: any SettingsStore = UserDefaults.standard, paths: CorePaths = .standard,
                platform: (any PlatformServices)? = nil, accounts: CloudAccountStore = .system,
                makeDevice: ACDeviceFactory? = nil, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.paths = paths
        self.platform = platform ?? FoundationPlatform()
        self.accounts = accounts
        self.makeDevice = makeDevice ?? Self.portaSplit
        self.now = now
    }

    /// Standard-Fabrik: die echte Anlage über `PortaSplitDevice`.
    public static let portaSplit: ACDeviceFactory = { cfg, mode, cloud in
        try PortaSplitDevice(config: cfg, mode: mode, cloud: cloud)
    }
}
