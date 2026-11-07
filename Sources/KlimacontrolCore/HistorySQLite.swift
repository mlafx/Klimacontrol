import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Fehler der Verlaufsdatenbank: SQLite-Code und Meldung der Verbindung.
struct HistoryDBError: Error, Equatable, CustomStringConvertible {
    let code: Int32
    let message: String

    /// Datei ist keine bzw. eine beschädigte Datenbank (dann wird sie beiseitegelegt).
    var isBrokenFile: Bool { code == SQLITE_NOTADB || code == SQLITE_CORRUPT }
    var description: String { message }
}

/// Eine SQLite-Verbindung mit kleinen Helfern (ausführen, vorbereiten, binden, lesen, Transaktion). Nicht
/// threadsicher: Der Besitzer sorgt für den exklusiven Zugriff (`HistoryDB.lock`). Schließt beim Freigeben.
final class SQLiteConnection {
    private let handle: OpaquePointer

    enum Mode {
        /// Lesen und Schreiben, Datei wird bei Bedarf angelegt.
        case readWrite
        /// Nur lesen (eigene Verbindung für den Export).
        case readOnly

        var flags: Int32 {
            switch self {
            case .readWrite: return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            case .readOnly: return SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            }
        }
    }

    /// Öffnet `url`; `busyTimeout` in Millisekunden.
    init(url: URL, mode: Mode, busyTimeout: Int32) throws {
        let flags = mode.flags
        var db: OpaquePointer?
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return SQLITE_CANTOPEN }
            return sqlite3_open_v2(path, &db, flags, nil)
        }
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unbekannt"
            sqlite3_close(db)
            throw HistoryDBError(code: code, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, busyTimeout)
    }

    deinit { sqlite3_close(handle) }

    /// Letzter Fehler der Verbindung.
    var lastError: HistoryDBError {
        HistoryDBError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Geänderte Zeilen seit dem Öffnen (zum Zählen eingefügter Zeilen).
    var totalChanges: Int { Int(sqlite3_total_changes(handle)) }

    /// Eine oder mehrere Anweisungen ohne Werte und ohne Ergebnis.
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    /// Anweisung vorbereiten, `body` damit ausführen, danach freigeben.
    func withStatement<T>(_ sql: String, _ body: (SQLStatement) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let error = lastError
            sqlite3_finalize(stmt)
            throw error
        }
        defer { sqlite3_finalize(stmt) }
        return try body(SQLStatement(handle: stmt, connection: self))
    }

    /// Vorbereiten, Werte binden, `row` je Ergebniszeile.
    func query(_ sql: String, _ args: [HistoryValue?] = [], row: (SQLStatement) throws -> Void = { _ in }) throws {
        try withStatement(sql) { stmt in
            stmt.bind(args)
            try stmt.forEachRow(row)
        }
    }

    /// `body` in BEGIN … COMMIT; bei einem Fehler ROLLBACK und weiterwerfen.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

/// Eine vorbereitete Anweisung; gültig nur innerhalb von `SQLiteConnection.withStatement`.
struct SQLStatement {
    let handle: OpaquePointer
    unowned let connection: SQLiteConnection

    /// Werte binden (Platzhalter 1…n): nil → NULL, Zahlen als Zahl, Text als Text.
    func bind(_ args: [HistoryValue?]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case .int(let v)?: sqlite3_bind_int64(handle, n, v)
            case .real(let v)?: sqlite3_bind_double(handle, n, v)
            case .text(let v)?: sqlite3_bind_text(handle, n, v, -1, transient)
            case nil: sqlite3_bind_null(handle, n)
            }
        }
    }

    /// Für die nächste Ausführung mit neuen Werten zurücksetzen.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// Einen Schritt ausführen: true = Ergebniszeile liegt an, false = fertig.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.lastError
        }
    }

    /// Bis zum Ende ausführen, `body` je Ergebniszeile.
    func forEachRow(_ body: (SQLStatement) throws -> Void) throws {
        while try step() { try body(self) }
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(handle, i) }
    /// Text des Werts, wie SQLite ihn ausgibt (Zahlen ohne „.0“, NULL → leer).
    func text(_ i: Int32) -> String { sqlite3_column_text(handle, i).map { String(cString: $0) } ?? "" }
    func optionalText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: Double(int(i))) }
}
