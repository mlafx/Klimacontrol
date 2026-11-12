import Foundation

/// Y-Achse eines Graphen: Bereich `min…max`, Gitterlinien ab `first` im Abstand `step`. Mac und Windows zeichnen
/// danach; die Windows-Oberfläche rechnet in C# gleich und prüft sich gegen `Tests/Shared/chart-axis-table.json`.
public struct ChartAxis: Equatable, Sendable {
    public let min, max, first, step: Double

    public var domain: ClosedRange<Double> { min...max }

    /// Werte der Gitterlinien innerhalb des Bereichs (Toleranz ein Tausendstel Schritt wie in C#).
    public var ticks: [Double] {
        guard step > 0, first <= max + step / 1000 else { return [] }
        return (0...Int(((max - first) / step + 0.001).rounded(.down))).map { first + Double($0) * step }
    }

    /// Leistung: ab 0, nach oben auf einen runden Schritt aufgerundet (etwa drei Abschnitte). Nicht endliche Werte
    /// zählen bei beiden Achsen nicht (sonst fände die Schrittsuche kein Ende).
    public static func power(_ values: [Double]) -> ChartAxis? {
        guard let highest = values.filter(\.isFinite).max() else { return nil }
        let top = Swift.max(highest, 1)
        let step = Swift.max(1, niceStep(top / 3))
        return ChartAxis(min: 0, max: (top / step).rounded(.up) * step, first: 0, step: step)
    }

    /// Temperatur: kleinster Wert − 1 bis größter + 1, mindestens 4° breit (bei einem Wert ±2°).
    public static func temperature(_ values: [Double]) -> ChartAxis? {
        let values = values.filter(\.isFinite)
        guard var lo = values.min(), var hi = values.max() else { return nil }
        lo -= 1
        hi += 1
        if hi - lo < 4 {
            let mid = (lo + hi) / 2
            (lo, hi) = (mid - 2, mid + 2)
        }
        return gridded(lo, hi)
    }

    /// Bereich nach unten verlängert, sodass der neue Teil `fraction` der Höhe einnimmt (Platz für das Modus-Band unter
    /// der Nulllinie). Gitterlinien bleiben, wo sie waren.
    public func extendedBelow(fraction: Double) -> ChartAxis {
        guard fraction > 0, fraction < 1, max > min else { return self }
        let extra = (max - min) * fraction / (1 - fraction)
        return ChartAxis(min: min - extra, max: max, first: first, step: step)
    }

    /// Bereich nach oben so weit verlängert, dass über `highest` noch `fraction` der Höhe frei bleibt (Werte über den
    /// Verbrauchsbalken). Gitterlinien bleiben.
    public func withHeadroom(above highest: Double, fraction: Double) -> ChartAxis {
        guard highest.isFinite, fraction > 0, fraction < 1 else { return self }
        let needed = min + (highest - min) / (1 - fraction)
        return ChartAxis(min: min, max: Swift.max(max, needed), first: first, step: step)
    }

    /// Achse ohne Daten: genau dieser Bereich, Gitter wie bei Messwerten.
    public static func fixed(_ range: ClosedRange<Double>) -> ChartAxis {
        gridded(range.lowerBound, range.upperBound)
    }

    /// Gitter auf runden Graden (1, 2, 5 mal Zehnerpotenz), höchstens fünf Abschnitte.
    private static func gridded(_ lo: Double, _ hi: Double) -> ChartAxis {
        var step = 1.0
        var magnitude = 1.0
        search: while true {
            for n in [1.0, 2.0, 5.0] where (hi - lo) / (n * magnitude) <= 5 {
                step = n * magnitude
                break search
            }
            magnitude *= 10
        }
        return ChartAxis(min: lo, max: hi, first: (lo / step).rounded(.up) * step, step: step)
    }

    /// Nächster runder Schritt (1, 2, 5 mal Zehnerpotenz) ab `raw`.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let magnitude = pow(10, log10(raw).rounded(.down))
        let n = raw / magnitude
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * magnitude
    }

    /// Jede wievielte Beschriftung unter den Verbrauchsbalken Platz hat. `labelLength` ist die Zeichenzahl der
    /// längsten Beschriftung. Gezeigt werden die Balken mit `showsLabel`, damit die letzte immer stehen bleibt.
    public static func labelStep(count: Int, plotWidth: Double, labelLength: Int) -> Int {
        guard count > 0, plotWidth > 0 else { return 1 }
        let slot = plotWidth / Double(count)
        let needed = Double(labelLength) * labelCharWidth + labelGap
        return Swift.max(1, Int((needed / slot).rounded(.up)))
    }

    /// Ob der Balken `index` von `count` bei Schrittweite `step` beschriftet wird (von hinten gezählt).
    public static func showsLabel(index: Int, count: Int, step: Int) -> Bool {
        (count - 1 - index) % Swift.max(1, step) == 0
    }

    /// Zeichenbreite und Abstand der Achsenbeschriftung: Systemschrift 10 pt (Swift Charts) misst 4,6–5,9 pt je
    /// Zeichen bei Tagen und Monaten, 6,2–6,5 bei den kurzen Wochen („KW 45“); der Abstand fängt den Rest auf.
    static let labelCharWidth = 6.0
    static let labelGap = 10.0

    // MARK: Zeitachse

    /// Abstand der Zeitbeschriftungen je Zeitraum: 1 h alle 10 min, bis 6 h stündlich, bis 24 h alle 4 h, darüber täglich.
    public static func timeStepMinutes(range: TimeInterval) -> Int {
        if range <= 3600 { return 10 }
        if range <= 6 * 3600 { return 60 }
        if range <= 86400 { return 240 }
        return 1440
    }

    /// Halbe Breite einer Zeitbeschriftung für `timeTicks`: Datum („10.11.“) bei mehr als einem Tag, sonst Uhrzeit.
    public static func timeLabelHalfWidth(range: TimeInterval) -> Double { range > 86400 ? 20 : 16 }

    /// Zeitpunkte der Beschriftungen auf runden Ortszeiten in `domain`. Die Beschriftung steht mittig unter ihrem Punkt;
    /// Punkte, deren Beschriftung (halbe Breite `labelHalfWidth`) über den Rand der Zeichenfläche (`plotWidth`) ragte,
    /// entfallen, sonst kürzt Swift Charts die letzte zu „…“.
    public static func timeTicks(domain: ClosedRange<Date>, range: TimeInterval, plotWidth: Double,
                                 labelHalfWidth: Double = 18, calendar: Calendar = .current) -> [Date] {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return [] }
        let minutes = timeStepMinutes(range: range)
        var out: [Date] = []
        var t = calendar.startOfDay(for: domain.lowerBound)
        var guardCount = 0
        while t <= domain.upperBound, guardCount < 10_000 {
            guardCount += 1
            let c = calendar.dateComponents([.hour, .minute], from: t)
            let onGrid = minutes >= 1440 || ((c.hour ?? 0) * 60 + (c.minute ?? 0)) % minutes == 0
            if onGrid, t >= domain.lowerBound {
                let x = t.timeIntervalSince(domain.lowerBound) / span * plotWidth
                if plotWidth <= 0 || (x >= labelHalfWidth && x <= plotWidth - labelHalfWidth) { out.append(t) }
            }
            let next = minutes >= 1440 ? calendar.date(byAdding: .day, value: 1, to: t)
                : calendar.date(byAdding: .minute, value: Swift.min(minutes, 60), to: t)
            guard let next, next > t else { break }
            t = next
        }
        return out
    }
}
