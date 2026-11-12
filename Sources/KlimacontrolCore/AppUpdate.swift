import Foundation

/// Updates der App: Mac über Sparkle, Windows über WinSparkle. Beide lesen je eine Update-Datei, der als Datei an jedem
/// GitHub-Release hängt; `releases/latest/download/…` zeigt immer auf das neueste Release. Die Archive sind mit
/// EdDSA signiert (öffentlicher Schlüssel in `tools/UPDATE_PUBLIC_KEY`, privater nur im Schlüsselbund des Bauenden).
public enum AppUpdate {
    public static let repository = "https://github.com/mlafx/Klimacontrol"
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
    /// Standard: automatisch einmal am Tag suchen (`SUScheduledCheckInterval` in der Info.plist).
    public static let checkInterval = UpdateInterval.daily.seconds
    /// Gesucht und geladen wird immer; „Updates automatisch installieren“ ist Standard. Aus: Installation erst nach
    /// „Jetzt installieren“, nie still beim Beenden. Ein Überspringen gibt es in keinem Fall.
    public static let autoInstallDefault = true
    /// Abstand der Erinnerung an ein geladenes, noch nicht installiertes Update nach „Später“.
    public static let reminderInterval: TimeInterval = 24 * 3600

    public static func autoInstall(stored: Any?) -> Bool { stored as? Bool ?? autoInstallDefault }

    /// Nächste Erinnerung nach „Später“.
    public static func nextReminder(after answer: Date) -> Date { answer.addingTimeInterval(reminderInterval) }

    /// Ob der Hinweis zu einem geladenen Update jetzt erscheint; nil = noch nie gefragt.
    public static func reminderDue(now: Date, remindAt: Date?) -> Bool {
        guard let remindAt else { return true }
        return now >= remindAt
    }

    /// Ohne automatische Installation: Ob ein gefundenes Update jetzt geladen und angeboten wird. Eine vom Nutzer
    /// angestoßene Suche bietet es immer an, sonst erst, wenn die Erinnerung fällig ist.
    public static func offersUpdate(userInitiated: Bool, now: Date, remindAt: Date?) -> Bool {
        userInitiated || reminderDue(now: now, remindAt: remindAt)
    }
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

/// Einstellung „Nach Updates suchen“ (`SettingsKey.updateInterval`).
public enum UpdateInterval: String, CaseIterable, Sendable {
    case daily, weekly

    public var seconds: Int {
        switch self {
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }

    /// Unbekannte oder fehlende Werte gelten als täglich.
    public init(stored: Any?) {
        self = (stored as? String).flatMap(UpdateInterval.init(rawValue:)) ?? .daily
    }
}
