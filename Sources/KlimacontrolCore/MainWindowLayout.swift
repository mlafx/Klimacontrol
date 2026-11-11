import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Spaltenbreiten, Mindestgrößen und Fensterrahmen des Mac-Hauptfensters als reine Rechnung (ohne Oberflächentypen),
/// damit Grenzen und Regeln im Kern getestet sind und Windows sie später übernehmen kann.
/// Breiten der Seitenspalten schließen ihre Trennlinie ein.
public enum MainWindowLayout {
    public static let controlWidth = 480.0
    public static let historyMin = 460.0
    /// Bis hierher bekommt der Verlauf zuerst allen zusätzlichen Platz, danach die Diagnose.
    public static let historyBalanced = 700.0
    /// Ab dieser Verlaufsbreite stehen die Graphen als 2 × 2 nebeneinander.
    public static let historyGridFrom = 880.0
    public static let diagnosticsMin = 340.0
    public static let diagnosticsMax = 400.0
    /// Ohne Verlauf und Diagnose ist das Fenster höchstens so breit.
    public static let controlsOnlyMaxWidth = 520.0

    public enum Column: String, Hashable, Sendable { case history, diagnostics }

    public struct Visible: Equatable, Sendable {
        public var history: Bool
        public var diagnostics: Bool
        public init(history: Bool = false, diagnostics: Bool = false) {
            self.history = history
            self.diagnostics = diagnostics
        }
        public func contains(_ c: Column) -> Bool { c == .history ? history : diagnostics }
    }

    public struct Widths: Equatable, Sendable {
        public var history = 0.0
        public var control = MainWindowLayout.controlWidth
        public var diagnostics = 0.0
        /// Rest rechts der Spalten, wenn der Platz nicht gebraucht wird.
        public var margin = 0.0
        public var total: Double { history + control + diagnostics + margin }
    }

    public static func minimumWidth(_ v: Visible) -> Double {
        controlWidth + (v.history ? historyMin : 0) + (v.diagnostics ? diagnosticsMin : 0)
    }

    /// Verteilung: erst die Mindestbreiten, der Überschuss zuerst an den Verlauf bis 700, dann an die Diagnose bis 400,
    /// danach wieder an den Verlauf. Ohne Verlauf bleibt der Rest Rand. Unter der Mindestbreite wird nicht gequetscht.
    public static func widths(total: Double, visible v: Visible) -> Widths {
        var w = Widths()
        w.history = v.history ? historyMin : 0
        w.diagnostics = v.diagnostics ? diagnosticsMin : 0
        var rest = max(0, total - minimumWidth(v))
        if v.history {
            let a = min(rest, historyBalanced - historyMin)
            w.history += a
            rest -= a
        }
        if v.diagnostics {
            let b = min(rest, diagnosticsMax - diagnosticsMin)
            w.diagnostics += b
            rest -= b
        }
        if v.history {
            w.history += rest
        } else {
            w.margin = rest
        }
        return w
    }

    public static func historyUsesGrid(width: Double) -> Bool { width >= historyGridFrom }

    public struct Resolution: Equatable, Sendable {
        public var shown: Visible
        public var hidden: [Column]
    }

    /// „Passt nicht“-Regel: Reicht die verfügbare Breite nicht für die gewünschten Spalten, bleibt nur die zuletzt
    /// geöffnete (Vorgabe: Verlauf); passt auch die nicht, bleibt nur die Steuerung.
    public static func resolve(wanted: Visible, available: Double, lastOpened: Column?) -> Resolution {
        if minimumWidth(wanted) <= available { return Resolution(shown: wanted, hidden: []) }
        var shown = wanted
        var hidden: [Column] = []
        if wanted.history && wanted.diagnostics {
            let keep = lastOpened ?? .history
            let drop: Column = keep == .history ? .diagnostics : .history
            if drop == .history { shown.history = false } else { shown.diagnostics = false }
            hidden.append(drop)
            if minimumWidth(shown) <= available { return Resolution(shown: shown, hidden: hidden) }
        }
        if shown.history { hidden.append(.history) }
        if shown.diagnostics { hidden.append(.diagnostics) }
        return Resolution(shown: Visible(), hidden: hidden)
    }

    // MARK: Höhe

    public static func minimumHeight(_ size: Appearance.SizeClass) -> Double {
        switch size {
        case .compact: 470
        case .normal: 520
        case .large: 600
        }
    }

    /// Höhe der Verlaufsspalte einspaltig mit allen Graphen (Außen eigener Graph) in Mindesthöhe, Kopf, Kennzahlenzeile
    /// und Ränder eingerechnet (geschätzt).
    public static var historyBaseHeight: Double { singleOverhead + baseHeightSum(separateOutdoor: true) }
    /// Geschätzte Höhe ohne die Graphen selbst (Kopf, Überschriften, Kennzahlenzeile, Ränder, Abstände), bis die
    /// Oberfläche sie misst.
    public static let singleOverhead = 340.0
    public static let gridOverhead = 290.0
    /// Höchsthöhe eines Graphen im 2 × 2-Raster.
    public static let gridRowMax = 520.0
    private static let gridTopMin = 180.0
    private static let gridBottomMin = 150.0

    public struct ChartHeights: Equatable, Sendable {
        public var power = 120.0
        public var temperature = 150.0
        public var outdoor = 80.0
        public var energy = 150.0
    }

    private static let chartMax = ChartHeights(power: 260, temperature: 340, outdoor: 180, energy: 240)
    /// Anteile, nach denen zusätzliche Höhe verteilt wird: Leistung, Temperatur, Außen (in dieser Reihenfolge).
    public static let chartWeights = [3.0, 3.0, 2.0]
    public static let chartStep = 20.0

    private static func baseHeightSum(separateOutdoor: Bool) -> Double {
        let b = ChartHeights()
        return b.power + b.temperature + (separateOutdoor ? b.outdoor : 0) + b.energy
    }

    /// Zusätzliche Höhe geht anteilig (3 : 3 : 2) an Leistung, Temperatur und Außen bis zu ihrer Höchsthöhe, danach an
    /// den Verbrauch; Höhen in Stufen von 20 pt, der Rest bleibt leer. Ohne eigenen Außengraphen (`separateOutdoor`
    /// aus: Außen steht im Temperaturgraphen) teilen sich Leistung und Temperatur den Platz, `outdoor` ist dann 0.
    /// Im 2 × 2-Raster (`grid`) teilen sich beide Zeilen die Höhe unter dem Kopf gleichmäßig (je Zeile bis 520 pt).
    /// `overhead` ist die Höhe der Spalte ohne die Graphen (von der Oberfläche gemessen), sonst eine Schätzung.
    public static func chartHeights(columnHeight: Double, grid: Bool = false, overhead: Double? = nil,
                                    separateOutdoor: Bool = true) -> ChartHeights {
        if grid {
            let available = columnHeight - (overhead ?? gridOverhead)
            let share = available / 2
            let top = min(gridRowMax, max(gridTopMin, ((share + 0.001) / chartStep).rounded(.down) * chartStep))
            let bottom = min(gridRowMax, max(gridBottomMin, ((share + 0.001) / chartStep).rounded(.down) * chartStep))
            return ChartHeights(power: top, temperature: top, outdoor: separateOutdoor ? bottom : 0, energy: bottom)
        }
        let base = ChartHeights()
        let baseValues = [base.power, base.temperature, separateOutdoor ? base.outdoor : 0]
        let maxValues = [chartMax.power, chartMax.temperature, separateOutdoor ? chartMax.outdoor : 0]
        var extra = max(0, columnHeight - (overhead ?? singleOverhead) - baseHeightSum(separateOutdoor: separateOutdoor))
        var add = [0.0, 0.0, 0.0]
        var open = separateOutdoor ? [0, 1, 2] : [0, 1]
        while extra > 0.5 && !open.isEmpty {
            let weight = open.map { chartWeights[$0] }.reduce(0, +)
            var used = 0.0
            var next: [Int] = []
            for i in open {
                let room = maxValues[i] - baseValues[i] - add[i]
                let give = min(room, extra * chartWeights[i] / weight)
                add[i] += give
                used += give
                if room - give > 0.5 { next.append(i) }
            }
            extra -= used
            open = next
            if used < 0.5 { break }
        }
        var out = base
        out.power += step(add[0], room: chartMax.power - base.power)
        out.temperature += step(add[1], room: chartMax.temperature - base.temperature)
        out.outdoor = separateOutdoor ? base.outdoor + step(add[2], room: chartMax.outdoor - base.outdoor) : 0
        let energyRoom = chartMax.energy - base.energy
        out.energy += step(min(max(0, extra), energyRoom), room: energyRoom)
        return out
    }

    /// In Stufen abrunden; die volle Höchsthöhe zählt als erreicht.
    private static func step(_ v: Double, room: Double) -> Double {
        v >= room - 0.5 ? room : ((v + 0.001) / chartStep).rounded(.down) * chartStep
    }

    /// Höchstbreite eines Verbrauchsbalkens.
    public static let energyBarMaxWidth = 56.0
}

/// Rahmenrechnung des Hauptfensters (Bildschirmkoordinaten wie AppKit, y nach oben).
public enum MainWindowFrame {
    public enum Side: Equatable, Sendable { case left, right }

    public struct Growth: Equatable, Sendable {
        public var frame: CGRect
        /// Wirklich angebaute Breite (zum späteren Zurücknehmen).
        public var added: Double
    }

    /// Wächst nur um den Fehlbetrag bis `minimumWidth` (links oder rechts) und passt das Ergebnis auf den
    /// Bildschirm ein. `nil`, wenn die Mindestbreite breiter ist als der Bildschirm.
    public static func grow(_ frame: CGRect, toMinimumWidth minimum: Double, side: Side, screen: CGRect) -> Growth? {
        guard minimum <= Double(screen.width) else { return nil }
        let deficit = max(0, minimum - Double(frame.width))
        var f = frame
        f.size.width += CGFloat(deficit)
        if side == .left { f.origin.x -= CGFloat(deficit) }
        return Growth(frame: fit(f, in: screen), added: deficit)
    }

    /// Nimmt höchstens `amount` Breite zurück, aber nie unter `minimumWidth`.
    public static func shrink(_ frame: CGRect, by amount: Double, side: Side, minimumWidth: Double) -> CGRect {
        let take = max(0, min(amount, Double(frame.width) - minimumWidth))
        var f = frame
        f.size.width -= CGFloat(take)
        if side == .left { f.origin.x += CGFloat(take) }
        return f
    }

    /// Kürzt auf `maximum`; `keeping` ist die Seite, die stehen bleibt.
    public static func limitWidth(_ frame: CGRect, to maximum: Double, keeping side: Side) -> CGRect {
        let cut = Double(frame.width) - maximum
        guard cut > 0 else { return frame }
        var f = frame
        f.size.width -= CGFloat(cut)
        if side == .right { f.origin.x += CGFloat(cut) }
        return f
    }

    /// Wächst nach unten (obere Kante bleibt) bis zur Mindesthöhe, soweit der Bildschirm reicht.
    public static func growHeight(_ frame: CGRect, toMinimum minimum: Double, screen: CGRect) -> CGRect {
        let target = min(minimum, Double(screen.height))
        guard Double(frame.height) < target else { return frame }
        var f = frame
        let delta = CGFloat(target) - f.height
        f.size.height += delta
        f.origin.y -= delta
        return fit(f, in: screen)
    }

    /// Rückt das Fenster gerade so weit herein, dass es ganz auf dem Bildschirm liegt (kleiner machen nur, wenn es
    /// größer als der Bildschirm ist).
    public static func fit(_ frame: CGRect, in screen: CGRect) -> CGRect {
        var f = frame
        if f.width > screen.width { f.size.width = screen.width }
        if f.height > screen.height { f.size.height = screen.height }
        if f.maxX > screen.maxX { f.origin.x = screen.maxX - f.width }
        if f.minX < screen.minX { f.origin.x = screen.minX }
        if f.maxY > screen.maxY { f.origin.y = screen.maxY - f.height }
        if f.minY < screen.minY { f.origin.y = screen.minY }
        return f
    }

    /// Fenster, die der Nutzer oder das System an den Bildschirm gebunden hat (maximiert, gekachelt): bildschirmhoch
    /// und an einem seitlichen Rand. Solche Fenster werden nicht vergrößert oder verschoben.
    public static func isConstrained(_ frame: CGRect, screen: CGRect) -> Bool {
        let tall = frame.height >= screen.height - 2
        let atEdge = frame.minX <= screen.minX + 2 || frame.maxX >= screen.maxX - 2
        return tall && atEdge
    }
}
