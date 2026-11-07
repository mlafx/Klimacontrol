import Foundation
import MideaKit
import Observation

/// Zustand und Befehle für jede Oberfläche. Fragt die Anlage im eingestellten Takt ab und schickt Stellbefehle.
/// Kennt keine Oberfläche: Dateidialoge, Farben und Symbole bleiben in der jeweiligen App.
///
/// Hier steht nur der Speicher (beobachtet bzw. `@ObservationIgnored`), Start und Stopp. Die Abläufe stehen in
/// Erweiterungen: Einstellungen (+Preferences), Verbindungszustand und Meldungen (+Status), Einrichtung wechseln
/// (+Session), Abfrage (+Polling), Stellbefehle (+Commands), Sicherung (+Backup), Midea-Konto (+Cloud),
/// Adresse neu suchen (+AddressRecovery), Bedienlogik (+UI), Timer, Szenen, Verbrauch, Darstellung.
///
/// Läuft auf dem MainActor. Unter Windows muss die Oberfläche die Main-Queue bedienen (`kc_pump`).
@MainActor
@Observable
public final class ACController {
    // MARK: Anlage und Werte

    public internal(set) var config: DeviceConfig?
    public internal(set) var state: ACState?
    public internal(set) var diagnostics: Diagnostics?
    public internal(set) var deviceIdentifier: String?
    /// Zeitpunkt der nächsten automatischen Abfrage (für den Countdown in der Diagnose).
    public internal(set) var nextRefresh: Date?
    public internal(set) var scenes: [ACScene]
    public internal(set) var lastUpdate: Date?
    /// Zuletzt genutzter Weg (WLAN/Cloud).
    public internal(set) var connectionPath: ConnectionPath?
    /// Letzter Verlaufspunkt beim Start (für „Stand HH:MM“, solange noch keine Abfrage gelang); nil = kein Verlauf.
    public internal(set) var lastKnown: HistorySample?

    // MARK: Meldungen und Verbindungszustand (+Status)

    /// Verbindungsfehler (nil = in Ordnung); Hinweise zu Befehlen stehen in `notice`, damit nicht jeder abgelehnte
    /// Befehl „Keine Verbindung“ zeigt. Oberflächen ändern ihn nur über `clearConnectionError()`; die nächste
    /// gelungene Abfrage löscht ihn ohnehin. Eigene Fehler der Oberfläche über `showNotice(_:)`.
    public internal(set) var message: String?
    /// Dieselbe Meldung in Teilen (für Kurzinfo/Details), nil ohne Verbindungsfehler.
    public internal(set) var messageDetail: UserMessage?
    /// Die letzte Abfrage bzw. der letzte Gerätebefehl scheiterte an der Verbindung; false nach jedem Erfolg.
    public internal(set) var lastRefreshFailed = false
    /// `message` ist der Cloud-Hinweis „Anlage ausgeschaltet oder ohne Strom“ – ein Verbindungszustand, kein Fehler
    /// der App. Die Oberfläche zeigt ihn ruhig in Grau statt orange.
    public internal(set) var deviceOffNotice = false
    /// Hinweis zum letzten Befehl (nicht übernommen, Timer nicht ausgeführt, Sicherung in Cloud-Ordner …).
    /// Verschwindet nach `noticeSeconds` von selbst oder mit dem nächsten Befehl.
    public internal(set) var noticeMessage: UserMessage?
    /// Hinweistext (`noticeMessage.text`), nil ohne Hinweis.
    public var notice: String? { noticeMessage?.text }
    /// Anzeigedauer eines Hinweises in Sekunden (Tests setzen sie kürzer).
    @ObservationIgnored var noticeSeconds: Double = 10
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    /// Schritt beim Verbinden (Anlage suchen · Anmelden · Werte lesen); nil = verbunden oder keine Verbindung.
    /// Gesetzt nur, solange noch kein Zustand da ist oder die Verbindung zuletzt fehlte.
    public internal(set) var connectPhase: ConnectPhase?
    /// Das Verbinden dauert länger als `connectSlowSeconds` (Standard 10 s) – „Dauert länger als üblich“.
    public internal(set) var connectSlow = false
    @ObservationIgnored var connectSlowSeconds: Double = 10
    @ObservationIgnored var connectSlowTask: Task<Void, Never>?

    // MARK: Midea-Konto (+Cloud)

    /// Hinterlegtes Midea-Konto für den Cloud-Weg (nur der Kontoname; das Passwort liegt im Geheimnisspeicher).
    public internal(set) var cloudAccount: String?
    public internal(set) var cloudLoginRunning = false

    // MARK: Timer (+Timers)

    /// App-Timer: die PortaSplit nimmt Gerätetimer per LAN nicht an, deshalb schaltet die App selbst.
    public internal(set) var offAt: Date?
    public internal(set) var onAt: Date?
    /// Ergebnis des letzten App-Timers (ausgeführt/verpasst/fehlgeschlagen), für Chip/Mitteilung.
    public internal(set) var lastTimerResult: TimerOutcome?
    /// Laufzeitdaten der Timer-Schleife (Versuche, Hook `onTimerResult`).
    @ObservationIgnored var timerRuntime = TimerRuntime()
    /// Schläft bis zur nächsten Fälligkeit und prüft dann die Timer.
    @ObservationIgnored var timerTask: Task<Void, Never>?
    /// Schickt die Befehle fälliger Timer; Neusetzen, Löschen und `stop()` brechen sie ab.
    @ObservationIgnored var timerFireTask: Task<Void, Never>?
    /// Timer-Schleife erlaubt (laufende App nach `startTimerLoop`); sie läuft nur, solange ein Timer gesetzt ist.
    @ObservationIgnored var timerLoopEnabled = false

    // MARK: Adresse neu suchen (+AddressRecovery)

    /// „Adresse neu suchen“ läuft (Router-/IP-Wechsel).
    public internal(set) var relocating = false
    /// Rückmeldung des letzten „Adresse neu suchen“ (nil = noch keins).
    public internal(set) var relocateMessage: String?
    /// Sucht die Anlage über ihre Anlagen-ID im WLAN (Broadcast, dann Subnetz) und liefert ihre Adresse.
    /// Ohne `autostart` (Tests): findet nichts, damit kein Test ins Netz geht.
    @ObservationIgnored var locate: (UInt64) async throws -> (ip: String, port: UInt16)?
    /// Automatische Adresssuche nach wiederholten WLAN-Fehlern (nur in der laufenden App).
    @ObservationIgnored var relocation: RelocationTrigger

    // MARK: Einstellungen (+Preferences)

    // Die gespeicherten Werte sind beobachtet, die öffentlichen Zugriffe prüfen Grenzen.
    var storedDisplayName: String
    var storedRefreshSeconds: Int
    var storedPrice: Double
    var storedMode: ConnectionMode
    var storedCurrency: String
    var storedLanguage: LanguageChoice
    var storedBetaChannel: Bool
    var storedBeep: Bool
    /// Darstellung (beobachtet); ändern nur über `setAppearance`/`applyTheme`/`resetAppearance`.
    public internal(set) var appearance: Appearance = .standard
    /// Zugangsdaten der aktuellen Einrichtung wurden gesichert (Export oder eingelesene Sicherung). Ohne Sicherung
    /// kann die Oberfläche „Jetzt sichern?“ anbieten.
    public internal(set) var credentialsBackedUp = false
    /// „Neu in dieser Version“ für diese Plattform (neueste zuerst); leer, wenn nichts zu zeigen ist. Siehe `ACController+WhatsNew`.
    public internal(set) var whatsNew: [ReleaseNote] = []
    /// Dasselbe ungefiltert (die Bridge filtert für Windows selbst).
    @ObservationIgnored var pendingReleaseNotes: [ReleaseNote] = []
    /// Sichtbare Oberflächen (z. B. "main", "menu"); siehe `setUIVisible`.
    var visibleUIs: Set<String> = []
    /// Die Oberfläche zeigt die Diagnose: dann wird sie bei jeder Abfrage gelesen, sonst höchstens alle 30 s.
    @ObservationIgnored public var diagnosticsVisible = false

    // MARK: Teile und Abhängigkeiten

    /// Verlauf für die Graphen.
    @ObservationIgnored public let history: HistoryStore
    /// Einrichtung (Suche im WLAN, Midea-Konto).
    @ObservationIgnored public let setup: SetupFlow
    @ObservationIgnored let settings: any SettingsStore
    /// Laufende Version der App.
    @ObservationIgnored public let appVersion: String
    @ObservationIgnored let paths: CorePaths
    @ObservationIgnored let platform: any PlatformServices
    @ObservationIgnored let accounts: CloudAccountStore
    @ObservationIgnored let makeDevice: ACDeviceFactory
    /// Uhr (aus `CoreDependencies`; Tests stellen sie).
    @ObservationIgnored var now: () -> Date
    /// Prüft Zugangsdaten mit eigener Verbindung (Sicherung, Adresse neu suchen). Tests geben einen Versuch vor.
    @ObservationIgnored var probe: CredentialProbe

    // MARK: Gerät, Abfrage, Befehle (+Session, +Polling, +Commands)

    @ObservationIgnored var device: (any ACDevice)?
    @ObservationIgnored var pollTask: Task<Void, Never>?
    /// Nach `stop()` startet nichts mehr eine Abfrage (auch keine noch laufende Anmeldung oder Einrichtung).
    @ObservationIgnored var stopped = false
    /// Laufende Gerätebefehle (Abfrage oder Stellbefehl) – nicht beobachtet, damit nicht jede Abfrage neu zeichnet.
    @ObservationIgnored var inFlight = 0
    /// Laufende Stellbefehle (ohne Abfragen).
    var commandsInFlight = 0
    /// Eine Abfrage wurde verlangt, während ein Befehl lief – sie folgt, sobald er fertig ist.
    @ObservationIgnored var refreshPending = false
    /// Eine eigene Prüfverbindung läuft (Sicherung, Adresse neu suchen): so lange keine Abfrage, denn die Anlage
    /// nimmt nur eine WLAN-Verbindung an.
    @ObservationIgnored var probing = 0
    /// Zählt Stellbefehle; eine Abfrage oder ein älterer Befehl, der davor begann, überschreibt den Zustand nicht mehr.
    @ObservationIgnored var generation = 0
    /// Zählt Einrichtungswechsel (`use`, `stopDevice`); Ergebnisse eines alten Geräts werden verworfen.
    @ObservationIgnored var configGeneration = 0
    @ObservationIgnored var lastDiagnostics = Date.distantPast
    /// Schnellmodus: Zähler für den Block im Wechsel (`fastCycle`).
    @ObservationIgnored var fastStep = 0
    /// Gesammelte Befehle (Temperatur, Lüfter), die nach `debounceDelay` Ruhe gesendet werden.
    @ObservationIgnored var debounce: [DebounceKey: Task<Void, Never>] = [:]
    /// Ausgangsstand je gesammeltem Befehl (vor dem ersten Wert im Sammelfenster), für das Zurücksetzen.
    @ObservationIgnored var debounceOrigin: [DebounceKey: ACState] = [:]
    /// Lüfter-Zonen (+UI): letztes Umschalten von „Außengerät leise“/Turbo – beim Ziehen kommen viele Werte,
    /// bevor die Anlage antwortet, darum höchstens einmal je `zoneGap`.
    @ObservationIgnored var zoneSentAt = Date.distantPast
    /// Mindestabstand zweier Zonen-Wechsel an der Anlage (Tests verkürzen ihn).
    @ObservationIgnored var zoneGap: TimeInterval = 2
    /// Ruhezeit, nach der ein gesammelter Befehl gesendet wird.
    @ObservationIgnored var debounceDelay: Duration = .milliseconds(700)

    /// - Parameters:
    ///   - appVersion: steht im Protokoll beim Start.
    ///   - dependencies: Ablagen, Betriebssystem, Anlage, Midea-Konto, Uhr.
    ///   - autostart: false für Tests – dann keine Einrichtung laden, keine Abfrage- und Timer-Schleife, keine Suche im Netz.
    public init(appVersion: String, dependencies deps: CoreDependencies, autostart: Bool = true) {
        self.appVersion = appVersion
        settings = deps.settings
        paths = deps.paths
        platform = deps.platform
        accounts = deps.accounts
        makeDevice = deps.makeDevice
        now = deps.now
        probe = .device(deps.makeDevice, quiet: false)
        setup = SetupFlow(now: deps.now)
        relocation = RelocationTrigger(enabled: autostart)
        locate = autostart
            ? { id in try await Discovery.find(deviceId: id).map { (ip: $0.ip, port: $0.port) } }
            : { _ in nil }
        let stored = deps.settings
        let store = HistoryStore(db: HistoryDB(url: deps.paths.historyDB), log: HistoryLog(url: deps.paths.history),
                                 importExisting: autostart)
        store.csvEnabled = stored.object(forKey: SettingsKey.historyCSV) as? Bool ?? false
        history = store
        let loadedScenes = ACScene.loadReporting(from: deps.paths.scenes)
        scenes = loadedScenes.scenes
        cloudAccount = deps.accounts.load()?.account
        storedDisplayName = stored.object(forKey: SettingsKey.displayName) as? String ?? Self.defaultDisplayName
        storedRefreshSeconds = Self.clampRefresh(stored.object(forKey: SettingsKey.refreshSeconds) as? Int ?? 30)
        storedPrice = Self.validPrice(stored.object(forKey: SettingsKey.pricePerKWh) as? Double) ?? 0.30
        // Alte Bluetooth-Werte („ble“, „blePreferred“) werden zu „Automatisch“.
        storedMode = ConnectionMode(stored: stored.object(forKey: SettingsKey.connectionMode) as? String)
        storedCurrency = Self.validCurrency(stored.object(forKey: SettingsKey.currency) as? String) ?? UIOptions.currencyDefault
        storedLanguage = LanguageChoice(stored: stored.object(forKey: SettingsKey.language) as? String)
        storedBetaChannel = stored.object(forKey: SettingsKey.updateBetaChannel) as? Bool ?? false
        storedBeep = stored.object(forKey: SettingsKey.beep) as? Bool ?? true
        appearance = Self.loadAppearance(from: stored)
        credentialsBackedUp = stored.object(forKey: SettingsKey.credentialsBackedUp) as? Bool ?? false
        setup.sink = self
        loadTimers()
        loadWhatsNew()
        if let aside = loadedScenes.movedAside {
            showNotice(L.Message.Scenes.movedAside(name: aside))
        }
        guard autostart else { return }
        if let cfg = DeviceConfig.load(from: paths.config) {
            AppLog.write("Klimacontrol \(appVersion) gestartet – Anlage \(cfg.name) @ \(cfg.ip)")
            // Startanzeige: zuletzt bekannte Werte (höchstens 1 Tag alt) abgeblendet mit „Stand HH:MM“.
            lastKnown = history.window(86400).last
            use(cfg)
        } else {
            AppLog.write("Klimacontrol \(appVersion) gestartet – noch keine Anlage eingerichtet")
        }
        startTimerLoop()
    }

    /// Wie `init(appVersion:dependencies:autostart:)` mit einzelnen Abhängigkeiten.
    /// - Parameters:
    ///   - accounts: Midea-Konto (Standard: Geheimnisspeicher des Systems).
    ///   - makeDevice: baut das Gerät (Standard: `PortaSplitDevice`).
    public convenience init(appVersion: String, settings: any SettingsStore = UserDefaults.standard,
                            paths: CorePaths = .standard, platform: (any PlatformServices)? = nil,
                            accounts: CloudAccountStore = .system, makeDevice: ACDeviceFactory? = nil,
                            autostart: Bool = true) {
        self.init(appVersion: appVersion,
                  dependencies: CoreDependencies(settings: settings, paths: paths, platform: platform,
                                                 accounts: accounts, makeDevice: makeDevice),
                  autostart: autostart)
    }

    /// Beendet Abfrage, Timer, gesammelte Befehle und Verbindung (z. B. beim Schließen der Oberfläche).
    public func stop() {
        stopped = true
        pollTask?.cancel()
        endConnectPhase()
        timerLoopEnabled = false
        timerTask?.cancel()
        timerFireTask?.cancel()
        platform.keepAwake(false)
        cancelAllDebounce()
        device?.disconnect()
        // Zum Schluss die WAL-Datei des Verlaufs in die Datenbank übernehmen (sonst wächst sie auf mehrere MB).
        history.close()
    }
}

/// Verbindungszustand (`ACController.connectionState`).
public enum ConnectionState: Sendable, Equatable {
    /// Noch keine Anlage eingerichtet.
    case notConfigured
    /// Verbindet gerade (Schritt in `connectPhase`) bzw. wartet auf die erste Abfrage.
    case connecting
    /// Werte sind aktuell.
    case live
    /// Anlage laut Midea-Cloud ausgeschaltet oder ohne Strom (ruhig/grau anzeigen; Werte = `staleSince`).
    case deviceOff
    /// Verbindung fehlt (Werte = `staleSince`, Meldung in `message`).
    case noConnection
}
