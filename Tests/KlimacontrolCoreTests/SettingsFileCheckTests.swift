import XCTest
import Foundation
@testable import KlimacontrolCore

final class SettingsFileCheckTests: CoreTestCase {
    /// 2026-11-11 08:05:09 UTC
    let now = Date(timeIntervalSince1970: 1_794_384_309)
    let stamp = "2026-11-11T080509Z"

    var file: URL { dir.appendingPathComponent("Klimacontrol.exe.plist") }

    func write(_ data: Data) throws { try data.write(to: file) }

    func plist(_ value: Any, _ format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    var sample: [String: Any] { ["refreshSeconds": 10, "displayName": "Test", "beep": true, "pricePerKWh": 0.3] }

    func dirContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func assertUnchanged(_ data: Data, _ outcome: SettingsFileCheck.Outcome, file f: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(outcome, .valid, file: f, line: line)
        XCTAssertEqual(try Data(contentsOf: file), data, file: f, line: line)
        XCTAssertEqual(try dirContents(), ["Klimacontrol.exe.plist"], file: f, line: line)
    }

    func assertMovedAside(_ original: Data, _ outcome: SettingsFileCheck.Outcome, file f: StaticString = #filePath, line: UInt = #line) throws {
        let name = "Klimacontrol.exe.plist.defekt-\(stamp)"
        XCTAssertEqual(outcome, .movedAside(fileName: name), file: f, line: line)
        XCTAssertEqual(outcome.asideFileName, name, file: f, line: line)
        XCTAssertTrue(outcome.settingsWereReset, file: f, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file: f, line: line)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), original, file: f, line: line)
    }

    // MARK: nichts zu tun

    func testMissingFile() throws {
        XCTAssertEqual(SettingsFileCheck.run(fileAt: file, now: now), .missing)
        XCTAssertEqual(try dirContents(), [])
    }

    func testEmptyFile() throws {
        try write(Data())
        let outcome = SettingsFileCheck.run(fileAt: file, now: now)
        XCTAssertEqual(outcome, .empty)
        XCTAssertFalse(outcome.settingsWereReset)
        XCTAssertEqual(try dirContents(), ["Klimacontrol.exe.plist"])
    }

    func testValidXMLPlistStaysByteIdentical() throws {
        let data = try plist(sample, .xml)
        try write(data)
        try assertUnchanged(data, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testValidBinaryPlistStaysByteIdentical() throws {
        let data = try plist(sample, .binary)
        XCTAssertEqual(data.prefix(6), Data("bplist".utf8))
        try write(data)
        try assertUnchanged(data, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testEmptyDictionaryIsValid() throws {
        let data = try plist([String: Any](), .xml)
        try write(data)
        try assertUnchanged(data, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testCheckDoesNotTouchModificationDate() throws {
        let data = try plist(sample, .xml)
        try write(data)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        _ = SettingsFileCheck.run(fileAt: file, now: now)
        let mod = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(mod, past)
    }

    // MARK: defekt

    func testTruncatedXMLIsMovedAside() throws {
        let full = try plist(sample, .xml)
        let cut = full.prefix(full.count / 2)
        try write(cut)
        try assertMovedAside(cut, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testTruncatedBinaryIsMovedAside() throws {
        let full = try plist(sample, .binary)
        let cut = full.prefix(full.count - 10)
        try write(cut)
        try assertMovedAside(cut, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testGarbageIsMovedAside() throws {
        let junk = Data([0x00, 0xFF, 0x13, 0x37, 0x42, 0x00, 0x00, 0x9C] + Array("<<< kein plist >>>".utf8))
        try write(junk)
        try assertMovedAside(junk, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testZeroBytesOfSameLengthAreMovedAside() throws {
        let zeros = Data(count: 4096)
        try write(zeros)
        try assertMovedAside(zeros, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testArrayInsteadOfDictionaryIsMovedAside() throws {
        let data = try plist(["a", "b"], .xml)
        try write(data)
        try assertMovedAside(data, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testScalarPlistIsMovedAside() throws {
        let data = try plist("nur ein Text", .binary)
        try write(data)
        try assertMovedAside(data, SettingsFileCheck.run(fileAt: file, now: now))
    }

    func testAsideNameIsUniqueWithinTheSameSecond() throws {
        try write(Data("kaputt".utf8))
        XCTAssertEqual(SettingsFileCheck.run(fileAt: file, now: now).asideFileName, "Klimacontrol.exe.plist.defekt-\(stamp)")
        try write(Data("wieder kaputt".utf8))
        XCTAssertEqual(SettingsFileCheck.run(fileAt: file, now: now).asideFileName, "Klimacontrol.exe.plist.defekt-\(stamp)-2")
        XCTAssertEqual(try dirContents(), ["Klimacontrol.exe.plist.defekt-\(stamp)", "Klimacontrol.exe.plist.defekt-\(stamp)-2"])
    }

    func testAsideFailedDoesNotCrashAndIsDistinguishable() throws {
        #if os(Windows)
        throw XCTSkip("Schreibschutz über POSIX-Rechte gibt es nur auf Darwin/Linux")
        #else
        try write(Data("kaputt".utf8))
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let outcome = SettingsFileCheck.run(fileAt: file, now: now)
        guard case .asideFailed = outcome else { return XCTFail("erwartet asideFailed, war \(outcome)") }
        XCTAssertNil(outcome.asideFileName)
        XCTAssertTrue(outcome.settingsWereReset)
        XCTAssertEqual(try Data(contentsOf: file), Data("kaputt".utf8))
        #endif
    }

    // MARK: Pfad unter Windows

    func testWindowsSettingsURL() {
        let url = SettingsFileCheck.windowsSettingsURL(localAppData: "/tmp/Local",
                                                       executablePath: #"C:\Programme\Klimacontrol\Klimacontrol.exe"#)
        XCTAssertEqual(url.lastPathComponent, "Klimacontrol.exe.plist")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Local")
        XCTAssertEqual(SettingsFileCheck.windowsSettingsURL(localAppData: "/tmp", executablePath: "Klimacontrol.exe").lastPathComponent,
                       "Klimacontrol.exe.plist")
    }

    // MARK: Hinweis im Kern

    @MainActor
    func testReportShowsPersistentNotice() async throws {
        let c = makeController()
        c.noticeSeconds = 0.05
        c.reportSettingsFileCheck(.movedAside(fileName: "Klimacontrol.exe.plist.defekt-\(stamp)"), fileName: "Klimacontrol.exe.plist")
        let expected = L.Message.settingsReset(file: "Klimacontrol.exe.plist.defekt-\(stamp)")
        XCTAssertEqual(c.notice, expected)
        XCTAssertTrue(c.notice?.hasSuffix("(settings-reset)") ?? false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.notice, expected, "Hinweis darf nicht von selbst verschwinden")
        c.clearNotice()
        XCTAssertNil(c.notice)
        c.stop()
    }

    @MainActor
    func testReportAsideFailedShowsLostNotice() {
        let c = makeController()
        c.reportSettingsFileCheck(.asideFailed(error: "gesperrt"), fileName: "Klimacontrol.exe.plist")
        XCTAssertEqual(c.notice, L.Message.settingsResetLost)
        c.stop()
    }

    @MainActor
    func testReportWithoutResetShowsNothing() {
        let c = makeController()
        for outcome in [SettingsFileCheck.Outcome.missing, .empty, .valid, .readFailed(error: "x")] {
            c.reportSettingsFileCheck(outcome, fileName: "Klimacontrol.exe.plist")
            XCTAssertNil(c.notice, "\(outcome)")
        }
        c.stop()
    }

    @MainActor
    func testNormalNoticeStillExpires() async throws {
        let c = makeController()
        c.noticeSeconds = 0.05
        c.showNotice(UserMessage(what: "Probe.", todo: ""))
        try await waitUntil { c.notice == nil }
        c.stop()
    }
}
