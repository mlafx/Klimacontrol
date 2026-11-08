import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Sucht deutsche Reste im englischen Katalog und in allen Anzeigetexten des Kerns.
@MainActor
final class EnglishLeakTests: CoreTestCase {
    override func tearDown() async throws {
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        try await super.tearDown()
    }

    /// „“ (U+201C) ist auch das öffnende Anführungszeichen des Englischen; deutsch ist nur das tiefgestellte „.
    private static let badCharacters = CharacterSet(charactersIn: "äöüÄÖÜß„‚")
    private static let badWords: Set<String> = [
        "der", "die", "das", "und", "nicht", "ist", "mit", "für", "anlage", "einstellungen", "verlauf",
        "zugangsdaten", "sicherung",
    ]

    private func leaks(in text: String) -> [String] {
        var found: [String] = []
        if text.rangeOfCharacter(from: Self.badCharacters) != nil { found.append("Zeichen") }
        // Dateinamen (verlauf.sqlite, verlauf.csv) bleiben deutsch.
        let cleaned = text.replacingOccurrences(of: "verlauf.", with: "file.")
        for token in cleaned.split(whereSeparator: { !$0.isLetter }) where Self.badWords.contains(token.lowercased()) {
            found.append(String(token))
        }
        return found
    }

    private func assertNoGerman(_ texts: [String], file: StaticString = #filePath, line: UInt = #line) {
        for t in texts {
            let found = leaks(in: t)
            XCTAssertTrue(found.isEmpty, "Deutscher Rest \(found) in: \(t)", file: file, line: line)
        }
    }

    private func local(_ day: Int = 6, _ hour: Int = 14, _ minute: Int = 32) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func setUpController(now: Date) throws -> ACController {
        let c = makeController()
        try c.adopt(Self.config)
        c.stop()
        c.now = { now }
        return c
    }

    private func set(_ c: ACController, mode: OperationalMode, power: Bool, fan: Int = 60, kWh: Double? = 100) {
        var s = ACState()
        s.power = power
        s.mode = mode
        s.targetTemperature = 24
        s.indoorTemperature = 25.5
        s.outdoorTemperature = 31
        s.fanSpeed = fan
        s.powerWatts = 450
        s.totalEnergyKWh = kWh
        c.state = s
    }

    private func catalogEnglish() -> [(key: String, text: String)] {
        var result: [(String, String)] = []
        for key in Localizer.catalog.keys {
            switch Localizer.catalog.value(key, .en) {
            case .text(let s)?: result.append((key, s))
            case .plural(let cases)?: for (k, s) in cases { result.append(("\(key)#\(k)", s)) }
            case nil: XCTFail("Englischer Text fehlt: \(key)")
            }
        }
        return result
    }

    /// Alle öffentlichen Anzeigetexte in einem Satz von Zuständen; jeder Eintrag stammt aus dem Katalog.
    private func collect() throws -> [String] {
        let t0 = local()
        let c = try setUpController(now: t0)
        var out: [String] = []
        let modes: [OperationalMode] = [.cool, .heat, .dry, .fan, .auto]

        for (power, kWh) in [(true, Optional(100.0)), (false, Optional(100.0)), (true, nil)] {
            for mode in modes {
                set(c, mode: mode, power: power, kWh: kWh)
                c.lastUpdate = t0.addingTimeInterval(-5)
                c.connectionPath = .lan
                out += [c.connectionLine(now: t0), c.connectionStatus.text, c.heroCaption, c.goalLine, c.statusLine,
                        c.miniCaption, c.costLine.title, c.costLine.value, c.costLine.help, c.powerCostHelp,
                        c.nextRefreshLine(now: t0)]
                out += [c.heroHint, c.menuTitle].compactMap { $0 }
                for f in UIOptions.ComfortFeature.allCases { out += [UIOptions.availability(f, mode: mode).why].compactMap { $0 } }
            }
        }
        set(c, mode: .cool, power: true)
        c.connectionPath = .cloud
        out.append(c.connectionLine(now: t0))
        c.connectionPath = nil
        out.append(c.connectionLine(now: t0))
        out.append(c.connectionTooltip)
        c.lastUpdate = t0.addingTimeInterval(-3600)
        c.showConnectionError(UserMessage(what: "x", todo: ""))
        out += [c.connectionLine(now: t0), c.connectionStatus.text, c.heroCaption].compactMap { $0 }
        out += [c.staleText].compactMap { $0 }
        c.showConnectionError(UserMessage(what: "x", todo: ""), deviceOff: true)
        out += [c.connectionLine(now: t0), c.connectionStatus.text]
        c.clearConnectionError()
        c.setOffTimer(in: 90, now: t0)
        c.setOnTimer(hour: 7, minute: 0, now: t0)
        out += [c.offTimerChip(now: t0), c.onTimerChip, c.onTimerLabel, c.offTimerLabel].compactMap { $0 }
        out += [c.quitPrompt()].compactMap { $0 }.flatMap { [$0.title, $0.message, $0.cancel, $0.confirm] }
        let forget = [c.forgetPrompt(host: .mac), c.forgetPrompt(host: .windows)]
        out += forget.flatMap { [$0.title, $0.message, $0.backup, $0.confirm, $0.cancel] }
        c.state = nil
        out += [c.heroCaption, c.statusLine, c.goalLine]
        out += [c.startupValues(from: nil, now: t0)].compactMap { $0 }.flatMap { [String(describing: $0)] }
        for phase in [ConnectPhase.searching, .handshake, .reading] { out.append(UIText.connectStepsLine(phase)) }
        out += [UIText.connectSlowText, UIText.retryButton, UIText.offCaption, UIText.offHint, UIText.fanModeCaption,
                UIText.notConfiguredCaption, UIText.updatesChecking, UIText.updatesCurrent, UIText.updatesInstalling(version: "1.2.0.0"),
                UIText.updatesFailed, UIText.updatesCheckButton, UIText.updatesHelp(host: .mac), UIText.updatesHelp(host: .windows),
                UIText.whatsNewTitle(version: "1.2.0.0"), UIText.whatsNewOK, UIText.whatsNewGermanOnly,
                UIText.importPanelTitle, UIText.importPanelMessage, UIText.exportBackupPanelTitle, UIText.exportBackupPanelMessage,
                UIText.exportHistoryPanelTitle, UIText.importAlertTitle, UIText.notBackedUpTitle,
                UIText.setupDoneTitle, UIText.setupBackupTitle, UIText.setupLANOnlyChoice, UIText.accountSignedIn,
                UIText.accountRemoved, UIText.accountFooter(signedIn: true, host: .mac), UIText.accountFooter(signedIn: false, host: .windows)]
        for p in [UIText.replaceScenesPrompt, UIText.otherDevicePrompt(backup: "A", current: "B"),
                  UIText.cloudFolderPrompt(folder: "OneDrive"), UIText.selfCleanPrompt,
                  UIText.accountRemovePrompt(host: .mac), UIText.accountRemovePrompt(host: .windows)] {
            out += [p.title, p.message, p.cancel, p.confirm]
        }
        out += [UIText.cloudNeedsAccount.title, UIText.cloudNeedsAccount.message, UIText.cloudFolderNotice.text]
        for mode in ConnectionMode.allCases { out.append(UIText.wayHelp(mode)) }
        out += UIText.connectSteps.map(\.name)
        out += UIText.maintenanceHints(filterAlert: true, errorCode: 5) + UIText.maintenanceHints(filterAlert: false, errorCode: 0)
        out += [UIText.errorCodeValue(0), UIText.errorCodeValue(7), UIText.filterValue(alert: true), UIText.filterValue(alert: false)]
        out += [UIText.backupExported(fileName: "a.json").text, UIText.historyExported(fileName: "a.csv").text,
                UIText.backupExportFailed(CocoaError(.fileWriteNoPermission)).text, UIText.historyExportFailed(CocoaError(.fileWriteNoPermission)).text,
                UIText.backupImportFailed(CocoaError(.fileReadCorruptFile)).text,
                UIText.backupImported(BackupImportResult(verified: true, scenesImported: 2, scenesSkipped: 1), ip: "192.168.1.40").text,
                UIText.backupImported(BackupImportResult(verified: false, scenesImported: 0, scenesSkipped: 0), ip: "192.168.1.40").text,
                UIText.backupImported(BackupImportResult(verified: nil, scenesImported: 1, scenesSkipped: 0), ip: "").text]

        // Auswahllisten, Verbrauch, Darstellung
        out += UIOptions.refreshChoices.map(\.label) + UIOptions.offTimerChoices.map(\.label) + UIOptions.fanMarks.map(\.label)
        out += UIOptions.chartRanges.map(\.label)
        out += [UIOptions.refreshCustomLabel, UIOptions.refreshCustomHelp, UIOptions.refreshWarning, UIOptions.fanLockedText,
                UIOptions.fanAutoHelp, UIOptions.addressExample, UIOptions.addressOrHostPrompt, UIOptions.tokenPrompt,
                UIOptions.keyPrompt, UIOptions.rateHelp, UIOptions.fanQuietZoneHelp(on: true), UIOptions.fanQuietZoneHelp(on: false),
                UIOptions.fanTurboZoneHelp(on: true), UIOptions.fanTurboZoneHelp(on: false)]
        for mode in modes {
            var s = ACState()
            s.mode = mode
            for speed in [1, 20, 60, 100, 102] { s.fanSpeed = speed; out.append(UIOptions.fanCaption(s)) }
            s.turbo = true
            out.append(UIOptions.fanCaption(s))
            s.turbo = false
            s.outSilent = true
            s.fanSpeed = 1
            out.append(UIOptions.fanCaption(s))
        }
        out += UIOptions.energyKinds.flatMap { [$0.label] }
        out += [UIText.energyTitle, UIText.energyHelp, UIText.energyLegend, UIText.energyNoData]
        for kind in EnergyPeriodKind.allCases {
            let end = kind == .day ? local(7) : kind == .week ? local(13) : Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1))!
            let start = kind == .day ? local(6) : kind == .week ? local(6) : local(11).addingTimeInterval(-5 * 86400)
            for (kWh, measured, complete, current) in [(Optional(4.2), Optional(4.1), true, false), (nil, Optional(1.0), false, true)] {
                let p = EnergyPeriod(start: start, end: end, kWh: kWh, measuredKWh: measured, complete: complete, current: current)
                out += [UIText.energyPeriodLabel(p, kind: kind), UIText.energyPeriodName(p, kind: kind),
                        UIText.energyTooltip(p, kind: kind, price: 0.3), UIText.energyCost(p, price: 0.3)]
                out.append(UIText.energySummary([p], price: 0.3))
            }
        }
        out += Appearance.Theme.allCases.map(\.label) + Appearance.Scheme.allCases.map(\.label)
        out += Appearance.Accent.allCases.map(\.label) + Appearance.CustomColor.allCases.map(\.label)
        out += Appearance.Background.allCases.map(\.label) + Appearance.SizeClass.allCases.map(\.label)
        out += Appearance.DigitStyle.allCases.map(\.label) + Appearance.HeroValue.allCases.map(\.label)
        out += Appearance.Scope.allCases.map(\.label) + Appearance.MenuBarText.allCases.map(\.label)

        // Meldungen
        let errors: [any Error] = [
            MideaError.timeout, MideaError.busy(""), MideaError.refused, MideaError.unreachable("x"),
            MideaError.authenticationFailed("x"), MideaError.crypto(3), MideaError.protocolError("x"),
            MideaError.invalidResponse("x"), MideaError.outcomeUnknown("x"), MideaError.connectionFailed("x"),
            MideaError.commandNotApplied(ACState()),
            MideaCloud.CloudError.api(3101, "x"), MideaCloud.CloudError.api(3123, "x"), MideaCloud.CloudError.api(9999, "x"),
            MideaCloud.CloudError.noToken, MideaCloud.CloudError.network("x"), MideaCloud.CloudError.tokenRejected,
            MideaCloud.CloudError.notInAccount, MideaCloud.CloudError.badReply("x"), MideaCloud.CloudError.api(42, "Boom"),
            ConfigError.noDevice, ConfigError.invalidHex, ConfigError.invalidAddress, ConfigError.unsupportedVersion(2),
        ]
        for e in errors {
            let m = UserMessage.from(e)
            out += [m.text, m.what, m.todo]
        }
        for (hint, path) in [(true, SetupPath.account), (false, .manual)] {
            _ = hint
            out.append(SetupFlow.nothingFoundText(target: "192.168.1.40", asked: nil, path: path))
            out.append(SetupFlow.nothingFoundText(target: nil, asked: 254, path: path))
            out.append(SetupFlow.nothingFoundText(target: nil, asked: nil, path: path))
        }
        out.append(SetupFlow.networkHint)
        for e in errors.compactMap({ $0 as? MideaError }) {
            out.append(SetupFlow.describeDevice(e, context: .manual).text)
        }
        out += [SetupFlow.describeCloud(.api(3101, "x"), context: .account).text,
                SetupFlow.describeCloud(.api(3123, "x"), context: .account).text,
                SetupFlow.describe(ConfigError.invalidHex, context: .manual).text]
        return out.filter { !$0.isEmpty }
    }

    func testCatalogEnglishHasNoGerman() {
        let all = catalogEnglish()
        XCTAssertGreaterThan(all.count, 900)
        for (key, text) in all {
            let found = leaks(in: text)
            XCTAssertTrue(found.isEmpty, "Deutscher Rest \(found) in \(key): \(text)")
        }
    }

    func testCollectedDisplayTextsEnglish() throws {
        try Localizer.withLanguage(.en) {
            try FormatProfile.withProfile(.unitedStates) {
                let texts = try collect()
                XCTAssertGreaterThan(texts.count, 300)
                assertNoGerman(texts)
            }
        }
    }

    func testCollectedDisplayTextsWithGermanFormatEnglish() throws {
        try Localizer.withLanguage(.en) { assertNoGerman(try collect()) }
    }

    func testPseudoMarksEveryCatalogText() throws {
        let texts = try Localizer.withLanguage(.en, pseudo: true) { try collect() }
        for t in texts {
            // Reine Einheiten wie “1 h” sind keine Wörter und stehen unübersetzt im Katalog.
            let letters = t.filter(\.isLetter)
            guard letters.count > 2 else { continue }
            XCTAssertTrue(t.contains("⟦"), "Text am Katalog vorbei (keine Pseudo-Markierung): \(t)")
        }
    }

    func testLogLinesFollowTheInterfaceLanguage() throws {
        let due = local(6, 7, 0)
        Localizer.withLanguage(.en) {
            FormatProfile.withProfile(.unitedStates) {
                XCTAssertEqual(TimerOutcome.executed(powerOn: false, due: due, at: due).logMessage,
                               "Timer “Off”: air conditioner turned off at 07:00.")
                XCTAssertEqual(ACController.logLabel(due, now: due), "today 07:00")
                XCTAssertEqual(MideaError.timeout.errorDescription, "The air conditioner is not responding.")
                XCTAssertEqual(KeychainError.unreadable.errorDescription,
                               "The stored entry is unreadable. Enter the credentials again in the settings.")
                XCTAssertEqual(L.Log.Level.error, "ERROR")
            }
        }
        Localizer.withLanguage(.de) {
            XCTAssertEqual(TimerOutcome.executed(powerOn: false, due: due, at: due).logMessage,
                           "Timer „Aus“: Anlage um 07:00 ausgeschaltet.")
            XCTAssertEqual(ACController.logLabel(due, now: due), "heute 07:00")
            XCTAssertEqual(MideaError.timeout.errorDescription, "Die Anlage antwortet nicht.")
            XCTAssertEqual(L.Log.Level.error, "FEHLER")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogLang-\(UUID().uuidString)")
        AppLog.redirect(to: dir)
        defer { AppLog.redirect(to: nil) }
        Localizer.withLanguage(.en) { AppLog.error(MideaError.timeout.errorDescription ?? "") }
        Localizer.withLanguage(.de) { AppLog.error(MideaError.timeout.errorDescription ?? "") }
        let tail = AppLog.tail()
        XCTAssertTrue(tail.contains(" ERROR The air conditioner is not responding."), tail)
        XCTAssertTrue(tail.contains(" FEHLER Die Anlage antwortet nicht."), tail)
    }

    func testRedactionDoesNotDependOnTheLanguage() {
        for language in AppLanguage.allCases {
            Localizer.withLanguage(language) {
                let line = LogText.t("log.cloud.kindError", "Cloud {kind}: {error}",
                                     ["kind": "MSmartHome", "error": "{\"token\": \"abc\", \"password\": 7}"])
                let out = AppLog.redact(line)
                XCTAssertFalse(out.contains("abc"), out)
                XCTAssertTrue(out.contains("\"token\":\"***\""), out)
                XCTAssertTrue(out.contains("\"password\":\"***\""), out)
            }
        }
    }
}
