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
    let kind: Kind
    /// Wert aus Zustand und Diagnose (nil = unbekannt).
    let read: @Sendable (ACState, Diagnostics) -> HistoryValue?

    /// Katalog-Schlüssel des lesbaren Spaltennamens (`soll_c` → `history.column.sollC`).
    private var catalogKey: String {
        let parts = name.split(separator: "_").map(String.init)
        return "history.column." + (parts.first ?? name) + parts.dropFirst().map(\.capitalized).joined()
    }

    /// Spaltenname im lesbaren Export in der Sprache der Oberfläche, z. B. „Leistung (W)“ / „Power (W)“.
    var readableName: String { Localizer.text(catalogKey) }

    func readableName(in language: AppLanguage) -> String { Localizer.text(catalogKey, language: language) }

    /// Spaltendefinition für `CREATE TABLE`/`ALTER TABLE`. NUMERIC: ganze Zahlen bleiben ganz, Kommazahlen Kommazahlen.
    var sqlDefinition: String {
        switch kind {
        case .time: return "\(name) INTEGER PRIMARY KEY"
        case .number: return "\(name) NUMERIC"
        case .text: return "\(name) TEXT"
        }
    }

    /// CSV-Feld → Wert. Leer = unbekannt, Unlesbares = unbekannt (nie 0). Dezimalkomma wird wie ein Punkt gelesen.
    /// Ein Modus in der Sprache der Oberfläche (deutsch oder englisch) wird zum deutschen Namen der Datenbank.
    func parse(_ field: String) -> HistoryValue? {
        let f = field.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return nil }
        if kind == .text { return .text(name == "modus" ? HistoryColumn.modeLabel(fromTitle: f) : f) }
        if let v = Int64(f) { return .int(v) }
        return Double(f.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? .real($0) : nil }
    }

    /// Wie der lesbare Export Zahlen und Modus schreibt.
    struct ReadableStyle: Sendable {
        let decimal: String
        let modeTitles: [String: String]

        /// Nur „.“ oder „,“ (der Import liest nur diese); jedes andere Dezimalzeichen wird zu „,“.
        init(profile: FormatProfile = .current) {
            let d = profile.decimalSeparator
            decimal = d == "." ? "." : ","
            modeTitles = Dictionary(uniqueKeysWithValues: OperationalMode.allCases.map { ($0.label, $0.title) })
        }
    }

    /// Feld im Export aus dem Text, den SQLite für den gespeicherten Wert liefert.
    func exportField(_ sqliteText: String, style: ReadableStyle?) -> String {
        guard let style else { return sqliteText }
        switch kind {
        case .number: return style.decimal == "." ? sqliteText : sqliteText.replacingOccurrences(of: ".", with: style.decimal)
        case .text: return name == "modus" ? style.modeTitles[sqliteText] ?? sqliteText : sqliteText
        case .time: return sqliteText
        }
    }

    /// Deutscher Modusname zu einem Anzeigenamen in einer der beiden Sprachen; Unbekanntes bleibt unverändert.
    static func modeLabel(fromTitle text: String) -> String {
        for language in AppLanguage.allCases {
            for mode in OperationalMode.allCases
            where Localizer.text("mode.\(modeKey(mode))", language: language).caseInsensitiveCompare(text) == .orderedSame {
                return mode.label
            }
        }
        return text
    }

    private static func modeKey(_ mode: OperationalMode) -> String {
        switch mode {
        case .auto: "auto"
        case .cool: "cool"
        case .dry: "dry"
        case .heat: "heat"
        case .fan: "fan"
        }
    }
}

extension HistoryColumn {
    static let time = HistoryColumn(name: "zeit", kind: .time) { _, _ in nil }

    /// Wertespalten (ohne Zeit), in der Reihenfolge von AGENTS.md Anhang B.
    static let data: [HistoryColumn] = [
        flag("ein") { s, _ in s.power },
        HistoryColumn(name: "modus", kind: .text) { s, _ in .text(s.mode.label) },
        real("soll_c") { s, _ in s.targetTemperature },
        real("innen_c") { s, _ in s.indoorTemperature },
        real("aussen_c") { s, _ in s.outdoorTemperature },
        int("luefter") { s, _ in s.fanSpeed },
        flag("eco") { s, _ in s.eco },
        flag("turbo") { s, _ in s.turbo },
        flag("aussen_leise") { s, _ in s.outSilent },
        real("leistung_w") { s, _ in s.powerWatts },
        real("gesamt_kwh") { s, _ in s.totalEnergyKWh },
        int("verdichter_hz") { _, d in d.compressorHz },
        int("verdichter_soll_hz") { _, d in d.compressorTargetHz },
        int("strom_a") { _, d in d.currentA },
        int("spannung_v") { _, d in d.voltageV },
        int("verdichter_w") { _, d in d.compressorPowerW },
        real("t1") { _, d in d.t1IndoorAir },
        real("t2") { _, d in d.t2IndoorCoil },
        real("t3") { _, d in d.t3OutdoorCoil },
        real("t4") { _, d in d.t4OutdoorAir },
        int("tp") { _, d in d.tpDischarge },
        int("eev") { _, d in d.eevOpening },
        int("luefter_innen_upm") { _, d in d.indoorFanRpm },
        int("luefter_aussen_upm") { _, d in d.outdoorFanRpm },
        flag("kondensatpumpe") { _, d in d.condensatePump },
        flag("abtauen") { _, d in d.defrost },
        int("zaehler_roh") { _, d in d.energyCounterRaw },
        int("fehlercode") { s, _ in s.errorCode },
    ]

    /// Alle Spalten, Zeit zuerst.
    static let all = [time] + data

    private static func real(_ name: String,
                             _ value: @escaping @Sendable (ACState, Diagnostics) -> Double?) -> HistoryColumn {
        HistoryColumn(name: name, kind: .number) { value($0, $1).map(HistoryValue.real) }
    }

    private static func int(_ name: String,
                            _ value: @escaping @Sendable (ACState, Diagnostics) -> Int?) -> HistoryColumn {
        HistoryColumn(name: name, kind: .number) { value($0, $1).map(HistoryValue.integer) }
    }

    private static func flag(_ name: String,
                             _ value: @escaping @Sendable (ACState, Diagnostics) -> Bool?) -> HistoryColumn {
        HistoryColumn(name: name, kind: .number) { value($0, $1).map { .int($0 ? 1 : 0) } }
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
