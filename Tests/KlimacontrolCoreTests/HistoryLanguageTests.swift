import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Lesbare CSV-Form in Deutsch und Englisch: Kopfzeile, Modus und Dezimalzeichen folgen App-Sprache und Format,
/// Datenbank und technische Form bleiben deutsch bzw. unverändert; der Import liest beide Sprachen.
final class HistoryLanguageTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-histlang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Localizer.resetForTesting()
        FormatProfile.setCurrent(.germany)
    }

    static let englishHeader = "Time (local time);Power on (1/0);Mode;Target (°C);Indoor (°C);Outdoor (°C);Fan (%);"
        + "Eco (1/0);Turbo (1/0);Quiet outdoor (1/0);Power (W);Meter total (kWh);Compressor (Hz);"
        + "Compressor target (Hz);Current (A);Voltage (V);Compressor (W);T1 indoor air (°C);T2 indoor coil (°C);"
        + "T3 outdoor coil (°C);T4 outdoor air (°C);Tp discharge (°C);Expansion valve (steps);"
        + "Indoor fan (rpm);Outdoor fan (rpm);Condensate pump (1/0);Defrost (1/0);Meter raw\n"

    private func makeDB(_ name: String = "verlauf.sqlite") -> HistoryDB { HistoryDB(url: dir.appendingPathComponent(name)) }

    private func filled(_ db: HistoryDB) -> Date {
        let t = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 600).rounded(.down))
        let (s, d) = HistoryTests.fullRow()
        db.insert(time: t, fields: HistoryLog.fields(state: s, diagnostics: d, time: t))
        return t
    }

    private func export(_ db: HistoryDB, readable: Bool, name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try db.exportCSV(to: url, from: nil, until: nil, readable: readable)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEnglishHeaderLiteral() {
        Localizer.withLanguage(.en) {
            XCTAssertEqual(HistoryLog.readableHeader, Self.englishHeader)
            XCTAssertEqual(HistoryLog.header, HistoryTests.technicalHeader)
        }
        XCTAssertEqual(HistoryLog.readableHeader, HistoryTests.readableHeader)
    }

    func testEnglishNamesHaveNoGermanText() {
        let names = HistoryColumn.all.map { $0.readableName(in: .en) }
        for n in names {
            XCTAssertNil(n.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüÄÖÜß„“")), n)
            for word in ["der", "die", "das", "und", "nicht", "Anlage"] {
                XCTAssertFalse(n.lowercased().split(separator: " ").contains(Substring(word.lowercased())), n)
            }
        }
        XCTAssertEqual(Set(names).count, names.count, "Spaltennamen eindeutig")
    }

    func testEnglishExportWithUSFormat() throws {
        let db = makeDB()
        let t = filled(db)
        let text = try Localizer.withLanguage(.en) {
            try FormatProfile.withProfile(.unitedStates) { try export(db, readable: true, name: "en-us.csv") }
        }
        let expected = "1;Heat;21.5;19;-3.5;60;0;1;;640;1234.56;45;50;3;230;600;21.5;30.25;-1;-3.5;70;300;900;800;0;;123456"
        XCTAssertEqual(text, Self.englishHeader + HistoryLog.readableTime(t) + ";" + expected + "\n")
    }

    func testEnglishExportWithGermanFormatUsesComma() throws {
        let db = makeDB()
        _ = filled(db)
        let text = try Localizer.withLanguage(.en) {
            try FormatProfile.withProfile(.germany) { try export(db, readable: true, name: "en-de.csv") }
        }
        let row = text.split(separator: "\n")[1].split(separator: ";", omittingEmptySubsequences: false)
        XCTAssertEqual(row[1], "1")
        XCTAssertEqual(row[2], "Heat")
        XCTAssertEqual(row[3], "21,5")
        XCTAssertEqual(row[11], "1234,56")
    }

    func testGermanExportWithUSFormatUsesPoint() throws {
        let db = makeDB()
        _ = filled(db)
        let text = try FormatProfile.withProfile(.unitedStates) { try export(db, readable: true, name: "de-us.csv") }
        let row = text.split(separator: "\n")[1].split(separator: ";", omittingEmptySubsequences: false)
        XCTAssertEqual(row[2], "Heizen")
        XCTAssertEqual(row[3], "21.5")
    }

    func testUnusableDecimalSeparatorFallsBackToComma() {
        var odd = FormatProfile.unitedStates
        odd.decimalSeparator = ";"
        XCTAssertEqual(HistoryColumn.ReadableStyle(profile: odd).decimal, ",")
        odd.decimalSeparator = "ab"
        XCTAssertEqual(HistoryColumn.ReadableStyle(profile: odd).decimal, ",")
    }

    func testEnglishRoundTripKeepsGermanDatabase() throws {
        let db = makeDB()
        _ = filled(db)
        let technical = try export(db, readable: false, name: "technisch.csv")
        let english = try Localizer.withLanguage(.en) {
            try FormatProfile.withProfile(.unitedStates) { try export(db, readable: true, name: "en.csv") }
        }
        XCTAssertTrue(english.contains(";Heat;"))
        let copy = makeDB("kopie.sqlite")
        copy.importCSVOnce(from: [dir.appendingPathComponent("en.csv")])
        XCTAssertEqual(try export(copy, readable: false, name: "zurueck.csv"), technical)
        XCTAssertTrue(technical.contains(";Heizen;"))
    }

    func testOldGermanReadableFileImportsUnderEnglish() throws {
        let db = makeDB()
        _ = filled(db)
        let technical = try export(db, readable: false, name: "technisch.csv")
        let german = try export(db, readable: true, name: "de.csv")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("de.csv"), encoding: .utf8), german)
        let copy = makeDB("kopie.sqlite")
        Localizer.withLanguage(.en) { copy.importCSVOnce(from: [dir.appendingPathComponent("de.csv")]) }
        XCTAssertEqual(try export(copy, readable: false, name: "zurueck.csv"), technical)
    }

    func testMixedHeaderAndModeLanguagesImport() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let head = "Zeit (Ortszeit);Mode;Target (°C)\n"
        let body = HistoryLog.readableTime(t) + ";Cool;21,5\n"
        let url = dir.appendingPathComponent("misch.csv")
        try (head + body).write(to: url, atomically: true, encoding: .utf8)
        let db = makeDB()
        db.importCSVOnce(from: [url])
        let text = try export(db, readable: false, name: "technisch.csv")
        XCTAssertTrue(text.contains(";Kühlen;21.5;"), text)
    }

    func testTechnicalFormUnchangedUnderEnglish() throws {
        let db = makeDB()
        _ = filled(db)
        let german = try export(db, readable: false, name: "a.csv")
        let english = try Localizer.withLanguage(.en) {
            try FormatProfile.withProfile(.unitedStates) { try export(db, readable: false, name: "b.csv") }
        }
        XCTAssertEqual(german, english)
    }
}
