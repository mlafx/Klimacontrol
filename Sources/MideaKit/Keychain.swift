import Foundation
import Synchronization
#if canImport(Security)
import Security
#elseif os(Windows)
import WinSDK
#endif

/// Zugangsdaten fürs Midea-Konto (nur für die Cloud-Steuerung). Das Passwort liegt nur im macOS-Schlüsselbund bzw.
/// in der Windows-Anmeldeinformationsverwaltung, damit sich Klimacontrol bei Bedarf neu anmelden kann; es verlässt den
/// Rechner nur zur Anmeldung bei Midea und steht nie in device.json oder im Protokoll.
///
/// Abwägung LAN-Token/-Schlüssel: Die liegen bewusst in `device.json` (nur für den eigenen Benutzer lesbar,
/// 0600) – sie gelten nur im eigenen Netz für genau diese Anlage, werden für die Sicherung („Backup“) gebraucht und
/// sollen auch ohne entsperrten Schlüsselbund (z. B. Home Assistant) nutzbar sein.
public struct CloudCredentials: Equatable, Sendable {
    public var account: String
    public var password: String

    public init(account: String, password: String) {
        self.account = account
        self.password = password
    }
}

/// Fehler der Geheimnis-Ablage. „Gesperrt“ ist ausdrücklich etwas anderes als „nicht vorhanden“: bei
/// einem gesperrten Schlüsselbund darf sich die Cloud nicht neu anmelden.
public enum KeychainError: Error, LocalizedError, Equatable {
    /// Schlüsselbund gesperrt, Zugriff abgelehnt oder abgebrochen (Status/Fehlercode des Systems).
    case unavailable(Int)
    /// Speichern fehlgeschlagen (Status/Fehlercode des Systems).
    case saveFailed(Int)
    /// Eintrag zu groß (Windows: höchstens 2560 Byte je Anmeldeinformation).
    case tooLarge(Int)
    /// Eintrag vorhanden, aber unlesbar (z. B. von Hand verändert).
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .unavailable(let s):
            return LogText.t("kit.keychain.unavailable", "Der Schlüsselbund ist gesperrt oder hat den Zugriff abgelehnt. Mac entsperren bzw. den Zugriff erlauben und erneut versuchen. (Status {status})", ["status": String(s)])
        case .saveFailed(let s):
            return LogText.t("kit.keychain.saveFailed", "Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden. Erneut versuchen; die alten Daten bleiben erhalten. (Status {status})", ["status": String(s)])
        case .tooLarge(let n):
            return LogText.t("kit.keychain.tooLarge", "Die Daten sind zu groß für den Geheimnisspeicher. Bitte melden. ({bytes} Byte)", ["bytes": String(n)])
        case .unreadable:
            return LogText.t("kit.keychain.unreadable", "Der gespeicherte Eintrag ist unlesbar. Zugangsdaten in den Einstellungen neu eingeben.")
        }
    }
}

/// Austauschbare Geheimnis-Ablage (Schlüsselbund, Windows-Anmeldeinformationen oder – in Tests – nur im Speicher).
/// `read` liefert nil nur, wenn der Eintrag fehlt; jeder andere Fehler wird geworfen.
public protocol KeychainStore: AnyObject, Sendable {
    func read(service: String) throws -> Data?
    func write(service: String, _ value: Data) throws
    func remove(service: String) throws
}

/// Nur im Speicher (für Tests und `KLIMACONTROL_KEYCHAIN=memory`). `failReads`/`failWrites` bilden einen gesperrten
/// Schlüsselbund nach.
public final class InMemoryKeychain: KeychainStore {
    private struct State {
        var items: [String: Data] = [:]
        var failReads: KeychainError?
        var failWrites: KeychainError?
    }
    private let state = Mutex(State())

    public init() {}

    public var failReads: KeychainError? {
        get { state.withLock { $0.failReads } }
        set { state.withLock { $0.failReads = newValue } }
    }

    public var failWrites: KeychainError? {
        get { state.withLock { $0.failWrites } }
        set { state.withLock { $0.failWrites = newValue } }
    }

    public func read(service: String) throws -> Data? {
        try state.withLock { s in
            if let e = s.failReads { throw e }
            return s.items[service]
        }
    }

    public func write(service: String, _ value: Data) throws {
        try state.withLock { s in
            if let e = s.failWrites { throw e }
            s.items[service] = value
        }
    }

    public func remove(service: String) throws {
        state.withLock { _ = $0.items.removeValue(forKey: service) }
    }
}

/// Der Geheimnisspeicher des Systems: macOS/iOS Schlüsselbund (generisches Passwort), Windows
/// Anmeldeinformationsverwaltung (generische Anmeldeinformation, Ziel = Dienstname, nur dieser Benutzer).
public final class SystemKeychain: KeychainStore, Sendable {
    public init() {}

    #if canImport(Security)
    private func base(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    public func read(service: String) throws -> Data? {
        var query = base(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unreadable }
            return data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unavailable(Int(status))
        }
    }

    /// Erst ändern, nur wenn nichts da ist anlegen: kein Zwischenstand ohne Daten, und die
    /// Freigabe „Immer erlauben“ des bestehenden Eintrags bleibt erhalten.
    public func write(service: String, _ value: Data) throws {
        let update: [String: Any] = [kSecValueData as String: value]
        let status = SecItemUpdate(base(service) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.saveFailed(Int(status)) }
        var add = base(service)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.saveFailed(Int(added)) }
    }

    public func remove(service: String) throws {
        let status = SecItemDelete(base(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unavailable(Int(status)) }
    }
    #elseif os(Windows)
    /// CRED_MAX_CREDENTIAL_BLOB_SIZE (5 × 512 Byte).
    static let maxBlob = 2560
    private func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

    public func read(service: String) throws -> Data? {
        var pcred: PCREDENTIALW?
        guard CredReadW(wide(service), DWORD(CRED_TYPE_GENERIC), 0, &pcred), let cred = pcred else {
            let err = Int(GetLastError())
            if err == 1168 { return nil } // ERROR_NOT_FOUND
            throw KeychainError.unavailable(err)
        }
        defer { CredFree(cred) }
        guard let blob = cred.pointee.CredentialBlob else { return Data() }
        return Data(bytes: blob, count: Int(cred.pointee.CredentialBlobSize))
    }

    /// CredWriteW ersetzt einen vorhandenen Eintrag in einem Schritt (kein Löschen vorher).
    public func write(service: String, _ value: Data) throws {
        guard value.count <= Self.maxBlob else { throw KeychainError.tooLarge(value.count) }
        var target = wide(service)
        var user = wide("Klimacontrol")
        var blob = [UInt8](value)
        var failure: Int?
        target.withUnsafeMutableBufferPointer { t in
            user.withUnsafeMutableBufferPointer { u in
                blob.withUnsafeMutableBufferPointer { b in
                    var cred = CREDENTIALW()
                    cred.`Type` = DWORD(CRED_TYPE_GENERIC)
                    cred.TargetName = t.baseAddress
                    cred.UserName = u.baseAddress
                    cred.CredentialBlobSize = DWORD(b.count)
                    cred.CredentialBlob = b.baseAddress
                    cred.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    if !CredWriteW(&cred, 0) { failure = Int(GetLastError()) }
                }
            }
        }
        if let failure { throw KeychainError.saveFailed(failure) }
    }

    public func remove(service: String) throws {
        if !CredDeleteW(wide(service), DWORD(CRED_TYPE_GENERIC), 0) {
            let err = Int(GetLastError())
            if err != 1168 { throw KeychainError.unavailable(err) }
        }
    }
    #else
    // Weder Schlüsselbund noch Windows: nichts speichern (Cloud meldet sich dann je Programmstart neu an).
    public func read(service: String) throws -> Data? { nil }
    public func write(service: String, _ value: Data) throws {}
    public func remove(service: String) throws {}
    #endif
}

/// Geheimnis-Ablage je Dienstname über den austauschbaren `backend`. In Testprozessen (und mit
/// `KLIMACONTROL_KEYCHAIN=memory`) ist das ein `InMemoryKeychain` – Tests berühren den echten Schlüsselbund nie.
public enum SecretStore {
    private static let current = Mutex<any KeychainStore>(defaultBackend())

    /// Aktuelle Ablage; Tests und Werkzeuge können sie ersetzen (z. B. `SecretStore.backend = InMemoryKeychain()`).
    public static var backend: any KeychainStore {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    static func defaultBackend() -> any KeychainStore {
        if ProcessInfo.processInfo.environment["KLIMACONTROL_KEYCHAIN"] == "memory" || TestEnvironment.isRunningTests {
            return InMemoryKeychain()
        }
        return SystemKeychain()
    }

    static func read(service: String) throws -> Data? { try backend.read(service: service) }
    static func write(service: String, _ value: Data) throws { try backend.write(service: service, value) }

    /// Ohne Rückmeldung (alte Aufrufer); Fehler landen im Protokoll. Neuer Code nimmt `write`.
    @discardableResult
    static func save(service: String, _ value: Data) -> Bool {
        do { try write(service: service, value); return true } catch {
            AppLog.error(LogText.t("log.keychain.notSaved", "Geheimnisspeicher: {service} nicht gespeichert ({error}, {bytes} Byte)", ["service": service, "error": error.localizedDescription, "bytes": String(value.count)]))
            return false
        }
    }

    /// nil bei „fehlt“ und bei Fehler (Fehler wird protokolliert). Wer beides unterscheiden muss, nimmt `read`.
    static func load(service: String) -> Data? {
        do { return try read(service: service) } catch {
            AppLog.error(LogText.t("log.keychain.notReadable", "Geheimnisspeicher: {service} nicht lesbar ({error})", ["service": service, "error": error.localizedDescription]))
            return nil
        }
    }

    static func delete(service: String) {
        do { try backend.remove(service: service) } catch {
            AppLog.error(LogText.t("log.keychain.notRemoved", "Geheimnisspeicher: {service} nicht entfernt ({error})", ["service": service, "error": error.localizedDescription]))
        }
    }
}

public enum CloudKeychain {
    private static let service = "de.mlafx.klimacontrol.cloud"

    /// Speichert und meldet Fehler. Die alten Daten bleiben bei einem Fehler erhalten.
    public static func store(_ creds: CloudCredentials) throws {
        let value = try JSONSerialization.data(withJSONObject: ["account": creds.account, "password": creds.password])
        try SecretStore.write(service: service, value)
        MideaCloudSession.forget(account: creds.account) // neue Zugangsdaten = Nutzer hat gehandelt
    }

    /// Wie `store`, aber ohne Rückmeldung (Fehler nur im Protokoll). Neuer Code nimmt `store`.
    public static func save(_ creds: CloudCredentials) {
        do { try store(creds) } catch { AppLog.error(LogText.t("log.keychain.accountNotSaved", "Cloud-Konto nicht gespeichert: {error}", ["error": error.localizedDescription])) }
    }

    /// Unterscheidet „fehlt“ (nil) von „gesperrt/Fehler“ (wirft).
    public static func lookup() throws -> CloudCredentials? {
        guard let data = try SecretStore.read(service: service) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let account = json["account"], let password = json["password"] else { throw KeychainError.unreadable }
        return CloudCredentials(account: account, password: password)
    }

    /// nil bei „fehlt“ oder Fehler. Wer beides unterscheiden muss, nimmt `lookup()`.
    public static func load() -> CloudCredentials? {
        do { return try lookup() } catch {
            AppLog.error(LogText.t("log.keychain.accountNotReadable", "Cloud-Konto nicht lesbar: {error}", ["error": error.localizedDescription]))
            return nil
        }
    }

    /// „Cloud-Konto entfernen“: löscht das Passwort aus dem Schlüsselbund und vergisst die Cloud-Sitzungen im Speicher.
    public static func clear() {
        SecretStore.delete(service: service)
        MideaCloudSession.forgetAll()
    }
}

/// Welche der beiden Midea-Clouds eine Sitzung nutzt (Rohwert = bisheriger Text in gespeicherten Sitzungen).
public enum CloudKind: String, Codable, Sendable, CaseIterable {
    case smartHome = "MSmartHome"
    case netHomePlus = "NetHome Plus"
}

/// Eine bestehende Cloud-Sitzung (Token + abgeleitete Schlüssel). Wird nach einer erfolgreichen Anmeldung
/// gespeichert und beim nächsten Mal wiederverwendet, damit sich die App nicht ständig neu anmeldet
/// (jede Neuanmeldung löst bei Midea die Meldung „Konto anderswo eingeloggt“ aus).
public struct CloudSession: Codable, Equatable, Sendable {
    public var account: String
    public var cloud: String        // CloudKind.rawValue: "MSmartHome" oder "NetHome Plus"
    public var accessToken: String
    public var aesKeyHex: String    // meiju-Sitzungsschlüssel (leer bei NetHome Plus)
    public var aesIvHex: String
    public var sessionId: String    // NetHome Plus (leer bei meiju)
    public var applianceId: String
    public var savedAt: Date
    /// Geräte-ID der Anlage, für die die Sitzung gilt (nil bei älteren gespeicherten Sitzungen bzw. ohne Anlage).
    public var deviceId: UInt64?

    public var kind: CloudKind? { CloudKind(rawValue: cloud) }
}

/// Ablage der Cloud-Sitzung im Schlüsselbund (enthält den Access-Token, daher Keychain, nicht device.json).
public enum CloudSessionStore {
    private static let service = "de.mlafx.klimacontrol.cloud.session"

    public static func store(_ session: CloudSession) throws {
        try SecretStore.write(service: service, try JSONEncoder().encode(session))
    }

    public static func save(_ session: CloudSession) {
        do { try store(session) } catch { AppLog.error(LogText.t("log.keychain.sessionNotSaved", "Cloud-Sitzung nicht gespeichert: {error}", ["error": error.localizedDescription])) }
    }

    /// Gespeicherte Sitzung zum Konto (und zur Anlage, falls angegeben). nil = keine passende; wirft, wenn der
    /// Schlüsselbund gesperrt ist (dann nicht neu anmelden). Eine unlesbare Sitzung gilt als fehlend.
    public static func lookup(account: String, deviceId: UInt64?) throws -> CloudSession? {
        guard let data = try SecretStore.read(service: service),
              let session = try? JSONDecoder().decode(CloudSession.self, from: data),
              session.account == account.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let deviceId, let saved = session.deviceId, saved != deviceId { return nil }
        return session
    }

    /// Lädt die gespeicherte Sitzung, aber nur, wenn sie zum angefragten Konto und zur Anlage gehört
    /// (sonst gingen Cloud-Befehle nach einem Anlagenwechsel an die alte Anlage).
    public static func load(account: String, deviceId: UInt64) -> CloudSession? {
        (try? lookup(account: account, deviceId: deviceId)) ?? nil
    }

    public static func clear() {
        SecretStore.delete(service: service)
    }
}
