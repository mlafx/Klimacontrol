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

/// Anzeigetexte und Auswahllisten im Schnappschuss (BridgeDisplay.swift): kommen aus dem Kern, additiv zum Vertrag.
@MainActor
final class BridgeDisplayTests: XCTestCase {
    private var dir: URL!
    private var controller: ACController!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-\(UUID().uuidString)")
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
        try? FileManager.default.removeItem(at: dir)
    }

    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotJSON(controller).utf8)) as? [String: Any])
    }

    func testOptionsComeFromTheCore() throws {
        let o = try XCTUnwrap(json()["options"] as? [String: Any])
        let refresh = try XCTUnwrap(o["refresh"] as? [String: Any])
        XCTAssertEqual((refresh["choices"] as? [[String: Any]])?.compactMap { $0["seconds"] as? Int }, [5, 10, 30, 60, 300])
        XCTAssertEqual(refresh["customHelp"] as? String, "1 bis 600 Sekunden.")
        XCTAssertEqual((o["temperature"] as? [String: Any])?["min"] as? Int, 16)
        XCTAssertEqual((o["rate"] as? [String: Any])?["choices"] as? [Int], [100, 75, 50])
        XCTAssertEqual((o["offTimerChoices"] as? [[String: Any]])?.count, 7)
        XCTAssertEqual(((o["fan"] as? [String: Any])?["marks"] as? [[String: Any]])?.count, 6)
        XCTAssertEqual((o["credentials"] as? [String: Any])?["tokenLength"] as? Int, 128)
        let modes = try XCTUnwrap(o["connectionModes"] as? [[String: Any]])
        XCTAssertEqual(modes.compactMap { $0["id"] as? String }, ["auto", "lan", "cloud"])
        XCTAssertEqual(modes.first?["help"] as? String, "Erst WLAN, dann über das Midea-Konto – empfohlen.")
        let prompts = try XCTUnwrap(o["prompts"] as? [String: Any])
        XCTAssertEqual((prompts["selfClean"] as? [String: Any])?["confirm"] as? String, "Starten")
        let forget = try XCTUnwrap(prompts["forgetNeedsBackup"] as? [String: Any])
        XCTAssertEqual(forget["backup"] as? String, "Erst sichern …")
        XCTAssertTrue((forget["message"] as? String)?.contains("im Datenordner beiseitegelegt") ?? false, "Windows-Wortlaut")
        XCTAssertEqual((prompts["cloudNeedsAccount"] as? [String: Any])?["title"] as? String, "Midea-Konto fehlt")
        let folder = try XCTUnwrap(o["cloudFolder"] as? [String: Any])
        XCTAssertTrue((folder["messageTemplate"] as? String)?.contains("{folder}") ?? false)
        XCTAssertNil(o["accountLoginSwitchesLanToAuto"])
    }

    func testAvailabilityFollowsTheMode() throws {
        var s = ACState()
        s.power = true
        s.mode = .heat
        controller.state = s
        var a = try XCTUnwrap(json()["availability"] as? [String: [String: Any]])
        XCTAssertEqual(Set(a.keys), Set(UIOptions.ComfortFeature.allCases.map(\.rawValue) + ["fan", "target"]))
        XCTAssertEqual(a["fan"]?["enabled"] as? Bool, true)
        XCTAssertEqual(a["target"]?["enabled"] as? Bool, true)
        XCTAssertEqual(a["eco"]?["enabled"] as? Bool, false)
        XCTAssertEqual(a["eco"]?["why"] as? String, "Eco gibt es nur beim Kühlen")
        XCTAssertEqual(a["freezeProtection"]?["enabled"] as? Bool, true)
        s.mode = .cool
        controller.state = s
        a = try XCTUnwrap(json()["availability"] as? [String: [String: Any]])
        XCTAssertEqual(a["eco"]?["enabled"] as? Bool, true)
        XCTAssertEqual(a["freezeProtection"]?["enabled"] as? Bool, false)
        s.mode = .dry
        controller.state = s
        a = try XCTUnwrap(json()["availability"] as? [String: [String: Any]])
        XCTAssertEqual(a["fan"]?["enabled"] as? Bool, false)
        XCTAssertEqual(a["fan"]?["why"] as? String, UIOptions.fanLockedText)
        s.mode = .fan
        controller.state = s
        a = try XCTUnwrap(json()["availability"] as? [String: [String: Any]])
        XCTAssertEqual(a["target"]?["enabled"] as? Bool, false)
    }

    func testDisplayTexts() throws {
        var s = ACState()
        s.power = true
        s.mode = .cool
        s.targetTemperature = 24
        s.indoorTemperature = 25.5
        controller.state = s
        controller.showNotice(UserMessage(what: "Anlage offline.", todo: "Später.", code: "3123"))
        let j = try json()
        XCTAssertEqual(j["heroValue"] as? String, "24°")
        XCTAssertEqual(j["heroCaption"] as? String, "Kühlt · noch 1,5° bis zum Ziel")
        XCTAssertEqual(j["menuTitle"] as? String, "24°")
        XCTAssertEqual(j["connectionTooltip"] as? String, "net_ac_1A2B · 192.168.1.40:6444 · lokal")
        XCTAssertEqual(j["uiConnectionState"] as? String, "live", "Zustand da, kein Fehler")
        XCTAssertEqual(j["appearanceIsStandard"] as? Bool, true)
        XCTAssertEqual(j["notice"] as? String, "Anlage offline. Später. (3123)")
        let detail = try XCTUnwrap(j["noticeDetail"] as? [String: Any])
        XCTAssertEqual(detail["code"] as? String, "3123")
        XCTAssertEqual(detail["what"] as? String, "Anlage offline.")
        XCTAssertEqual((j["costLine"] as? [String: Any])?["title"] as? String, "Kosten heute")
        XCTAssertEqual(j["errorCodeValue"] as? String, "keiner")
        XCTAssertEqual(j["filterValue"] as? String, "in Ordnung")
        XCTAssertTrue((j["accountFooter"] as? String)?.contains("Windows-Anmeldeinformationsverwaltung") ?? false)
        XCTAssertEqual(j["forgetNeedsBackup"] as? Bool, true, "WLAN-Zugangsdaten noch nicht gesichert")
        XCTAssertNil(j["quitPrompt"], "ohne Timer keine Rückfrage")
        controller.offAt = Date().addingTimeInterval(3600)
        XCTAssertEqual((try json()["quitPrompt"] as? [String: Any])?["title"] as? String, "Klimacontrol beenden?")
    }

    func testWindowRulesComeFromMainWindowLayout() throws {
        let o = try XCTUnwrap(json()["options"] as? [String: Any])
        let w = try XCTUnwrap(o["window"] as? [String: Any])
        let widths: [String: Double] = [
            "controlWidth": MainWindowLayout.controlWidth, "historyMin": MainWindowLayout.historyMin,
            "historyBalanced": MainWindowLayout.historyBalanced, "historyGridFrom": MainWindowLayout.historyGridFrom,
            "diagnosticsMin": MainWindowLayout.diagnosticsMin, "diagnosticsMax": MainWindowLayout.diagnosticsMax,
            "controlsOnlyMaxWidth": MainWindowLayout.controlsOnlyMaxWidth,
            "historyBaseHeight": MainWindowLayout.historyBaseHeight, "singleOverhead": MainWindowLayout.singleOverhead,
            "gridOverhead": MainWindowLayout.gridOverhead, "gridRowMax": MainWindowLayout.gridRowMax,
            "chartStep": MainWindowLayout.chartStep, "energyBarMaxWidth": MainWindowLayout.energyBarMaxWidth,
        ]
        for (key, value) in widths {
            XCTAssertEqual((w[key] as? NSNumber)?.doubleValue, value, key)
        }
        let heights = try XCTUnwrap(w["minimumHeight"] as? [String: Double])
        XCTAssertEqual(heights, ["compact": 470, "normal": 520, "large": 600])
        XCTAssertEqual(w["chartMin"] as? [String: Double], ["power": 120, "temperature": 150, "outdoor": 80, "energy": 150])
        XCTAssertEqual(w["chartMax"] as? [String: Double], ["power": 260, "temperature": 340, "outdoor": 180, "energy": 240])
        XCTAssertEqual(w["gridChartMin"] as? [String: Double], ["power": 180, "temperature": 180, "outdoor": 150, "energy": 150])
        // Gegenprobe: Mehr Platz als die Höchsthöhen ändert nichts mehr.
        let huge = MainWindowLayout.chartHeights(columnHeight: 10_000)
        XCTAssertEqual(w["chartMax"] as? [String: Double],
                       ["power": huge.power, "temperature": huge.temperature, "outdoor": huge.outdoor, "energy": huge.energy])
    }

    /// Die Bridge nennt die Lückenregel als Faktor und Mindestwert; beides muss `UIOptions.chartGapThreshold` ergeben.
    func testChartGapRuleMatchesTheCore() throws {
        let chart = try XCTUnwrap((json()["options"] as? [String: Any])?["chart"] as? [String: Any])
        let factor = try XCTUnwrap((chart["gapFactor"] as? NSNumber)?.doubleValue)
        let minimum = try XCTUnwrap((chart["gapMinSeconds"] as? NSNumber)?.doubleValue)
        let windows = try XCTUnwrap((chart["windowCount"] as? NSNumber)?.doubleValue)
        let ranges: [Double] = UIOptions.chartRanges.map(\.seconds) + [0, 60, 30 * 86400, 365 * 86400]
        for range in ranges {
            XCTAssertEqual(max(minimum, factor * max(1, range / windows)), UIOptions.chartGapThreshold(range: range),
                           accuracy: 1e-9, "Zeitraum \(range) s")
        }
    }

    func testDetailedLogFieldsFollowTheCore() throws {
        let before = AppLog.debugEnabled
        defer { AppLog.debugEnabled = before }
        controller.setDetailedLog(false)
        var j = try json()
        XCTAssertEqual(j["debugLog"] as? Bool, false)
        XCTAssertTrue(j["debugLogNotice"] == nil || j["debugLogNotice"] is NSNull)
        try runCommand(try XCTUnwrap(CommandArgs(json: #"{"cmd":"debugLog","on":true}"#)), controller)
        j = try json()
        XCTAssertEqual(j["debugLog"] as? Bool, true)
        XCTAssertEqual(j["debugLogNotice"] as? String, "Ausführliches Protokoll aktiv")
    }

    func testHistoryUnavailableFollowsTheDatabase() throws {
        XCTAssertEqual(try json()["historyUnavailable"] as? Bool, false)

        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blocked) }
        // Ein Ordner an der Stelle der Datenbank lässt sich nicht öffnen (und wird nicht als kaputte Datei beiseitegelegt).
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("verlauf.sqlite"),
                                                withIntermediateDirectories: true)
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        let c = ACController(appVersion: "test", settings: NoSettings(), paths: CorePaths(directory: blocked),
                             platform: NoPlatform(), accounts: accounts,
                             makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
        defer { c.stop() }
        XCTAssertFalse(c.history.db.isOpen)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotJSON(c).utf8)) as? [String: Any])
        XCTAssertEqual(j["historyUnavailable"] as? Bool, true)
    }

    func testSnapshotStaysStable() throws {
        XCTAssertEqual(snapshotJSON(controller), snapshotJSON(controller), "feste Schlüsselreihenfolge, keine zufälligen Werte")
    }

    func testAppearanceIsStandardFollowsTheCore() throws {
        var a = controller.appearance
        a.glow = 0.5
        controller.setAppearance(a)
        XCTAssertEqual(try json()["appearanceIsStandard"] as? Bool, false)
        XCTAssertEqual(try json()["appearanceCustomized"] as? Bool, true)
        controller.resetAppearance()
        XCTAssertEqual(try json()["appearanceIsStandard"] as? Bool, true)
        XCTAssertEqual(try json()["appearanceCustomized"] as? Bool, false)
    }

    func testImportResultCarriesTextAndPrompt() throws {
        let r = ImportResultDTO(ok: false, verified: nil, scenesImported: 0, scenesSkipped: 0, error: "x", errorCode: "otherDevice",
                                text: UIText.backupImportFailed(BackupImportError.rejected).text,
                                prompt: PromptDTO(UIText.otherDevicePrompt(backup: "A", current: "B")))
        let data = try JSONEncoder().encode(r)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((o["prompt"] as? [String: Any])?["title"] as? String, "Andere Anlage einrichten?")
        XCTAssertEqual(o["text"] as? String, BackupImportError.rejected.errorDescription)
    }
}
