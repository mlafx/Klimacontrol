import Charts
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Linke Spalte: Graphen
//
// Das Fenster (Filtern, Ausdünnen, Kennzahlen) wird im Hintergrund gelesen und nur bei neuem Zeitraum bzw.
// Mittelungsfenster neu berechnet (`ChartWindowKey`): Jeder Neuaufbau kostet kurz ~190 MB Grafikspeicher (Metal).
// Marks in Equatable-Ansichten, Mauszeiger-Anzeige als eigene Ebene: Mausbewegung baut die Graphen nicht neu.

struct ChartsPanel: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    @Environment(HistoryStore.self) var history
    /// Nur der Modus (für die Farbe der Leistungskurve) statt `model.state`: sonst liefe dieser Body bei jeder Abfrage.
    let mode: OperationalMode?
    let close: () -> Void
    @AppStorage(SettingsKey.chartRange) private var range = UIOptions.chartRangeDefault
    @Environment(WindowRef.self) private var resizing
    @State private var window = ChartWindow()
    @State private var loaded = false
    @State private var settled = CGSize.zero
    /// Höhe der Spalte ohne die Graphen, je Anordnung gemessen (einspaltig, Raster).
    @State private var overhead: [Bool: Double] = [:]

    var body: some View {
        // Die Zeitscheibe wird ausdrücklich getrieben (alle 30 s), nicht durch zufälliges Neuzeichnen des
        // Hauptfensters: Lange Zeiträume rücken so auch weiter, wenn die Ansicht sonst ruhig ist.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
    }

    private func content(now: Date) -> some View {
        let key = ChartWindowKey(range: range, history: history, sparse: window.data.count < 2, now: now)
        // Während das Fenster seine Größe ändert, bleibt die Fläche der Graphen eingefroren (links ausgerichtet,
        // abgeschnitten): Jede neue Größe ließe Swift Charts alle Graphen neu aufbauen.
        return GeometryReader { geo in
            let size = resizing.isResizing && settled.width > 0 ? settled : geo.size
            ScrollView { column(size: size) }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .onChange(of: geo.size, initial: true) { _, new in if !resizing.isResizing { settled = new } }
                .onChange(of: resizing.isResizing) { _, now in if !now { settled = geo.size } }
        }
        .task(id: key) {
            let db = history.db
            let now = Date()
            let since = now.addingTimeInterval(-key.range)
            let fresh = await Task.detached(priority: .userInitiated) {
                ChartWindow(db.samples(since: since, now: now), stats: db.stats(since: since), now: now)
            }.value
            guard !Task.isCancelled else { return }
            if fresh != window { window = fresh }
            loaded = true
        }
    }

    private func column(size: CGSize) -> some View {
        let w = window
        let grid = MainWindowLayout.historyUsesGrid(width: size.width)
        let heights = MainWindowLayout.chartHeights(columnHeight: size.height, grid: grid, overhead: overhead[grid])
        let inner = size.width - 40
        let cardWidth = grid ? (inner - 16) / 2 : inner
        let hasCharts = loaded && w.data.count >= 2
        let colors = SeriesColors(theme)
        let topHeight = grid ? max(heights.power, heights.temperature) : nil
        let bottomHeight = grid ? max(heights.outdoor, heights.energy) : nil
        let hasOutdoor = hasCharts && !w.outdoor.isEmpty
        let applied: Double
        if grid {
            applied = (hasCharts ? topHeight ?? 0 : 0) + (hasOutdoor || loaded ? bottomHeight ?? 0 : 0)
        } else {
            applied = (hasCharts ? heights.power + heights.temperature : 0) + (hasOutdoor ? heights.outdoor : 0)
                + (loaded ? heights.energy : 0)
        }
        let power = PowerChart(points: w.power, time: w.timeDomain, tint: mode.map { theme.tint(for: $0) } ?? .accentColor,
                               range: range, height: topHeight ?? heights.power, fill: grid)
        let temperature = TemperatureChart(window: w, range: range, colors: colors, height: topHeight ?? heights.temperature, fill: grid)
        let outdoor = OutdoorChart(window: w, range: range, color: colors.outdoor, height: bottomHeight ?? heights.outdoor, fill: grid)
        let energy = EnergySection(chartHeight: bottomHeight ?? heights.energy, plotWidth: (cardWidth - 24 - 50).rounded(.down), fill: grid)
        return VStack(alignment: .leading, spacing: 16) {
            // Schließen rechts wie bei der Diagnose – links säße es neben den Fensterknöpfen.
            HStack {
                Label(L.Charts.title, systemImage: "chart.xyaxis.line").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker(L.Charts.range, selection: $range) {
                    ForEach(UIOptions.chartRanges, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(L.Charts.hideHelp).accessibilityLabel(L.Charts.hide)
            }
            SummaryTiles(avg: w.stats.avgWatts, peak: w.stats.peakWatts, kwh: w.stats.kWh, price: model.pricePerKWh, currency: model.currency)
            if !loaded {
                Color.clear.frame(height: 120)
            } else if w.data.count < 2 {
                Text(L.Charts.tooFew)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            // Reihenfolge für VoiceOver in beiden Anordnungen gleich: Leistung, Temperatur, Außen, Verbrauch.
            if grid {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    if hasCharts {
                        GridRow {
                            power
                            temperature
                        }
                    }
                    GridRow {
                        if hasCharts, !w.outdoor.isEmpty { outdoor }
                        if loaded { energy }
                    }
                }
            } else {
                if hasCharts {
                    power
                    temperature
                    if !w.outdoor.isEmpty { outdoor }
                }
                if loaded { energy }
            }
        }
        .padding(20)
        .frame(width: size.width, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { h in
            let value = max(0, Double(h) - applied)
            if overhead[grid] != value, hasCharts { overhead[grid] = value }
        }
    }
}

/// Wann die Graphen neu gelesen werden. Die Datenbank mittelt auf ~600 Zeitfenster (Länge = Zeitraum / 600, an der
/// Uhrzeit ausgerichtet): Bei 24 h bzw. 7 T ändert sich die Linie sichtbar erst, wenn ein neues Fenster beginnt
/// (alle 2,4 bzw. ~17 min). Bei kurzen Fenstern (1 h: 6 s) zählt jeder neue Punkt (`revision`), ebenso solange noch
/// zu wenig Daten da sind.
struct ChartWindowKey: Hashable {
    let range: Double
    let slot: Int

    @MainActor
    init(range: Double, history: HistoryStore, sparse: Bool, now: Date = Date()) {
        self.range = range
        let bucket = UIOptions.chartBucketSeconds(range: range)
        if bucket < 10 || sparse {
            slot = -1 - history.revision
        } else {
            slot = Int(now.timeIntervalSince1970) / bucket
        }
    }
}

/// Fensterdaten der Graphen, einmal je Änderung berechnet.
struct ChartWindow: Equatable {
    var data: [HistorySample] = []
    var power: [HistorySample] = []
    var indoor: [HistorySample] = []
    var target: [HistorySample] = []
    var outdoor: [HistorySample] = []
    /// Y-Bereiche: Raum/Soll im Temperaturgraph, Außen im eigenen Graphen darunter – je mit voller Höhe.
    /// Gemeinsame Zeitachse aller drei Graphen (sonst beginnt der Außengraph beim ersten Außenwert).
    var timeDomain: ClosedRange<Date>?
    var insideRange: ClosedRange<Double>?
    var outsideRange: ClosedRange<Double>?
    /// Kennzahlen aus allen Punkten der Datenbank, nicht aus den gemittelten Graphenpunkten.
    var stats = HistoryStats()

    init() {}

    /// `now`: Die Zeitachse endet bei „jetzt“, nicht beim letzten Punkt – eine Lücke am Ende bleibt sichtbar.
    init(_ data: [HistorySample], stats: HistoryStats, now: Date = Date()) {
        self.stats = stats
        self.data = data
        power = data.filter { $0.power != nil }
        indoor = data.filter { $0.indoor != nil }
        target = data.filter { $0.target != nil }
        outdoor = data.filter { $0.outdoor != nil }
        if let first = data.first?.time, let last = data.last?.time, first < last { timeDomain = first...max(last, now) }
        insideRange = Self.range(indoor.compactMap(\.indoor) + target.compactMap(\.target))
        outsideRange = Self.range(outdoor.compactMap(\.outdoor))
    }

    /// Min…Max mit 1° Luft, mindestens 4° breit (bei einem einzigen Wert ±2°); `nil` ohne Werte.
    static func range(_ values: [Double]) -> ClosedRange<Double>? {
        guard var lo = values.min(), var hi = values.max() else { return nil }
        lo -= 1
        hi += 1
        if hi - lo < 4 {
            let mid = (lo + hi) / 2
            (lo, hi) = (mid - 2, mid + 2)
        }
        return lo...hi
    }
}

/// Abschnitt einer Reihe: zusammenhängende Messpunkte oder die Brücke über eine Lücke ohne Daten (z. B. App oder
/// Rechner aus). Lücken werden blass gezeichnet, damit man sieht, wo nichts gemessen wurde.
struct ChartSegment {
    let id: Int
    let gap: Bool
    let points: [HistorySample]

    /// Deckkraft einer Lücke (Linie und Fläche).
    static let gapOpacity = 0.22

    /// Teilt die (zeitlich sortierten) Punkte in Läufe und Lücken-Brücken (je zwei Punkte, linear).
    static func split(_ points: [HistorySample], range: TimeInterval) -> [ChartSegment] {
        guard !points.isEmpty else { return [] }
        // Ab dieser Lücke bricht die Linie ab (Regel im Kern).
        let limit = UIOptions.chartGapThreshold(range: range)
        var out: [ChartSegment] = []
        var run: [HistorySample] = [points[0]]
        for p in points.dropFirst() {
            if let last = run.last, p.time.timeIntervalSince(last.time) > limit {
                out.append(ChartSegment(id: out.count, gap: false, points: run))
                out.append(ChartSegment(id: out.count, gap: true, points: [last, p]))
                run = [p]
            } else {
                run.append(p)
            }
        }
        out.append(ChartSegment(id: out.count, gap: false, points: run))
        return out
    }
}

/// Achsen- und Reihennamen der Graphen (VoiceOver-Namen); einmal nachgeschlagen, nicht je Punkt.
enum ChartNames {
    static let time = L.Charts.Axis.time
    static let watt = L.Charts.Axis.watt
    static let segment = L.Charts.Axis.segment
    static let series = L.Charts.Axis.series
    static let room = L.Charts.Series.room
    static let target = L.Charts.Series.target
}

struct SummaryTiles: View {
    let avg: Double?
    let peak: Double?
    let kwh: Double?
    let price: Double
    let currency: String

    var body: some View {
        HStack(spacing: 8) {
            tile("bolt", L.Charts.Tile.avg, Fmt.watts(avg), help: L.Charts.Tile.avgHelp)
            tile("bolt.fill", L.Charts.Tile.peak, Fmt.watts(peak), help: L.Charts.Tile.peakHelp)
            tile("sum", L.Energy.title, Fmt.kwh(kwh), help: L.Charts.Tile.consumptionHelp)
            tile("banknote", L.Charts.Tile.cost, Fmt.money(kwh.map { $0 * price }, currency: currency),
                 help: L.Charts.Tile.costHelp(price: Fmt.num(price, 2), currency: currency))
        }
    }

    private func tile(_ icon: String, _ title: String, _ value: String, help: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .plainCard(radius: 12)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }
}

struct PowerChart: View {
    let points: [HistorySample]
    let time: ClosedRange<Date>?
    let tint: Color
    let range: TimeInterval
    var height = 150.0
    var fill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.Charts.power, systemImage: "bolt").font(.subheadline.weight(.medium))
            PowerMarks(points: points, time: time, tint: tint, range: range)
                .equatable()
                .frame(height: height)
                .chartSummary(L.Charts.power, points.compactMap(\.power)) { Fmt.watts($0) }
        }
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .padding(12)
        .plainCard(radius: 14)
    }
}

/// Nur von den Daten abhängig. IDs sind die Positionen (0 … ~600): Zeitstempel als ID ließen die interne
/// ID-Tabelle von Charts mit jedem weitergerückten Fenster wachsen.
private struct PowerMarks: View, Equatable {
    let points: [HistorySample]
    let time: ClosedRange<Date>?
    let tint: Color
    let range: TimeInterval
    /// Gehört zum Vergleich: ändern sich die Formate zur Laufzeit, baut sich der Graph neu auf.
    var format = FormatProfile.current

    var body: some View {
        Chart {
            ForEach(ChartSegment.split(points, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    // Nicht stapeln: Lauf und Lücken-Brücke teilen sich ihre Nahtpunkte.
                    AreaMark(x: .value(ChartNames.time, s.time), y: .value(ChartNames.watt, s.power ?? 0),
                             series: .value(ChartNames.segment, seg.id), stacking: .unstacked)
                        .foregroundStyle(.linearGradient(colors: [tint.opacity(0.45), tint.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                    LineMark(x: .value(ChartNames.time, s.time), y: .value(ChartNames.watt, s.power ?? 0),
                             series: .value(ChartNames.segment, seg.id))
                        .foregroundStyle(tint)
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
        }
        .chartYAxisLabel("W")
        .chartXScale(domain: time ?? Date().addingTimeInterval(-range)...Date())
        .timeAxis(range: range)
        .chartOverlay { proxy in
            HoverOverlay(proxy: proxy, points: points) { p in
                p.power.map { w in
                    HoverPick(y: w, color: tint, label: HoverLabel(value: Fmt.watts(w), time: p.time, range: range))
                }
            }
        }
    }
}

/// Raum (Ist) und Soll. Außen hat einen eigenen Graphen darunter (`OutdoorChart`): Er liegt meist weit unter
/// Raum/Soll und hätte beide sonst auf einen schmalen Streifen gestaucht.
struct TemperatureChart: View {
    let window: ChartWindow
    let range: TimeInterval
    var colors = SeriesColors()
    var height = 180.0
    var fill = false

    // Neutrale Reihenfarben: Orange/Grün/Blau stehen für die Modi Heizen/Entfeuchten/Kühlen.
    static let indoorColor = SeriesColors.indoorBase
    static let targetColor = SeriesColors.targetBase
    static let outdoorColor = SeriesColors.outdoorBase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.Charts.temperature, systemImage: "thermometer.medium").font(.subheadline.weight(.medium))
            TemperatureMarks(window: window, range: range, colors: colors)
                .equatable()
                .frame(height: height)
                .chartSummary(L.Appearance.Hero.room, window.indoor.compactMap(\.indoor)) { Fmt.temp($0) }
        }
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .padding(12)
        .plainCard(radius: 14)
    }
}

private struct TemperatureMarks: View, Equatable {
    let window: ChartWindow
    let range: TimeInterval
    let colors: SeriesColors
    /// Gehört zum Vergleich: ändern sich die Formate zur Laufzeit, baut sich der Graph neu auf.
    var format = FormatProfile.current

    var body: some View {
        Chart {
            ForEach(ChartSegment.split(window.indoor, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    LineMark(x: .value(ChartNames.time, s.time), y: .value("°C", s.indoor ?? 0), series: .value(ChartNames.series, "\(ChartNames.room) \(seg.id)"))
                        .foregroundStyle(by: .value(ChartNames.series, ChartNames.room))
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
            ForEach(ChartSegment.split(window.target, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    LineMark(x: .value(ChartNames.time, s.time), y: .value("°C", s.target ?? 0), series: .value(ChartNames.series, "\(ChartNames.target) \(seg.id)"))
                        .foregroundStyle(by: .value(ChartNames.series, ChartNames.target))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(seg.gap ? .linear : .stepEnd)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
        }
        .chartForegroundStyleScale([ChartNames.room: colors.indoor, ChartNames.target: colors.target])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYAxisLabel("°C")
        .chartYScale(domain: window.insideRange ?? UIOptions.chartTemperatureAxis)
        .chartXScale(domain: window.timeDomain ?? Date().addingTimeInterval(-range)...Date())
        .timeAxis(range: range)
        .chartOverlay { proxy in
            HoverOverlay(proxy: proxy, points: window.indoor) { p in
                p.indoor.map { y in
                    HoverPick(y: y, color: colors.indoor,
                              label: HoverLabel(value: Fmt.temp(y), time: p.time, range: range,
                                                extra: [p.target.map { L.Charts.hoverTarget(target: Fmt.target($0)) }].compactMap { $0 }))
                }
            }
        }
    }
}

/// Außentemperatur als eigener, flacher Graph unter dem Temperaturgraphen – mit eigener Skala in voller Höhe.
struct OutdoorChart: View {
    let window: ChartWindow
    let range: TimeInterval
    var color = SeriesColors.outdoorBase
    var height = 120.0
    var fill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.Charts.outdoor, systemImage: "sun.max").font(.subheadline.weight(.medium))
            OutdoorMarks(points: window.outdoor, time: window.timeDomain, domain: window.outsideRange ?? UIOptions.chartOutdoorAxis, range: range, color: color)
                .equatable()
                .frame(height: height)
                .chartSummary(L.Charts.outdoor, window.outdoor.compactMap(\.outdoor)) { Fmt.temp($0) }
        }
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .padding(12)
        .plainCard(radius: 14)
    }
}

private struct OutdoorMarks: View, Equatable {
    let points: [HistorySample]
    let time: ClosedRange<Date>?
    let domain: ClosedRange<Double>
    let range: TimeInterval
    let color: Color
    /// Gehört zum Vergleich: ändern sich die Formate zur Laufzeit, baut sich der Graph neu auf.
    var format = FormatProfile.current

    var body: some View {
        Chart {
            ForEach(ChartSegment.split(points, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    AreaMark(x: .value(ChartNames.time, s.time), yStart: .value("°C", domain.lowerBound),
                             yEnd: .value("°C", s.outdoor ?? 0), series: .value(ChartNames.segment, seg.id))
                        .foregroundStyle(.linearGradient(colors: [color.opacity(0.30), color.opacity(0.03)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                    LineMark(x: .value(ChartNames.time, s.time), y: .value("°C", s.outdoor ?? 0), series: .value(ChartNames.segment, seg.id))
                        .foregroundStyle(color)
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
        }
        .chartYAxisLabel("°C")
        .chartYScale(domain: domain)
        .chartXScale(domain: time ?? Date().addingTimeInterval(-range)...Date())
        .timeAxis(range: range)
        .chartOverlay { proxy in
            HoverOverlay(proxy: proxy, points: points) { p in
                p.outdoor.map { y in
                    HoverPick(y: y, color: color, label: HoverLabel(value: Fmt.temp(y), time: p.time, range: range))
                }
            }
        }
    }
}

/// Reihenfarben der Temperaturgraphen im Thema (Standard = neutrale Farben).
struct SeriesColors: Equatable {
    static let indoorBase = Color.primary.opacity(0.85)
    static let targetBase = Color(red: 0.85, green: 0.25, blue: 0.55)
    static let outdoorBase = Color(red: 0.50, green: 0.52, blue: 0.56)

    var indoor = Self.indoorBase
    var target = Self.targetBase
    var outdoor = Self.outdoorBase

    init() {}

    init(_ theme: ThemeStyle) {
        // Raum bleibt die Vordergrundfarbe (hell/dunkel); eine feste Umrechnung verlöre den Wechsel.
        target = theme.series(Self.targetBase)
        outdoor = theme.series(Self.outdoorBase)
    }
}

// MARK: - Mauszeiger über dem Graphen: senkrechte Linie, Punkt und großer Wert mit Uhrzeit

/// Was unter dem Mauszeiger gezeigt wird.
struct HoverPick {
    let y: Double
    let color: Color
    let label: HoverLabel
}

/// Eigene Ebene über dem Graphen mit eigenem Zustand: Nur sie zeichnet bei Mausbewegung neu.
private struct HoverOverlay: View {
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
        let text: String
        if let last = values.last, let lo = values.min(), let hi = values.max() {
            text = L.Charts.summary(last: format(last), low: format(lo), high: format(hi))
        } else {
            text = L.Charts.summaryNone
        }
        return accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(text)
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
}

extension View {
    /// Zeitachse mit den Formaten des Kerns: Die automatische Beschriftung von Charts mischt Sprache und Region
    /// („7 Nov at 22:00“) und wird abgeschnitten.
    func timeAxis(range: TimeInterval) -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range > 86400 ? 7 : 6)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(range > 86400 ? Fmt.dayMonth(d) : Fmt.clock(d))
                    }
                }
            }
        }
    }
}
