import AppKit
import MideaKit
import KlimacontrolCore
import UniformTypeIdentifiers

// MARK: - Dateidialoge und Hinweisfenster (die Logik steckt in KlimacontrolCore.ACController)

/// Startordner der Dateidialoge: der Benutzerordner – nicht „Dokumente“, das oft mit iCloud abgeglichen wird.
@MainActor
private func prepareFilePanel(_ panel: NSSavePanel) {
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    NSApp.activate()
}

/// Liegt der Ort in einem Cloud-Ordner (Liste und Regel im Kern)?
func isCloudFolder(_ url: URL) -> Bool { UIText.isCloudFolder(path: url.standardizedFileURL.path) }

/// Rückfrage aus dem Kern als Hinweisfenster; true = die weitermachende Antwort (`confirm`).
@MainActor
func runConfirm(_ prompt: ConfirmPrompt) -> Bool {
    let alert = NSAlert()
    if prompt.warning { alert.alertStyle = .warning }
    alert.messageText = prompt.title
    alert.informativeText = prompt.message
    alert.addButton(withTitle: prompt.cancel)
    alert.addButton(withTitle: prompt.confirm)
    return alert.runModal() == .alertSecondButtonReturn
}

extension ResultMessage {
    var feedback: ActionFeedback { ok ? .ok(text) : .failed(text) }
}

extension ACController {
    /// Sicherungsdatei per Dateidialog wählen und einlesen (Einrichtung, Startseite). Ein Fehler beim Lesen erscheint
    /// in der Einrichtung, eine nicht antwortende Anlage danach als Hinweisfenster.
    func importBackup() {
        Task {
            guard let result = await chooseAndImportBackup() else { return }
            if config == nil {
                if !result.ok { setup.error = result.text }
            } else if !result.ok {
                Self.alert(UIText.importAlertTitle, result.text)
            }
        }
    }

    /// Sicherungsdatei wählen und über den Kern einlesen (prüft an der Anlage, legt die alte Einrichtung in den
    /// Papierkorb). Fragt vorher, ob vorhandene Szenen ersetzt werden sollen, und bei einer Sicherung einer anderen
    /// Anlage, ob gewechselt werden soll. nil = abgebrochen.
    func chooseAndImportBackup() async -> ActionFeedback? {
        let panel = NSOpenPanel()
        panel.title = UIText.importPanelTitle
        panel.message = UIText.importPanelMessage
        panel.allowedContentTypes = [.json]
        prepareFilePanel(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        var replaceScenes = false
        if !scenes.isEmpty {
            replaceScenes = runConfirm(UIText.replaceScenesPrompt)
        }
        var allowOther = false
        while true {
            do {
                let r = try await importBackupChecked(from: url, replaceScenes: replaceScenes, allowOtherDevice: allowOther)
                return UIText.backupImported(r, ip: config?.ip ?? "").feedback
            } catch BackupImportError.otherDevice(let backup, let current) where !allowOther {
                guard runConfirm(UIText.otherDevicePrompt(backup: backup, current: current)) else { return nil }
                allowOther = true
            } catch {
                return UIText.backupImportFailed(error).feedback
            }
        }
    }

    /// Ganzen Verlauf per Dateidialog als CSV sichern – lesbar (deutsche Spalten, Ortszeit, Dezimalkomma), im
    /// Hintergrund geschrieben. nil = abgebrochen.
    func exportHistoryCSV() async -> ActionFeedback? {
        let panel = NSSavePanel()
        panel.title = UIText.exportHistoryPanelTitle
        panel.nameFieldStringValue = UIText.exportHistoryFileName
        panel.allowedContentTypes = [.commaSeparatedText]
        prepareFilePanel(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let db = history.db
            try await Task.detached(priority: .userInitiated) {
                try db.exportCSV(to: url, from: nil, until: nil, readable: true)
            }.value
            AppLog.write(L.Log.App.csvExported)
            return UIText.historyExported(fileName: url.lastPathComponent).feedback
        } catch {
            return UIText.historyExportFailed(error).feedback
        }
    }

    /// Zugangsdaten + Szenen per Dateidialog sichern. Vor dem Speichern in einen Cloud-Ordner wird gefragt.
    /// nil = abgebrochen.
    @discardableResult
    func exportBackup() -> ActionFeedback? {
        guard config != nil else { return nil }
        let panel = NSSavePanel()
        panel.title = UIText.exportBackupPanelTitle
        panel.message = UIText.exportBackupPanelMessage
        panel.nameFieldStringValue = UIText.exportBackupFileName
        panel.allowedContentTypes = [.json]
        prepareFilePanel(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if isCloudFolder(url) {
            guard runConfirm(UIText.cloudFolderPrompt(folder: url.deletingLastPathComponent().lastPathComponent)) else {
                return exportBackup()
            }
        }
        do {
            try exportBackup(to: url)
            // Den Cloud-Hinweis des Kerns (für Windows) hat der Mac schon vor dem Speichern gefragt – nicht doppelt zeigen.
            if isCloudFolder(url) { clearNotice() }
            return UIText.backupExported(fileName: url.lastPathComponent).feedback
        } catch {
            return UIText.backupExportFailed(error).feedback
        }
    }

    /// Hinweisfenster, wenn es keinen Ort für die Rückmeldung mehr gibt (z. B. Einrichtung schon geschlossen).
    static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }

    /// Nach gelungener Einrichtung (die Einrichtungsseite ist dann schon weg): Vorschlag „Nur WLAN“ und „Zugangsdaten
    /// jetzt sichern?“ aus `setup.completion` als Hinweisfenster. Der Weg wird nicht still umgestellt.
    func presentSetupCompletion() {
        guard let c = setup.completion else { return }
        defer { setup.dismissCompletion() }
        guard let prompt = UIText.setupDonePrompt(c) else { return }
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.paragraphs.joined(separator: "\n\n")
        if let choice = prompt.lanOnlyChoice {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = choice
            alert.suppressionButton?.state = .on
        }
        alert.addButton(withTitle: prompt.primary)
        if let secondary = prompt.secondary { alert.addButton(withTitle: secondary) }
        NSApp.activate()
        let answer = alert.runModal()
        if c.suggestLANOnly, alert.suppressionButton?.state == .on { setup.applySuggestedMode() }
        guard c.offerBackup, answer == .alertFirstButtonReturn, let result = exportBackup(), !result.ok else { return }
        Self.alert(UIText.notBackedUpTitle, result.text)
    }
}
