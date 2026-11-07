import Foundation
import XCTest

/// Regeln für die Bauskripte, die sonst erst auf dem anderen Rechner auffallen (AGENTS.md 10, 12).
final class ToolsTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Windows PowerShell 5.1 liest UTF-8 ohne BOM als ANSI: Umlaute zerbrächen das Skript.
    func testWindowsBuildScriptIsPureASCII() throws {
        let script = try text("tools/build_windows.ps1")
        let bad = script.unicodeScalars.filter { !$0.isASCII }
        XCTAssertTrue(bad.isEmpty, "Nicht-ASCII in build_windows.ps1: \(String(String.UnicodeScalarView(bad.prefix(10))))")
    }

    /// CRLF macht die zsh-Skripte unbrauchbar.
    func testShellScriptsUseLF() throws {
        for path in ["tools/build_app.sh", "tools/test.sh", "tools/make_dmg.sh"] {
            XCTAssertFalse(try text(path).contains("\r\n"), "\(path) hat CRLF")
        }
    }

    /// Hintergrundbild und dmgbuild-Einstellungen müssen dieselben Maße und Symbolpositionen nennen.
    func testDMGLayoutMatchesBackground() throws {
        let background = try text("tools/make_dmg_background.swift")
        let settings = try text("tools/dmg_settings.py")
        XCTAssertTrue(background.contains("CGSize(width: 640, height: 380)"))
        XCTAssertTrue(background.contains("size.height - 210"))
        XCTAssertTrue(settings.contains("window_rect = ((200, 120), (640, 380))"))
        XCTAssertTrue(settings.contains("\"Klimacontrol.app\": (160, 210)"))
        XCTAssertTrue(settings.contains("\"Programme\": (480, 210)"))
    }

    /// `--beta` und `--out` gibt es; aufgeräumt werden nur Pakete derselben Version, nie alle Versionen.
    func testBuildScriptOptions() throws {
        let script = try text("tools/build_app.sh")
        XCTAssertTrue(script.contains("--beta)") && script.contains("--out)"))
        XCTAssertTrue(script.contains("rm -f \"$OUT/$ZIPNAME.zip\""))
        XCTAssertTrue(script.contains("rm -f \"$OUT/$DMGNAME.dmg\""))
        XCTAssertTrue(script.contains("DMGNAME=\"Klimacontrol-$VERSION_SHOWN-mac\""))
        XCTAssertFalse(script.contains("Klimacontrol-*-mac"), "keine Wildcard über alle Versionen")
    }
}
