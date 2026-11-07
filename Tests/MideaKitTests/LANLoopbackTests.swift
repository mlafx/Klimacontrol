#if canImport(Darwin)
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import MideaKit

/// Echter LAN-Weg über TCP: `LANClient` gegen eine nachgebildete Anlage auf 127.0.0.1 (Schlüssel aus vectors.json).
/// Nur Darwin (die Gegenstelle nutzt POSIX-Sockets); unter Windows deckt TransportTests den Fake-Weg ab.
final class LANLoopbackTests: XCTestCase {
    /// Was die nachgebildete Anlage auf die n-te Anfrage (ab 0, über alle Verbindungen) tut.
    enum Reply {
        /// Antwortrahmen senden; `chunk` > 0 schickt die Bytes in Stücken dieser Größe mit kurzer Pause.
        case frames([Data], chunk: Int = 0)
        /// Antworten senden und danach die Verbindung schließen.
        case framesThenClose([Data])
        /// Fehlerpaket (Typ 0xF), wie bei abgelaufenem Token.
        case errorPacket
    }

    /// Nachgebildete Anlage: lauscht auf 127.0.0.1:0, nimmt nacheinander Verbindungen an.
    final class FakeAnlage: Sendable {
        private struct Seen {
            var stopped = false
            var tokens: [Data] = []
            var requests: [Data] = []
            var connections = 0
        }

        let port: UInt16
        private let listener: Int32
        private let localKey: Data
        private let handshakeResponse: Data
        private let answerHandshake: Bool
        private let reply: @Sendable (Int) -> Reply
        private let seen = Mutex(Seen())
        /// Gibt der Server-Thread frei, wenn er endet.
        private let done = DispatchSemaphore(value: 0)

        var tokens: [Data] { seen.withLock { $0.tokens } }
        var requests: [Data] { seen.withLock { $0.requests } }
        var connections: Int { seen.withLock { $0.connections } }

        init(localKey: Data, handshakeResponse: Data, answerHandshake: Bool = true,
             reply: @escaping @Sendable (Int) -> Reply) throws {
            self.localKey = localKey
            self.handshakeResponse = handshakeResponse
            self.answerHandshake = answerHandshake
            self.reply = reply
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { throw MideaError.connectionFailed("socket") }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, len) == 0 && Darwin.listen(s, 4) == 0 && getsockname(s, $0, &len) == 0
                }
            }
            guard ok else { close(s); throw MideaError.connectionFailed("bind/listen") }
            listener = s
            port = UInt16(bigEndian: addr.sin_port)
            Thread { [self] in serve() }.start()
        }

        func stop() {
            seen.withLock { $0.stopped = true }
            // Der Server prüft `stopped` spätestens alle 50 ms (poll); 5 s Frist statt endlos zu warten.
            if done.wait(timeout: .now() + 5) == .timedOut { XCTFail("nachgebildete Anlage hält nicht an") }
            close(listener)
        }

        private var isStopped: Bool { seen.withLock { $0.stopped } }

        private func serve() {
            defer { done.signal() }
            var index = 0
            while !isStopped {
                var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 50) > 0 else { continue }
                let c = accept(listener, nil, nil)
                guard c >= 0 else { continue }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                seen.withLock { $0.connections += 1 }
                handle(c, index: &index)
                close(c)
            }
        }

        /// Eine Verbindung: Handshake, dann Anfragen bis zum Schließen (durch Client, Antwortplan oder Stopp).
        private func handle(_ c: Int32, index: inout Int) {
            var codec = V3Codec()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !isStopped {
                var pfd = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 50) > 0 else { continue }
                let n = recv(c, &buffer, buffer.count, 0)
                guard n > 0 else { return }
                for packet in codec.feed(Data(buffer[0..<n])) {
                    let p = [UInt8](packet)
                    let id = Data(p[6..<8])
                    switch p[5] & 0xF {
                    case 0x0: // Handshake-Anfrage: 6 Byte Kopf, 2 Byte Paketnummer, Token
                        seen.withLock { $0.tokens.append(Data(p[8...])) }
                        if answerHandshake {
                            send(c, Self.header(length: handshakeResponse.count, type: 0x1) + id + handshakeResponse)
                        }
                    case 0x6: // verschlüsselte Anfrage
                        guard let frame = decrypt(packet) else { return }
                        seen.withLock { $0.requests.append(frame) }
                        let plan = reply(index)
                        index += 1
                        switch plan {
                        case .frames(let frames, let chunk):
                            let bytes = frames.reduce(Data()) { $0 + encryptedResponse($1) }
                            if chunk > 0 {
                                var offset = 0
                                while offset < bytes.count {
                                    send(c, bytes.subdata(in: offset..<min(bytes.count, offset + chunk)))
                                    offset += chunk
                                    // Bewusste Pause (langsame Anlage/WLAN): ohne sie fasst der Kernel die Stücke
                                    // auf 127.0.0.1 meist zu einem Lesevorgang zusammen, und das Zusammensetzen
                                    // beim Client bliebe ungeprüft.
                                    usleep(5_000)
                                }
                            } else {
                                send(c, bytes)
                            }
                        case .framesThenClose(let frames):
                            send(c, frames.reduce(Data()) { $0 + encryptedResponse($1) })
                            return
                        case .errorPacket:
                            send(c, Self.header(length: 0, type: 0xF) + id)
                        }
                    default:
                        return
                    }
                }
            }
        }

        private func send(_ c: Int32, _ data: Data) {
            data.withUnsafeBytes { b in
                var sent = 0
                while sent < b.count {
                    let n = Darwin.send(c, b.baseAddress!.advanced(by: sent), b.count - sent, 0)
                    if n <= 0 { return }
                    sent += n
                }
            }
        }

        static func header(length: Int, type: UInt8) -> Data {
            Data([0x83, 0x70, UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), 0x20, type])
        }

        /// Anfrage entschlüsseln (Gegenstück zu `V3Codec.encodeEncrypted`) und den Befehlsrahmen aus dem V2-Paket holen.
        private func decrypt(_ packet: Data) -> Data? {
            let p = [UInt8](packet)
            guard p.count >= 6 + 16 + 32,
                  let plain = try? MideaCrypto.decryptCBC(key: localKey, Data(p[6..<(p.count - 32)])),
                  MideaCrypto.sha256(Data(p[0..<6]) + plain) == Data(p[(p.count - 32)...]) else { return nil }
            let pad = Int(p[5] >> 4)
            return try? V2Packet.decode(Data(plain[2..<(plain.count - pad)]))
        }

        /// Antwortpaket (Typ 0x3) mit dem Rahmen im V2-Paket, verschlüsselt mit dem Sitzungsschlüssel.
        private func encryptedResponse(_ frame: Data) -> Data {
            let v2 = (try? V2Packet.encode(deviceId: LANLoopbackTests.deviceId, frame: frame)) ?? Data()
            let remainder = (v2.count + 2) % 16
            let pad = remainder == 0 ? 0 : 16 - remainder
            let hdr = Self.header(length: v2.count + pad + 32, type: UInt8(pad << 4) | 0x3)
            let payload = Data([0, 1]) + v2 + Data(count: pad)
            return hdr + ((try? MideaCrypto.encryptCBC(key: localKey, payload)) ?? Data()) + MideaCrypto.sha256(hdr + payload)
        }
    }

    static let deviceId: UInt64 = 20015998343868
    static let token = Data((0..<64).map { UInt8($0) })

    /// Handshake-Vektor aus vectors.json: Geräteschlüssel, Antwort der Anlage, erwarteter Sitzungsschlüssel.
    static let handshake: (key: Data, response: Data, localKey: Data) = {
        let h = try! TestVectors.json()["handshake"] as! [String: String]
        return (Data(hex: h["key"]!)!, Data(hex: h["response"]!)!, Data(hex: h["localKey"]!)!)
    }()

    /// Rahmen mit Antwort-ID (Byte 10) und Typ (Byte 9), Rest Füllbytes.
    static func frame(id: UInt8, type: UInt8 = 0x03, fill: UInt8 = 0x11) -> Data {
        Data(TestFrames.bare(type: type, id: id, count: 24, length: 23, fill: fill))
    }

    static let query = frame(id: 0x41, type: 0x03, fill: 0x00)
    static let state = frame(id: 0xC0, fill: 0x22)
    static let spontaneous = frame(id: 0xA0, type: 0x05, fill: 0x33)

    private var anlage: FakeAnlage?

    override func tearDown() {
        anlage?.stop()
        anlage = nil
    }

    private func start(answerHandshake: Bool = true, reply: @escaping @Sendable (Int) -> Reply) throws -> FakeAnlage {
        let a = try FakeAnlage(localKey: Self.handshake.localKey, handshakeResponse: Self.handshake.response,
                               answerHandshake: answerHandshake, reply: reply)
        anlage = a
        return a
    }

    private func client(_ a: FakeAnlage, key: Data = LANLoopbackTests.handshake.key) -> LANClient {
        let c = LANClient(host: "127.0.0.1", port: a.port, deviceId: Self.deviceId, token: Self.token, key: key)
        c.quietErrors = true // Fehler gehören zum Test, nicht ins Protokoll
        return c
    }

    func testHandshakeAndRequestOverTCP() throws {
        let a = try start { _ in .frames([Self.state]) }
        let c = client(a)
        defer { c.disconnect() }
        XCTAssertEqual(try c.send(Self.query, retries: 0, expect: 0xC0), [Self.state])
        XCTAssertEqual(a.tokens, [Self.token], "Token im Handshake übertragen")
        XCTAssertEqual(a.requests, [Self.query], "Anlage entschlüsselt genau den gesendeten Rahmen")
        // Zweite Anfrage auf derselben Verbindung, ohne neuen Handshake.
        XCTAssertEqual(try c.send(Self.query, retries: 0, expect: 0xC0), [Self.state])
        XCTAssertEqual(a.connections, 1)
        XCTAssertEqual(a.tokens.count, 1)
    }

    func testFragmentedResponseIsReassembled() throws {
        let a = try start { _ in .frames([Self.state], chunk: 7) }
        let c = client(a)
        defer { c.disconnect() }
        XCTAssertEqual(try c.send(Self.query, retries: 0, expect: 0xC0), [Self.state])
    }

    /// Spontane Meldung vor der eigentlichen Antwort, beide in einem TCP-Segment: beide Rahmen kommen zurück.
    func testSpontaneousMessageBeforeAnswer() throws {
        let a = try start { _ in .frames([Self.spontaneous, Self.state]) }
        let c = client(a)
        defer { c.disconnect() }
        XCTAssertEqual(try c.send(Self.query, retries: 0, expect: 0xC0), [Self.spontaneous, Self.state])
    }

    /// Die Anlage schließt die Verbindung nach der Antwort; die nächste Sendung verbindet neu (neuer Handshake).
    func testReconnectsAfterPeerClosed() throws {
        let a = try start { _ in .framesThenClose([Self.state]) }
        let c = client(a)
        defer { c.disconnect() }
        XCTAssertEqual(try c.send(Self.query, retries: 0, expect: 0xC0), [Self.state])
        XCTAssertEqual(try c.send(Self.query, retries: 1, expect: 0xC0), [Self.state])
        XCTAssertEqual(a.connections, 2)
        XCTAssertEqual(a.tokens.count, 2, "neuer Handshake auf der neuen Verbindung")
    }

    func testErrorPacketIsAProtocolError() throws {
        let a = try start { _ in .errorPacket }
        let c = client(a)
        defer { c.disconnect() }
        XCTAssertThrowsError(try c.send(Self.query, retries: 0, expect: 0xC0)) { error in
            guard case MideaError.protocolError = error else { return XCTFail("\(error)") }
        }
    }

    /// Falscher Geräteschlüssel: Prüfsumme der Handshake-Antwort passt nicht → Anmeldefehler, kein Wiederholen.
    func testWrongKeyFailsAuthenticationWithoutRetry() throws {
        let a = try start { _ in .frames([Self.state]) }
        let c = client(a, key: Data(repeating: 0x55, count: 32))
        defer { c.disconnect() }
        XCTAssertThrowsError(try c.send(Self.query, retries: 2, expect: 0xC0)) { error in
            guard case MideaError.authenticationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(a.tokens.count, 1, "Anmeldefehler wird nicht wiederholt")
        XCTAssertTrue(a.requests.isEmpty)
    }

    /// Keine Antwort auf den Handshake → nach dem Zeitlimit (4 s) „antwortet nicht“ (kein Token-Fehler);
    /// „belegt“ nur, wenn die Anlage unter dieser Adresse kurz vorher antwortete.
    func testHandshakeTimeout() throws {
        let a = try start(answerHandshake: false) { _ in .frames([Self.state]) }
        let c = client(a)
        defer { c.disconnect() }
        let start = Date()
        XCTAssertThrowsError(try c.send(Self.query, retries: 0, expect: 0xC0)) { error in
            XCTAssertEqual(error as? MideaError, .timeout)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 3.9, "volles Zeitlimit von 4 s abgewartet")
        // Die Einordnung „belegt“ hängt nicht an der Wartezeit: Restzeit des Auftrags 1 s (wie unter
        // `PortaSplitDevice.run`) kürzt das Warten auf die Anmeldeantwort.
        c.lastReachableAt = Date()
        c.deadline = Date().addingTimeInterval(1)
        XCTAssertThrowsError(try c.send(Self.query, retries: 0, expect: 0xC0)) { error in
            guard case MideaError.busy = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 12)
    }
}
#endif
