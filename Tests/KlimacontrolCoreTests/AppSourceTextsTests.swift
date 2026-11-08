import Foundation
import XCTest

/// Die Mac-Oberfläche hält keine eigenen deutschen Texte: Alles Sichtbare kommt aus dem Katalog (`L.…`).
final class AppSourceTextsTests: XCTestCase {
    private static let badCharacters = CharacterSet(charactersIn: "äöüÄÖÜß„‚")
    private static let badWords: Set<String> = [
        "der", "die", "das", "und", "nicht", "ist", "mit", "für", "anlage", "einstellungen", "verlauf", "zugangsdaten",
        "sicherung", "fenster", "abbrechen", "schließen", "öffnen", "einschalten", "ausschalten",
    ]

    /// Begründete Ausnahmen als „Datei:Literal“. Leer: es gibt keine.
    private static let exceptions: Set<String> = []

    /// Alle Zeichenketten-Literale einer Zeile (auch in Interpolationen); Zeilenkommentare und Blockkommentare
    /// werden übersprungen. Mehrzeilige Literale (`"""`) gibt es in der App nicht.
    static func literals(in line: String) -> [String] {
        let chars = Array(line)
        var result: [String] = []
        var i = 0
        func scan(_ stopAtParen: Bool) {
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" { i = chars.count; return }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    if let end = line.range(of: "*/", range: line.index(line.startIndex, offsetBy: i + 2)..<line.endIndex) {
                        i = line.distance(from: line.startIndex, to: end.upperBound)
                        continue
                    }
                    i = chars.count
                    return
                }
                if stopAtParen {
                    if c == "(" { depth += 1 }
                    if c == ")" {
                        if depth == 0 { i += 1; return }
                        depth -= 1
                    }
                }
                if c == "\\" || c == "#" || c == "\"" {
                    var hashes = 0
                    var j = i
                    while j < chars.count, chars[j] == "#" { hashes += 1; j += 1 }
                    if j < chars.count, chars[j] == "\"" {
                        i = j + 1
                        result.append(literalBody(hashes: hashes))
                        continue
                    }
                }
                i += 1
            }
        }
        func literalBody(hashes: Int) -> String {
            var body = ""
            let closing = String(repeating: "#", count: hashes)
            while i < chars.count {
                let c = chars[i]
                if c == "\\" {
                    let marker = "\\" + closing
                    if hashes == 0 || String(chars[i..<min(chars.count, i + marker.count)]) == marker {
                        let after = i + marker.count
                        if after < chars.count, chars[after] == "(" {
                            i = after + 1
                            scan(true)
                            body += "\u{0}"
                            continue
                        }
                        body.append(chars[min(after, chars.count - 1)])
                        i = after + 1
                        continue
                    }
                }
                if c == "\"", String(chars[(i + 1)..<min(chars.count, i + 1 + hashes)]) == closing {
                    i += 1 + hashes
                    return body
                }
                body.append(c)
                i += 1
            }
            return body
        }
        scan(false)
        return result
    }

    static func leaks(in text: String) -> [String] {
        var found: [String] = []
        if text.rangeOfCharacter(from: badCharacters) != nil { found.append("Zeichen") }
        for token in text.split(whereSeparator: { !$0.isLetter }) where badWords.contains(token.lowercased()) {
            found.append(String(token))
        }
        return found
    }

    func testScannerFindsLiterals() {
        XCTAssertEqual(Self.literals(in: #"Text("Die Anlage") // "nicht""#), ["Die Anlage"])
        XCTAssertEqual(Self.literals(in: ##"let x = "a \(f("b")) c" + #"raw"# "##), ["b", "a \u{0} c", "raw"])
        XCTAssertEqual(Self.literals(in: "/// \"Anlage\""), [])
    }

    func testMacAppHasNoGermanTexts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources").appendingPathComponent("KlimacontrolApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(names.isEmpty, "Ordner Sources/KlimacontrolApp nicht gefunden")
        var hits: [String] = []
        for name in names {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                if s.contains("AppLog.") || s.hasSuffix("// Protokoll") { continue }
                for literal in Self.literals(in: s) {
                    let found = Self.leaks(in: literal)
                    if !found.isEmpty, !Self.exceptions.contains("\(name):\(literal)") {
                        hits.append("\(name):\(index + 1): \(found) in \"\(literal)\"")
                    }
                }
            }
        }
        XCTAssertEqual(hits, [], "Deutsche Texte in der Mac-Oberfläche: in den Katalog (L.…) verlegen")
    }
}
