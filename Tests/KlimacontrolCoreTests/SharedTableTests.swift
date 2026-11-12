import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import MideaKit
import XCTest
@testable import KlimacontrolCore

// Gemeinsame Tabellen unter Tests/Shared, gegen die auch die Windows-Oberfläche (C#) ihre Nachbauten prüft.

private func sharedTable<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Shared/\(name)")
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

private struct Rect: Decodable, Equatable {
    let x, y, width, height: Double
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ r: CGRect) {
        x = Double(r.origin.x)
        y = Double(r.origin.y)
        width = Double(r.width)
        height = Double(r.height)
    }
}

private struct UnknownSide: Error { let name: String }

final class TimeTicksTableTests: XCTestCase {
    private struct Step: Decodable { let range: Double; let stepMinutes: Int; let labelHalfWidth: Double }
    private struct Case: Decodable {
        let note: String
        let start, end, range, plotWidth, labelHalfWidth: Double
        let stepMinutes: Int
        let ticks: [Double]
    }
    private struct Table: Decodable {
        let timeZone: String
        let steps: [Step]
        let cases: [Case]
    }

    func testStepsPerRange() throws {
        let t = try sharedTable("time-ticks-table.json", as: Table.self)
        XCTAssertGreaterThanOrEqual(t.steps.count, 6)
        for s in t.steps {
            XCTAssertEqual(ChartAxis.timeStepMinutes(range: s.range), s.stepMinutes, "Zeitraum \(s.range)")
            XCTAssertEqual(ChartAxis.timeLabelHalfWidth(range: s.range), s.labelHalfWidth, "Zeitraum \(s.range)")
        }
    }

    func testTicksInFixedZone() throws {
        let t = try sharedTable("time-ticks-table.json", as: Table.self)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: t.timeZone))
        XCTAssertGreaterThanOrEqual(t.cases.count, 10)
        XCTAssertTrue(t.cases.contains { $0.note.contains("Ende der Sommerzeit") })
        for c in t.cases {
            XCTAssertEqual(ChartAxis.timeStepMinutes(range: c.range), c.stepMinutes, c.note)
            let domain = Date(timeIntervalSince1970: c.start)...Date(timeIntervalSince1970: c.end)
            let ticks = ChartAxis.timeTicks(domain: domain, range: c.range, plotWidth: c.plotWidth,
                                            labelHalfWidth: c.labelHalfWidth, calendar: cal)
            XCTAssertEqual(ticks.map(\.timeIntervalSince1970), c.ticks, c.note)
        }
    }
}

final class ChartHeightsTableTests: XCTestCase {
    private struct Heights: Decodable { let power, temperature, outdoor, energy: Double }
    private struct Case: Decodable {
        let note: String
        let columnHeight: Double
        let grid: Bool
        let overhead: Double?
        let separateOutdoor: Bool
        let heights: Heights
    }
    private struct Table: Decodable { let cases: [Case] }

    func testHeights() throws {
        let t = try sharedTable("chart-heights-table.json", as: Table.self)
        XCTAssertGreaterThanOrEqual(t.cases.count, 15)
        for c in t.cases {
            let h = MainWindowLayout.chartHeights(columnHeight: c.columnHeight, grid: c.grid, overhead: c.overhead,
                                                  separateOutdoor: c.separateOutdoor)
            XCTAssertEqual([h.power, h.temperature, h.outdoor, h.energy],
                           [c.heights.power, c.heights.temperature, c.heights.outdoor, c.heights.energy], c.note)
        }
    }

    /// Die Bridge gibt die Gewichte als Leistung/Temperatur/Außen weiter; die Tabelle setzt 3 : 3 : 2 voraus.
    func testWeights() {
        XCTAssertEqual(MainWindowLayout.chartWeights, [3, 3, 2])
    }
}

final class ModeRunsTableTests: XCTestCase {
    private struct Point: Decodable { let t: Double; let mode: Int? }
    private struct Run: Decodable { let mode: Int; let start, end: Double }
    private struct Case: Decodable {
        let note: String
        let gapLimit: Double
        let samples: [Point]
        let runs: [Run]
    }
    private struct Table: Decodable { let cases: [Case] }

    func testRuns() throws {
        let t = try sharedTable("mode-runs-table.json", as: Table.self)
        XCTAssertGreaterThanOrEqual(t.cases.count, 10)
        for c in t.cases {
            let data = try c.samples.map { p in
                let mode = try p.mode.map { try XCTUnwrap(OperationalMode(rawValue: $0), c.note) }
                return HistorySample(time: Date(timeIntervalSince1970: p.t), power: nil, indoor: nil, outdoor: nil,
                                     target: nil, on: mode != nil, mode: mode)
            }
            let runs = HistorySample.modeRuns(data, gapLimit: c.gapLimit)
            XCTAssertEqual(runs.map { [Double($0.mode.rawValue), $0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970] },
                           c.runs.map { [Double($0.mode), $0.start, $0.end] }, c.note)
        }
    }
}

final class MainWindowLayoutTableTests: XCTestCase {
    private struct Widths: Decodable { let history, control, diagnostics, margin: Double }
    private struct WidthCase: Decodable {
        let note: String
        let total: Double
        let history, diagnostics: Bool
        let minimum: Double
        let expected: Widths
        let historyGrid: Bool
    }
    private struct Shown: Decodable { let history, diagnostics: Bool }
    private struct ResolveCase: Decodable {
        let note: String
        let history, diagnostics: Bool
        let available: Double
        let lastOpened: String?
        let shown: Shown
        let hidden: [String]
    }
    private struct Growth: Decodable { let frame: Rect; let added: Double }
    private struct GrowCase: Decodable {
        let note: String
        let frame: Rect
        let minimum: Double
        let side: String
        let screen: Rect
        let expected: Growth?
    }
    private struct ShrinkCase: Decodable {
        let note: String
        let frame: Rect
        let amount: Double
        let side: String
        let minimumWidth: Double
        let expected: Rect
    }
    private struct LimitCase: Decodable {
        let note: String
        let frame: Rect
        let maximum: Double
        let keeping: String
        let expected: Rect
    }
    private struct HeightCase: Decodable {
        let note: String
        let frame, screen: Rect
        let minimum: Double
        let expected: Rect
    }
    private struct ConstrainedCase: Decodable {
        let note: String
        let frame, screen: Rect
        let expected: Bool
    }
    private struct Table: Decodable {
        let widths: [WidthCase]
        let resolve: [ResolveCase]
        let grow: [GrowCase]
        let shrink: [ShrinkCase]
        let limitWidth: [LimitCase]
        let growHeight: [HeightCase]
        let isConstrained: [ConstrainedCase]
    }

    private func table() throws -> Table { try sharedTable("main-window-layout-table.json", as: Table.self) }

    private func side(_ s: String) throws -> MainWindowFrame.Side {
        switch s {
        case "left": return .left
        case "right": return .right
        default: throw UnknownSide(name: s)
        }
    }

    func testWidths() throws {
        let t = try table()
        XCTAssertGreaterThanOrEqual(t.widths.count, 12)
        for c in t.widths {
            let v = MainWindowLayout.Visible(history: c.history, diagnostics: c.diagnostics)
            XCTAssertEqual(MainWindowLayout.minimumWidth(v), c.minimum, c.note)
            let w = MainWindowLayout.widths(total: c.total, visible: v)
            XCTAssertEqual([w.history, w.control, w.diagnostics, w.margin],
                           [c.expected.history, c.expected.control, c.expected.diagnostics, c.expected.margin], c.note)
            XCTAssertEqual(MainWindowLayout.historyUsesGrid(width: w.history), c.historyGrid, c.note)
        }
    }

    func testResolve() throws {
        let t = try table()
        XCTAssertGreaterThanOrEqual(t.resolve.count, 10)
        for c in t.resolve {
            let last = try c.lastOpened.map { try XCTUnwrap(MainWindowLayout.Column(rawValue: $0), c.note) }
            let r = MainWindowLayout.resolve(wanted: .init(history: c.history, diagnostics: c.diagnostics),
                                             available: c.available, lastOpened: last)
            XCTAssertEqual(r.shown, .init(history: c.shown.history, diagnostics: c.shown.diagnostics), c.note)
            XCTAssertEqual(r.hidden.map(\.rawValue), c.hidden, c.note)
        }
    }

    func testGrow() throws {
        let t = try table()
        XCTAssertGreaterThanOrEqual(t.grow.count, 6)
        for c in t.grow {
            let g = MainWindowFrame.grow(c.frame.cg, toMinimumWidth: c.minimum, side: try side(c.side), screen: c.screen.cg)
            XCTAssertEqual(g.map { Rect($0.frame) }, c.expected?.frame, c.note)
            XCTAssertEqual(g?.added, c.expected?.added, c.note)
        }
    }

    func testShrink() throws {
        let t = try table()
        XCTAssertGreaterThanOrEqual(t.shrink.count, 5)
        for c in t.shrink {
            let f = MainWindowFrame.shrink(c.frame.cg, by: c.amount, side: try side(c.side), minimumWidth: c.minimumWidth)
            XCTAssertEqual(Rect(f), c.expected, c.note)
        }
    }

    func testLimitWidthGrowHeightAndConstrained() throws {
        let t = try table()
        for c in t.limitWidth {
            XCTAssertEqual(Rect(MainWindowFrame.limitWidth(c.frame.cg, to: c.maximum, keeping: try side(c.keeping))),
                           c.expected, c.note)
        }
        for c in t.growHeight {
            XCTAssertEqual(Rect(MainWindowFrame.growHeight(c.frame.cg, toMinimum: c.minimum, screen: c.screen.cg)),
                           c.expected, c.note)
        }
        for c in t.isConstrained {
            XCTAssertEqual(MainWindowFrame.isConstrained(c.frame.cg, screen: c.screen.cg), c.expected, c.note)
        }
        XCTAssertFalse(t.limitWidth.isEmpty)
        XCTAssertFalse(t.growHeight.isEmpty)
        XCTAssertFalse(t.isConstrained.isEmpty)
    }
}
