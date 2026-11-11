import Foundation
import MideaKit

/// Wörter, die je Rechnerart wechseln (Mac · Windows); alles andere an den Texten ist gleich.
public struct HostWords: Equatable, Sendable {
    /// „Mac“ bzw. „Rechner“ / „computer“ (Einrichtung, Sicherung).
    public let computer: String
    /// Wo Passwörter liegen, im Satz nach „aus“: „dem Schlüsselbund“ bzw. „der Anmeldeinformationsverwaltung“.
    public let credentialStoreDative: String
    /// Satz zum Passwort bei Midea-Konto.
    public let passwordStorage: String
    /// Was „Neu einrichten“ mit der Einrichtungsdatei macht (Mac: Papierkorb, Windows: umbenannt im Datenordner).
    public let setAsideDevice: String
    /// Erklärung zu den Updates (Mac installiert still, Windows fragt vor der Installation).
    public let updatesHelp: String
    /// Windows statt Mac: wählt Texte, die den Schlüsselbund bzw. die Anmeldeinformationsverwaltung nennen.
    public let isWindows: Bool

    public static var mac: HostWords {
        HostWords(computer: L.Host.Mac.computer, credentialStoreDative: L.Host.Mac.credentialStore,
                  passwordStorage: L.Host.Mac.passwordStorage, setAsideDevice: L.Host.Mac.setAsideDevice,
                  updatesHelp: L.Host.Mac.updatesHelp, isWindows: false)
    }
    public static var windows: HostWords {
        HostWords(computer: L.Host.Windows.computer, credentialStoreDative: L.Host.Windows.credentialStore,
                  passwordStorage: L.Host.Windows.passwordStorage, setAsideDevice: L.Host.Windows.setAsideDevice,
                  updatesHelp: L.Host.Windows.updatesHelp, isWindows: true)
    }

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
    public static var updatesChecking: String { L.Updates.checking }
    public static var updatesCurrent: String { L.Updates.current }
    public static func updatesInstalling(version: String) -> String { L.Updates.installing(version: version) }
    public static var updatesFailed: String { L.Updates.failed }
    public static var updatesManualCurrentTitle: String { L.Updates.Manual.Current.title }
    public static func updatesManualCurrentMessage(version: String) -> String { L.Updates.Manual.Current.message(version: version) }
    public static var updatesManualFailedTitle: String { L.Updates.Manual.Failed.title }
    public static var updatesManualFailedMessage: String { L.Updates.Manual.Failed.message }
    public static var updatesCheckButton: String { L.Updates.checkButton }

    // MARK: Hauptfenster (Spalten)

    public static var columnControls: String { L.Main.Column.controls }
    public static var columnHistory: String { L.Main.Footer.history }
    public static var columnDiagnostics: String { L.Main.Footer.diagnostics }
    public static func columnName(_ c: MainWindowLayout.Column) -> String {
        c == .history ? columnHistory : columnDiagnostics
    }
    /// Ansage, wenn eine Seitenspalte wegen zu schmalem Bildschirm ausgeblendet wird.
    public static func columnHidden(_ c: MainWindowLayout.Column) -> String { L.Main.Column.hidden(column: columnName(c)) }

    // MARK: Neu in dieser Version

    public static func whatsNewTitle(version: String) -> String { L.WhatsNew.title(version: version) }
    public static func whatsNewVersionHeading(_ version: String) -> String { L.WhatsNew.versionHeading(version: version) }
    public static var whatsNewOK: String { L.WhatsNew.ok }
    public static var whatsNewGermanOnly: String { L.WhatsNew.germanOnly }

    // MARK: Sicherung einlesen

    public static var importPanelTitle: String { L.File.importPanelTitle }
    public static var importPanelMessage: String { L.File.importPanelMessage }
    public static var exportBackupPanelTitle: String { L.File.exportBackupTitle }
    public static var exportBackupPanelMessage: String { L.File.exportBackupMessage }
    public static var exportBackupFileName: String { L.File.backupFileName }
    public static var exportHistoryPanelTitle: String { L.File.exportHistoryTitle }
    public static var exportHistoryFileName: String { L.File.historyFileName }
    public static var importAlertTitle: String { L.File.importAlertTitle }
    public static var notBackedUpTitle: String { L.File.notBackedUpTitle }

    public static var replaceScenesPrompt: ConfirmPrompt {
        ConfirmPrompt(title: L.Prompt.ReplaceScenes.title, message: L.Prompt.ReplaceScenes.message,
                      cancel: L.Prompt.ReplaceScenes.cancel, confirm: L.Prompt.ReplaceScenes.confirm, warning: false)
    }

    public static func otherDevicePrompt(backup: String, current: String) -> ConfirmPrompt {
        ConfirmPrompt(
            title: L.Prompt.OtherDevice.title,
            message: L.Prompt.OtherDevice.message(backup: backup, current: current),
            cancel: L.Common.cancel, confirm: L.Prompt.OtherDevice.confirm, warning: true)
    }

    /// „Nur Cloud (unterwegs)“ gewählt, ohne dass ein Midea-Konto angemeldet ist.
    public static var cloudNeedsAccount: NoticeText {
        NoticeText(title: L.Prompt.CloudNeedsAccount.title, message: L.Prompt.CloudNeedsAccount.message)
    }

    // MARK: Neu einrichten

    /// `needsBackup`: Die Anlage hat WLAN-Zugangsdaten, die noch nicht gesichert sind.
    public static func forgetPrompt(needsBackup: Bool, host: HostWords = .current) -> ForgetPrompt {
        let message = needsBackup
            ? L.Prompt.Forget.messageNeedsBackup(setAside: host.setAsideDevice)
            : L.Prompt.Forget.message(setAside: host.setAsideDevice)
        return ForgetPrompt(title: L.Prompt.Forget.title, message: message, backup: L.Prompt.Forget.backup,
                            confirm: L.Prompt.Forget.confirm, cancel: L.Common.cancel, warning: needsBackup)
    }

    /// Sicherung eingelesen. `verified == false`: die Anlage antwortete nicht – das ist ein Hinweis, kein Erfolg.
    public static func backupImported(_ r: BackupImportResult, ip: String) -> ResultMessage {
        var parts: [String] = []
        switch r.verified {
        case true?: parts.append(L.Result.backupRestoredVerified)
        case false?:
            return .failed(what: ip.isEmpty ? L.Result.backupRestoredNoReply : L.Result.backupRestoredNoReplyAt(ip: ip),
                           todo: L.Result.backupRestoredNoReplyTodo)
        case nil: parts.append(L.Result.backupRestored)
        }
        if r.scenesImported > 0 { parts.append(L.Result.scenesImported(count: r.scenesImported)) }
        if r.scenesSkipped > 0 { parts.append(L.Result.scenesKept) }
        return .ok(parts.joined(separator: " "))
    }

    /// Sicherung nicht eingelesen. Fehler der Sicherung selbst tragen ihren Text, alles andere die Rückfrage nach der Datei.
    public static func backupImportFailed(_ error: any Error) -> ResultMessage {
        if let e = error as? BackupImportError, let text = e.errorDescription { return split(text) }
        return .failed(what: L.Result.ImportFailed.what, todo: L.Result.ImportFailed.todo,
                       code: error.localizedDescription)
    }

    // MARK: Sicherung und Verlauf speichern

    public static func backupExported(fileName: String) -> ResultMessage { .ok(L.Result.backupExported(name: fileName)) }

    public static func backupExportFailed(_ error: any Error) -> ResultMessage {
        .failed(what: L.Result.BackupExportFailed.what, todo: L.Result.saveFailedTodo, code: error.localizedDescription)
    }

    public static func historyExported(fileName: String) -> ResultMessage { .ok(L.Result.historyExported(name: fileName)) }

    public static func historyExportFailed(_ error: any Error) -> ResultMessage {
        .failed(what: L.Result.HistoryExportFailed.what, todo: L.Result.saveFailedTodo, code: error.localizedDescription)
    }

    /// Rückfrage vor dem Sichern in einen Cloud-Ordner (`folder` = Name des Ordners).
    public static func cloudFolderPrompt(folder: String) -> ConfirmPrompt {
        ConfirmPrompt(
            title: L.Prompt.CloudFolder.title, message: L.Prompt.CloudFolder.message(folder: folder),
            cancel: L.Prompt.CloudFolder.cancel, confirm: L.Prompt.CloudFolder.confirm, warning: true)
    }

    /// Pfadteile (mit `/` geschrieben), an denen ein Cloud-Ordner zu erkennen ist.
    public static let cloudFolderMarkers = ["/CloudStorage/", "/Mobile Documents/", "/OneDrive", "/Dropbox/", "/Google Drive/", "iCloud"]

    /// Liegt der Ort in einem Cloud-Ordner (iCloud, OneDrive, Dropbox, Google Drive)? Pfad mit `/` oder `\`.
    public static func isCloudFolder(path: String) -> Bool {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        return cloudFolderMarkers.contains { p.contains($0) }
    }

    /// Hinweis, wenn eine Sicherung schon in einem Cloud-Ordner liegt (kein Hinweis zusätzlich zur Rückfrage nötig).
    public static var cloudFolderNotice: UserMessage {
        UserMessage(what: L.File.CloudFolderNotice.what, todo: L.File.CloudFolderNotice.todo)
    }

    // MARK: Einrichtung abgeschlossen

    public static var setupDoneTitle: String { L.Prompt.SetupDone.title }
    public static var setupBackupTitle: String { L.Prompt.SetupDone.backupTitle }
    public static var setupLANOnlyChoice: String { L.Prompt.SetupDone.lanOnly }

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
        if c.offerBackup { paragraphs.append(L.Prompt.SetupDone.backupNote(computer: host.computer)) }
        return SetupDonePrompt(title: c.offerBackup ? setupBackupTitle : setupDoneTitle,
                               paragraphs: paragraphs.filter { !$0.isEmpty },
                               lanOnlyChoice: c.suggestLANOnly ? setupLANOnlyChoice : nil,
                               primary: c.offerBackup ? L.Prompt.SetupDone.backupButton : L.Common.ok,
                               secondary: c.offerBackup ? L.Prompt.SetupDone.later : nil)
    }

    // MARK: Konto

    public static var accountSignedIn: String { L.Account.signedIn }
    public static var accountRemoved: String { L.Account.removed }

    public static func accountRemovePrompt(host: HostWords = .current) -> ConfirmPrompt {
        ConfirmPrompt(
            title: L.Prompt.AccountRemove.title,
            message: L.Prompt.AccountRemove.message(store: host.credentialStoreDative),
            cancel: L.Common.cancel, confirm: L.Prompt.AccountRemove.confirm, warning: true)
    }

    public static func accountFooter(signedIn: Bool, host: HostWords = .current) -> String {
        signedIn
            ? L.Account.footerSignedIn(storage: host.passwordStorage)
            : L.Account.footerSignedOut(storage: host.passwordStorage)
    }

    /// Wer ein Konto anmeldet, will es auch nutzen: „Nur WLAN“ würde es nie fragen, darum wird daraus „Automatisch“.
    public static func modeAfterAccountLogin(_ mode: ConnectionMode) -> ConnectionMode { mode == .lan ? .auto : mode }

    // MARK: Selbstreinigung

    public static var selfCleanPrompt: ConfirmPrompt {
        ConfirmPrompt(title: L.Prompt.SelfClean.title, message: L.Prompt.SelfClean.message,
                      cancel: L.Common.cancel, confirm: L.Prompt.SelfClean.confirm, warning: false)
    }

    // MARK: Beenden mit Timern

    /// Rückfrage beim Beenden; nil ohne gestellten Timer. `off`/`on` = Zeitpunkte der Timer.
    public static func quitPrompt(off: Date?, on: Date?, now: Date) -> ConfirmPrompt? {
        let message: String
        switch (off, on) {
        case let (off?, on?):
            message = L.Prompt.Quit.messageBoth(offDay: dayLabel(off, now: now), offTime: ACController.clock(off),
                                                onDay: dayLabel(on, now: now), onTime: ACController.clock(on))
        case let (off?, nil):
            message = L.Prompt.Quit.messageOff(day: dayLabel(off, now: now), time: ACController.clock(off))
        case let (nil, on?):
            message = L.Prompt.Quit.messageOn(day: dayLabel(on, now: now), time: ACController.clock(on))
        case (nil, nil): return nil
        }
        return ConfirmPrompt(title: L.Prompt.Quit.title, message: message, cancel: L.Prompt.Quit.cancel,
                             confirm: L.Prompt.Quit.confirm, warning: false)
    }

    /// „heute“, „morgen“ oder „am Mi. 6.11.“ (Deutsch: Tag ohne, Monat mit führender Null) bzw. „on Wed 11/6“.
    static func dayLabel(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return DateWords.today }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return DateWords.tomorrow
        }
        return L.Timer.dayOn(weekday: DateWords.weekdayShort(cal.component(.weekday, from: date)),
                             date: dayMonthUnpaddedDay(date, calendar: cal))
    }

    /// Tag und Monat nach dem Muster des Profils, der Tag immer ohne führende Null.
    private static func dayMonthUnpaddedDay(_ d: Date, calendar: Calendar, profile: FormatProfile = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: d)
        let chars = Array(profile.dayMonthPattern)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" {
                i += 1
                while i < chars.count, chars[i] != "'" {
                    out.append(chars[i])
                    i += 1
                }
                i += 1
            } else if ch == "d" || ch == "M" || ch == "L" {
                var run = 0
                while i < chars.count, chars[i] == ch {
                    run += 1
                    i += 1
                }
                let value = ch == "d" ? (c.day ?? 0) : (c.month ?? 0)
                out += run == 1 || ch == "d" ? "\(value)" : ACController.pad(value, 2)
            } else {
                out.append(ch)
                i += 1
            }
        }
        return out
    }

    // MARK: Verbindung (Einstellungen)

    public static func wayHelp(_ mode: ConnectionMode) -> String {
        switch mode {
        case .auto: return L.Way.auto
        case .lan: return L.Way.lan
        case .cloud: return L.Way.cloud
        }
    }

    // MARK: Startanzeige

    public struct ConnectStep: Equatable, Sendable {
        public let phase: ConnectPhase
        public let name: String
    }

    public static var connectSteps: [ConnectStep] {
        [ConnectStep(phase: .searching, name: L.Startup.searching), ConnectStep(phase: .handshake, name: L.Startup.handshake),
         ConnectStep(phase: .reading, name: L.Startup.reading)]
    }
    public static var connectSlowText: String { L.Startup.slow }
    public static var retryButton: String { L.Startup.retry }

    /// „Anlage suchen ✓ · Anmelden … · Werte lesen“ – erledigte mit Haken, laufender mit „…“; ohne Schritt der erste.
    public static func connectStepsLine(_ phase: ConnectPhase?) -> String {
        let steps = connectSteps
        let current = phase.flatMap { p in steps.firstIndex { $0.phase == p } } ?? 0
        return steps.enumerated().map { i, step in
            i < current ? L.Startup.stepDone(name: step.name)
                : i == current ? L.Startup.stepCurrent(name: step.name) : step.name
        }.joined(separator: " · ")
    }

    // MARK: Diagnose

    public static func errorCodeValue(_ code: Int) -> String { code == 0 ? L.Diagnostics.errorNone : L.Diagnostics.errorCode(code: "\(code)") }
    public static func filterValue(alert: Bool) -> String { alert ? L.Diagnostics.filterClean : L.Diagnostics.filterOk }

    /// Ruhige Hinweise zu Störung und Filter (leer, solange alles in Ordnung ist).
    public static func maintenanceHints(filterAlert: Bool, errorCode: Int) -> [String] {
        var out: [String] = []
        if errorCode != 0 { out.append(L.Diagnostics.hintFault(code: "\(errorCode)")) }
        if filterAlert { out.append(L.Diagnostics.hintFilter) }
        return out
    }

    // MARK: Aus und Lüften (große Zahl)

    public static var offCaption: String { L.Hero.offCaption }
    public static var offHint: String { L.Hero.offHint }
    public static var fanModeCaption: String { L.Hero.fanModeCaption }
    public static var notConfiguredCaption: String { L.Hero.notConfiguredCaption }

    // MARK: Skala der Solltemperatur

    /// Beschriftete Werte unter dem Regler der Solltemperatur (Enden und eine Mitte).
    public static let temperatureScaleLabels: [Double] = [16, 25, 30]
    /// Betonte Striche an der Skala.
    public static let temperatureScaleEmphasized: [Double] = [20, 25]

    /// Lage eines Werts auf der Skala (0 = 16°, 1 = 30°); Werte außerhalb stehen am Rand.
    public static func temperatureScaleFraction(_ value: Double) -> Double {
        let span = UIOptions.temperatureMax - UIOptions.temperatureMin
        return min(1, max(0, (value - UIOptions.temperatureMin) / span))
    }

    /// Beschriftung der Raum-Marke an der Skala: „Raum 19,0°“.
    public static func temperatureScaleRoom(_ room: Double) -> String { L.Main.Hero.scaleRoom(value: Fmt.temp(room)) }

    // MARK: Hilfsfunktionen

    /// Teilt einen fertigen Satz „Was ist passiert. Was tun.“ nach dem ersten Satzende in `what` und `todo`.
    static func split(_ text: String) -> ResultMessage {
        guard let r = text.range(of: ". ") else { return .failed(what: text) }
        return .failed(what: String(text[..<r.lowerBound]) + ".", todo: String(text[r.upperBound...]))
    }
}
