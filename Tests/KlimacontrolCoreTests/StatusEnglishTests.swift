import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Status- und Kopfzeilen auf Englisch; Zahlenformat und Sprache sind unabhängig.
@MainActor
final class StatusEnglishTests: CoreTestCase {
    override func tearDown() async throws {
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        try await super.tearDown()
    }

    private func local(_ day: Int = 6, _ hour: Int = 14, _ minute: Int = 32) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func controller(now: Date) throws -> ACController {
        let c = makeController()
        try c.adopt(Self.config)
        c.stop()
        c.now = { now }
        return c
    }

    private func set(_ c: ACController, mode: OperationalMode = .cool, indoor: Double? = 25.5, target: Double = 24, power: Bool = true) {
        var s = ACState()
        s.power = power
        s.mode = mode
        s.targetTemperature = target
        s.indoorTemperature = indoor
        c.state = s
    }

    /// Kein deutsches Zeichen oder Wort in einem englischen Text.
    private func assertEnglish(_ texts: [String], file: StaticString = #filePath, line: UInt = #line) {
        let bad = CharacterSet(charactersIn: "äöüÄÖÜß„“")
        let words = ["der", "die", "das", "und", "nicht", "Anlage"]
        for t in texts {
            XCTAssertNil(t.rangeOfCharacter(from: bad), t, file: file, line: line)
            let tokens = t.split { !$0.isLetter }.map(String.init)
            for w in words { XCTAssertFalse(tokens.contains(w), "\(t) enthält „\(w)“", file: file, line: line) }
        }
    }

    func testConnectionLines() throws {
        let t0 = local()
        let c = try controller(now: t0)
        Localizer.withLanguage(.en) {
            XCTAssertEqual(c.connectionLine, "Connecting…")
            set(c)
            c.connectionPath = .lan
            c.lastUpdate = t0.addingTimeInterval(-5)
            XCTAssertEqual(c.connectionLine(now: t0), "Connected via Wi-Fi · just refreshed")
            XCTAssertEqual(c.connectionLine(now: t0.addingTimeInterval(300)), "Connected via Wi-Fi · refreshed 5 min ago")
            c.connectionPath = .cloud
            XCTAssertEqual(c.connectionLine(now: t0), "Connected via Cloud · just refreshed")
            c.connectionPath = nil
            XCTAssertEqual(c.connectionLine(now: t0), "Connected · just refreshed")
            c.showConnectionError(UserMessage(what: "x", todo: ""))
            XCTAssertEqual(c.connectionLine(now: t0), "No connection · last seen less than 1 min ago")
            XCTAssertEqual(c.connectionLine(now: t0.addingTimeInterval(300)), "No connection · last seen 5 min ago")
            c.showConnectionError(UserMessage(what: "x", todo: ""), deviceOff: true)
            XCTAssertEqual(c.connectionLine(now: t0), "Air conditioner off or without power · last seen less than 1 min ago")
            XCTAssertEqual(c.connectionStatus, ConnectionStatus(text: "Air conditioner off or without power", connected: false))
            assertEnglish([c.connectionLine(now: t0), c.connectionStatus.text])
        }
    }

    func testNotReachableAndStatus() throws {
        let t0 = local()
        let c = try controller(now: t0)
        Localizer.withLanguage(.en) {
            c.lastUpdate = nil
            c.showConnectionError(UserMessage(what: "x", todo: ""))
            XCTAssertEqual(c.connectionLine(now: t0), "Not reachable")
            c.connectionPath = .lan
            XCTAssertEqual(c.connectionTooltip, "Test · 192.168.1.40:6444 · local")
        }
        c.clearConnectionError()
        Localizer.withLanguage(.en) {
            XCTAssertEqual(c.connectionStatus, ConnectionStatus(text: "Connected via Wi-Fi", connected: true))
        }
    }

    func testStaleAndHeroCaption() throws {
        let t0 = local()
        let c = try controller(now: t0)
        set(c)
        c.lastUpdate = t0.addingTimeInterval(-3600)
        c.showConnectionError(UserMessage(what: "x", todo: ""))
        Localizer.withLanguage(.en) {
            XCTAssertEqual(c.staleText, "As of 13:32 · not current")
            FormatProfile.withProfile(.unitedStates) {
                XCTAssertEqual(c.staleText, "As of 1:32 PM · not current")
            }
        }
        c.clearConnectionError()
        var a = c.appearance
        a.hero = .room
        c.setAppearance(a)
        Localizer.withLanguage(.en) {
            XCTAssertEqual(c.heroCaption, "Target 24° · Cooling · 1,5° to target")
            FormatProfile.withProfile(.unitedStates) {
                XCTAssertEqual(c.heroCaption, "Target 24° · Cooling · 1.5° to target")
            }
            assertEnglish([c.heroCaption])
        }
        XCTAssertEqual(c.heroCaption, "Soll 24° · Kühlt · noch 1,5° bis zum Ziel")
    }

    func testCostLine() async throws {
        let c = try await makeConnected()
        let now = local()
        c.now = { now }
        c.pricePerKWh = 0.3
        c.currency = "CHF"
        var s = c.state!
        s.totalEnergyKWh = 100
        s.powerWatts = 400
        c.state = s
        settings.values[SettingsKey.energyDayStart] = "\(ACController.dayString(now));99;42;\(Int(now.addingTimeInterval(-6 * 3600).timeIntervalSince1970));0"
        XCTAssertEqual(c.costLine.value, "0,30 CHF")
        Localizer.withLanguage(.en) {
            FormatProfile.withProfile(.unitedStates) {
                XCTAssertEqual(c.costLine.title, "Cost since 8:32 AM")
                XCTAssertEqual(c.costLine.value, "0.30 CHF")
                XCTAssertEqual(c.costLine.help, "1.00 kWh per the meter of the air conditioner since 8:32 AM · meter total 100.00 kWh")
                XCTAssertEqual(c.powerCostHelp, "Cost at this power: 0.12 CHF per hour")
            }
            XCTAssertEqual(c.costLine.value, "0,30 CHF", "englisch mit deutschem Format")
            settings.values[SettingsKey.energyDayStart] = "\(ACController.dayString(now));105;42;\(Int(now.timeIntervalSince1970));1"
            XCTAssertEqual(c.costLine.value, "0,00 CHF · uncertain")
            XCTAssertTrue(c.costLine.help.hasSuffix("\nUncertain: The meter does not match the measured power."))
            XCTAssertEqual(c.costLine.title, "Cost today")
            assertEnglish([c.costLine.title, c.costLine.help, c.costLine.value])
            var s2 = c.state!
            s2.totalEnergyKWh = nil
            c.state = s2
            XCTAssertEqual(c.costLine.value, "unknown")
            XCTAssertEqual(c.costLine.help, "Daily consumption unknown; the meter of the air conditioner has not delivered a value yet.")
        }
    }

    func testGoalAndStatusLine() throws {
        let c = try controller(now: local())
        set(c, mode: .heat, indoor: 20.5, target: 22)
        c.connectionPath = .cloud
        Localizer.withLanguage(.en) {
            FormatProfile.withProfile(.unitedStates) {
                XCTAssertEqual(c.goalLine, "Heating · 1.5° to target")
            }
            XCTAssertEqual(c.goalLine, "Heating · 1,5° to target")
            XCTAssertEqual(c.statusLine, "Heating · Room 20,5° · via Cloud")
            set(c, mode: .heat, indoor: 22, target: 22)
            XCTAssertEqual(c.goalLine, "Heating · target reached")
            set(c, mode: .fan, indoor: 22.1)
            XCTAssertEqual(c.goalLine, "Fan running · Room 22,1°")
            set(c, mode: .cool, indoor: 24.5, power: false)
            XCTAssertEqual(c.statusLine, "Off · Room 24,5° · via Cloud")
            var s = c.state!
            s.selfClean = true
            c.state = s
            XCTAssertEqual(c.goalLine, "Self-cleaning running")
            assertEnglish([c.goalLine, c.statusLine])
        }
    }

    func testMiniCaption() throws {
        let c = makeController()
        Localizer.withLanguage(.en) {
            XCTAssertEqual(c.miniCaption, "Not set up")
        }
        try c.adopt(Self.config)
        c.stop()
        Localizer.withLanguage(.en) {
            XCTAssertEqual(c.miniCaption, "Connecting…")
            set(c)
            XCTAssertEqual(c.miniCaption, "Cool · Room 25,5°")
            set(c, power: false)
            XCTAssertEqual(c.miniCaption, "Off · Room")
            set(c, mode: .fan)
            XCTAssertEqual(c.miniCaption, "Fan · Room")
        }
    }

    func testTimerChipsAndRefreshLine() throws {
        let t0 = local()
        let c = try controller(now: t0)
        c.offAt = t0.addingTimeInterval(90 * 60)
        c.onAt = local(7, 7, 0)
        Localizer.withLanguage(.en) {
            XCTAssertEqual(c.offTimerChip, "Off in 1 h 30 min")
            XCTAssertTrue(c.onTimerChip?.hasPrefix("On ") == true)
            XCTAssertEqual(c.nextRefreshLine(now: t0), "Live from the air conditioner · every 30 s · next refresh in …")
            c.nextRefresh = t0.addingTimeInterval(11.2)
            XCTAssertEqual(c.nextRefreshLine(now: t0), "Live from the air conditioner · every 30 s · next refresh in 12 s")
            assertEnglish([c.offTimerChip ?? "", c.nextRefreshLine(now: t0)])
        }
    }

    func testStartupValues() throws {
        let t0 = local()
        let c = try controller(now: t0)
        let on = HistorySample(time: t0.addingTimeInterval(-3600), power: 300, indoor: 25.5, outdoor: 29, target: 24, on: true)
        let off = HistorySample(time: t0.addingTimeInterval(-3600), power: 0, indoor: 22, outdoor: nil, target: nil, on: false)
        Localizer.withLanguage(.en) {
            let v = c.startupValues(from: on, now: t0)
            XCTAssertEqual(v?.caption, "As of 13:32 · Target temperature")
            XCTAssertEqual(v?.extras, ["Room 25,5°", "Outdoor 29,0°"])
            XCTAssertEqual(v?.accessibility, "Last known values, As of 13:32: 24°")
            let w = c.startupValues(from: off, now: t0)
            XCTAssertEqual(w?.caption, "As of 13:32 · Room temperature · off")
            XCTAssertEqual(w?.extras, ["Outdoor –"])
            assertEnglish([v?.caption ?? "", w?.caption ?? ""] + (v?.extras ?? []))
        }
    }
}
