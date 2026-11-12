import Charts
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Mauszeiger über dem Graphen: senkrechte Linie, Punkt und großer Wert mit Uhrzeit

/// Was unter dem Mauszeiger gezeigt wird.
struct HoverPick {
    let y: Double
    let color: Color
    let label: HoverLabel
}

/// Eigene Ebene über dem Graphen mit eigenem Zustand: Nur sie zeichnet bei Mausbewegung neu.
struct HoverOverlay: View {
    let proxy: ChartProxy
    let points: [HistorySample]
    let pick: (HistorySample) -> HoverPick?
    @State private var hover: Date?

    /// Durchmesser wie `PointMark.symbolSize(70)` (Fläche in pt²).
    private static let dot = 2 * (70 / Double.pi).squareRoot()

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard plot.contains(location) else { hover = nil; return }
                            hover = proxy.value(atX: location.x - plot.minX, as: Date.self)
                        case .ended:
                            hover = nil
                        }
                    }
                if let t = hover, let p = HistorySample.nearest(in: points, to: t), let h = pick(p),
                   let px = proxy.position(forX: p.time), let py = proxy.position(forY: h.y) {
                    let x = plot.minX + px
                    Rectangle().fill(.secondary.opacity(0.5))
                        .frame(width: 1, height: plot.height)
                        .position(x: x, y: plot.midY)
                    Circle().fill(h.color)
                        .frame(width: Self.dot, height: Self.dot)
                        .position(x: x, y: plot.minY + py)
                    LabelAbove(x: x, bottom: plot.minY) { h.label }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Beschriftung mittig über `x`, unterer Rand an `bottom`, aber ganz innerhalb der Fläche
/// (wie `annotation(position: .top, overflowResolution: .fit(to: .chart))`).
private struct LabelAbove: Layout {
    let x: CGFloat
    let bottom: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let s = v.sizeThatFits(.unspecified)
        let left = min(max(x - s.width / 2, 0), max(0, bounds.width - s.width))
        let top = min(max(bottom - s.height, 0), max(0, bounds.height - s.height))
        v.place(at: CGPoint(x: bounds.minX + left, y: bounds.minY + top), anchor: .topLeading, proposal: ProposedViewSize(s))
    }
}

/// Großer Wert, darunter die Uhrzeit (bei mehr als 24 h mit Wochentag), optional weitere kleine Zeilen.
struct HoverLabel: View {
    let value: String
    let time: Date
    let range: TimeInterval
    var extra: [String] = []

    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
            Text(timeText).font(.caption.weight(.semibold).monospacedDigit())
            ForEach(extra, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var timeText: String {
        let t = Fmt.clock(time)
        guard range > 86400 else { return t }
        return time.formatted(Date.FormatStyle().weekday(.abbreviated).locale(Fmt.locale)) + " " + t
    }
}

extension View {
    /// Ein einziges Element für VoiceOver statt hunderter Punkte: „Leistung: zuletzt 412 W, niedrigster 0 W, höchster 980 W“.
    func chartSummary(_ title: String, _ values: [Double], _ format: (Double) -> String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(Self.summaryText(values, format))
    }

    /// Temperaturgraph für VoiceOver: Raum, mit Außen im selben Graphen auch dessen Werte („…; Außen: zuletzt …“).
    func temperatureSummary(_ w: ChartWindow, outdoor: Bool) -> some View {
        var text = Self.summaryText(w.indoor.compactMap(\.indoor)) { Fmt.temp($0) }
        if outdoor {
            text += "; " + ChartNames.outdoor + ": " + Self.summaryText(w.outdoor.compactMap(\.outdoor)) { Fmt.temp($0) }
        }
        return accessibilityElement(children: .ignore)
            .accessibilityLabel(ChartNames.room)
            .accessibilityValue(text)
    }

    private static func summaryText(_ values: [Double], _ format: (Double) -> String) -> String {
        guard let last = values.last, let lo = values.min(), let hi = values.max() else { return L.Charts.summaryNone }
        return L.Charts.summary(last: format(last), low: format(lo), high: format(hi))
    }

    /// Schlichte Karte statt Glas für die Graphen: Glas rechnet bei jedem Neuzeichnen des Inhalts den Hintergrund
    /// neu ein – bei den Graphen kostet das je Abfrage kurz ~190 MB Grafikspeicher.
    func plainCard(radius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        )
    }

    /// Karte um einen oder mehrere Graphen; im Raster füllt sie die Zeilenhöhe.
    func chartCard(fill: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .padding(ChartLayout.cardPadding)
            .plainCard(radius: 14)
    }
}

extension View {
    /// Y-Achse nach der Rechnung des Kerns, damit Mac und Windows dieselben Gitterlinien zeigen; Zahlen im Format
    /// des Kerns, die Einheit an der obersten Linie. Die Beschriftung steht rechts in fester Breite, damit alle
    /// Graphen einer Karte dieselbe Zeichenfläche haben. `shown` ist der gezeichnete Bereich, falls er über die
    /// Gitterlinien hinausgeht (Modus-Band).
    func valueAxis(_ axis: ChartAxis, shown: ChartAxis? = nil, unit: String) -> some View {
        let ticks = axis.ticks
        return chartYScale(domain: (shown ?? axis).domain).chartYAxis {
            AxisMarks(position: .trailing, values: ticks) { value in
                AxisGridLine()
                AxisValueLabel(horizontalSpacing: ChartLayout.axisSpacing) {
                    if let v = value.as(Double.self) {
                        Text(v == ticks.last ? "\(Fmt.num(v, 0)) \(unit)" : Fmt.num(v, 0))
                            .lineLimit(1)
                            .frame(width: ChartLayout.axisLabelWidth, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Zeitachse auf runden Ortszeiten aus dem Kern (`ChartAxis.timeTicks`), mit den Formaten des Kerns: Die
    /// automatische Beschriftung von Charts mischt Sprache und Region („7 Nov at 22:00“) und kürzt die letzte zu „…“.
    /// Ohne `labels` nur die Gitterlinien (Graphen über dem untersten in einer Karte).
    func timeAxis(domain: ClosedRange<Date>, range: TimeInterval, plotWidth: Double, labels: Bool) -> some View {
        let ticks = ChartAxis.timeTicks(domain: domain, range: range, plotWidth: plotWidth,
                                        labelHalfWidth: ChartAxis.timeLabelHalfWidth(range: range))
        return chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                if labels {
                    AxisTick()
                    AxisValueLabel(collisionResolution: .disabled) {
                        if let d = value.as(Date.self) {
                            Text(range > 86400 ? Fmt.dayMonth(d) : Fmt.clock(d)).fixedSize()
                        }
                    }
                }
            }
        }
    }
}
