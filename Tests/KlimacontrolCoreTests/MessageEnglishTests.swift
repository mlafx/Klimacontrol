import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

final class MessageEnglishTests: XCTestCase {
    override func tearDown() {
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        super.tearDown()
    }

    private func en<T>(_ body: () -> T) -> T { Localizer.withLanguage(.en, body) }

    func testDeviceMessages() {
        en {
            XCTAssertEqual(UserMessage.from(MideaError.timeout).text,
                           "The air conditioner is not responding. Check that it has power and is connected to Wi-Fi. Klimacontrol keeps trying.")
            XCTAssertEqual(UserMessage.from(MideaError.busy(.unknown)).text,
                           "The air conditioner is busy right now. Close other apps (Midea app, a second Klimacontrol with Diagnostics open) or wait 10 s.")
            XCTAssertEqual(UserMessage.from(MideaError.crypto(-5)).text,
                           "The air conditioner's response could not be decrypted. Try again. (-5)")
            XCTAssertEqual(UserMessage.from(MideaError.commandNotApplied(ACState())).text,
                           "The air conditioner did not apply the change. Another app may be controlling it right now. Try again.")
            XCTAssertEqual(UserMessage.switchNotApplied("iECO", mode: .fan).text,
                           "The air conditioner did not apply “iECO” in “Fan” mode. The air conditioner does not accept this switch in this mode. Choose another mode and try again. (not-in-mode)")
            XCTAssertEqual(UserMessage.deviceOff(detail: nil).text,
                           "The air conditioner is off or has no power (according to the Midea cloud). Klimacontrol keeps checking. (3123)")
            let failed = MideaError.allPathsFailed([PathFailure(path: .cloud, reason: .cloud(.other, code: 3004), text: "x")])
            let m = UserMessage.from(failed)
            XCTAssertEqual(m.what, "No connection to the air conditioner.")
            XCTAssertEqual(m.code, "3004")
        }
    }

    func testCloudMessages() {
        en {
            let m = UserMessage.from(MideaCloud.CloudError.api(3101, "x"))
            XCTAssertEqual(m.text, "The email or password of the Midea account is incorrect. Enter the credentials from the MSmartHome app again in Settings. (3101)")
            let other = UserMessage.from(MideaCloud.CloudError.api(42, "Boom"))
            XCTAssertEqual(other.what, "The Midea cloud reports an error: Boom.")
        }
        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 5))!
        en {
            FormatProfile.withProfile(.unitedStates) {
                XCTAssertEqual(UserMessage.from(MideaCloud.CloudError.paused(until: until)).text,
                               "Cloud sign-in is paused after failures. Klimacontrol will try again at 2:05 PM.")
            }
        }
        XCTAssertEqual(UserMessage.from(MideaCloud.CloudError.api(3101, "x")).what,
                       "E-Mail oder Passwort des Midea-Kontos stimmen nicht.")
    }

    func testKeychainMessages() {
        XCTAssertEqual(UserMessage.from(KeychainError.unavailable(5), host: .mac).text,
                       "Der Schlüsselbund ist gesperrt oder hat den Zugriff abgelehnt. Mac entsperren bzw. den Zugriff erlauben und erneut versuchen. (Status 5)")
        XCTAssertEqual(UserMessage.from(KeychainError.tooLarge(3000)).text,
                       "Die Daten sind zu groß für den Geheimnisspeicher. Bitte melden. (3000 Byte)")
        en {
            XCTAssertEqual(UserMessage.from(KeychainError.unavailable(5), host: .mac).text,
                           "The keychain is locked or denied access. Unlock the Mac or allow access, then try again. (status 5)")
        }
    }

    @MainActor func testBackupAndAccountTexts() {
        XCTAssertEqual(BackupImportError.otherDevice(backup: "A", current: "B").errorDescription,
                       "Die Sicherung gehört zu einer anderen Anlage („A“, eingerichtet ist „B“). Wähle die passende Sicherung oder bestätige, dass du die Anlage wechseln willst.")
        en {
            XCTAssertEqual(BackupImportError.otherDevice(backup: "Living room", current: "Bedroom").errorDescription,
                           "The backup belongs to a different air conditioner (“Living room”, currently set up: “Bedroom”). Choose the matching backup or confirm that you want to switch air conditioners.")
            XCTAssertEqual(BackupImportError.nothingToExport.errorDescription,
                           "No air conditioner is set up yet. Set one up first.")
            #if os(Windows)
            XCTAssertEqual(CloudAccountError.notSaved.errorDescription, L.Message.Account.Windows.notSaved)
            #else
            XCTAssertEqual(CloudAccountError.notSaved.errorDescription,
                           "The Midea account was not saved in the keychain. Check keychain access and sign in again.")
            #endif
        }
        let german = ACController.defaultDisplayName
        let english = Localizer.withLanguage(.en) { ACController.defaultDisplayName }
        XCTAssertEqual(german, "Klimaanlage")
        XCTAssertEqual(english, "Air conditioner")
    }

    func testRelocateTexts() {
        en {
            XCTAssertEqual(L.Message.Relocate.moved(ip: "192.168.1.40"),
                           "The air conditioner has a new address (192.168.1.40) and is connected again.")
            XCTAssertEqual(L.Message.Relocate.LoginFailed.what(ip: "192.168.1.40"),
                           "The air conditioner is at the new address 192.168.1.40, but signing in there did not work just now.")
        }
    }

    func testSplitPointIsFirstSentence() {
        en {
            for text in [L.Message.Backup.otherDevice(backup: "A", current: "B"), L.Message.Backup.rejected,
                         L.Message.Relocate.notFound, L.Message.Account.noId] {
                XCTAssertNotNil(text.range(of: ". "), text)
            }
        }
    }
}
