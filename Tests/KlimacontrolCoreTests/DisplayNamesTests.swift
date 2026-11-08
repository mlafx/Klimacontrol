import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

final class DisplayNamesTests: XCTestCase {
    override func tearDown() {
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        super.tearDown()
    }

    private let refusedDE = "Die Anlage weist die Verbindung ab. Stimmt die Adresse noch? Sonst „Adresse neu suchen“ – oder eine andere App hält die Anlage gerade."
    private let closedDE = "Die Anlage hat die Verbindung geschlossen."
    private let busyHintDE = "Vermutlich hält sie die Klimacontrol-App (Diagnose offen) oder die Midea-App. Die andere App schließen oder 10 Sekunden warten und erneut versuchen."
    private let noLanDE = "keine WLAN-Zugangsdaten – einmal mit dem Konto einrichten"
    private let noCloudDE = "Cloud nicht eingerichtet – einmal mit dem Midea-Konto anmelden"

    /// Kein deutsches Zeichen oder Wort in einem englischen Text.
    private func assertEnglish(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(text.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüÄÖÜß„")), text, file: file, line: line)
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        for w in ["der", "die", "das", "und", "nicht", "anlage"] {
            XCTAssertFalse(words.contains(w), "\(text) enthält „\(w)“", file: file, line: line)
        }
    }

    private func scene(on: Bool = true, mode: Int = 2, temp: Double = 18, fan: Int = 100) -> ACScene {
        ACScene(id: "s1", name: "Test", powerOn: on, mode: mode, tempC: temp, fan: fan, swing: false, eco: false,
                anion: false, outdoorSilent: false, selfClean: false)
    }

    func testModeAndFanTitles() {
        for mode in OperationalMode.allCases { XCTAssertEqual(mode.title, mode.label) }
        for fan in FanSpeed.allCases { XCTAssertEqual(fan.title, fan.label) }
        var state = ACState()
        state.fanSpeed = 37
        XCTAssertEqual(state.fanTitle, "37 %")
        state.fanSpeed = 40
        XCTAssertEqual(state.fanTitle, "Niedrig")
        Localizer.withLanguage(.en) {
            XCTAssertEqual(OperationalMode.cool.title, "Cool")
            XCTAssertEqual(OperationalMode.heat.title, "Heat")
            XCTAssertEqual(OperationalMode.dry.title, "Dry")
            XCTAssertEqual(OperationalMode.fan.title, "Fan")
            XCTAssertEqual(OperationalMode.auto.title, "Auto")
            XCTAssertEqual(FanSpeed.silent.title, "Quiet")
            XCTAssertEqual(FanSpeed.low.title, "Low")
            XCTAssertEqual(FanSpeed.medium.title, "Medium")
            XCTAssertEqual(FanSpeed.high.title, "High")
            XCTAssertEqual(FanSpeed.max.title, "Max")
            XCTAssertEqual(FanSpeed.auto.title, "Auto")
            state.fanSpeed = 37
            XCTAssertEqual(state.fanTitle, "37 %")
            state.fanSpeed = 40
            XCTAssertEqual(state.fanTitle, "Low")
        }
    }

    func testVerbs() {
        XCTAssertEqual(OperationalMode.cool.verb, "Kühlt")
        XCTAssertEqual(OperationalMode.heat.verb, "Heizt")
        XCTAssertEqual(OperationalMode.dry.verb, "Entfeuchtet")
        XCTAssertEqual(OperationalMode.fan.verb, "Lüftet")
        XCTAssertEqual(OperationalMode.auto.verb, "Regelt automatisch")
        Localizer.withLanguage(.en) {
            XCTAssertEqual(OperationalMode.cool.verb, "Cooling")
            XCTAssertEqual(OperationalMode.heat.verb, "Heating")
            XCTAssertEqual(OperationalMode.dry.verb, "Drying")
            XCTAssertEqual(OperationalMode.fan.verb, "Fan running")
            XCTAssertEqual(OperationalMode.auto.verb, "Auto mode")
        }
    }

    func testConnectionTitles() {
        for mode in ConnectionMode.allCases { XCTAssertEqual(mode.title, mode.label) }
        XCTAssertEqual(ConnectionPath.lan.title, ConnectionPath.lan.rawValue)
        XCTAssertEqual(ConnectionPath.cloud.title, ConnectionPath.cloud.rawValue)
        Localizer.withLanguage(.en) {
            XCTAssertEqual(ConnectionMode.auto.title, "Automatic (Wi-Fi first)")
            XCTAssertEqual(ConnectionMode.lan.title, "Wi-Fi only")
            XCTAssertEqual(ConnectionMode.cloud.title, "Cloud only (away)")
            XCTAssertEqual(ConnectionPath.lan.title, "Wi-Fi")
            XCTAssertEqual(ConnectionPath.cloud.title, "Cloud")
        }
    }

    func testSceneSummaryText() {
        XCTAssertEqual(scene().summaryText, "Kühlen · 18° · Max")
        XCTAssertEqual(scene().summaryText, scene().summary)
        XCTAssertEqual(scene(on: false).summaryText, "Aus")
        XCTAssertEqual(scene(on: false).summaryText, scene(on: false).summary)
        XCTAssertEqual(scene(fan: 37).summaryText, scene(fan: 37).summary)
        Localizer.withLanguage(.en) {
            XCTAssertEqual(scene().summaryText, "Cool · 18° · Max")
            XCTAssertEqual(scene(on: false).summaryText, "Off")
            XCTAssertEqual(scene(mode: 4, temp: 22, fan: 102).summaryText, "Heat · 22° · Auto")
        }
    }

    func testDateWords() {
        XCTAssertEqual(DateWords.today, "heute")
        XCTAssertEqual(DateWords.tomorrow, "morgen")
        XCTAssertEqual(DateWords.weekdayShort(1), "So")
        XCTAssertEqual(DateWords.weekdayLong(1), "Sonntag")
        XCTAssertEqual(DateWords.monthShort(3), "März")
        XCTAssertEqual(DateWords.monthShort(5), "Mai")
        XCTAssertEqual(DateWords.monthShort(9), "Sept.")
        XCTAssertEqual(DateWords.monthLong(12), "Dezember")
        Localizer.withLanguage(.en) {
            XCTAssertEqual(DateWords.today, "today")
            XCTAssertEqual(DateWords.tomorrow, "tomorrow")
            XCTAssertEqual(DateWords.weekdayShort(1), "Sun")
            XCTAssertEqual(DateWords.weekdayShort(7), "Sat")
            XCTAssertEqual(DateWords.weekdayLong(1), "Sunday")
            XCTAssertEqual(DateWords.monthShort(3), "Mar")
            XCTAssertEqual(DateWords.monthShort(5), "May")
            XCTAssertEqual(DateWords.monthLong(12), "December")
        }
        for n in [0, 8, -1, 13, 99] {
            XCTAssertEqual(DateWords.weekdayShort(n), "")
            XCTAssertEqual(DateWords.weekdayLong(n), "")
        }
        for n in [0, 13, -1] {
            XCTAssertEqual(DateWords.monthShort(n), "")
            XCTAssertEqual(DateWords.monthLong(n), "")
        }
    }

    func testReasonsGermanUnchanged() {
        let busyText = MideaError.busy(.otherApp).errorDescription!
        let cases: [(PathFailure, String)] = [
            (PathFailure(path: .lan, reason: .refused, text: refusedDE), refusedDE),
            (PathFailure(path: .lan, reason: .timeout, text: "antwortet nicht"), "antwortet nicht"),
            (PathFailure(path: .lan, reason: .unreachable, text: "nicht erreichbar"), "nicht erreichbar"),
            (PathFailure(path: .lan, reason: .busy(.otherApp), text: busyText), busyText),
            (PathFailure(path: .lan, reason: .busy(.unknown), text: MideaError.busy(.unknown).errorDescription!), MideaError.busy(.unknown).errorDescription!),
            (PathFailure(path: .lan, reason: .connection(.closed), text: closedDE), closedDE),
            (PathFailure(path: .lan, reason: .connection(.noLAN), text: noLanDE), noLanDE),
            (PathFailure(path: .cloud, reason: .connection(.noCloud), text: noCloudDE), noCloudDE),
            (PathFailure(path: .cloud, reason: .cloud(.network, code: nil), text: "Cloud nicht erreichbar"), "Cloud nicht erreichbar"),
            (PathFailure(path: .cloud, reason: .cloud(.wrongCredentials, code: 3101), text: "Falsch (3101)"), "Falsch (3101)"),
            (PathFailure(path: .cloud, reason: .cloud(.tokenRejected, code: nil), text: "Text (-1002)"), "Text (-1002)"),
            (PathFailure(path: .cloud, reason: .applianceOffline(nextCheck: "in 5 min"), text: "Anlage ausgeschaltet oder ohne Strom (laut Midea-Cloud) – nächste Prüfung in 5 min"),
             "Anlage ausgeschaltet oder ohne Strom (laut Midea-Cloud) – nächste Prüfung in 5 min"),
            (PathFailure(path: .cloud, reason: .applianceOffline(nextCheck: nil), text: "Anlage offline laut Cloud (3123)"),
             "Anlage offline laut Cloud (3123)"),
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(failure.displayText, expected)
            XCTAssertEqual(failure.displayText, failure.text)
        }

        XCTAssertEqual(MideaError.refused.connectionDetailText, MideaError.refused.connectionDetail)
        XCTAssertEqual(MideaError.connectionFailed("x").connectionDetailText, "x")
        XCTAssertEqual(MideaError.connectionFailed("x").connectionDetailText, MideaError.connectionFailed("x").connectionDetail)
        XCTAssertEqual(MideaError.connectionFailed(.closed).connectionDetailText, closedDE)
        XCTAssertEqual(MideaError.unreachable("Zeitüberschreitung").connectionDetailText, "Zeitüberschreitung")
        let all = MideaError.allPathsFailed([cases[0].0, cases[8].0])
        XCTAssertEqual(all.connectionDetailText, all.connectionDetail)
        let none = MideaError.allPathsFailed([])
        XCTAssertEqual(none.connectionDetailText, "kein Weg zur Anlage verfügbar")
        XCTAssertEqual(none.connectionDetailText, none.connectionDetail)
        XCTAssertNil(MideaError.timeout.connectionDetailText)

        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9, minute: 5))!
        let errors: [MideaCloud.CloudError] = [
            .api(3004, "token expired"), .noToken, .tokenRejected, .notInAccount, .paused(until: until), .keychainLocked,
            .network("offline"), .badReply("kaputt"), .sessionKeys("Sitzungsschlüssel passt nicht"), .incompleteLogin("fehlt"),
        ]
        for e in errors {
            // Der Rohtext nennt immer den Schlüsselbund; die Anzeige nennt den Speicher des Rechners.
            if case .keychainLocked = e {
                XCTAssertEqual(e.displayMessage, keychainLockedText())
                XCTAssertEqual(keychainLockedText(host: .mac), e.message)
            } else {
                XCTAssertEqual(e.displayMessage, e.message, "\(e)")
            }
        }
    }

    /// Jede Ursache hat in beiden Sprachen einen festen Katalogtext, unabhängig vom Rohtext.
    func testReasonMappingBothLanguages() {
        let cases: [(any Error, de: String, en: String)] = [
            (MideaError.connectionFailed(.closed), closedDE, "The air conditioner closed the connection."),
            (MideaError.connectionFailed(.noLAN), noLanDE, Localizer.text("reason.noLan", language: .en)),
            (MideaError.connectionFailed(.noCloud), noCloudDE, Localizer.text("reason.noCloud", language: .en)),
            (MideaError.connectionFailed(.noPath), "kein Weg zur Anlage verfügbar", "no way to reach the air conditioner"),
            (MideaError.connectionFailed(.other("Systemtext")), "Systemtext", "not reachable"),
            (MideaError.connectionFailed(.budget), "Die Anlage hat nicht rechtzeitig geantwortet (Zeitlimit erreicht). Erneut versuchen.", "not reachable"),
            (MideaError.refused, refusedDE, Localizer.text("reason.refused", language: .en)),
            (MideaError.unreachable("Zeitüberschreitung"), "Zeitüberschreitung", "not reachable"),
        ]
        for (e, de, en) in cases {
            let m = e as! MideaError
            XCTAssertEqual(m.connectionDetailText, de, "\(m)")
            Localizer.withLanguage(.en) {
                XCTAssertEqual(m.connectionDetailText, en, "\(m)")
            }
        }
        let paths: [(PathFailure, de: String, en: String)] = [
            (PathFailure(path: .lan, reason: .busy(.unknown), text: "x"), "Die Anlage ist gerade belegt. Bitte kurz warten und erneut versuchen.",
             Localizer.text("reason.busyShort", language: .en)),
            (PathFailure(path: .lan, reason: .busy(.otherApp), text: "x"), "Die Anlage ist gerade belegt. \(busyHintDE)",
             "The air conditioner is busy right now. Probably the Klimacontrol app (diagnostics open) or the Midea app is holding it. Close the other app, or wait 10 seconds and try again."),
            (PathFailure(path: .lan, reason: .connection(.closed), text: "x"), closedDE, "The air conditioner closed the connection."),
            (PathFailure(path: .lan, reason: .connection(.noLAN), text: "x"), noLanDE, Localizer.text("reason.noLan", language: .en)),
            (PathFailure(path: .cloud, reason: .connection(.noCloud), text: "x"), noCloudDE, Localizer.text("reason.noCloud", language: .en)),
            (PathFailure(path: .lan, reason: .connection(.noPath), text: "x"), "kein Weg zur Anlage verfügbar", "no way to reach the air conditioner"),
            (PathFailure(path: .lan, reason: .timeout, text: "x"), "antwortet nicht", "not responding"),
            (PathFailure(path: .lan, reason: .refused, text: "x"), refusedDE, Localizer.text("reason.refused", language: .en)),
            (PathFailure(path: .lan, reason: .other, text: "Fehlertext"), "Fehlertext", "not reachable"),
        ]
        for (f, de, en) in paths {
            XCTAssertEqual(f.displayText, de)
            Localizer.withLanguage(.en) { XCTAssertEqual(f.displayText, en); assertEnglish(f.displayText) }
        }
    }

    func testReasonsEnglish() {
        Localizer.withLanguage(.en) {
            let texts: [String?] = [
                MideaError.refused.connectionDetailText,
                MideaError.connectionFailed("Zeitüberschreitung").connectionDetailText,
                MideaError.unreachable("Netzwerk nicht erreichbar").connectionDetailText,
                MideaError.connectionFailed(.closed).connectionDetailText,
                MideaError.connectionFailed(.noLAN).connectionDetailText,
                MideaError.allPathsFailed([]).connectionDetailText,
                PathFailure(path: .lan, reason: .timeout, text: "antwortet nicht").displayText,
                PathFailure(path: .lan, reason: .busy(.otherApp), text: MideaError.busy(.otherApp).errorDescription!).displayText,
                PathFailure(path: .cloud, reason: .cloud(.tokenRejected, code: nil), text: "Text (-1002)").displayText,
                PathFailure(path: .cloud, reason: .applianceOffline(nextCheck: "in 5 min"), text: "x").displayText,
                MideaCloud.CloudError.tokenRejected.displayMessage,
                MideaCloud.CloudError.network("Zeitüberschreitung").displayMessage,
                MideaCloud.CloudError.badReply("Antwort unlesbar").displayMessage,
            ]
            for t in texts { assertEnglish(t ?? "") }
            XCTAssertTrue(MideaError.refused.connectionDetailText!.hasPrefix("The air conditioner refuses the connection."))
            XCTAssertEqual(MideaError.connectionFailed("Zeitüberschreitung").connectionDetailText, "not reachable")
            XCTAssertEqual(MideaError.connectionFailed(.closed).connectionDetailText, "The air conditioner closed the connection.")
            XCTAssertEqual(MideaError.allPathsFailed([]).connectionDetailText, "no way to reach the air conditioner")
            XCTAssertEqual(PathFailure(path: .lan, reason: .timeout, text: "antwortet nicht").displayText, "not responding")
            XCTAssertEqual(PathFailure(path: .cloud, reason: .applianceOffline(nextCheck: "in 5 min"), text: "x").displayText,
                           "Air conditioner off or without power (according to the Midea Cloud); next check in 5 min")
            let all = MideaError.allPathsFailed([
                PathFailure(path: .lan, reason: .timeout, text: "antwortet nicht"),
                PathFailure(path: .cloud, reason: .cloud(.network, code: nil), text: "Cloud nicht erreichbar"),
            ])
            XCTAssertEqual(all.connectionDetailText, "Wi-Fi: not responding · Cloud: Cloud not reachable")
            XCTAssertEqual(MideaCloud.CloudError.api(3004, "token expired").displayMessage, "token expired")
            XCTAssertEqual(PathFailure(path: .cloud, reason: .cloud(.wrongCredentials, code: 3101), text: "Wrong (3101)").displayText,
                           "Wrong (3101)")
            XCTAssertEqual(MideaCloud.CloudError.noToken.displayMessage, "no token")
        }
    }

    func testCloudPausedUsesFormatProfile() {
        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15, minute: 5))!
        XCTAssertEqual(MideaCloud.CloudError.paused(until: until).displayMessage,
                       "Die Cloud-Anmeldung ist nach Fehlschlägen pausiert. Klimacontrol versucht es ab 15:05 wieder.")
        Localizer.withLanguage(.en) {
            FormatProfile.withProfile(.unitedStates) {
                XCTAssertEqual(MideaCloud.CloudError.paused(until: until).displayMessage,
                               "Cloud sign-in is paused after failures. Klimacontrol will try again at 3:05 PM.")
            }
            XCTAssertEqual(MideaCloud.CloudError.paused(until: until).displayMessage,
                           "Cloud sign-in is paused after failures. Klimacontrol will try again at 15:05.")
        }
    }

    func testTextInLanguage() {
        XCTAssertEqual(Localizer.language, .de)
        XCTAssertEqual(Localizer.text("mode.cool", language: .en), "Cool")
        XCTAssertEqual(Localizer.text("mode.cool", language: .de), "Kühlen")
        XCTAssertEqual(Localizer.text("mode.cool"), "Kühlen")
        XCTAssertEqual(Localizer.text("fan.percent", language: .en, ["value": "37"]), "37 %")
        XCTAssertEqual(Localizer.text("no.such.key", language: .en), "no.such.key")
        Localizer.withLanguage(.en, pseudo: true) {
            XCTAssertEqual(Localizer.text("mode.cool", language: .de), "Kühlen")
        }
    }

    func testStandStillGerman() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 18))!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 32))!
        let earlier = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 14, minute: 32))!
        XCTAssertEqual(Fmt.stand(today, now: now), "Stand 14:32")
        XCTAssertEqual(Fmt.stand(earlier, now: now), "Stand 05.11., 14:32")
        Localizer.withLanguage(.en) {
            XCTAssertEqual(Fmt.stand(today, now: now), "As of 14:32")
            XCTAssertEqual(Fmt.stand(earlier, now: now), "As of 05.11., 14:32")
            XCTAssertEqual(Fmt.stand(earlier, now: now, profile: .unitedStates), "As of 11/05, 2:32 PM")
        }
    }

    func testProtocolLinesFollowTheInterfaceLanguage() {
        var state = ACState()
        state.power = true
        state.mode = .cool
        state.targetTemperature = 22
        state.indoorTemperature = 21.5
        state.powerWatts = 1200
        var before = state
        before.targetTemperature = 20
        before.mode = .heat
        Localizer.withLanguage(.en) {
            FormatProfile.withProfile(.unitedStates) {
                let line = Fmt.stateLine(state)
                XCTAssertTrue(line.contains("target 22°"), line)
                XCTAssertTrue(line.contains("21,5°"), line)
                XCTAssertTrue(line.contains("Cool"), line)
                XCTAssertTrue(line.contains("1.200 W"), line)
                let change = Fmt.change(from: before, to: state)
                XCTAssertTrue(change.contains("Mode Cool"), change)
                XCTAssertTrue(change.contains("Target 22°"), change)
            }
        }
        Localizer.withLanguage(.de) {
            XCTAssertTrue(Fmt.stateLine(state).contains("Soll 22°"))
            XCTAssertTrue(Fmt.change(from: before, to: state).contains("Modus Kühlen"))
        }
    }
}
