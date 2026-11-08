#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
import _CryptoExtras
#endif
import Foundation

/// Kryptografie des Midea-LAN-Protokolls (nachgebaut nach msmart-ng `lan.Security`).
/// Apple: CommonCrypto (ECB/CBC) und CryptoKit. Windows/Linux: swift-crypto; die Betriebsarten ECB/CBC/PKCS7
/// baut `AESModes` dort aus einzelnen AES-Blöcken (swift-crypto kennt kein ECB).
///
/// **Krypto-Grenzen des Protokolls** (von Midea vorgegeben, nicht änderbar – nur dokumentiert):
/// - V2-Pakete und Discovery: AES-128-**ECB** mit einem **festen, öffentlich bekannten** Schlüssel (MD5 von
///   `signKey`) und eine **MD5**-„Signatur“ mit demselben festen Schlüssel. Das schützt nur gegen
///   Übertragungsfehler, nicht gegen Mitlesen oder Fälschen: jeder im LAN kann Discovery-Antworten bauen.
///   Darum Discovery-Ergebnisse nie ungeprüft übernehmen (neue IP erst nach Handshake mit gespeichertem Token).
/// - V3 (8370): Handshake mit Token/Schlüssel aus der Cloud, danach AES-128-**CBC mit Null-IV** und SHA256 über
///   Klartext (kein HMAC). Geheim sind nur Token und Schlüssel; wer sie hat, kann die Anlage steuern.
/// - Keiner der Vergleiche hier schützt einen geheimen Schlüssel, darum ist kein Vergleich in konstanter Zeit nötig.
/// - Windows/Linux hängen an der Unterstrich-API `_CryptoExtras` (`AES.permute`) aus swift-crypto, festgepinnt in
///   Package.swift. Bei jedem Update von swift-crypto müssen die `AESModes`-Tests gegen CommonCrypto (macOS) grün
///   sein, bevor die Windows-Ausgabe gebaut wird.
enum MideaCrypto {
    static let signKey = Data("xhdiwjnchekd4d512chdjx5d8e4c394D2D7S".utf8)
    static let encKey = md5(signKey)

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// MD5(Paket + fester Schlüssel) – Signatur der V2-Pakete.
    static func sign(_ data: Data) -> Data {
        md5(data + signKey)
    }

    /// AES-128-ECB mit PKCS7 – verschlüsselt den Befehlsrahmen im V2-Paket.
    static func encryptECB(_ data: Data) throws -> Data {
        try encryptECB(key: encKey, data)
    }

    static func decryptECB(_ data: Data) throws -> Data {
        try decryptECB(key: encKey, data)
    }

    /// AES-ECB mit beliebigem Schlüssel und PKCS7 – Cloud-Datenschlüssel (data_key).
    static func encryptECB(key: Data, _ data: Data) throws -> Data {
        try crypt(encrypt: true, key: key, data: data, padding: true, iv: nil)
    }

    static func decryptECB(key: Data, _ data: Data) throws -> Data {
        try crypt(encrypt: false, key: key, data: data, padding: true, iv: nil)
    }

    /// AES-CBC mit Null-IV, ohne Padding – V3-Transport (Daten sind schon auf 16 Byte aufgefüllt).
    static func encryptCBC(key: Data, _ data: Data) throws -> Data {
        try crypt(encrypt: true, key: key, data: data, padding: false, iv: Data(count: 16))
    }

    static func decryptCBC(key: Data, _ data: Data) throws -> Data {
        try crypt(encrypt: false, key: key, data: data, padding: false, iv: Data(count: 16))
    }

    /// AES-CBC mit eigenem IV und PKCS7 – meiju-Cloud-Sitzungsschlüssel (aus accessToken/randomData).
    static func encryptCBC(key: Data, iv: Data, _ data: Data) throws -> Data {
        try crypt(encrypt: true, key: key, data: data, padding: true, iv: iv)
    }

    static func decryptCBC(key: Data, iv: Data, _ data: Data) throws -> Data {
        try crypt(encrypt: false, key: key, data: data, padding: true, iv: iv)
    }

    /// Ein einzelner AES-Block (16 Byte, ECB ohne Padding) – Grundbaustein für `AESModes`.
    static func aesBlock(encrypt: Bool, key: Data, _ block: Data) throws -> Data {
        guard block.count == 16 else { throw MideaError.crypto(AESModes.alignmentError) }
        #if canImport(CommonCrypto)
        return try commonCrypt(encrypt: encrypt, key: key, data: block, options: CCOptions(kCCOptionECBMode), iv: nil)
        #else
        var b = [UInt8](block)
        do {
            if encrypt {
                try AES.permute(&b, key: SymmetricKey(data: key))
            } else {
                try AES.inversePermute(&b, key: SymmetricKey(data: key))
            }
        } catch {
            throw MideaError.crypto(AESModes.paramError)
        }
        return Data(b)
        #endif
    }

    private static func crypt(encrypt: Bool, key: Data, data: Data, padding: Bool, iv: Data?) throws -> Data {
        #if canImport(CommonCrypto)
        var options = padding ? CCOptions(kCCOptionPKCS7Padding) : 0
        if iv == nil { options |= CCOptions(kCCOptionECBMode) }
        return try commonCrypt(encrypt: encrypt, key: key, data: data, options: options, iv: iv)
        #else
        return try AESModes.crypt(encrypt: encrypt, data: data, padding: padding, iv: iv) {
            try aesBlock(encrypt: $0, key: key, $1)
        }
        #endif
    }

    #if canImport(CommonCrypto)
    private static func commonCrypt(encrypt: Bool, key: Data, data: Data, options: CCOptions, iv: Data?) throws -> Data {
        let op = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    withIV(iv) { ivPtr in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options,
                                keyPtr.baseAddress, key.count, ivPtr,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MideaError.crypto(Int(status)) }
        return out.prefix(moved)
    }

    private static func withIV<R>(_ iv: Data?, _ body: (UnsafeRawPointer?) -> R) -> R {
        guard let iv else { return body(nil) }
        return iv.withUnsafeBytes { body($0.baseAddress) }
    }
    #endif
}

/// AES-Betriebsarten ECB (`iv == nil`) und CBC mit optionalem PKCS7, aus einer Blockfunktion gebaut.
/// Läuft auf Windows/Linux produktiv; unter macOS prüfen die Tests sie gegen CommonCrypto.
enum AESModes {
    /// Fehlercodes wie CommonCrypto (kCCParamError, kCCAlignmentError, kCCDecodeError).
    static let paramError = -4300, alignmentError = -4303, decodeError = -4304

    static func crypt(encrypt: Bool, data: Data, padding: Bool, iv: Data?,
                      block: (_ encrypt: Bool, _ block: Data) throws -> Data) throws -> Data {
        if let iv, iv.count != 16 { throw MideaError.crypto(paramError) }
        var input = [UInt8](data)
        if encrypt && padding {
            let pad = 16 - input.count % 16
            input += [UInt8](repeating: UInt8(pad), count: pad)
        }
        guard input.count % 16 == 0 else { throw MideaError.crypto(alignmentError) }
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        var chain = iv.map { [UInt8]($0) }
        for i in stride(from: 0, to: input.count, by: 16) {
            let chunk = Array(input[i..<(i + 16)])
            if encrypt {
                let x = chain.map { zip(chunk, $0).map { $0 ^ $1 } } ?? chunk
                let c = [UInt8](try block(true, Data(x)))
                out += c
                if chain != nil { chain = c }
            } else {
                let p = [UInt8](try block(false, Data(chunk)))
                out += chain.map { zip(p, $0).map { $0 ^ $1 } } ?? p
                if chain != nil { chain = chunk }
            }
        }
        if !encrypt && padding {
            guard let last = out.last, (1...16).contains(Int(last)), out.count >= Int(last),
                  out.suffix(Int(last)).allSatisfy({ $0 == last }) else { throw MideaError.crypto(decodeError) }
            out.removeLast(Int(last))
        }
        return Data(out)
    }
}

public enum MideaError: Error, LocalizedError, Equatable {
    case crypto(Int)
    case protocolError(String)
    case authenticationFailed(String)
    case timeout
    case connectionFailed(String)
    case invalidResponse(String)
    /// Die Anlage hat einen Stellbefehl nach 3 Versuchen nicht übernommen; die Payload ist ihr aktueller Stand.
    case commandNotApplied(ACState)
    /// Die Anlage nimmt gerade keine Verbindung an (nur eine gleichzeitig). `msg` nennt, wer sie vermutlich hält
    /// und was zu tun ist.
    case busy(String)
    /// Die Anlage weist die TCP-Verbindung ab: alte Adresse oder eine andere App hält sie (ohne Beleg für „belegt“).
    case refused
    /// Im Netz nicht erreichbar (Zeitüberschreitung beim Verbinden, keine Route); `msg` ist der Text fürs Protokoll.
    case unreachable(String)
    /// Ein Stellbefehl ging hinaus, danach brach die Verbindung ab: ob er ankam, ist offen. `reason` = ursprünglicher Fehler.
    case outcomeUnknown(String)
    /// „Automatisch“: alle Wege gescheitert, je Weg mit Grund.
    case allPathsFailed([PathFailure])

    /// Deutsch, für Protokoll; Anzeige über `UserMessage` und `connectionDetailText` im Kern (`DisplayNames.swift`).
    public var errorDescription: String? {
        switch self {
        case .crypto(let code): return LogText.t("kit.error.crypto", "Verschlüsselungsfehler ({code})", ["code": String(code)])
        case .protocolError(let msg): return LogText.t("kit.error.protocol", "Protokollfehler: {message}", ["message": msg])
        case .authenticationFailed(let msg): return LogText.t("kit.error.authentication", "Anmeldung an der Anlage fehlgeschlagen: {message}", ["message": msg])
        case .timeout: return LogText.t("kit.error.timeout", "Die Anlage antwortet nicht.")
        case .connectionFailed, .refused, .unreachable, .allPathsFailed:
            return LogText.t("kit.error.noConnection", "Keine Verbindung zur Anlage: {detail}", ["detail": connectionDetail ?? ""])
        case .invalidResponse(let msg): return LogText.t("kit.error.invalidResponse", "Unerwartete Antwort: {message}", ["message": msg])
        case .commandNotApplied: return LogText.t("kit.error.notApplied", "Die Anlage hat die Änderung nicht übernommen – vielleicht steuert gerade eine andere App.")
        case .busy(let msg):
            return msg.isEmpty ? LogText.t("reason.busyShort", "Die Anlage ist gerade belegt. Bitte kurz warten und erneut versuchen.")
                : LogText.t("reason.busy", "Die Anlage ist gerade belegt. {hint}", ["hint": msg])
        case .outcomeUnknown(let reason):
            return LogText.t("kit.error.outcomeUnknown", "Keine Verbindung zur Anlage: {reason} Ob die Änderung angekommen ist, ist unklar – bitte die Anzeige prüfen. (nach dem Senden)", ["reason": reason])
        }
    }

    /// Text hinter „Keine Verbindung zur Anlage: “ bei Verbindungsfehlern, sonst nil.
    public var connectionDetail: String? {
        switch self {
        case .connectionFailed(let msg), .unreachable(let msg): return msg
        case .refused: return NetSocket.refusedText
        case .allPathsFailed(let failures):
            return failures.isEmpty ? PathFailure.noPathText
                : failures.map { "\($0.path.rawValue): \($0.text)" }.joined(separator: " · ")
        default: return nil
        }
    }
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30          // 0–9
            case 0x41...0x46: return c - 0x41 + 10     // A–F
            case 0x61...0x66: return c - 0x61 + 10     // a–f
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    /// Kleinbuchstaben-Hex über eine Nachschlagetabelle (statt `String(format:)` je Byte): wird für jeden
    /// Rahmen im Debug-Protokoll und für Token/Schlüssel benutzt.
    var hex: String {
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

private let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
