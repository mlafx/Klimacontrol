import Foundation
import MideaKit

/// Ein gespeicherter Wert des Verlaufs. Zahlen bleiben ganz oder Kommazahl, wie sie gelesen wurden (Spaltentyp
/// NUMERIC) – so sieht der Export aus wie die Eingabe.
enum HistoryValue: Equatable, Sendable {
    case int(Int64)
    case real(Double)
    case text(String)

    static func integer(_ v: Int) -> HistoryValue { .int(Int64(v)) }

    /// Feld in `verlauf.csv` (Swift-Schreibweise: „21.5“, „19.0“).
    var csvField: String {
        switch self {
        case .int(let v): return "\(v)"
        case .real(let v): return "\(v)"
        case .text(let v): return v
        }
    }
}

/// Eine Spalte des Verlaufs. `HistoryColumn.all` ist die einzige Spaltentabelle: Kopfzeilen (technisch und lesbar),
/// SQL-Schema, Export und Import leiten sich daraus ab. Reihenfolge = Reihenfolge in Datei und Tabelle; neue Spalten
/// nur hinten anhängen (eine geänderte Kopfzeile legt `verlauf.csv` beiseite, die Tabelle bekommt die Spalte dazu).
struct HistoryColumn: Sendable {
    enum Kind: Sendable {
        /// Unix-Sekunden in der Datenbank, ISO 8601 bzw. Ortszeit in CSV-Dateien.
        case time
        /// Zahl oder Ein/Aus (1/0); im lesbaren Export mit Dezimalkomma.
        case number
        /// Text (Modus), unverändert.
        case text
    }

    let name: String
    let label: String
    let unit: String?
    let kind: Kind
    /// Wert aus Zustand und Diagnose (nil = unbekannt).
    let read: @Sendable (ACState, Diagnostics) -> HistoryValue?

    /// Spaltenname im lesbaren Export, z. B. „Leistung (W)“.
    var readableName: String { unit.map { "\(label) (\($0))" } ?? label }

    /// Spaltendefinition für `CREATE TABLE`/`ALTER TABLE`. NUMERIC: ganze Zahlen bleiben ganz, Kommazahlen Kommazahlen.
    var sqlDefinition: String {
        switch kind {
        case .time: return "\(name) INTEGER PRIMARY KEY"
        case .number: return "\(name) NUMERIC"
        case .text: return "\(name) TEXT"
        }
    }

    /// CSV-Feld → Wert. Leer = unbekannt, Unlesbares = unbekannt (nie 0). Dezimalkomma wird wie ein Punkt gelesen.
    func parse(_ field: String) -> HistoryValue? {
        let f = field.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return nil }
        if kind == .text { return .text(f) }
        if let v = Int64(f) { return .int(v) }
        return Double(f.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? .real($0) : nil }
    }

    /// Feld im Export aus dem Text, den SQLite für den gespeicherten Wert liefert.
    func exportField(_ sqliteText: String, readable: Bool) -> String {
        readable && kind == .number ? sqliteText.replacingOccurrences(of: ".", with: ",") : sqliteText
    }
}

extension HistoryColumn {
    static let time = HistoryColumn(name: "zeit", label: "Zeit", unit: "Ortszeit", kind: .time) { _, _ in nil }

    /// Wertespalten (ohne Zeit), in der Reihenfolge von AGENTS.md Anhang B.
    static let data: [HistoryColumn] = [
        flag("ein", "Eingeschaltet") { s, _ in s.power },
        HistoryColumn(name: "modus", label: "Modus", unit: nil, kind: .text) { s, _ in .text(s.mode.label) },
        real("soll_c", "Soll", "°C") { s, _ in s.targetTemperature },
        real("innen_c", "Innen", "°C") { s, _ in s.indoorTemperature },
        real("aussen_c", "Außen", "°C") { s, _ in s.outdoorTemperature },
        int("luefter", "Lüfter", "%") { s, _ in s.fanSpeed },
        flag("eco", "Eco") { s, _ in s.eco },
        flag("turbo", "Turbo") { s, _ in s.turbo },
        flag("aussen_leise", "Außen leise") { s, _ in s.outSilent },
        real("leistung_w", "Leistung", "W") { s, _ in s.powerWatts },
        real("gesamt_kwh", "Zähler gesamt", "kWh") { s, _ in s.totalEnergyKWh },
        int("verdichter_hz", "Verdichter", "Hz") { _, d in d.compressorHz },
        int("verdichter_soll_hz", "Verdichter Soll", "Hz") { _, d in d.compressorTargetHz },
        int("strom_a", "Strom", "A") { _, d in d.currentA },
        int("spannung_v", "Spannung", "V") { _, d in d.voltageV },
        int("verdichter_w", "Verdichter", "W") { _, d in d.compressorPowerW },
        real("t1", "T1 Innenluft", "°C") { _, d in d.t1IndoorAir },
        real("t2", "T2 Wärmetauscher innen", "°C") { _, d in d.t2IndoorCoil },
        real("t3", "T3 Wärmetauscher außen", "°C") { _, d in d.t3OutdoorCoil },
        real("t4", "T4 Außenluft", "°C") { _, d in d.t4OutdoorAir },
        int("tp", "Tp Heißgas", "°C") { _, d in d.tpDischarge },
        int("eev", "Expansionsventil", "Schritte") { _, d in d.eevOpening },
        int("luefter_innen_upm", "Lüfter innen", "U/min") { _, d in d.indoorFanRpm },
        int("luefter_aussen_upm", "Lüfter außen", "U/min") { _, d in d.outdoorFanRpm },
        flag("kondensatpumpe", "Kondensatpumpe") { _, d in d.condensatePump },
        flag("abtauen", "Abtauen") { _, d in d.defrost },
        int("zaehler_roh", "Zähler roh", nil) { _, d in d.energyCounterRaw },
    ]

    /// Alle Spalten, Zeit zuerst.
    static let all = [time] + data

    private static func real(_ name: String, _ label: String, _ unit: String,
                             _ value: @escaping @Sendable (ACState, Diagnostics) -> Double?) -> HistoryColumn {
        HistoryColumn(name: name, label: label, unit: unit, kind: .number) { value($0, $1).map(HistoryValue.real) }
    }

    private static func int(_ name: String, _ label: String, _ unit: String?,
                            _ value: @escaping @Sendable (ACState, Diagnostics) -> Int?) -> HistoryColumn {
        HistoryColumn(name: name, label: label, unit: unit, kind: .number) { value($0, $1).map(HistoryValue.integer) }
    }

    private static func flag(_ name: String, _ label: String,
                             _ value: @escaping @Sendable (ACState, Diagnostics) -> Bool?) -> HistoryColumn {
        HistoryColumn(name: name, label: label, unit: "1/0", kind: .number) { value($0, $1).map { .int($0 ? 1 : 0) } }
    }
}

/// Eine Zeile des Verlaufs: Zeit und ein Wert je Spalte aus `HistoryColumn.data` (nil = unbekannt).
struct HistoryRow: Equatable, Sendable {
    var time: Date
    var values: [HistoryValue?]

    init(time: Date, values: [HistoryValue?]) {
        self.time = time
        let n = HistoryColumn.data.count
        self.values = values.count == n ? values : Array(values.prefix(n)) + Array(repeating: nil, count: max(0, n - values.count))
    }

    /// Zeile aus einer Abfrage.
    init(state: ACState, diagnostics: Diagnostics, time: Date) {
        self.init(time: time, values: HistoryColumn.data.map { $0.read(state, diagnostics) })
    }

    /// Zeile aus CSV-Feldern in der Reihenfolge von `HistoryColumn.all`; Feld 0 (Zeit) zählt nicht, maßgeblich ist `time`.
    /// Fehlende Felder sind unbekannt.
    init(time: Date, fields: [String]) {
        self.init(time: time, values: HistoryColumn.data.enumerated().map { i, column in
            i + 1 < fields.count ? column.parse(fields[i + 1]) : nil
        })
    }

    /// Felder für `verlauf.csv` in der Reihenfolge von `HistoryColumn.all` (leer = unbekannt).
    var fields: [String] { [HistoryLog.isoString(time)] + values.map { $0?.csvField ?? "" } }

    /// Wert einer Spalte nach Namen (nil = unbekannt oder keine Wertespalte).
    subscript(name: String) -> HistoryValue? {
        guard let i = HistoryColumn.data.firstIndex(where: { $0.name == name }) else { return nil }
        return values[i]
    }

    /// Bindewerte für SQLite: Zeit als ganze Unix-Sekunden, dann die Werte. Nicht endliche Zahlen werden NULL.
    var bindings: [HistoryValue?] {
        [.integer(HistoryDB.unix(time))] + values.map { v -> HistoryValue? in
            if case .real(let d) = v, !d.isFinite { return nil }
            return v
        }
    }
}
