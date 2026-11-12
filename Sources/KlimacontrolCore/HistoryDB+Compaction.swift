import Foundation
import MideaKit

extension HistoryDB {
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

    func firstTimeLocked() -> Int? {
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
}
