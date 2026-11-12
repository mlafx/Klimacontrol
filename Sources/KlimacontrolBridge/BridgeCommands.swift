import Foundation
import KlimacontrolCore
import MideaKit

/// Ein Befehl von `kc_command`. `needsDevice`: ohne eingerichtete Anlage kommt eine Meldung statt „angenommen“.
struct BridgeCommand: Sendable {
    let name: String
    let needsDevice: Bool
    let run: @MainActor @Sendable (CommandArgs, ACController) throws -> Void

    static func device(_ name: String, _ run: @escaping @MainActor @Sendable (CommandArgs, ACController) throws -> Void)
        -> BridgeCommand { BridgeCommand(name: name, needsDevice: true, run: run) }

    static func always(_ name: String, _ run: @escaping @MainActor @Sendable (CommandArgs, ACController) throws -> Void)
        -> BridgeCommand { BridgeCommand(name: name, needsDevice: false, run: run) }
}

/// Alle Befehle, gruppiert wie in AGENTS.md §8.3. Neue Befehle hier eintragen und in der Windows-Oberfläche
/// (`Cmd` in windows/KlimacontrolTray/BridgeCommands.cs) – `BridgeCommandTests` prüft beide Richtungen.
let bridgeCommandGroups: [(group: String, commands: [BridgeCommand])] = [
    ("Bedienung", operationCommands), ("Schalter", switchCommands), ("Szenen", sceneCommands),
    ("Timer", timerCommands), ("Einstellungen", settingsCommands), ("Darstellung", appearanceCommands),
    ("Daten", dataCommands), ("Konto", accountCommands), ("Einrichtung", setupCommands),
    ("Anlage", deviceManagementCommands), ("Meldungen", messageCommands),
]

/// Befehlstabelle nach Namen (doppelte Namen fallen in den Tests sofort auf).
let bridgeCommands: [String: BridgeCommand] = Dictionary(
    uniqueKeysWithValues: bridgeCommandGroups.flatMap(\.commands).map { ($0.name, $0) })

/// Liest und führt einen Befehl aus; nil = angenommen, sonst fertiger Meldungstext.
@MainActor func handleCommand(_ text: String?, on c: ACController?) -> String? {
    guard let c else { return UserMessage(what: L.Bridge.coreNotReady, todo: L.Bridge.Todo.restart, code: "core-not-started").text }
    guard let text, let args = CommandArgs(json: text) else {
        return UserMessage(what: L.Bridge.badCommand, todo: L.Bridge.Todo.restart, code: "bad-command").text
    }
    do {
        try runCommand(args, c)
        return nil
    } catch {
        return bridgeMessage(for: error)
    }
}

@MainActor func runCommand(_ a: CommandArgs, _ c: ACController) throws {
    guard let command = bridgeCommands[a.cmd] else {
        throw CommandError(UserMessage(what: L.Bridge.unknownCommand(cmd: a.cmd), todo: L.Bridge.Todo.restartOrUpdate, code: "unknown-command"))
    }
    if command.needsDevice, c.config == nil {
        throw CommandError(UserMessage(what: L.Bridge.noDevice, todo: L.Bridge.noDeviceTodo, code: "no-device"))
    }
    try command.run(a, c)
}

@MainActor private func scene(_ a: CommandArgs, _ c: ACController) throws -> ACScene {
    let id = try a.string("id")
    guard let s = c.scenes.first(where: { $0.id == id }) else {
        throw CommandError(UserMessage(what: L.Bridge.sceneUnknown, todo: L.Bridge.sceneUnknownTodo, code: "scene-unknown"))
    }
    return s
}

@MainActor private func found(_ a: CommandArgs, _ c: ACController) throws -> DiscoveredDevice {
    let id = try a.string("id")
    guard let d = c.setup.discovered.first(where: { String($0.deviceId) == id }) else {
        throw CommandError(UserMessage(what: L.Bridge.deviceUnknown, todo: L.Bridge.deviceUnknownTodo, code: "device-unknown"))
    }
    return d
}

// MARK: - Bedienung

private let operationCommands: [BridgeCommand] = [
    // „Jetzt aktualisieren“: hebt die Sperren der Wegwahl auf (WLAN-Sperre, Cloud-Backoff) und fragt sofort ab.
    .device("refresh") { _, c in Task { await c.refreshNow() } },
    .device("power") { a, c in c.setPower(try a.bool("on")) },
    // Der Kern schaltet ein und nimmt zurück, was der neue Modus nicht kann (Eco, Turbo, Außengerät leise).
    .device("mode") { a, c in
        let v = try a.int("value")
        guard let m = OperationalMode(rawValue: v) else {
            throw CommandError(UserMessage(what: L.Bridge.modeUnknown, todo: L.Bridge.Todo.chooseOther, code: "mode-\(v)"))
        }
        c.setMode(m)
    },
    .device("temp") { a, c in c.setTemperature(try a.double("value")) },
    .device("nudgeTemp") { a, c in c.nudgeTemperature(by: try a.double("delta")) },
    // Schieberegler 1–100 % oder Auto (102); schnelle Folgewerte sammelt der Kern. Verlässt der Wert eine Zone
    // („Außengerät leise“, Turbo), schaltet der Kern sie ab – die Oberfläche schickt dafür nichts extra.
    .device("fan") { a, c in
        let f = try a.int("value")
        guard (1...100).contains(f) || f == FanSpeed.auto.rawValue else {
            throw CommandError(UserMessage(what: L.Bridge.fanUnknown, todo: L.Bridge.fanUnknownTodo, code: "fan-\(f)"))
        }
        c.setFan(f, now: try a.flag("now"))
    },
    // Zonen am Lüfterregler: ganz links „Außengerät leise · 1 %“, ganz rechts „Turbo · 100 %“ (nur Kühlen/Heizen).
    // Optional `now` (Standard an): beim Ziehen false, dann sammelt der Kern wie bei `fan`.
    .device("fanQuiet") { a, c in c.setFanQuiet(now: try a.flag("now", default: true)) },
    .device("fanTurbo") { a, c in c.setFanTurbo(now: try a.flag("now", default: true)) },
]

// MARK: - Schalter

private let switchCommands: [BridgeCommand] = [
    .device("swing") { a, c in
        let on = try a.bool("on")
        c.update { $0.swing = on ? .vertical : .off }
    },
    // Eco nur beim Kühlen, Turbo nur beim Kühlen/Heizen; beide schließen sich aus (Regeln im Kern).
    .device("eco") { a, c in c.setEco(try a.bool("on")) },
    .device("turbo") { a, c in c.setTurbo(try a.bool("on")) },
    .device("purifier") { a, c in
        let on = try a.bool("on")
        c.update { $0.purifier = on }
    },
    .device("freezeProtection") { a, c in
        let on = try a.bool("on")
        c.update { $0.freezeProtection = on }
    },
    .device("sleep") { a, c in c.setSleep(try a.bool("on")) },
    .device("outdoorSilent") { a, c in c.setOutdoorSilent(try a.bool("on")) },
    .device("selfClean") { a, c in c.setSelfClean(try a.bool("on")) },
    .device("ieco") { a, c in c.setIECO(try a.bool("on")) },
    .device("display") { _, c in c.toggleDisplay() },
    .device("rate") { a, c in
        let v = try a.int("value")
        guard [50, 75, 100].contains(v) else {
            throw CommandError(UserMessage(what: L.Bridge.rateUnknown, todo: L.Bridge.rateUnknownTodo, code: "rate-\(v)"))
        }
        c.setRate(v)
    },
    .device("sound") { a, c in c.setSound(try a.bool("on")) },
]

// MARK: - Szenen

private let sceneCommands: [BridgeCommand] = [
    .device("applyScene") { a, c in c.apply(try scene(a, c)) },
    .always("deleteScene") { a, c in c.deleteScene(try scene(a, c)) },
    .device("saveScene") { a, c in
        let name = DeviceConfig.cleanText(try a.string("name"), fallback: "")
        guard !name.isEmpty else { throw CommandError(UserMessage(what: L.Bridge.sceneName, todo: L.Bridge.sceneNameTodo, code: "scene-name")) }
        guard c.state != nil else {
            throw CommandError(UserMessage(what: L.Bridge.noState, todo: L.Bridge.noStateTodo, code: "no-state"))
        }
        c.saveCurrentAsScene(named: name)
    },
]

// MARK: - Timer

private let timerCommands: [BridgeCommand] = [
    // Ohne `minutes`/`at` (oder null): Timer löschen. Ein Wert anderen Typs ist ein Fehler, löscht also nichts.
    .device("offTimer") { a, c in c.setOffTimer(in: try a.optionalInt("minutes")) },
    // Bevorzugt `hour`+`minute` (nächstes Vorkommen dieser Uhrzeit), sonst `at` (Unix-Zeit).
    .device("onTimer") { a, c in
        if !a.absent("hour") || !a.absent("minute") {
            let h = try a.int("hour"), m = try a.int("minute")
            guard (0...23).contains(h), (0...59).contains(m) else {
                throw CommandError(UserMessage(what: L.Bridge.timeInvalid, todo: L.Bridge.timeInvalidTodo, code: "time"))
            }
            c.setOnTimer(hour: h, minute: m)
        } else {
            c.setOnTimer(at: try a.optionalDate("at"))
        }
    },
]

// MARK: - Einstellungen

private let settingsCommands: [BridgeCommand] = [
    .always("connectionMode") { a, c in
        let v = try a.string("value")
        guard ConnectionMode(rawValue: v) != nil else {
            throw CommandError(UserMessage(what: L.Bridge.pathUnknown, todo: L.Bridge.Todo.chooseOther, code: "path-\(v)"))
        }
        c.connectionMode = ConnectionMode(stored: v)
    },
    .always("displayName") { a, c in c.displayName = try a.string("value") },
    .always("refreshSeconds") { a, c in c.refreshSeconds = try a.int("value") },
    .always("price") { a, c in
        let p = try a.double("value")
        guard ACController.validPrice(p) != nil else { throw CommandError(ACController.priceHint) }
        c.pricePerKWh = p
    },
    // Sprachwahl "system" | "de" | "en"; wirkt nach Neustart der App.
    .always("language") { a, c in
        let v = try a.string("value")
        guard let choice = LanguageChoice(rawValue: v) else { throw CommandError(L.Settings.Language.unknown(value: v)) }
        c.languageChoice = choice
    },
    // Währung des Strompreises (1-3 Zeichen, keine Ziffern).
    .always("currency") { a, c in
        let v = try a.string("value")
        guard ACController.validCurrency(v) != nil else { throw CommandError(ACController.currencyHint) }
        c.currency = v
    },
    // Gilt nur für die laufende Sitzung; das Umschalten schreibt der Kern ins Protokoll.
    .always("debugLog") { a, c in c.setDetailedLog(try a.bool("on")) },
    .always("historyCSV") { a, c in c.historyCSV = try a.bool("on") },
    // Updates: geladene Updates ohne Rückfrage installieren; Suchintervall "daily" | "weekly".
    .always("updateAutoInstall") { a, c in c.updateAutoInstall = try a.bool("on") },
    .always("updateInterval") { a, c in
        let v = try a.string("value")
        guard let interval = UpdateInterval(rawValue: v) else { throw a.invalid("value", L.Bridge.Expect.updateInterval) }
        c.updateInterval = interval
    },
    .always("diagnosticsVisible") { a, c in c.diagnosticsVisible = try a.bool("on") },
    // Sichtbare Oberflächen ("main", "flyout", "settings"); ohne sichtbare fragt der Kern höchstens alle 30 s ab.
    .always("uiVisible") { a, c in
        let id = try a.string("id")
        guard !id.isEmpty else { throw a.invalid("id", L.Bridge.Expect.uiName) }
        c.setUIVisible(id, try a.bool("visible"))
    },
]

// MARK: - Darstellung

private let appearanceCommands: [BridgeCommand] = [
    // `value` = ganzes oder Teil-Objekt (fehlende/falsche Felder bleiben wie bisher, Zahlen geklemmt).
    .always("appearance") { a, c in c.setAppearance(Appearance.decode(try a.object("value"), base: c.appearance)) },
    .always("appearanceTheme") { a, c in
        let name = try a.string("theme")
        guard let theme = Appearance.Theme(rawValue: name) else { throw a.invalid("theme", L.Bridge.Expect.theme) }
        c.applyTheme(theme)
    },
    .always("appearanceReset") { _, c in c.resetAppearance() },
]

// MARK: - Daten

private let dataCommands: [BridgeCommand] = [
    // Optional: from/until (Unix-Zeit) und readable (deutsche Spalten, Ortszeit, Dezimalkomma für Excel).
    .always("exportHistory") { a, c in
        let url = try a.path()
        let from = try a.optionalDate("from"), until = try a.optionalDate("until")
        try c.history.exportCSV(to: url, from: from, until: until, readable: try a.flag("readable"))
    },
    // Wie `exportHistory`, aber im Hintergrund (ein Jahr Verlauf dauert Sekunden): Rückgabe nil = gestartet,
    // Ergebnis in exportSeq/exportError. `readable` hier mit Standard an – wie der Export am Mac.
    .always("exportHistoryStart") { a, c in
        let url = try a.path()
        let from = try a.optionalDate("from"), until = try a.optionalDate("until")
        let readable = try a.flag("readable", default: true)
        let db = c.history.db
        results.exportHistoryText = nil
        results.exportHistory.run {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try db.exportCSV(to: url, from: from, until: until, readable: readable)
                }.value
                AppLog.write(L.Log.App.csvExported)
                results.exportHistoryText = UIText.historyExported(fileName: url.lastPathComponent).text
                return nil
            } catch {
                let text = exportHistoryMessage(for: error)
                AppLog.error(L.Log.Bridge.exportFailed(code: bridgeIssue(for: error).code ?? "export-failed"))
                return text
            }
        }
    },
    .always("clearLog") { _, _ in AppLog.clear() },
    // Asynchron mit Prüfung an der Anlage: Rückgabe nil = gestartet, Ergebnis in importSeq/importResult.
    // Optional: replaceScenes (vorhandene Szenen ersetzen), allowOtherDevice (Sicherung einer anderen Anlage).
    .always("importBackup") { a, c in
        let url = try a.path()
        let replace = try a.flag("replaceScenes"), other = try a.flag("allowOtherDevice")
        results.importBackup.run {
            do {
                let done = try await c.importBackupChecked(from: url, replaceScenes: replace, allowOtherDevice: other)
                return ImportResultDTO(ok: true, verified: done.verified, scenesImported: done.scenesImported,
                                       scenesSkipped: done.scenesSkipped,
                                       text: UIText.backupImported(done, ip: c.config?.ip ?? "").text)
            } catch {
                var prompt: PromptDTO?
                if case BackupImportError.otherDevice(let backup, let current) = error {
                    prompt = PromptDTO(UIText.otherDevicePrompt(backup: backup, current: current))
                }
                return ImportResultDTO(ok: false, verified: nil, scenesImported: 0, scenesSkipped: 0,
                                       error: bridgeMessage(for: error), errorCode: importErrorCode(error),
                                       text: UIText.backupImportFailed(error).text, prompt: prompt)
            }
        }
    },
    .device("exportBackup") { a, c in try c.exportBackup(to: try a.path()) },
]

private func importErrorCode(_ error: any Error) -> String {
    guard let e = error as? BackupImportError else { return "file" }
    switch e {
    case .otherDevice: return "otherDevice"
    case .rejected: return "rejected"
    default: return "other"
    }
}

// MARK: - Konto

private let accountCommands: [BridgeCommand] = [
    .always("cloudLogin") { a, c in
        let account = try a.string("account"), password = try a.string("password")
        results.login.reset(to: nil)
        results.login.run { await c.cloudLogin(account: account, password: password) }
    },
    .always("cloudLogout") { _, c in c.cloudLogout() },
]

// MARK: - Einrichtung

private let setupCommands: [BridgeCommand] = [
    // "account" | "manual" | "backup"; ohne Wert: zurück zur Startseite. Unbekannter Wert: Fehler.
    .always("setupPath") { a, c in
        if let v = try a.optionalString("value") {
            guard let p = SetupPath(rawValue: v) else {
                throw CommandError(UserMessage(what: L.Bridge.setupPathUnknown, todo: L.Bridge.setupPathUnknownTodo, code: "setup-path-\(v)"))
            }
            c.setup.choose(p)
        } else {
            c.setup.choose(nil)
        }
    },
    .always("scan") { a, c in c.setup.scan(ip: try a.optionalString("ip")) },
    .always("scanSubnet") { _, c in c.setup.scanSubnet() },
    // Cloud-Suche (Anlage ausgeschaltet oder nicht im WLAN): Funde kommen mit cloudOnly = true in `discovered`.
    .always("scanCloud") { a, c in c.setup.scanCloud(account: try a.string("account"), password: try a.string("password")) },
    // `id` null: Auswahl aufheben; unbekannte id: Fehler.
    .always("select") { a, c in c.setup.selected = a.absent("id") ? nil : try found(a, c) },
    .always("setupConnect") { a, c in
        let account = try a.string("account"), password = try a.string("password")
        guard c.setup.canConnect(account: account, password: password) else {
            throw CommandError(UserMessage(what: L.Bridge.setupIncomplete, todo: "", code: "setup-incomplete"))
        }
        results.setup.run { await c.setup.connect(account: account, password: password) }
    },
    // Nur die übergebenen Felder ändern: ip, port, deviceId, token, key.
    .always("manualSet") { a, c in
        var m = c.setup.manual
        if let v = try a.optionalString("ip") { m.ip = v }
        if let v = try a.optionalString("port") { m.port = v }
        if let v = try a.optionalString("deviceId") { m.deviceId = v }
        if let v = try a.optionalString("token") { m.token = v }
        if let v = try a.optionalString("key") { m.key = v }
        c.setup.manual = m
    },
    .always("manualUse") { a, c in c.setup.useForManual(try found(a, c)) },
    // Was erkannt wurde, steht danach in den Feldern; bei Misserfolg kommt der Grund als Fehlertext.
    .always("manualPaste") { a, c in
        if c.setup.pasteCredentials(try a.string("text")) == nil {
            throw CommandError(c.setup.error
                               ?? UserMessage(what: L.Bridge.pasteEmpty, todo: L.Bridge.pasteEmptyTodo, code: "paste-empty").text)
        }
    },
    .always("manualCheck") { _, c in Task { await c.setup.checkManual() } },
    .always("manualConnect") { _, c in results.setup.run { await c.setup.connectManual() } },
    // Nach der Einrichtung: vorgeschlagenen Weg „Nur WLAN“ übernehmen bzw. den Abschluss-Hinweis schließen.
    .always("applySuggestedMode") { _, c in c.setup.applySuggestedMode() },
    .always("dismissCompletion") { _, c in c.setup.dismissCompletion() },
]

// MARK: - Anlage

private let deviceManagementCommands: [BridgeCommand] = [
    .always("forgetDevice") { _, c in c.forgetDevice() },
    // „Adresse neu suchen“ (Router-/IP-Wechsel): Ergebnis in relocateSeq/relocateOK, Grund bei Misserfolg in `notice`.
    .device("relocate") { _, c in results.relocate.run { await c.relocate() } },
]

// MARK: - Meldungen

private let messageCommands: [BridgeCommand] = [
    .always("dismissMessage") { _, c in c.clearConnectionError() },
    .always("dismissNotice") { _, c in c.clearNotice() },
    .always("dismissWhatsNew") { _, c in c.dismissWhatsNew() },
]
