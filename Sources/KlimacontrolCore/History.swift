import Foundation
import MideaKit
import Observation

/// Ein Punkt im Verlauf (Graphen).
public struct HistorySample: Identifiable, Equatable, Sendable {
    public var id: Date { time }
    public let time: Date
    public let power: Double?
    public let indoor: Double?
    public let outdoor: Double?
    public let target: Double?
    public let on: Bool

    public init(time: Date, power: Double?, indoor: Double?, outdoor: Double?, target: Double?, on: Bool) {
        self.time = time
        self.power = power
        self.indoor = indoor
        self.outdoor = outdoor
        self.target = target
        self.on = on
    }

    /// Punkt, der `time` am nächsten liegt (für die Anzeige unter dem Mauszeiger). `data` muss nach Zeit sortiert sein.
    public static func nearest(in data: [HistorySample], to time: Date) -> HistorySample? {
        guard !data.isEmpty else { return nil }
        var lo = 0, hi = data.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if data[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return data[lo] }
        let before = data[lo - 1], after = data[lo]
        return time.timeIntervalSince(before.time) <= after.time.timeIntervalSince(time) ? before : after
    }

    init(_ s: ACState, at time: Date) {
        self.init(time: time, power: s.powerWatts, indoor: s.indoorTemperature, outdoor: s.outdoorTemperature,
                  target: s.power ? s.targetTemperature : nil, on: s.power)
    }
}

/// Verlauf zusätzlich als CSV (`verlauf.csv`, höchstens alle 30 s) – nur wenn in den Einstellungen gewünscht.
/// Kopfzeile, Felder und Zeitformate stehen in `HistoryCSV.swift` (aus `HistoryColumn.all`).
/// `@unchecked Sendable`: `lastWrite`/`headerChecked` nur unter `lock` (append).
public final class HistoryLog: @unchecked Sendable {
    public let url: URL
    private var lastWrite = Date.distantPast
    /// Kopfzeile in dieser Sitzung schon geprüft (danach schreibt nur noch diese Instanz mit der aktuellen Kopfzeile).
    private var headerChecked = false
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// Höchstens alle 30 s eine Zeile – auch wenn die App im Sekundentakt abfragt.
    public func append(state s: ACState, diagnostics d: Diagnostics, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastWrite) >= 29 else { return }
        lastWrite = now
        let line = HistoryRow(state: s, diagnostics: d, time: now).fields.joined(separator: ";") + "\n"
        let fm = FileManager.default
        if !headerChecked {
            rotateIfHeaderChanged(now: now)
            headerChecked = true
        }
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fm.createFile(atPath: url.path, contents: Data(Self.header.utf8))
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }

    /// Neue Spalten? Alte Datei mit anderer Kopfzeile beiseitelegen statt Spalten zu vermischen.
    private func rotateIfHeaderChanged(now: Date) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        let first = String(decoding: (try? h.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        try? h.close()
        guard first + "\n" != Self.header else { return }
        // Sekunde im Namen, bei Gleichstand ein Zähler – sonst schlüge das Beiseitelegen still fehl.
        let stamp = Self.readableTime(now).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent("verlauf-bis-\(stamp).csv")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("verlauf-bis-\(stamp)-\(n).csv")
            n += 1
        }
        do { try FileManager.default.moveItem(at: url, to: target) } catch {
            AppLog.error("verlauf.csv nicht beiseitegelegt: \(error.localizedDescription)")
        }
    }

    /// Vorhandene CSV-Dateien im Ablageordner (verlauf.csv und beiseitegelegte verlauf-bis-*.csv).
    func existingFiles() -> [URL] {
        let dir = url.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("verlauf") && $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Verlauf für die Graphen: schreibt jede Abfrage (höchstens alle 10 s) in die Datenbank und liest daraus nur, was
/// angezeigt wird. Nichts davon bleibt im Speicher. `revision` zählt neue Punkte – Oberflächen hängen ihr Neuzeichnen daran.
@MainActor
@Observable
public final class HistoryStore {
    public private(set) var revision = 0
    @ObservationIgnored private var lastLive = Date.distantPast
    /// Kennzahlen je Zeitraumbeginn, kurz zwischengespeichert (Tagesverbrauch-Prüfung bei jedem Neuzeichnen).
    @ObservationIgnored private var statsCache: [Int: (at: Date, revision: Int, stats: HistoryStats)] = [:]
    @ObservationIgnored public let db: HistoryDB
    @ObservationIgnored public let log: HistoryLog
    /// Zusätzlich `verlauf.csv` schreiben (Einstellung, Standard aus).
    public var csvEnabled = false

    public init(db: HistoryDB, log: HistoryLog, importExisting: Bool = true) {
        self.db = db
        self.log = log
        guard importExisting else { return }
        // Im Hintergrund: einmalig alte CSV-Dateien übernehmen, dann bei jedem Start den ganzen Bestand ausdünnen
        // (in Scheiben, die Sperre ist dazwischen frei), danach neu zeichnen.
        Task.detached(priority: .utility) { [db, log] in
            db.importCSVOnce(from: log.existingFiles())
            db.compactAll()
            await MainActor.run { self.revision += 1 }
        }
    }

    /// Neuer Punkt nach einer Abfrage. `diagnostics` nur mitgeben, wenn sie frisch sind (sonst bleiben die Spalten leer).
    public func add(_ s: ACState, diagnostics: Diagnostics? = nil, now: Date = Date()) {
        guard now.timeIntervalSince(lastLive) >= 10 else { return }
        lastLive = now
        let d = diagnostics ?? Diagnostics()
        db.insertSoon(HistoryRow(state: s, diagnostics: d, time: now))
        if csvEnabled, diagnostics != nil { log.append(state: s, diagnostics: d, now: now) }
        revision += 1
    }

    /// Punkte der letzten `seconds` Sekunden, für lange Zeiträume auf höchstens ~600 gemittelt.
    public func window(_ seconds: TimeInterval, now: Date = Date()) -> [HistorySample] {
        db.samples(since: now.addingTimeInterval(-seconds), now: now)
    }

    /// Ø Leistung, Spitze, Verbrauch der letzten `seconds` Sekunden aus allen Punkten.
    public func stats(_ seconds: TimeInterval, now: Date = Date()) -> HistoryStats {
        db.stats(since: now.addingTimeInterval(-seconds))
    }

    /// Wie `stats`, aber höchstens alle 60 s bzw. nach 30 neuen Punkten neu gerechnet.
    public func cachedStats(since start: Date, now: Date = Date()) -> HistoryStats {
        let key = HistoryDB.unix(start)
        if let c = statsCache[key], now.timeIntervalSince(c.at) < 60, revision - c.revision < 30 { return c.stats }
        let st = db.stats(since: start, now: now)
        if statsCache.count > 8 { statsCache.removeAll() }
        statsCache[key] = (now, revision, st)
        return st
    }

    /// Letzter gespeicherter Punkt (Startanzeige „Stand HH:MM“); nil = leerer Verlauf.
    public func lastSample() -> HistorySample? {
        guard let r = db.lastRow() else { return nil }
        let on = r.on ?? false
        return HistorySample(time: r.time, power: r.watts, indoor: r.indoor,
                             outdoor: on || r.outdoor != 10.0 ? r.outdoor : nil, target: on ? r.target : nil, on: on)
    }

    /// Letzter bekannter Zustand mit Zeit, aus dem Verlauf (für die abgeblendete Anzeige beim Verbinden).
    /// Nur Werte, die der Verlauf speichert (Ein/Aus, Modus, Soll, Temperaturen, Lüfter, Eco, Turbo, Leise außen,
    /// Leistung, Zähler); der Rest bleibt auf dem Standard von `ACState`.
    public func lastKnown() -> (state: ACState, at: Date)? {
        guard let r = db.lastRow() else { return nil }
        var s = ACState()
        s.power = r.on ?? false
        if let m = r.mode, let mode = OperationalMode.allCases.first(where: { $0.label == m }) { s.mode = mode }
        if let t = r.target { s.targetTemperature = t }
        s.indoorTemperature = r.indoor
        s.outdoorTemperature = s.power || r.outdoor != 10.0 ? r.outdoor : nil
        if let f = r.fan { s.fanSpeed = f }
        s.eco = r.eco ?? false
        s.turbo = r.turbo ?? false
        s.outSilent = r.outSilent
        s.powerWatts = r.watts
        s.totalEnergyKWh = r.totalKWh
        return (s, r.time)
    }

    /// Zählerstand zu Tagesbeginn aus dem Verlauf: die letzte Zeile höchstens 15 min vor Mitternacht gilt als Stand um
    /// Mitternacht; sonst die erste Zeile von heute (dann „seit HH:MM“). Nur Werte bis `notAbove` (Zähler steigt).
    func counterAtDayStart(now: Date, notAbove total: Double) -> (kWh: Double, since: Date, fromMidnight: Bool)? {
        let midnight = Calendar.current.startOfDay(for: now)
        if let b = db.counter(before: midnight), midnight.timeIntervalSince(b.time) <= 900, b.kWh <= total {
            return (b.kWh, midnight, true)
        }
        if let a = db.counter(atOrAfter: midnight, until: now), a.kWh <= total {
            return (a.kWh, a.time, a.time.timeIntervalSince(midnight) <= 900)
        }
        return nil
    }

    /// Ganzen Verlauf als CSV exportieren (Zeit in Ortszeit mit Abstand zu UTC).
    public func exportCSV(to url: URL) throws { try db.exportCSV(to: url) }

    /// Zeitraum exportieren; `readable` = Spaltennamen und Modus in der App-Sprache, Ortszeit, Dezimalzeichen des Formats (für Excel/Numbers).
    /// Kann im Hintergrund laufen (liest über eine eigene Verbindung): `Task.detached { try store.db.exportCSV(…) }`.
    public func exportCSV(to url: URL, from: Date?, until: Date?, readable: Bool) throws {
        try db.exportCSV(to: url, from: from, until: until, readable: readable)
    }

    /// Beim Beenden: zurückgestellte Zeilen schreiben, WAL-Datei in die Datenbank übernehmen (`ACController.stop()`).
    public func close() {
        db.flush()
        db.checkpoint()
    }
}
