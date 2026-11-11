import Charts
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Linke Spalte: Graphen
//
// Das Fenster (Filtern, Ausdünnen, Kennzahlen) wird im Hintergrund gelesen und nur bei neuem Zeitraum bzw.
// Mittelungsfenster neu berechnet (`ChartWindowKey`): Jeder Neuaufbau kostet kurz ~190 MB Grafikspeicher (Metal).
// Marks in Equatable-Ansichten, Mauszeiger-Anzeige als eigene Ebene: Mausbewegung baut die Graphen nicht neu.
// Einspaltig stehen Leistung, Temperatur und Außen in einer Karte, bleiben aber getrennte `Chart`-Ansichten: Ein
// gemeinsames `Chart` baute bei jeder Änderung einer Reihe alle neu auf.

struct ChartsPanel: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    @Environment(HistoryStore.self) var history
    /// Nur der Modus (für die Farbe der Sollkurve) statt `model.state`: sonst liefe dieser Body bei jeder Abfrage.
    let mode: OperationalMode?
    let close: () -> Void
    @AppStorage(SettingsKey.chartRange) private var range = UIOptions.chartRangeDefault
    @Environment(WindowRef.self) private var resizing
    @State private var window = ChartWindow()
    @State private var loaded = false
    @State private var settled = CGSize.zero
    /// Höhe der Spalte ohne die Graphen, je Anordnung gemessen (Raster ja/nein, eigener Außengraph ja/nein).
    @State private var overhead: [Int: Double] = [:]

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
            let range = key.range
            let since = now.addingTimeInterval(-range)
            let fresh = await Task.detached(priority: .userInitiated) {
                ChartWindow(db.samples(since: since, now: now), stats: db.stats(since: since), range: range, now: now)
            }.value
            guard !Task.isCancelled else { return }
            if fresh != window { window = fresh }
            loaded = true
        }
    }

    private func column(size: CGSize) -> some View {
        let w = window
        let combined = model.appearance.temperatureCombined
        let grid = MainWindowLayout.historyUsesGrid(width: size.width)
        let layoutKey = (grid ? 1 : 0) + (combined ? 2 : 0)
        let heights = MainWindowLayout.chartHeights(columnHeight: size.height, grid: grid, overhead: overhead[layoutKey],
                                                    separateOutdoor: !combined)
        let inner = size.width - 40
        let cardWidth = grid ? (inner - 16) / 2 : inner
        let plotWidth = max(0, (cardWidth - 2 * ChartLayout.cardPadding - ChartLayout.axisWidth).rounded(.down))
        let hasCharts = loaded && w.data.count >= 2
        let separateOutdoor = hasCharts && !combined && !w.outdoor.isEmpty
        let style = ChartStyle(theme, mode: mode)
        // Ohne Datenbank gibt es auch keinen Verbrauch; der Hinweis oben sagt, warum.
        let available = history.db.isOpen
        let showsEnergy = loaded && available
        // Im Raster ohne eigenen Außengraphen nimmt der Verbrauch die ganze untere Zeile: ruhiger als ein leerer Platz.
        let energyWide = grid && !separateOutdoor
        let topHeight = max(heights.power, heights.temperature)
        let bottomHeight = separateOutdoor ? max(heights.outdoor, heights.energy) : heights.energy
        let applied: Double
        if grid {
            applied = (hasCharts ? topHeight : 0) + (separateOutdoor || showsEnergy ? bottomHeight : 0)
        } else {
            applied = (hasCharts ? heights.power + heights.temperature : 0) + (separateOutdoor ? heights.outdoor : 0)
                + (showsEnergy ? heights.energy : 0)
        }
        let stats = UIText.chartStats(w.stats, price: model.pricePerKWh, currency: model.currency)
        let power = PowerSection(window: w, range: range, style: style, stats: stats,
                                 height: grid ? topHeight : heights.power, plotWidth: plotWidth, showsTime: grid)
        let temperature = TemperatureSection(window: w, range: range, style: style, combined: combined,
                                             height: grid ? topHeight : heights.temperature, plotWidth: plotWidth,
                                             showsTime: grid || !separateOutdoor)
        let outdoor = OutdoorSection(window: w, range: range, style: style, height: grid ? bottomHeight : heights.outdoor,
                                     plotWidth: plotWidth, fill: grid)
        let energyWidth = energyWide ? inner : cardWidth
        let energy = EnergySection(chartHeight: grid ? bottomHeight : heights.energy,
                                   plotWidth: max(0, (energyWidth - 2 * ChartLayout.cardPadding - ChartLayout.axisWidth).rounded(.down)),
                                   fill: grid)
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
            if !loaded {
                Color.clear.frame(height: 120)
            } else if w.data.count < 2 {
                Text(available ? L.Charts.tooFew : L.Charts.unavailable)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            // Reihenfolge für VoiceOver in beiden Anordnungen gleich: Leistung, Temperatur, Außen, Verbrauch.
            if grid {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    if hasCharts {
                        GridRow {
                            power.chartCard(fill: true)
                            temperature.chartCard(fill: true)
                        }
                    }
                    GridRow {
                        if separateOutdoor { outdoor.chartCard(fill: true) }
                        if showsEnergy { energy.gridCellColumns(energyWide ? 2 : 1) }
                    }
                }
            } else {
                if hasCharts {
                    VStack(alignment: .leading, spacing: 0) {
                        power
                        ChartDivider()
                        temperature
                        if separateOutdoor {
                            ChartDivider()
                            outdoor
                        }
                    }
                    .chartCard(fill: false)
                }
                if showsEnergy { energy }
            }
        }
        .padding(20)
        .frame(width: size.width, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { h in
            let value = max(0, Double(h) - applied)
            if overhead[layoutKey] != value, hasCharts { overhead[layoutKey] = value }
        }
    }
}

/// Maße, die alle Graphen teilen: Mit gleich breiter Y-Achsenspalte stehen die Graphen einer Karte bündig untereinander
/// und teilen sich die Zeitachse.
enum ChartLayout {
    static let cardPadding = 12.0
    /// Breite der Beschriftung der Y-Achse (rechts) und Abstand zur Zeichenfläche.
    static let axisLabelWidth = 46.0
    static let axisSpacing = 6.0
    static var axisWidth: Double { axisLabelWidth + axisSpacing }
    /// Modus-Band unter der Leistung: Höhe und Abstand zur Nulllinie.
    static let bandHeight = 4.0
    static let bandGap = 5.0
    static let lineWidth = 1.75
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
    /// Gemessene Außenwerte (Anzeige unter dem Mauszeiger) und die geglättete Linie mit denselben Zeiten.
    var outdoor: [HistorySample] = []
    var outdoorLine: [HistorySample] = []
    /// Zeiten, in denen die Anlage lief, je Betriebsart (Modus-Band).
    var modeRuns: [HistorySample.ModeRun] = []
    /// Gemeinsame Zeitachse aller Graphen (sonst beginnt der Außengraph beim ersten Außenwert).
    var timeDomain: ClosedRange<Date>?
    var powerAxis: ChartAxis?
    /// Raum und Soll; mit Außen im selben Graphen die gemeinsame Achse über alle drei Reihen.
    var insideAxis: ChartAxis?
    var combinedAxis: ChartAxis?
    var outsideAxis: ChartAxis?
    /// Kennzahlen aus allen Punkten der Datenbank, nicht aus den gemittelten Graphenpunkten.
    var stats = HistoryStats()

    init() {}

    /// `now`: Die Zeitachse endet bei „jetzt“, nicht beim letzten Punkt – eine Lücke am Ende bleibt sichtbar.
    init(_ data: [HistorySample], stats: HistoryStats, range: TimeInterval, now: Date = Date()) {
        self.stats = stats
        self.data = data
        power = data.filter { $0.power != nil }
        indoor = data.filter { $0.indoor != nil }
        target = data.filter { $0.target != nil }
        outdoor = data.filter { $0.outdoor != nil }
        let gap = UIOptions.chartGapThreshold(range: range)
        outdoorLine = HistorySample.smoothedOutdoor(outdoor, span: HistorySample.outdoorSmoothingSpan(range: range), gapLimit: gap)
        modeRuns = HistorySample.modeRuns(data, gapLimit: gap)
        if let first = data.first?.time, let last = data.last?.time, first < last { timeDomain = first...max(last, now) }
        powerAxis = ChartAxis.power(power.compactMap(\.power))
        let inside = indoor.compactMap(\.indoor) + target.compactMap(\.target)
        insideAxis = ChartAxis.temperature(inside)
        combinedAxis = ChartAxis.temperature(inside + outdoor.compactMap(\.outdoor))
        outsideAxis = ChartAxis.temperature(outdoor.compactMap(\.outdoor))
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
    static let outdoor = L.Charts.Series.outdoor
}

/// Farben der Graphen aus dem Thema: Leistung und Raum in der Vordergrundfarbe, Soll in der Modusfarbe, Außen neutral
/// grau, das Modus-Band je Betriebsart. Farbe nur mit Bedeutung; die Reihen unterscheiden sich zusätzlich im Strich.
struct ChartStyle: Equatable {
    static let outdoorBase = Color(red: 0.50, green: 0.52, blue: 0.56)

    var line = Color.primary.opacity(0.85)
    var target = Color.accentColor
    var outdoor = Self.outdoorBase
    var modes: [OperationalMode: Color] = [:]

    init() {}

    init(_ theme: ThemeStyle, mode: OperationalMode?) {
        // Vordergrund bleibt `primary` (hell/dunkel); eine feste Umrechnung verlöre den Wechsel.
        target = theme.tint(for: mode)
        outdoor = theme.series(Self.outdoorBase)
        modes = Dictionary(uniqueKeysWithValues: OperationalMode.allCases.map { ($0, theme.tint(for: $0)) })
    }

    func color(for mode: OperationalMode) -> Color { modes[mode] ?? target }

    static let targetStroke = StrokeStyle(lineWidth: ChartLayout.lineWidth, dash: [5, 3])
    static let outdoorStroke = StrokeStyle(lineWidth: ChartLayout.lineWidth + 0.25, lineCap: .round, dash: [0.5, 3.5])
    static let solidStroke = StrokeStyle(lineWidth: ChartLayout.lineWidth, lineCap: .round, lineJoin: .round)
}

// MARK: - Abschnitte (Überschrift, Graph, Zeile darunter)

private struct ChartSectionTitle: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.medium))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Feine Trennlinie zwischen den Graphen einer Karte.
private struct ChartDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
            .padding(.vertical, 10)
            .accessibilityHidden(true)
    }
}

struct PowerSection: View {
    let window: ChartWindow
    let range: TimeInterval
    let style: ChartStyle
    let stats: [UIText.ChartStat]
    let height: Double
    let plotWidth: Double
    let showsTime: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChartSectionTitle(title: L.Charts.power, icon: "bolt")
            PowerMarks(points: window.power, runs: window.modeRuns, axis: window.powerAxis ?? .fixed(0...3),
                       time: window.timeDomain, style: style, range: range, height: height, plotWidth: plotWidth,
                       showsTime: showsTime)
                .equatable()
                .frame(height: height)
                .chartSummary(L.Charts.power, window.power.compactMap(\.power)) { Fmt.watts($0) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    ModeLegend(runs: window.modeRuns, style: style)
                    Spacer(minLength: 12)
                    StatsLine(stats: stats)
                }
                VStack(alignment: .leading, spacing: 4) {
                    StatsLine(stats: stats)
                    ModeLegend(runs: window.modeRuns, style: style)
                }
            }
        }
    }
}

/// „Mittel 229 W · Spitze 767 W · 1,10 kWh · 0,33 €“; jeder Teil mit Kurzinfo und als eigenes Element für VoiceOver.
private struct StatsLine: View {
    let stats: [UIText.ChartStat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                if i > 0 { Text(" · ").accessibilityHidden(true) }
                Text(s.text).help(s.help).accessibilityHint(s.help)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Legende des Modus-Bands: Farbstreifen und Name je Betriebsart, die im Zeitraum vorkam.
private struct ModeLegend: View {
    let runs: [HistorySample.ModeRun]
    let style: ChartStyle

    private var modes: [OperationalMode] {
        var seen: [OperationalMode] = []
        for r in runs where !seen.contains(r.mode) { seen.append(r.mode) }
        return seen
    }

    var body: some View {
        if !modes.isEmpty {
            HStack(spacing: 10) {
                ForEach(modes, id: \.self) { m in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(style.color(for: m))
                            .frame(width: 14, height: ChartLayout.bandHeight)
                        Text(m.title)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(L.Charts.modeBandHelp)
            .accessibilityElement(children: .combine)
            .accessibilityHint(L.Charts.modeBandHelp)
        }
    }
}

/// Linienmuster in der Legende (durchgezogen, gestrichelt, gepunktet).
private struct LegendItem: View {
    let title: String
    let color: Color
    let stroke: StrokeStyle

    var body: some View {
        HStack(spacing: 5) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 1.5))
                p.addLine(to: CGPoint(x: 16, y: 1.5))
            }
            .stroke(color, style: stroke)
            .frame(width: 16, height: 3)
            Text(title)
        }
    }
}

struct TemperatureSection: View {
    let window: ChartWindow
    let range: TimeInterval
    let style: ChartStyle
    let combined: Bool
    let height: Double
    let plotWidth: Double
    let showsTime: Bool

    private var showsOutdoor: Bool { combined && !window.outdoor.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ChartSectionTitle(title: L.Charts.temperature, icon: "thermometer.medium")
                Spacer(minLength: 12)
                HStack(spacing: 12) {
                    LegendItem(title: ChartNames.room, color: style.line, stroke: ChartStyle.solidStroke)
                    LegendItem(title: ChartNames.target, color: style.target, stroke: ChartStyle.targetStroke)
                    if showsOutdoor {
                        LegendItem(title: ChartNames.outdoor, color: style.outdoor, stroke: ChartStyle.outdoorStroke)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).fixedSize()
                .accessibilityHidden(true)
            }
            TemperatureMarks(window: window, range: range, style: style, outdoor: showsOutdoor, plotWidth: plotWidth,
                             showsTime: showsTime)
                .equatable()
                .frame(height: height)
                .temperatureSummary(window, outdoor: showsOutdoor)
        }
    }
}

struct OutdoorSection: View {
    let window: ChartWindow
    let range: TimeInterval
    let style: ChartStyle
    let height: Double
    let plotWidth: Double
    var fill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChartSectionTitle(title: L.Charts.outdoor, icon: "sun.max")
            OutdoorMarks(line: window.outdoorLine, measured: window.outdoor, time: window.timeDomain,
                         axis: window.outsideAxis ?? .fixed(UIOptions.chartOutdoorAxis), range: range, color: style.outdoor,
                         plotWidth: plotWidth)
                .equatable()
                // Im Raster so hoch wie die Karte: Die Verbrauchskarte daneben bestimmt die Zeilenhöhe (Summe, Legende)
                // und hat eine feste Höhe je Graphenhöhe, darum wächst auch dieser Graph nur in deren 20-pt-Stufen.
                .frame(minHeight: height, idealHeight: height, maxHeight: fill ? .infinity : height)
                .chartSummary(L.Charts.outdoor, window.outdoor.compactMap(\.outdoor)) { Fmt.temp($0) }
        }
    }
}

// MARK: - Graphen (nur von den Daten abhängig)
//
// IDs sind die Positionen (0 … ~600): Zeitstempel als ID ließen die interne ID-Tabelle von Charts mit jedem
// weitergerückten Fenster wachsen.

private struct PowerMarks: View, Equatable {
    let points: [HistorySample]
    let runs: [HistorySample.ModeRun]
    let axis: ChartAxis
    let time: ClosedRange<Date>?
    let style: ChartStyle
    let range: TimeInterval
    let height: Double
    let plotWidth: Double
    let showsTime: Bool
    /// Gehört zum Vergleich: ändern sich die Formate zur Laufzeit, baut sich der Graph neu auf.
    var format = FormatProfile.current

    /// Unter der Nulllinie liegt das Modus-Band; der Bereich wird dafür nach unten verlängert (Höhe der Zeichenfläche
    /// geschätzt: Graph ohne Zeitbeschriftung).
    private var shown: ChartAxis {
        let plot = max(40, height - (showsTime ? 22 : 4))
        return axis.extendedBelow(fraction: (ChartLayout.bandHeight + ChartLayout.bandGap) / plot)
    }

    var body: some View {
        let shown = shown
        let bandTop = shown.min + (axis.min - shown.min) * ChartLayout.bandHeight / (ChartLayout.bandHeight + ChartLayout.bandGap)
        let domain = time ?? Date().addingTimeInterval(-range)...Date()
        Chart {
            ForEach(runs.indices, id: \.self) { i in
                let r = runs[i]
                RectangleMark(xStart: .value(ChartNames.time, r.start), xEnd: .value(ChartNames.time, r.end),
                              yStart: .value(ChartNames.watt, shown.min), yEnd: .value(ChartNames.watt, bandTop))
                    .foregroundStyle(style.color(for: r.mode))
            }
            ForEach(ChartSegment.split(points, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    // Nicht stapeln: Lauf und Lücken-Brücke teilen sich ihre Nahtpunkte.
                    AreaMark(x: .value(ChartNames.time, s.time), yStart: .value(ChartNames.watt, 0),
                             yEnd: .value(ChartNames.watt, s.power ?? 0), series: .value(ChartNames.segment, seg.id))
                        .foregroundStyle(style.line.opacity(0.07))
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                    LineMark(x: .value(ChartNames.time, s.time), y: .value(ChartNames.watt, s.power ?? 0),
                             series: .value(ChartNames.segment, seg.id))
                        .foregroundStyle(style.line)
                        .lineStyle(ChartStyle.solidStroke)
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
        }
        .valueAxis(axis, shown: shown, unit: "W")
        .chartXScale(domain: domain)
        .timeAxis(domain: domain, range: range, plotWidth: plotWidth, labels: showsTime)
        .chartOverlay { proxy in
            HoverOverlay(proxy: proxy, points: points) { p in
                p.power.map { w in
                    HoverPick(y: w, color: style.line, label: HoverLabel(value: Fmt.watts(w), time: p.time, range: range))
                }
            }
        }
    }
}

/// Raum (Ist) und Soll, auf Wunsch mit Außen. Ohne Außen hat dieser Graph eine eigene Skala: Außen liegt meist weit
/// unter Raum/Soll und hätte beide sonst auf einen schmalen Streifen gestaucht.
private struct TemperatureMarks: View, Equatable {
    let window: ChartWindow
    let range: TimeInterval
    let style: ChartStyle
    let outdoor: Bool
    let plotWidth: Double
    let showsTime: Bool
    /// Gehört zum Vergleich: ändern sich die Formate zur Laufzeit, baut sich der Graph neu auf.
    var format = FormatProfile.current

    var body: some View {
        let axis = (outdoor ? window.combinedAxis : window.insideAxis) ?? .fixed(UIOptions.chartTemperatureAxis)
        let domain = window.timeDomain ?? Date().addingTimeInterval(-range)...Date()
        Chart {
            if outdoor {
                ForEach(ChartSegment.split(window.outdoorLine, range: range), id: \.id) { seg in
                    ForEach(seg.points.indices, id: \.self) { i in
                        let s = seg.points[i]
                        LineMark(x: .value(ChartNames.time, s.time), y: .value("°C", s.outdoor ?? 0),
                                 series: .value(ChartNames.series, "\(ChartNames.outdoor) \(seg.id)"))
                            .foregroundStyle(style.outdoor)
                            .lineStyle(ChartStyle.outdoorStroke)
                            .interpolationMethod(seg.gap ? .linear : .monotone)
                            .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                    }
                }
            }
            ForEach(ChartSegment.split(window.target, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    LineMark(x: .value(ChartNames.time, s.time), y: .value("°C", s.target ?? 0),
                             series: .value(ChartNames.series, "\(ChartNames.target) \(seg.id)"))
                        .foregroundStyle(style.target)
                        .lineStyle(ChartStyle.targetStroke)
                        .interpolationMethod(seg.gap ? .linear : .stepEnd)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
            ForEach(ChartSegment.split(window.indoor, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    LineMark(x: .value(ChartNames.time, s.time), y: .value("°C", s.indoor ?? 0),
                             series: .value(ChartNames.series, "\(ChartNames.room) \(seg.id)"))
                        .foregroundStyle(style.line)
                        .lineStyle(ChartStyle.solidStroke)
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
        }
        .valueAxis(axis, unit: "°C")
        .chartXScale(domain: domain)
        .timeAxis(domain: domain, range: range, plotWidth: plotWidth, labels: showsTime)
        .chartOverlay { proxy in
            HoverOverlay(proxy: proxy, points: window.indoor) { p in
                p.indoor.map { y in
                    let extra = [p.target.map { L.Charts.hoverTarget(target: Fmt.target($0)) },
                                 outdoor ? p.outdoor.map { L.Charts.hoverOutdoor(outdoor: Fmt.temp($0)) } : nil]
                    return HoverPick(y: y, color: style.line,
                                     label: HoverLabel(value: Fmt.temp(y), time: p.time, range: range,
                                                       extra: extra.compactMap { $0 }))
                }
            }
        }
    }
}

/// Außentemperatur als eigener, flacher Graph mit eigener Skala in voller Höhe. Gezeichnet wird das gleitende Mittel
/// (der Fühler springt zwischen zwei Werten); unter dem Mauszeiger steht der gemessene Wert.
private struct OutdoorMarks: View, Equatable {
    let line: [HistorySample]
    let measured: [HistorySample]
    let time: ClosedRange<Date>?
    let axis: ChartAxis
    let range: TimeInterval
    let color: Color
    let plotWidth: Double
    /// Gehört zum Vergleich: ändern sich die Formate zur Laufzeit, baut sich der Graph neu auf.
    var format = FormatProfile.current

    var body: some View {
        let domain = time ?? Date().addingTimeInterval(-range)...Date()
        Chart {
            ForEach(ChartSegment.split(line, range: range), id: \.id) { seg in
                ForEach(seg.points.indices, id: \.self) { i in
                    let s = seg.points[i]
                    LineMark(x: .value(ChartNames.time, s.time), y: .value("°C", s.outdoor ?? 0), series: .value(ChartNames.segment, seg.id))
                        .foregroundStyle(color)
                        .lineStyle(ChartStyle.outdoorStroke)
                        .interpolationMethod(seg.gap ? .linear : .monotone)
                        .opacity(seg.gap ? ChartSegment.gapOpacity : 1)
                }
            }
        }
        .valueAxis(axis, unit: "°C")
        .chartXScale(domain: domain)
        .timeAxis(domain: domain, range: range, plotWidth: plotWidth, labels: true)
        .chartOverlay { proxy in
            HoverOverlay(proxy: proxy, points: line) { p in
                p.outdoor.map { y in
                    let value = HistorySample.nearest(in: measured, to: p.time)?.outdoor ?? y
                    return HoverPick(y: y, color: color, label: HoverLabel(value: Fmt.temp(value), time: p.time, range: range))
                }
            }
        }
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
                                        labelHalfWidth: range > 86400 ? 20 : 16)
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
