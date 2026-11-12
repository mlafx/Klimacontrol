import Foundation
import MideaKit

/// Einstellungen: gespeichert über `SettingsStore` (Schlüssel in `SettingsKey`), Grenzen prüfen die Setter.
extension ACController {
    static var defaultDisplayName: String { L.Message.defaultName }
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
            AppLog.write(L.Log.Settings.refresh(seconds: String(clamped)))
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
        AppLog.debug(background ? L.Log.Settings.backgroundPolling(seconds: String(effectiveRefreshSeconds)) : L.Log.Settings.windowVisible)
        restartPolling()
    }

    /// Strompreis je kWh (0–1000, Währung siehe `currency`).
    public var pricePerKWh: Double {
        get { storedPrice }
        set {
            guard let price = Self.validPrice(newValue) else { return }
            storedPrice = price
            settings.set(price, forKey: SettingsKey.pricePerKWh)
        }
    }

    /// Währung des Strompreises, immer nachgestellt. Ungültige Werte werden ignoriert (Oberfläche zeigt `currencyHint`).
    public var currency: String {
        get { storedCurrency }
        set {
            guard let value = Self.validCurrency(newValue), value != storedCurrency else { return }
            storedCurrency = value
            settings.set(value, forKey: SettingsKey.currency)
            AppLog.write(L.Log.Settings.currency(value: value))
        }
    }

    /// Gespeicherte Sprachwahl; ändert die laufende Sprache nicht (wirkt nach Neustart).
    public var languageChoice: LanguageChoice {
        get { storedLanguage }
        set {
            guard newValue != storedLanguage else { return }
            storedLanguage = newValue
            settings.set(newValue.rawValue, forKey: SettingsKey.language)
            AppLog.write(L.Log.Settings.languageAfterRestart(value: newValue.rawValue))
        }
    }

    /// Mac: Beta-Kanal der Updates.
    public var updateBetaChannel: Bool {
        get { storedBetaChannel }
        set {
            guard newValue != storedBetaChannel else { return }
            storedBetaChannel = newValue
            settings.set(newValue, forKey: SettingsKey.updateBetaChannel)
            AppLog.write(L.Log.Settings.betaChannel(state: newValue ? L.Log.Common.on : L.Log.Common.off))
        }
    }

    /// Geladene Updates ohne Rückfrage installieren (Standard an).
    public var updateAutoInstall: Bool {
        get { storedUpdateAutoInstall }
        set {
            guard newValue != storedUpdateAutoInstall else { return }
            storedUpdateAutoInstall = newValue
            settings.set(newValue, forKey: SettingsKey.updateAutoInstall)
            AppLog.write(L.Log.Settings.updateAutoInstall(state: newValue ? L.Log.Common.on : L.Log.Common.off))
        }
    }

    /// „Nach Updates suchen“: täglich oder wöchentlich.
    public var updateInterval: UpdateInterval {
        get { storedUpdateInterval }
        set {
            guard newValue != storedUpdateInterval else { return }
            storedUpdateInterval = newValue
            settings.set(newValue.rawValue, forKey: SettingsKey.updateInterval)
            AppLog.write(L.Log.Settings.updateInterval(value: newValue.title))
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
            AppLog.write(L.Log.Settings.connectionMode(mode: newValue.title))
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
            AppLog.write(L.Log.Settings.historyCSV(state: newValue ? L.Log.Common.on : L.Log.Common.off))
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
    public static var priceHint: String { L.Settings.Price.invalid }
    public static var currencyHint: String { L.Settings.Currency.invalid }
    /// Gültige Währung (getrimmt) oder nil: 1…`currencyMaxLength` Zeichen, nur Buchstaben oder Währungszeichen.
    public static func validCurrency(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= UIOptions.currencyMaxLength else { return nil }
        let allowed: Set<Unicode.GeneralCategory> = [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .currencySymbol]
        return value.unicodeScalars.allSatisfy { allowed.contains($0.properties.generalCategory) } ? value : nil
    }
}
