import Foundation

// Darstellung (Reiter „Darstellung“): gespeichert als JSON-Text unter `SettingsKey.appearance`, sofort wirksam.
extension ACController {
    /// Gespeicherte Darstellung lesen (Text oder Daten); fehlt sie oder ist sie kaputt → Standard, nie ein Fehler.
    static func loadAppearance(from settings: any SettingsStore) -> Appearance {
        switch settings.object(forKey: SettingsKey.appearance) {
        case let text as String: Appearance.decode(text)
        case let data as Data: Appearance.decode(data)
        default: .standard
        }
    }

    /// Ganze Darstellung setzen (Live-Vorschau: jede Reglerbewegung). Werte werden geklemmt; gleicher Wert = nichts.
    public func setAppearance(_ new: Appearance) {
        let value = new.clamped()
        guard value != appearance else { return }
        appearance = value
        if value == .standard {
            settings.removeObject(forKey: SettingsKey.appearance)
        } else {
            settings.set(value.json, forKey: SettingsKey.appearance)
        }
    }

    /// Thema anwenden: setzt dessen Aussehens-Werte, Aufbau und Menüleisten-Text bleiben (`Appearance.applying`).
    public func applyTheme(_ theme: Appearance.Theme) {
        setAppearance(appearance.applying(theme))
    }

    /// „Auf Standard zurücksetzen“.
    public func resetAppearance() {
        setAppearance(.standard)
    }
}
