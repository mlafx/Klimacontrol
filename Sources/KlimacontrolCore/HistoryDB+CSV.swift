import Foundation
import MideaKit

extension HistoryDB {
    // MARK: CSV-Import

    /// Alte CSV-Dateien einmalig übernehmen (vorhandene Zeitpunkte bleiben). Die Dateien bleiben liegen. Erledigt
    /// gilt der Import erst, wenn alle Dateien lesbar waren (OneDrive-Platzhalter werden beim nächsten Start erneut
    /// versucht). Läuft im Hintergrund; die Sperre wird nur je Stapel gehalten.
    public func importCSVOnce(from files: [URL]) {
        guard isOpen, !hasMeta("csv_import") else { return }
        var rows = 0, unreadable = 0
        for file in files {
            if let n = importFile(file) { rows += n } else { unreadable += 1 }
        }
        finishImport(addedRows: rows, complete: unreadable == 0)
        AppLog.write(L.Log.History.imported(
            rows: String(rows), files: String(files.count - unreadable),
            unreadable: unreadable > 0 ? L.Log.History.importUnreadable(count: String(unreadable)) : ""))
    }

    /// Eine CSV-Datei in Stapeln übernehmen. Gibt die Zahl neuer Zeilen zurück; nil = Datei nicht lesbar.
    private func importFile(_ file: URL) -> Int? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        guard var reader = HistoryCSVReader(text: text) else { return 0 }
        var added = 0
        var batch: [HistoryRow] = []
        batch.reserveCapacity(Self.importBatch)
        while let row = reader.next() {
            batch.append(row)
            if batch.count >= Self.importBatch {
                added += insertBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        return added + insertBatch(batch)
    }

    /// Ein Stapel in einer Transaktion, eine vorbereitete Anweisung für alle Zeilen. Eine Zeile, die SQLite ablehnt,
    /// wird protokolliert und übersprungen.
    private func insertBatch(_ batch: [HistoryRow]) -> Int {
        guard !batch.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return withConnectionLocked { c in
            try c.transaction {
                let before = c.totalChanges
                try c.withStatement(Self.importSQL) { stmt in
                    for row in batch {
                        stmt.reset()
                        stmt.bind(row.bindings)
                        do { try stmt.forEachRow { _ in } } catch { AppLog.error(L.Log.History.sqlite(error: "\(error)")) }
                    }
                }
                return c.totalChanges - before
            }
        } ?? 0
    }

    /// Import als erledigt merken (nur wenn alle Dateien lesbar waren). Sind ältere Zeilen dazugekommen, die Merker
    /// des Ausdünnens zurücksetzen, damit `compactAll` sie mit ausdünnt.
    private func finishImport(addedRows: Int, complete: Bool) {
        lock.lock(); defer { lock.unlock() }
        if complete { setMetaLocked("csv_import", HistoryLog.isoString(Date())) }
        guard addedRows > 0 else { return }
        withConnectionLocked { try $0.exec("DELETE FROM meta WHERE name LIKE 'ausgeduennt_bis_%'") }
        compactedUntil = [:]
    }

    // MARK: CSV-Export

    /// Ganzen Verlauf als CSV schreiben (Kopfzeile wie `HistoryLog.header`, Zeit als ISO 8601 in Ortszeit mit Abstand
    /// zu UTC, z. B. „2026-11-05T07:00:00+01:00“).
    public func exportCSV(to target: URL) throws {
        try exportCSV(to: target, from: nil, until: nil, readable: false)
    }

    /// CSV-Export eines Zeitraums. `readable`: Spaltennamen mit Einheit und Modus in der Sprache der Oberfläche, Zeit
    /// „JJJJ-MM-TT HH:MM:SS“ (Ortszeit) und Dezimalzeichen „,“ oder „.“ nach Format (Spaltentrenner bleibt „;“) – so öffnen Excel und Numbers die Datei richtig;
    /// der Import liest beide Formen und beide Sprachen.
    /// Liest über eine eigene Verbindung und schreibt zeilenweise in eine Zwischendatei, die am Ende das Ziel ersetzt:
    /// blockiert weder Graphen noch neue Punkte. Fehler als `CocoaError` (Lesen: `.fileReadUnknown`), damit die
    /// Oberflächen dieselben Meldungen zeigen.
    public func exportCSV(to target: URL, from: Date?, until: Date?, readable: Bool) throws {
        guard isOpen else { throw CocoaError(.fileWriteUnknown) }
        let source: SQLiteConnection
        do {
            source = try SQLiteConnection(url: url, mode: .readOnly, busyTimeout: 5000)
        } catch {
            throw CocoaError(.fileReadUnknown)
        }
        let range: [HistoryValue?] = [.integer(from.map(Self.unix) ?? Int(Int32.min)), .integer(until.map(Self.unix) ?? Int(1e12))]
        do {
            try source.withStatement(Self.exportSQL) { stmt in
                stmt.bind(range)
                try Self.writeExport(of: stmt, readable: readable, to: target)
            }
        } catch is HistoryDBError {
            throw CocoaError(.fileReadUnknown)
        }
    }

    /// Ergebniszeilen von `exportSQL` als CSV in eine Zwischendatei neben `target`, danach an die Stelle von `target`.
    /// Bei einem Fehler bleibt `target` unverändert und die Zwischendatei verschwindet.
    private static func writeExport(of stmt: SQLStatement, readable: Bool, to target: URL) throws {
        let fm = FileManager.default
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        #if os(Windows)
        let created = fm.createFile(atPath: tmp.path, contents: nil)
        #else
        let created = fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        #endif
        guard created, let h = try? FileHandle(forWritingTo: tmp) else { throw CocoaError(.fileWriteNoPermission) }
        do {
            let style = readable ? HistoryColumn.ReadableStyle() : nil
            var buffer = readable ? HistoryLog.readableHeader : HistoryLog.header
            try stmt.forEachRow { s in
                buffer += exportLine(s, style: style)
                if buffer.utf8.count >= 1 << 16 {
                    try h.write(contentsOf: Data(buffer.utf8))
                    buffer = ""
                }
            }
            try h.write(contentsOf: Data(buffer.utf8))
            try h.close()
            try replace(target, with: tmp)
        } catch {
            try? h.close()
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Eine Ergebniszeile als CSV-Zeile: Zeit technisch (ISO 8601) oder lesbar (Ortszeit), Werte wie SQLite sie
    /// ausgibt, lesbar mit Dezimalzeichen des Formats und Modus in der Sprache der Oberfläche.
    private static func exportLine(_ s: SQLStatement, style: HistoryColumn.ReadableStyle?) -> String {
        let t = s.date(0)
        var fields = [style != nil ? HistoryLog.readableTime(t) : HistoryLog.isoString(t)]
        for (i, column) in HistoryColumn.data.enumerated() {
            fields.append(column.exportField(s.text(Int32(i + 1)), style: style))
        }
        return fields.joined(separator: ";") + "\n"
    }

    private static func replace(_ target: URL, with tmp: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return try fm.moveItem(at: tmp, to: target) }
        #if os(Windows)
        // replaceItemAt ist unter Windows nicht umgesetzt: vorhandene Zieldatei (im Dialog „Ersetzen“) weg, dann verschieben.
        try fm.removeItem(at: target)
        try fm.moveItem(at: tmp, to: target)
        #else
        _ = try fm.replaceItemAt(target, withItemAt: tmp)
        #endif
    }
}
