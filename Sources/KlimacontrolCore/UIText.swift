import Foundation
import MideaKit

/// Wörter, die je Rechnerart wechseln (Mac · Windows); alles andere an den Texten ist gleich.
public struct HostWords: Equatable, Sendable {
    /// „Mac“ bzw. „Rechner“ (Einrichtung, Sicherung).
    public let computer: String
    /// Wo Passwörter liegen, im Dativ: „dem Schlüsselbund“ bzw. „der Anmeldeinformationsverwaltung“.
    public let credentialStoreDative: String
    /// Satz zum Passwort bei Midea-Konto.
    public let passwordStorage: String
    /// Was „Neu einrichten“ mit der Einrichtungsdatei macht (Mac: Papierkorb, Windows: umbenannt im Datenordner).
    public let setAsideDevice: String
    /// Erklärung zu den Updates (Mac installiert still, Windows fragt vor der Installation).
    public let updatesHelp: String

    public static let mac = HostWords(
        computer: "Mac",
        credentialStoreDative: "dem Schlüsselbund",
        passwordStorage: "Das Passwort wird nur im macOS-Schlüsselbund gespeichert, damit sich Klimacontrol neu anmelden kann. "
            + "Es verlässt den Mac nur zur Anmeldung bei Midea.",
        setAsideDevice: "Die Einrichtungsdatei kommt unverändert in den Papierkorb – Token und Schlüssel liegen danach im "
            + "Papierkorb (wer ihn leert, verliert sie).",
        updatesHelp: "Updates werden automatisch geladen und installiert. Klimacontrol startet danach kurz neu.")
    public static let windows = HostWords(
        computer: "Rechner",
        credentialStoreDative: "der Anmeldeinformationsverwaltung",
        passwordStorage: "Das Passwort wird nur in der Windows-Anmeldeinformationsverwaltung gespeichert, damit sich "
            + "Klimacontrol neu anmelden kann. Es verlässt den Rechner nur zur Anmeldung bei Midea.",
        setAsideDevice: "Die Einrichtungsdatei wird nicht gelöscht, sondern unverändert im Datenordner beiseitegelegt. "
            + "Token und Schlüssel bleiben in der Datei erhalten, bis du sie selbst löschst.",
        updatesHelp: "Klimacontrol sucht täglich nach Updates und fragt vor der Installation.")

    public static var current: HostWords {
        #if os(Windows)
        return .windows
        #else
        return .mac
        #endif
    }
}

/// Rückfrage mit zwei Antworten; `confirm` ist die Antwort, die weitermacht.
public struct ConfirmPrompt: Equatable, Sendable {
    public let title: String
    public let message: String
    public let cancel: String
    public let confirm: String
    /// Warnung (Warnsymbol) statt Frage.
    public let warning: Bool
}

/// Hinweis mit nur einem „OK“ (Titel und Text).
public struct NoticeText: Equatable, Sendable {
    public let title: String
    public let message: String
}

/// Rückfrage „Anlage neu einrichten?“ mit drei Antworten. `backup` („Erst sichern …“) ist der Standard bei Enter;
/// danach fragt die Oberfläche erneut.
public struct ForgetPrompt: Equatable, Sendable {
    public let title: String
    public let message: String
    public let backup: String
    public let confirm: String
    public let cancel: String
    /// Zugangsdaten noch nicht gesichert: Warnung statt Frage.
    public let warning: Bool
}

/// Ergebnis einer Aktion (Sicherung, Export …) mit fertigem Text für die Rückmeldung am Ort der Aktion.
public struct ResultMessage: Equatable, Sendable {
    public let ok: Bool
    public let message: UserMessage
    public var text: String { message.text }

    static func ok(_ text: String) -> ResultMessage { ResultMessage(ok: true, message: UserMessage(what: text, todo: "")) }

    static func failed(what: String, todo: String = "", code: String? = nil) -> ResultMessage {
        ResultMessage(ok: false, message: UserMessage(what: what, todo: todo, code: code))
    }
}

/// Texte und Rückfragen zu Sicherung, Verlauf-Export, Einrichtung, Beenden und Konto – für beide Oberflächen.
public enum UIText {
    // MARK: Updates

    public static func updatesHelp(host: HostWords = .current) -> String { host.updatesHelp }
    public static let updatesChecking = "Suche nach Updates …"
    public static let updatesCurrent = "Klimacontrol ist auf dem neuesten Stand."
    public static func updatesInstalling(version: String) -> String {
        "Version \(version) wird geladen und installiert. Klimacontrol startet danach neu."
    }
    public static let updatesFailed = "Die Suche nach Updates hat nicht geklappt. Später erneut versuchen."
    public static let updatesCheckButton = "Jetzt suchen …"

    // MARK: Neu in dieser Version

    public static func whatsNewTitle(version: String) -> String { "Neu in Klimacontrol \(version)" }
    public static func whatsNewVersionHeading(_ version: String) -> String { "Version \(version)" }
    public static let whatsNewOK = "OK"

    // MARK: Sicherung einlesen

    public static let importPanelTitle = "Sicherung einlesen"
    public static let importPanelMessage = "Sicherungsdatei mit Token und Schlüssel der Anlage"
    public static let exportBackupPanelTitle = "Zugangsdaten sichern"
    public static let exportBackupPanelMessage = "Enthält Token und Schlüssel deiner Anlage – nicht in Cloud-Ordnern ablegen."
    public static let exportBackupFileName = "Klimacontrol-Sicherung.json"
    public static let exportHistoryPanelTitle = "Verlauf exportieren"
    public static let exportHistoryFileName = "Klimacontrol-Verlauf.csv"
    public static let importAlertTitle = "Sicherung eingelesen"
    public static let notBackedUpTitle = "Nicht gesichert"

    public static let replaceScenesPrompt = ConfirmPrompt(
        title: "Szenen ersetzen?",
        message: "Es gibt schon Szenen. Sollen sie durch die Szenen aus der Sicherung ersetzt werden?",
        cancel: "Behalten", confirm: "Ersetzen", warning: false)

    public static func otherDevicePrompt(backup: String, current: String) -> ConfirmPrompt {
        ConfirmPrompt(
            title: "Andere Anlage einrichten?",
            message: "Die Sicherung gehört zu „\(backup)“, eingerichtet ist „\(current)“. "
                + "Beim Wechsel kommt die bisherige Einrichtung in den Papierkorb.",
            cancel: "Abbrechen", confirm: "Anlage wechseln", warning: true)
    }

    /// „Nur Cloud (unterwegs)“ gewählt, ohne dass ein Midea-Konto angemeldet ist.
    public static let cloudNeedsAccount = NoticeText(
        title: "Midea-Konto fehlt",
        message: "Dieser Weg geht nur mit Midea-Konto. Bitte zuerst unten beim Midea-Konto anmelden.")

    // MARK: Neu einrichten

    /// `needsBackup`: Die Anlage hat WLAN-Zugangsdaten, die noch nicht gesichert sind.
    public static func forgetPrompt(needsBackup: Bool, host: HostWords = .current) -> ForgetPrompt {
        var message = host.setAsideDevice + " Die Sitzung beim Midea-Konto endet. "
            + "Danach sucht Klimacontrol neu – im WLAN oder über das Midea-Konto."
        if needsBackup {
            message += "\n\nDie Zugangsdaten sind noch nicht gesichert. Mit „Erst sichern …“ lässt sich die Anlage später "
                + "ohne neue Suche wieder einrichten."
        }
        return ForgetPrompt(title: "Anlage neu einrichten?", message: message, backup: "Erst sichern …",
                            confirm: "Neu einrichten", cancel: "Abbrechen", warning: needsBackup)
    }

    /// Sicherung eingelesen. `verified == false`: die Anlage antwortete nicht – das ist ein Hinweis, kein Erfolg.
    public static func backupImported(_ r: BackupImportResult, ip: String) -> ResultMessage {
        var parts: [String] = []
        switch r.verified {
        case true?: parts.append("Sicherung eingelesen, die Anlage nimmt die Zugangsdaten an.")
        case false?:
            return .failed(what: "Sicherung eingelesen, aber die Anlage antwortet nicht\(ip.isEmpty ? "" : " unter \(ip)").",
                           todo: "Ist sie eingeschaltet? Hat sie eine neue Adresse, hilft „Adresse neu suchen“ unter "
                               + "Einstellungen → Anlage.")
        case nil: parts.append("Sicherung eingelesen.")
        }
        if r.scenesImported > 0 { parts.append("\(r.scenesImported) Szenen übernommen.") }
        if r.scenesSkipped > 0 { parts.append("Die vorhandenen Szenen bleiben.") }
        return .ok(parts.joined(separator: " "))
    }

    /// Sicherung nicht eingelesen. Fehler der Sicherung selbst tragen ihren Text, alles andere die Rückfrage nach der Datei.
    public static func backupImportFailed(_ error: any Error) -> ResultMessage {
        if let e = error as? BackupImportError, let text = e.errorDescription { return split(text) }
        return .failed(what: "Die Sicherung ließ sich nicht einlesen.", todo: "Ist es die richtige Datei?",
                       code: error.localizedDescription)
    }

    // MARK: Sicherung und Verlauf speichern

    public static func backupExported(fileName: String) -> ResultMessage { .ok("Gesichert als „\(fileName)“.") }

    public static func backupExportFailed(_ error: any Error) -> ResultMessage {
        .failed(what: "Die Sicherung ließ sich nicht speichern.", todo: "Anderen Ort wählen?", code: error.localizedDescription)
    }

    public static func historyExported(fileName: String) -> ResultMessage { .ok("Verlauf gespeichert als „\(fileName)“.") }

    public static func historyExportFailed(_ error: any Error) -> ResultMessage {
        .failed(what: "Der Verlauf ließ sich nicht speichern.", todo: "Anderen Ort wählen?", code: error.localizedDescription)
    }

    /// Rückfrage vor dem Sichern in einen Cloud-Ordner (`folder` = Name des Ordners).
    public static func cloudFolderPrompt(folder: String) -> ConfirmPrompt {
        ConfirmPrompt(
            title: "In einem Cloud-Ordner sichern?",
            message: "„\(folder)“ wird mit einem Cloud-Dienst abgeglichen. Mit Token und Schlüssel lässt sich die Anlage "
                + "steuern – besser lokal oder auf einem USB-Stick ablegen.",
            cancel: "Anderen Ort wählen", confirm: "Trotzdem sichern", warning: true)
    }

    /// Pfadteile (mit `/` geschrieben), an denen ein Cloud-Ordner zu erkennen ist.
    public static let cloudFolderMarkers = ["/CloudStorage/", "/Mobile Documents/", "/OneDrive", "/Dropbox/", "/Google Drive/", "iCloud"]

    /// Liegt der Ort in einem Cloud-Ordner (iCloud, OneDrive, Dropbox, Google Drive)? Pfad mit `/` oder `\`.
    public static func isCloudFolder(path: String) -> Bool {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        return cloudFolderMarkers.contains { p.contains($0) }
    }

    /// Hinweis, wenn eine Sicherung schon in einem Cloud-Ordner liegt (kein Hinweis zusätzlich zur Rückfrage nötig).
    public static let cloudFolderNotice = UserMessage(
        what: "Die Sicherung liegt in einem Cloud-Ordner und enthält Token und Schlüssel der Anlage.",
        todo: "Lege sie besser in einen Ordner nur auf diesem Rechner.")

    // MARK: Einrichtung abgeschlossen

    public static let setupDoneTitle = "Anlage eingerichtet"
    public static let setupBackupTitle = "Zugangsdaten jetzt sichern?"
    public static let setupLANOnlyChoice = "Nur WLAN nutzen (nie über die Midea-Server)"

    /// Fenster nach gelungener Einrichtung: Titel, Absätze, Knöpfe und das Häkchen „Nur WLAN“. nil = nichts anzubieten.
    public struct SetupDonePrompt: Equatable, Sendable {
        public let title: String
        public let paragraphs: [String]
        public let lanOnlyChoice: String?
        public let primary: String
        public let secondary: String?
    }

    public static func setupDonePrompt(_ c: SetupCompletion, host: HostWords = .current) -> SetupDonePrompt? {
        guard c.offerBackup || c.suggestLANOnly else { return nil }
        var paragraphs = [c.note]
        if c.offerBackup {
            paragraphs.append("Ohne Midea-Konto liegen Token und Schlüssel nur auf diesem \(host.computer). "
                              + "Eine Sicherung braucht es für einen anderen Rechner oder nach „Neu einrichten“.")
        }
        return SetupDonePrompt(title: c.offerBackup ? setupBackupTitle : setupDoneTitle,
                               paragraphs: paragraphs.filter { !$0.isEmpty },
                               lanOnlyChoice: c.suggestLANOnly ? setupLANOnlyChoice : nil,
                               primary: c.offerBackup ? "Sichern …" : "OK", secondary: c.offerBackup ? "Später" : nil)
    }

    // MARK: Konto

    public static let accountSignedIn = "Angemeldet und gespeichert."
    public static let accountRemoved = "Midea-Konto und Passwort entfernt."

    public static func accountRemovePrompt(host: HostWords = .current) -> ConfirmPrompt {
        ConfirmPrompt(
            title: "Midea-Konto entfernen?",
            message: "Konto und Passwort werden aus \(host.credentialStoreDative) gelöscht, unterwegs ist die Anlage dann "
                + "nicht mehr erreichbar. Das Konto lässt sich jederzeit wieder anmelden.",
            cancel: "Abbrechen", confirm: "Entfernen", warning: true)
    }

    public static func accountFooter(signedIn: Bool, host: HostWords = .current) -> String {
        signedIn
            ? "Angemeldet. Bei „Automatisch“ springt das Midea-Konto ein, wenn WLAN nicht geht. " + host.passwordStorage
            : "Optional. " + host.passwordStorage
    }

    /// Wer ein Konto anmeldet, will es auch nutzen: „Nur WLAN“ würde es nie fragen, darum wird daraus „Automatisch“.
    public static func modeAfterAccountLogin(_ mode: ConnectionMode) -> ConnectionMode { mode == .lan ? .auto : mode }

    // MARK: Selbstreinigung

    public static let selfCleanPrompt = ConfirmPrompt(
        title: "Selbstreinigung starten?",
        message: "Dauert etwa 15 Minuten. Die Anlage macht dabei ungewöhnliche Geräusche, es kann Dampf austreten – das ist normal.",
        cancel: "Abbrechen", confirm: "Starten", warning: false)

    // MARK: Beenden mit Timern

    /// Rückfrage beim Beenden; nil ohne gestellten Timer. `off`/`on` = Zeitpunkte der Timer.
    public static func quitPrompt(off: Date?, on: Date?, now: Date) -> ConfirmPrompt? {
        var timers: [String] = []
        if let off { timers.append("„Aus“ \(dayLabel(off, now: now)) um \(ACController.clock(off))") }
        if let on { timers.append("„Ein“ \(dayLabel(on, now: now)) um \(ACController.clock(on))") }
        guard !timers.isEmpty else { return nil }
        return ConfirmPrompt(
            title: "Klimacontrol beenden?",
            message: "Timer \(timers.joined(separator: " und ")) ist gestellt. Er schaltet nur, solange Klimacontrol geöffnet ist.",
            cancel: "Geöffnet lassen", confirm: "Trotzdem beenden", warning: false)
    }

    /// „heute“, „morgen“ oder „am Mi. 6.11.“ (Wochentag mit Punkt, Tag ohne, Monat mit führender Null).
    static func dayLabel(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "heute" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) { return "morgen" }
        let names = ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."]
        let c = cal.dateComponents([.weekday, .day, .month], from: date)
        return "am \(names[((c.weekday ?? 1) - 1 + 7) % 7]) \(c.day ?? 0).\(ACController.pad(c.month ?? 0, 2))."
    }

    // MARK: Verbindung (Einstellungen)

    public static func wayHelp(_ mode: ConnectionMode) -> String {
        switch mode {
        case .auto: return "Erst WLAN, dann über das Midea-Konto – empfohlen."
        case .lan: return "Nur im selben WLAN. Nutzt nie die Midea-Server und braucht kein Internet."
        case .cloud: return "Über die Midea-Server, auch unterwegs – langsamer."
        }
    }

    // MARK: Startanzeige

    public struct ConnectStep: Equatable, Sendable {
        public let phase: ConnectPhase
        public let name: String
    }

    public static let connectSteps: [ConnectStep] = [
        ConnectStep(phase: .searching, name: "Anlage suchen"), ConnectStep(phase: .handshake, name: "Anmelden"),
        ConnectStep(phase: .reading, name: "Werte lesen"),
    ]
    public static let connectSlowText = "Dauert länger als üblich."
    public static let retryButton = "Erneut versuchen"

    /// „Anlage suchen ✓ · Anmelden … · Werte lesen“ – erledigte mit Haken, laufender mit „…“; ohne Schritt der erste.
    public static func connectStepsLine(_ phase: ConnectPhase?) -> String {
        let current = phase.flatMap { p in connectSteps.firstIndex { $0.phase == p } } ?? 0
        return connectSteps.enumerated().map { i, step in
            i < current ? "\(step.name) ✓" : i == current ? "\(step.name) …" : step.name
        }.joined(separator: " · ")
    }

    // MARK: Diagnose

    public static func errorCodeValue(_ code: Int) -> String { code == 0 ? "keiner" : "Code \(code) – siehe Bedienungsanleitung" }
    public static func filterValue(alert: Bool) -> String { alert ? "reinigen" : "in Ordnung" }

    /// Ruhige Hinweise zu Störung und Filter (leer, solange alles in Ordnung ist).
    public static func maintenanceHints(filterAlert: Bool, errorCode: Int) -> [String] {
        var out: [String] = []
        if errorCode != 0 {
            out.append("Die Anlage meldet eine Störung. Bedeutung und Abhilfe stehen in der Bedienungsanleitung (Code \(errorCode)).")
        }
        if filterAlert {
            out.append("Filter reinigen: Die Anlage bittet um eine Filterreinigung (siehe Bedienungsanleitung).")
        }
        return out
    }

    // MARK: Aus und Lüften (große Zahl)

    public static let offCaption = "Raumtemperatur · Anlage aus"
    public static let offHint = "Einschalten mit dem Knopf oben oder direkt einen Modus bzw. eine Szene wählen."
    public static let fanModeCaption = "Raumtemperatur · Lüften ohne Zieltemperatur"
    public static let notConfiguredCaption = "Nicht eingerichtet"

    // MARK: Hilfsfunktionen

    /// Teilt einen fertigen Satz „Was ist passiert. Was tun.“ nach dem ersten Satzende in `what` und `todo`.
    static func split(_ text: String) -> ResultMessage {
        guard let r = text.range(of: ". ") else { return .failed(what: text) }
        return .failed(what: String(text[..<r.lowerBound]) + ".", todo: String(text[r.upperBound...]))
    }
}
