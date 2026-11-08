import Foundation
@testable import KlimacontrolBridge
@testable import KlimacontrolCore
import MideaKit
import XCTest

private final class NoPlatform: PlatformServices {
    func keepAwake(_ on: Bool) {}
    func discard(_ url: URL) throws {}
}

private final class NoSettings: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Englische Texte der Bridge: Meldungen, Schnappschuss, Optionen (neu je Sprache), Verbrauch.
@MainActor
final class BridgeEnglishTests: XCTestCase {
    private var dir: URL!
    private var controller: ACController!

    override func setUp() async throws {
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-en-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        controller = ACController(appVersion: "test", settings: NoSettings(), paths: CorePaths(directory: dir),
                                  platform: NoPlatform(), accounts: accounts,
                                  makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
        try controller.adopt(DeviceConfig(name: "net_ac_1A2B", ip: "192.168.1.40", port: 6444, deviceId: 111122223333444,
                                          token: String(repeating: "ab", count: 64), key: String(repeating: "cd", count: 32)))
        controller.stop()
        controller.clearConnectionError()
    }

    override func tearDown() async throws {
        controller.stop()
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
        try? FileManager.default.removeItem(at: dir)
    }

    private func assertEnglish(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for ch in "äöüÄÖÜß„" {
            XCTAssertFalse(text.contains(ch), "deutsches Zeichen \(ch) in: \(text)", file: file, line: line)
        }
        for word in ["der", "die", "das", "und", "nicht", "Anlage"] {
            XCTAssertFalse(text.split(whereSeparator: { !$0.isLetter }).contains { $0 == word }, "deutsches Wort \(word) in: \(text)",
                           file: file, line: line)
        }
    }

    func testWrongTypeGivesEnglishMessageWithCode() throws {
        Localizer.withLanguage(.en) {
            let args = CommandArgs(cmd: "power", values: [:])
            let error = XCTAssertThrowsErrorResult { try args.bool("on") }
            let text = bridgeMessage(for: error)
            XCTAssertEqual(text, "Command “power” incomplete: value “on” is missing or does not fit (expected: on/off). "
                           + "Restart the app; if it persists, install the current version. (param-on)")
            assertEnglish(text)
            XCTAssertEqual(parsedMessage(text).code, "param-on")
        }
    }

    func testCommandMessagesAreEnglish() {
        Localizer.withLanguage(.en) {
            XCTAssertEqual(handleCommand(#"{"cmd":"refresh"}"#, on: nil),
                           "Klimacontrol is not ready yet. Restart the app. (core-not-started)")
            XCTAssertEqual(handleCommand("{", on: controller), "Command not readable. Restart the app. (bad-command)")
            let unknown = handleCommand(#"{"cmd":"nope"}"#, on: controller) ?? ""
            XCTAssertTrue(unknown.hasPrefix("Unknown command “nope”."), unknown)
            XCTAssertTrue(unknown.hasSuffix("(unknown-command)"), unknown)
            assertEnglish(unknown)
            XCTAssertEqual(handleCommand(#"{"cmd":"mode","value":99}"#, on: controller),
                           "Klimacontrol does not know this mode. Choose a different one. (mode-99)")
        }
    }

    func testIssueForMissingFileIsEnglish() {
        Localizer.withLanguage(.en) {
            let issue = bridgeIssue(for: CocoaError(.fileNoSuchFile))
            XCTAssertEqual(issue.text, "The file was not found. Check the location and name. (file-4)")
            XCTAssertEqual(issue.code, "file-4")
            assertEnglish(issue.text)
            XCTAssertEqual(exportHistoryMessage(for: CocoaError(.fileNoSuchFile)),
                           "The history could not be saved. Check the location and name. (file-4)")
        }
        XCTAssertEqual(bridgeIssue(for: CocoaError(.fileNoSuchFile)).text,
                       "Die Datei wurde nicht gefunden. Bitte Ort und Namen prüfen. (file-4)")
    }

    func testEnergyErrorsAreEnglish() throws {
        Localizer.withLanguage(.en) {
            let kind = energyJSON(controller, kind: "year", count: 3)
            XCTAssertEqual(kind, #"{"error":"Unknown type of consumption (day, week, month)."}"#)
            let count = energyJSON(controller, kind: "day", count: 0)
            XCTAssertEqual(count, #"{"error":"The number of periods must be between 1 and 60."}"#)
        }
        XCTAssertEqual(energyJSON(controller, kind: "day", count: 99),
                       #"{"error":"Die Anzahl der Zeiträume muss zwischen 1 und 60 liegen."}"#)
    }

    func testSnapshotAndOptionsFollowTheLanguage() throws {
        func options() throws -> [String: Any] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotJSON(controller).utf8)) as? [String: Any])
            return try XCTUnwrap(json["options"] as? [String: Any])
        }
        let german = try options()
        XCTAssertEqual((german["refresh"] as? [String: Any])?["customHelp"] as? String, "1 bis 600 Sekunden.")
        try Localizer.withLanguage(.en) {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotJSON(controller).utf8)) as? [String: Any])
            let o = try XCTUnwrap(json["options"] as? [String: Any])
            let help = try XCTUnwrap((o["refresh"] as? [String: Any])?["customHelp"] as? String)
            assertEnglish(help)
            XCTAssertNotEqual(help, "1 bis 600 Sekunden.")
            let modes = try XCTUnwrap(o["connectionModes"] as? [[String: Any]])
            XCTAssertEqual(modes.compactMap { $0["label"] as? String }, ["Automatic (Wi-Fi first)", "Wi-Fi only", "Cloud only (away)"])
            let pairs = try XCTUnwrap(json["connectionModes"] as? [[String]])
            XCTAssertEqual(pairs.map { $0[1] }, ["Automatic (Wi-Fi first)", "Wi-Fi only", "Cloud only (away)"])
            let requirement = try XCTUnwrap(json["timerRequirement"] as? String)
            assertEnglish(requirement)
            XCTAssertFalse(requirement.isEmpty)
        }
        XCTAssertEqual((try options()["refresh"] as? [String: Any])?["customHelp"] as? String, "1 bis 600 Sekunden.")
    }

    func testStateLabelsAndSceneSummaryAreEnglish() throws {
        let scene = ACScene(id: "s1", name: "Night", powerOn: true, mode: OperationalMode.cool.rawValue, tempC: 18,
                            fan: FanSpeed.max.rawValue, swing: false, eco: false,
                            anion: false, outdoorSilent: false, selfClean: false)
        Localizer.withLanguage(.en) {
            XCTAssertEqual(scene.summaryText, "Cool · 18° · Max")
            XCTAssertEqual(OperationalMode.cool.title, "Cool")
        }
    }
}

private func XCTAssertThrowsErrorResult<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) -> any Error {
    do {
        _ = try body()
        XCTFail("kein Fehler", file: file, line: line)
    } catch {
        return error
    }
    return CommandError("none")
}
