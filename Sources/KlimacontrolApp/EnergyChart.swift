import Charts
import KlimacontrolCore
import SwiftUI

// MARK: - Verbrauch je Tag, Woche, Monat (unter den Graphen)
//
// Gelesen wird im Hintergrund und nur bei anderer Art oder alle 10 Minuten neu (Grafikspeicher, siehe Charts.swift).
// Die Balken sind eine Equatable-Ansicht; Mausbewegung ändert nur den Zustand der Ansicht darum herum.

struct EnergySection: View {
    @Environment(ACController.self) private var model
    @Environment(\.klimaTheme) private var theme
    @Environment(HistoryStore.self) private var history
    @AppStorage(SettingsKey.energyKind) private var kindRaw = UIOptions.energyKindDefault.rawValue
    /// Höhe des Balkendiagramms und Breite seiner Zeichenfläche (für die Höchstbreite der Balken).
    var chartHeight = 150.0
    var plotWidth = 400.0
    var fill = false
    @State private var loaded: Loaded?
    @State private var hovered: String?

    private struct Loaded: Equatable {
        let kind: EnergyPeriodKind
        let periods: [EnergyPeriod]
    }

    private struct Key: Hashable {
        let kind: EnergyPeriodKind
        let slot: Int
    }

    private var kind: EnergyPeriodKind { EnergyPeriodKind(rawValue: kindRaw) ?? UIOptions.energyKindDefault }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 600)) { ctx in
            content(key: Key(kind: kind, slot: Int(ctx.date.timeIntervalSince1970) / 600))
        }
    }

    private func content(key: Key) -> some View {
        let price = model.pricePerKWh
        let periods = loaded?.kind == key.kind ? loaded?.periods ?? [] : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(UIText.energyTitle, systemImage: "chart.bar").font(.subheadline.weight(.medium))
                    .help(UIText.energyHelp)
                Spacer()
                Picker(UIText.energyTitle, selection: Binding(get: { kind }, set: { kindRaw = $0.rawValue })) {
                    ForEach(UIOptions.energyKinds, id: \.kind) { Text($0.label).tag($0.kind) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let periods {
                if periods.contains(where: { $0.shownKWh != nil }) {
                    let style = ChartStyle(theme, mode: nil)
                    EnergyBars(bars: periods.map { EnergyBar($0, kind: key.kind, count: periods.count, price: price, currency: model.currency) },
                               average: UIText.energyAverage(periods), color: style.outdoor, averageColor: style.line,
                               plotWidth: plotWidth, hovered: $hovered)
                        .equatable()
                        .frame(height: chartHeight)
                    // Feste Höhe für Summe und Legende: Sonst änderte die Kurzinfo beim Überfahren die Höhe der Karte
                    // und im Raster damit den Außengraphen daneben (jeder Neuaufbau kostet Grafikspeicher).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            summary(periods, price: price)
                            Spacer(minLength: 12)
                            averageLegend(periods, color: style.line)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            summary(periods, price: price)
                            averageLegend(periods, color: style.line)
                        }
                    }
                    Text(hovered ?? UIText.energyLegend).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    Text(UIText.energyNoData).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            } else {
                Color.clear.frame(height: chartHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .padding(ChartLayout.cardPadding)
        .plainCard(radius: 14)
        .task(id: key) {
            let db = history.db
            let kind = key.kind
            let count = UIOptions.energyChoice(kind).count
            let periods = await Task.detached(priority: .utility) { db.energyPeriods(kind, count: count) }.value
            guard !Task.isCancelled else { return }
            let fresh = Loaded(kind: kind, periods: periods)
            if fresh != loaded { loaded = fresh }
        }
    }

    private func summary(_ periods: [EnergyPeriod], price: Double) -> some View {
        Text(UIText.energySummary(periods, price: price, currency: model.currency))
            .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.8)
    }

    /// Gestrichelte Linie mit „Durchschnitt 2,35 kWh“.
    @ViewBuilder private func averageLegend(_ periods: [EnergyPeriod], color: Color) -> some View {
        if let text = UIText.energyAverageText(periods) {
            HStack(spacing: 5) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 1))
                    p.addLine(to: CGPoint(x: 16, y: 1))
                }
                .stroke(color.opacity(0.6), style: EnergyBars.averageStroke)
                .frame(width: 16, height: 2)
                .accessibilityHidden(true)
                Text(text)
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
        }
    }
}

/// Ein Balken mit den fertigen Texten aus dem Kern.
struct EnergyBar: Equatable, Identifiable {
    let id: Date
    let label: String
    let value: Double
    let fromMeasurement: Bool
    let current: Bool
    let complete: Bool
    let tooltip: String
    /// Wert über dem Balken; nil bei zu vielen Balken.
    let valueText: String?

    init(_ p: EnergyPeriod, kind: EnergyPeriodKind, count: Int, price: Double, currency: String) {
        id = p.start
        label = UIText.energyPeriodLabel(p, kind: kind)
        value = p.shownKWh ?? 0
        fromMeasurement = p.fromMeasurement
        current = p.current
        complete = p.complete
        tooltip = UIText.energyTooltip(p, kind: kind, price: price, currency: currency)
        valueText = UIText.energyBarValue(p, barCount: count)
    }

    /// Geschätzte Balken („ca.“) sind nur blasser; die Legende erklärt das, ein Text über jedem Balken liefe bei vielen Balken ineinander.
    var opacity: Double {
        if current { return 0.4 }
        if fromMeasurement { return 0.5 }
        return complete ? 1 : 0.7
    }
}

struct EnergyBars: View, Equatable {
    let bars: [EnergyBar]
    let average: Double?
    let color: Color
    let averageColor: Color
    let plotWidth: Double
    let hovered: Binding<String?>
    /// Gehört zum Vergleich: ändern sich die Formate zur Laufzeit, baut sich der Graph neu auf.
    var format = FormatProfile.current

    static let averageStroke = StrokeStyle(lineWidth: 1, dash: [4, 3])

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.bars == b.bars && a.average == b.average && a.color == b.color && a.averageColor == b.averageColor
            && a.plotWidth == b.plotWidth && a.format == b.format
    }

    /// Bereich mit Platz über dem höchsten Balken für Wert und Zeichen darüber.
    private var axis: ChartAxis {
        let values = bars.map(\.value) + [average ?? 0]
        let base = ChartAxis.power(values) ?? .fixed(0...1)
        return base.withHeadroom(above: values.max() ?? 0, fraction: bars.contains { $0.valueText != nil } ? 0.24 : 0.12)
    }

    /// Breite eines Balkens: 70 % seines Platzes, höchstens `MainWindowLayout.energyBarMaxWidth`.
    private var barWidth: Double {
        min(MainWindowLayout.energyBarMaxWidth, max(4, plotWidth / Double(max(1, bars.count)) * 0.7)).rounded()
    }

    /// Nur so viele Beschriftungen, wie nebeneinander Platz haben; die letzte bleibt stehen.
    private var shownLabels: [String] {
        let step = ChartAxis.labelStep(count: bars.count, plotWidth: plotWidth, labelLength: bars.map(\.label.count).max() ?? 0)
        return bars.enumerated().filter { ChartAxis.showsLabel(index: $0.offset, count: bars.count, step: step) }
            .map(\.element.label)
    }

    var body: some View {
        let axis = axis
        Chart {
            ForEach(bars) { b in
                BarMark(x: .value(L.Charts.range, b.label), y: .value("kWh", b.value), width: .fixed(barWidth))
                    .foregroundStyle(color)
                    .opacity(b.opacity)
                    .annotation(position: .top, spacing: 2) { marker(b) }
                    .accessibilityLabel(b.label)
                    .accessibilityValue(b.tooltip)
            }
            if let average {
                RuleMark(y: .value("kWh", average))
                    .foregroundStyle(averageColor.opacity(0.6))
                    .lineStyle(Self.averageStroke)
                    .accessibilityHidden(true)
            }
        }
        .valueAxis(axis, shown: axis, unit: "kWh")
        .chartXAxis {
            // Charts kürzt Beschriftungen sonst auf die Breite eines Balkens; der Abstand kommt aus `labelStep`.
            AxisMarks(values: shownLabels) { value in
                AxisValueLabel(collisionResolution: .disabled) {
                    if let label = value.as(String.self) { Text(label).fixedSize() }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard plot.contains(location),
                                  let label = proxy.value(atX: location.x - plot.minX, as: String.self) else {
                                hovered.wrappedValue = nil
                                return
                            }
                            hovered.wrappedValue = bars.first { $0.label == label }?.tooltip
                        case .ended:
                            hovered.wrappedValue = nil
                        }
                    }
            }
        }
    }

    /// Zeichen (läuft noch, Lücke) über dem Wert.
    private func marker(_ b: EnergyBar) -> some View {
        VStack(spacing: 0) {
            if b.current {
                Image(systemName: "clock")
            } else if !b.complete, !b.fromMeasurement {
                Text("…")
            }
            if let v = b.valueText {
                Text(v).monospacedDigit().foregroundStyle(.primary.opacity(0.75))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}
