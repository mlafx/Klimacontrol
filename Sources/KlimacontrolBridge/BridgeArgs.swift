import Foundation
import KlimacontrolCore

/// Fehler eines Befehls mit fertigem Text für die Oberfläche („Was ist passiert. Was tun. (Code)“).
struct CommandError: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

/// Ein JSON-Wert mit getrennten Booleans und Zahlen. Gelesen mit `JSONDecoder` statt `JSONSerialization`: Dort
/// kommen Booleans als `NSNumber` an (`true` wäre als Zahl 1, die Zahl 1 als `true` lesbar), und ob man sie
/// unterscheiden kann, hängt von der Plattform ab. `JSONDecoder` lehnt Zahl ↔ Boolean auf macOS und Windows gleich ab.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Parameter eines Befehls. Pflichtparameter werfen `CommandError`, wenn sie fehlen oder den falschen Typ haben –
/// nie still ein Standardwert. Booleans sind keine Zahlen und umgekehrt.
struct CommandArgs {
    let cmd: String
    let values: [String: JSONValue]

    init(cmd: String, values: [String: JSONValue]) {
        self.cmd = cmd
        self.values = values
    }

    /// Liest `{"cmd": "...", …}`; nil, wenn der Text kein Objekt mit Text in `cmd` ist.
    init?(json text: String) {
        guard let values = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)),
              case .string(let cmd)? = values["cmd"] else { return nil }
        self.init(cmd: cmd, values: values)
    }

    /// Schlüssel fehlt oder ist JSON-null.
    func absent(_ k: String) -> Bool { values[k] == nil || values[k] == .null }

    func bool(_ k: String) throws -> Bool {
        guard case .bool(let v)? = values[k] else { throw invalid(k, "an/aus") }
        return v
    }

    /// Wahlschalter mit Standard „aus“ (nur für reine Zusatzangaben wie `now`); falscher Typ ist trotzdem ein Fehler.
    func flag(_ k: String) throws -> Bool { absent(k) ? false : try bool(k) }

    /// Wie `flag`, aber mit Standard „an“.
    func flag(_ k: String, default value: Bool) throws -> Bool { absent(k) ? value : try bool(k) }

    func double(_ k: String) throws -> Double {
        guard case .number(let d)? = values[k], d.isFinite else { throw invalid(k, "Zahl") }
        return d
    }

    func int(_ k: String) throws -> Int {
        let d = try double(k)
        guard d == d.rounded(), abs(d) < 1e9 else { throw invalid(k, "ganze Zahl") }
        return Int(d)
    }

    func string(_ k: String) throws -> String {
        guard case .string(let s)? = values[k] else { throw invalid(k, "Text") }
        return s
    }

    func optionalString(_ k: String) throws -> String? { absent(k) ? nil : try string(k) }
    func optionalInt(_ k: String) throws -> Int? { absent(k) ? nil : try int(k) }
    func optionalDouble(_ k: String) throws -> Double? { absent(k) ? nil : try double(k) }
    func optionalDate(_ k: String) throws -> Date? { try optionalDouble(k).map(Date.init(timeIntervalSince1970:)) }

    /// JSON-Objekt als Daten (z. B. Teil-Darstellung für `Appearance.decode`).
    func object(_ k: String) throws -> Data {
        guard let v = values[k], case .object = v, let data = try? JSONEncoder().encode(v) else {
            throw invalid(k, "Objekt")
        }
        return data
    }

    /// Dateipfad: Pflicht, nicht leer.
    func path(_ k: String = "path") throws -> URL {
        guard case .string(let s)? = values[k], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError("Kein Dateiname angegeben. Bitte eine Datei auswählen. (path-missing)")
        }
        return URL(fileURLWithPath: s)
    }

    func invalid(_ k: String, _ expected: String) -> CommandError {
        CommandError("Befehl „\(cmd)“ unvollständig: Angabe „\(k)“ fehlt oder passt nicht (erwartet: \(expected)). "
                     + "Bitte die App neu starten; bleibt es, die aktuelle Version installieren. (param-\(k))")
    }
}

/// Zerlegt einen fertigen Meldungstext „… (code)“ in Text und Code (ohne Code: alles ist `what`).
func parsedMessage(_ text: String) -> UserMessage {
    guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else {
        return UserMessage(what: text, todo: "")
    }
    let code = String(text[open.upperBound..<text.index(before: text.endIndex)])
    guard !code.isEmpty, !code.contains(" ") else { return UserMessage(what: text, todo: "") }
    return UserMessage(what: String(text[..<open.lowerBound]), todo: "", code: code)
}

/// Meldung für einen Fehler aus Kern oder Dateisystem – Deutsch auch unter Windows (dort liefert
/// `localizedDescription` für Datei-Fehler Englisch).
func bridgeIssue(for error: any Error) -> UserMessage {
    if let e = error as? CommandError { return parsedMessage(e.text) }
    if error is DecodingError {
        return UserMessage(what: "Die Datei ist keine Klimacontrol-Sicherung oder beschädigt.",
                           todo: "Bitte eine andere Datei wählen.", code: "file-format")
    }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
        let code = "file-\(ns.code)"
        switch CocoaError.Code(rawValue: ns.code) {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return UserMessage(what: "Die Datei wurde nicht gefunden.", todo: "Bitte Ort und Namen prüfen.", code: code)
        case .fileReadNoPermission, .fileWriteNoPermission:
            return UserMessage(what: "Kein Zugriff auf diese Datei.", todo: "Bitte einen anderen Ordner wählen.", code: code)
        case .fileWriteOutOfSpace:
            return UserMessage(what: "Kein Speicherplatz mehr frei.",
                               todo: "Bitte Platz schaffen oder einen anderen Ort wählen.", code: code)
        case .fileReadCorruptFile:
            return UserMessage(what: "Die Datei ist beschädigt.", todo: "Bitte eine andere Datei wählen.", code: code)
        case .fileReadInvalidFileName, .fileWriteInvalidFileName:
            return UserMessage(what: "Der Dateiname ist ungültig.", todo: "Bitte einen anderen Namen wählen.", code: code)
        default:
            return UserMessage(what: "Die Datei ließ sich nicht lesen oder speichern.",
                               todo: "Bitte einen anderen Ort wählen.", code: code)
        }
    }
    if ns.domain == NSPOSIXErrorDomain {
        return UserMessage(what: "Die Datei ließ sich nicht lesen oder speichern.", todo: "Bitte einen anderen Ort wählen.",
                           code: "posix-\(ns.code)")
    }
    if let e = error as? any LocalizedError, let text = e.errorDescription { return parsedMessage(text) }
    return UserMessage(what: "Unerwarteter Fehler.", todo: "Bitte erneut versuchen.", code: "\(type(of: error))")
}

/// Fertiger Meldungstext zu `bridgeIssue(for:)`.
func bridgeMessage(for error: any Error) -> String { bridgeIssue(for: error).text }

/// Meldung „Verlauf exportieren“ gescheitert: eigener Satz, Rat und Code der Ursache (nicht ineinander verschachtelt).
func exportHistoryMessage(for error: any Error) -> String {
    let cause = bridgeIssue(for: error)
    return UserMessage(what: "Der Verlauf ließ sich nicht speichern.",
                       todo: cause.todo.isEmpty ? "Bitte einen anderen Ort wählen." : cause.todo,
                       code: cause.code ?? "export-failed").text
}
