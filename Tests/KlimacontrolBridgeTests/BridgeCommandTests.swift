import Foundation
@testable import KlimacontrolBridge
@testable import KlimacontrolCore
import MideaKit
import XCTest

private final class QuietPlatform: PlatformServices {
    func keepAwake(_ on: Bool) {}
    func discard(_ url: URL) throws {}
}

private final class MemoryStore: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Befehle von `kc_command`: strenge Parametertypen, Meldungen, Befehlstabelle und Abgleich mit der Windows-Oberfläche.
/// Die Anlage ist nicht erreichbar (`makeDevice` wirft); geprüft werden nur Fälle, die vor jedem Senden scheitern.
@MainActor
final class BridgeCommandTests: XCTestCase {
    private var dir: URL!
    private var controllers: [ACController] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.stop() }
        controllers = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeController(configured: Bool) throws -> ACController {
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        let c = ACController(appVersion: "test", settings: MemoryStore(), paths: CorePaths(directory: dir),
                             platform: QuietPlatform(), accounts: accounts,
                             makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
        controllers.append(c)
        if configured {
            try c.adopt(DeviceConfig(name: "net_ac_1A2B", ip: "192.168.1.40", port: 6444, deviceId: 111122223333444,
                                     token: String(repeating: "ab", count: 64), key: String(repeating: "cd", count: 32)))
        }
        return c
    }

    private func args(_ json: String) throws -> CommandArgs { try XCTUnwrap(CommandArgs(json: json), json) }

    private func assertError<T>(_ body: @autoclosure () throws -> T, code: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let text = bridgeMessage(for: error)
            XCTAssertTrue(text.hasSuffix("(\(code))"), "Meldung „\(text)“ endet nicht mit (\(code))", file: file, line: line)
        }
    }

    // MARK: - CommandArgs

    func testBoolAcceptsOnlyRealBooleans() throws {
        XCTAssertTrue(try args(#"{"cmd":"power","on":true}"#).bool("on"))
        XCTAssertFalse(try args(#"{"cmd":"power","on":false}"#).bool("on"))
        assertError(try args(#"{"cmd":"power","on":1}"#).bool("on"), code: "param-on")
        assertError(try args(#"{"cmd":"power","on":0}"#).bool("on"), code: "param-on")
        assertError(try args(#"{"cmd":"power","on":"true"}"#).bool("on"), code: "param-on")
        assertError(try args(#"{"cmd":"power"}"#).bool("on"), code: "param-on")
        assertError(try args(#"{"cmd":"power","on":null}"#).bool("on"), code: "param-on")
    }

    func testNumbersRejectBooleans() throws {
        XCTAssertEqual(try args(#"{"cmd":"temp","value":21.5}"#).double("value"), 21.5)
        XCTAssertEqual(try args(#"{"cmd":"temp","value":21}"#).int("value"), 21)
        XCTAssertEqual(try args(#"{"cmd":"temp","value":-3}"#).int("value"), -3)
        assertError(try args(#"{"cmd":"temp","value":true}"#).double("value"), code: "param-value")
        assertError(try args(#"{"cmd":"temp","value":false}"#).int("value"), code: "param-value")
        assertError(try args(#"{"cmd":"temp","value":"21"}"#).double("value"), code: "param-value")
        assertError(try args(#"{"cmd":"temp","value":21.5}"#).int("value"), code: "param-value")
        assertError(try args(#"{"cmd":"temp","value":1e12}"#).int("value"), code: "param-value")
        assertError(try args(#"{"cmd":"temp"}"#).double("value"), code: "param-value")
    }

    func testStringsAndOptionals() throws {
        let a = try args(#"{"cmd":"x","s":"abc","n":5,"nothing":null}"#)
        XCTAssertEqual(try a.string("s"), "abc")
        assertError(try a.string("n"), code: "param-n")
        XCTAssertNil(try a.optionalString("nothing"))
        XCTAssertNil(try a.optionalString("missing"))
        XCTAssertNil(try a.optionalInt("missing"))
        XCTAssertEqual(try a.optionalInt("n"), 5)
        assertError(try a.optionalInt("s"), code: "param-s")
        XCTAssertEqual(try a.optionalDate("n"), Date(timeIntervalSince1970: 5))
        XCTAssertNil(try a.optionalDate("nothing"))
    }

    func testFlagDefaultsAndStrictness() throws {
        let a = try args(#"{"cmd":"fan","yes":true,"no":false,"nothing":null,"one":1}"#)
        XCTAssertFalse(try a.flag("missing"))
        XCTAssertFalse(try a.flag("nothing"))
        XCTAssertTrue(try a.flag("yes"))
        XCTAssertFalse(try a.flag("no"))
        assertError(try a.flag("one"), code: "param-one")
        XCTAssertTrue(try a.flag("missing", default: true))
        XCTAssertFalse(try a.flag("no", default: true))
        assertError(try a.flag("one", default: true), code: "param-one")
    }

    func testPathAndObject() throws {
        assertError(try args(#"{"cmd":"exportBackup"}"#).path(), code: "path-missing")
        assertError(try args(#"{"cmd":"exportBackup","path":"  "}"#).path(), code: "path-missing")
        assertError(try args(#"{"cmd":"exportBackup","path":7}"#).path(), code: "path-missing")
        XCTAssertEqual(try args(#"{"cmd":"exportBackup","path":"/tmp/a.json"}"#).path().lastPathComponent, "a.json")

        let data = try args(#"{"cmd":"appearance","value":{"glow":0.5,"lively":true,"theme":"neon"}}"#).object("value")
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(back["theme"] as? String, "neon")
        XCTAssertEqual((back["glow"] as? NSNumber)?.doubleValue, 0.5)
        assertError(try args(#"{"cmd":"appearance","value":[1,2]}"#).object("value"), code: "param-value")
        assertError(try args(#"{"cmd":"appearance","value":true}"#).object("value"), code: "param-value")
    }

    func testUnreadableCommandText() {
        XCTAssertNil(CommandArgs(json: "kein JSON"))
        XCTAssertNil(CommandArgs(json: "[1,2]"))
        XCTAssertNil(CommandArgs(json: #"{"value":1}"#))
        XCTAssertNil(CommandArgs(json: #"{"cmd":5}"#))
        XCTAssertEqual(CommandArgs(json: #"{"cmd":"refresh"}"#)?.cmd, "refresh")
    }

    // MARK: - handleCommand

    func testHandleCommandWithoutCoreOrReadableText() throws {
        XCTAssertTrue(handleCommand(#"{"cmd":"refresh"}"#, on: nil)?.hasSuffix("(core-not-started)") == true)
        let c = try makeController(configured: false)
        XCTAssertTrue(handleCommand(nil, on: c)?.hasSuffix("(bad-command)") == true)
        XCTAssertTrue(handleCommand("{", on: c)?.hasSuffix("(bad-command)") == true)
        XCTAssertTrue(handleCommand(#"{"cmd":"gibtsNicht"}"#, on: c)?.hasSuffix("(unknown-command)") == true)
    }

    func testDeviceCommandsNeedAConfiguredDevice() throws {
        let c = try makeController(configured: false)
        let expected: Set<String> = [
            "refresh", "power", "mode", "fan", "fanQuiet", "fanTurbo", "nudgeTemp", "temp", "freezeProtection", "swing",
            "eco", "turbo", "purifier", "outdoorSilent", "selfClean", "ieco", "sleep", "display", "rate", "sound", "applyScene",
            "saveScene", "offTimer", "onTimer", "exportBackup", "relocate",
        ]
        XCTAssertEqual(Set(bridgeCommands.values.filter(\.needsDevice).map(\.name)), expected)
        for name in expected.sorted() {
            let reply = handleCommand(#"{"cmd":"\#(name)"}"#, on: c)
            XCTAssertTrue(reply?.hasSuffix("(no-device)") == true, "\(name): \(reply ?? "angenommen")")
        }
    }

    func testWrongTypesAreRejectedBeforeAnythingHappens() throws {
        let c = try makeController(configured: true)
        let target = c.state?.targetTemperature
        XCTAssertTrue(handleCommand(#"{"cmd":"temp","value":true}"#, on: c)?.hasSuffix("(param-value)") == true)
        XCTAssertEqual(c.state?.targetTemperature, target)
        XCTAssertTrue(handleCommand(#"{"cmd":"power","on":1}"#, on: c)?.hasSuffix("(param-on)") == true)
        XCTAssertTrue(handleCommand(#"{"cmd":"fan","value":50,"now":1}"#, on: c)?.hasSuffix("(param-now)") == true)

        let seconds = c.refreshSeconds
        XCTAssertTrue(handleCommand(#"{"cmd":"refreshSeconds","value":true}"#, on: c)?.hasSuffix("(param-value)") == true)
        XCTAssertEqual(c.refreshSeconds, seconds)
        let csv = c.historyCSV
        XCTAssertTrue(handleCommand(#"{"cmd":"historyCSV","on":1}"#, on: c)?.hasSuffix("(param-on)") == true)
        XCTAssertEqual(c.historyCSV, csv)
        XCTAssertTrue(handleCommand(#"{"cmd":"uiVisible","id":"main","visible":0}"#, on: c)?.hasSuffix("(param-visible)") == true)
    }

    func testCommandNamesAreUnique() {
        let all = bridgeCommandGroups.flatMap(\.commands).map(\.name)
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertEqual(bridgeCommands.count, all.count)
    }

    // MARK: - Meldungen

    func testMessagesKeepTheirFormat() {
        XCTAssertEqual(bridgeMessage(for: CocoaError(.fileNoSuchFile)),
                       "Die Datei wurde nicht gefunden. Bitte Ort und Namen prüfen. (file-4)")
        XCTAssertEqual(bridgeMessage(for: CommandError("Etwas ging schief. Bitte neu. (x-1)")),
                       "Etwas ging schief. Bitte neu. (x-1)")
        XCTAssertEqual(parsedMessage("Etwas ging schief. (x-1)").code, "x-1")
        XCTAssertNil(parsedMessage("Ohne Code (mit Leerzeichen)").code)
        XCTAssertEqual(parsedMessage("Ohne Code (mit Leerzeichen)").text, "Ohne Code (mit Leerzeichen)")
    }

    func testExportHistoryMessageIsNotNested() {
        XCTAssertEqual(exportHistoryMessage(for: CocoaError(.fileWriteNoPermission)),
                       "Der Verlauf ließ sich nicht speichern. Bitte einen anderen Ordner wählen. (file-513)")
        XCTAssertEqual(exportHistoryMessage(for: CocoaError(.fileWriteUnknown)),
                       "Der Verlauf ließ sich nicht speichern. Bitte einen anderen Ort wählen. (file-512)")
        let text = exportHistoryMessage(for: CommandError("Ohne Code"))
        XCTAssertEqual(text, "Der Verlauf ließ sich nicht speichern. Bitte einen anderen Ort wählen. (export-failed)")
    }

    func testExportHistoryStartReportsOneFlatMessage() async throws {
        let c = try makeController(configured: false)
        let target = dir.appendingPathComponent("fehlt/noch/verlauf.csv")
        let before = results.exportHistory.seq
        let json = #"{"cmd":"exportHistoryStart","path":"\#(target.path)"}"#
        XCTAssertNil(handleCommand(json, on: c))
        let deadline = Date().addingTimeInterval(10)
        while results.exportHistory.seq == before, Date() < deadline { await Task.yield() }
        let text = try XCTUnwrap(results.exportHistory.result)
        XCTAssertTrue(text.hasPrefix("Der Verlauf ließ sich nicht speichern."), text)
        XCTAssertEqual(text.components(separatedBy: "(").count, 2, "genau ein Code in Klammern: \(text)")
        XCTAssertTrue(text.hasSuffix(")"), text)
    }

    // MARK: - Abgleich mit der Windows-Oberfläche

    static let trayFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../windows/KlimacontrolTray").standardizedFileURL

    /// Erste Gruppe aller Treffer; Kommentarzeilen (`//`, `///`) zählen nicht.
    private static func matches(_ pattern: String, in source: String) throws -> Set<String> {
        let text = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// `Cmd` in BridgeCommands.cs muss genau die Befehle der Bridge nennen. Gibt es die Datei (noch) nicht, prüft der
    /// Test nur, dass jeder in `Send("…")`/`Toggle("…")` genannte Befehl in der Bridge steht.
    func testWindowsCommandNamesMatchTheBridge() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.trayFolder.path) else { throw XCTSkip("windows/KlimacontrolTray fehlt") }
        let known = Set(bridgeCommands.keys)

        var used: Set<String> = []
        for name in try fm.contentsOfDirectory(atPath: Self.trayFolder.path) where name.hasSuffix(".cs") {
            let text = try String(contentsOf: Self.trayFolder.appendingPathComponent(name), encoding: .utf8)
            used.formUnion(try Self.matches(#"\b(?:Send|Toggle)\(\s*"([A-Za-z]+)""#, in: text))
        }
        let catalog = Self.trayFolder.appendingPathComponent("BridgeCommands.cs")
        var named: Set<String>?
        if fm.fileExists(atPath: catalog.path) {
            let text = try String(contentsOf: catalog, encoding: .utf8)
            named = try Self.matches(#"const\s+string\s+\w+\s*=\s*"([^"]*)"\s*;"#, in: text)
            used.formUnion(named ?? [])
        }

        XCTAssertEqual(used.subtracting(known).sorted(), [],
                       "Von der Windows-Oberfläche benutzt, in der Befehlstabelle der Bridge (BridgeCommands.swift) nicht")
        if let named {
            XCTAssertEqual(known.subtracting(named).sorted(), [],
                           "In der Bridge, aber nicht in `Cmd` (windows/KlimacontrolTray/BridgeCommands.cs)")
        }
    }
}
