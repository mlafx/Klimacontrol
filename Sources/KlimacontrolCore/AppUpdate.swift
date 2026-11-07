import Foundation

/// Updates der App: Mac über Sparkle, Windows über WinSparkle. Beide lesen je eine Update-Datei, der als Datei an jedem
/// GitHub-Release hängt; `releases/latest/download/…` zeigt immer auf das neueste Release. Die Archive sind mit
/// EdDSA signiert (öffentlicher Schlüssel in `tools/UPDATE_PUBLIC_KEY`, privater nur im Schlüsselbund des Bauenden).
public enum AppUpdate {
    public static let repository = "https://github.com/mlafx/Klimacontrol"
    public static let releasesPage = repository + "/releases"
    public static let feedMac = repository + "/releases/latest/download/updateinfo-mac.xml"
    public static let feedWindows = repository + "/releases/latest/download/updateinfo-win.xml"
    /// Standard: automatisch einmal am Tag suchen.
    public static let checkInterval = 86_400
    /// Updates werden immer automatisch geladen und installiert; es gibt kein Überspringen und kein Abschalten.
    public static let installsAutomatically = true
    /// Erste Version, die Updates selbst still installiert. Ältere zeigen das Update im Standarddialog; als
    /// „kritisch“ markiert (Appcast) bietet er dort kein Überspringen an.
    public static let firstAutoInstallVersion = "1.0.1.0"
}
