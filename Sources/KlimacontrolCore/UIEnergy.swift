import Foundation

// Anzeige-Katalog zum Verbrauch je Tag, Woche und Monat (Verlauf).

extension UIOptions {
    public struct EnergyKindChoice: Equatable, Sendable {
        public let kind: EnergyPeriodKind
        public let label: String
        /// Wie viele Zeiträume die Ansicht zeigt.
        public let count: Int
    }

    public static var energyKinds: [EnergyKindChoice] {
        [
            EnergyKindChoice(kind: .day, label: L.Energy.Kind.day, count: 14),
            EnergyKindChoice(kind: .week, label: L.Energy.Kind.week, count: 8),
            EnergyKindChoice(kind: .month, label: L.Energy.Kind.month, count: 12),
        ]
    }
    public static let energyKindDefault = EnergyPeriodKind.day

    public static func energyChoice(_ kind: EnergyPeriodKind) -> EnergyKindChoice {
        energyKinds.first { $0.kind == kind } ?? energyKinds[0]
    }

    /// Bis zu so vielen Balken steht der Wert über jedem Balken; bei mehr wäre er nicht mehr lesbar.
    public static let energyValuesMaxBars = 14
}

extension UIText {
    public static var energyTitle: String { L.Energy.title }
    public static var energyHelp: String { L.Energy.help }
    public static var energyLegend: String { L.Energy.legend }
    public static var energyNoData: String { L.Energy.noData }

    /// Tag und Monat ohne führende Nullen nach dem Muster des Profils: „2.11.“, „11/2“.
    private static func plainDayMonth(_ d: Date, calendar: Calendar) -> String {
        var profile = FormatProfile.current
        var pattern = ""
        var last: Character?
        for ch in profile.dayMonthPattern {
            if (ch == "d" || ch == "M" || ch == "L"), ch == last { continue }
            pattern.append(ch)
            last = ch
        }
        profile.dayMonthPattern = pattern
        return Fmt.dayMonth(d, calendar: calendar, profile: profile)
    }

    /// Beschriftung unter dem Balken: „Mo 2.11.“, „KW 45“, „Nov. 2026“ (englisch „Mon 11/2“, „Wk 45“, „Nov 2026“).
    public static func energyPeriodLabel(_ p: EnergyPeriod, kind: EnergyPeriodKind) -> String {
        let cal = EnergyPeriodKind.calendar()
        let c = cal.dateComponents([.weekday, .day, .month, .year, .weekOfYear], from: p.start)
        switch kind {
        case .day:
            return L.Energy.Label.day(weekday: DateWords.weekdayShort(c.weekday ?? 1),
                                      date: plainDayMonth(p.start, calendar: cal))
        case .week: return L.Energy.Label.week(week: "\(c.weekOfYear ?? 0)")
        case .month: return L.Energy.Label.month(month: DateWords.monthShort(c.month ?? 1), year: "\(c.year ?? 0)")
        }
    }

    /// Ausgeschriebener Zeitraum: „Montag, 2. November“, „Kalenderwoche 45 (2.11. – 8.11.)“, „November 2026“.
    public static func energyPeriodName(_ p: EnergyPeriod, kind: EnergyPeriodKind) -> String {
        let cal = EnergyPeriodKind.calendar()
        let c = cal.dateComponents([.weekday, .day, .month, .year, .weekOfYear], from: p.start)
        let month = DateWords.monthLong(c.month ?? 1)
        switch kind {
        case .day:
            return L.Energy.Name.day(weekday: DateWords.weekdayLong(c.weekday ?? 1), month: month, day: "\(c.day ?? 0)")
        case .week:
            let last = cal.date(byAdding: .day, value: -1, to: p.end) ?? p.end
            return L.Energy.Name.week(week: "\(c.weekOfYear ?? 0)", from: plainDayMonth(p.start, calendar: cal),
                                      to: plainDayMonth(last, calendar: cal))
        case .month: return L.Energy.Name.month(month: month, year: "\(c.year ?? 0)")
        }
    }

    /// Kurzinfo bzw. Vorlesetext zum Balken: „Montag, 2. November: 4,20 kWh · 1,26 € (Zähler der Anlage)“.
    public static func energyTooltip(_ p: EnergyPeriod, kind: EnergyPeriodKind, price: Double,
                                     currency: String = UIOptions.currencyDefault) -> String {
        let name = energyPeriodName(p, kind: kind)
        var text: String
        if let kWh = p.kWh {
            text = L.Energy.Tooltip.meter(name: name, kwh: Fmt.kwh(kWh), cost: Fmt.money(kWh * price, currency: currency))
        } else if let m = p.measuredKWh {
            text = L.Energy.Tooltip.measured(name: name, kwh: Fmt.kwh(m), cost: Fmt.money(m * price, currency: currency))
        } else {
            text = L.Energy.Tooltip.noData(name: name)
        }
        if p.current {
            text += L.Energy.Tooltip.current
        } else if !p.complete {
            text += L.Energy.Tooltip.incomplete
        }
        return text
    }

    /// Kosten des Zeitraums: „1,26 €“, aus Messwerten „ca. 1,26 €“, ohne Daten „–“.
    public static func energyCost(_ p: EnergyPeriod, price: Double, currency: String = UIOptions.currencyDefault) -> String {
        guard let v = p.shownKWh else { return "–" }
        let cost = Fmt.money(v * price, currency: currency)
        return p.fromMeasurement ? L.Energy.Cost.approx(cost: cost) : cost
    }

    /// Summenzeile unter den Balken: „Summe 31,40 kWh · 9,42 €“.
    public static func energySummary(_ periods: [EnergyPeriod], price: Double,
                                     currency: String = UIOptions.currencyDefault) -> String {
        let shown = periods.compactMap(\.shownKWh)
        guard !shown.isEmpty else { return L.Energy.Summary.none }
        let total = shown.reduce(0, +)
        var text = L.Energy.Summary.total(kwh: Fmt.kwh(total), cost: Fmt.money(total * price, currency: currency))
        if periods.contains(where: \.fromMeasurement) { text += L.Energy.Summary.partly }
        return text
    }

    /// Durchschnitt der abgeschlossenen Zeiträume mit Wert (gestrichelte Linie); der laufende zählt nicht mit.
    /// nil, wenn es keinen solchen Zeitraum gibt.
    public static func energyAverage(_ periods: [EnergyPeriod]) -> Double? {
        let done = periods.filter { !$0.current }.compactMap(\.shownKWh)
        guard !done.isEmpty else { return nil }
        return done.reduce(0, +) / Double(done.count)
    }

    /// Legende der Durchschnittslinie: „Durchschnitt 2,35 kWh“.
    public static func energyAverageText(_ periods: [EnergyPeriod]) -> String? {
        energyAverage(periods).map { L.Energy.average(kwh: Fmt.kwh($0)) }
    }

    /// Wert über dem Balken ohne Einheit: unter 10 mit einer Nachkommastelle („4,2“), sonst ganz („123“). nil ohne
    /// Wert oder bei mehr als `UIOptions.energyValuesMaxBars` Balken.
    public static func energyBarValue(_ p: EnergyPeriod, barCount: Int) -> String? {
        guard barCount <= UIOptions.energyValuesMaxBars, let v = p.shownKWh else { return nil }
        return Fmt.num(v, v < 9.95 ? 1 : 0)
    }

    /// Eine Kennzahl der Zeile unter dem Leistungsgraphen mit Kurzinfo.
    public struct ChartStat: Equatable, Sendable {
        public let text: String
        public let help: String
    }

    /// Kennzahlen des Zeitraums als Zeile: „Mittel 229 W · Spitze 767 W · 1,10 kWh · 0,33 €“ (Teile mit Kurzinfo).
    public static func chartStats(_ s: HistoryStats, price: Double, currency: String = UIOptions.currencyDefault) -> [ChartStat] {
        [
            ChartStat(text: L.Charts.Stat.avg(value: Fmt.watts(s.avgWatts)), help: L.Charts.Tile.avgHelp),
            ChartStat(text: L.Charts.Stat.peak(value: Fmt.watts(s.peakWatts)), help: L.Charts.Tile.peakHelp),
            ChartStat(text: Fmt.kwh(s.kWh), help: L.Charts.Tile.consumptionHelp),
            ChartStat(text: Fmt.money(s.kWh.map { $0 * price }, currency: currency),
                      help: L.Charts.Tile.costHelp(price: Fmt.num(price, 2), currency: currency)),
        ]
    }
}
