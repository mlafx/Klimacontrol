import Foundation
import MideaKit

/// CSV-Format des Verlaufs: Kopfzeilen und Zeitformate für `verlauf.csv`, Export und Import. Alles leitet sich aus
/// `HistoryColumn.all` ab. `;`-getrennt, eine Zeile je Punkt, leeres Feld = unbekannt (AGENTS.md Anhang B).
extension HistoryLog {
    /// Kopfzeile von `verlauf.csv` und des technischen Exports.
    public static let header = HistoryColumn.all.map(\.name).joined(separator: ";") + "\n"

    /// Kopfzeile des lesbaren Exports (deutsche Spaltennamen mit Einheit).
    public static let readableHeader = HistoryColumn.all.map(\.readableName).joined(separator: ";") + "\n"

    private static let technicalNames = Dictionary(uniqueKeysWithValues: HistoryColumn.all.map { ($0.readableName, $0.name) })

    /// Spaltenname aus einer Kopfzeile (technisch oder lesbar) → technischer Name; Unbekanntes bleibt, wie es ist.
    static func technicalName(_ name: String) -> String { technicalNames[name] ?? name }

    /// Felder einer Zeile in der Reihenfolge von `header` (leer = unbekannt).
    static func fields(state s: ACState, diagnostics d: Diagnostics, time: Date) -> [String] {
        HistoryRow(state: s, diagnostics: d, time: time).fields
    }

    // MARK: Zeit
    //
    // Ortszeit über `Calendar.current.timeZone`, nie `TimeZone.current`: Unter Windows liefert `TimeZone.current` GMT,
    // und auf keiner Plattform folgt es einer gesetzten Standardzone. Die Bridge setzt sie unter Windows beim Start;
    // die Formatierer folgen ihr bei jedem Zugriff (`followLocalZone`).

    /// Ortszeit mit Abstand zu UTC („2026-11-05T07:00:00+01:00“) – Tabellen zeigen sonst um 1–2 h verschobene Zeiten.
    /// Ein Formatierer für alle Zeilen (teuer anzulegen). `nonisolated(unsafe)`: nicht `Sendable`, jeder Zugriff hält
    /// `timeLock`.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = Calendar.current.timeZone
        return f
    }()
    /// Zeit im lesbaren Export „JJJJ-MM-TT HH:MM:SS“ (Ortszeit, ohne Zone). Zugriff unter `timeLock`.
    private static let plain = readableFormatter(timeZone: Calendar.current.timeZone)

    static func readableFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }
    private static let timeLock = NSLock()

    /// Unter `timeLock` aufrufen.
    private static func followLocalZone() {
        let tz = Calendar.current.timeZone
        guard plain.timeZone != tz else { return }
        plain.timeZone = tz
        iso.timeZone = tz
    }

    static func isoString(_ date: Date) -> String {
        timeLock.lock(); defer { timeLock.unlock() }
        followLocalZone()
        return iso.string(from: date)
    }

    static func readableTime(_ date: Date) -> String {
        timeLock.lock(); defer { timeLock.unlock() }
        followLocalZone()
        return plain.string(from: date)
    }

    /// Liest ISO 8601 (mit „Z“ oder Abstand, ältere Dateien stehen in UTC) und die lesbare Form.
    static func date(_ text: String) -> Date? {
        timeLock.lock(); defer { timeLock.unlock() }
        followLocalZone()
        let t = text.trimmingCharacters(in: .whitespaces)
        return iso.date(from: t) ?? plain.date(from: t)
    }

    /// Lesbare Zeiten haben keine Zone: Am Ende der Sommerzeit kommt eine Stunde (z. B. 02:00–02:59) zweimal vor, und
    /// welches Vorkommen das Lesen liefert, hängt von der Plattform ab (macOS: das zweite). Gemeint ist in einer
    /// aufsteigenden Datei das früheste Vorkommen, das nicht vor der vorigen Zeile liegt – sonst fiele beim Einfügen
    /// eine Stunde weg. Ohne vorige Zeile (oder wenn alle davor liegen) das erste Vorkommen. `t` ist das gelesene
    /// Datum zu `text`; Zeiten mit Zone (ISO 8601) bleiben unverändert.
    static func resolveRepeatedHour(_ t: Date, text: String, after previous: Date?) -> Date {
        timeLock.lock(); defer { timeLock.unlock() }
        followLocalZone()
        return resolveRepeatedHour(t, text: text, after: previous, formatter: plain)
    }

    /// Wie oben mit eigenem Formatierer (`readableFormatter`), damit Tests eine feste Zone nehmen können.
    static func resolveRepeatedHour(_ t: Date, text: String, after previous: Date?, formatter: DateFormatter) -> Date {
        let tz = formatter.timeZone ?? Calendar.current.timeZone
        let before = t.addingTimeInterval(-3600), later = t.addingTimeInterval(3600)
        guard tz.secondsFromGMT(for: before) != tz.secondsFromGMT(for: later) else { return t }
        let candidates = [before, t, later].filter { formatter.string(from: $0) == text }
        guard let first = candidates.first else { return t }
        guard let previous else { return first }
        return candidates.first { $0 >= previous } ?? first
    }
}

/// Liest die Zeilen einer CSV-Datei des Verlaufs. Spalten nach den Namen ihrer Kopfzeile (beiseitegelegte Dateien
/// haben eine ältere, ein lesbarer Export deutsche Spaltennamen); fehlende Spalten sind unbekannt, unbekannte werden
/// übergangen. Zeilen ohne lesbare Zeit werden übersprungen.
struct HistoryCSVReader: IteratorProtocol {
    private var lines: IndexingIterator<[Substring]>
    /// Position jeder Spalte aus `HistoryColumn.all` in der Datei (nil = fehlt).
    private let positions: [Int?]
    private let timePosition: Int
    private var previous: Date?

    /// nil = leere Datei oder keine Zeitspalte (dann gibt es nichts zu übernehmen).
    init?(text: String) {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let head = lines.next() else { return nil }
        let names = head.split(separator: ";", omittingEmptySubsequences: false)
            .map { HistoryLog.technicalName($0.trimmingCharacters(in: .whitespaces)) }
        let positions = HistoryColumn.all.map { names.firstIndex(of: $0.name) }
        guard let timePosition = positions[0] else { return nil }
        self.lines = lines
        self.positions = positions
        self.timePosition = timePosition
    }

    mutating func next() -> HistoryRow? {
        while let line = lines.next() {
            let cells = line.split(separator: ";", omittingEmptySubsequences: false)
            guard timePosition < cells.count else { continue }
            let text = cells[timePosition].trimmingCharacters(in: .whitespaces)
            guard let read = HistoryLog.date(text) else { continue }
            let time = HistoryLog.resolveRepeatedHour(read, text: text, after: previous)
            previous = time
            let fields = positions.map { p in p.flatMap { $0 < cells.count ? String(cells[$0]) : nil } ?? "" }
            return HistoryRow(time: time, fields: fields)
        }
        return nil
    }
}
