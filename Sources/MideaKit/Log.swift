import Foundation
import Synchronization

/// Erkennt Testläufe (XCTest, swift-testing, `swift test`), damit Protokoll und Schlüsselbund dort nie echt sind.
enum TestEnvironment {
    static let isRunningTests: Bool = {
        let p = ProcessInfo.processInfo
        let name = p.processName
        if name.hasSuffix("xctest") || name.contains("PackageTests") || name == "swiftpm-testing-helper" { return true }
        // Windows: SwiftPM startet die Tests als <Ziel>-test-runner(.exe).
        let lower = name.lowercased()
        if lower.hasSuffix("-test-runner") || lower.hasSuffix("-test-runner.exe") { return true }
        let env = p.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil || env["SWIFT_TESTING_ENABLED"] != nil { return true }
        return p.arguments.contains { $0.hasSuffix(".xctest") || $0.contains("PackageTests") }
    }()
}

/// Protokoll in ~/Library/Application Support/Klimacontrol/klimacontrol.log (rotiert bei 5 MB, 2 Sicherungen).
/// Nie Passwörter, Token oder Schlüssel hineinschreiben – nur Schritte, Adressen und Fehlermeldungen.
/// Rahmen-Hex und Verbindungsschritte nur mit `debugEnabled` (Standard aus), damit ein Tag ins Protokoll passt.
public enum AppLog {
    /// Aktuelle Protokolldatei. Ziel in dieser Reihenfolge: `redirect(to:)`, Umgebungsvariable
    /// `KLIMACONTROL_LOG_DIR`, in Testläufen ein Temp-Ordner, sonst der Ordner von device.json.
    public static var url: URL { currentURL.withLock { $0 } }
    private static let currentURL = Mutex<URL>(defaultURL())

    static func defaultURL() -> URL {
        let env = ProcessInfo.processInfo.environment["KLIMACONTROL_LOG_DIR"] ?? ""
        let dir: URL
        if !env.isEmpty {
            dir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else if TestEnvironment.isRunningTests {
            // Unter `swift test` nicht ins echte Protokoll schreiben (verfälschte sonst die Fehlersuche).
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("KlimacontrolTests")
        } else {
            dir = DeviceConfig.defaultURL.deletingLastPathComponent()
        }
        return dir.appendingPathComponent("klimacontrol.log")
    }

    /// Protokoll in einen anderen Ordner umlenken (Tests, Werkzeuge); `nil` = zurück zum Standard.
    /// Wartet, bis alle bisherigen Zeilen geschrieben sind, und schließt die alte Datei.
    public static func redirect(to directory: URL?) {
        queue.sync {
            closeHandle()
            let target = directory.map { $0.appendingPathComponent("klimacontrol.log") } ?? defaultURL()
            currentURL.withLock { $0 = target }
        }
    }

    private static let queue = DispatchQueue(label: "klimacontrol.log")
    private static let maxBytes = 5_000_000

    /// Debug-Protokoll (alle Rahmen als Hex, Cloud-Anfragen, Verbindungsschritte). Standard aus, sonst überschreibt
    /// die Rotation den Tag nach wenigen Stunden. Einmal aus UserDefaults gelesen, danach im Speicher (jede
    /// Rahmenzeile fragt ihn ab); der Setter schreibt beides.
    public static var debugEnabled: Bool {
        get {
            debugCache.withLock { cache in
                if let v = cache { return v }
                let v = UserDefaults.standard.object(forKey: "debugLog") as? Bool ?? false
                cache = v
                return v
            }
        }
        set {
            debugCache.withLock { $0 = newValue }
            UserDefaults.standard.set(newValue, forKey: "debugLog")
            #if os(Windows)
            _ = UserDefaults.standard.synchronize()  // swift-corelibs-foundation speichert sonst nicht
            #endif
        }
    }
    private static let debugCache = Mutex<Bool?>(nil)

    public static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        write(message(), "DEBUG")
    }

    /// Geheimnisse in JSON/Text schwärzen (Token, Schlüssel, Passwörter, Sitzungsdaten).
    /// Schlüsselnamen werden ohne Rücksicht auf Groß-/Kleinschreibung erkannt und in der Schreibweise der Liste
    /// ausgegeben (`"Token": "x"` → `"token":"***"`).
    public static func redact(_ text: String) -> String {
        // Schneller Vorabtest: beide Muster brauchen `:` (JSON) bzw. `=` (Formular).
        guard text.utf8.contains(where: { $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "=") }) else { return text }
        var out = replace(redactObject, in: text, keyGroup: 1) { _, k in "\"\(k)\":\"***\"" }
        out = replace(redactJSON, in: out, keyGroup: 1) { _, k in "\"\(k)\":\"***\"" }
        // Formulardaten (NetHome Plus): password=…&sessionId=…
        out = replace(redactForm, in: out, keyGroup: 2) { lead, k in "\(lead)\(k)=***" }
        return out
    }

    /// Bekannte geheime bzw. persönliche Felder (camelCase und snake_case). Werte als Text **und** als Zahl.
    private static let redactKeys = ["token", "key", "accessToken", "sessionId", "password", "iampwd", "pushToken",
                                     "refreshToken", "loginId", "loginAccount", "randomData", "tokenPwd", "secretKey",
                                     "access_token", "refresh_token", "session_id", "random_data", "login_id",
                                     "email", "mobile", "phone", "phoneNumber", "uid", "userId", "user_id", "accountId",
                                     "nickName", "nick_name", "userName", "user_name", "dataKey", "aesKey", "sign",
                                     "sn", "homeName", "homegroupId", "des"]
    /// Ganze Objekte mit Personendaten (eine Ebene tief) – z. B. `"userInfo":{…}` aus der Anmeldung.
    private static let redactObjects = ["userInfo", "user_info", "userinfo"]
    private static let redactCanonical: [String: String] =
        Dictionary((redactKeys + redactObjects).map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    /// Einmal übersetzt; NSRegularExpression ist unveränderlich und threadsicher beim Suchen.
    private static let redactJSON = try! NSRegularExpression(
        pattern: "\"(\(redactKeys.joined(separator: "|")))\"\\s*:\\s*(\"[^\"]*\"|-?[0-9][0-9.eE+-]*)",
        options: [.caseInsensitive])
    private static let redactObject = try! NSRegularExpression(
        pattern: "\"(\(redactObjects.joined(separator: "|")))\"\\s*:\\s*\\{[^{}]*\\}", options: [.caseInsensitive])
    private static let redactForm = try! NSRegularExpression(
        pattern: "(^|&)(\(redactKeys.joined(separator: "|")))=[^&]*", options: [.caseInsensitive])

    /// Ersetzt jeden Treffer; `make` bekommt Gruppe 1 (nur fürs Formular: Anfang/`&`) und den Schlüssel in
    /// Listenschreibweise.
    private static func replace(_ re: NSRegularExpression, in s: String, keyGroup: Int,
                                _ make: (String, String) -> String) -> String {
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard !matches.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var last = s.startIndex
        for m in matches {
            guard let r = Range(m.range, in: s), let kr = Range(m.range(at: keyGroup), in: s) else { continue }
            let lead = keyGroup > 1 ? Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? "" : ""
            let key = String(s[kr])
            out += s[last..<r.lowerBound]
            out += make(lead, redactCanonical[key.lowercased()] ?? key)
            last = r.upperBound
        }
        out += s[last...]
        return out
    }

    private static let timeFormat = Date.ISO8601FormatStyle()
    // Nur auf `queue` benutzt: offene Datei und wann sie zuletzt neu geöffnet wurde.
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var openedAt = Date.distantPast
    /// Die Datei bleibt offen, wird aber spätestens nach so vielen Sekunden neu geöffnet – falls sie von außen
    /// gelöscht oder von einem anderen Prozess rotiert wurde, schreibt die App dann wieder in die richtige.
    private static let reopenInterval: TimeInterval = 5

    public static func write(_ message: String, _ level: String = "INFO") {
        let now = Date()
        queue.async {
            let line = "\(now.formatted(timeFormat)) \(level) \(message)\n"
            guard let h = openHandle(now: now) else { return }
            // Ans Ende springen (ein anderer Prozess kann inzwischen angehängt haben); liefert zugleich die Größe.
            if let size = try? h.seekToEnd(), size > UInt64(maxBytes) {
                rotate()
                guard let fresh = openHandle(now: now) else { return }
                _ = try? fresh.seekToEnd()
                try? fresh.write(contentsOf: Data(line.utf8))
                return
            }
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    /// Offene Protokolldatei (nur auf `queue`); legt Ordner und Datei bei Bedarf an.
    private static func openHandle(now: Date) -> FileHandle? {
        if let h = handle, now.timeIntervalSince(openedAt) < reopenInterval { return h }
        closeHandle()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            // Nur für den eigenen Benutzer lesbar (enthält Adressen und Gerätekennungen).
            #if os(Windows)
            _ = fm.createFile(atPath: url.path, contents: nil)
            #else
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            #endif
        }
        handle = try? FileHandle(forWritingTo: url)
        openedAt = now
        return handle
    }

    private static func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// 5 MB erreicht: klimacontrol.log → .1 → .2 (nur auf `queue`).
    private static func rotate() {
        closeHandle()
        let fm = FileManager.default
        let old1 = url.appendingPathExtension("1"), old2 = url.appendingPathExtension("2")
        try? fm.removeItem(at: old2)
        try? fm.moveItem(at: old1, to: old2)
        try? fm.moveItem(at: url, to: old1)
    }

    public static func error(_ message: String) { write(message, LogText.t("log.level.error", "FEHLER")) }

    /// Letzte Zeilen für die Anzeige in den Einstellungen.
    public static func tail(_ lines: Int = 300) -> String {
        queue.sync {}
        // Nur das Ende der Datei lesen (bis 5 MB groß; die Einstellungen fragen alle 3 s).
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 128 * 1024
        try? h.seek(toOffset: size > chunk ? size - chunk : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        if size > chunk, !rows.isEmpty { rows.removeFirst() } // erste Zeile ist angeschnitten
        return rows.suffix(lines).joined(separator: "\n")
    }

    public static func clear() {
        queue.sync {
            closeHandle()
            let fm = FileManager.default
            // Auch die Sicherungen .1/.2 (sonst blieben bis 10 MB alter Zeilen liegen).
            for u in [url, url.appendingPathExtension("1"), url.appendingPathExtension("2")] { try? fm.removeItem(at: u) }
        }
    }

    /// E-Mail-Adresse für das Protokoll kürzen: m***@gmail.com
    public static func mask(_ account: String) -> String {
        guard let at = account.firstIndex(of: "@"), at > account.startIndex else { return "***" }
        return String(account[account.startIndex]) + "***" + account[at...]
    }
}
