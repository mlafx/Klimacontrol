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

    public static let refreshChoices: [RefreshChoice] = [
        RefreshChoice(label: "5 Sekunden", seconds: 5), RefreshChoice(label: "10 Sekunden", seconds: 10),
        RefreshChoice(label: "30 Sekunden", seconds: 30), RefreshChoice(label: "1 Minute", seconds: 60),
        RefreshChoice(label: "5 Minuten", seconds: 300),
    ]
    public static let refreshMin = 1
    public static let refreshMax = 600
    public static let refreshCustomLabel = "Eigener Wert …"
    public static let refreshCustomHelp = "1 bis 600 Sekunden."
    /// Darunter bleibt die Verbindung dauerhaft offen, andere Apps kommen nicht an die Anlage.
    public static let refreshWarnBelow = 8
    public static let refreshWarning =
        "Unter 8 s bleibt die Verbindung dauerhaft offen – andere Apps (z. B. die Midea-App) kommen dann nicht an die Anlage."

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

    public static let offTimerChoices: [OffTimerChoice] = [30, 60, 120, 180, 240, 360, 480].map {
        OffTimerChoice(minutes: $0, label: $0 < 60 ? "\($0) Minuten" : "\($0 / 60) Stunde\($0 == 60 ? "" : "n")")
    }

    // MARK: Lüfter

    public struct FanMark: Equatable, Sendable {
        public let label: String
        public let value: Int
    }

    /// Sprungmarken an ihrer Position auf der Skala (1 % ganz links, daneben Leise = 20 %).
    public static let fanMarks: [FanMark] = [
        FanMark(label: "1 %", value: 1), FanMark(label: "Leise", value: 20), FanMark(label: "Niedrig", value: 40),
        FanMark(label: "Mittel", value: 60), FanMark(label: "Hoch", value: 80), FanMark(label: "Max", value: 100),
    ]
    /// Lage des Reglerknopfs bei „Auto“ (die Anlage regelt selbst).
    public static let fanAutoKnob = 60

    public static let fanLockedText = "regelt die Anlage beim Trocknen"
    public static let fanAutoHelp = "Lüfter regelt die Anlage selbst"

    /// Kopfzeile des Lüfters: „automatisch“, „Außengerät leise · 1 %“, „Turbo · 100 %“, „Mittel · 60 %“, „37 %“;
    /// beim Trocknen der feste Text. Eine Funktion, die an ist, ohne dass der Lüfter in ihrer Zone steht (Kachel,
    /// Fernbedienung), wird angehängt.
    public static func fanCaption(_ s: ACState) -> String {
        if s.mode == .dry { return fanLockedText }
        let zones = isAvailable(.turbo, in: s.mode)
        let auto = s.fanSpeed == FanSpeed.auto.rawValue
        let quietOn = zones && s.outSilent == true
        let turboOn = zones && s.turbo
        if zones, !auto, s.fanSpeed == 1, quietOn { return "Außengerät leise · 1 %" }
        if zones, !auto, s.fanSpeed == 100, turboOn { return "Turbo · 100 %" }
        let base: String
        if auto {
            base = "automatisch"
        } else {
            let name = fanMarks.first { $0.value == s.fanSpeed && $0.value != 1 }?.label
            base = name.map { "\($0) · \(s.fanSpeed) %" } ?? "\(s.fanSpeed) %"
        }
        return base + (turboOn ? " · Turbo" : "") + (quietOn ? " · Außengerät leise" : "")
    }

    public static func fanQuietZoneHelp(on: Bool) -> String {
        on ? "Außengerät leise ist an – Klick: zusätzlich Lüfter auf 1 %"
           : "Außengerät leise: 1 % und leises Außengerät – nur beim Kühlen und Heizen"
    }

    public static func fanTurboZoneHelp(on: Bool) -> String {
        on ? "Turbo ist an – Klick: zusätzlich Lüfter auf 100 %"
           : "Turbo: 100 % und Turbo – nur beim Kühlen und Heizen"
    }

    // MARK: Zugangsdaten und Adresse (Einrichtung)

    public static let tokenLength = 128
    public static let keyLength = 64
    public static let defaultPort = 6444
    public static let addressPlaceholder = "192.168.1.20"
    public static let addressExample = "z. B. 192.168.1.20"
    public static let addressOrHostPrompt = "oder Adresse, z. B. 192.168.1.20"
    public static let tokenPrompt = "128 Zeichen (0–9, a–f)"
    public static let keyPrompt = "64 Zeichen (0–9, a–f)"

    // MARK: Verlauf (Graphen)

    public struct ChartRange: Equatable, Sendable {
        public let label: String
        public let seconds: Double
    }

    public static let chartRanges: [ChartRange] = [
        ChartRange(label: "1 h", seconds: 3600), ChartRange(label: "6 h", seconds: 6 * 3600),
        ChartRange(label: "24 h", seconds: 86400), ChartRange(label: "7 Tage", seconds: 7 * 86400),
    ]
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
        case .swing: return Availability(enabled: on, why: "Lamellen schwenken auf und ab")
        case .eco: return Availability(enabled: on, why: "Eco gibt es nur beim Kühlen")
        case .turbo:
            return Availability(enabled: on, why: on
                ? "Turbo an/aus – die Lüfterstufe bleibt. Ganz rechts am Lüfter: Turbo und 100 % zusammen"
                : "Turbo gibt es nur beim Kühlen und Heizen")
        case .outdoorSilent:
            return Availability(enabled: on, why: on
                ? "Verdichter und Lüfter draußen gedrosselt – die Lüfterstufe bleibt. Ganz links am Lüfter: zusätzlich 1 %"
                : "Außengerät leise wirkt nur beim Kühlen und Heizen")
        case .ieco:
            return Availability(enabled: on, why: "iECO = Sparprogramm der Anlage, begrenzt die Leistungsaufnahme in jedem Modus (Eco oben gilt nur beim Kühlen)")
        case .purifier: return Availability(enabled: on, why: nil)
        case .freezeProtection: return Availability(enabled: on, why: "Hält 8 °C – nur im Heizbetrieb")
        case .selfClean:
            return Availability(enabled: on, why: "Selbstreinigung: trocknet und reinigt das Innengerät (ca. 15 Min.)")
        case .display: return Availability(enabled: on, why: "Temperaturanzeige an der Anlage")
        }
    }

    public static let rateHelp = "Begrenzt die Leistungsaufnahme der Anlage – leiser und sparsamer, kühlt/heizt aber langsamer"

    // MARK: Darstellung

    public static func isStandard(_ a: Appearance) -> Bool { a == .standard }
}
