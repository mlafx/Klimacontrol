import Foundation

/// Prüft die Einstellungsdatei vor dem ersten Zugriff auf `UserDefaults.standard` (Windows:
/// `%LOCALAPPDATA%\<Name der exe>.plist`). swift-corelibs-foundation liest eine unlesbare Datei still als leer und
/// überschreibt sie beim nächsten Speichern; darum wird sie vorher beiseitegelegt (`<Name>.defekt-<Zeit>`).
public enum SettingsFileCheck {
    public enum Outcome: Equatable, Sendable {
        /// Datei fehlt (erster Start).
        case missing
        /// Datei ist leer (0 Byte); Foundation beginnt ebenfalls leer, es geht nichts verloren.
        case empty
        /// Property List mit Dictionary als oberstem Objekt; Datei unverändert.
        case valid
        /// Datei ließ sich nicht lesen (z. B. gesperrt); unverändert gelassen.
        case readFailed(error: String)
        /// Defekt und umbenannt; `fileName` = neuer Name im selben Ordner.
        case movedAside(fileName: String)
        /// Defekt, Umbenennen gescheitert, aber als Kopie gesichert; das Original bleibt liegen.
        case copiedAside(fileName: String)
        /// Defekt und weder umbenannt noch kopiert; Foundation wird die Datei beim nächsten Speichern überschreiben.
        case asideFailed(error: String)

        /// Name der gesicherten alten Datei, falls es eine gibt.
        public var asideFileName: String? {
            switch self {
            case .movedAside(let name), .copiedAside(let name): return name
            default: return nil
            }
        }

        /// Die Einstellungen beginnen wegen einer defekten Datei leer (Hinweis an den Nutzer nötig).
        public var settingsWereReset: Bool {
            switch self {
            case .movedAside, .copiedAside, .asideFailed: return true
            default: return false
            }
        }
    }

    /// Prüft die Datei und legt sie beiseite, wenn Foundation sie nicht als Dictionary lesen könnte. Schreibt nicht ins
    /// Protokoll: Die Prüfung läuft vor der Festlegung der Sprache, die Zeile schreibt `ACController.reportSettingsFileCheck`.
    public static func run(fileAt url: URL, now: Date = Date()) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .readFailed(error: error.localizedDescription)
        }
        if data.isEmpty { return .empty }
        if isSettingsDictionary(data) { return .valid }

        let name = asideName(for: url, now: now)
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fm.moveItem(at: url, to: target)
            return .movedAside(fileName: name)
        } catch {
            // Unter Windows scheitert das Umbenennen z. B., wenn ein anderes Programm die Datei offen hält; eine Kopie
            // bewahrt den Inhalt trotzdem vor dem Überschreiben.
            if (try? fm.copyItem(at: url, to: target)) != nil { return .copiedAside(fileName: name) }
            return .asideFailed(error: error.localizedDescription)
        }
    }

    /// So liest swift-corelibs-foundation die Datei: Property List (XML oder binär), oberstes Objekt ein Dictionary.
    public static func isSettingsDictionary(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return false
        }
        return plist is [String: Any]
    }

    /// `<Name>.defekt-<ISO-Zeit in UTC ohne Doppelpunkte>`; ist der Name schon vergeben, mit `-2`, `-3` … dahinter.
    public static func asideName(for url: URL, now: Date) -> String {
        // ISO8601DateFormatter rechnet ohne Angabe in UTC (nie TimeZone.current, Abschnitt 12 in AGENTS.md).
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let base = "\(url.lastPathComponent).defekt-\(stamp)"
        let dir = url.deletingLastPathComponent()
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    /// Ort der Einstellungsdatei unter Windows, wie swift-corelibs-foundation ihn bildet: Ordner „Lokale Anwendungsdaten“
    /// (FOLDERID_LocalAppData) plus Dateiname der laufenden exe mit Endung plus „.plist“.
    public static func windowsSettingsURL(localAppData: String, executablePath: String) -> URL {
        let exe = executablePath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? executablePath
        return URL(fileURLWithPath: localAppData, isDirectory: true).appendingPathComponent(exe + ".plist")
    }
}
