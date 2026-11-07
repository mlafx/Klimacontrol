import Foundation

/// Einmaliges Eintragen als Anmeldeobjekt beim ersten Start (Mac). Reine Entscheidung, ohne Systemaufruf.
public enum LoginItemDefault {
    public enum Decision: Equatable, Sendable {
        /// Eintragen und Merker setzen.
        case register
        /// Nichts tun, beim nächsten Start erneut prüfen.
        case wait
        /// Entscheidung ist schon gefallen.
        case none
    }

    /// - applied: Der Merker `SettingsKey.loginItemDefaultOn` ist gesetzt.
    /// - installed: Die App liegt in einem Programme-Ordner (`isInstalledLocation`).
    /// Gilt auch für bestehende Einrichtungen: Der erste Start aus „Programme“ trägt einmal ein.
    public static func decide(applied: Bool, installed: Bool) -> Decision {
        if applied { return .none }
        return installed ? .register : .wait
    }

    /// `/Applications/…` oder `<home>/Applications/…`; nie aus einem DMG (`/Volumes/…`), einer App-Translocation
    /// oder dem Build-Ordner.
    public static func isInstalledLocation(_ bundlePath: String, home: String) -> Bool {
        if bundlePath.contains("/AppTranslocation/") { return false }
        var roots = ["/Applications/"]
        if !home.isEmpty { roots.append(home.hasSuffix("/") ? home + "Applications/" : home + "/Applications/") }
        return roots.contains { bundlePath.hasPrefix($0) }
    }
}
