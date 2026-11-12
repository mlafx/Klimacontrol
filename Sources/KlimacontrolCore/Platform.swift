import Foundation
import MideaKit
#if os(Windows)
import WinSDK
#endif

/// Ablage der Einstellungen (Schlüssel → Wert). `UserDefaults` erfüllt das schon; Tests nehmen einen Speicher im RAM.
public protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// Schlüssel der Einstellungen – an einer Stelle, damit Oberflächen und Kern dieselben Namen benutzen.
public enum SettingsKey {
    public static let displayName = "displayName"
    public static let refreshSeconds = "refreshSeconds"
    public static let pricePerKWh = "pricePerKWh"
    public static let connectionMode = "connectionMode"
    /// Windows: gewählte Sprache "system", "de" oder "en" (wirkt nach Neustart). Mac: Sprache über AppleLanguages der App.
    public static let language = "language"
    /// Währung des Strompreises (1–3 Zeichen, Standard „€“).
    public static let currency = "currency"
    /// Mac: Vorabversionen (Beta) über die Beta-Update-Datei beziehen (Standard aus).
    public static let updateBetaChannel = "updateBetaChannel"
    /// Geladene Updates ohne Rückfrage installieren (Standard an); aus = erst nach „Jetzt installieren“.
    public static let updateAutoInstall = "updateAutoInstall"
    /// Suchintervall der Updates: "daily" oder "weekly" (`UpdateInterval`).
    public static let updateInterval = "updateInterval"
    public static let beep = "beep"
    public static let timerOffAt = "timerOffAt"
    public static let timerOnAt = "timerOnAt"
    /// Tag und Zählerstand beim ersten Abruf des Tages, „JJJJ-MM-TT;kWh“.
    public static let energyDayStart = "energyDayStart"
    /// Rechte Spalte (Diagnose) offen – dann wird die Diagnose bei jeder Abfrage gelesen.
    public static let showDiagnosticsPanel = "showDiagnosticsPanel"
    /// Verlauf zusätzlich als verlauf.csv schreiben (Standard aus; der Verlauf liegt in verlauf.sqlite).
    public static let historyCSV = "historyCSV"
    /// Zugangsdaten der aktuellen Einrichtung wurden gesichert (Export oder aus einer Sicherung eingelesen).
    public static let credentialsBackedUp = "credentialsBackedUp"
    /// Fenster-Einstellungen der Mac-Oberfläche (Windows merkt sie sich in Prefs.cs).
    public static let showChartsPanel = "showChartsPanel"
    public static let showScenes = "showScenes"
    /// Mac: Seitenspalte, die zuletzt geöffnet wurde (`history` oder `diagnostics`); bleibt bei zu schmalem Bildschirm.
    public static let lastOpenedColumn = "lastOpenedColumn"
    /// Mac: Verlauf und Diagnose vor dem Vollbild („1,0“), damit sie beim Verlassen zurückkehren; leer = nicht im Vollbild.
    public static let columnsBeforeFullScreen = "columnsBeforeFullScreen"
    public static let showMoreControls = "showMoreControls"
    public static let chartRange = "chartRange"
    /// Art des Verbrauchs unter den Graphen: day, week oder month.
    public static let energyKind = "energyKind"
    public static let logEventsOnly = "logEventsOnly"
    /// Mac: Der Standard „Beim Anmelden starten“ ist schon einmal angewendet worden (auch bei bestehender Einrichtung).
    public static let loginItemDefaultOn = "loginItemDefaultOn"
    /// Version, deren „Neu in dieser Version“ der Nutzer bestätigt hat (oder die frisch installiert wurde).
    public static let lastSeenVersion = "lastSeenVersion"
}

/// Wo der Kern seine Dateien ablegt. Standard: der Ablageordner von MideaKit; Tests geben einen Temp-Ordner an.
public struct CorePaths: Sendable {
    public var config: URL
    public var scenes: URL
    /// verlauf.csv (nur wenn „Verlauf als CSV“ an ist).
    public var history: URL
    public var historyDB: URL

    public init(config: URL, scenes: URL, history: URL, historyDB: URL? = nil) {
        self.config = config
        self.scenes = scenes
        self.history = history
        self.historyDB = historyDB ?? history.deletingLastPathComponent().appendingPathComponent("verlauf.sqlite")
    }

    public init(directory: URL) {
        self.init(config: directory.appendingPathComponent("device.json"),
                  scenes: directory.appendingPathComponent("szenen.json"),
                  history: directory.appendingPathComponent("verlauf.csv"))
    }

    public static var standard: CorePaths { CorePaths(directory: DeviceConfig.supportDirectory) }
}

/// Was je Betriebssystem anders ist (Ruhezustand verhindern, Dateien beiseitelegen).
@MainActor
public protocol PlatformServices: AnyObject {
    /// true: Rechner soll nicht von selbst einschlafen (ein Timer läuft); false: wieder erlauben.
    func keepAwake(_ on: Bool)
    /// Datei entfernen, ohne sie hart zu löschen.
    func discard(_ url: URL) throws
}

/// Umsetzung mit Foundation. macOS/iOS: Aktivität gegen Ruhezustand, Papierkorb.
/// Windows: `SetThreadExecutionState` (gilt für den Hauptthread, auf dem der MainActor läuft).
/// Andere Plattformen: kein Schlafschutz. Außer macOS wird die Datei mit Zeitstempel umbenannt statt gelöscht.
@MainActor
public final class FoundationPlatform: PlatformServices {
    #if os(macOS) || os(iOS)
    private var activity: (any NSObjectProtocol)?
    #endif

    public init() {}

    public func keepAwake(_ on: Bool) {
        #if os(macOS) || os(iOS)
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Klimacontrol-Timer läuft")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        #elseif os(Windows)
        // Nur der Ruhezustand wird verhindert, der Bildschirm darf ausgehen (wie idleSystemSleepDisabled).
        let flags = on ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED) : ES_CONTINUOUS
        _ = SetThreadExecutionState(EXECUTION_STATE(flags))
        #endif
    }

    public func discard(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingPathExtension().appendingPathExtension("entfernt-\(stamp).\(url.pathExtension)")
        try FileManager.default.moveItem(at: url, to: target)
        #endif
    }
}
