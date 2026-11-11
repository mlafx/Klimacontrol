import Foundation

/// Updates der App: Mac über Sparkle, Windows über WinSparkle. Beide lesen je eine Update-Datei, der als Datei an jedem
/// GitHub-Release hängt; `releases/latest/download/…` zeigt immer auf das neueste Release. Die Archive sind mit
/// EdDSA signiert (öffentlicher Schlüssel in `tools/UPDATE_PUBLIC_KEY`, privater nur im Schlüsselbund des Bauenden).
public enum AppUpdate {
    public static let repository = "https://github.com/mlafx/Klimacontrol"
    public static let releasesPage = repository + "/releases"
    public static let feedMac = repository + "/releases/latest/download/updateinfo-mac.xml"
    /// Beta-Kanal (nur Mac): feste Update-Datei am Vorabrelease „beta“, nie unter latest.
    public static let feedMacBeta = repository + "/releases/download/beta/updateinfo-mac-beta.xml"
    public static func feedMac(beta: Bool) -> String { beta ? feedMacBeta : feedMac }
    /// Adresse, die der Mac-Updater statt `SUFeedURL` liest; nil = Info.plist. Die Testumleitung geht immer vor.
    /// `stableFallback`: Die Beta-Datei war nicht lesbar (es gibt sie erst mit der ersten Beta), die Suche läuft
    /// einmal im stabilen Kanal.
    public static func macFeedOverride(beta: Bool, testFeed: String?, stableFallback: Bool) -> String? {
        if let test = testFeedOverride(testFeed) { return test }
        return beta && !stableFallback ? feedMacBeta : nil
    }

    /// Ob eine gescheiterte Suche einmal im stabilen Kanal wiederholt wird: nur, wenn sie die Beta-Datei las, noch kein
    /// Update gefunden hatte und nicht bloß „kein Update“ meldete. Fehler beim Laden oder Installieren eines gefundenen
    /// Updates zählen nicht.
    public static func fallsBackToStable(betaFeedUsed: Bool, updateFound: Bool, noUpdate: Bool) -> Bool {
        betaFeedUsed && !updateFound && !noUpdate
    }

    public static let feedWindows = repository + "/releases/latest/download/updateinfo-win.xml"
    /// Standard: automatisch einmal am Tag suchen.
    public static let checkInterval = 86_400
    /// Updates werden immer automatisch geladen und installiert; es gibt kein Überspringen und kein Abschalten.
    public static let installsAutomatically = true
    /// Erste Version, die Updates selbst still installiert. Ältere zeigen das Update im Standarddialog; als
    /// „kritisch“ markiert (Appcast) bietet er dort kein Überspringen an.
    public static let firstAutoInstallVersion = "1.1.0.0"

    /// Nur für die Update-Prüfungen vor dem Release (D3): `KLIMACONTROL_UPDATE_TEST_FEED` darf die Update-Datei auf einen
    /// lokalen Server umbiegen, auch im Beta-Kanal. Nur `http://127.0.0.1:<Port>/…`; jeder andere Wert bleibt wirkungslos.
    public static let testFeedVariable = "KLIMACONTROL_UPDATE_TEST_FEED"
    public static func testFeedOverride(_ value: String?) -> String? {
        guard let value, let m = value.wholeMatch(of: /http:\/\/127\.0\.0\.1:([0-9]{1,5})\/[A-Za-z0-9._\/-]*/),
              let port = Int(m.1), (1...65535).contains(port) else { return nil }
        return value
    }
}
