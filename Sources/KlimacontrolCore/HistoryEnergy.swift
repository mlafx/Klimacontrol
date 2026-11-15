import Foundation

/// Länge der Zeiträume, in denen der Verbrauch aufgeführt wird.
public enum EnergyPeriodKind: String, CaseIterable, Sendable {
    case day, week, month

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    /// Ortszeit-Kalender für die Grenzen: Woche ab Montag (ISO), Zone der Ortszeit (`Calendar.current`).
    static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    /// Grenzen der letzten `count` Zeiträume, ältester zuerst; der letzte enthält `now`. Tage mit 23 oder 25 Stunden
    /// ergeben sich aus dem Kalender, nie aus festen 86 400 s.
    func bounds(count: Int, now: Date) -> [(start: Date, end: Date)] {
        let cal = Self.calendar()
        guard count > 0, let first = cal.dateInterval(of: component, for: now) else { return [] }
        return (0..<count).reversed().compactMap { back in
            guard let start = cal.date(byAdding: component, value: -back, to: first.start),
                  let end = cal.date(byAdding: component, value: 1, to: start) else { return nil }
            return (start, end)
        }
    }
}

/// Verbrauch eines Tages, einer Woche oder eines Monats.
public struct EnergyPeriod: Equatable, Sendable, Identifiable {
    public var id: Date { start }
    public var start: Date
    /// Ende des Zeitraums (Beginn des nächsten); beim laufenden Zeitraum liegt es in der Zukunft.
    public var end: Date
    /// Verbrauch laut Zähler der Anlage (Stand am Ende − Stand am Anfang); nil = unbekannt oder unplausibel.
    public var kWh: Double?
    /// Verbrauch aus Leistung × Zeit der Messwerte (Rückfall und Gegenprobe); nil = keine Messwerte.
    public var measuredKWh: Double?
    /// Beide Zählerstände liegen höchstens 15 min neben den Grenzen des Zeitraums.
    public var complete: Bool
    /// Der Zeitraum enthält jetzt.
    public var current: Bool
    /// Mindestens ein Grenzstand ist linear aus den Zählerständen vor und nach einer Lücke im Verlauf geschätzt.
    public var interpolated: Bool

    public init(start: Date, end: Date, kWh: Double?, measuredKWh: Double?, complete: Bool, current: Bool,
                interpolated: Bool = false) {
        self.start = start; self.end = end; self.kWh = kWh; self.measuredKWh = measuredKWh
        self.complete = complete; self.current = current; self.interpolated = interpolated
    }

    /// Verbrauch für die Anzeige: Zähler, sonst Messwerte.
    public var shownKWh: Double? { kWh ?? measuredKWh }
    /// Der angezeigte Wert stammt aus Messwerten, weil der Zähler fehlt.
    public var fromMeasurement: Bool { kWh == nil && measuredKWh != nil }
    /// Der angezeigte Wert ist ein Näherungswert (aus Messwerten oder aus Zählerständen vor und nach einer Lücke).
    public var approximate: Bool { fromMeasurement || interpolated }
}

extension HistoryDB {
    /// So weit darf ein Zählerstand neben einer Grenze liegen, um als Stand an der Grenze zu gelten.
    static let boundarySlack: TimeInterval = 900

    /// Verbrauch der letzten `count` Tage, Wochen oder Monate (ältester zuerst, der letzte ist der laufende).
    /// Zeiträume vor dem ersten Verlaufspunkt fehlen. Eine Abfrage je Grenze, darum für wenige Zeiträume gedacht.
    public func energyPeriods(_ kind: EnergyPeriodKind, count: Int, now: Date = Date()) -> [EnergyPeriod] {
        guard let first = firstTime() else { return [] }
        return kind.bounds(count: count, now: now).compactMap { b in
            b.end > first ? energyPeriod(start: b.start, end: b.end, now: now) : nil
        }
    }

    private func energyPeriod(start: Date, end: Date, now: Date) -> EnergyPeriod {
        let current = now >= start && now < end
        let upper = current ? now : end
        let from = counterAtStart(of: start, until: upper, now: now)
        let to = counterAtEnd(of: upper, notBefore: start, current: current, now: now)
        var kWh: Double?
        if let from, let to, to.time > from.time {
            let delta = to.kWh - from.kWh
            let hours = to.time.timeIntervalSince(from.time) / 3600
            // Rücksprung über die Rundung hinaus oder mehr als die Anlage aufnehmen kann: Zähler unbrauchbar.
            if delta >= -ACController.counterJitterKWh, delta <= ACController.maxPlausibleKW * hours + 0.05 {
                kWh = max(0, delta)
            }
        }
        let estimated = kWh != nil && ((from?.interpolated ?? false) || (to?.interpolated ?? false))
        return EnergyPeriod(start: start, end: end, kWh: kWh, measuredKWh: measuredKWh(from: start, to: upper, now: now),
                            complete: (from?.sure ?? false) && (to?.sure ?? false), current: current,
                            interpolated: estimated)
    }

    typealias CounterBoundary = (time: Date, kWh: Double, sure: Bool, interpolated: Bool)

    /// Stand am Anfang: die letzte Zeile bis 15 min davor, sonst linear aus den Ständen davor und danach geschätzt,
    /// sonst die erste Zeile danach (dann unsicher).
    private func counterAtStart(of start: Date, until: Date, now: Date) -> CounterBoundary? {
        if let b = counter(before: start), start.timeIntervalSince(b.time) <= Self.boundarySlack {
            return (b.time, b.kWh, true, false)
        }
        if let v = interpolatedCounter(at: start, now: now) { return (start, v, false, true) }
        return counter(atOrAfter: start, until: until).map { ($0.time, $0.kWh, false, false) }
    }

    /// Stand am Ende: die letzte Zeile vor der Grenze (bzw. bis jetzt), aber nicht vor dem Anfang des Zeitraums.
    /// Bei einem abgeschlossenen Zeitraum ohne Zeile nahe der Grenze wird geschätzt; der laufende nie.
    private func counterAtEnd(of end: Date, notBefore start: Date, current: Bool, now: Date) -> CounterBoundary? {
        let limit = current ? end.addingTimeInterval(1) : end
        let last = counter(before: limit).flatMap { $0.time >= start ? $0 : nil }
        if let e = last, end.timeIntervalSince(e.time) <= Self.boundarySlack { return (e.time, e.kWh, true, false) }
        if !current, let v = interpolatedCounter(at: end, now: now) { return (end, v, false, true) }
        return last.map { ($0.time, $0.kWh, false, false) }
    }

    /// So groß darf die Lücke zwischen den beiden Zählerständen höchstens sein, damit dazwischen geschätzt wird.
    static let maxInterpolationGap: TimeInterval = 14 * 86400

    /// Zählerstand zur Zeit `t`, linear aus dem letzten Stand davor und dem ersten ab `t` (bis `now`). nil, wenn einer
    /// fehlt, die Lücke über `maxInterpolationGap` liegt oder der Zuwachs nicht plausibel ist.
    func interpolatedCounter(at t: Date, now: Date) -> Double? {
        guard let a = counter(before: t), let b = counter(atOrAfter: t, until: max(now, t)) else { return nil }
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0, span <= Self.maxInterpolationGap else { return nil }
        let delta = b.kWh - a.kWh
        guard delta >= -ACController.counterJitterKWh, delta <= ACController.maxPlausibleKW * span / 3600 + 0.05 else { return nil }
        return a.kWh + max(0, delta) * t.timeIntervalSince(a.time) / span
    }
}

extension HistoryStore {
    /// Siehe `HistoryDB.energyPeriods`.
    public func energyPeriods(_ kind: EnergyPeriodKind, count: Int, now: Date = Date()) -> [EnergyPeriod] {
        db.energyPeriods(kind, count: count, now: now)
    }
}
