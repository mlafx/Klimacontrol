import Foundation
import MideaKit

/// Einstellungen: gespeichert über `SettingsStore` (Schlüssel in `SettingsKey`), Grenzen prüfen die Setter.
extension ACController {
    static let defaultDisplayName = "Klimaanlage"
    public static let backgroundRefreshSeconds = 30

    /// Anzeigename statt der technischen Kennung der Anlage.
    public var displayName: String {
        get { storedDisplayName }
        set {
            storedDisplayName = DeviceConfig.cleanText(newValue, fallback: Self.defaultDisplayName)
            settings.set(storedDisplayName, forKey: SettingsKey.displayName)
        }
    }

    /// Abfrageintervall in Sekunden (1–600). Kürzer = aktueller, aber mehr Verkehr zur Anlage;
    /// unter 8 s bleibt die Verbindung dauerhaft offen (andere Apps kommen dann nicht an die Anlage).
    public var refreshSeconds: Int {
        get { storedRefreshSeconds }
        set {
            let clamped = Self.clampRefresh(newValue)
            guard clamped != storedRefreshSeconds else { return }
            storedRefreshSeconds = clamped
            settings.set(clamped, forKey: SettingsKey.refreshSeconds)
            AppLog.write("Aktualisierung alle \(clamped) s")
            restartPolling()
        }
    }

    /// Keine Oberfläche sichtbar (nur Menüleiste/Infobereich).
    public var background: Bool { visibleUIs.isEmpty }

    /// Takt, mit dem tatsächlich abgefragt wird: ohne sichtbare Oberfläche höchstens alle
    /// `backgroundRefreshSeconds` – der eingestellte Takt bleibt gespeichert und gilt wieder, sobald ein Fenster offen ist.
    public var effectiveRefreshSeconds: Int {
        background ? max(Self.backgroundRefreshSeconds, refreshSeconds) : refreshSeconds
    }

    /// Eine Oberfläche meldet, ob sie sichtbar ist. Ändert sich dadurch der Takt, startet die Abfrage neu
    /// (beim Sichtbarwerden also sofort).
    public func setUIVisible(_ id: String, _ visible: Bool) {
        let before = effectiveRefreshSeconds
        let wasBackground = background
        if visible { visibleUIs.insert(id) } else { visibleUIs.remove(id) }
        guard before != effectiveRefreshSeconds || (wasBackground && !background) else { return }
        // Wer nach Hause kommt und das Fenster öffnet, soll sofort wieder WLAN probieren statt bis zu 5 min auf den
        // Cloud-Backoff zu warten.
        if wasBackground, !background { device?.resetBackoff() }
        AppLog.debug(background ? "Kein Fenster sichtbar – Abfrage alle \(effectiveRefreshSeconds) s" : "Fenster sichtbar")
        restartPolling()
    }

    /// Strompreis je kWh in Euro (0–10).
    public var pricePerKWh: Double {
        get { storedPrice }
        set {
            guard let price = Self.validPrice(newValue) else { return }
            storedPrice = price
            settings.set(price, forKey: SettingsKey.pricePerKWh)
        }
    }

    /// Weg zur Anlage: Automatisch (WLAN → Cloud), Nur WLAN, Nur Cloud.
    public var connectionMode: ConnectionMode {
        get { storedMode }
        set {
            guard newValue != storedMode else { return }
            storedMode = newValue
            settings.set(newValue.rawValue, forKey: SettingsKey.connectionMode)
            device?.connectionMode = newValue
            AppLog.write("Verbindungsweg: \(newValue.label)")
        }
    }

    /// Signalton der Anlage bei Befehlen; ändern über `setSound` (gilt erst, wenn die Anlage ihn angenommen hat).
    public var beep: Bool { storedBeep }

    /// Verlauf zusätzlich als `verlauf.csv` schreiben (der Verlauf selbst liegt immer in `verlauf.sqlite`).
    public var historyCSV: Bool {
        get { history.csvEnabled }
        set {
            guard newValue != history.csvEnabled else { return }
            history.csvEnabled = newValue
            settings.set(newValue, forKey: SettingsKey.historyCSV)
            AppLog.write("Verlauf als CSV: \(newValue ? "an" : "aus")")
        }
    }

    public var cloudConfigured: Bool { cloudAccount != nil }

    func setCredentialsBackedUp(_ on: Bool) {
        credentialsBackedUp = on
        if on { settings.set(true, forKey: SettingsKey.credentialsBackedUp) } else {
            settings.removeObject(forKey: SettingsKey.credentialsBackedUp)
        }
    }

    static func clampRefresh(_ v: Int) -> Int { min(UIOptions.refreshMax, max(UIOptions.refreshMin, v)) }
    public static func validPrice(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && ($0 >= UIOptions.priceMin && $0 <= UIOptions.priceMax) ? $0 : nil } }
    /// Meldung für einen Strompreis außerhalb von `validPrice` (beide Oberflächen).
    public static let priceHint = "Der Strompreis muss zwischen 0 und 10 € je kWh liegen. Bitte korrigieren. (price)"
}
