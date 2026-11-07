import XCTest
@testable import MideaKit
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#endif

/// Plattformnahe Teile (Kryptografie, Geheimnis-Ablage, Sockets, Pfade). Laufen auf macOS und Windows;
/// unter macOS prüfen sie zusätzlich die portable AES-Umsetzung (`AESModes`) gegen CommonCrypto.
final class PlatformTests: XCTestCase {
    private func hex(_ s: String) -> Data { Data(hex: s)! }

    /// FIPS-197 Anhang C.1 (AES-128, ein Block).
    func testAESBlockVector() throws {
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let pt = hex("00112233445566778899aabbccddeeff")
        let ct = try MideaCrypto.aesBlock(encrypt: true, key: key, pt)
        XCTAssertEqual(ct.hex, "69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertEqual(try MideaCrypto.aesBlock(encrypt: false, key: key, ct), pt)
    }

    /// NIST SP 800-38A F.2.1 (CBC-AES128, ohne Padding) und F.1.1 (ECB).
    func testAESModeVectors() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let pt = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let cbc = try AESModes.crypt(encrypt: true, data: pt, padding: false, iv: iv) {
            try MideaCrypto.aesBlock(encrypt: $0, key: key, $1)
        }
        XCTAssertEqual(cbc.hex, "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2")
        let ecb = try AESModes.crypt(encrypt: true, data: pt, padding: false, iv: nil) {
            try MideaCrypto.aesBlock(encrypt: $0, key: key, $1)
        }
        XCTAssertEqual(ecb.hex, "3ad77bb40d7a3660a89ecaf32466ef97f5d3d58503b9699de785895a96fdbaaf")
    }

    /// Portable Betriebsarten = Produktivweg (unter macOS CommonCrypto), für alle Längen und alle Varianten.
    func testAESModesMatchPlatform() throws {
        let key = hex("8f3c1a2b4d5e6f708192a3b4c5d6e7f8")
        let iv = hex("0f0e0d0c0b0a09080706050403020100")
        func modes(_ enc: Bool, _ d: Data, padding: Bool, iv: Data?) throws -> Data {
            try AESModes.crypt(encrypt: enc, data: d, padding: padding, iv: iv) {
                try MideaCrypto.aesBlock(encrypt: $0, key: key, $1)
            }
        }
        for len in 0...48 {
            let data = Data((0..<len).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let ecb = try MideaCrypto.encryptECB(key: key, data)
            XCTAssertEqual(try modes(true, data, padding: true, iv: nil), ecb, "ECB \(len)")
            XCTAssertEqual(try MideaCrypto.decryptECB(key: key, ecb), data)
            XCTAssertEqual(try modes(false, ecb, padding: true, iv: nil), data)

            let cbc = try MideaCrypto.encryptCBC(key: key, iv: iv, data)
            XCTAssertEqual(try modes(true, data, padding: true, iv: iv), cbc, "CBC+PKCS7 \(len)")
            XCTAssertEqual(try MideaCrypto.decryptCBC(key: key, iv: iv, cbc), data)
            XCTAssertEqual(try modes(false, cbc, padding: true, iv: iv), data)

            if len % 16 == 0 {
                let raw = try MideaCrypto.encryptCBC(key: key, data)
                XCTAssertEqual(try modes(true, data, padding: false, iv: Data(count: 16)), raw, "CBC roh \(len)")
                XCTAssertEqual(try MideaCrypto.decryptCBC(key: key, raw), data)
            }
        }
        // Ungültiges Padding (letztes Klartextbyte 0) und falsche Länge: AESModes prüft streng wie msmart-ng
        // (Python cryptography). CommonCrypto ist hier nachsichtig und liefert den Block ungekürzt – kein Vergleich.
        let zeroBlock = try MideaCrypto.aesBlock(encrypt: true, key: key, Data(count: 16))
        XCTAssertThrowsError(try modes(false, zeroBlock, padding: true, iv: nil))
        XCTAssertThrowsError(try modes(false, zeroBlock.prefix(15), padding: true, iv: nil))
    }

    func testHashes() {
        XCTAssertEqual(MideaCrypto.md5(Data()).hex, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MideaCrypto.sha256(Data("abc".utf8)).hex,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Speichern, lesen, überschreiben, löschen über eine Ablage (eigener Testname).
    private func roundTrip(_ store: any KeychainStore) throws {
        let service = "de.mlafx.klimacontrol.test"
        try store.remove(service: service)
        defer { try? store.remove(service: service) }
        XCTAssertNil(try store.read(service: service))
        let value = Data(#"{"accessToken":"t","savedAt":1}"#.utf8) + Data(repeating: 0x41, count: 600)
        try store.write(service: service, value)
        XCTAssertEqual(try store.read(service: service), value)
        try store.write(service: service, Data("neu".utf8))
        XCTAssertEqual(try store.read(service: service), Data("neu".utf8))
        try store.remove(service: service)
        XCTAssertNil(try store.read(service: service))
    }

    /// `SecretStore` im Testprozess: Ablage nur im Speicher, Runde über die alten Aufrufe.
    func testSecretStoreRoundTrip() throws {
        XCTAssertTrue(SecretStore.backend is InMemoryKeychain, "Testprozess muss den Speicher-Schlüsselbund nutzen")
        let service = "de.mlafx.klimacontrol.test"
        SecretStore.delete(service: service)
        defer { SecretStore.delete(service: service) }
        XCTAssertNil(SecretStore.load(service: service))
        SecretStore.save(service: service, Data("x".utf8))
        XCTAssertEqual(SecretStore.load(service: service), Data("x".utf8))
        try roundTrip(SecretStore.backend)
    }

    /// Echter Schlüsselbund bzw. Windows-Anmeldeinformationsverwaltung – nur mit KLIMACONTROL_REAL_SECRETS=1
    /// (legt einen eigenen Testeintrag an und entfernt ihn wieder; fasst die Einträge von Klimacontrol nicht an).
    func testSystemKeychainRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KLIMACONTROL_REAL_SECRETS"] == "1",
                          "echter Schlüsselbund nur mit KLIMACONTROL_REAL_SECRETS=1")
        try roundTrip(SystemKeychain())
    }

    /// Freier TCP-Port auf 127.0.0.1: binden an Port 0, Nummer lesen, Socket schließen. Danach lauscht dort niemand,
    /// eine Verbindung wird also abgewiesen (statt sich auf den „geschlossenen“ Port 9 zu verlassen).
    static func unusedLoopbackPort() -> UInt16? {
        #if os(Windows)
        var wsa = WSADATA()
        _ = WSAStartup(0x0202, &wsa)
        let s = WinSDK.socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard s != INVALID_SOCKET else { return nil }
        defer { closesocket(s) }
        #else
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { Darwin.close(s) }
        #endif
        var addr = sockaddr_in()
        addr.sin_port = 0
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0
                #else
                Darwin.bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0
                #endif
            }
        }
        return ok ? UInt16(bigEndian: addr.sin_port) : nil
    }

    /// Unbenutzter Port auf dem eigenen Rechner → abgewiesen, nicht erst nach dem Zeitlimit. Unter Windows wiederholt
    /// der Stack ein RST-beantwortetes SYN (ca. 1–2 s), darum dort ein großzügigeres Limit.
    func testTCPConnectRefused() throws {
        let port = try XCTUnwrap(Self.unusedLoopbackPort(), "kein freier Port")
        let start = Date()
        XCTAssertThrowsError(try NetSocket.connectTCP(host: "127.0.0.1", port: port, timeoutMs: 4000)) { error in
            XCTAssertEqual(error as? MideaError, .refused)
            XCTAssertTrue((error as? MideaError)?.errorDescription?.contains("weist die Verbindung ab") == true)
        }
        #if os(Windows)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5)
        #else
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        #endif
        // Ungültige Adresse: „.invalid“ beantwortet jeder Resolver ohne Netzanfrage (RFC 6761).
        XCTAssertThrowsError(try NetSocket.connectTCP(host: "kein-host.invalid", port: 6444, timeoutMs: 1000))
    }

    /// Datagramm an sich selbst wäre ohne bind nicht empfangbar – hier nur: Senden an Loopback klappt.
    func testUDPSend() throws {
        let s = try NetSocket.udpBroadcast()
        defer { s.close() }
        XCTAssertNil(s.send(Data([1, 2, 3]), toIPv4: "127.0.0.1", port: 6445))
    }

    func testSupportDirectory() {
        let dir = DeviceConfig.supportDirectory
        XCTAssertEqual(dir.lastPathComponent, "Klimacontrol")
        XCTAssertEqual(DeviceConfig.defaultURL.deletingLastPathComponent(), dir)
        #if os(Windows)
        if let appData = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
            XCTAssertTrue(dir.path.lowercased().contains(URL(fileURLWithPath: appData).path.lowercased()), dir.path)
        }
        #else
        XCTAssertTrue(dir.path.hasSuffix("Library/Application Support/Klimacontrol"), dir.path)
        #endif
    }

    #if os(Windows)
    /// Eigene Netze über GetAdaptersAddresses: nur gültige, zusammenhängende Masken, kein Loopback/Link-Local, keine
    /// Doppelten. Ohne Netz darf die Liste leer sein (kein Fehlschlag). Gibt die Netze aus (keine Geheimnisse).
    func testLocalNetworksWindows() {
        let nets = NetSocket.localNetworks()
        let api = NetSocket.windowsAdapterNetworks()
        print("localNetworks: \(nets.map { "\($0.ip)/\($0.mask)" }.joined(separator: ", ")) · GetAdaptersAddresses: \(api.count) Netz(e)")
        // Hat der Rechner eine Route nach außen, muss die API deren Adresse kennen (sonst nur Rückfall aktiv).
        if let routed = NetSocket.localIPv4(towards: "8.8.8.8") {
            XCTAssertTrue(api.contains(where: { $0.ip == routed }), "GetAdaptersAddresses kennt \(routed) nicht")
        }
        if !api.isEmpty { XCTAssertEqual(nets.map(\.ip), api.map(\.ip)) }
        XCTAssertEqual(Set(nets.map(\.ip)).count, nets.count, "keine doppelten Adressen")
        for n in nets {
            XCTAssertFalse(n.ip.hasPrefix("127."), n.ip)
            XCTAssertFalse(n.ip.hasPrefix("169.254."), n.ip)
            XCTAssertEqual(n.ip.split(separator: ".").compactMap { UInt8($0) }.count, 4, n.ip)
            let m = n.mask.split(separator: ".").compactMap { UInt32($0) }
            XCTAssertEqual(m.count, 4, n.mask)
            guard m.count == 4 else { continue }
            let value = m[0] << 24 | m[1] << 16 | m[2] << 8 | m[3]
            XCTAssertEqual(value, value == 0 ? 0 : ~UInt32(0) << UInt32(value.trailingZeroBitCount), "Maske zusammenhängend: \(n.mask)")
        }
    }
    #endif
}
