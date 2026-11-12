import Charts
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Abschnitte (Überschrift, Graph, Zeile darunter)

private struct ChartSectionTitle: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.medium))
            .accessibilityAddTraits(.isHeader)
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
