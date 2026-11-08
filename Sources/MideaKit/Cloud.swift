#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Zugang zur Midea-Cloud (Token-Abruf nach msmart-ng `cloud.py`, Kontoliste, Steuerung über `MideaCloudSession`).
/// Das Passwort geht nur zur Anmeldung an Midea; gespeichert wird es nur im Schlüsselbund (siehe `CloudKeychain`).
public enum MideaCloud {
    /// Fehler der Cloud. Genauer für Oberfläche und Sitzungslogik über `kind`.
    public enum CloudError: Error, LocalizedError {
        /// Fehlercode und Text einer Antwort der Midea-Cloud (-1 = Code fehlte in der Antwort).
        case api(Int, String)
        case noToken
        case network(String)
        /// Die Anlage lehnt das Token aus der Cloud ab.
        case tokenRejected
        /// Die Anlage ist in diesem Konto nicht vorhanden.
        case notInAccount
        /// Antwort der Cloud unlesbar (kein JSON, kein Hex, Paket kaputt, leere Antwort).
        case badReply(String)
        /// Sitzungsschlüssel fehlen oder passen nicht (Entschlüsseln scheitert).
        case sessionKeys(String)
        /// Anmeldung ohne Token bzw. ohne Sitzungsdaten beantwortet.
        case incompleteLogin(String)
        /// Neuanmeldung nach Fehlschlägen pausiert (Rückzug), frühestens wieder ab `until`.
        case paused(until: Date)
        /// Schlüsselbund gesperrt – ohne gespeicherte Sitzung keine Neuanmeldung.
        case keychainLocked

        public var kind: CloudErrorKind {
            switch self {
            case .noToken: return .noToken
            case .network: return .network
            case .tokenRejected: return .tokenRejected
            case .notInAccount: return .notInAccount
            case .badReply: return .badReply
            case .sessionKeys, .incompleteLogin: return .sessionExpired
            case .paused: return .paused
            case .keychainLocked: return .keychainLocked
            case .api(let code, let msg):
                let m = msg.lowercased()
                switch code {
                case 3123: return .applianceOffline
                case 3101, 3102: return .wrongCredentials
                case 9999: return .serviceUnavailable
                default: break
                }
                if m.contains("password") { return .wrongCredentials }
                if m.contains("locked") || m.contains("frozen") || m.contains("too many") { return .accountLocked }
                if CloudControlClient.isSessionError(self) { return .sessionExpired }
                return .other
            }
        }

        /// Text des Fehlers für Protokoll und Kurzgrund (bei `.api` der Text von Midea). Deutsch; Anzeige über `displayMessage` im Kern (`DisplayNames.swift`).
        public var message: String {
            switch self {
            case .api(_, let msg), .network(let msg), .badReply(let msg), .sessionKeys(let msg), .incompleteLogin(let msg):
                return msg
            case .noToken: return LogText.t("reason.cloud.noToken", "kein Token")
            case .tokenRejected: return LogText.t("reason.cloud.tokenRejected", "Die Anlage lehnt das Token ab – ist sie in genau diesem Konto eingerichtet?")
            case .notInAccount: return LogText.t("reason.cloud.notInAccount", "Anlage ist in diesem Konto nicht vorhanden")
            case .paused(let until):
                return LogText.t("reason.cloud.paused", "Die Cloud-Anmeldung ist nach Fehlschlägen pausiert. Klimacontrol versucht es ab {time} wieder.",
                                 ["time": MideaCloudSession.clock(until)])
            case .keychainLocked:
                return LogText.t("reason.cloud.keychainLocked", "Der Schlüsselbund ist gesperrt. Mac entsperren; Klimacontrol versucht es danach von selbst wieder.")
            }
        }

        /// Code für Kurzgrund und Einrichtung: bei `.api` der Midea-Code, sonst ein fester eigener Code
        /// (negativ, ab -1000; Midea nutzt nur positive Codes).
        public var code: Int {
            switch self {
            case .api(let code, _): return code
            case .noToken, .network: return -1
            case .tokenRejected: return -1002
            case .notInAccount: return -1004
            case .badReply: return -1010
            case .sessionKeys: return -1011
            case .incompleteLogin: return -1012
            case .paused: return -1021
            case .keychainLocked: return -1030
            }
        }

        /// Was ist passiert (ein Satz, ohne Fachwörter). Deutsch für Protokoll; die Anzeige-Texte stehen im Katalog des Kerns.
        public var what: String {
            switch kind {
            case .wrongCredentials: return LogText.t("kit.cloud.what.wrongCredentials", "E-Mail oder Passwort des Midea-Kontos stimmen nicht.")
            case .accountLocked: return LogText.t("kit.cloud.what.accountLocked", "Das Midea-Konto ist vorübergehend gesperrt.")
            case .serviceUnavailable: return LogText.t("kit.cloud.what.serviceUnavailable", "Die Midea-Cloud gibt über diesen Zugang gerade keine Zugangsdaten aus.")
            case .sessionExpired: return LogText.t("kit.cloud.what.sessionExpired", "Die Anmeldung bei der Midea-Cloud ist abgelaufen.")
            case .applianceOffline: return LogText.t("kit.cloud.what.applianceOffline", "Die Anlage ist laut Midea-Cloud ausgeschaltet oder ohne Strom.")
            case .notInAccount, .noToken: return LogText.t("kit.cloud.what.unknownAppliance", "Die Cloud kennt diese Anlage nicht.")
            case .tokenRejected: return LogText.t("kit.cloud.what.tokenRejected", "Die Anlage lehnt die Zugangsdaten aus der Cloud ab.")
            case .network: return LogText.t("kit.cloud.what.network", "Die Midea-Cloud ist nicht erreichbar.")
            case .badReply: return LogText.t("kit.cloud.what.badReply", "Die Midea-Cloud hat unerwartet geantwortet.")
            case .other:
                if case .api(_, let msg) = self {
                    return LogText.t("kit.cloud.what.otherWithText", "Die Midea-Cloud meldet einen Fehler: {text}.", ["text": DeviceConfig.cleanText(msg, fallback: LogText.t("kit.cloud.noText", "ohne Text"))])
                }
                return LogText.t("kit.cloud.what.other", "Die Midea-Cloud meldet einen Fehler.")
            case .paused, .keychainLocked: return message
            }
        }

        /// Was tun (ein Satz).
        public var todo: String {
            switch kind {
            case .wrongCredentials: return LogText.t("kit.cloud.todo.wrongCredentials", "Zugangsdaten aus der MSmartHome-App in den Einstellungen neu eingeben.")
            case .accountLocked: return LogText.t("kit.cloud.todo.accountLocked", "Später erneut versuchen oder in der MSmartHome-App anmelden.")
            case .serviceUnavailable: return LogText.t("kit.cloud.todo.serviceUnavailable", "Später erneut versuchen oder die Anlage über die Suche im WLAN einrichten.")
            case .sessionExpired: return LogText.t("kit.cloud.todo.sessionExpired", "Klimacontrol meldet sich automatisch neu an; sonst später erneut versuchen.")
            case .applianceOffline: return LogText.t("kit.cloud.todo.applianceOffline", "Klimacontrol prüft regelmäßig weiter.")
            case .notInAccount, .noToken: return LogText.t("kit.cloud.todo.unknownAppliance", "Prüfen, ob sie in der MSmartHome-App in genau diesem Konto eingerichtet ist.")
            case .tokenRejected: return LogText.t("kit.cloud.todo.tokenRejected", "Prüfen, ob die Anlage in genau diesem Konto eingerichtet ist.")
            case .network: return LogText.t("kit.cloud.todo.network", "Internetverbindung prüfen und erneut versuchen.")
            case .badReply, .other: return LogText.t("kit.cloud.todo.retryLater", "Später erneut versuchen.")
            case .paused, .keychainLocked: return ""
            }
        }

        /// Code für die Klammer am Ende (nur echte Midea-Codes; eigene Codes sind für Nutzer bedeutungslos).
        public var codeText: String? {
            if case .api(let code, _) = self, code >= 0 || code == -1 { return String(code) }
            return nil
        }

        /// Muster „Was ist passiert. Was tun. (Code)“.
        public var errorDescription: String? {
            var text = todo.isEmpty ? what : what + " " + todo
            if case .network(let detail) = self, !detail.isEmpty { text += " (\(detail))" }
            if let c = codeText { text += " (\(c))" }
            return text
        }
    }

    /// Holt Token und Schlüssel und prüft sie an der Anlage (beide Byte-Reihenfolgen der udpid, beide Cloud-Zugänge).
    /// Nutzt die gemeinsame Sitzung des Kontos (keine zweite Anmeldung, wenn kurz vorher die Kontoliste kam).
    public static func fetchConfig(for dev: DiscoveredDevice, account: String, password: String) async throws -> DeviceConfig {
        var lastError: any Error = CloudError.noToken
        AppLog.write(LogText.t("log.token.fetch", "Token-Abruf für {name} ({ip}, id {id}) mit Konto {account}", ["name": dev.name, "ip": dev.ip, "id": String(dev.deviceId), "account": AppLog.mask(account)]))
        let session = MideaCloudSession.shared(account: account, password: password)
        await session.userActed()
        for kind in CloudKind.allCases {
            do {
                // PortaSplit nutzt big endian; little endian als Rückfall.
                for big in [true, false] {
                    let udpid = Discovery.udpid(deviceId: dev.deviceId, bigEndian: big)
                    let found = try await session.token(kind: kind, udpid: udpid, applianceId: dev.deviceId)
                    guard let (token, key) = found else {
                        AppLog.write(LogText.t("log.token.none", "Kein Token für udpid ({order} endian, {kind})", ["order": big ? "big" : "little", "kind": kind.rawValue]))
                        continue
                    }
                    AppLog.write(LogText.t("log.token.received", "Token erhalten ({order} endian), prüfe an der Anlage …", ["order": big ? "big" : "little"]))
                    let cfg = DeviceConfig(name: dev.name, ip: dev.ip, port: dev.port, deviceId: dev.deviceId, token: token, key: key)
                    if await PortaSplitDevice.verify(cfg, quiet: true) {
                        AppLog.write(LogText.t("log.token.accepted", "Anlage hat das Token angenommen – Einrichtung fertig"))
                        return cfg
                    }
                    AppLog.write(LogText.t("log.token.rejected", "Anlage lehnt dieses Token ab ({order} endian) – probiere die andere Variante", ["order": big ? "big" : "little"]))
                    lastError = CloudError.tokenRejected
                }
            } catch {
                AppLog.error(LogText.t("log.token.error", "{kind}: {error}", ["kind": kind.rawValue, "error": error.localizedDescription]))
                lastError = error
            }
        }
        throw lastError
    }

    /// Listet die Anlagen des Midea-Kontos wie die MSmartHome-App (Appliance-Liste der Cloud). Findet die
    /// Anlage auch, wenn sie ausgeschaltet ist und im WLAN nicht auf die Suche antwortet. MSmartHome zuerst,
    /// NetHome Plus als Rückfall.
    public static func listAppliances(account: String, password: String) async throws -> [CloudAppliance] {
        var lastError: any Error = CloudError.noToken
        AppLog.write(LogText.t("log.cloud.search", "Cloud-Suche mit Konto {account}", ["account": AppLog.mask(account)]))
        let session = MideaCloudSession.shared(account: account, password: password)
        await session.userActed()
        for kind in CloudKind.allCases {
            do {
                let list = try await session.appliances(kind: kind)
                let found = list.isEmpty ? LogText.t("log.cloud.searchEmpty", "keine Anlage im Konto")
                    : list.map { LogText.t("log.cloud.searchItem", "{name} id {id} {state}", ["name": $0.name, "id": String($0.deviceId), "state": $0.online ? LogText.t("log.cloud.online", "online") : LogText.t("log.cloud.offline", "offline")]) }.joined(separator: ", ")
                AppLog.write(LogText.t("log.cloud.searchResult", "Cloud-Suche ({kind}): {result}", ["kind": kind.rawValue, "result": found]))
                if !list.isEmpty { return list }
                lastError = CloudError.noToken
            } catch {
                AppLog.error(LogText.t("log.cloud.searchError", "Cloud-Suche {kind}: {error}", ["kind": kind.rawValue, "error": error.localizedDescription]))
                lastError = error
            }
        }
        throw lastError
    }

    /// Anlagen-ID eines Listeneintrags – eine Regel für Kontoliste und Steuerung: `id`, sonst `applianceCode`.
    static func applianceId(of item: [String: Any]) -> String? {
        for field in ["id", "applianceCode"] {
            guard let v = item[field], !(v is NSNull) else { continue }
            let s = "\(v)".trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
        }
        return nil
    }

    /// Ein Eintrag der Appliance-Liste. `id` ist die Geräte-ID (dieselbe wie in der WLAN-Suche).
    static func parseAppliance(_ item: [String: Any]) -> CloudAppliance? {
        guard let raw = applianceId(of: item), let deviceId = UInt64(raw), deviceId != 0 else { return nil }
        let name = DeviceConfig.cleanText(item["name"] as? String ?? "", fallback: "PortaSplit")
        let online = "\(item["onlineStatus"] ?? "1")" == "1"
        return CloudAppliance(deviceId: deviceId, name: name, type: parseType("\(item["type"] ?? "")"), online: online)
    }

    /// Gerätetyp aus der Cloud („0xAC“, „AC“, „0000AC“) → 0xAC; Unbekanntes → 0.
    static func parseType(_ s: String) -> Int {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard !t.isEmpty, t.allSatisfy(\.isHexDigit) else { return 0 }
        return Int(t.suffix(2), radix: 16) ?? 0
    }

    /// Gregorianischer UTC-Kalender, einmal angelegt (statt je Anfrage einen DateFormatter zu bauen).
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// Zeitstempel `yyyyMMddHHmmss` in UTC.
    static func stamp(_ date: Date = Date()) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var out = ""
        out.reserveCapacity(14)
        func pad(_ v: Int?, _ width: Int) {
            let digits = String(v ?? 0)
            if digits.count < width { out += String(repeating: "0", count: width - digits.count) }
            out += digits
        }
        pad(c.year, 4); pad(c.month, 2); pad(c.day, 2); pad(c.hour, 2); pad(c.minute, 2); pad(c.second, 2)
        return out
    }

    static func randomHex(_ bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).hex
    }

    static func sha256Hex(_ s: String) -> String { MideaCrypto.sha256(Data(s.utf8)).hex }
    static func md5Hex(_ s: String) -> String { MideaCrypto.md5(Data(s.utf8)).hex }

    /// Geräte-ID fürs Midea-Konto, dauerhaft gespeichert: eine neue ID je Start sieht Midea als neues Gerät
    /// und meldet „Konto anderswo eingeloggt“.
    static let deviceId: String = {
        let key = "MideaCloudDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key), existing.count == 16 { return existing }
        let new = randomHex(8)
        UserDefaults.standard.set(new, forKey: key)
        #if os(Windows)
        _ = UserDefaults.standard.synchronize()  // swift-corelibs-foundation speichert sonst nicht
        #endif
        return new
    }()

    /// Eigene, flüchtige URLSession: keine geteilten Cookies/Caches, Gesamtlimit je Anfrage 30 s.
    static func makeURLSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 30
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return URLSession(configuration: c)
    }

    private static let sharedURLSession = Mutex<URLSession>(makeURLSession())
    /// Austauschbar für Tests (Fake-`URLProtocol`).
    static var urlSession: URLSession {
        get { sharedURLSession.withLock { $0 } }
        set { sharedURLSession.withLock { $0 = newValue } }
    }

    /// Fehlertext einer Cloud-Antwort: Steuerzeichen und Zeilenumbrüche raus, höchstens 200 Zeichen (landet in
    /// Protokoll und Meldungen).
    static func cleanMessage(_ raw: Any?) -> String {
        DeviceConfig.cleanText(raw.map { "\($0)" } ?? "", fallback: "", maxLength: 200)
    }

    static func post(_ request: URLRequest) async throws -> [String: Any] {
        let endpoint = request.url.map { ($0.host ?? "") + $0.path + ($0.query.map { "?" + $0 } ?? "") } ?? "?"
        AppLog.debug("Cloud → \(endpoint) \(AppLog.redact(String(decoding: request.httpBody ?? Data(), as: UTF8.self)).prefix(600))")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        AppLog.debug("Cloud ← HTTP \(status) \(AppLog.redact(String(decoding: data, as: UTF8.self)).prefix(800))")
        if status >= 500 { throw CloudError.network("HTTP \(status)") }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudError.badReply("unerwartete Antwort (HTTP \(status))")
        }
        return json
    }
}

/// Fehlerart einer Cloud-Antwort (für Oberfläche und Sitzungslogik).
public enum CloudErrorKind: Sendable, Equatable {
    case wrongCredentials, accountLocked, serviceUnavailable, sessionExpired, applianceOffline, notInAccount
    case tokenRejected, noToken, network, badReply, other
    /// Neuanmeldung pausiert; Schlüsselbund gesperrt.
    case paused, keychainLocked
}

/// Eine im Midea-Konto hinterlegte Anlage (aus der Cloud, unabhängig davon, ob sie gerade an oder im WLAN ist).
public struct CloudAppliance: Equatable, Sendable {
    public let deviceId: UInt64
    public let name: String
    /// 0xAC = Klimaanlage, 0 = unbekannt
    public let type: Int
    public let online: Bool

    public var isAirConditioner: Bool { type == 0xAC || type == 0xCC }
}

/// Eine Cloud-Schicht für beide Zugänge: Anmeldung, Token, Kontoliste, Steuerung, Sitzung.
/// Nur aus `MideaCloudSession` benutzt (dort serialisiert). `Sendable`, weil der Aktor die asynchronen Aufrufe
/// außerhalb seiner Isolation ausführt; die Zugänge schützen ihren veränderlichen Zustand selbst mit einem `Mutex`.
protocol MideaCloudAPI: AnyObject, Sendable {
    var kind: CloudKind { get }
    /// Anmelden; wirft bei unvollständiger Antwort (`incompleteLogin`).
    func login() async throws
    /// Kann diese Sitzung Befehle senden (Sitzungsschlüssel vorhanden)?
    var canControl: Bool { get }
    func token(udpid: String, applianceId: UInt64) async throws -> (String, String)?
    /// Alle Anlagen des Kontos, roh wie von der Cloud geliefert (`/v1/appliance/user/list/get`).
    func listAppliancesRaw() async throws -> [[String: Any]]
    /// Einen Geräterahmen senden und die Antwortrahmen zurückgeben.
    func transparentSend(_ frame: Data, deviceId: UInt64, applianceId: String) async throws -> [Data]
    /// Die aktuelle Sitzung zum Speichern – nil, wenn Schlüssel fehlen.
    func makeSession(account: String, applianceId: String) -> CloudSession?
    /// Gespeicherte Sitzung übernehmen (ohne Netz); false, wenn sie unvollständig ist.
    func restore(_ s: CloudSession) -> Bool
}

extension MideaCloudAPI {
    var label: String { kind.rawValue }

    static func tokenFrom(_ result: [String: Any], udpid: String) -> (String, String)? {
        guard let list = result["tokenlist"] as? [[String: Any]] else { return nil }
        for t in list where (t["udpId"] as? String) == udpid {
            if let token = t["token"] as? String, let key = t["key"] as? String { return (token, key) }
        }
        return nil
    }

    /// Antwort der Anlage (CSV aus signed Bytes) in den inneren Rahmen wandeln. Kein CSV nach dem Entschlüsseln
    /// heißt: der Sitzungsschlüssel passt nicht (`sessionKeys`); gültiges CSV, aber kaputtes Paket = `badReply`.
    static func innerFrame(fromCSV text: String) throws -> [Data] {
        guard let decoded = CloudControlClient.fromCSV(text), !decoded.isEmpty else {
            throw MideaCloud.CloudError.sessionKeys(LogText.t("kit.cloud.sessionKeyMismatch", "Sitzungsschlüssel passt nicht"))
        }
        guard let inner = CloudPacket.decode(decoded) else {
            throw MideaCloud.CloudError.badReply(LogText.t("reason.cloud.badReply", "Antwort der Anlage über die Cloud unlesbar"))
        }
        return [inner]
    }
}

func makeCloudAPI(_ kind: CloudKind, account: String, password: String) -> any MideaCloudAPI {
    switch kind {
    case .smartHome: return SmartHomeClient(account: account, password: password)
    case .netHomePlus: return NetHomePlusClient(account: account, password: password)
    }
}

/// MSmartHome-Zugang (mp-prod.appsmb.com, JSON, HMAC-Signatur). Steuerung über „transparent send“ mit den
/// Sitzungsschlüsseln aus der Anmeldung (Best effort, nachgebaut nach dem Schlüsselschema von midea_ac_lan).
final class SmartHomeClient: MideaCloudAPI, Sendable {
    static let appId = "1010"
    static let base = "https://mp-prod.appsmb.com"
    static let hmacKey = "PROD_VnoClJI9aikS8dyy"
    static let iotKey = "meicloud"
    static let loginKey = "ac21b9f9cbfe4ca5a88562ef25e2b768"

    let kind = CloudKind.smartHome
    let account: String
    let password: String
    private struct Keys {
        var accessToken = ""
        /// Sitzungsschlüssel für „transparent send“ (aus accessToken/randomData der Anmeldung abgeleitet).
        var aesKey = Data()
        var aesIv = Data()
    }
    private let keys = Mutex(Keys())
    private var accessToken: String {
        get { keys.withLock { $0.accessToken } }
        set { keys.withLock { $0.accessToken = newValue } }
    }
    private(set) var aesKey: Data {
        get { keys.withLock { $0.aesKey } }
        set { keys.withLock { $0.aesKey = newValue } }
    }
    private(set) var aesIv: Data {
        get { keys.withLock { $0.aesIv } }
        set { keys.withLock { $0.aesIv = newValue } }
    }

    init(account: String, password: String) {
        self.account = account
        self.password = password
    }

    var canControl: Bool { !accessToken.isEmpty && !aesKey.isEmpty && !aesIv.isEmpty }

    /// Gespeicherte Sitzung wiederherstellen (ohne Netzanmeldung): nur Token und Sitzungsschlüssel setzen.
    func restoreSession(accessToken: String, aesKey: Data, aesIv: Data) {
        self.accessToken = accessToken
        self.aesKey = aesKey
        self.aesIv = aesIv
    }

    func restore(_ s: CloudSession) -> Bool {
        guard !s.accessToken.isEmpty, let key = Data(hex: s.aesKeyHex), let iv = Data(hex: s.aesIvHex),
              !key.isEmpty, !iv.isEmpty else { return false }
        restoreSession(accessToken: s.accessToken, aesKey: key, aesIv: iv)
        return true
    }

    private func body(_ extra: [String: Any]) -> [String: Any] {
        var b: [String: Any] = ["appId": Self.appId, "src": Self.appId, "format": 2, "clientType": 1,
                                "language": "en_US", "deviceId": MideaCloud.deviceId, "stamp": MideaCloud.stamp(),
                                "reqId": MideaCloud.randomHex(16)]
        b.merge(extra) { $1 }
        return b
    }

    static func sign(_ json: String, random: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data((iotKey + json + random).utf8),
                                             using: SymmetricKey(data: Data(hmacKey.utf8)))).hex
    }

    static func encryptPassword(loginId: String, password: String) -> String {
        MideaCloud.sha256Hex(loginId + MideaCloud.sha256Hex(password) + loginKey)
    }

    static func iamPassword(loginId: String, password: String) -> String {
        MideaCloud.sha256Hex(loginId + MideaCloud.md5Hex(MideaCloud.md5Hex(password)) + loginKey)
    }

    private func request(_ endpoint: String, _ body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let json = String(decoding: bodyData, as: UTF8.self)
        let random = MideaCloud.randomHex(16)
        let sig = Self.sign(json, random: random)
        var req = URLRequest(url: URL(string: "\(Self.base)/mas/v5/app/proxy?alias=\(endpoint)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "secretVersion")
        req.setValue(sig, forHTTPHeaderField: "sign")
        req.setValue(random, forHTTPHeaderField: "random")
        req.setValue(accessToken, forHTTPHeaderField: "accessToken")
        let r = try await MideaCloud.post(req)
        let code = Int("\(r["code"] ?? "-1")") ?? -1
        guard code == 0 else { throw MideaCloud.CloudError.api(code, MideaCloud.cleanMessage(r["msg"])) }
        return r["data"] as? [String: Any] ?? [:]
    }

    func login() async throws {
        accessToken = ""; aesKey = Data(); aesIv = Data()
        let loginId = try await request("/v1/user/login/id/get", body(["loginAccount": account]))["loginId"] as? String ?? ""
        guard !loginId.isEmpty else {
            throw MideaCloud.CloudError.incompleteLogin("Anmeldung ohne Kennung beantwortet")
        }
        let iam = Self.iamPassword(loginId: loginId, password: password)
        let pwd = Self.encryptPassword(loginId: loginId, password: password)
        let b: [String: Any] = [
            "data": ["platform": 2, "deviceId": MideaCloud.deviceId],
            "iotData": ["appId": Self.appId, "src": Self.appId, "clientType": 1, "loginAccount": account,
                        "iampwd": iam, "password": pwd, "pushToken": MideaCloud.randomHex(60),
                        "stamp": MideaCloud.stamp(), "reqId": MideaCloud.randomHex(16)],
        ]
        let r = try await request("/mj/user/login", b)
        let token = (r["mdata"] as? [String: Any])?["accessToken"] as? String ?? ""
        guard !token.isEmpty else {
            throw MideaCloud.CloudError.incompleteLogin("Anmeldung ohne Token beantwortet")
        }
        accessToken = token
        // Sitzungsschlüssel für die Steuerung (meiju: accessToken + randomData). Fehlen sie, geht nur der
        // Token-Abruf; `canControl` bleibt false und die Sitzung wählt für Befehle den anderen Zugang.
        if let encKey = r["accessToken"] as? String, let encIv = r["randomData"] as? String {
            try deriveSessionKeys(encKeyHex: encKey, encIvHex: encIv)
        }
    }

    /// meiju: tmp-Schlüssel aus sha256(loginKey); damit accessToken/randomData per AES-CBC zum Sitzungsschlüssel.
    private func deriveSessionKeys(encKeyHex: String, encIvHex: String) throws {
        let (tmpKey, tmpIv) = Self.tmpKeyIv()
        guard let ek = Data(hex: encKeyHex), let ei = Data(hex: encIvHex) else {
            throw MideaCloud.CloudError.incompleteLogin(LogText.t("kit.cloud.sessionKeyUnreadable", "Sitzungsschlüssel unlesbar"))
        }
        do {
            aesKey = try MideaCrypto.decryptCBC(key: tmpKey, iv: tmpIv, ek)
            aesIv = try MideaCrypto.decryptCBC(key: tmpKey, iv: tmpIv, ei)
        } catch {
            aesKey = Data(); aesIv = Data()
            throw MideaCloud.CloudError.incompleteLogin(LogText.t("kit.cloud.sessionKeyUnreadable", "Sitzungsschlüssel unlesbar"))
        }
    }

    static func tmpKeyIv() -> (Data, Data) {
        let digest = MideaCloud.sha256Hex(loginKey) // 64 Hex-Zeichen
        return (Data(digest.prefix(16).utf8), Data(digest.dropFirst(16).prefix(16).utf8))
    }

    func token(udpid: String, applianceId: UInt64) async throws -> (String, String)? {
        let r = try await request("/v1/iot/secure/getToken", body(["udpid": udpid, "applianceCodes": "\(applianceId)"]))
        return Self.tokenFrom(r, udpid: udpid)
    }

    func makeSession(account: String, applianceId: String) -> CloudSession? {
        guard canControl else { return nil }
        return CloudSession(account: account, cloud: kind.rawValue, accessToken: accessToken,
                            aesKeyHex: aesKey.hex, aesIvHex: aesIv.hex, sessionId: "",
                            applianceId: applianceId, savedAt: Date())
    }

    func listAppliancesRaw() async throws -> [[String: Any]] {
        let r = try await request("/v1/appliance/user/list/get", body(["homegroupId": "0"]))
        return r["list"] as? [[String: Any]] ?? []
    }

    func transparentSend(_ frame: Data, deviceId: UInt64, applianceId: String) async throws -> [Data] {
        guard canControl else {
            throw MideaCloud.CloudError.sessionKeys(LogText.t("kit.cloud.sessionKeysMissing", "Sitzungsschlüssel fehlen"))
        }
        let packet = CloudPacket.encode(deviceId: deviceId, frame: frame)
        let order = try MideaCrypto.encryptCBC(key: aesKey, iv: aesIv, Data(CloudControlClient.csv(packet).utf8)).hex
        // meiju-Schema: Feld heißt applianceCode (nicht applianceId); waitResp lässt die Cloud auf die Antwort warten.
        let r = try await request("/v1/appliance/transparent/send",
                                  body(["order": order, "funId": "0000", "applianceCode": applianceId, "waitResp": true]))
        guard let reply = r["reply"] as? String, let rd = Data(hex: reply) else {
            throw MideaCloud.CloudError.badReply(LogText.t("kit.cloud.noApplianceReply", "keine Antwort von der Anlage"))
        }
        let plain: Data
        do { plain = try MideaCrypto.decryptCBC(key: aesKey, iv: aesIv, rd) } catch {
            // Schlüssel passt nicht – ein Sitzungsproblem, kein Netzfehler.
            throw MideaCloud.CloudError.sessionKeys(LogText.t("kit.cloud.sessionKeyMismatch", "Sitzungsschlüssel passt nicht"))
        }
        return try Self.innerFrame(fromCSV: String(decoding: plain, as: UTF8.self))
    }
}

/// NetHome-Plus-Zugang (mapp.appsmb.com, Formular, SHA256-Signatur). Steuerung über „transparent send“,
/// data_key = AES-ECB-Entschlüsselung des Access-Token.
final class NetHomePlusClient: MideaCloudAPI, Sendable {
    static let appId = "1017"
    static let base = "https://mapp.appsmb.com"
    static let appKey = "3742e9e5842d4ad59c2db887e12449f9"

    let kind = CloudKind.netHomePlus
    let account: String
    let password: String
    private struct Keys {
        var sessionId = ""
        var accessToken = ""
    }
    private let keys = Mutex(Keys())
    private var sessionId: String {
        get { keys.withLock { $0.sessionId } }
        set { keys.withLock { $0.sessionId = newValue } }
    }
    private var accessToken: String {
        get { keys.withLock { $0.accessToken } }
        set { keys.withLock { $0.accessToken = newValue } }
    }

    init(account: String, password: String) {
        self.account = account
        self.password = password
    }

    var canControl: Bool { !sessionId.isEmpty && !accessToken.isEmpty }

    /// Gespeicherte Sitzung wiederherstellen (ohne Netzanmeldung).
    func restoreSession(sessionId: String, accessToken: String) {
        self.sessionId = sessionId
        self.accessToken = accessToken
    }

    func restore(_ s: CloudSession) -> Bool {
        guard !s.sessionId.isEmpty, !s.accessToken.isEmpty else { return false }
        restoreSession(sessionId: s.sessionId, accessToken: s.accessToken)
        return true
    }

    private func body(_ extra: [String: String]) -> [String: String] {
        var b = ["appId": Self.appId, "src": Self.appId, "format": "2", "clientType": "1", "language": "en_US",
                 "deviceId": MideaCloud.deviceId, "stamp": MideaCloud.stamp(), "sessionId": sessionId]
        b.merge(extra) { $1 }
        return b
    }

    private func request(_ endpoint: String, _ fields: [String: String]) async throws -> [String: Any] {
        var f = fields
        f["sign"] = Self.sign(endpoint: endpoint, fields: fields)
        let form = f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? "")" }
            .joined(separator: "&")
        var req = URLRequest(url: URL(string: Self.base + endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.httpBody = Data(form.utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let r = try await MideaCloud.post(req)
        let code = Int("\(r["errorCode"] ?? "-1")") ?? -1
        guard code == 0 else { throw MideaCloud.CloudError.api(code, MideaCloud.cleanMessage(r["msg"])) }
        return r["result"] as? [String: Any] ?? [:]
    }

    /// Zeichen, die im Formular unverändert bleiben (einmal angelegt statt je Anfrage).
    private static let formAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    static func sign(endpoint: String, fields: [String: String]) -> String {
        let query = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return MideaCloud.sha256Hex(endpoint + query + appKey)
    }

    static func encryptPassword(loginId: String, password: String) -> String {
        MideaCloud.sha256Hex(loginId + MideaCloud.sha256Hex(password) + appKey)
    }

    func login() async throws {
        sessionId = ""; accessToken = ""
        let loginId = try await request("/v1/user/login/id/get", body(["loginAccount": account]))["loginId"] as? String ?? ""
        guard !loginId.isEmpty else {
            throw MideaCloud.CloudError.incompleteLogin("Anmeldung ohne Kennung beantwortet")
        }
        let pwd = Self.encryptPassword(loginId: loginId, password: password)
        let r = try await request("/v1/user/login", body(["loginAccount": account, "password": pwd]))
        let sid = r["sessionId"] as? String ?? "", token = r["accessToken"] as? String ?? ""
        guard !sid.isEmpty, !token.isEmpty else {
            throw MideaCloud.CloudError.incompleteLogin("Anmeldung ohne Sitzung beantwortet")
        }
        sessionId = sid
        accessToken = token
    }

    func token(udpid: String, applianceId: UInt64) async throws -> (String, String)? {
        let r = try await request("/v1/iot/secure/getToken", body(["udpid": udpid, "applianceCodes": "\(applianceId)"]))
        return Self.tokenFrom(r, udpid: udpid)
    }

    func makeSession(account: String, applianceId: String) -> CloudSession? {
        guard canControl else { return nil }
        return CloudSession(account: account, cloud: kind.rawValue, accessToken: accessToken,
                            aesKeyHex: "", aesIvHex: "", sessionId: sessionId,
                            applianceId: applianceId, savedAt: Date())
    }

    func listAppliancesRaw() async throws -> [[String: Any]] {
        let r = try await request("/v1/appliance/user/list/get", body([:]))
        return r["list"] as? [[String: Any]] ?? []
    }

    func transparentSend(_ frame: Data, deviceId: UInt64, applianceId: String) async throws -> [Data] {
        let dataKey: Data
        do { dataKey = try CloudControlClient.deriveDataKey(accessTokenHex: accessToken, appKey: Self.appKey) } catch {
            throw MideaCloud.CloudError.sessionKeys(LogText.t("kit.cloud.sessionKeyUnreadable", "Sitzungsschlüssel unlesbar"))
        }
        let packet = CloudPacket.encode(deviceId: deviceId, frame: frame)
        let order = try CloudControlClient.encryptString(CloudControlClient.csv(packet), dataKey: dataKey)
        let r = try await request("/v1/appliance/transparent/send",
                                  body(["order": order, "funId": "0000", "applianceId": applianceId]))
        guard let reply = r["reply"] as? String else {
            throw MideaCloud.CloudError.badReply(LogText.t("kit.cloud.noApplianceReply", "keine Antwort von der Anlage"))
        }
        let text: String
        do { text = try CloudControlClient.decryptString(reply, dataKey: dataKey) } catch let e as MideaCloud.CloudError {
            throw e
        } catch {
            throw MideaCloud.CloudError.sessionKeys(LogText.t("kit.cloud.sessionKeyMismatch", "Sitzungsschlüssel passt nicht"))
        }
        return try Self.innerFrame(fromCSV: text)
    }
}
