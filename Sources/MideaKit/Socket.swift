#if os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation

/// Dünne Hülle um BSD-Sockets (macOS/iOS) bzw. Winsock (Windows) – nur das, was LAN-Steuerung und Suche brauchen.
/// Blockierend; Zeitlimits über poll/WSAPoll.
struct NetSocket {
    #if os(Windows)
    typealias Handle = SOCKET
    #else
    typealias Handle = Int32
    #endif

    let handle: Handle

    // MARK: Fehlercodes (errno bzw. WSAGetLastError)

    #if os(Windows)
    private static let inProgress: Int32 = 10035     // WSAEWOULDBLOCK (nicht blockierendes connect)
    private static let netUnreach: Int32 = 10051     // WSAENETUNREACH
    private static let connReset: Int32 = 10054      // WSAECONNRESET
    private static let connRefused: Int32 = 10061    // WSAECONNREFUSED
    private static let hostUnreach: Int32 = 10065    // WSAEHOSTUNREACH
    private static let pollRead: Int16 = 0x0100      // POLLRDNORM (POLLIN ist unter Windows ein zusammengesetztes Makro)
    private static let pollWrite: Int16 = 0x0010     // POLLWRNORM
    #else
    private static let inProgress = EINPROGRESS
    private static let netUnreach = ENETUNREACH
    private static let connReset = ECONNRESET
    private static let connRefused = ECONNREFUSED
    private static let hostUnreach = EHOSTUNREACH
    private static let pollRead = Int16(POLLIN)
    private static let pollWrite = Int16(POLLOUT)
    #endif

    static var lastError: Int32 {
        #if os(Windows)
        WSAGetLastError()
        #else
        errno
        #endif
    }

    static func describe(_ code: Int32) -> String {
        #if os(Windows)
        "Winsock-Fehler \(code)"
        #else
        String(cString: strerror(code))
        #endif
    }

    /// Neutraler Text für eine abgewiesene Verbindung (kein Rückschluss auf „belegt“).
    static var refusedText: String { LogText.t("reason.refused", "Die Anlage weist die Verbindung ab. Stimmt die Adresse noch? Sonst „Adresse neu suchen“ – oder eine andere App hält die Anlage gerade.") }

    static func isUnreachable(_ code: Int32) -> Bool { code == hostUnreach || code == netUnreach }

    /// Fehler einer bestehenden Verbindung (Lesen, Warten, Senden) als `MideaError`; keine Route = nicht erreichbar.
    static func failure(_ code: Int32, prefix: String = "") -> MideaError {
        code == hostUnreach ? .unreachable(prefix + describe(code)) : .connectionFailed(.other(prefix + describe(code)))
    }
    static func isRefused(_ code: Int32) -> Bool { code == connReset || code == connRefused }

    #if os(Windows)
    /// Winsock muss einmal je Prozess gestartet werden.
    private static let winsockStarted: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()
    #endif

    private static func open(type: Int32, proto: Int32) throws -> NetSocket {
        #if os(Windows)
        guard winsockStarted else { throw MideaError.connectionFailed(.other(LogText.t("kit.socket.winsock", "Winsock nicht verfügbar"))) }
        let s = WinSDK.socket(AF_INET, type, proto)
        guard s != INVALID_SOCKET else { throw MideaError.connectionFailed(.other(LogText.t("kit.socket.createFailed", "Socket: {error}", ["error": describe(lastError)]))) }
        #else
        let s = Darwin.socket(AF_INET, type, proto)
        guard s >= 0 else { throw MideaError.connectionFailed(.other(LogText.t("kit.socket.createFailed", "Socket: {error}", ["error": describe(lastError)]))) }
        #endif
        return NetSocket(handle: s)
    }

    func close() {
        #if os(Windows)
        closesocket(handle)
        #else
        Darwin.close(handle)
        #endif
    }

    private func setOption(_ name: Int32, _ value: Int32) {
        var v = value
        #if os(Windows)
        withUnsafeBytes(of: &v) {
            _ = setsockopt(handle, SOL_SOCKET, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count))
        }
        #else
        setsockopt(handle, SOL_SOCKET, name, &v, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Zeitlimit fürs Senden: ein volles Sendefenster blockiert sonst die Geräte-Queue unbegrenzt.
    private func setSendTimeout(ms: Int32) {
        #if os(Windows)
        var v = UInt32(ms)   // DWORD in Millisekunden
        withUnsafeBytes(of: &v) {
            _ = setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count))
        }
        #else
        var tv = timeval(tv_sec: Int(ms / 1000), tv_usec: Int32(ms % 1000) * 1000)
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    /// Unterbrochener Systemaufruf (Signal) – dann einfach wiederholen.
    static func isInterrupted(_ code: Int32) -> Bool {
        #if os(Windows)
        code == 10004   // WSAEINTR
        #else
        code == EINTR
        #endif
    }

    private func setNonBlocking(_ on: Bool) {
        #if os(Windows)
        var mode: u_long = on ? 1 : 0
        _ = ioctlsocket(handle, Int32(bitPattern: 0x8004_667E), &mode)   // FIONBIO
        #else
        let flags = fcntl(handle, F_GETFL)
        _ = fcntl(handle, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
        #endif
    }

    private func pendingError() -> Int32 {
        var err: Int32 = 0
        #if os(Windows)
        var len = Int32(MemoryLayout<Int32>.size)
        withUnsafeMutableBytes(of: &err) {
            _ = getsockopt(handle, SOL_SOCKET, SO_ERROR, $0.baseAddress!.assumingMemoryBound(to: CChar.self), &len)
        }
        #else
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(handle, SOL_SOCKET, SO_ERROR, &err, &len)
        #endif
        return err
    }

    /// Wartet, bis lesbar (`write == false`) bzw. schreibbar; > 0 bereit, 0 Zeitlimit, < 0 Fehler.
    func wait(write: Bool = false, timeoutMs: Int32) -> Int32 {
        #if os(Windows)
        var pfd = WSAPOLLFD(fd: handle, events: write ? Self.pollWrite : Self.pollRead, revents: 0)
        return WSAPoll(&pfd, 1, timeoutMs)
        #else
        // Bei EINTR mit der Restzeit weiter warten statt einen Fehler zu melden.
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000)
        var ms = timeoutMs
        while true {
            var pfd = pollfd(fd: handle, events: write ? Self.pollWrite : Self.pollRead, revents: 0)
            let r = poll(&pfd, 1, ms)
            guard r < 0, Self.isInterrupted(errno) else { return r }
            ms = timeoutMs < 0 ? timeoutMs : Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        }
        #endif
    }

    // MARK: TCP

    /// Verbindet per TCP mit Zeitlimit. Fehlertexte sind schon für die Anzeige formuliert.
    static func connectTCP(host: String, port: UInt16, timeoutMs: Int32) throws -> NetSocket {
        #if os(Windows)
        guard winsockStarted else { throw MideaError.connectionFailed(.other(LogText.t("kit.socket.winsock", "Winsock nicht verfügbar"))) }
        #endif
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Int32(SOCK_STREAM)
        // Nur Ziffernadressen, nie eine Namensauflösung (kein DNS-Hänger, kein Umleiten über Namen).
        #if os(Windows)
        hints.ai_flags = 0x04   // AI_NUMERICHOST
        #else
        hints.ai_flags = AI_NUMERICHOST
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else {
            throw MideaError.connectionFailed(.other(LogText.t("kit.socket.invalidHost", "Adresse {host} ungültig", ["host": host])))
        }
        defer { freeaddrinfo(res) }
        #if os(Windows)
        let s = try open(type: Int32(SOCK_STREAM), proto: Int32(IPPROTO_TCP.rawValue))
        #else
        let s = try open(type: SOCK_STREAM, proto: IPPROTO_TCP)
        s.setOption(SO_NOSIGPIPE, 1)
        #endif

        // Verbinden mit Zeitlimit (nicht blockierend + poll).
        s.setNonBlocking(true)
        #if os(Windows)
        let rc = WinSDK.connect(s.handle, ai.pointee.ai_addr, Int32(ai.pointee.ai_addrlen))
        #else
        let rc = Darwin.connect(s.handle, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        #endif
        if rc != 0 {
            let code = lastError
            if code != inProgress {
                s.close()
                throw MideaError.connectionFailed(.other(isUnreachable(code) ? LANClient.localNetworkHint : describe(code)))
            }
        }
        if s.wait(write: true, timeoutMs: timeoutMs) <= 0 {
            s.close()
            throw MideaError.unreachable(LogText.t("kit.socket.connectTimeout", "Zeitüberschreitung beim Verbinden mit {host}", ["host": host]))
        }
        let err = s.pendingError()
        if err != 0 {
            s.close()
            // Abgewiesen: falsche/alte Adresse oder belegt. Neutral melden; `LANClient` macht „belegt“ daraus,
            // wenn die Anlage hier kurz vorher antwortete.
            if isRefused(err) { throw MideaError.refused }
            throw MideaError.connectionFailed(.other(isUnreachable(err) ? LANClient.localNetworkHint : describe(err)))
        }
        s.setNonBlocking(false)
        s.setSendTimeout(ms: 4000)
        return s
    }

    func send(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buf in
            while sent < data.count {
                let p = buf.baseAddress!.advanced(by: sent)
                #if os(Windows)
                let n = Int(WinSDK.send(handle, p.assumingMemoryBound(to: CChar.self), Int32(data.count - sent), 0))
                #else
                let n = Darwin.send(handle, p, data.count - sent, 0)
                #endif
                if n < 0, Self.isInterrupted(Self.lastError) { continue }
                if n <= 0 { throw Self.failure(Self.lastError, prefix: "Senden: ") }
                sent += n
            }
        }
    }

    /// Liest, was da ist (blockierend; vorher `wait`). 0 = Gegenseite hat geschlossen, < 0 Fehler.
    func receive(into buf: inout [UInt8]) -> Int {
        buf.withUnsafeMutableBytes { b in
            #if os(Windows)
            Int(recv(handle, b.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(b.count), 0))
            #else
            recv(handle, b.baseAddress, b.count, 0)
            #endif
        }
    }

    // MARK: UDP

    static func udpBroadcast() throws -> NetSocket {
        #if os(Windows)
        let s = try open(type: Int32(SOCK_DGRAM), proto: Int32(IPPROTO_UDP.rawValue))
        #else
        let s = try open(type: SOCK_DGRAM, proto: IPPROTO_UDP)
        #endif
        s.setOption(SO_BROADCAST, 1)
        return s
    }

    /// Sendet ein Datagramm an eine IPv4-Adresse; nil bei Erfolg, sonst der Fehlercode.
    func send(_ data: Data, toIPv4 ip: String, port: UInt16) -> Int32? {
        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = port.bigEndian
        // Ungültige Adresse nicht still als 0.0.0.0 senden.
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return -1 }
        let n = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    #if os(Windows)
                    Int(sendto(handle, buf.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(buf.count), 0,
                               $0, Int32(MemoryLayout<sockaddr_in>.size)))
                    #else
                    sendto(handle, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #endif
                }
            }
        }
        return n > 0 ? nil : Self.lastError
    }

    /// Empfängt ein Datagramm; liefert Länge und Absender-IP (nil bei Fehler).
    func receiveFrom(into buf: inout [UInt8]) -> (count: Int, ip: String)? {
        var from = sockaddr_in()
        #if os(Windows)
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let n = buf.withUnsafeMutableBytes { b in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    #if os(Windows)
                    Int(recvfrom(handle, b.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(b.count), 0, $0, &len))
                    #else
                    recvfrom(handle, b.baseAddress, b.count, 0, $0, &len)
                    #endif
                }
            }
        }
        guard n > 0 else { return nil }
        var ipBuf = [CChar](repeating: 0, count: 64)
        #if os(Windows)
        _ = inet_ntop(AF_INET, &from.sin_addr, &ipBuf, ipBuf.count)
        #else
        _ = inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(ipBuf.count))
        #endif
        return (n, Self.cText(ipBuf))
    }

    /// C-Zeichenpuffer bis zur ersten Null als UTF-8-Text (ersetzt das veraltete `String(cString:)` für Arrays).
    static func cText(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Eigene Adressen (für den Subnetz-Scan)

    /// IPv4-Adresse als Text („192.168.1.20“).
    static func ipv4String(_ a: in_addr) -> String {
        var copy = a
        var ipBuf = [CChar](repeating: 0, count: 64)
        #if os(Windows)
        _ = inet_ntop(AF_INET, &copy, &ipBuf, ipBuf.count)
        #else
        _ = inet_ntop(AF_INET, &copy, &ipBuf, socklen_t(ipBuf.count))
        #endif
        return Self.cText(ipBuf)
    }

    /// Adresse der Schnittstelle, über die `ip` erreicht würde: verbundener UDP-Socket + getsockname, es wird
    /// nichts gesendet. nil ohne Route (z. B. kein Netz). Rückfall, wenn die Schnittstellen nicht abfragbar sind.
    static func localIPv4(towards ip: String, port: UInt16 = 53) -> String? {
        #if os(Windows)
        guard let s = try? open(type: Int32(SOCK_DGRAM), proto: Int32(IPPROTO_UDP.rawValue)) else { return nil }
        #else
        guard let s = try? open(type: SOCK_DGRAM, proto: IPPROTO_UDP) else { return nil }
        #endif
        defer { s.close() }
        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.connect(s.handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) == 0
                #else
                Darwin.connect(s.handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #endif
            }
        }
        guard connected else { return nil }
        var local = sockaddr_in()
        #if os(Windows)
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let ok = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s.handle, $0, &len) == 0 }
        }
        guard ok else { return nil }
        let text = ipv4String(local.sin_addr)
        return text == "0.0.0.0" ? nil : text
    }

    /// Aktive IPv4-Netze des Rechners (Adresse + Netzmaske), ohne Loopback, Link-Local (169.254) und
    /// Punkt-zu-Punkt (VPN-Tunnel). Mac: `getifaddrs`; Windows: `GetAdaptersAddresses`; als Rückfall: Adresse zu
    /// 8.8.8.8 mit angenommener /24-Maske.
    static func localNetworks() -> [(ip: String, mask: String)] {
        var nets: [(ip: String, mask: String)] = []
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(first) }
            var cur: UnsafeMutablePointer<ifaddrs>? = first
            while let p = cur {
                defer { cur = p.pointee.ifa_next }
                let flags = Int32(bitPattern: p.pointee.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                      let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                      let nm = p.pointee.ifa_netmask else { continue }
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4String($0.pointee.sin_addr) }
                let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4String($0.pointee.sin_addr) }
                guard !ip.hasPrefix("169.254."), !nets.contains(where: { $0.ip == ip }) else { continue }
                nets.append((ip, mask))
            }
        }
        #elseif os(Windows)
        nets = windowsAdapterNetworks()
        #endif
        if nets.isEmpty, let ip = localIPv4(towards: "8.8.8.8") {
            nets.append((ip, "255.255.255.0"))
        }
        return nets
    }

    #if os(Windows)
    /// Windows: alle aktiven IPv4-Adapter über `GetAdaptersAddresses` (IP-Hilfs-API; `iphlpapi.lib` bindet das
    /// WinSDK-Modul selbst ein). Ohne Loopback, Tunnel und PPP (VPN-Einwahl), ohne Link-Local (169.254); Maske aus
    /// `OnLinkPrefixLength`. Leer, wenn die API scheitert – dann greift der Rückfall in `localNetworks()`.
    /// Adapter mit Standardgateway zuerst (das Heimnetz), virtuelle Netze ohne Gateway (Hyper-V, WSL) danach.
    static func windowsAdapterNetworks() -> [(ip: String, mask: String)] {
        let family = ULONG(AF_INET)
        // GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_INCLUDE_GATEWAYS
        let flags = ULONG(0x0002 | 0x0004 | 0x0008 | 0x0080)
        var size: ULONG = 16 * 1024
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        var rc: ULONG = 0
        for _ in 0..<3 {
            rc = GetAdaptersAddresses(family, flags, nil, buffer.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES.self), &size)
            guard rc == ULONG(ERROR_BUFFER_OVERFLOW) else { break }
            buffer.deallocate()
            buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        }
        guard rc == ULONG(NO_ERROR) else { return [] }

        var withGateway: [(ip: String, mask: String)] = []
        var withoutGateway: [(ip: String, mask: String)] = []
        var adapter: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>? = buffer.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES.self)
        while let a = adapter {
            defer { adapter = a.pointee.Next }
            let type = a.pointee.IfType
            // IF_TYPE_SOFTWARE_LOOPBACK 24, IF_TYPE_PPP 23, IF_TYPE_TUNNEL 131; IfOperStatusUp 1
            guard a.pointee.OperStatus.rawValue == 1, type != 24, type != 23, type != 131 else { continue }
            let hasGateway = a.pointee.FirstGatewayAddress != nil
            var unicast = a.pointee.FirstUnicastAddress
            while let u = unicast {
                defer { unicast = u.pointee.Next }
                guard let sa = u.pointee.Address.lpSockaddr, sa.pointee.sa_family == ADDRESS_FAMILY(AF_INET) else { continue }
                let prefix = Int(u.pointee.OnLinkPrefixLength)
                guard prefix > 0, prefix <= 32 else { continue }
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4String($0.pointee.sin_addr) }
                guard !ip.hasPrefix("169.254."), ip != "0.0.0.0",
                      !withGateway.contains(where: { $0.ip == ip }), !withoutGateway.contains(where: { $0.ip == ip })
                else { continue }
                let m = UInt32.max << UInt32(32 - prefix)
                let mask = "\(m >> 24 & 0xFF).\(m >> 16 & 0xFF).\(m >> 8 & 0xFF).\(m & 0xFF)"
                if hasGateway { withGateway.append((ip, mask)) } else { withoutGateway.append((ip, mask)) }
            }
        }
        return withGateway + withoutGateway
    }
    #endif
}
