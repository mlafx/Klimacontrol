import Foundation

/// Eine im WLAN gefundene Midea-Anlage (Antwort auf den Discovery-Broadcast).
public struct DiscoveredDevice: Equatable, Hashable, Identifiable, Sendable {
    public var id: UInt64 { deviceId }
    public let ip: String
    public let port: UInt16
    public let deviceId: UInt64
    public let sn: String
    public let name: String
    /// 0xAC = Klimaanlage
    public let type: Int
    public let version: Int
    /// Nur bei Einträgen aus der Cloud: meldet die Cloud die Anlage als verbunden?
    public var cloudOnline: Bool? = nil

    public var isAirConditioner: Bool { type == 0xAC || type == 0xCC }
    /// Nur über die Cloud bekannt (keine Antwort im WLAN, z. B. weil die Anlage ausgeschaltet ist).
    public var isCloudOnly: Bool { ip.isEmpty }
}

extension DiscoveredDevice {
    /// Eintrag für eine Anlage aus der Appliance-Liste des Kontos (ohne IP).
    public init(cloud a: CloudAppliance) {
        self.init(ip: "", port: 0, deviceId: a.deviceId, sn: "", name: a.name, type: a.type, version: 0, cloudOnline: a.online)
    }
}

/// Netzwerksuche wie msmart-ng `Discover`: UDP an Port 6445 und 20086, Antwort mit AES-ECB (fester Midea-Schlüssel).
public enum Discovery {
    static let message = Data([
        0x5a, 0x5a, 0x01, 0x11, 0x48, 0x00, 0x92, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7f, 0x75, 0xbd, 0x6b, 0x3e, 0x4f, 0x8b, 0x76,
        0x2e, 0x84, 0x9c, 0x6e, 0x57, 0x8d, 0x65, 0x90, 0x03, 0x6e, 0x9d, 0x43, 0x42, 0xa5, 0x0f, 0x1f,
        0x56, 0x9e, 0xb8, 0xec, 0x91, 0x8e, 0x92, 0xe5,
    ])

    /// Sucht Anlagen per Broadcast (oder gezielt an `target`) und wartet `timeout` Sekunden auf Antworten.
    public static func scan(target: String = "255.255.255.255", timeout: TimeInterval = 4) async throws -> [DiscoveredDevice] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try scanBlocking(target: target, timeout: timeout) })
            }
        }
    }

    static func scanBlocking(target: String, timeout: TimeInterval,
                             stop: ((DiscoveredDevice) -> Bool)? = nil) throws -> [DiscoveredDevice] {
        let s = try NetSocket.udpBroadcast()
        defer { s.close() }

        var sentAny = false
        var lastError: Int32 = 0
        for port: UInt16 in [6445, 20086] {
            for _ in 0..<3 {
                if let err = s.send(message, toIPv4: target, port: port) { lastError = err } else { sentAny = true }
            }
        }
        AppLog.debug(LogText.t("log.discovery.broadcast", "Suche: Broadcast an {target} Port 6445 und 20086 (je 3×), warte {seconds} s", ["target": target, "seconds": String(Int(timeout))]))
        guard sentAny else {
            throw MideaError.connectionFailed(NetSocket.isUnreachable(lastError)
                ? LANClient.localNetworkHint : LogText.t("kit.discovery.searchFailed", "Suche nicht möglich: {error}", ["error": NetSocket.describe(lastError)]))
        }

        var found: [String: DiscoveredDevice] = [:]
        var buf = [UInt8](repeating: 0, count: 2048)
        collect(s, until: Date().addingTimeInterval(timeout), into: &found, buf: &buf, label: LogText.t("log.discovery.labelSearch", "Suche"), stop: stop)
        let list = found.values.sorted { $0.ip < $1.ip }
        AppLog.write(LogText.t("log.discovery.result", "Suche an {target}: {result}", ["target": target, "result": foundText(list)]))
        return list
    }

    /// Antwort zerlegen (V2: 0x5A5A, V3: 0x8370 mit 8 Byte Kopf und 16 Byte Anhang). Jede Antwort kommt von
    /// irgendeinem Rechner im LAN, ohne Schlüssel: darum alle Längen prüfen – kurze, abgeschnittene oder
    /// unsinnige Pakete werfen `invalidResponse`, nie Absturz. Das innere V2-Paket muss die MD5-Signatur
    /// (fester, öffentlicher Schlüssel) tragen – das schützt nur gegen Übertragungsfehler, nicht gegen Fälschung;
    /// eine neue IP darf darum erst nach gelungenem Handshake mit gespeichertem Token übernommen werden.
    static func parse(_ data: Data, ip: String) throws -> DiscoveredDevice {
        var p = [UInt8](data)
        guard p.count >= 8 else { throw MideaError.invalidResponse(LogText.t("kit.discovery.tooShort", "Discovery-Antwort zu kurz")) }
        let version: Int
        if p[0] == 0x83 && p[1] == 0x70 {
            version = 3
            // 8 Byte Kopf + V2-Paket + 16 Byte Anhang
            // Längenfeld des 8370-Kopfs (Bytes 2–3, ohne die 8 Byte Kopf) muss ins Paket passen.
            let outer = (Int(p[2]) << 8 | Int(p[3])) + 8
            guard outer >= 8 + 56 + 16, outer <= p.count else { throw MideaError.invalidResponse(LogText.t("kit.discovery.tooShort", "Discovery-Antwort zu kurz")) }
            p = Array(p[8..<(outer - 16)])
        } else if p[0] == 0x5A && p[1] == 0x5A {
            version = 2
        } else {
            throw MideaError.invalidResponse(LogText.t("kit.discovery.unknownDevice", "Unbekanntes Gerät (V1 wird nicht unterstützt)"))
        }
        guard p.count >= 56, p[0] == 0x5A, p[1] == 0x5A else { throw MideaError.invalidResponse(LogText.t("kit.discovery.tooShort", "Discovery-Antwort zu kurz")) }
        // Längenfeld des V2-Pakets: muss zum Inhalt passen (überzählige Bytes am Ende werden ignoriert).
        let length = Int(p[4]) | Int(p[5]) << 8
        guard length >= 56 + 16, length <= p.count, (length - 56) % 16 == 0 else {
            throw MideaError.invalidResponse(LogText.t("kit.discovery.badLength", "Discovery-Antwort mit falscher Länge"))
        }
        p = Array(p[0..<length])
        guard MideaCrypto.sign(Data(p[0..<(length - 16)])) == Data(p[(length - 16)...]) else {
            throw MideaError.invalidResponse(LogText.t("kit.discovery.badSignature", "Discovery-Antwort mit falscher Signatur"))
        }
        var id: UInt64 = 0
        for (i, b) in p[20..<26].enumerated() { id |= UInt64(b) << (8 * UInt64(i)) }
        let plain = [UInt8](try MideaCrypto.decryptECB(Data(p[40..<(length - 16)])))
        guard plain.count > 41 else { throw MideaError.invalidResponse(LogText.t("kit.discovery.profileTooShort", "Steckbrief zu kurz")) }
        let port = UInt16(plain[4]) | UInt16(plain[5]) << 8
        let sn = DeviceConfig.cleanText(String(decoding: plain[8..<40], as: UTF8.self), fallback: "")
        let nameLen = Int(plain[40])
        let name = DeviceConfig.cleanText(String(decoding: plain[41..<min(plain.count, 41 + nameLen)], as: UTF8.self),
                                          fallback: "")
        let type = name.split(separator: "_").dropFirst().first.flatMap { Int($0, radix: 16) } ?? 0
        return DiscoveredDevice(ip: ip, port: port, deviceId: id, sn: sn, name: name, type: type, version: version)
    }

    // MARK: Anlage über die Geräte-ID wiederfinden (Adresse neu suchen)

    /// Sucht die Anlage mit `deviceId`: zuerst Broadcast, ohne Treffer dann Subnetz-Scan. Endet beim ersten
    /// Treffer. nil = nicht gefunden. Wirft nur, wenn keine der beiden Suchen überhaupt senden konnte.
    /// Achtung: Das Ergebnis ist ungeprüft (Discovery hat keinen geheimen Schlüssel) – die neue Adresse erst nach
    /// gelungenem Handshake mit dem gespeicherten Token übernehmen.
    public static func find(deviceId: UInt64, timeout: TimeInterval = 4) async throws -> DiscoveredDevice? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try findBlocking(deviceId: deviceId, timeout: timeout) })
            }
        }
    }

    private static func foundText(_ list: [DiscoveredDevice]) -> String {
        list.isEmpty ? LogText.t("log.discovery.nothing", "nichts gefunden")
            : list.map { "\($0.name) \($0.ip) V\($0.version)" }.joined(separator: ", ")
    }

    static func findBlocking(deviceId: UInt64, timeout: TimeInterval) throws -> DiscoveredDevice? {
        let match: (DiscoveredDevice) -> Bool = { $0.deviceId == deviceId && DeviceConfig.isIPv4($0.ip) }
        var firstError: (any Error)?
        do {
            if let d = try scanBlocking(target: "255.255.255.255", timeout: timeout, stop: match).first(where: match) {
                AppLog.write(LogText.t("log.discovery.foundBroadcast", "Anlage {id} per Broadcast gefunden unter {ip}", ["id": String(deviceId), "ip": d.ip]))
                return d
            }
        } catch { firstError = error }
        do {
            if let d = try scanSubnetBlocking(timeout: timeout, progress: nil, stop: match).first(where: match) {
                AppLog.write(LogText.t("log.discovery.foundScan", "Anlage {id} per Netz-Scan gefunden unter {ip}", ["id": String(deviceId), "ip": d.ip]))
                return d
            }
        } catch {
            if let firstError { throw firstError }
        }
        AppLog.write(LogText.t("log.discovery.notFound", "Anlage {id} im Netz nicht gefunden", ["id": String(deviceId)]))
        return nil
    }

    /// udpid für den Token-Abruf: SHA256 der 6-Byte-Geräte-ID, erste und zweite Hälfte XOR.
    public static func udpid(deviceId: UInt64, bigEndian: Bool) -> String {
        var bytes = (0..<6).map { UInt8(truncatingIfNeeded: deviceId >> (8 * UInt64($0))) }
        if bigEndian { bytes.reverse() }
        let h = [UInt8](MideaCrypto.sha256(Data(bytes)))
        return Data(zip(h[0..<16], h[16..<32]).map { $0 ^ $1 }).hex
    }

    // MARK: Subnetz-Scan (Unicast an jede Adresse – wenn der Broadcast nicht zugestellt wird)

    /// Fragt jede Adresse der eigenen IPv4-Netze einzeln (beide Ports) plus die gerichtete Broadcast-Adresse und
    /// sammelt die Antworten wie `scan`. `progress(gesendet, gesamt)` kommt aus einer Hintergrundqueue.
    public static func scanSubnet(timeout: TimeInterval = 4,
                                  progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [DiscoveredDevice] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try scanSubnetBlocking(timeout: timeout, progress: progress) })
            }
        }
    }

    static func scanSubnetBlocking(timeout: TimeInterval, progress: (@Sendable (Int, Int) -> Void)?,
                                   stop: ((DiscoveredDevice) -> Bool)? = nil) throws -> [DiscoveredDevice] {
        let nets = NetSocket.localNetworks()
        var targets: [String] = []
        var seen = Set<String>()
        for n in nets {
            guard let net = hosts(ip: n.ip, mask: n.mask) else { continue }
            targets += (net.hosts + [net.broadcast]).filter { seen.insert($0).inserted }
        }
        guard !targets.isEmpty else {
            throw MideaError.connectionFailed(LogText.t("kit.discovery.noNetwork", "Kein aktives Netz gefunden – ist der Rechner mit WLAN oder Ethernet verbunden?"))
        }
        AppLog.debug(LogText.t("log.discovery.scanPlan", "Netz-Scan: {nets} → {count} Adressen, warte {seconds} s", ["nets": nets.map { "\($0.ip)/\($0.mask)" }.joined(separator: ", "), "count": String(targets.count), "seconds": String(Int(timeout))]))

        let s = try NetSocket.udpBroadcast() // Broadcast-Flag für die gerichtete Broadcast-Adresse
        defer { s.close() }
        var found: [String: DiscoveredDevice] = [:]
        var buf = [UInt8](repeating: 0, count: 2048)
        var sent = 0
        for target in targets {
            for port: UInt16 in [6445, 20086] { _ = s.send(message, toIPv4: target, port: port) } // Einzelfehler egal
            sent += 1
            // Alle 32 Adressen kurz Antworten einsammeln, damit weder Sende- noch Empfangspuffer überlaufen.
            if sent % 32 == 0 || sent == targets.count {
                progress?(sent, targets.count)
                if collect(s, until: Date().addingTimeInterval(0.005), into: &found, buf: &buf, label: LogText.t("log.discovery.labelScan", "Netz-Scan"), stop: stop) {
                    break
                }
            }
        }
        if stop == nil || !found.values.contains(where: { stop!($0) }) {
            collect(s, until: Date().addingTimeInterval(timeout), into: &found, buf: &buf, label: LogText.t("log.discovery.labelScan", "Netz-Scan"), stop: stop)
        }
        let list = found.values.sorted { $0.ip < $1.ip }
        AppLog.write(LogText.t("log.discovery.scanResult", "Netz-Scan über {count} Adressen: {result}", ["count": String(targets.count), "result": foundText(list)]))
        return list
    }

    /// Antworten bis `deadline` einsammeln (eine je Absender-IP). Mit `stop`: endet beim ersten passenden Fund
    /// und meldet dann true.
    @discardableResult
    private static func collect(_ s: NetSocket, until deadline: Date, into found: inout [String: DiscoveredDevice],
                                buf: inout [UInt8], label: String, stop: ((DiscoveredDevice) -> Bool)? = nil) -> Bool {
        while deadline.timeIntervalSinceNow > 0 {
            guard s.wait(timeoutMs: Int32(max(0, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            guard let (n, ip) = s.receiveFrom(into: &buf), n > 0, n <= buf.count, found[ip] == nil else { continue }
            AppLog.debug(LogText.t("log.discovery.reply", "{label}: Antwort von {ip} ({bytes} Byte) {hex}…", ["label": label, "ip": ip, "bytes": String(n), "hex": Data(buf[0..<min(n, 64)]).hex]))
            do {
                let dev = try parse(Data(buf[0..<n]), ip: ip)
                found[ip] = dev
                AppLog.debug(LogText.t("log.discovery.device", "{label}: {name} {ip} Typ 0x{type} V{version} Port {port} id {id} SN {sn}", ["label": label, "name": dev.name, "ip": ip, "type": String(dev.type, radix: 16), "version": String(dev.version), "port": String(dev.port), "id": String(dev.deviceId), "sn": dev.sn]))
                if let stop, stop(dev) { return true }
            } catch {
                AppLog.debug(LogText.t("log.discovery.unreadable", "{label}: Antwort von {ip} nicht lesbar: {error}", ["label": label, "ip": ip, "error": error.localizedDescription]))
            }
        }
        return false
    }

    /// Hosts eines IPv4-Netzes aus Adresse + Maske: alle Adressen außer Netz, Broadcast und der eigenen, dazu die
    /// gerichtete Broadcast-Adresse. Netze größer als /22 werden auf das /24 der eigenen Adresse beschränkt
    /// (sonst Zehntausende Datagramme). nil bei ungültiger Maske oder ohne Hosts (/31, /32).
    static func hosts(ip: String, mask: String) -> (hosts: [String], broadcast: String)? {
        guard let addr = ipv4Value(ip), let m = ipv4Value(mask) else { return nil }
        var prefix = 32 - m.trailingZeroBitCount
        guard prefix > 0, m == ~UInt32(0) << UInt32(32 - prefix) else { return nil } // Maske nicht zusammenhängend
        if prefix < 22 { prefix = 24 }
        guard prefix <= 30 else { return nil }
        let netmask = ~UInt32(0) << (32 - prefix)
        let network = addr & netmask
        let broadcast = network | ~netmask
        let list = ((network + 1)..<broadcast).filter { $0 != addr }.map(dotted)
        return (list, dotted(broadcast))
    }

    static func ipv4Value(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    static func dotted(_ v: UInt32) -> String {
        "\(v >> 24).\(v >> 16 & 0xff).\(v >> 8 & 0xff).\(v & 0xff)"
    }
}

extension PortaSplitDevice {
    /// Prüft Token und Schlüssel per Handshake, ohne etwas zu verändern.
    public static func verify(_ config: DeviceConfig, quiet: Bool = false) async -> Bool {
        guard let dev = try? PortaSplitDevice(config: config) else { return false }
        dev.quietErrors = quiet
        defer { dev.disconnect() }
        return (try? await dev.refresh()) != nil
    }
}
