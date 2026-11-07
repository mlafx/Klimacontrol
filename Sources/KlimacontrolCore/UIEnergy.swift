import Foundation

// Anzeige-Katalog zum Verbrauch je Tag, Woche und Monat (Verlauf).

extension UIOptions {
    public struct EnergyKindChoice: Equatable, Sendable {
        public let kind: EnergyPeriodKind
        public let label: String
        /// Wie viele Zeiträume die Ansicht zeigt.
        public let count: Int
    }

    public static let energyKinds: [EnergyKindChoice] = [
        EnergyKindChoice(kind: .day, label: "Tage", count: 14),
        EnergyKindChoice(kind: .week, label: "Wochen", count: 8),
        EnergyKindChoice(kind: .month, label: "Monate", count: 12),
    ]
    public static let energyKindDefault = EnergyPeriodKind.day

    public static func energyChoice(_ kind: EnergyPeriodKind) -> EnergyKindChoice {
        energyKinds.first { $0.kind == kind } ?? energyKinds[0]
    }
}

extension UIText {
    public static let energyTitle = "Verbrauch"
    public static let energyHelp = "Verbrauch laut Zähler der Anlage. Die Kosten rechnen mit dem Strompreis aus den "
        + "Einstellungen, auch für frühere Zeiträume."
    public static let energyLegend = "Heller Balken: Zeitraum läuft noch · ca.: aus Messwerten, Zähler unbekannt · …: Lücke im Verlauf. "
        + "Mit der Maus über einen Balken fahren zeigt Verbrauch und Kosten."
    public static let energyNoData = "Noch zu wenig Daten – der Verbrauch füllt sich, sobald der Verlauf Zählerstände enthält."

    private static let weekdayShort = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
    private static let weekdayLong = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
    private static let monthShort = ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."]
    private static let monthLong = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September",
                                    "Oktober", "November", "Dezember"]

    /// Beschriftung unter dem Balken: „Mo 2.11.“, „KW 45“, „Nov. 2026“.
    public static func energyPeriodLabel(_ p: EnergyPeriod, kind: EnergyPeriodKind) -> String {
        let cal = EnergyPeriodKind.calendar()
        let c = cal.dateComponents([.weekday, .day, .month, .year, .weekOfYear], from: p.start)
        switch kind {
        case .day: return "\(weekdayShort[((c.weekday ?? 1) - 1 + 7) % 7]) \(c.day ?? 0).\(c.month ?? 0)."
        case .week: return "KW \(c.weekOfYear ?? 0)"
        case .month: return "\(monthShort[(((c.month ?? 1) - 1) % 12 + 12) % 12]) \(c.year ?? 0)"
        }
    }

    /// Ausgeschriebener Zeitraum: „Montag, 2. November“, „Kalenderwoche 45 (2.11. – 8.11.)“, „November 2026“.
    public static func energyPeriodName(_ p: EnergyPeriod, kind: EnergyPeriodKind) -> String {
        let cal = EnergyPeriodKind.calendar()
        let c = cal.dateComponents([.weekday, .day, .month, .year, .weekOfYear], from: p.start)
        let month = monthLong[(((c.month ?? 1) - 1) % 12 + 12) % 12]
        switch kind {
        case .day: return "\(weekdayLong[((c.weekday ?? 1) - 1 + 7) % 7]), \(c.day ?? 0). \(month)"
        case .week:
            let last = cal.date(byAdding: .day, value: -1, to: p.end) ?? p.end
            let l = cal.dateComponents([.day, .month], from: last)
            return "Kalenderwoche \(c.weekOfYear ?? 0) (\(c.day ?? 0).\(c.month ?? 0). – \(l.day ?? 0).\(l.month ?? 0).)"
        case .month: return "\(month) \(c.year ?? 0)"
        }
    }

    /// Kurzinfo bzw. Vorlesetext zum Balken: „Montag, 2. November: 4,20 kWh · 1,26 € (Zähler der Anlage)“.
    public static func energyTooltip(_ p: EnergyPeriod, kind: EnergyPeriodKind, price: Double) -> String {
        let name = energyPeriodName(p, kind: kind)
        var text: String
        if let kWh = p.kWh {
            text = "\(name): \(Fmt.kwh(kWh)) · \(Fmt.euro(kWh * price)) (Zähler der Anlage)"
        } else if let m = p.measuredKWh {
            text = "\(name): ca. \(Fmt.kwh(m)) · ca. \(Fmt.euro(m * price)) (aus Messwerten, Zähler unbekannt)"
        } else {
            text = "\(name): keine Daten"
        }
        if p.current {
            text += " · noch nicht abgeschlossen"
        } else if !p.complete {
            text += " · unvollständig (Lücke im Verlauf)"
        }
        return text
    }

    /// Kosten des Zeitraums: „1,26 €“, aus Messwerten „ca. 1,26 €“, ohne Daten „–“.
    public static func energyCost(_ p: EnergyPeriod, price: Double) -> String {
        guard let v = p.shownKWh else { return "–" }
        return (p.fromMeasurement ? "ca. " : "") + Fmt.euro(v * price)
    }

    /// Summenzeile unter den Balken: „Summe 31,40 kWh · 9,42 €“.
    public static func energySummary(_ periods: [EnergyPeriod], price: Double) -> String {
        let shown = periods.compactMap(\.shownKWh)
        guard !shown.isEmpty else { return "Summe –" }
        let total = shown.reduce(0, +)
        var text = "Summe \(Fmt.kwh(total)) · \(Fmt.euro(total * price))"
        if periods.contains(where: \.fromMeasurement) { text += " · teils aus Messwerten" }
        return text
    }
}
