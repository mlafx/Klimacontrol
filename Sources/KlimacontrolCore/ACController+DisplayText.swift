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
        case .deviceOff: return "Anlage ausgeschaltet oder ohne Strom" + lastSeen(now: now)
        // Startfehler: noch nie geantwortet.
        case .noConnection: return (state == nil ? "Nicht erreichbar" : "Keine Verbindung") + lastSeen(now: now)
        case .connecting: return "Verbinde …" + lastSeen(now: now)
        case .notConfigured: return ""
        case .live: break
        }
        guard let t = lastUpdate else { return "Verbinde …" }
        let secs = Int(now.timeIntervalSince(t))
        let via = connectionPath.map { "Verbunden über \($0.rawValue)" } ?? "Verbunden"
        return secs < 60 ? "\(via) · gerade aktualisiert" : "\(via) · vor \(secs / 60) min aktualisiert"
    }

    /// „· zuletzt vor N min“ – wann die Anlage zuletzt geantwortet hat (leer, wenn noch nie).
    private func lastSeen(now: Date) -> String {
        guard let t = lastUpdate else { return "" }
        let secs = Int(now.timeIntervalSince(t))
        return secs < 60 ? " · zuletzt vor weniger als 1 min" : " · zuletzt vor \(secs / 60) min"
    }

    /// Kurzinfo der Verbindungszeile: Adresse bei WLAN-Einrichtung, sonst „über Midea-Konto“; leer ohne Einrichtung.
    public var connectionTooltip: String {
        guard let c = config else { return "" }
        return c.hasLAN ? "\(c.name) · \(c.ip):\(c.port) · lokal" : "\(c.name) · über Midea-Konto"
    }

    /// Status im Reiter „Verbindung“.
    public var connectionStatus: ConnectionStatus {
        let text: String
        if deviceOffNotice {
            text = "Anlage ausgeschaltet oder ohne Strom"
        } else if lastRefreshFailed {
            text = "Keine Verbindung"
        } else if let path = connectionPath {
            text = "Verbunden über \(path.rawValue)"
        } else {
            text = "Verbinde …"
        }
        return ConnectionStatus(text: text, connected: !lastRefreshFailed && connectionPath != nil)
    }

    // MARK: Alte Werte

    /// „Stand 14:32 · nicht aktuell“, solange die Werte nicht live sind; sonst nil.
    public var staleText: String? { uiStaleSince.map { Fmt.stand($0, now: now()) + " · nicht aktuell" } }

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
        return roomIsBig ? "Soll \(Fmt.target(s.targetTemperature)) · \(goal)" : goal
    }

    /// Hinweis unter der Raumtemperatur bei ausgeschalteter Anlage; sonst nil.
    public var heroHint: String? { state?.power == false ? UIText.offHint : nil }

    // MARK: Kosten

    /// Kosten heute: „Kosten heute“ bzw. „Kosten seit 08:14“; „unbekannt“ ohne Zählerwert (nie 0 €), „· unsicher“,
    /// wenn der Zähler nicht zur gemessenen Leistung passt.
    public var costLine: CostLine {
        guard let e = todayEnergy else {
            return CostLine(title: "Kosten heute", value: "unbekannt",
                            help: "Tagesverbrauch unbekannt – der Zähler der Anlage hat noch keinen Wert geliefert.")
        }
        let title = e.sinceLabel.map { "Kosten " + $0 } ?? "Kosten heute"
        let euro = Fmt.euro(e.kWh * pricePerKWh)
        let since = e.fromMidnight ? " seit Mitternacht" : (e.sinceLabel.map { " " + $0 } ?? "")
        var help = "\(Fmt.kwh(e.kWh)) laut Zähler der Anlage\(since) · Zähler gesamt \(Fmt.kwh(state?.totalEnergyKWh))"
        if e.plausible == false { help += "\nUnsicher: Der Zähler passt nicht zur gemessenen Leistung." }
        return CostLine(title: title, value: e.plausible == false ? euro + " · unsicher" : euro, help: help)
    }

    /// Kurzinfo zur Leistung: „Kosten bei dieser Leistung: 0,12 € pro Stunde“.
    public var powerCostHelp: String { "Kosten bei dieser Leistung: \(Fmt.euro(costPerHour)) pro Stunde" }

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
        return "Aus in \(left)"
    }

    public var offTimerChip: String? { offTimerChip(now: now()) }

    /// Chip „Ein morgen 07:00“; nil ohne Timer.
    public var onTimerChip: String? { onTimerLabel.map { "Ein \($0)" } }

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
        if s.on { extras.append("Raum \(Fmt.temp(s.indoor))") }
        extras.append("Außen \(Fmt.temp(s.outdoor))")
        return StartupValues(main: main, caption: stand + " · " + (s.on ? "Solltemperatur" : "Raumtemperatur · aus"),
                             extras: extras, accessibility: "Zuletzt bekannte Werte, \(stand): \(main)")
    }

    public var startupValues: StartupValues? { startupValues(from: lastKnown, now: now()) }

    /// „Anlage suchen ✓ · Anmelden … · Werte lesen“.
    public var connectStepsLine: String { UIText.connectStepsLine(connectPhase) }

    // MARK: Diagnose

    /// „Live aus der Anlage · alle 30 s · nächste Abfrage in 12 s“.
    public func nextRefreshLine(now: Date) -> String {
        let secs = nextRefresh.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
        return "Live aus der Anlage · alle \(refreshSeconds) s · nächste Abfrage in \(secs.map { "\($0) s" } ?? "…")"
    }

    public var nextRefreshLine: String { nextRefreshLine(now: now()) }

    // MARK: Schalter und Darstellung

    /// Gültigkeit der Schalter im aktuellen Modus (ohne Zustand wie im Standardmodus).
    public func availability(_ f: UIOptions.ComfortFeature) -> UIOptions.Availability {
        UIOptions.availability(f, mode: state?.mode ?? ACState().mode)
    }

    /// Die Darstellung entspricht `Appearance.standard` dieser Plattform („Auf Standard zurücksetzen“ ausgegraut).
    public var appearanceIsStandard: Bool { UIOptions.isStandard(appearance) }
}
