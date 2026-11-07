import Foundation
import MideaKit

/// Auswahllisten, Grenzen und Standardwerte, die jede Oberfläche gleich zeigt (statisch, nicht vom Zustand abhängig).
public enum UIOptions {
    // MARK: Temperatur

    public static let temperatureMin = 16.0
    public static let temperatureMax = 30.0

    // MARK: Abfrage-Takt

    public struct RefreshChoice: Equatable, Sendable {
        public let label: String
        public let seconds: Int
    }

    public static var refreshChoices: [RefreshChoice] {
        [
            RefreshChoice(label: L.Common.seconds(count: 5), seconds: 5),
            RefreshChoice(label: L.Common.seconds(count: 10), seconds: 10),
            RefreshChoice(label: L.Common.seconds(count: 30), seconds: 30),
            RefreshChoice(label: L.Common.minutes(count: 1), seconds: 60),
            RefreshChoice(label: L.Common.minutes(count: 5), seconds: 300),
        ]
    }
    public static let refreshMin = 1
    public static let refreshMax = 600
    public static var refreshCustomLabel: String { L.Options.Refresh.custom }
    public static var refreshCustomHelp: String { L.Options.Refresh.customHelp }
    /// Darunter bleibt die Verbindung dauerhaft offen, andere Apps kommen nicht an die Anlage.
    public static let refreshWarnBelow = 8
    public static var refreshWarning: String { L.Options.Refresh.warning }

    /// Warnung zum eingestellten Takt, nil ab `refreshWarnBelow`.
    public static func refreshWarning(forSeconds s: Int) -> String? { s < refreshWarnBelow ? refreshWarning : nil }

    /// Ist der Wert eine Voreinstellung (sonst „Eigener Wert“)?
    public static func isRefreshPreset(_ seconds: Int) -> Bool { refreshChoices.contains { $0.seconds == seconds } }

    // MARK: Strompreis

    public static let priceMin = 0.0
    public static let priceMax = 1000.0
    public static let currencyDefault = "€"
    public static let currencyMaxLength = 3
    public static let priceFractionDigitsMin = 2
    public static let priceFractionDigitsMax = 4

    // MARK: Leistung begrenzen

    public static let rateChoices = [100, 75, 50]
    public static let rateFallback = 100

    /// Angezeigte Stufe: die gemeldete, ohne Meldung 100 %.
    public static func rateShown(_ reported: Int?) -> Int { reported ?? rateFallback }

    // MARK: Timer „Ausschalten in …“

    public struct OffTimerChoice: Equatable, Sendable {
        public let minutes: Int
        public let label: String
    }

    public static var offTimerChoices: [OffTimerChoice] {
        [30, 60, 120, 180, 240, 360, 480].map {
            OffTimerChoice(minutes: $0, label: $0 < 60 ? L.Common.minutes(count: $0) : L.Common.hours(count: $0 / 60))
        }
    }

    // MARK: Lüfter

    public struct FanMark: Equatable, Sendable {
        public let label: String
        public let value: Int
    }

    /// Sprungmarken an ihrer Position auf der Skala (1 % ganz links, daneben Leise = 20 %).
    public static var fanMarks: [FanMark] {
        [
            FanMark(label: L.Fan.percent(value: "1"), value: 1), FanMark(label: FanSpeed.silent.title, value: 20),
            FanMark(label: FanSpeed.low.title, value: 40), FanMark(label: FanSpeed.medium.title, value: 60),
            FanMark(label: FanSpeed.high.title, value: 80), FanMark(label: FanSpeed.max.title, value: 100),
        ]
    }
    /// Lage des Reglerknopfs bei „Auto“ (die Anlage regelt selbst).
    public static let fanAutoKnob = 60

    public static var fanLockedText: String { L.Options.Fan.locked }
    public static var fanAutoHelp: String { L.Options.Fan.autoHelp }

    /// Kopfzeile des Lüfters: „automatisch“, „Außengerät leise · 1 %“, „Turbo · 100 %“, „Mittel · 60 %“, „37 %“;
    /// beim Trocknen der feste Text. Eine Funktion, die an ist, ohne dass der Lüfter in ihrer Zone steht (Kachel,
    /// Fernbedienung), wird angehängt.
    public static func fanCaption(_ s: ACState) -> String {
        if s.mode == .dry { return fanLockedText }
        let zones = isAvailable(.turbo, in: s.mode)
        let auto = s.fanSpeed == FanSpeed.auto.rawValue
        let quietOn = zones && s.outSilent == true
        let turboOn = zones && s.turbo
        if zones, !auto, s.fanSpeed == 1, quietOn { return L.Options.Fan.quietOutdoorOne }
        if zones, !auto, s.fanSpeed == 100, turboOn { return L.Options.Fan.turboMax }
        let base: String
        if auto {
            base = L.Options.Fan.autoCaption
        } else {
            let name = fanMarks.first { $0.value == s.fanSpeed && $0.value != 1 }?.label
            base = name.map { L.Options.Fan.level(name: $0, value: "\(s.fanSpeed)") } ?? L.Fan.percent(value: "\(s.fanSpeed)")
        }
        var text = base
        if turboOn { text = L.Options.Fan.withTurbo(base: text) }
        if quietOn { text = L.Options.Fan.withQuiet(base: text) }
        return text
    }

    public static func fanQuietZoneHelp(on: Bool) -> String {
        on ? L.Options.Fan.quietZoneHelpOn : L.Options.Fan.quietZoneHelpOff
    }

    public static func fanTurboZoneHelp(on: Bool) -> String {
        on ? L.Options.Fan.turboZoneHelpOn : L.Options.Fan.turboZoneHelpOff
    }

    // MARK: Zugangsdaten und Adresse (Einrichtung)

    public static let tokenLength = 128
    public static let keyLength = 64
    public static let defaultPort = 6444
    public static let addressPlaceholder = "192.168.1.20"
    public static var addressExample: String { L.Options.Address.example }
    public static var addressOrHostPrompt: String { L.Options.Address.orHost }
    public static var tokenPrompt: String { L.Options.Token.prompt }
    public static var keyPrompt: String { L.Options.Key.prompt }

    // MARK: Verlauf (Graphen)

    public struct ChartRange: Equatable, Sendable {
        public let label: String
        public let seconds: Double
    }

    public static var chartRanges: [ChartRange] {
        [
            ChartRange(label: "1 h", seconds: 3600), ChartRange(label: "6 h", seconds: 6 * 3600),
            ChartRange(label: "24 h", seconds: 86400), ChartRange(label: L.Common.days(count: 7), seconds: 7 * 86400),
        ]
    }
    public static let chartRangeDefault = 6 * 3600.0
    /// Die Datenbank mittelt auf etwa so viele Zeitfenster.
    public static let chartWindowCount = 600
    /// Achse der Temperaturgraphen ohne Daten bzw. der Außentemperatur ersatzweise.
    public static let chartTemperatureAxis = 16.0...30.0
    public static let chartOutdoorAxis = 0.0...10.0

    /// Länge eines Zeitfensters in Sekunden (mindestens 1).
    public static func chartBucketSeconds(range: TimeInterval) -> Int { max(1, Int(range / Double(chartWindowCount))) }

    /// Ab dieser Lücke zwischen zwei Punkten bricht die Linie ab: das Dreifache des Punktabstands, mindestens 3 min.
    public static func chartGapThreshold(range: TimeInterval) -> TimeInterval {
        max(180, 3 * max(1, range / Double(chartWindowCount)))
    }

    // MARK: Gültigkeit je Modus

    /// Schalter, die nicht in jedem Modus gelten.
    public enum ComfortFeature: String, CaseIterable, Sendable {
        case swing, eco, turbo, outdoorSilent, ieco, purifier, freezeProtection, selfClean, display
    }

    public struct Availability: Equatable, Sendable {
        public let enabled: Bool
        /// Kurzinfo bzw. Grund, warum der Schalter gesperrt ist; nil = die Beschriftung genügt.
        public let why: String?
    }

    /// Einzige Quelle für „gilt im Modus“: Eco nur Kühlen, Turbo und Außengerät leise nur Kühlen/Heizen, Frostschutz
    /// nur Heizen. `setMode`, `setEco`, `setTurbo` und die Lüfter-Zonen benutzen dieselbe Regel.
    public static func isAvailable(_ f: ComfortFeature, in mode: OperationalMode) -> Bool {
        switch f {
        case .eco: return mode == .cool
        case .turbo, .outdoorSilent: return mode == .cool || mode == .heat
        case .freezeProtection: return mode == .heat
        case .swing, .ieco, .purifier, .selfClean, .display: return true
        }
    }

    public static func availability(_ f: ComfortFeature, mode: OperationalMode) -> Availability {
        let on = isAvailable(f, in: mode)
        switch f {
        case .swing: return Availability(enabled: on, why: L.Availability.swing)
        case .eco: return Availability(enabled: on, why: L.Availability.eco)
        case .turbo: return Availability(enabled: on, why: on ? L.Availability.turboOn : L.Availability.turboOff)
        case .outdoorSilent:
            return Availability(enabled: on, why: on ? L.Availability.outdoorSilentOn : L.Availability.outdoorSilentOff)
        case .ieco: return Availability(enabled: on, why: L.Availability.ieco)
        case .purifier: return Availability(enabled: on, why: nil)
        case .freezeProtection: return Availability(enabled: on, why: L.Availability.freezeProtection)
        case .selfClean: return Availability(enabled: on, why: L.Availability.selfClean)
        case .display: return Availability(enabled: on, why: L.Availability.display)
        }
    }

    public static var rateHelp: String { L.Options.rateHelp }

    // MARK: Darstellung

    public static func isStandard(_ a: Appearance) -> Bool { a == .standard }
}
