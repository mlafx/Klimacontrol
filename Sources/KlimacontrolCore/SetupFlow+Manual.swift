import Foundation
import MideaKit

/// Weg der Einrichtung.
public enum SetupPath: String, CaseIterable, Sendable {
    /// Token und Schlüssel über das Midea-Konto holen (empfohlen).
    case account
    /// Zugangsdaten selbst eingeben – kein Konto nötig.
    case manual
    /// Backup-Datei einlesen.
    case backup
}

/// Eingaben des Wegs „Zugangsdaten“. Alles als Text, damit die Felder frei editierbar bleiben; geprüft wird beim
/// Prüfen/Verbinden (`SetupFlow.manualConfig()`).
public struct ManualCredentials: Equatable, Sendable {
    public var ip = ""
    public var port = "6444"
    public var deviceId = ""
    public var token = ""
    public var key = ""
    /// Name der Anlage (aus der Suche bzw. dem Backup), sonst „PortaSplit“.
    public var name = ""

    public init() {}

    static func clean(_ s: String) -> String { s.filter { !$0.isWhitespace } }
    /// Token und Schlüssel ohne Leerzeichen/Zeilenumbrüche (beim Einfügen oft dabei).
    public var tokenHex: String { Self.clean(token) }
    public var keyHex: String { Self.clean(key) }
    public var tokenValid: Bool { tokenHex.count == 128 && tokenHex.allSatisfy(\.isHexDigit) }
    public var keyValid: Bool { keyHex.count == 64 && keyHex.allSatisfy(\.isHexDigit) }
    public var ipValid: Bool { DeviceConfig.isIPv4(ip.trimmingCharacters(in: .whitespaces)) }
    public var portValid: Bool { UInt16(port.trimmingCharacters(in: .whitespaces)).map { $0 > 0 } ?? false }
    public var deviceIdValid: Bool { UInt64(Self.clean(deviceId)).map { $0 > 0 } ?? false }
    public var isComplete: Bool { tokenValid && keyValid && ipValid && portValid && deviceIdValid }

    /// Was noch fehlt bzw. falsch ist – je Feld ein kurzer Satz für die Anzeige am Feld.
    public var problems: [String: String] {
        var p: [String: String] = [:]
        if !ipValid { p["ip"] = L.Setup.Problem.ip }
        if !portValid { p["port"] = L.Setup.Problem.port }
        if !deviceIdValid { p["deviceId"] = L.Setup.Problem.deviceId }
        if !tokenValid { p["token"] = Self.lengthProblem(tokenHex, of: 128) }
        if !keyValid { p["key"] = Self.lengthProblem(keyHex, of: 64) }
        return p
    }

    /// „37 von 128 Zeichen.“ bzw. Hinweis auf falsche Zeichen (erlaubt sind 0–9 und a–f).
    static func lengthProblem(_ s: String, of n: Int) -> String {
        if !s.allSatisfy(\.isHexDigit) { return L.Setup.Problem.lengthChars(count: String(s.count), total: String(n)) }
        return L.Setup.Problem.length(count: String(s.count), total: String(n))
    }
}

/// Nach gelungener Einrichtung: was die Oberfläche noch anbieten soll.
public struct SetupCompletion: Equatable, Sendable {
    public let path: SetupPath
    /// Ohne Konto gibt es keinen Cloud-Weg: Weg „Nur WLAN“ vorschlagen (nicht still setzen; `applySuggestedMode`).
    public let suggestLANOnly: Bool
    /// Token und Schlüssel liegen nur auf diesem Rechner: „Zugangsdaten jetzt sichern?“ anbieten.
    public let offerBackup: Bool
    /// Ein Satz, was über welchen Weg geht (an Midea oder nur im WLAN).
    public let note: String
}

/// Art einer Meldung der Einrichtung – für passende Knöpfe in der Oberfläche.
public enum SetupIssue: String, Sendable, Equatable {
    /// Suche ohne Antwort: Freigabe „Lokales Netzwerk“ (macOS) bzw. Firewall (Windows), Gast-WLAN.
    case nothingFound
    /// Gefunden, aber keine Klimaanlage (WLAN oder Konto).
    case notAirConditioner
    /// Eingabe unvollständig oder falsch.
    case invalidInput
    /// Die Anlage lehnt Token/Schlüssel ab.
    case rejected
    /// Die Anlage ist belegt (andere App, offene Diagnose).
    case busy
    /// Die Anlage antwortet nicht bzw. ist nicht erreichbar.
    case unreachable
    /// E-Mail oder Passwort falsch.
    case accountLogin
    /// Midea-Cloud meldet einen Fehler bzw. kennt die Anlage nicht.
    case cloud
    /// Kein Internet bzw. Midea nicht erreichbar.
    case network
    case other

    /// Oberfläche soll die Hilfe zum Netz zeigen (Knopf für die Freigabe „Lokales Netzwerk“ bzw. Firewall).
    public var showsNetworkHelp: Bool { self == .nothingFound || self == .unreachable }
}

extension SetupFlow {
    /// Weg wählen bzw. mit nil zurück zur Startseite.
    public func choose(_ path: SetupPath?) { self.path = path }

    /// Anlage aus der Suche übernehmen: Adresse, Port, Anlagen-ID und Name vorbelegen (Token/Schlüssel bleiben).
    public func useForManual(_ device: DiscoveredDevice) {
        selected = device
        guard !device.isCloudOnly else { manual.deviceId = String(device.deviceId); manual.name = device.name; return }
        manual.ip = device.ip
        manual.port = String(device.port)
        manual.deviceId = String(device.deviceId)
        manual.name = device.name
    }

    /// Text aus der Zwischenablage auswerten: Backup-JSON (`devices[0]` mit ip, port, deviceId, token, key) oder freier
    /// Text mit einer 128- und einer 64-stelligen Hex-Folge (Token, Schlüssel), optional IP-Adresse und Anlagen-ID.
    /// Übernimmt, was erkannt wurde, und sagt, was es war (nil = nichts erkannt).
    @discardableResult
    public func pasteCredentials(_ text: String) -> String? {
        if let parsed = Self.parseCredentials(text, into: manual) {
            manual = parsed.credentials
            error = nil
            return parsed.found
        }
        fail(L.Setup.pasteEmpty, .invalidInput)
        return nil
    }

    static func parseCredentials(_ text: String, into base: ManualCredentials) -> (credentials: ManualCredentials, found: String)? {
        var c = base
        var found: [String] = []
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let d = (obj["devices"] as? [[String: Any]])?.first ?? obj
            if let v = d["ip"] as? String { c.ip = v; found.append(L.Setup.Found.address) }
            if let v = d["port"] { c.port = "\(v)"; found.append(L.Setup.Found.port) }
            if let v = d["deviceId"] ?? d["id"] { c.deviceId = "\(v)"; found.append(L.Setup.Found.applianceId) }
            if let v = d["token"] as? String { c.token = v; found.append(L.Setup.Found.token) }
            if let v = d["key"] as? String { c.key = v; found.append(L.Setup.Found.key) }
            if let v = (d["discoveredName"] ?? d["name"]) as? String { c.name = v }
        } else {
            let words = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
                .filter { !$0.isEmpty }
            if let t = words.first(where: { $0.count == 128 && $0.allSatisfy(\.isHexDigit) }) { c.token = t; found.append(L.Setup.Found.token) }
            if let k = words.first(where: { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) { c.key = k; found.append(L.Setup.Found.key) }
            if let ip = words.first(where: DeviceConfig.isIPv4) { c.ip = ip; found.append(L.Setup.Found.address) }
            if let id = words.first(where: { $0.count >= 10 && $0.count <= 20 && $0.allSatisfy(\.isNumber) }) {
                c.deviceId = id; found.append(L.Setup.Found.applianceId)
            }
        }
        return found.isEmpty ? nil : (c, found.joined(separator: L.Setup.Found.separator))
    }

    /// Eingaben als geprüfte Einrichtung; wirft mit lesbarer Meldung, wenn etwas fehlt.
    func manualConfig() throws -> DeviceConfig {
        let m = manual
        if let first = ["ip", "port", "deviceId", "token", "key"].compactMap({ m.problems[$0] }).first {
            throw ManualError(message: first)
        }
        let name = m.name.isEmpty ? "PortaSplit" : m.name
        return try DeviceConfig(name: name, ip: m.ip.trimmingCharacters(in: .whitespaces),
                                port: UInt16(m.port.trimmingCharacters(in: .whitespaces)) ?? 6444,
                                deviceId: UInt64(ManualCredentials.clean(m.deviceId)) ?? 0,
                                token: m.tokenHex.lowercased(), key: m.keyHex.lowercased()).validated()
    }

    /// „Prüfen“: Anmeldung an der Anlage, ohne etwas zu speichern. Erfolg → true (auch in `manualCheckOK`).
    /// Nur eine echte Ablehnung setzt `manualCheckOK = false`; belegt oder keine Antwort bleibt „ungeprüft“.
    @discardableResult
    public func checkManual() async -> Bool {
        guard !busy else { return false }
        busy = true
        error = nil
        defer { busy = false }
        do {
            return await check(try manualConfig())
        } catch {
            fail(error, context: .manual)
            return false
        }
    }

    /// „Verbinden“: prüfen und übernehmen – kein Midea-Konto nötig. Erfolg → true. War „Prüfen“ mit genau diesen
    /// Eingaben eben erst erfolgreich, gibt es keine zweite Anmeldung an der Anlage.
    public func connectManual() async -> Bool {
        guard let sink, !busy else { return false }
        busy = true
        error = nil
        completion = nil
        defer { busy = false }
        do {
            let cfg = try manualConfig()
            let fresh = manualCheckOK == true && manualCheckedAt.map { now().timeIntervalSince($0) < Self.reuseSeconds } == true
            if !fresh, !(await check(cfg)) { return false }
            try sink.adopt(cfg)
            AppLog.write("Anlage mit eingegebenen Zugangsdaten eingerichtet: \(cfg.name) @ \(cfg.ip)")
            // Ohne Konto gibt es keinen Cloud-Weg und die Zugangsdaten liegen nur hier.
            completion = SetupCompletion(path: .manual, suggestLANOnly: sink.connectionMode != .lan,
                                         offerBackup: true, note: Self.completionNoteManual)
            return true
        } catch {
            fail(error, context: .manual)
            return false
        }
    }

    /// Eine Anmeldung an der Anlage; setzt `manualCheckOK` und bei Fehlern die passende Meldung. Nur eine echte
    /// Ablehnung heißt „Zugangsdaten falsch“; belegt oder keine Antwort sagt nichts über sie.
    private func check(_ cfg: DeviceConfig) async -> Bool {
        let result = await probe.check(cfg)
        guard let failure = result.error else {
            manualCheckOK = true
            manualCheckedAt = now()
            return true
        }
        manualCheckOK = result.isRejected ? false : nil
        manualCheckedAt = nil
        fail(failure, context: .manual)
        return false
    }

    static var rejectedManual: String { L.Setup.rejectedManual }
}

struct ManualError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Meldungen „Was ist passiert. Was tun. (Code)“

extension SetupFlow {
    /// Wo ein Fehler auftrat – bestimmt den Rat im zweiten Satz.
    enum Context { case general, cloudSearch, account, manual }

    /// Zusatzsatz, wenn die Suche nichts findet: Freigabe bzw. Firewall und Gast-WLAN.
    nonisolated static var networkHint: String {
        #if os(Windows)
        return L.Setup.NetworkHint.windows
        #else
        return L.Setup.NetworkHint.mac
        #endif
    }

    /// Adresse der macOS-Einstellung „Lokales Netzwerk“ für einen Knopf in der Oberfläche.
    public nonisolated static let localNetworkSettingsURL =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"

    /// Text, wenn die Suche nichts gefunden hat – je Weg (ohne Konto keine Cloud-Suche) und je Plattform.
    static func nothingFoundText(target: String?, asked: Int?, path: SetupPath?) -> String {
        let withAccount = path != .manual
        if let target {
            return withAccount ? L.Setup.NothingFound.Target.account(target: target)
                : L.Setup.NothingFound.Target.manual(target: target)
        }
        if let asked {
            return withAccount ? L.Setup.NothingFound.Asked.account(asked: String(asked), hint: networkHint)
                : L.Setup.NothingFound.Asked.manual(asked: String(asked), hint: networkHint)
        }
        return withAccount ? L.Setup.NothingFound.None.account(hint: networkHint)
            : L.Setup.NothingFound.None.manual(hint: networkHint)
    }

    static var completionNoteManual: String { L.Setup.Completion.manual }

    static func completionNote(cloudOnly: Bool) -> String {
        cloudOnly ? L.Setup.Completion.cloudOnly : L.Setup.Completion.account
    }

    /// Fehler → (Text, Art). Ohne Fachwörter; Codes klein am Ende.
    static func describe(_ error: any Error, context: Context) -> (text: String, issue: SetupIssue) {
        if let e = error as? ManualError { return (e.message, .invalidInput) }
        if let e = error as? MideaCloud.CloudError { return describeCloud(e, context: context) }
        if let e = error as? ConfigError {
            switch e {
            case .invalidHex: return (L.Setup.Config.invalidHex, .invalidInput)
            case .invalidAddress: return (L.Setup.Config.invalidAddress, .invalidInput)
            case .noDevice: return (L.Setup.Config.noDevice, .invalidInput)
            case .unsupportedVersion(let v): return (L.Setup.Config.unsupportedVersion(version: String(v)), .invalidInput)
            }
        }
        if let e = error as? MideaError { return describeDevice(e, context: context) }
        return (error.localizedDescription, .other)
    }

    static var busyText: String { L.Setup.busy }

    static func describeDevice(_ e: MideaError, context: Context) -> (text: String, issue: SetupIssue) {
        switch e {
        case .authenticationFailed:
            return (context == .manual ? rejectedManual
                    : L.Setup.Device.rejected, .rejected)
        case .timeout:
            return (L.Setup.Device.timeout, .unreachable)
        case .allPathsFailed(let failures) where failures.contains(where: { $0.reason == .busy }):
            return (busyText, .busy)
        case .connectionFailed, .refused, .unreachable, .outcomeUnknown, .allPathsFailed:
            // Abgewiesen ohne Beleg für „belegt“ (falsche oder alte Adresse) wie jede andere fehlende Verbindung.
            var msg = e.connectionDetailText ?? ""
            if case .outcomeUnknown(let reason) = e { msg = reason }
            let cleaned = DeviceConfig.cleanText(msg, fallback: "")
            let detail = cleaned.isEmpty ? "" : " (\(cleaned))"
            if context == .general {
                return (L.Setup.Device.searchFailed(detail: detail, hint: networkHint), .unreachable)
            }
            return (L.Setup.Device.noConnection(detail: detail), .unreachable)
        case .busy:
            return (busyText, .busy)
        case .commandNotApplied:
            return (busyText, .busy)
        case .crypto(let code):
            return (L.Setup.Device.crypto(code: String(code)), .other)
        case .protocolError, .invalidResponse:
            return (L.Setup.Device.unexpected, .other)
        }
    }

    static func describeCloud(_ e: MideaCloud.CloudError, context: Context) -> (text: String, issue: SetupIssue) {
        switch e {
        case .api(let code, let msg):
            switch e.kind {
            case .wrongCredentials:
                return (L.Setup.Cloud.wrongCredentials(code: String(code)), .accountLogin)
            case .serviceUnavailable:
                return (L.Setup.Cloud.serviceUnavailable, .cloud)
            case .applianceOffline:
                return (L.Setup.Cloud.applianceOffline, .unreachable)
            default:
                let m = DeviceConfig.cleanText(msg, fallback: L.Setup.Cloud.unknownError)
                return (L.Setup.Cloud.error(message: m, code: String(code)), .cloud)
            }
        case .noToken:
            return (context == .cloudSearch
                    ? L.Setup.Cloud.noTokenSearch : L.Setup.Cloud.noToken, .cloud)
        case .network:
            return (L.Setup.Cloud.network, .network)
        case .tokenRejected:
            return (L.Setup.Cloud.tokenRejected, .rejected)
        case .notInAccount, .badReply, .sessionKeys, .incompleteLogin, .paused, .keychainLocked:
            let m = DeviceConfig.cleanText(e.displayMessage, fallback: L.Setup.Cloud.unknownError)
            return (L.Setup.Cloud.error(message: m, code: String(e.code)), .cloud)
        }
    }
}
