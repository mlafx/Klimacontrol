import XCTest
@testable import KlimacontrolCore

final class FormatProfileTests: XCTestCase {
    override func tearDown() {
        FormatProfile.setCurrent(.germany)
        super.tearDown()
    }

    private var berlin: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        berlin.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testGermanNumbersUnchanged() {
        let values: [Double] = [0, 0.3, -0.25, 1.005, 21.25, 21.35, 999.995, 1234.5, -1234.567, 1_000_000, 12.5]
        let de = Locale(identifier: "de_DE")
        for v in values {
            for d in 0...4 {
                XCTAssertEqual(Fmt.num(v, d, profile: .germany),
                               v.formatted(.number.rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(d)).locale(de)),
                               "\(v) / \(d)")
            }
        }
    }

    /// Halbwerte runden weg von null (wie .NET); dieselbe Tabelle prüft die Windows-Oberfläche.
    func testRoundingTable() throws {
        struct Row: Decodable { let value: Double; let digits: Int; let de: String; let en: String }
        struct Table: Decodable { let rows: [Row] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/rounding-table.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        XCTAssertFalse(table.rows.isEmpty)
        for r in table.rows {
            XCTAssertEqual(Fmt.num(r.value, r.digits, profile: .germany), r.de, "\(r.value) / \(r.digits)")
            XCTAssertEqual(Fmt.num(r.value, r.digits, profile: .unitedStates), r.en, "\(r.value) / \(r.digits)")
        }
    }

    func testOtherSeparators() {
        XCTAssertEqual(Fmt.num(1234.5, 1, profile: .unitedStates), "1,234.5")
        var p = FormatProfile.germany
        p.groupingSeparator = "\u{202F}"
        XCTAssertEqual(Fmt.num(1234.5, 1, profile: p), "1\u{202F}234,5")
        p.groupingSeparator = ""
        XCTAssertEqual(Fmt.num(1234.5, 1, profile: p), "1234,5")
    }

    func testUnitsAndMoney() {
        let de = FormatProfile.germany
        XCTAssertEqual(Fmt.temp(21.5, profile: de), "21,5°")
        XCTAssertEqual(Fmt.target(21.6, profile: de), "22°")
        XCTAssertEqual(Fmt.watts(410, profile: de), "410 W")
        XCTAssertEqual(Fmt.kwh(1.234, profile: de), "1,23 kWh")
        XCTAssertEqual(Fmt.money(0.3, currency: "€", profile: de), "0,30 €")
        XCTAssertEqual(Fmt.money(0.3, currency: "CHF", profile: de), "0,30 CHF")
        XCTAssertEqual(Fmt.money(nil, currency: "€", profile: de), "–")
        XCTAssertEqual(Fmt.money(12.5, currency: "$", profile: .unitedStates), "12.50 $")
    }

    func testClock() {
        let cases: [(Date, String, String)] = [
            (date(2026, 11, 3, 14, 32), "14:32", "2:32 PM"),
            (date(2026, 11, 3, 0, 5), "00:05", "12:05 AM"),
            (date(2026, 11, 3, 12, 0), "12:00", "12:00 PM"),
        ]
        for (d, de, us) in cases {
            XCTAssertEqual(Fmt.clock(d, calendar: berlin, profile: .germany), de)
            XCTAssertEqual(Fmt.clock(d, calendar: berlin, profile: .unitedStates), us)
        }
    }

    func testDayMonthPatterns() {
        let d = date(2026, 11, 3, 10, 0)
        let cases = [("dd.MM.", "03.11."), ("MM/dd", "11/03"), ("M/d", "11/3"), ("d. MMM", "3. 11"), ("'Tag' d", "Tag 3")]
        for (pattern, expected) in cases {
            var p = FormatProfile.germany
            p.dayMonthPattern = pattern
            XCTAssertEqual(Fmt.dayMonth(d, calendar: berlin, profile: p), expected, pattern)
        }
    }

    func testStandUnchangedForGermany() {
        let now = date(2026, 11, 6, 18, 0)
        XCTAssertEqual(Fmt.stand(date(2026, 11, 6, 14, 32), now: now, calendar: berlin, profile: .germany), "Stand 14:32")
        let earlier = date(2026, 11, 5, 14, 32)
        XCTAssertEqual(Fmt.stand(earlier, now: now, calendar: berlin, profile: .germany), "Stand 05.11., 14:32")
        XCTAssertEqual(Fmt.stand(earlier, now: now, calendar: berlin, profile: .unitedStates), "Stand 11/05, 2:32 PM")
    }

    func testCurrentDefaultsToGermanyAndSwitches() {
        XCTAssertEqual(FormatProfile.current, .germany)
        FormatProfile.withProfile(.unitedStates) {
            XCTAssertEqual(Fmt.num(1.5, 1), "1.5")
        }
        XCTAssertEqual(Fmt.num(1.5, 1), "1,5")
        XCTAssertEqual(Fmt.locale.identifier, "de_DE")
    }

    func testDecode() throws {
        func json(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var o: [String: Any] = [
                "localeIdentifier": "en_US", "decimalSeparator": ".", "groupingSeparator": ",",
                "uses24HourClock": false, "amSymbol": "AM", "pmSymbol": "PM", "dayMonthPattern": "MM/dd",
            ]
            edit(&o)
            return try JSONSerialization.data(withJSONObject: o)
        }
        XCTAssertEqual(FormatProfile.decode(try json { _ in }), .unitedStates)
        XCTAssertNil(FormatProfile.decode(try json { $0.removeValue(forKey: "uses24HourClock") }))
        XCTAssertNil(FormatProfile.decode(try json { $0["decimalSeparator"] = "" }))
        XCTAssertNil(FormatProfile.decode(try json { $0["uses24HourClock"] = 1 }))
        XCTAssertNil(FormatProfile.decode(try json { $0["dayMonthPattern"] = "yyyy" }))
        XCTAssertNotNil(FormatProfile.decode(try json { $0["amSymbol"] = "" }))
    }

    #if os(macOS)
    func testTwelveHourDetection() {
        XCTAssertFalse(FormatProfile.uses24Hour(template: "h a"))
        XCTAssertFalse(FormatProfile.uses24Hour(template: "Bh:mm"))
        XCTAssertFalse(FormatProfile.uses24Hour(template: "K a"))
        XCTAssertTrue(FormatProfile.uses24Hour(template: "HH"))
        XCTAssertTrue(FormatProfile.uses24Hour(template: "H 'h'"))
        XCTAssertTrue(FormatProfile.uses24Hour(template: "HH 'Uhr'"))
    }

    func testFromLocale() {
        let d = date(2026, 11, 3, 10, 0)
        let de = FormatProfile.from(locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(de.decimalSeparator, ",")
        XCTAssertEqual(de.groupingSeparator, ".")
        XCTAssertTrue(de.uses24HourClock)
        XCTAssertEqual(Fmt.dayMonth(d, calendar: berlin, profile: de), "03.11.")
        let us = FormatProfile.from(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(us.decimalSeparator, ".")
        XCTAssertEqual(us.groupingSeparator, ",")
        XCTAssertFalse(us.uses24HourClock)
        XCTAssertEqual(Fmt.dayMonth(d, calendar: berlin, profile: us), "11/03")
        let gb = FormatProfile.from(locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(gb.uses24HourClock)
        XCTAssertEqual(Fmt.dayMonth(d, calendar: berlin, profile: gb), "03/11")
    }
    #endif
}
