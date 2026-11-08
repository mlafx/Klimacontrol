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
                    EnergyBars(bars: periods.map { EnergyBar($0, kind: key.kind, price: price, currency: model.currency) }, color: SeriesColors(theme).outdoor,
                               plotWidth: plotWidth, hovered: $hovered)
                        .equatable()
                        .frame(height: chartHeight)
                    Text(UIText.energySummary(periods, price: price, currency: model.currency))
                        .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    Text(hovered ?? UIText.energyLegend).font(.caption).foregroundStyle(.secondary)
                        .frame(minHeight: 32, alignment: .topLeading)
                } else {
                    Text(UIText.energyNoData).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            } else {
                Color.clear.frame(height: chartHeight)
            }
        }
        .padding(12)
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

    init(_ p: EnergyPeriod, kind: EnergyPeriodKind, price: Double, currency: String) {
        id = p.start
        label = UIText.energyPeriodLabel(p, kind: kind)
        value = p.shownKWh ?? 0
        fromMeasurement = p.fromMeasurement
        current = p.current
        complete = p.complete
        tooltip = UIText.energyTooltip(p, kind: kind, price: price, currency: currency)
    }

    /// Nicht nur über die Farbe erkennbar: zusätzlich ein Zeichen über dem Balken (`marker`).
    var opacity: Double {
        if current { return 0.4 }
        if fromMeasurement { return 0.5 }
        return complete ? 1 : 0.7
    }
}

private struct EnergyBars: View, Equatable {
    let bars: [EnergyBar]
    let color: Color
    let plotWidth: Double
    let hovered: Binding<String?>

    nonisolated static func == (a: Self, b: Self) -> Bool { a.bars == b.bars && a.color == b.color && a.plotWidth == b.plotWidth }

    /// Breite eines Balkens: 70 % seines Platzes, höchstens `MainWindowLayout.energyBarMaxWidth`.
    private var barWidth: Double {
        min(MainWindowLayout.energyBarMaxWidth, max(4, plotWidth / Double(max(1, bars.count)) * 0.7)).rounded()
    }

    /// Bei vielen Balken nur jede zweite Beschriftung.
    private var shownLabels: [String] {
        let step = bars.count > 8 ? 2 : 1
        return bars.enumerated().filter { ($0.offset + bars.count - 1) % step == 0 }.map(\.element.label)
    }

    var body: some View {
        Chart(bars) { b in
            BarMark(x: .value(L.Charts.range, b.label), y: .value("kWh", b.value), width: .fixed(barWidth))
                .foregroundStyle(color)
                .opacity(b.opacity)
                .annotation(position: .top, spacing: 2) { marker(b) }
                .accessibilityLabel(b.label)
                .accessibilityValue(b.tooltip)
        }
        .chartYAxisLabel("kWh")
        .chartXAxis {
            AxisMarks(values: shownLabels) { _ in AxisValueLabel() }
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

    @ViewBuilder private func marker(_ b: EnergyBar) -> some View {
        if b.current {
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        } else if b.fromMeasurement {
            Text(L.Charts.approxMarker).font(.caption2).foregroundStyle(.secondary)
        } else if !b.complete {
            Text("…").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
