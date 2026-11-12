import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Einschalt-Timer stellen (Vorschlag, nächstes Vorkommen, Zeile mit dem Tag), Tageswechsel bei Zeitumstellung und
/// die Regel, wann sich die Solltemperatur verstellen lässt. Ortszeit Europe/Berlin.
final class TimerDayTests: XCTestCase {
    var savedZone: TimeZone!

    override func setUpWithError() throws {
        savedZone = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
    }

    private func local(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testNextDayStartAcrossClockChanges() {
        // Ende der Sommerzeit (25 h) und Beginn (23 h): immer Mitternacht des Folgetags.
        XCTAssertEqual(ACController.nextDayStart(after: local(10, 25, 12)), local(10, 26))
        XCTAssertEqual(ACController.nextDayStart(after: local(3, 29, 12)), local(3, 30))
        XCTAssertEqual(ACController.nextDayStart(after: local(11, 6, 0)), local(11, 7))
    }

    func testDefaultOnTimeAndNextOccurrence() {
        let now = local(11, 6, 10)
        let seven = ACController.defaultOnTime(now: now)
        XCTAssertEqual(seven, local(11, 6, 7))
        XCTAssertEqual(ACController.nextOccurrence(of: seven, after: now), local(11, 7, 7))
        XCTAssertEqual(ACController.nextOccurrence(of: local(11, 6, 19, 5), after: now), local(11, 6, 19, 5))
        // Popover Tage lang offen: nur die Uhrzeit zählt.
        XCTAssertEqual(ACController.nextOccurrence(of: local(11, 1, 7), after: now), local(11, 7, 7))
    }

    func testOnTimerPreviewMatchesQuitPromptDay() {
        FormatProfile.withProfile(.germany) {
            let now = local(11, 6, 10)
            XCTAssertEqual(UIText.onTimerPreview(local(11, 7, 7), now: now), "Schaltet morgen um 07:00 ein")
            XCTAssertEqual(UIText.onTimerPreview(local(11, 6, 19, 5), now: now), "Schaltet heute um 19:05 ein")
            let later = local(11, 9, 7)
            XCTAssertEqual(UIText.onTimerPreview(later, now: now),
                           "Schaltet \(UIText.dayLabel(later, now: now)) um 07:00 ein")
        }
    }

    func testTargetAdjustable() {
        var s = ACState()
        s.power = true
        s.mode = .cool
        XCTAssertTrue(UIText.targetAdjustable(s))
        s.mode = .fan
        XCTAssertFalse(UIText.targetAdjustable(s))
        s.mode = .heat
        s.power = false
        XCTAssertFalse(UIText.targetAdjustable(s))
        XCTAssertFalse(UIText.targetAdjustable(nil))
    }
}
