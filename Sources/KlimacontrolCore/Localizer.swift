import Foundation
import MideaKit
import Synchronization

/// Sprache der Oberfläche.
public enum AppLanguage: String, CaseIterable, Sendable {
    case de, en
}

/// Gespeicherte Sprachwahl (Windows: `SettingsKey.language`). Wirkt erst nach einem Neustart.
public enum LanguageChoice: String, CaseIterable, Sendable {
    case system, de, en

    /// Unbekannt oder nil → `.system`.
    public init(stored: String?) {
        self = stored.flatMap(LanguageChoice.init(rawValue:)) ?? .system
    }

    /// „Systemsprache“, „Deutsch“, „English“ (aus dem Katalog).
    public var label: String {
        switch self {
        case .system: L.Settings.Language.system
        case .de: L.Settings.Language.german
        case .en: L.Settings.Language.english
        }
    }

    /// `.de`/`.en` fest, `.system` über `Localizer.resolve(preferred:)`.
    public func resolve(preferred: [String]) -> AppLanguage {
        switch self {
        case .system: Localizer.resolve(preferred: preferred)
        case .de: .de
        case .en: .en
        }
    }
}

/// Ein Wert des Katalogs: Text oder Mehrzahl-Fälle („one“, „other“ …). JSON: Zeichenkette bzw. Objekt.
public enum LocalizedValue: Equatable, Sendable, Encodable {
    case text(String)
    case plural([String: String])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .plural(let cases): try container.encode(cases)
        }
    }
}

/// Texte der Oberfläche in der Sprache des Prozesses. Die Sprache wird einmal beim Start festgelegt
/// (Mac: `Bundle.main.preferredLocalizations`, Windows: `kc_set_locale`); ohne Festlegung gilt Deutsch.
public enum Localizer {
    private struct State {
        var language = AppLanguage.de
        var pseudo = false
        var configured = false
    }

    private static let state = Mutex(State())

    public static var language: AppLanguage { state.withLock { $0.language } }
    public static var isPseudo: Bool { state.withLock { $0.pseudo } }
    public static var isConfigured: Bool { state.withLock { $0.configured } }

    /// Legt Sprache (und Pseudo-Sprache) fest. Nur der erste Aufruf zählt; spätere liefern false und ändern nichts.
    @discardableResult
    public static func configure(_ language: AppLanguage, pseudo: Bool = Localizer.pseudoRequested) -> Bool {
        let accepted = state.withLock { s -> Bool in
            guard !s.configured else { return false }
            s = State(language: language, pseudo: pseudo, configured: true)
            return true
        }
        if accepted { AppLog.write("Sprache: \(language.rawValue)" + (pseudo ? " (Pseudo)" : "")) }
        return accepted
    }

    /// Systemsprachen → App-Sprache. Nur das erste Element zählt: "de", "de-…", "de_…" (Groß/Klein egal) → `.de`,
    /// alles andere und eine leere Liste → `.en`.
    public static func resolve(preferred: [String]) -> AppLanguage {
        guard let first = preferred.first?.lowercased() else { return .en }
        return first == "de" || first.hasPrefix("de-") || first.hasPrefix("de_") ? .de : .en
    }

    /// `KLIMACONTROL_PSEUDO=1` in der Umgebung (AGENTS.md §13.2).
    public static var pseudoRequested: Bool { ProcessInfo.processInfo.environment["KLIMACONTROL_PSEUDO"] == "1" }

    /// Text zu `key` in der aktiven Sprache (Rückfall Englisch, dann der Schlüssel selbst), Platzhalter `{name}` aus `args`.
    public static func text(_ key: String, _ args: [String: String] = [:]) -> String {
        let (lang, pseudo) = current
        switch resolved(key, lang, pseudo) {
        case .text(let s): return fill(s, args)
        case .plural(let cases): return fill(cases["other"] ?? cases.values.sorted().first ?? key, args)
        case nil: return key
        }
    }

    /// Text in einer bestimmten Sprache, unabhängig von der Sprache des Prozesses (z. B. CSV-Import beider Sprachen).
    /// Rückfall Englisch, dann der Schlüssel; keine Pseudo-Sprache.
    public static func text(_ key: String, language: AppLanguage, _ args: [String: String] = [:]) -> String {
        switch catalog.value(key, language) {
        case .text(let s): return fill(s, args)
        case .plural(let cases): return fill(cases["other"] ?? cases.values.sorted().first ?? key, args)
        case nil: return key
        }
    }

    /// Mehrzahl: Fall `one` bei count == 1, sonst `other` (fehlt `one`: `other`); `{count}` = `Fmt.num(Double(count), 0)`.
    public static func plural(_ key: String, count: Int, _ args: [String: String] = [:]) -> String {
        let (lang, pseudo) = current
        var all = args
        all["count"] = Fmt.num(Double(count), 0)
        switch resolved(key, lang, pseudo) {
        case .text(let s): return fill(s, all)
        case .plural(let cases):
            let template = (count == 1 ? cases["one"] : nil) ?? cases["other"] ?? key
            return fill(template, all)
        case nil: return key
        }
    }

    /// Alle Schlüssel mit Wert der aktiven Sprache (Rückfall und Pseudo schon angewandt) – für `kc_strings_json`.
    public static func table() -> [String: LocalizedValue] {
        let (lang, pseudo) = current
        var result: [String: LocalizedValue] = [:]
        for key in catalog.keys {
            if let v = resolved(key, lang, pseudo) { result[key] = v }
        }
        return result
    }

    // MARK: - intern

    static let catalog: StringTable = {
        do {
            return try StringTable(catalogJSON: StringsData.catalog)
        } catch {
            AppLog.error("Textkatalog nicht lesbar: \(error)")
            return StringTable.empty
        }
    }()

    private static var current: (AppLanguage, Bool) { state.withLock { ($0.language, $0.pseudo) } }

    private static func resolved(_ key: String, _ language: AppLanguage, _ pseudo: Bool) -> LocalizedValue? {
        guard let value = catalog.value(key, pseudo ? .en : language) else { return nil }
        guard pseudo else { return value }
        switch value {
        case .text(let s): return .text(Self.pseudo(s))
        case .plural(let cases): return .plural(cases.mapValues { Self.pseudo($0) })
        }
    }

    /// Führt `body` mit dieser Sprache aus und stellt danach den vorigen Zustand wieder her (auch `isConfigured`).
    static func withLanguage<T>(_ language: AppLanguage, pseudo: Bool = false, _ body: () throws -> T) rethrows -> T {
        let saved = state.withLock { s -> State in
            let old = s
            s = State(language: language, pseudo: pseudo, configured: old.configured)
            return old
        }
        defer { state.withLock { $0 = saved } }
        return try body()
    }

    /// Zurück auf „nicht festgelegt, Deutsch, ohne Pseudo“.
    static func resetForTesting() {
        state.withLock { $0 = State() }
    }

    private static let pseudoMap: [Character: Character] = [
        "a": "å", "e": "é", "i": "ï", "o": "ö", "u": "ü", "y": "ý", "n": "ñ", "c": "ç",
        "A": "Å", "E": "É", "I": "Ï", "O": "Ö", "U": "Ü", "Y": "Ý", "N": "Ñ", "C": "Ç",
    ]

    /// Pseudo-Umformung: Akzente, Rand und Verlängerung; Platzhalter bleiben unverändert.
    static func pseudo(_ text: String) -> String {
        var out = ""
        var visible = 0
        var inPlaceholder = false
        for ch in text {
            if inPlaceholder {
                out.append(ch)
                if ch == "}" { inPlaceholder = false }
            } else if ch == "{" {
                inPlaceholder = true
                out.append(ch)
            } else {
                out.append(pseudoMap[ch] ?? ch)
                visible += 1
            }
        }
        return "⟦" + out + String(repeating: "~", count: max(1, visible * 3 / 10)) + "⟧"
    }

    /// `{name}` durch `args[name]` ersetzen; unbekannte Platzhalter bleiben stehen, überzählige `args` zählen nicht.
    static func fill(_ template: String, _ args: [String: String]) -> String {
        guard !args.isEmpty, template.contains("{") else { return template }
        var out = ""
        var index = template.startIndex
        while index < template.endIndex {
            let ch = template[index]
            if ch == "{", let close = template[index...].firstIndex(of: "}") {
                let name = String(template[template.index(after: index)..<close])
                if let value = args[name] {
                    out += value
                    index = template.index(after: close)
                    continue
                }
            }
            out.append(ch)
            index = template.index(after: index)
        }
        return out
    }
}

/// Eingebetteter Katalog (Inhalt in StringsData.swift).
enum StringsData {}

/// Der dekodierte Katalog: je Sprache Schlüssel → Wert.
struct StringTable: Sendable {
    private struct Unit: Decodable { let value: String }
    private struct Localization: Decodable {
        struct Plural: Decodable { let plural: [String: PluralCase] }
        struct PluralCase: Decodable { let stringUnit: Unit }
        let stringUnit: Unit?
        let variations: Plural?
    }
    private struct Entry: Decodable { let localizations: [String: Localization]? }
    private struct File: Decodable { let strings: [String: Entry] }

    static let empty = StringTable(keys: [], values: [:])

    let keys: [String]
    private let values: [String: [AppLanguage: LocalizedValue]]

    private init(keys: [String], values: [String: [AppLanguage: LocalizedValue]]) {
        self.keys = keys
        self.values = values
    }

    /// Wirft bei unlesbarem JSON.
    init(catalogJSON: String) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(catalogJSON.utf8))
        var values: [String: [AppLanguage: LocalizedValue]] = [:]
        for (key, entry) in file.strings {
            var perLanguage: [AppLanguage: LocalizedValue] = [:]
            for language in AppLanguage.allCases {
                guard let loc = entry.localizations?[language.rawValue] else { continue }
                if let unit = loc.stringUnit {
                    perLanguage[language] = .text(unit.value)
                } else if let plural = loc.variations?.plural {
                    perLanguage[language] = .plural(plural.mapValues(\.stringUnit.value))
                }
            }
            values[key] = perLanguage
        }
        self.init(keys: values.keys.sorted(), values: values)
    }

    /// Wert genau dieser Sprache, ohne Rückfall.
    func raw(_ key: String, _ language: AppLanguage) -> LocalizedValue? {
        values[key]?[language]
    }

    /// Wert mit Rückfall auf Englisch; nil, wenn der Schlüssel unbekannt ist.
    func value(_ key: String, _ language: AppLanguage) -> LocalizedValue? {
        raw(key, language) ?? raw(key, .en)
    }
}
