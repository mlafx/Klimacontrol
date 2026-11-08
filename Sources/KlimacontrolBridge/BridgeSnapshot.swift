import Foundation
import KlimacontrolCore
import MideaKit
import Observation

// Schnappschuss für kc_state_json: Datenobjekte, Abbildung aus dem Kern und Beobachtung (kc_state_rev).

struct StateDTO: Encodable {
    var power, swing, eco, turbo, purifier, sleep, displayOn, filterAlert: Bool
    var mode: Int
    var modeLabel: String
    var fan: Int
    var fanLabel: String
    var target: Double
    var indoor, outdoor, powerWatts, totalKWh: Double?
    var ratePercent: Int?
    var outSilent, selfClean, ieco, sound: Bool?
    var freezeProtection: Bool
    var errorCode: Int
}

/// Alle Diagnosewerte wie in der Diagnosespalte der Mac-App (nil = nicht geliefert).
struct DiagDTO: Encodable {
    var compressorPowerW, compressorHz, compressorTargetHz, currentA, voltageV, outdoorFanRpm: Int?
    var tpDischarge, eevOpening, indoorFanRpm, indoorFanTargetRpm: Int?
    var t1IndoorAir, indoorTemp2, t2IndoorCoil, t3OutdoorCoil, t4OutdoorAir: Double?
    var defrost, condensatePump: Bool?
}

struct SceneDTO: Encodable {
    var id, name, summary: String
    var active: Bool
    /// Modus der Szene (OperationalMode.rawValue) – für Symbol und Farbe der Kachel wie am Mac.
    var mode: Int
}

struct FoundDTO: Encodable {
    var id, name, ip, sn: String
    /// Protokollversion (2/3) bei WLAN-Funden, 0 bei Cloud-Funden.
    var version: Int
    /// Nur aus der Cloud bekannt (keine Antwort im WLAN); `cloudOnline` = laut Cloud verbunden (nil bei WLAN-Funden).
    var cloudOnly: Bool
    var cloudOnline: Bool?
}

struct SetupDTO: Encodable {
    var scanning, cloudScanning, busy: Bool
    /// Subnetz-Scan („Netz durchsuchen“): läuft? und Fortschritt (gesendet, gesamt; nil außerhalb eines Laufs).
    var subnetScanning: Bool
    var subnetSent, subnetTotal: Int?
    var error: String?
    var discovered: [FoundDTO]
    var selected: String?
    var seq: Int
    var ok: Bool
    /// Gewählter Weg: "account", "manual", "backup" oder nil (Startseite „Wie möchtest du verbinden?“).
    var path: String?
    /// Weg „Zugangsdaten“: Eingaben, Probleme je Feld (ip, port, deviceId, token, key), vollständig?, Ergebnis von
    /// „Prüfen“ (nil = nicht geprüft bzw. seitdem geändert). Nur bei `path == "manual"` gefüllt – sonst leer, damit
    /// Token und Schlüssel nicht in jedem Schnappschuss stehen.
    var manual: ManualDTO
    var manualCheckOK: Bool?
    /// Art der Meldung in `error` (SetupIssue.rawValue: nothingFound, notAirConditioner, invalidInput, rejected,
    /// busy, unreachable, accountLogin, cloud, network, other) – für passende Knöpfe; nil = keine Meldung.
    var issue: String? = nil
    /// Knopf zur Netz-Hilfe zeigen (Freigabe/Firewall) – nur bei nothingFound/unreachable.
    var showsNetworkHelp = false
    /// Nach gelungener Einrichtung: was noch anzubieten ist (nil = nichts); Befehle applySuggestedMode/dismissCompletion.
    var completion: CompletionDTO? = nil
}

struct CompletionDTO: Encodable {
    var path: String
    var suggestLANOnly, offerBackup: Bool
    var note: String
    /// Fertiger Inhalt des Abschlussfensters (Titel, Absätze, Knöpfe); nil, wenn nichts anzubieten ist.
    var prompt: SetupDonePromptDTO? = nil
}

/// Ergebnis des letzten App-Timers (ausgeführt/verpasst/nicht ausgeführt) für Hinweis und Mitteilung.
struct TimerResultDTO: Encodable {
    /// "executed" | "missed" | "failed"
    var kind: String
    var title, message: String
    var succeeded, powerOn: Bool
    var due: Double
}

/// Letzter bekannter Verlaufspunkt beim Start („Stand HH:MM“), solange noch keine Abfrage gelang.
struct LastKnownDTO: Encodable {
    var t: Double
    var power, indoor, outdoor, target: Double?
    var on: Bool
}

struct ManualDTO: Encodable {
    var ip, port, deviceId, token, key, name: String
    var tokenCount, keyCount: Int
    var problems: [String: String]
    var complete: Bool

    static let empty = ManualDTO(ip: "", port: "", deviceId: "", token: "", key: "", name: "", tokenCount: 0, keyCount: 0,
                                 problems: [:], complete: false)
}

struct Snapshot: Encodable {
    /// Version der C-Schnittstelle (wie kc_api_version).
    var apiVersion: Int
    var configured: Bool
    var displayName: String
    var deviceName, ip: String?
    var port: Int?
    /// Als Text: 64 bit passen nicht verlustfrei in jede JSON-Zahl.
    var deviceId: String?
    var deviceIdentifier: String?
    var message: String?
    /// `lastRefreshFailed`: letzte Abfrage/letzter Befehl scheiterte an der Verbindung (dann „Keine Verbindung“);
    /// `deviceOffNotice`: `message` ist der Hinweis „Anlage ausgeschaltet oder ohne Strom“ (grau statt orange);
    /// `notice`: Hinweis zu einem Befehl (nicht übernommen, Timer, Backup) – eigene graue Zeile, verschwindet nach 10 s.
    var lastRefreshFailed, deviceOffNotice: Bool
    var notice: String?
    var path: String?
    /// Zieltext („Heizt · noch 1,2° bis zum Ziel“) und Statuszeile („Kühlt · Raum 24,5° · über WLAN“) aus dem Kern;
    /// leer ohne Zustand. `fanZonesAvailable`: „Leise außen“/Turbo am Lüfterregler (nur Kühlen/Heizen).
    var goalLine, statusLine: String
    var fanZonesAvailable: Bool
    var lastUpdate: Double?
    var connectionMode: String
    var connectionModes: [[String]]
    var cloudAccount: String?
    var cloudLoginRunning: Bool
    var loginSeq: Int
    var loginError: String?
    var state: StateDTO?
    var diagnostics: String?
    var diag: DiagDTO?
    var scenes: [SceneDTO]
    var offAt, onAt: Double?
    var costPerHour, todayKWh: Double?
    var refreshSeconds: Int
    var price: Double
    /// Gespeicherte Sprachwahl ("system", "de", "en"; wirkt nach Neustart) und Währung des Strompreises.
    var language: String
    var currency: String
    var beep: Bool
    var debugLog: Bool
    var historyCSV: Bool
    var historyRevision: Int
    var setup: SetupDTO
    /// Startanzeige: Verbindungsschritt ("searching", "handshake", "reading"; nil = verbunden/keine Verbindung),
    /// `connectSlow` = dauert länger als üblich (> 10 s), `staleSince` = Werte nicht live seit (Unix-Zeit),
    /// `lastKnown` = letzter Verlaufspunkt vor der ersten Abfrage, `relocating` = „Adresse neu suchen“ läuft.
    var connectPhase: String? = nil
    var connectSlow = false
    var staleSince: Double? = nil
    var lastKnown: LastKnownDTO? = nil
    var relocating = false
    var relocateSeq = 0
    var relocateOK = false
    var timerResult: TimerResultDTO? = nil
    /// "notConfigured" | "connecting" | "live" | "deviceOff" | "noConnection"
    var connectionState = "notConfigured"
    /// `message` aufgeteilt nach „Was ist passiert“ / „Was tun“ / Code (nil ohne Meldung).
    var messageDetail: MessageDTO? = nil
    /// Zugangsdaten wurden gesichert (sonst „Zugangsdaten sichern“ anbieten).
    var credentialsBackedUp = false
    var importSeq = 0
    var importResult: ImportResultDTO? = nil
    var exportSeq = 0
    var exportError: String? = nil
    /// Rückmeldung des letzten „Adresse neu suchen“ (Text aus dem Kern).
    var relocateMessage: String? = nil
    /// Anlage arbeitet sichtbar (Effekte nur dann), Texte des Mini-Fensters – alles aus dem Kern.
    var working = false
    var miniValue = "–"
    var miniCaption = ""
    var todayEnergy: TodayEnergyDTO? = nil
    /// Anzeige der App-Timer („22:30“ bzw. „morgen 07:00“), nil = kein Timer; Voraussetzung als fester Hinweistext.
    var onTimerLabel, offTimerLabel: String?
    var timerRequirement = ""
    /// Darstellung (Reiter „Darstellung“), Felder wie `Appearance` (Enums als Text, Zahlen als Double).
    var appearance = Appearance.standard
    /// Appcast für WinSparkle und Standard-Suchintervall in Sekunden (beides fest aus dem Kern).
    var updateFeedURL = AppUpdate.feedWindows
    var updateCheckInterval = AppUpdate.checkInterval
    // Anzeigetexte und Auswahllisten aus dem Kern (BridgeDisplay.swift); alles nur zum Anzeigen.
    /// Statische Auswahllisten, Grenzen, Standardwerte und feste Rückfragen.
    var options = OptionsDTO.current
    /// Gültigkeit der Schalter im aktuellen Modus je Schalter (swing, eco, turbo, outdoorSilent, ieco, purifier,
    /// freezeProtection, selfClean, display): `enabled` und Kurzinfo/Grund `why`.
    var availability: [String: AvailabilityDTO] = [:]
    /// Kurzinfo der Verbindungszeile; die Zeile selbst (zeitabhängig) steht in `kc_live_json` (`connectionLine`).
    var connectionTooltip = ""
    /// Verbindungszustand für die Anzeige (wie `connectionState`, aber „Anlage aus“/„Keine Verbindung“ bleiben
    /// während eines neuen Versuchs stehen) und Zeitpunkt, seit dem die Werte nicht live sind.
    var uiConnectionState = "notConfigured"
    var uiStaleSince: Double? = nil
    /// „Stand 14:32 · nicht aktuell“, solange die Werte nicht live sind.
    var staleText: String? = nil
    /// Große Zahl, Zeile darunter und Hinweis bei ausgeschalteter Anlage.
    var heroValue = "–"
    var heroCaption = ""
    var heroHint: String? = nil
    var costLine = CostLineDTO(title: "", value: "", help: "")
    var powerCostHelp = ""
    /// Text neben dem Symbol im Infobereich (nil = nur Symbol).
    var menuTitle: String? = nil
    /// Zeile „Status“ im Reiter Verbindung.
    var connectionStatus = ConnectionStatusDTO(text: "", connected: false)
    var connectStepsLine = ""
    var startupValues: StartupValuesDTO? = nil
    /// `notice` in Teilen (Text, Rat, Code); `notice` bleibt der ganze Satz.
    var noticeDetail: MessageDTO? = nil
    /// Die Darstellung entspricht dem Standard dieser Plattform („Auf Standard zurücksetzen“ ausgegraut).
    var appearanceIsStandard = true
    var appearanceCustomized = false
    var onTimerChip: String? = nil
    /// Rückfrage beim Beenden, solange ein App-Timer gestellt ist (nil = ohne Rückfrage beenden).
    var quitPrompt: PromptDTO? = nil
    /// „Neu einrichten“ fragt mit `options.prompts.forgetNeedsBackup` (WLAN-Zugangsdaten noch nicht gesichert).
    var forgetNeedsBackup = false
    var fanCaption = ""
    var maintenanceHints: [String] = []
    var errorCodeValue = ""
    var filterValue = ""
    var accountFooter = ""
    /// Text zum letzten gelungenen Verlauf-Export („Verlauf gespeichert als …“), nil bei Fehler.
    var exportText: String? = nil
    /// „Neu in dieser Version“ nach einem Update (nil = nichts zu zeigen); Bestätigen mit `dismissWhatsNew`.
    var whatsNew: WhatsNewDTO? = nil
}

struct WhatsNewDTO: Encodable {
    struct Section: Encodable {
        var title: String
        var items: [String]
    }
    struct Version: Encodable {
        var version, heading: String
        var sections: [Section]
    }
    var title, ok: String
    var versions: [Version]
}

/// Verbrauch heute laut Zähler: `plausible` false = Zähler passt nicht zur gemessenen Leistung, nil = nicht prüfbar;
/// `sinceLabel` („seit 08:14“) nur, wenn nicht ab Mitternacht gezählt wird.
struct TodayEnergyDTO: Encodable {
    var kWh: Double
    var since: Double?
    var fromMidnight: Bool
    var plausible: Bool?
    var sinceLabel: String?
}

struct MessageDTO: Encodable {
    var what, todo: String
    var code: String?
}

func stateName(_ s: ConnectionState) -> String {
    switch s {
    case .notConfigured: return "notConfigured"
    case .connecting: return "connecting"
    case .live: return "live"
    case .deviceOff: return "deviceOff"
    case .noConnection: return "noConnection"
    }
}

func phaseName(_ p: ConnectPhase) -> String {
    switch p {
    case .searching: return "searching"
    case .handshake: return "handshake"
    case .reading: return "reading"
    }
}

/// Schnappschuss als JSON wie `kc_state_json` (auch für den Vertragstest in KlimacontrolBridgeTests).
@MainActor func snapshotJSON(_ c: ACController) -> String { encode(snapshot(c), fallback: "{}") }

@MainActor func snapshot(_ c: ACController) -> Snapshot {
    let s = c.state.map {
        StateDTO(power: $0.power, swing: $0.swing == .vertical, eco: $0.eco, turbo: $0.turbo, purifier: $0.purifier,
                 sleep: $0.sleep, displayOn: $0.displayOn, filterAlert: $0.filterAlert, mode: $0.mode.rawValue,
                 modeLabel: $0.mode.title, fan: $0.fanSpeed, fanLabel: $0.fanTitle, target: $0.targetTemperature,
                 indoor: $0.indoorTemperature, outdoor: $0.outdoorTemperature, powerWatts: $0.powerWatts,
                 totalKWh: $0.totalEnergyKWh, ratePercent: $0.ratePercent, outSilent: $0.outSilent,
                 selfClean: $0.selfClean, ieco: $0.ieco, sound: $0.sound, freezeProtection: $0.freezeProtection,
                 errorCode: $0.errorCode)
    }
    let setup = c.setup
    let modes = ConnectionMode.allCases.map { [$0.rawValue, $0.title] }
    let manual = setup.path == .manual
        ? ManualDTO(ip: setup.manual.ip, port: setup.manual.port, deviceId: setup.manual.deviceId,
                    token: setup.manual.token, key: setup.manual.key, name: setup.manual.name,
                    tokenCount: setup.manual.tokenHex.count, keyCount: setup.manual.keyHex.count,
                    problems: setup.manual.problems, complete: setup.manual.isComplete)
        : ManualDTO.empty
    var snap = Snapshot(
        apiVersion: Int(bridgeAPIVersion), configured: c.config != nil, displayName: c.displayName, deviceName: c.config?.name, ip: c.config?.ip,
        // Port nur mit WLAN-Zugang: über die Cloud eingerichtet (ohne Token) gibt es keine Adresse, nur die Anlagen-ID.
        port: c.config.flatMap { $0.hasLAN ? Int($0.port) : nil },
        deviceId: c.config.flatMap { $0.deviceId != 0 ? String($0.deviceId) : nil },
        deviceIdentifier: c.deviceIdentifier, message: c.message,
        lastRefreshFailed: c.lastRefreshFailed, deviceOffNotice: c.deviceOffNotice, notice: c.notice,
        path: c.connectionPath?.rawValue,
        goalLine: c.goalLine, statusLine: c.statusLine, fanZonesAvailable: c.fanZonesAvailable,
        lastUpdate: c.lastUpdate?.timeIntervalSince1970,
        connectionMode: c.connectionMode.rawValue, connectionModes: modes,
        cloudAccount: c.cloudAccount.map(AppLog.mask), cloudLoginRunning: c.cloudLoginRunning,
        loginSeq: results.login.seq, loginError: results.login.result, state: s, diagnostics: c.diagnostics.map(Fmt.diagnosticsLine),
        diag: c.diagnostics.map {
            DiagDTO(compressorPowerW: $0.compressorPowerW, compressorHz: $0.compressorHz, compressorTargetHz: $0.compressorTargetHz,
                    currentA: $0.currentA, voltageV: $0.voltageV, outdoorFanRpm: $0.outdoorFanRpm, tpDischarge: $0.tpDischarge,
                    eevOpening: $0.eevOpening, indoorFanRpm: $0.indoorFanRpm, indoorFanTargetRpm: $0.indoorFanTargetRpm,
                    t1IndoorAir: $0.t1IndoorAir, indoorTemp2: $0.indoorTemp2, t2IndoorCoil: $0.t2IndoorCoil,
                    t3OutdoorCoil: $0.t3OutdoorCoil, t4OutdoorAir: $0.t4OutdoorAir, defrost: $0.defrost,
                    condensatePump: $0.condensatePump)
        },
        scenes: c.scenes.map { SceneDTO(id: $0.id, name: $0.name, summary: $0.summaryText, active: c.isActive($0), mode: $0.mode) },
        offAt: c.offAt?.timeIntervalSince1970, onAt: c.onAt?.timeIntervalSince1970,
        costPerHour: c.costPerHour, todayKWh: c.todayKWh, refreshSeconds: c.refreshSeconds, price: c.pricePerKWh,
        language: c.languageChoice.rawValue, currency: c.currency,
        beep: c.beep, debugLog: results.debugLog, historyCSV: c.historyCSV, historyRevision: c.history.revision,
        setup: SetupDTO(scanning: setup.scanning, cloudScanning: setup.cloudScanning, busy: setup.busy,
                        subnetScanning: setup.subnetScanning,
                        subnetSent: setup.subnetProgress?.0, subnetTotal: setup.subnetProgress?.1, error: setup.error,
                        discovered: setup.discovered.map {
                            FoundDTO(id: String($0.deviceId), name: $0.name, ip: $0.ip, sn: $0.sn, version: $0.version,
                                     cloudOnly: $0.isCloudOnly, cloudOnline: $0.cloudOnline)
                        },
                        selected: setup.selected.map { String($0.deviceId) }, seq: results.setup.seq, ok: results.setup.result,
                        path: setup.path?.rawValue, manual: manual, manualCheckOK: setup.manualCheckOK))
    snap.setup.issue = setup.issue?.rawValue
    snap.setup.showsNetworkHelp = setup.issue?.showsNetworkHelp ?? false
    snap.setup.completion = setup.completion.map {
        CompletionDTO(path: $0.path.rawValue, suggestLANOnly: $0.suggestLANOnly, offerBackup: $0.offerBackup, note: $0.note)
    }
    snap.connectPhase = c.connectPhase.map(phaseName)
    snap.connectSlow = c.connectSlow
    snap.staleSince = c.staleSince?.timeIntervalSince1970
    snap.lastKnown = c.lastKnown.map {
        LastKnownDTO(t: $0.time.timeIntervalSince1970, power: $0.power, indoor: $0.indoor, outdoor: $0.outdoor,
                     target: $0.target, on: $0.on)
    }
    snap.relocating = c.relocating
    snap.relocateSeq = results.relocate.seq
    snap.connectionState = stateName(c.connectionState)
    snap.messageDetail = c.messageDetail.map { MessageDTO(what: $0.what, todo: $0.todo, code: $0.code) }
    snap.credentialsBackedUp = c.credentialsBackedUp
    snap.importSeq = results.importBackup.seq
    snap.importResult = results.importBackup.result
    snap.exportSeq = results.exportHistory.seq
    snap.exportError = results.exportHistory.result
    snap.relocateMessage = c.relocateMessage
    snap.working = c.isWorking
    snap.miniValue = c.miniValue
    snap.miniCaption = c.miniCaption
    snap.relocateOK = results.relocate.result
    snap.todayEnergy = c.todayEnergy.map {
        TodayEnergyDTO(kWh: $0.kWh, since: $0.since?.timeIntervalSince1970, fromMidnight: $0.fromMidnight,
                       plausible: $0.plausible, sinceLabel: $0.sinceLabel)
    }
    snap.onTimerLabel = c.onTimerLabel
    snap.offTimerLabel = c.offTimerLabel
    snap.appearance = c.appearance
    snap.timerRequirement = ACController.timerRequirement
    snap.applyDisplay(c)
    let news = c.whatsNew(for: .windows)
    if !news.isEmpty {
        snap.whatsNew = WhatsNewDTO(
            title: UIText.whatsNewTitle(version: c.appVersion), ok: UIText.whatsNewOK,
            versions: news.map { n in
                WhatsNewDTO.Version(version: n.version, heading: UIText.whatsNewVersionHeading(n.version),
                                    sections: n.sections.map { .init(title: $0.title, items: $0.items) })
            })
    }
    snap.timerResult = c.lastTimerResult.map { r in
        let kind: String
        switch r {
        case .executed: kind = "executed"
        case .missed: kind = "missed"
        case .failed: kind = "failed"
        }
        return TimerResultDTO(kind: kind, title: r.title, message: r.message, succeeded: r.succeeded, powerOn: r.powerOn,
                              due: r.due.timeIntervalSince1970)
    }
    return snap
}

/// Beobachtet alle Eigenschaften, die `snapshot` liest. Bei der ersten Änderung (willSet) einmal den Zähler erhöhen
/// und neu registrieren – beides erst im nächsten Durchlauf der Main-Queue, dann ist der neue Wert gesetzt und
/// mehrere Änderungen desselben Durchlaufs zählen einmal. Die Ergebnisse der Bridge (`results`) sind ebenfalls
/// beobachtbar; von Hand erhöht wird der Zähler nur bei kc_init/kc_stop.
@MainActor func track() {
    guard let c = controller, !tracking else { return }
    tracking = true
    let observed = ObjectIdentifier(c)
    withObservationTracking {
        _ = snapshot(c)
    } onChange: {
        Task { @MainActor in
            // Meldung eines inzwischen gestoppten Controllers: nicht doppelt beobachten.
            guard let current = controller, ObjectIdentifier(current) == observed else { return }
            tracking = false
            stateRev += 1
            track()
        }
    }
}
