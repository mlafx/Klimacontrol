import Foundation
import Synchronization

/// Texte für Protokoll und Fehlerdetails. MideaKit kennt den Katalog nicht: Der Kern installiert einen Übersetzer,
/// ohne ihn gilt der deutsche Text im Code. Schlüssel und deutscher Text müssen mit dem Katalog übereinstimmen
/// (`LogTextTests`).
public enum LogText {
    /// Liefert den Text zum Schlüssel in der aktiven Sprache mit eingesetzten Platzhaltern, nil bei unbekanntem Schlüssel.
    public typealias Translator = @Sendable (_ key: String, _ args: [String: String]) -> String?

    private static let translator = Mutex<Translator?>(nil)

    public static func install(_ translate: Translator?) {
        translator.withLock { $0 = translate }
    }

    /// `{name}` in `german` bzw. im übersetzten Text wird durch `args["name"]` ersetzt.
    public static func t(_ key: String, _ german: String, _ args: [String: String] = [:]) -> String {
        if let translate = translator.withLock({ $0 }), let text = translate(key, args) { return text }
        return fill(german, args)
    }

    public static func fill(_ template: String, _ args: [String: String]) -> String {
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
