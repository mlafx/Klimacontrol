import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Rückfragen, Ergebnisse, Timer-Texte und Startanzeige auf Englisch; Deutsch bleibt Standard.
@MainActor
final class PromptEnglishTests: XCTestCase {
    override func tearDown() async throws {
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        try await super.tearDown()
    }

    private func en<T>(_ body: () -> T) -> T { Localizer.withLanguage(.en) { FormatProfile.withProfile(.unitedStates, body) } }

    private func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testForgetPromptBothHosts() {
        let mac = en { UIText.forgetPrompt(needsBackup: false, host: .mac) }
        XCTAssertEqual(mac.title, "Set up the air conditioner again?")
        XCTAssertEqual(mac.message, "The setup file goes to the Trash unchanged. The token and key are then in the Trash; emptying it deletes them. "
            + "The Midea account session ends. Klimacontrol then searches again, on Wi-Fi or through the Midea account.")
        XCTAssertEqual([mac.backup, mac.confirm, mac.cancel], ["Back up first…", "Set up again", "Cancel"])
        XCTAssertFalse(mac.warning)
        let win = en { UIText.forgetPrompt(needsBackup: true, host: .windows) }
        XCTAssertTrue(win.message.hasPrefix("The setup file is not deleted but set aside unchanged in the data folder."))
        XCTAssertTrue(win.message.hasSuffix("without a new search."))
        XCTAssertTrue(win.message.contains("\n\nThe credentials are not backed up yet."))
        XCTAssertTrue(win.warning)
    }

    func testHostWordsFollowLanguage() {
        XCTAssertEqual(HostWords.mac.credentialStoreDative, "dem Schlüsselbund")
        XCTAssertEqual(HostWords.windows.computer, "Rechner")
        XCTAssertEqual(en { HostWords.mac.credentialStoreDative }, "the Keychain")
        XCTAssertEqual(en { HostWords.windows.credentialStoreDative }, "Windows Credential Manager")
        XCTAssertEqual(en { HostWords.windows.computer }, "computer")
        XCTAssertEqual(en { HostWords.mac.updatesHelp }, "Updates are downloaded automatically. Klimacontrol then asks whether to restart right away; otherwise the update is installed when the app quits.")
        XCTAssertEqual(en { HostWords.windows.updatesHelp }, "Klimacontrol checks for updates daily and asks before installing.")
        XCTAssertEqual(en { UIText.accountRemovePrompt(host: .windows).message },
                       "The account and password are deleted from Windows Credential Manager, so the air conditioner can no longer be reached while away. You can sign in again at any time.")
    }

    func testQuitPromptWithBothTimers() throws {
        let now = local(6, 10)
        let prompt = try XCTUnwrap(en { UIText.quitPrompt(off: local(6, 19, 30), on: local(7, 7), now: now) })
        XCTAssertEqual(prompt.message, "Timers “Off” today at 7:30 PM and “On” tomorrow at 7:00 AM are set. They only run while Klimacontrol is open.")
        XCTAssertEqual([prompt.title, prompt.cancel, prompt.confirm], ["Quit Klimacontrol?", "Keep open", "Quit anyway"])
        let one = try XCTUnwrap(en { UIText.quitPrompt(off: nil, on: local(9, 7), now: now) })
        XCTAssertEqual(one.message, "Timer “On” on Mon 11/9 at 7:00 AM is set. It only runs while Klimacontrol is open.")
        let de = try XCTUnwrap(UIText.quitPrompt(off: nil, on: local(9, 7), now: now))
        XCTAssertEqual(de.message, "Timer „Ein“ am Mo. 9.11. um 07:00 ist gestellt. Er schaltet nur, solange Klimacontrol geöffnet ist.")
        XCTAssertNil(UIText.quitPrompt(off: nil, on: nil, now: now))
    }

    func testBackupImportedPlural() {
        XCTAssertEqual(en { UIText.backupImported(BackupImportResult(verified: true, scenesImported: 1), ip: "").text },
                       "Backup restored; the air conditioner accepts the credentials. 1 scene imported.")
        XCTAssertEqual(en { UIText.backupImported(BackupImportResult(verified: nil, scenesImported: 3, scenesSkipped: 2), ip: "").text },
                       "Backup restored. 3 scenes imported. The existing scenes are kept.")
        XCTAssertEqual(UIText.backupImported(BackupImportResult(verified: nil, scenesImported: 1), ip: "").text, "Sicherung eingelesen. 1 Szene übernommen.")
        let silent = en { UIText.backupImported(BackupImportResult(verified: false), ip: "192.168.1.40") }
        XCTAssertFalse(silent.ok)
        XCTAssertEqual(silent.message.what, "Backup restored, but the air conditioner is not responding at 192.168.1.40.")
    }

    func testFilesAndFolderPrompts() {
        XCTAssertEqual(en { UIText.exportBackupFileName }, "Klimacontrol-Backup.json")
        XCTAssertEqual(en { UIText.exportHistoryFileName }, "Klimacontrol-History.csv")
        XCTAssertEqual(UIText.exportBackupFileName, "Klimacontrol-Sicherung.json")
        let p = en { UIText.cloudFolderPrompt(folder: "OneDrive") }
        XCTAssertEqual(p.title, "Back up to a cloud folder?")
        XCTAssertEqual(p.message, "“OneDrive” is synced with a cloud service. The token and key allow controlling the air conditioner, so store the backup locally or on a USB drive instead.")
        XCTAssertEqual([p.cancel, p.confirm], ["Choose another location", "Back up anyway"])
        XCTAssertEqual(en { UIText.historyExported(fileName: "a.csv").text }, "History saved as “a.csv”.")
    }

    func testAccountFooterAndWay() {
        XCTAssertEqual(en { UIText.accountFooter(signedIn: false, host: .mac) },
                       "Optional. The password is stored only in the macOS Keychain so that Klimacontrol can sign in again. It leaves the Mac only to sign in to Midea.")
        XCTAssertTrue(en { UIText.accountFooter(signedIn: true, host: .mac) }.hasPrefix("Signed in. With “Automatic”, the Midea account takes over"))
        XCTAssertEqual(en { UIText.wayHelp(.lan) }, "On the same Wi-Fi only. Never uses Midea servers and needs no internet.")
        let done = en { UIText.setupDonePrompt(SetupCompletion(path: .manual, suggestLANOnly: false, offerBackup: true, note: ""), host: .windows) }
        XCTAssertEqual(done?.primary, "Back up…")
        XCTAssertEqual(done?.secondary, "Later")
        XCTAssertEqual(done?.paragraphs.first, "Without a Midea account, the token and key are stored only on this computer. A backup is needed for another computer or after “Set up again”.")
    }

    func testStartupAndDiagnostics() {
        XCTAssertEqual(en { UIText.connectStepsLine(.handshake) }, "Finding air conditioner ✓ · Signing in… · Reading values")
        XCTAssertEqual(UIText.connectStepsLine(.handshake), "Anlage suchen ✓ · Anmelden … · Werte lesen")
        XCTAssertEqual(en { UIText.maintenanceHints(filterAlert: true, errorCode: 7) },
                       ["The air conditioner reports a fault. The meaning and remedy are in the user manual (code 7).",
                        "Clean the filter: The air conditioner asks for a filter cleaning (see the user manual)."])
        XCTAssertEqual(en { UIText.errorCodeValue(0) }, "none")
        XCTAssertEqual(en { UIText.errorCodeValue(5) }, "Code 5, see the user manual")
        XCTAssertEqual(en { UIText.offCaption }, "Room temperature · air conditioner off")
        XCTAssertEqual(en { UIText.retryButton }, "Try again")
    }

    func testTimerTexts() {
        let due = local(6, 7)
        let missed = en { TimerOutcome.missed(powerOn: true, due: due).message }
        XCTAssertEqual(missed, "Timer “On” for 7:00 AM missed. Klimacontrol was closed or the computer was asleep. Set the timer again.")
        XCTAssertEqual(en { TimerOutcome.executed(powerOn: false, due: due, at: local(6, 7, 1)).message },
                       "Timer “Off”: air conditioner turned off at 7:01 AM.")
        XCTAssertEqual(en { TimerOutcome.failed(powerOn: true, due: due, reason: .unreachable).title }, "Timer not executed")
        XCTAssertEqual(TimerOutcome.missed(powerOn: false, due: due).message,
                       "Timer „Aus“ für 07:00 verpasst. Klimacontrol war geschlossen oder der Rechner schlief – bitte neu stellen.")
        XCTAssertEqual(en { ACController.timerRequirement }, "The timer only runs while Klimacontrol is open and the computer is awake.")
    }

    func testTimerLabel() {
        let now = local(6, 10)
        XCTAssertEqual(en { ACController.timerLabel(local(7, 7), now: now) }, "tomorrow 7:00 AM")
        XCTAssertEqual(en { ACController.timerLabel(local(6, 19, 5), now: now) }, "today 7:05 PM")
        XCTAssertEqual(en { ACController.timerLabel(local(9, 7), now: now) }, "Mon 7:00 AM")
        XCTAssertEqual(ACController.timerLabel(local(7, 7), now: now), "morgen 07:00")
        XCTAssertEqual(ACController.timerLabel(local(9, 7), now: now), "Mo 07:00")
    }

    func testDayLabelGermanKeepsPadding() {
        let now = local(6, 10)
        let jan = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 6, hour: 8))!
        XCTAssertEqual(UIText.dayLabel(jan, now: now), "am Mi. 6.01.")
    }
}
