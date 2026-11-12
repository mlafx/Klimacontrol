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
        outdoorLine = HistorySample.smoothedOutdoor(outdoor, range: range)
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

/// Feine Trennlinie zwischen den Graphen einer Karte.
private struct ChartDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
            .padding(.vertical, 10)
            .accessibilityHidden(true)
    }
}
