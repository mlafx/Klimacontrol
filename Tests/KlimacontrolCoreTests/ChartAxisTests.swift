import XCTest
@testable import KlimacontrolCore

/// Y-Achsen der Verlaufsgraphen und Beschriftungen unter den Verbrauchsbalken. Dieselbe Tabelle prüft die
/// Windows-Oberfläche, damit beide Plattformen dieselben Gitterlinien zeigen.
final class ChartAxisTests: XCTestCase {
    private struct Expected: Decodable { let min, max, first, step: Double }
    private struct AxisCase: Decodable { let values: [Double]; let axis: Expected? }
    private struct LabelCase: Decodable {
        let count: Int
        let plotWidth: Double
        let labelLength: Int
        let note: String
        let step: Int
        let shown: [Int]
    }
    private struct Table: Decodable {
        let power: [AxisCase]
        let temperature: [AxisCase]
        let labels: [LabelCase]
    }

    private func table() throws -> Table {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/chart-axis-table.json")
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
    }

    private func check(_ axis: ChartAxis?, _ expected: Expected?, _ name: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard let expected else { return XCTAssertNil(axis, name, file: file, line: line) }
        guard let axis else { return XCTFail("\(name): keine Achse", file: file, line: line) }
        XCTAssertEqual(axis.min, expected.min, accuracy: 1e-9, "\(name) min", file: file, line: line)
        XCTAssertEqual(axis.max, expected.max, accuracy: 1e-9, "\(name) max", file: file, line: line)
        XCTAssertEqual(axis.first, expected.first, accuracy: 1e-9, "\(name) first", file: file, line: line)
        XCTAssertEqual(axis.step, expected.step, accuracy: 1e-9, "\(name) step", file: file, line: line)
    }

    func testPowerTable() throws {
        let t = try table()
        XCTAssertGreaterThanOrEqual(t.power.count, 8)
        for c in t.power { check(ChartAxis.power(c.values), c.axis, "Leistung \(c.values)") }
    }

    func testTemperatureTable() throws {
        let t = try table()
        XCTAssertGreaterThanOrEqual(t.temperature.count, 8)
        for c in t.temperature { check(ChartAxis.temperature(c.values), c.axis, "Temperatur \(c.values)") }
    }

    func testLabelTableKeepsLastLabel() throws {
        let t = try table()
        XCTAssertFalse(t.labels.isEmpty)
        for c in t.labels {
            let step = ChartAxis.labelStep(count: c.count, plotWidth: c.plotWidth, labelLength: c.labelLength)
            XCTAssertEqual(step, c.step, c.note)
            let shown = (0..<c.count).filter { ChartAxis.showsLabel(index: $0, count: c.count, step: step) }
            XCTAssertEqual(shown, c.shown, c.note)
            if c.count > 0 { XCTAssertEqual(shown.last, c.count - 1, "\(c.note): letzte Beschriftung fehlt") }
        }
    }

    /// Beschriftungen dürfen sich nicht berühren: Platz je gezeigter Beschriftung reicht für die längste.
    func testLabelsFitTheirSpace() {
        for count in [8, 12, 14] {
            for width in stride(from: 300.0, through: 1200, by: 10) {
                for length in 5...10 {
                    let step = ChartAxis.labelStep(count: count, plotWidth: width, labelLength: length)
                    let space = width / Double(count) * Double(step)
                    XCTAssertGreaterThanOrEqual(space, Double(length) * ChartAxis.labelCharWidth + ChartAxis.labelGap,
                                                "\(count) Balken, \(width) pt, \(length) Zeichen")
                    if step > 1 {
                        let tighter = width / Double(count) * Double(step - 1)
                        XCTAssertLessThan(tighter, Double(length) * ChartAxis.labelCharWidth + ChartAxis.labelGap,
                                          "unnötig wenige Beschriftungen")
                    }
                }
            }
        }
    }

    func testTicksLieOnTheGridInsideTheRange() {
        XCTAssertEqual(ChartAxis.power([450])?.ticks, [0, 200, 400, 600])
        XCTAssertEqual(ChartAxis.temperature([20.4, 23.7])?.ticks, [20, 22, 24])
        XCTAssertEqual(ChartAxis.temperature([-12.3, -8.1])?.ticks, [-12, -10, -8])
        XCTAssertEqual(ChartAxis.temperature([21])?.ticks, [19, 20, 21, 22, 23])
        for values in [[0.4], [99], [3000], [1234, 800, 50], [25000]] {
            guard let a = ChartAxis.power(values) else { return XCTFail("\(values)") }
            XCTAssertEqual(a.ticks.first, 0)
            XCTAssertEqual(a.ticks.last ?? .nan, a.max, accuracy: 1e-9, "oberste Linie am Rand: \(values)")
            XCTAssertLessThanOrEqual(a.ticks.count, 5, "\(values)")
        }
        for values in [[21], [0], [-40, 45], [16, 30], [10, 10.5, 11.2], [-3, 2]] {
            guard let a = ChartAxis.temperature(values) else { return XCTFail("\(values)") }
            XCTAssertFalse(a.ticks.isEmpty)
            XCTAssertTrue(a.ticks.allSatisfy { $0 >= a.min - 1e-9 && $0 <= a.max + 1e-9 }, "\(values)")
            XCTAssertLessThanOrEqual(a.ticks.count, 6, "höchstens fünf Abschnitte: \(values)")
            XCTAssertGreaterThanOrEqual(a.max - a.min, 4 - 1e-9)
        }
    }

    func testTicksToleranceAndEmptyGrid() {
        // Rechenungenauigkeit an der Obergrenze: die oberste Linie bleibt (wie in C# mit einem Tausendstel Schritt).
        XCTAssertEqual(ChartAxis(min: 0, max: 2.9999999, first: 0, step: 1).ticks, [0, 1, 2, 3])
        XCTAssertEqual(ChartAxis(min: 0, max: 2.99, first: 0, step: 1).ticks, [0, 1, 2])
        XCTAssertEqual(ChartAxis(min: 0, max: 1, first: 2, step: 1).ticks, [])
        XCTAssertEqual(ChartAxis(min: 0, max: 1, first: 0, step: 0).ticks, [])
    }

    func testFixedKeepsTheRange() {
        XCTAssertEqual(ChartAxis.fixed(0...3), ChartAxis(min: 0, max: 3, first: 0, step: 1))
        XCTAssertEqual(ChartAxis.fixed(UIOptions.chartTemperatureAxis), ChartAxis(min: 16, max: 30, first: 20, step: 5))
        XCTAssertEqual(ChartAxis.fixed(UIOptions.chartTemperatureAxis).ticks, [20, 25, 30])
        XCTAssertEqual(ChartAxis.fixed(UIOptions.chartOutdoorAxis), ChartAxis(min: 0, max: 10, first: 0, step: 2))
        XCTAssertEqual(ChartAxis.fixed(-5...5).ticks, [-4, -2, 0, 2, 4])
        XCTAssertEqual(ChartAxis.fixed(0...3).domain, 0...3)
    }

    func testNiceStep() {
        XCTAssertEqual(ChartAxis.niceStep(0), 1)
        XCTAssertEqual(ChartAxis.niceStep(-3), 1)
        XCTAssertEqual(ChartAxis.niceStep(1), 1)
        XCTAssertEqual(ChartAxis.niceStep(1.01), 2)
        XCTAssertEqual(ChartAxis.niceStep(150), 200)
        XCTAssertEqual(ChartAxis.niceStep(411), 500)
        XCTAssertEqual(ChartAxis.niceStep(501), 1000)
        XCTAssertEqual(ChartAxis.niceStep(1000), 1000)
        XCTAssertEqual(ChartAxis.niceStep(0.3333), 0.5, accuracy: 1e-12)
    }

    func testNonFiniteValuesDoNotHang() {
        XCTAssertNil(ChartAxis.temperature([.infinity]))
        XCTAssertNil(ChartAxis.power([.nan]))
        XCTAssertEqual(ChartAxis.temperature([.nan, 21, -.infinity]), ChartAxis.temperature([21]))
        XCTAssertEqual(ChartAxis.fixed(0...0).ticks, [0])
    }
}
