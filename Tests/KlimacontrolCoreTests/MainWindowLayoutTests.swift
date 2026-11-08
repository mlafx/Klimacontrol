import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import KlimacontrolCore

final class MainWindowLayoutTests: XCTestCase {
    private typealias M = MainWindowLayout
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testMinimumWidths() {
        XCTAssertEqual(M.minimumWidth(.init()), 480)
        XCTAssertEqual(M.minimumWidth(.init(history: true)), 940)
        XCTAssertEqual(M.minimumWidth(.init(diagnostics: true)), 820)
        XCTAssertEqual(M.minimumWidth(.init(history: true, diagnostics: true)), 1280)
    }

    func testWidthsAtMinimumGiveEachColumnItsMinimum() {
        let w = M.widths(total: 1280, visible: .init(history: true, diagnostics: true))
        XCTAssertEqual([w.history, w.control, w.diagnostics, w.margin], [460, 480, 340, 0])
    }

    func testSurplusGoesToHistoryThenDiagnosticsThenHistory() {
        let both = Visible(history: true, diagnostics: true)
        var w = M.widths(total: 1280 + 100, visible: both)
        XCTAssertEqual([w.history, w.diagnostics], [560, 340])
        w = M.widths(total: 1280 + 240 + 30, visible: both)
        XCTAssertEqual([w.history, w.diagnostics], [700, 370])
        w = M.widths(total: 1280 + 240 + 60 + 500, visible: both)
        XCTAssertEqual([w.history, w.diagnostics], [1200, 400])
        XCTAssertEqual(w.total, 1280 + 240 + 60 + 500)
    }

    func testWithoutHistoryTheRestIsMargin() {
        var w = M.widths(total: 1600, visible: .init(diagnostics: true))
        XCTAssertEqual([w.history, w.control, w.diagnostics, w.margin], [0, 480, 400, 720])
        w = M.widths(total: 1000, visible: .init())
        XCTAssertEqual([w.control, w.margin], [480, 520])
    }

    func testNeverSqueezedBelowMinimum() {
        let w = M.widths(total: 600, visible: .init(history: true, diagnostics: true))
        XCTAssertEqual([w.history, w.diagnostics], [460, 340])
    }

    func testGridFrom880() {
        XCTAssertFalse(M.historyUsesGrid(width: 879))
        XCTAssertTrue(M.historyUsesGrid(width: 880))
    }

    func testResolveKeepsWhatFits() {
        let r = M.resolve(wanted: .init(history: true, diagnostics: true), available: 1440, lastOpened: .diagnostics)
        XCTAssertEqual(r.shown, .init(history: true, diagnostics: true))
        XCTAssertTrue(r.hidden.isEmpty)
    }

    func testResolveHidesTheOtherColumnWhenNotFitting() {
        let both = Visible(history: true, diagnostics: true)
        var r = M.resolve(wanted: both, available: 1024, lastOpened: .diagnostics)
        XCTAssertEqual(r.shown, .init(diagnostics: true))
        XCTAssertEqual(r.hidden, [.history])
        r = M.resolve(wanted: both, available: 1024, lastOpened: .history)
        XCTAssertEqual(r.shown, .init(history: true))
        XCTAssertEqual(r.hidden, [.diagnostics])
        r = M.resolve(wanted: both, available: 1024, lastOpened: nil)
        XCTAssertEqual(r.shown, .init(history: true))
    }

    func testResolveHidesEverythingOnVeryNarrowScreens() {
        let r = M.resolve(wanted: .init(history: true, diagnostics: true), available: 700, lastOpened: .history)
        XCTAssertEqual(r.shown, .init())
        XCTAssertEqual(Set(r.hidden.map { "\($0)" }), ["history", "diagnostics"])
        XCTAssertEqual(M.resolve(wanted: .init(history: true), available: 900, lastOpened: nil).shown, .init())
    }

    func testMinimumHeightsFitA1024By640Screen() {
        let menuBarAndDock = 24.0 + 70.0
        XCTAssertEqual(M.minimumHeight(.compact), 470)
        XCTAssertEqual(M.minimumHeight(.normal), 520)
        XCTAssertEqual(M.minimumHeight(.large), 600)
        XCTAssertLessThanOrEqual(M.minimumHeight(.normal) + menuBarAndDock, 640)
        XCTAssertLessThanOrEqual(M.minimumHeight(.compact), M.minimumHeight(.normal))
    }

    func testChartHeights() {
        XCTAssertEqual(M.chartHeights(columnHeight: 0), .init())
        XCTAssertEqual(M.chartHeights(columnHeight: M.historyBaseHeight), .init())
        let mid = M.chartHeights(columnHeight: M.historyBaseHeight + 160)
        XCTAssertEqual(mid.power, 150 + 60)
        XCTAssertEqual(mid.temperature, 180 + 60)
        XCTAssertEqual(mid.outdoor, 120 + 40)
        XCTAssertEqual(mid.energy, 150)
        let tall = M.chartHeights(columnHeight: 5000)
        XCTAssertEqual([tall.power, tall.temperature, tall.outdoor, tall.energy], [300, 360, 240, 240])
        for h in stride(from: 900.0, to: 2600.0, by: 37) {
            let c = M.chartHeights(columnHeight: h)
            for (v, room) in [(c.power - 150, 150.0), (c.temperature - 180, 180), (c.outdoor - 120, 120), (c.energy - 150, 90)]
            where v != room {
                XCTAssertEqual(v.truncatingRemainder(dividingBy: 20), 0)
            }
        }
    }

    // MARK: Rahmen

    func testGrowLeftOnlyByTheDeficit() throws {
        let f = CGRect(x: 600, y: 100, width: 480, height: 700)
        let g = try XCTUnwrap(MainWindowFrame.grow(f, toMinimumWidth: 940, side: .left, screen: screen))
        XCTAssertEqual(g.added, 460)
        XCTAssertEqual(g.frame, CGRect(x: 140, y: 100, width: 940, height: 700))
    }

    func testGrowRightAndAlreadyWideEnough() throws {
        let f = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let same = try XCTUnwrap(MainWindowFrame.grow(f, toMinimumWidth: 940, side: .right, screen: screen))
        XCTAssertEqual(same.added, 0)
        XCTAssertEqual(same.frame, f)
        let g = try XCTUnwrap(MainWindowFrame.grow(CGRect(x: 100, y: 100, width: 480, height: 700),
                                                   toMinimumWidth: 820, side: .right, screen: screen))
        XCTAssertEqual(g.frame.minX, 100)
        XCTAssertEqual(g.frame.width, 820)
    }

    func testGrowIsPulledOntoTheScreen() throws {
        let f = CGRect(x: 100, y: 100, width: 480, height: 700)
        let left = try XCTUnwrap(MainWindowFrame.grow(f, toMinimumWidth: 940, side: .left, screen: screen))
        XCTAssertEqual(left.frame.minX, 0)
        XCTAssertEqual(left.frame.width, 940)
        let right = try XCTUnwrap(MainWindowFrame.grow(CGRect(x: 1100, y: 100, width: 340, height: 700),
                                                       toMinimumWidth: 820, side: .right, screen: screen))
        XCTAssertEqual(right.frame.maxX, 1440)
    }

    func testGrowFailsWhenMinimumIsWiderThanTheScreen() {
        let small = CGRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertNil(MainWindowFrame.grow(CGRect(x: 0, y: 0, width: 480, height: 500), toMinimumWidth: 940, side: .left, screen: small))
    }

    func testShrinkTakesBackOnlyWhatWasAdded() {
        let f = CGRect(x: 140, y: 100, width: 940, height: 700)
        XCTAssertEqual(MainWindowFrame.shrink(f, by: 460, side: .left, minimumWidth: 480),
                       CGRect(x: 600, y: 100, width: 480, height: 700))
        XCTAssertEqual(MainWindowFrame.shrink(f, by: 0, side: .left, minimumWidth: 480), f)
        XCTAssertEqual(MainWindowFrame.shrink(f, by: 460, side: .right, minimumWidth: 480).minX, 140)
        XCTAssertEqual(MainWindowFrame.shrink(f, by: 900, side: .right, minimumWidth: 700).width, 700)
    }

    func testLimitWidthKeepsTheChosenSide() {
        let f = CGRect(x: 100, y: 0, width: 700, height: 600)
        XCTAssertEqual(MainWindowFrame.limitWidth(f, to: 520, keeping: .left), CGRect(x: 100, y: 0, width: 520, height: 600))
        XCTAssertEqual(MainWindowFrame.limitWidth(f, to: 520, keeping: .right), CGRect(x: 280, y: 0, width: 520, height: 600))
        XCTAssertEqual(MainWindowFrame.limitWidth(f, to: 900, keeping: .left), f)
    }

    func testGrowHeightKeepsTheTopEdge() {
        let f = CGRect(x: 0, y: 300, width: 480, height: 500)
        let g = MainWindowFrame.growHeight(f, toMinimum: 600, screen: screen)
        XCTAssertEqual(g.maxY, f.maxY)
        XCTAssertEqual(g.height, 600)
        XCTAssertEqual(MainWindowFrame.growHeight(f, toMinimum: 400, screen: screen), f)
        XCTAssertEqual(MainWindowFrame.growHeight(f, toMinimum: 5000, screen: screen).height, 900)
    }

    func testConstrainedWindows() {
        XCTAssertTrue(MainWindowFrame.isConstrained(CGRect(x: 0, y: 0, width: 720, height: 900), screen: screen))
        XCTAssertTrue(MainWindowFrame.isConstrained(CGRect(x: 0, y: 0, width: 1440, height: 900), screen: screen))
        XCTAssertFalse(MainWindowFrame.isConstrained(CGRect(x: 300, y: 0, width: 480, height: 900), screen: screen))
        XCTAssertFalse(MainWindowFrame.isConstrained(CGRect(x: 0, y: 100, width: 480, height: 600), screen: screen))
    }
}

private typealias Visible = MainWindowLayout.Visible
