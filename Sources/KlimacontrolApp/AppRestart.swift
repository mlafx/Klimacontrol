import AppKit
import KlimacontrolCore
import MideaKit

/// Neustart der App (Sprachwechsel, geladenes Update) und die Sprachwahl dieser App in `AppleLanguages`.
@MainActor
enum AppRestart {
    /// Timer sind gespeichert und laufen nach dem Neustart weiter; die Rückfrage beim Beenden entfällt dann.
    static var skipQuitPrompt = false

    private static let languagesKey = "AppleLanguages"

    /// Wahl, mit der die App gestartet wurde (der erste Zugriff geschieht in `KlimacontrolApp.init`).
    static let startChoice = storedChoice()

    /// Nur die Domäne dieser App, nicht die globale Liste, die `UserDefaults.array(forKey:)` mit liefert.
    static func storedChoice() -> LanguageChoice {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return LanguageChoice(appleLanguages: domain?[languagesKey] as? [String])
    }

    static func store(_ choice: LanguageChoice) {
        if let languages = choice.appleLanguages {
            UserDefaults.standard.set(languages, forKey: languagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: languagesKey)
        }
        AppLog.write(L.Log.Settings.languageAfterRestart(value: choice.rawValue))
    }

    /// Nur im fertigen Bundle; bei `swift run` gäbe es nichts, was sich neu öffnen ließe.
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func relaunch() {
        if AppUpdater.shared.hasPendingInstall {
            AppUpdater.shared.installNow()
            return
        }
        guard canRelaunch else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Pfad und Prozessnummer als Argumente ($1, $2), nie in den Befehlstext eingesetzt.
        helper.arguments = ["-c", "while /bin/kill -0 \"$2\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                            "klimacontrol-relaunch", Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            AppLog.error(L.Log.App.restartNotPossible(error: error.localizedDescription))
            return
        }
        AppLog.write(L.Log.App.restart)
        skipQuitPrompt = true
        NSApp.terminate(nil)
    }
}
