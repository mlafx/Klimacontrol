import Foundation
import MideaKit

/// Kennzahlen eines Zeitraums, aus allen gespeicherten Punkten (nicht aus den ausgedünnten Graphenpunkten).
public struct HistoryStats: Equatable, Sendable {
    public var avgWatts: Double?
    public var peakWatts: Double?
    public var kWh: Double?
    /// Von Messwerten abgedeckte Sekunden (Lücken zählen nicht) – mit der Länge des Zeitraums ergibt das „Lücken: x h“.
    public var coveredSeconds: Double?
    /// Verbrauch laut Zähler der Anlage im Zeitraum (letzter − erster Zählerstand); nil = unbekannt oder Rücksprung.
    public var counterKWh: Double?

    public init(avgWatts: Double? = nil, peakWatts: Double? = nil, kWh: Double? = nil, coveredSeconds: Double? = nil,
                counterKWh: Double? = nil) {
        self.avgWatts = avgWatts
        self.peakWatts = peakWatts
        self.kWh = kWh
        self.coveredSeconds = coveredSeconds
        self.counterKWh = counterKWh
    }
}

/// Letzte gespeicherte Zeile (für die Startanzeige „Stand HH:MM“).
public struct HistoryLastRow: Equatable, Sendable {
    public var time: Date
    public var on: Bool?
    public var mode: String?
    public var target: Double?
    public var indoor: Double?
    public var outdoor: Double?
    public var fan: Int?
    public var eco: Bool?
    public var turbo: Bool?
    public var outSilent: Bool?
    public var watts: Double?
    public var totalKWh: Double?
}

/// Verlauf in SQLite (`verlauf.sqlite` im Ablageordner): eine Zeile je Abfrage (höchstens alle 10 s), Spalten aus
/// `HistoryColumn.all`. Die Graphen fragen nur ab, was sie zeigen – nichts davon muss im Speicher liegen.
/// Eine Verbindung, Zugriff über `lock`; alle Aufrufe sind kurz (Index auf der Zeit). Lässt sich die Datei nicht
/// öffnen, bleibt `isOpen` falsch und alle Aufrufe tun nichts (die App läuft ohne Verlauf weiter).
/// `@unchecked Sendable`: Verbindung und Merker nur unter `lock`; Hintergrundarbeit auf den seriellen Queues
/// `writes`/`maintenance` nimmt dieselbe Sperre.
public final class HistoryDB: @unchecked Sendable {
    public let url: URL
    /// Spaltennamen der Tabelle in der Reihenfolge von `HistoryLog.header` (Spalte 0 = Zeit in Unix-Sekunden).
    static let columns = HistoryColumn.all.map(\.name)
    /// Punkte älter als das werden auf eine Minute ausgedünnt (rund 1.440 Zeilen je Tag statt 8.640).
    static let denseSpan: TimeInterval = 86400
    static let sparseStep = 60
    /// Zeilen je Transaktion beim CSV-Import; dazwischen ist die Sperre frei (Graphen und neue Punkte warten nicht).
    static let importBatch = 2000
    /// Ausdünnen in Scheiben dieser Länge (vielfaches einer Minute); dazwischen ist die Sperre frei, damit ein
    /// neuer Punkt oder ein Graph nicht auf das Ausdünnen von Tagen warten muss.
    static let compactSlice = 6 * 3600
    /// Stufen des Ausdünnens (nichts wird gelöscht, nur gröber): älter als 1 Tag → 1 min, älter als 30 Tage → 15 min,
    /// älter als 1 Jahr → 1 h. Die behaltene Zeile trägt die mittlere Leistung ihres Zeitfensters, damit der
    /// Verbrauch alter Zeiträume erhalten bleibt.
    static let tiers: [(age: TimeInterval, step: Int)] = [(denseSpan, sparseStep), (30 * 86400, 900), (365 * 86400, 3600)]
    /// Größte Lücke zwischen zwei Zeilen, die beim Verbrauch noch mitzählt – je Stufe (dicht 10 min, sonst Raster + Rand).
    static let gapLimits: (dense: Int, mid: Int, old: Int) = (600, 1500, 4200)

    private static let insertSQL = "INSERT OR REPLACE INTO verlauf (\(columns.joined(separator: ","))) VALUES ("
        + Array(repeating: "?", count: columns.count).joined(separator: ",") + ")"
    private static let importSQL = insertSQL.replacingOccurrences(of: "OR REPLACE", with: "OR IGNORE")
    private static let exportSQL = "SELECT \(columns.joined(separator: ",")) FROM verlauf WHERE zeit >= ? AND zeit <= ? ORDER BY zeit"

    private var connection: SQLiteConnection?
    private let lock = NSLock()
    private var lastCompaction = Date.distantPast
    /// Bis hierhin (Unix-Sekunden) ist je Rasterweite schon ausgedünnt (Merker auch in `meta`, damit nicht jeder
    /// Start den ganzen Bestand durchgeht).
    private var compactedUntil: [Int: Int] = [:]
    /// Stündliches Ausdünnen läuft hier statt im Aufrufer von `insert` (dem MainActor).
    private let maintenance = DispatchQueue(label: "klimacontrol.history.compact", qos: .utility)
    /// Neue Zeilen, die nicht sofort geschrieben werden konnten (Sperre belegt), in Ankunftsreihenfolge.
    private let writes = DispatchQueue(label: "klimacontrol.history.write", qos: .utility)

    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            connection = try open()
        } catch let error as HistoryDBError where error.isBrokenFile {
            // Kaputte Datei: beiseitelegen (nicht löschen) und neu anfangen – sonst bliebe der Verlauf für immer leer.
            moveAside()
            connection = try? open()
        } catch {}
        binaryCounterSince = loadCounterMarker()
    }

    public var isOpen: Bool { connection != nil }

    /// Ab hier (Unix-Sekunden) steht in `gesamt_kwh` der binär gelesene Zähler. Davor ist `gesamt_kwh`
    /// BCD-verfälscht; dort gilt nur `zaehler_roh` × 0,01 kWh. Die gespeicherten Werte bleiben unverändert.
    private var binaryCounterSince = 0

    /// Zählerstand in kWh als SQL-Ausdruck (nil = unbekannt), für alle Verbrauchsauswertungen.
    private var counterSQL: String {
        "(CASE WHEN zeit >= \(binaryCounterSince) THEN gesamt_kwh "
            + "WHEN zaehler_roh > 0 AND zaehler_roh < 4294967295 THEN zaehler_roh * 0.01 END)"
    }

    /// Merker „Zähler binär ab“ lesen; fehlt er, ab jetzt (erste Öffnung mit binärer Lesart).
    private func loadCounterMarker() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return 0 }
        if let m = metaLocked("zaehler_binaer_ab").flatMap(Int.init) { return m }
        let now = Self.unix(Date())
        setMetaLocked("zaehler_binaer_ab", String(now))
        return now
    }

    // MARK: Öffnen

    /// Öffnen und Tabellen anlegen. Fehler werden protokolliert und weitergeworfen.
    private func open() throws -> SQLiteConnection {
        do {
            let c = try SQLiteConnection(url: url, mode: .readWrite, busyTimeout: 2000)
            // Vor dem ersten Schreiben: -wal und -shm übernehmen die Rechte der Hauptdatei.
            try? DeviceConfig.restrictToOwner(url, 0o600)
            defer {
                for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                    try? DeviceConfig.restrictToOwner(sibling(suffix), 0o600)
                }
            }
            try Self.setupSchema(c)
            return c
        } catch let error as HistoryDBError {
            AppLog.error("Verlaufsdatenbank nicht zu öffnen (\(error.code)): \(error.message)")
            throw error
        }
    }

    private func sibling(_ suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
    }

    private func moveAside() {
        let stamp = HistoryLog.isoString(Date()).prefix(19).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.moveItem(at: sibling(suffix), to: sibling(".defekt-\(stamp)\(suffix)"))
        }
        AppLog.error("Verlaufsdatenbank defekt – beiseitegelegt als \(url.lastPathComponent).defekt-\(stamp)")
    }

    /// Tabellen anlegen; neue Spalten aus `HistoryColumn.all` an eine bestehende Tabelle anhängen.
    private static func setupSchema(_ c: SQLiteConnection) throws {
        let definitions = HistoryColumn.all.map(\.sqlDefinition).joined(separator: ", ")
        try c.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
                   + "CREATE TABLE IF NOT EXISTS verlauf (\(definitions));"
                   + "CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, wert TEXT);")
        var have = Set<String>()
        try c.query("PRAGMA table_info(verlauf)") { have.insert($0.text(1)) }
        for column in HistoryColumn.all where !have.contains(column.name) {
            try c.exec("ALTER TABLE verlauf ADD COLUMN \(column.sqlDefinition)")
        }
    }

    // MARK: Zugriff (nur mit `lock`)

    /// `work` mit der Verbindung; ohne Verbindung nil. SQLite-Fehler werden protokolliert und ergeben nil.
    @discardableResult
    private func withConnectionLocked<T>(_ work: (SQLiteConnection) throws -> T) -> T? {
        guard let connection else { return nil }
        do {
            return try work(connection)
        } catch {
            AppLog.error("Verlauf (SQLite): \(error)")
            return nil
        }
    }

    private func metaLocked(_ name: String) -> String? {
        withConnectionLocked { c in
            var value: String?
            try c.query("SELECT wert FROM meta WHERE name = ?", [.text(name)]) { value = $0.text(0) }
            return value
        } ?? nil
    }

    private func setMetaLocked(_ name: String, _ value: String) {
        withConnectionLocked { try $0.query("INSERT OR REPLACE INTO meta (name, wert) VALUES (?, ?)", [.text(name), .text(value)]) }
    }

    private func hasMeta(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return withConnectionLocked { c in
            var found = false
            try c.query("SELECT 1 FROM meta WHERE name = ?", [.text(name)]) { _ in found = true }
            return found
        } ?? false
    }

    // MARK: Schreiben

    /// Datum → ganze Unix-Sekunden, begrenzt (NaN/∞/riesige Werte stürzen an der C-Grenze sonst über `Int(...)` ab).
    static func unix(_ date: Date) -> Int {
        let t = date.timeIntervalSince1970
        guard !t.isNaN else { return 0 }
        return Int(min(max(t, -1e12), 1e12).rounded(.down))
    }

    /// Eine Zeile (Felder wie `HistoryLog.fields`, leere Felder = NULL), sofort geschrieben (wartet auf die Sperre).
    /// Das stündliche Ausdünnen läuft danach im Hintergrund.
    public func insert(time: Date, fields: [String]) {
        insert(HistoryRow(time: time, fields: fields))
    }

    func insert(_ row: HistoryRow) {
        lock.lock()
        write(row)
    }

    /// Wie `insert`, aber ist die Sperre gerade belegt (Ausdünnen, Import), wird die Zeile im Hintergrund geschrieben,
    /// statt den Aufrufer (MainActor) warten zu lassen. Für neue Punkte der laufenden App (`HistoryStore.add`).
    public func insertSoon(time: Date, fields: [String]) {
        insertSoon(HistoryRow(time: time, fields: fields))
    }

    func insertSoon(_ row: HistoryRow) {
        if lock.try() {
            write(row)
        } else {
            writes.async { [self] in
                lock.lock()
                write(row)
            }
        }
    }

    /// Schreiben mit gehaltener Sperre; gibt sie frei und stößt bei Bedarf das Ausdünnen an.
    private func write(_ row: HistoryRow) {
        let now = Date()
        withConnectionLocked { try $0.query(Self.insertSQL, row.bindings) }
        let due = isOpen && now.timeIntervalSince(lastCompaction) >= 3600
        if due { lastCompaction = now }
        lock.unlock()
        guard due else { return }
        maintenance.async { [self] in
            for tier in Self.tiers { compact(before: now.addingTimeInterval(-tier.age), from: nil, step: tier.step) }
        }
    }

    /// Wartet, bis zurückgestellte Zeilen geschrieben sind (Beenden, Tests).
    public func flush() { writes.sync {} }

    /// WAL-Datei in die Datenbank übernehmen und auf 0 kürzen. Ohne das wuchs sie auf mehrere MB bei 600 KB
    /// Datenbank, weil die App nie schließt und SQLite nur bei 1.000 Seiten von selbst übernimmt.
    public func checkpoint() {
        lock.lock(); defer { lock.unlock() }
        withConnectionLocked { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    // MARK: Ausdünnen

    /// Zeilen zwischen `start` und `limit` auf eine je `step` Sekunden ausdünnen; die behaltene Zeile bekommt die
    /// mittlere Leistung des Fensters. Ohne `start`: ab dem Merker der letzten Ausdünnung, sonst die letzten drei Tage
    /// (älteres erledigt `compactAll` beim Start). Läuft in Scheiben von `compactSlice`; die Sperre gilt je Scheibe.
    func compact(before limit: Date, from start: Date? = nil, step: Int = sparseStep) {
        let to = Self.unix(limit)
        guard let plan = compactionPlan(to: to, start: start, step: step),
              let reached = compactSlices(from: plan.from, to: to, step: step) else { return }
        if plan.contiguous { advanceMarker(step: step, to: reached) }
        // Nach dem Löschen steht viel in der WAL-Datei – jetzt in die Datenbank übernehmen.
        checkpoint()
    }

    /// Bestand ausdünnen (einmal je Start, im Hintergrund) – ab dem gespeicherten Merker, ohne Merker ab der ältesten
    /// Zeile. So geht nicht jeder Start den ganzen Bestand durch, und nach Pausen von Tagen wird trotzdem nachgeholt.
    public func compactAll() {
        let now = Date()
        for tier in Self.tiers {
            lock.lock()
            let marker = markerLocked(tier.step)
            lock.unlock()
            compact(before: now.addingTimeInterval(-tier.age),
                    from: marker.map { Date(timeIntervalSince1970: Double($0)) } ?? .distantPast, step: tier.step)
        }
    }

    /// Wo das Ausdünnen beginnt und ob es lückenlos an Bestand bzw. Merker anschließt; nil = leere Tabelle.
    private struct CompactionPlan {
        let from: Int
        /// Den Merker „ausgedünnt bis“ nur fortschreiben, wenn lückenlos ab der ältesten Zeile bzw. ab dem bisherigen
        /// Merker ausgedünnt wird – das stündliche Fenster (letzte 3 Tage) darf ältere Zeilen nicht als erledigt melden.
        let contiguous: Bool
    }

    private func compactionPlan(to: Int, start: Date?, step: Int) -> CompactionPlan? {
        lock.lock(); defer { lock.unlock() }
        let marker = markerLocked(step)
        let requested = Self.align(start.map(Self.unix) ?? min(marker ?? to - 3 * 86400, to), step)
        // Nicht ab „distantPast“ in Scheiben zählen: erst ab der ältesten vorhandenen Zeile.
        guard let first = firstTimeLocked() else { return nil }
        let oldest = Self.align(first, step)
        return CompactionPlan(from: max(requested, oldest),
                              contiguous: requested <= oldest || marker.map { requested <= $0 } ?? false)
    }

    /// Scheibe für Scheibe bis `to`; die Sperre ist zwischen den Scheiben frei. Gibt das erreichte Ende zurück
    /// (nil = keine Scheibe geschafft).
    private func compactSlices(from start: Int, to: Int, step: Int) -> Int? {
        var from = start
        var reached: Int?
        while from < to {
            let end = min(to, from + Self.compactSlice)
            lock.lock()
            let ok = compactSliceLocked(from: from, to: end, step: step)
            lock.unlock()
            guard ok else { break }
            reached = end
            from = end
        }
        return reached
    }

    /// Eine Scheibe [from, to) ausdünnen (`from` auf vollem Raster, darum schneidet kein Fenster zwei Scheiben).
    private func compactSliceLocked(from: Int, to: Int, step: Int) -> Bool {
        guard from < to else { return true }
        let keep = "SELECT MIN(zeit) FROM verlauf WHERE zeit >= ?1 AND zeit < ?2 GROUP BY zeit / ?3"
        let args: [HistoryValue?] = [.integer(from), .integer(to), .integer(step)]
        let done: Void? = withConnectionLocked { c in
            try c.transaction { () throws -> Void in
                try c.query("UPDATE verlauf SET leistung_w = (SELECT AVG(v.leistung_w) FROM verlauf v WHERE v.zeit >= ?1 "
                            + "AND v.zeit < ?2 AND v.zeit / ?3 = verlauf.zeit / ?3) WHERE zeit IN (\(keep) HAVING COUNT(*) > 1)",
                            args)
                try c.query("DELETE FROM verlauf WHERE zeit >= ?1 AND zeit < ?2 AND zeit NOT IN (\(keep))", args)
            }
        }
        return done != nil
    }

    private func advanceMarker(step: Int, to reached: Int) {
        lock.lock(); defer { lock.unlock() }
        let until = max(compactedUntil[step] ?? reached, reached)
        compactedUntil[step] = until
        setMetaLocked("ausgeduennt_bis_\(step)", String(until))
    }

    /// Beginn auf volle Rasterweite: das beim letzten Lauf angeschnittene Fenster wird ganz erfasst (eine Zeile bleibt).
    private static func align(_ t: Int, _ step: Int) -> Int { t - ((t % step) + step) % step }

    private func firstTimeLocked() -> Int? {
        withConnectionLocked { c in
            var first: Int?
            try c.query("SELECT MIN(zeit) FROM verlauf") { s in if !s.isNull(0) { first = Int(s.int(0)) } }
            return first
        } ?? nil
    }

    /// Merker „ausgedünnt bis“ je Rasterweite (Speicher, sonst `meta`).
    private func markerLocked(_ step: Int) -> Int? {
        if let m = compactedUntil[step] { return m }
        let m = metaLocked("ausgeduennt_bis_\(step)").flatMap(Int.init)
        if let m { compactedUntil[step] = m }
        return m
    }

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
        AppLog.write("Verlauf: \(rows) Zeilen aus \(files.count - unreadable) CSV-Datei(en) in die Datenbank übernommen"
                     + (unreadable > 0 ? " – \(unreadable) Datei(en) nicht lesbar, nächster Versuch beim nächsten Start" : ""))
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
                        do { try stmt.forEachRow { _ in } } catch { AppLog.error("Verlauf (SQLite): \(error)") }
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

    // MARK: Lesen

    /// Punkte ab `start`, für die Graphen auf höchstens ~`maxPoints` Zeitfenster gemittelt. Die Fenster hängen an der
    /// Uhrzeit (nicht am Anfang des Zeitraums), damit die Linie beim Weiterrücken nicht springt.
    public func samples(since start: Date, maxPoints: Int = 600, now: Date = Date()) -> [HistorySample] {
        lock.lock(); defer { lock.unlock() }
        let points = max(1, maxPoints)
        let from = Self.unix(start)
        let bucket = max(1, max(1, Self.unix(now) - from) / points)
        // Alte Zeilen haben im Aus-Zustand 10,0 °C außen als Platzhalter – kein Messwert.
        let sql = """
            SELECT MIN(zeit), AVG(leistung_w), AVG(innen_c),
                   AVG(CASE WHEN ein = 1 OR aussen_c <> 10.0 THEN aussen_c END),
                   MAX(CASE WHEN ein = 1 THEN soll_c END), MAX(ein)
            FROM verlauf WHERE zeit >= ? GROUP BY zeit / ? ORDER BY 1
            """
        var out: [HistorySample] = []
        out.reserveCapacity(min(points, 10_000) + 2)
        withConnectionLocked { c in
            try c.query(sql, [.integer(from), .integer(bucket)]) { s in
                out.append(HistorySample(time: s.date(0), power: s.double(1), indoor: s.double(2), outdoor: s.double(3),
                                         target: s.double(4), on: s.int(5) == 1))
            }
        }
        return out
    }

    /// Ø Leistung (zeitgewichtet – dichte und ausgedünnte Zeilen zählen nach ihrer Dauer), Spitze und Verbrauch ab
    /// `start` aus allen Zeilen. Lücken zählen nicht (dicht: über 10 min; ausgedünnte Stufen: über ihr Raster).
    /// Dazu der Verbrauch laut Zähler der Anlage und die abgedeckte Zeit.
    public func stats(since start: Date, now: Date = Date()) -> HistoryStats {
        lock.lock(); defer { lock.unlock() }
        let n = Self.unix(now)
        let sql = """
            SELECT SUM(CASE WHEN dt < lim THEN leistung_w * dt END),
                   SUM(CASE WHEN dt < lim AND leistung_w IS NOT NULL THEN dt END),
                   AVG(leistung_w), MAX(leistung_w), COUNT(*),
                   (SELECT \(counterSQL) AS k FROM verlauf WHERE zeit >= ?1 AND k IS NOT NULL ORDER BY zeit LIMIT 1),
                   (SELECT \(counterSQL) AS k FROM verlauf WHERE zeit >= ?1 AND k IS NOT NULL ORDER BY zeit DESC LIMIT 1)
            FROM (SELECT leistung_w, LEAD(zeit) OVER (ORDER BY zeit) - zeit AS dt,
                         CASE WHEN zeit < ?2 THEN ?4 WHEN zeit < ?3 THEN ?5 ELSE ?6 END AS lim
                  FROM verlauf WHERE zeit >= ?1)
            """
        let args: [HistoryValue?] = [.integer(Self.unix(start)), .integer(n - 365 * 86400), .integer(n - 30 * 86400),
                                     .integer(Self.gapLimits.old), .integer(Self.gapLimits.mid), .integer(Self.gapLimits.dense)]
        var r = HistoryStats()
        withConnectionLocked { c in
            try c.query(sql, args) { s in
                let ws = s.double(0), span = s.double(1)
                var avg = s.double(2)
                if let ws, let span, span > 0 { avg = ws / span }
                var counter: Double?
                if let a = s.double(5), let b = s.double(6), b >= a { counter = b - a }
                r = HistoryStats(avgWatts: avg, peakWatts: s.double(3), kWh: s.int(4) > 1 ? (ws ?? 0) / 3_600_000 : nil,
                                 coveredSeconds: span, counterKWh: counter)
            }
        }
        return r
    }

    /// Letzte Zeile mit Zeit (Startanzeige „Stand HH:MM“); nil = leerer Verlauf.
    public func lastRow() -> HistoryLastRow? {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT zeit, ein, modus, soll_c, innen_c, aussen_c, luefter, eco, turbo, aussen_leise, leistung_w, "
            + "\(counterSQL) FROM verlauf ORDER BY zeit DESC LIMIT 1"
        return withConnectionLocked { c in
            var row: HistoryLastRow?
            try c.query(sql) { s in
                func b(_ i: Int32) -> Bool? { s.double(i).map { $0 != 0 } }
                row = HistoryLastRow(time: s.date(0), on: b(1), mode: s.optionalText(2), target: s.double(3),
                                     indoor: s.double(4), outdoor: s.double(5), fan: s.double(6).map { Int($0) },
                                     eco: b(7), turbo: b(8), outSilent: b(9), watts: s.double(10), totalKWh: s.double(11))
            }
            return row
        } ?? nil
    }

    /// Letzter Zählerstand vor `date` bzw. erster ab `date` (höchstens bis `until`), mit Zeit.
    func counter(before date: Date) -> (time: Date, kWh: Double)? {
        counterQuery("zeit < ?1 AND k IS NOT NULL ORDER BY zeit DESC", [.integer(Self.unix(date))])
    }

    func counter(atOrAfter date: Date, until: Date) -> (time: Date, kWh: Double)? {
        counterQuery("zeit >= ?1 AND zeit <= ?2 AND k IS NOT NULL ORDER BY zeit",
                     [.integer(Self.unix(date)), .integer(Self.unix(until))])
    }

    private func counterQuery(_ condition: String, _ args: [HistoryValue?]) -> (time: Date, kWh: Double)? {
        lock.lock(); defer { lock.unlock() }
        return withConnectionLocked { c in
            var out: (time: Date, kWh: Double)?
            try c.query("SELECT zeit, \(counterSQL) AS k FROM verlauf WHERE \(condition) LIMIT 1", args) { s in
                if let k = s.double(1) { out = (s.date(0), k) }
            }
            return out
        } ?? nil
    }

    /// Zeit der ältesten Zeile; nil = leerer Verlauf.
    func firstTime() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return firstTimeLocked().map { Date(timeIntervalSince1970: Double($0)) }
    }

    /// Verbrauch aus Leistung × Zeit in [`from`, `to`), mit denselben Lückengrenzen wie `stats`. Die Dauer der letzten
    /// Zeile endet an `to`, die der Zeile davor wird nicht mitgezählt. nil = keine Messwerte im Zeitraum.
    func measuredKWh(from: Date, to: Date, now: Date = Date()) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let n = Self.unix(now)
        let sql = """
            SELECT SUM(CASE WHEN dt < lim AND leistung_w IS NOT NULL THEN leistung_w * MIN(dt, ?7 - zeit) END),
                   COUNT(CASE WHEN dt < lim AND leistung_w IS NOT NULL THEN 1 END)
            FROM (SELECT zeit, leistung_w, LEAD(zeit) OVER (ORDER BY zeit) - zeit AS dt,
                         CASE WHEN zeit < ?2 THEN ?4 WHEN zeit < ?3 THEN ?5 ELSE ?6 END AS lim
                  FROM verlauf WHERE zeit >= ?1 AND zeit <= ?7 + \(Self.gapLimits.old))
            WHERE zeit < ?7
            """
        let args: [HistoryValue?] = [.integer(Self.unix(from)), .integer(n - 365 * 86400), .integer(n - 30 * 86400),
                                     .integer(Self.gapLimits.old), .integer(Self.gapLimits.mid), .integer(Self.gapLimits.dense),
                                     .integer(Self.unix(to))]
        return withConnectionLocked { c in
            var out: Double?
            try c.query(sql, args) { s in
                if s.int(1) > 0, let ws = s.double(0) { out = ws / 3_600_000 }
            }
            return out
        } ?? nil
    }

    // MARK: CSV-Export

    /// Ganzen Verlauf als CSV schreiben (Kopfzeile wie `HistoryLog.header`, Zeit als ISO 8601 in Ortszeit mit Abstand
    /// zu UTC, z. B. „2026-11-05T07:00:00+01:00“).
    public func exportCSV(to target: URL) throws {
        try exportCSV(to: target, from: nil, until: nil, readable: false)
    }

    /// CSV-Export eines Zeitraums. `readable`: deutsche Spaltennamen mit Einheit, Zeit „JJJJ-MM-TT HH:MM:SS“
    /// (Ortszeit) und Dezimalkomma – so öffnen Excel und Numbers die Datei richtig; der Import liest beide Formen.
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
            var buffer = readable ? HistoryLog.readableHeader : HistoryLog.header
            try stmt.forEachRow { s in
                buffer += exportLine(s, readable: readable)
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
    /// ausgibt, lesbar mit Dezimalkomma.
    private static func exportLine(_ s: SQLStatement, readable: Bool) -> String {
        let t = s.date(0)
        var fields = [readable ? HistoryLog.readableTime(t) : HistoryLog.isoString(t)]
        for (i, column) in HistoryColumn.data.enumerated() {
            fields.append(column.exportField(s.text(Int32(i + 1)), readable: readable))
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
