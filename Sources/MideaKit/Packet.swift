import Foundation

/// V2-Paket (0x5A5A): trägt den verschlüsselten Befehlsrahmen. Bei V3 steckt es im verschlüsselten 8370-Paket.
enum V2Packet {
    static func encode(deviceId: UInt64, frame: Data, date: Date = Date()) throws -> Data {
        let encrypted = try MideaCrypto.encryptECB(frame)
        let length = 40 + encrypted.count + 16
        var header = Data([0x5A, 0x5A, 0x01, 0x11])
        header.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8)])
        header.append(contentsOf: [0x20, 0x00])
        header.append(Data(count: 4))
        header.append(timestamp(date))
        withUnsafeBytes(of: deviceId.littleEndian) { header.append(contentsOf: $0) }
        header.append(Data(count: 12))
        let packet = header + encrypted
        return packet + MideaCrypto.sign(packet)
    }

    static func decode(_ data: Data) throws -> Data {
        let packet = Data(data)
        guard packet.count >= 6 else { throw MideaError.protocolError("Paket zu kurz") }
        guard packet[0] == 0x5A, packet[1] == 0x5A else { throw MideaError.protocolError("Unbekanntes Paket \(packet.prefix(8).hex)") }
        let length = Int(packet[4]) | Int(packet[5]) << 8
        guard packet.count >= length, length >= 56 else { throw MideaError.protocolError("Paket abgeschnitten") }
        guard (length - 56) % 16 == 0 else { throw MideaError.protocolError("Paketlänge passt nicht") }
        let body = packet.prefix(length)
        guard MideaCrypto.sign(body.prefix(length - 16)) == body.suffix(16) else {
            throw MideaError.protocolError("MD5-Signatur stimmt nicht")
        }
        return try MideaCrypto.decryptECB(Data(body[40..<(length - 16)]))
    }

    /// Zeitstempel wie msmart-ng: Hundertstel, Sek., Min., Std., Tag, Monat, Jahr%100, Jahr/100 (UTC).
    static func timestamp(_ date: Date) -> Data {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 2000
        let millis = Int((date.timeIntervalSince1970 * 1000).rounded()) % 1000
        return Data([UInt8(millis / 10), UInt8(c.second ?? 0), UInt8(c.minute ?? 0),
                     UInt8(c.hour ?? 0), UInt8(c.day ?? 1), UInt8(c.month ?? 1),
                     UInt8(year % 100), UInt8(year / 100)])
    }

    /// Ein gemeinsamer UTC-Kalender statt einer neuen Instanz je Paket (`Calendar` ist ein Werttyp, Lesen ist
    /// threadsicher).
    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return cal
    }()
}

/// V3-Transport (0x8370): Handshake mit Token, danach AES-CBC mit dem ausgehandelten Sitzungsschlüssel.
struct V3Codec {
    enum PacketType: UInt8 {
        case handshakeRequest = 0x0, handshakeResponse = 0x1
        case encryptedResponse = 0x3, encryptedRequest = 0x6, error = 0xF
    }

    var localKey: Data?
    private(set) var packetId: UInt16 = 0
    private var buffer: [UInt8] = []
    var randomBytes: (Int) -> Data = { n in Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

    mutating func encodeHandshake(token: Data) -> Data {
        let packet = header(length: token.count, extra: PacketType.handshakeRequest.rawValue)
            + bigEndian(packetId) + token
        bump()
        return packet
    }

    mutating func encodeEncrypted(_ data: Data) throws -> Data {
        guard let key = localKey else { throw MideaError.protocolError("Nicht angemeldet") }
        let remainder = (data.count + 2) % 16
        let pad = remainder == 0 ? 0 : 16 - remainder
        let hdr = header(length: data.count + pad + 32, extra: UInt8(pad << 4) | PacketType.encryptedRequest.rawValue)
        let payload = bigEndian(packetId) + data + randomBytes(pad)
        bump()
        return hdr + (try MideaCrypto.encryptCBC(key: key, payload)) + MideaCrypto.sha256(hdr + payload)
    }

    /// Sitzungsschlüssel aus der Handshake-Antwort (64 Byte: 32 verschlüsselt + 32 SHA256).
    static func localKey(key: Data, response: Data) throws -> Data {
        guard response.count == 64 else { throw MideaError.authenticationFailed("Handshake-Antwort hat \(response.count) statt 64 Byte") }
        let plain = try MideaCrypto.decryptCBC(key: key, Data(response.prefix(32)))
        guard MideaCrypto.sha256(plain) == Data(response.suffix(32)) else {
            throw MideaError.authenticationFailed("Token oder Schlüssel passen nicht zur Anlage")
        }
        return Data(zip(plain, key).map { $0 ^ $1 })
    }

    /// Größtes 8370-Paket, das wir annehmen. Echte Antworten sind < 300 Byte; ein unsinniges Längenfeld (bis 64 KB)
    /// würde sonst den Strom stauen, bis die Verbindung abbricht.
    static let maxPacketLength = 4096

    /// Nimmt Rohdaten vom Socket auf und liefert alle vollständigen 8370-Pakete. Ein angeschnittenes 0x83 am Ende
    /// bleibt für den nächsten Aufruf liegen; ein Kopf mit unsinniger Länge wird übersprungen (Neusynchronisation).
    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var packets: [Data] = []
        var i = 0 // Lese-Index; der Puffer wird nur einmal am Ende gekürzt
        scan: while i < buffer.count {
            // Nächsten Paketanfang suchen
            guard let start = (i..<buffer.count).first(where: { buffer[$0] == 0x83 }) else { i = buffer.count; break }
            i = start
            guard i + 1 < buffer.count else { break scan } // 0x83 als letztes Byte: behalten
            guard buffer[i + 1] == 0x70 else { i += 1; continue }
            guard buffer.count - i >= 6 else { break scan }
            let total = (Int(buffer[i + 2]) << 8 | Int(buffer[i + 3])) + 8
            guard total <= Self.maxPacketLength else {
                AppLog.debug("8370-Kopf mit unsinniger Länge \(total) verworfen")
                i += 2
                continue
            }
            guard buffer.count - i >= total else { break scan }
            packets.append(Data(buffer[i..<(i + total)]))
            i += total
        }
        if i > 0 { buffer.removeFirst(min(i, buffer.count)) }
        return packets
    }

    func decode(_ packet: Data) throws -> (PacketType, Data) {
        let p = [UInt8](packet)
        guard p.count >= 8, p[0] == 0x83, p[1] == 0x70 else { throw MideaError.protocolError("Ungültiger Paketanfang") }
        guard p[4] == 0x20 else { throw MideaError.protocolError("Ungültiges Kennbyte") }
        guard let type = PacketType(rawValue: p[5] & 0xF) else { throw MideaError.protocolError("Unbekannter Pakettyp") }
        switch type {
        case .handshakeResponse:
            return (type, Data(p[8...]))
        case .encryptedResponse:
            guard let key = localKey else { throw MideaError.protocolError("Nicht angemeldet") }
            guard p.count >= 6 + 32 + 16 else { throw MideaError.protocolError("Paket zu kurz") }
            let hdr = Data(p[0..<6])
            let plain = try MideaCrypto.decryptCBC(key: key, Data(p[6..<(p.count - 32)]))
            guard MideaCrypto.sha256(hdr + plain) == Data(p[(p.count - 32)...]) else {
                throw MideaError.protocolError("SHA256 der Antwort stimmt nicht")
            }
            let pad = Int(p[5] >> 4)
            // Nur die Anlage selbst kann das auslösen (SHA256 vorher geprüft) – trotzdem nie abstürzen.
            guard plain.count >= 2 + pad else { throw MideaError.protocolError("Füllbytes passen nicht zur Paketlänge") }
            return (type, Data(plain[2..<(plain.count - pad)]))
        case .error:
            throw MideaError.protocolError("Die Anlage meldet einen Fehler (Token abgelaufen oder Verbindung belegt)")
        default:
            throw MideaError.protocolError("Unerwarteter Pakettyp \(type)")
        }
    }

    private func header(length: Int, extra: UInt8) -> Data {
        Data([0x83, 0x70, UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), 0x20, extra])
    }

    private func bigEndian(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }

    private mutating func bump() { packetId = (packetId + 1) & 0xFFF }
}
