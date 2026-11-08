import Foundation
import XCTest

/// Startet den Python-Selbsttest des Release-Skripts (nachgebildetes sign_update, nur Temp-Ordner, kein Netz).
final class ReleaseScriptTests: XCTestCase {
    func testMakeReleaseSelfTest() throws {
        #if os(macOS)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["python3", "--version"]
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        do { try probe.run(); probe.waitUntilExit() } catch { throw XCTSkip("python3 nicht verfügbar") }
        if probe.terminationStatus != 0 { throw XCTSkip("python3 nicht verfügbar") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "tools/test_make_release.py"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var output = Data()
        let reader = DispatchQueue(label: "release-script-test.read")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            reader.sync { output.append(chunk) }
        }
        try process.run()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            XCTFail("tools/test_make_release.py: Zeitlimit von 120 s überschritten")
            return
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = reader.sync { String(decoding: output + rest, as: UTF8.self) }
        XCTAssertEqual(process.terminationStatus, 0, "tools/test_make_release.py fehlgeschlagen:\n\(text)")
        #else
        throw XCTSkip("Python-Selbsttest läuft nur am Mac")
        #endif
    }
}
