import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

final class OptionsEnglishTests: XCTestCase {
    override func tearDown() {
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        super.tearDown()
    }

    private func local(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func english<T>(_ body: () -> T) -> T {
        Localizer.withLanguage(.en) { FormatProfile.withProfile(.unitedStates, body) }
    }

    func testChoicesEnglish() {
        english {
            XCTAssertEqual(UIOptions.refreshChoices.map(\.label), ["5 seconds", "10 seconds", "30 seconds", "1 minute", "5 minutes"])
            XCTAssertEqual(UIOptions.offTimerChoices.map(\.label),
                           ["30 minutes", "1 hour", "2 hours", "3 hours", "4 hours", "6 hours", "8 hours"])
            XCTAssertEqual(UIOptions.chartRanges.map(\.label), ["1 h", "6 h", "24 h", "7 days"])
            XCTAssertEqual(UIOptions.fanMarks.map(\.label), ["1 %", "Quiet", "Low", "Medium", "High", "Max"])
            XCTAssertEqual(UIOptions.refreshCustomLabel, "Custom value…")
            XCTAssertEqual(UIOptions.energyKinds.map(\.label), ["Days", "Weeks", "Months"])
        }
    }

    func testTemperatureScaleEnglish() {
        english {
            XCTAssertEqual(UIText.temperatureScaleRoom(19), "Room 19.0°")
            XCTAssertEqual(L.Main.Power.stateOn, "On")
            XCTAssertEqual(L.Main.Power.stateOff, "Off")
        }
    }

    func testFanCaptionEnglish() {
        english {
            var s = ACState()
            s.mode = .cool
            s.fanSpeed = FanSpeed.auto.rawValue
            XCTAssertEqual(UIOptions.fanCaption(s), "automatic")
            s.fanSpeed = 100
            s.turbo = true
            XCTAssertEqual(UIOptions.fanCaption(s), "Turbo · 100 %")
            s.turbo = false
            s.fanSpeed = 1
            s.outSilent = true
            XCTAssertEqual(UIOptions.fanCaption(s), "Quiet outdoor · 1 %")
            s.outSilent = false
            s.fanSpeed = 60
            XCTAssertEqual(UIOptions.fanCaption(s), "Medium · 60 %")
            s.mode = .dry
            XCTAssertEqual(UIOptions.fanCaption(s), "the air conditioner controls it while drying")
        }
    }

    func testAvailabilityAndAppearanceEnglish() {
        english {
            XCTAssertEqual(UIOptions.availability(.eco, mode: .heat).why, "Eco is only available when cooling")
            XCTAssertFalse(UIOptions.availability(.eco, mode: .heat).enabled)
            XCTAssertEqual(Appearance.Theme.night.label, "Night")
            XCTAssertEqual(Appearance.MenuBarText.roomTarget.label, "Room + target")
            XCTAssertEqual(Appearance.Background.glassStrong.label, "Strong glass")
        }
        XCTAssertEqual(Appearance.Theme.night.label, "Nacht")
    }

    func testEnergyEnglish() {
        english {
            let day = EnergyPeriod(start: local(11, 2), end: local(11, 3), kWh: 4.2, measuredKWh: 4.1, complete: true, current: false)
            XCTAssertEqual(UIText.energyPeriodLabel(day, kind: .day), "Mon 11/2")
            XCTAssertEqual(UIText.energyPeriodName(day, kind: .day), "Monday, November 2")
            XCTAssertEqual(UIText.energyTooltip(day, kind: .day, price: 0.30),
                           "Monday, November 2: 4.20 kWh · 1.26 € (air conditioner's meter)")
            let week = EnergyPeriod(start: local(11, 2), end: local(11, 9), kWh: 30, measuredKWh: nil, complete: true, current: false)
            XCTAssertEqual(UIText.energyPeriodLabel(week, kind: .week), "Wk 45")
            XCTAssertEqual(UIText.energyPeriodName(week, kind: .week), "Week 45 (11/2 – 11/8)")
            let month = EnergyPeriod(start: local(11, 1), end: local(12, 1), kWh: 30, measuredKWh: nil, complete: true, current: true)
            XCTAssertEqual(UIText.energyPeriodLabel(month, kind: .month), "Nov 2026")
            XCTAssertEqual(UIText.energyPeriodName(month, kind: .month), "November 2026")
            XCTAssertTrue(UIText.energyTooltip(month, kind: .month, price: 0.3).hasSuffix(" · not finished yet"))
            let measured = EnergyPeriod(start: local(11, 2), end: local(11, 3), kWh: nil, measuredKWh: 1, complete: true, current: false)
            XCTAssertEqual(UIText.energyCost(measured, price: 0.5, currency: "CHF"), "approx. 0.50 CHF")
            XCTAssertEqual(UIText.energySummary([measured], price: 0.5), "Total 1.00 kWh · 0.50 € · partly from measurements")
            let a = EnergyPeriod(start: local(11, 2), end: local(11, 3), kWh: 31.4, measuredKWh: nil, complete: true, current: false)
            XCTAssertEqual(UIText.energySummary([a], price: 0.3, currency: "CHF"), "Total 31.40 kWh · 9.42 CHF")
            XCTAssertEqual(UIText.energySummary([], price: 0.3), "Total –")
        }
    }

    func testEnergyGermanWithCurrency() {
        let a = EnergyPeriod(start: local(11, 2), end: local(11, 3), kWh: 31.4, measuredKWh: nil, complete: true, current: false)
        XCTAssertEqual(UIText.energySummary([a], price: 0.3, currency: "CHF"), "Summe 31,40 kWh · 9,42 CHF")
        XCTAssertEqual(UIText.energyCost(a, price: 0.3, currency: "CHF"), "9,42 CHF")
    }
}
