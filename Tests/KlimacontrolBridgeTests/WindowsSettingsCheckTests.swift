#if os(Windows)
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

@MainActor
final class WindowsSettingsCheckTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-plist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        WindowsSettingsCheck.reset()
    }

    override func tearDown() async throws {
        WindowsSettingsCheck.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    func testPathFollowsLocalAppDataAndExecutable() throws {
        let url = try XCTUnwrap(windowsSettingsFileURL())
        let folder = try XCTUnwrap(localAppDataFolder())
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path.lowercased(),
                       URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path.lowercased())
        let exe = try XCTUnwrap(executablePath())
        XCTAssertTrue(exe.lowercased().hasSuffix(".exe"))
        XCTAssertTrue(url.lastPathComponent.lowercased().hasSuffix(".exe.plist"))
    }

    func testTestProcessNeverTouchesRealFile() {
        XCTAssertTrue(TestEnvironment.isRunningTests)
        var asked = false
        WindowsSettingsCheck.runOnce(fileURL: { asked = true; return nil })
        XCTAssertFalse(asked)
        XCTAssertNil(WindowsSettingsCheck.pendingOutcome)
    }

    func testDamagedFileIsMovedAsideAndReportedOnce() throws {
        let file = dir.appendingPathComponent("Klimacontrol.exe.plist")
        try Data("kaputt".utf8).write(to: file)
        WindowsSettingsCheck.runOnce(fileURL: { file }, skip: false)
        guard case .movedAside(let aside)? = WindowsSettingsCheck.pendingOutcome else {
            return XCTFail("erwartet movedAside, war \(String(describing: WindowsSettingsCheck.pendingOutcome))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside)), Data("kaputt".utf8))

        // Zweiter Aufruf (kc_init nach kc_set_locale) prüft nicht erneut.
        try Data("wieder kaputt".utf8).write(to: file)
        WindowsSettingsCheck.runOnce(fileURL: { file }, skip: false)
        XCTAssertEqual(try Data(contentsOf: file), Data("wieder kaputt".utf8))

        let c = makeController()
        defer { c.stop() }
        WindowsSettingsCheck.report(to: c)
        XCTAssertNotNil(c.notice)
        c.clearNotice()
        WindowsSettingsCheck.report(to: c)
        XCTAssertNil(c.notice)
    }

    func testValidFileStaysUnchangedWithoutNotice() throws {
        let file = dir.appendingPathComponent("Klimacontrol.exe.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["refreshSeconds": 10],
                                                      format: .xml, options: 0)
        try data.write(to: file)
        WindowsSettingsCheck.runOnce(fileURL: { file }, skip: false)
        XCTAssertEqual(WindowsSettingsCheck.pendingOutcome, .valid)
        XCTAssertEqual(try Data(contentsOf: file), data)
        let c = makeController()
        defer { c.stop() }
        WindowsSettingsCheck.report(to: c)
        XCTAssertNil(c.notice)
    }

    private func makeController() -> ACController {
        let accounts = CloudAccountStore(load: { nil }, save: { _ in }, clear: {}, verify: { _, _ in })
        return ACController(appVersion: "test", settings: NoSettings(), paths: CorePaths(directory: dir),
                            platform: NoPlatform(), accounts: accounts,
                            makeDevice: { _, _, _ in throw MideaError.connectionFailed("Test") }, autostart: false)
    }
}
#endif
