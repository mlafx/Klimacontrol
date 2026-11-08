import Foundation
import MideaKit

/// Kosten-Kennzahl im Kopf: Titel, Wert und erklärende Kurzinfo.
public struct CostLine: Equatable, Sendable {
    public let title: String
    public let value: String
    public let help: String
}

/// Zuletzt bekannte Werte vor der ersten Abfrage (Startanzeige).
public struct StartupValues: Equatable, Sendable {
    /// Große Zahl: Soll bei laufender Anlage, sonst Raumtemperatur.
    public let main: String
    /// „Stand 14:32 · Solltemperatur“ bzw. „… · Raumtemperatur · aus“.
    public let caption: String
    /// Kleine Zeile darunter („Raum 24,5°“, „Außen 29,0°“).
    public let extras: [String]
    public let accessibility: String
}

/// Zeile „Verbunden über WLAN“ der Einstellungen.
public struct ConnectionStatus: Equatable, Sendable {
    public let text: String
    /// Grün nur, wenn die letzte Abfrage gelungen ist.
    public let connected: Bool
}

/// Anzeigetexte aus dem Zustand – beide Oberflächen zeigen sie nur an. Zeitabhängige Texte gibt es auch mit `now:`.
extension ACController {
    // MARK: Verbindung

    /// Verbindungszeile im Kopf: „Verbunden über WLAN · gerade aktualisiert“, „Verbinde …“, „Nicht erreichbar“ …
    public var connectionLine: String { connectionLine(now: now()) }

    public func connectionLine(now: Date) -> String {
        switch uiConnectionState {
        case .deviceOff: return L.Status.deviceOff + lastSeen(now: now)
        // Startfehler: noch nie geantwortet.
        case .noConnection: return (state == nil ? L.Status.notReachable : L.Status.noConnection) + lastSeen(now: now)
        case .connecting: return L.Status.connecting + lastSeen(now: now)
        case .notConfigured: return ""
        case .live: break
        }
        guard let t = lastUpdate else { return L.Status.connecting }
        let secs = Int(now.timeIntervalSince(t))
        let via = connectionPath.map { L.Status.connectedVia(path: $0.title) } ?? L.Status.connected
        return secs < 60 ? L.Status.justRefreshed(via: via) : L.Status.refreshedAgo(via: via, min: "\(secs / 60)")
    }

    /// „· zuletzt vor N min“ – wann die Anlage zuletzt geantwortet hat (leer, wenn noch nie).
    private func lastSeen(now: Date) -> String {
        guard let t = lastUpdate else { return "" }
        let secs = Int(now.timeIntervalSince(t))
        return " · " + (secs < 60 ? L.Status.lastSeenNow : L.Status.lastSeenAgo(min: "\(secs / 60)"))
    }

    /// Kurzinfo der Verbindungszeile: Adresse bei WLAN-Einrichtung, sonst „über Midea-Konto“; leer ohne Einrichtung.
    public var connectionTooltip: String {
        guard let c = config else { return "" }
        return c.hasLAN ? L.Status.tooltipLocal(name: c.name, address: "\(c.ip):\(c.port)")
            : L.Status.tooltipAccount(name: c.name)
    }

    /// Status im Reiter „Verbindung“.
    public var connectionStatus: ConnectionStatus {
        let text: String
        if deviceOffNotice {
            text = L.Status.deviceOff
        } else if lastRefreshFailed {
            text = L.Status.noConnection
        } else if let path = connectionPath {
            text = L.Status.connectedVia(path: path.title)
        } else {
            text = L.Status.connecting
        }
        return ConnectionStatus(text: text, connected: !lastRefreshFailed && connectionPath != nil)
    }

    // MARK: Alte Werte

    /// „Stand 14:32 · nicht aktuell“, solange die Werte nicht live sind; sonst nil.
    public var staleText: String? { uiStaleSince.map { L.Status.stale(stand: Fmt.stand($0, now: now())) } }

    // MARK: Große Zahl

    /// „Groß angezeigt: Raumtemperatur“ – nur, wenn die Anlage sie gemeldet hat.
    private var roomIsBig: Bool { appearance.hero == .room && state?.indoorTemperature != nil }

    /// Große Zahl im Kopf: Soll, bei ausgeschalteter Anlage, Lüften oder „Groß angezeigt: Raum“ die Raumtemperatur.
    public var heroValue: String {
        guard let s = state else { return "–" }
        if !s.power || s.mode == .fan || roomIsBig { return Fmt.temp(s.indoorTemperature) }
        return Fmt.target(s.targetTemperature)
    }

    /// Zeile unter der großen Zahl (ein, aus, Lüften, alte Werte). Leer ohne Zustand.
    public var heroCaption: String {
        guard let s = state else { return "" }
        let stale = staleText
        if !s.power { return stale ?? UIText.offCaption }
        if s.mode == .fan { return stale ?? UIText.fanModeCaption }
        let goal = stale ?? goalLine
        return roomIsBig ? L.Status.heroTarget(target: Fmt.target(s.targetTemperature), goal: goal) : goal
    }

    /// Hinweis unter der Raumtemperatur bei ausgeschalteter Anlage; sonst nil.
    public var heroHint: String? { state?.power == false ? UIText.offHint : nil }

    // MARK: Kosten

    /// Kosten heute: „Kosten heute“ bzw. „Kosten seit 08:14“; „unbekannt“ ohne Zählerwert (nie 0 €), „· unsicher“,
    /// wenn der Zähler nicht zur gemessenen Leistung passt.
    public var costLine: CostLine {
        guard let e = todayEnergy else {
            return CostLine(title: L.Cost.title, value: L.Cost.unknown, help: L.Cost.unknownHelp)
        }
        let title = e.sinceLabel.map { L.Cost.titleSince(since: $0) } ?? L.Cost.title
        let money = Fmt.money(e.kWh * pricePerKWh, currency: currency)
        let kwh = Fmt.kwh(e.kWh)
        let total = Fmt.kwh(state?.totalEnergyKWh)
        var help: String
        if e.fromMidnight {
            help = L.Cost.helpMidnight(kwh: kwh, total: total)
        } else if let label = e.sinceLabel {
            help = L.Cost.helpSince(kwh: kwh, since: label, total: total)
        } else {
            help = L.Cost.helpPlain(kwh: kwh, total: total)
        }
        if e.plausible == false { help += "\n" + L.Cost.unsureHelp }
        return CostLine(title: title, value: e.plausible == false ? L.Cost.unsureValue(cost: money) : money, help: help)
    }

    /// Kurzinfo zur Leistung: „Kosten bei dieser Leistung: 0,12 € pro Stunde“.
    public var powerCostHelp: String { L.Cost.perHour(cost: Fmt.money(costPerHour, currency: currency)) }

    // MARK: Menüleiste

    /// Text neben dem Symbol in Menüleiste bzw. Infobereich. `iconTarget`: Soll nur bei laufender Anlage, nicht beim
    /// Lüften.
    public var menuTitle: String? {
        let s = state
        let target = s.flatMap { $0.power && $0.mode != .fan ? Fmt.target($0.targetTemperature) : nil }
        let room = s?.indoorTemperature.map { Fmt.temp($0) }
        switch appearance.menuBarText {
        case .iconOnly: return nil
        case .iconTarget: return target
        case .iconRoom: return room
        case .roomTarget:
            guard let room else { return target }
            return target.map { "\(room) → \($0)" } ?? room
        }
    }

    // MARK: Timer

    /// Chip „Aus in 1 h 30 min“ (Restzeit auf Minuten gerundet); nil ohne Timer.
    public func offTimerChip(now: Date) -> String? {
        guard let off = offAt else { return nil }
        let m = max(0, Int(off.timeIntervalSince(now) / 60.0 + 0.5))
        let left = m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min")
        return L.Status.offTimer(left: left)
    }

    public var offTimerChip: String? { offTimerChip(now: now()) }

    /// Chip „Ein morgen 07:00“; nil ohne Timer.
    public var onTimerChip: String? { onTimerLabel.map { L.Status.onTimer(label: $0) } }

    /// Rückfrage beim Beenden, solange ein Timer gestellt ist; sonst nil.
    public func quitPrompt() -> ConfirmPrompt? { UIText.quitPrompt(off: offAt, on: onAt, now: now()) }

    /// Noch nicht gesicherte WLAN-Zugangsdaten (eine nur über das Midea-Konto eingerichtete Anlage hat keine).
    public var forgetNeedsBackup: Bool { (config?.hasLAN ?? false) && !credentialsBackedUp }

    public func forgetPrompt(host: HostWords = .current) -> ForgetPrompt {
        UIText.forgetPrompt(needsBackup: forgetNeedsBackup, host: host)
    }

    // MARK: Startanzeige

    /// Zuletzt bekannte Werte (höchstens 7 Tage alt); `sample` = `lastKnown` oder letzter Verlaufspunkt.
    public func startupValues(from sample: HistorySample?, now: Date) -> StartupValues? {
        guard let s = sample, now.timeIntervalSince(s.time) < 7 * 86400 else { return nil }
        let main = s.on && s.target != nil ? s.target.map { Fmt.target($0) } ?? "–" : Fmt.temp(s.indoor)
        let stand = Fmt.stand(s.time, now: now)
        var extras: [String] = []
        if s.on { extras.append(L.Status.startupRoom(temp: Fmt.temp(s.indoor))) }
        extras.append(L.Status.startupOutdoor(temp: Fmt.temp(s.outdoor)))
        let caption = s.on ? L.Status.startupTarget(stand: stand) : L.Status.startupRoomOff(stand: stand)
        return StartupValues(main: main, caption: caption, extras: extras,
                             accessibility: L.Status.startupAccessibility(stand: stand, main: main))
    }

    public var startupValues: StartupValues? { startupValues(from: lastKnown, now: now()) }

    /// „Anlage suchen ✓ · Anmelden … · Werte lesen“.
    public var connectStepsLine: String { UIText.connectStepsLine(connectPhase) }

    // MARK: Diagnose

    /// „Live aus der Anlage · alle 30 s · nächste Abfrage in 12 s“.
    public func nextRefreshLine(now: Date) -> String {
        let secs = nextRefresh.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
        return L.Status.nextRefresh(seconds: "\(refreshSeconds)", next: secs.map { "\($0) s" } ?? "…")
    }

    public var nextRefreshLine: String { nextRefreshLine(now: now()) }

    // MARK: Schalter und Darstellung

    /// Gültigkeit der Schalter im aktuellen Modus (ohne Zustand wie im Standardmodus).
    public func availability(_ f: UIOptions.ComfortFeature) -> UIOptions.Availability {
        UIOptions.availability(f, mode: state?.mode ?? ACState().mode)
    }

    /// Die Darstellung entspricht `Appearance.standard` dieser Plattform („Auf Standard zurücksetzen“ ausgegraut).
    public var appearanceIsStandard: Bool { UIOptions.isStandard(appearance) }

    /// Das Aussehen weicht vom gewählten Thema ab („angepasst“, „Thema wiederherstellen“).
    public var appearanceIsCustomized: Bool { appearance.isCustomized }
}
