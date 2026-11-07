import XCTest
@testable import MideaKit

/// Robustheit der Parser: kurze, abgeschnittene und zufällige Eingaben dürfen
/// werfen oder nil liefern, aber nie abstürzen. Zufall mit festem Startwert, damit Fehler nachstellbar sind.
final class RobustnessTests: XCTestCase {

    /// Kleiner deterministischer Zufallsgenerator (SplitMix64).
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &self) } }
    }

    // MARK: Discovery (von jedem Rechner im LAN erreichbar)

    func testDiscoveryPrefixesNeverCrash() throws {
        let full = try TestVectors.hex("discovery")
        for n in 0..<full.count {
            XCTAssertThrowsError(try Discovery.parse(full.prefix(n), ip: "192.168.1.40"), "Präfix \(n)")
        }
        XCTAssertNoThrow(try Discovery.parse(full, ip: "192.168.1.40"))
    }

    func testDiscoveryRandomNeverCrashes() {
        var rng = Rng(state: 0xA05)
        let heads: [[UInt8]] = [[0x83, 0x70], [0x5A, 0x5A], [0x83, 0x70, 0x00, 0x48], [0x5A, 0x5A, 0x01, 0x11, 0x48, 0x00], []]
        for i in 0..<3000 {
            let head = heads[i % heads.count]
            let data = Data(head + rng.bytes(Int.random(in: 0...260, using: &rng)))
            _ = try? Discovery.parse(data, ip: "10.0.0.1")
        }
    }

    func testDiscoveryRejectsTamperedSignatureAndLength() throws {
        var bad = [UInt8](try TestVectors.hex("discovery"))
        bad[8 + 60] ^= 0x01 // ein Byte im verschlüsselten Teil → MD5 passt nicht
        XCTAssertThrowsError(try Discovery.parse(Data(bad), ip: "1.2.3.4"))
        var shortLen = [UInt8](try TestVectors.hex("discovery"))
        shortLen[3] = 0x10 // 8370-Länge kleiner als der Inhalt
        XCTAssertThrowsError(try Discovery.parse(Data(shortLen), ip: "1.2.3.4"))
    }

    /// Eine selbst gebaute V2-Antwort mit Steuerzeichen in Name und SN: beides kommt bereinigt an.
    func testDiscoveryCleansNameAndSerial() throws {
        var plain = [UInt8](repeating: 0, count: 8)
        plain[4] = 0x2C; plain[5] = 0x19 // Port 6444
        let sn = Array("SN\u{1B}[31m\n0000".utf8)
        plain += sn + [UInt8](repeating: 0x20, count: 32 - sn.count)
        let name = Array("net_ac_\u{7}1A2B\r\n".utf8)
        plain += [UInt8(name.count)] + name
        let enc = [UInt8](try MideaCrypto.encryptECB(Data(plain)))
        let length = 40 + enc.count + 16
        var head = [UInt8](repeating: 0, count: 40)
        head[0] = 0x5A; head[1] = 0x5A; head[2] = 0x01; head[3] = 0x11
        head[4] = UInt8(length & 0xFF); head[5] = UInt8(length >> 8)
        head[20] = 0x2A // Geräte-ID 42
        let packet = Data(head + enc)
        let dev = try Discovery.parse(packet + MideaCrypto.sign(packet), ip: "192.168.1.9")
        XCTAssertEqual(dev.deviceId, 42)
        XCTAssertEqual(dev.port, 6444)
        XCTAssertEqual(dev.version, 2)
        XCTAssertEqual(dev.type, 0xAC)
        XCTAssertFalse(dev.name.unicodeScalars.contains { $0.properties.generalCategory == .control })
        XCTAssertFalse(dev.sn.unicodeScalars.contains { $0.properties.generalCategory == .control })
        XCTAssertTrue(dev.name.hasPrefix("net_ac_"))
    }

    // MARK: Antwortrahmen (LAN und Cloud)

    /// Rahmen mit gültiger Prüfsumme, aber ohne Nutzdaten (12 Byte) – auch über die Cloud kein Absturz.
    func testResponseTwelveByteFrameThrows() {
        var f = TestFrames.bare(type: 0x03, id: 0x00)
        f.append(Frame.checksum(f.dropFirst()))
        XCTAssertEqual(f.count, 12)
        XCTAssertThrowsError(try Response.parse(Data(f)))
    }

    func testResponsePrefixesAndRandomNeverCrash() throws {
        let energy = Data(hex: "aa22ac00000000000803c1210144000005e00000000000000006000aeb000000487a5e")!
        for n in 0...energy.count { _ = try? Response.parse(energy.prefix(n)) }
        var rng = Rng(state: 0xF00D)
        for _ in 0..<5000 {
            var f = [UInt8](arrayLiteral: 0xAA, 0, 0xAC) + rng.bytes(Int.random(in: 0...60, using: &rng))
            f[1] = UInt8(truncatingIfNeeded: f.count)
            // Gültige Prüfsumme, damit der Zufall bis in die Zerleger kommt
            f.append(Frame.checksum(f.dropFirst()))
            _ = try? Response.parse(Data(f))
        }
    }

    func testPropertyParserNeverCrashes() {
        var rng = Rng(state: 7)
        for _ in 0..<3000 {
            let p = [0xB1] + rng.bytes(Int.random(in: 0...40, using: &rng))
            _ = Response.parseProperties(p)
        }
        XCTAssertTrue(Response.parsePropertyBytes([]).isEmpty)
        XCTAssertTrue(Response.parsePropertyBytes([0xB1]).isEmpty)
    }

    // MARK: Zähler: binär, 0,01 kWh je Schritt

    static func energyFrame(counter: UInt32, watts10: UInt32) -> Data {
        var p = [UInt8](repeating: 0, count: 22)
        p[0] = 0xC1; p[1] = 0x21; p[2] = 0x01; p[3] = 0x44
        p[4] = UInt8(counter >> 24); p[5] = UInt8(counter >> 16 & 0xFF); p[6] = UInt8(counter >> 8 & 0xFF); p[7] = UInt8(counter & 0xFF)
        p[16] = UInt8(watts10 >> 16 & 0xFF); p[17] = UInt8(watts10 >> 8 & 0xFF); p[18] = UInt8(watts10 & 0xFF)
        return Frame.build(.query, p, id: 1)
    }

    func testEnergyCounterIsBinary() throws {
        // 0x000120EF: BCD hätte 121,47 ergeben (0xEF ist kein BCD), binär 73967 × 0,01 = 739,67 kWh
        guard case .energy(let w, let kwh) = try Response.parse(Self.energyFrame(counter: 0x0001_20EF, watts10: 3835)) else {
            return XCTFail("keine Verbrauchsantwort")
        }
        XCTAssertEqual(try XCTUnwrap(kwh), 739.67, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(w), 383.5, accuracy: 0.0001)
        // Ein Schritt weiter ist genau 0,01 kWh mehr (BCD-Lesart spränge hier von 121,59 auf 121,00 zurück)
        guard case .energy(_, let next) = try Response.parse(Self.energyFrame(counter: 0x0001_20F0, watts10: 3835)) else {
            return XCTFail("keine Verbrauchsantwort")
        }
        XCTAssertEqual(try XCTUnwrap(next) - (kwh ?? 0), 0.01, accuracy: 0.0001)
    }

    func testEnergyCounterZeroIsUnknownNotZero() throws {
        guard case .energy(let w, let kwh) = try Response.parse(Self.energyFrame(counter: 0, watts10: 85)) else {
            return XCTFail("keine Verbrauchsantwort")
        }
        XCTAssertNil(kwh)
        XCTAssertEqual(w, 8.5)
        guard case .energy(_, let ff) = try Response.parse(Self.energyFrame(counter: 0xFFFF_FFFF, watts10: 85)) else {
            return XCTFail("keine Verbrauchsantwort")
        }
        XCTAssertNil(ff)
    }

    func testDiagnosticsCounterMatchesState() throws {
        let frame = [UInt8](Self.energyFrame(counter: 75057, watts10: 0))
        var d = Diagnostics()
        d.apply(group: 4, payload: Array(frame.dropFirst(10).dropLast(2)))
        XCTAssertEqual(d.energyCounterRaw, 75057)
        guard case .energy(_, let kwh) = try Response.parse(Data(frame)) else { return XCTFail() }
        XCTAssertEqual(try XCTUnwrap(kwh), Double(75057) * Response.energyCounterStepKWh, accuracy: 0.0001)
    }

    // MARK: Timer

    func testTimerOver24HoursIsNil() {
        XCTAssertEqual(DeviceTimer.decode(0xFF, 0xFF, 0xFF).0, nil)
        XCTAssertEqual(DeviceTimer.decode(0xFF, 0xFF, 0xFF).1, nil)
        let e = DeviceTimer.encode(on: 24 * 60, off: 90)
        XCTAssertEqual(DeviceTimer.decode(e.0, e.1, e.2).0, 24 * 60)
        XCTAssertEqual(DeviceTimer.decode(e.0, e.1, e.2).1, 90)
        for b in 0...255 { for r in stride(from: 0, through: 255, by: 17) {
            let d = DeviceTimer.decode(UInt8(b), UInt8(b), UInt8(r))
            if let m = d.0 { XCTAssertTrue((1...DeviceTimer.maxMinutes).contains(m)) }
        } }
    }

    // MARK: V2-Paket (Cloud und LAN innen)

    func testV2DecodePrefixesAndRandomNeverCrash() throws {
        let packet = try V2Packet.encode(deviceId: 1234, frame: Frame.getState(id: 1))
        for n in 0..<packet.count { XCTAssertThrowsError(try V2Packet.decode(packet.prefix(n))) }
        XCTAssertNoThrow(try V2Packet.decode(packet))
        var rng = Rng(state: 0x5A5A)
        for _ in 0..<3000 {
            var b = [0x5A, 0x5A, 0x01, 0x11] + rng.bytes(Int.random(in: 0...140, using: &rng))
            if b.count > 5 { b[4] = UInt8(truncatingIfNeeded: b.count); b[5] = 0 }
            _ = try? V2Packet.decode(Data(b))
        }
        // Slice mit Startindex ≠ 0
        let sliced = (Data([0, 0, 0]) + packet).dropFirst(3)
        XCTAssertNoThrow(try V2Packet.decode(sliced))
    }

    // MARK: V3-Codec

    func testFeedKeepsSplitMagicByte() {
        var c = V3Codec()
        let pkt = Data([0x83, 0x70, 0x00, 0x02, 0x20, 0x01, 0x00, 0x00, 0xAB, 0xCD])
        XCTAssertTrue(c.feed(Data([0x00, 0x83])).isEmpty)
        XCTAssertEqual(c.feed(pkt.dropFirst()), [pkt])
    }

    func testFeedSkipsAbsurdLength() {
        var c = V3Codec()
        let junk = Data([0x83, 0x70, 0xFF, 0xF0, 0x20, 0x03])
        let pkt = Data([0x83, 0x70, 0x00, 0x00, 0x20, 0x01, 0x00, 0x00])
        XCTAssertEqual(c.feed(junk + pkt), [pkt])
    }

    func testFeedRandomChunksNeverCrash() {
        var rng = Rng(state: 0x8370)
        var c = V3Codec()
        for _ in 0..<2000 {
            var b = rng.bytes(Int.random(in: 0...80, using: &rng))
            if b.count > 6, Bool.random(using: &rng) { b[0] = 0x83; b[1] = 0x70 }
            for p in c.feed(Data(b)) {
                XCTAssertLessThanOrEqual(p.count, V3Codec.maxPacketLength)
                _ = try? c.decode(p)
            }
        }
    }

    func testDecodeRejectsPaddingLongerThanPayload() throws {
        let key = Data(repeating: 0x11, count: 32)
        var c = V3Codec()
        c.localKey = key
        let hdr = Data([0x83, 0x70, 0x00, 0x30, 0x20, 0xF3]) // Typ 3, 15 Füllbytes
        let plain = Data(repeating: 0x42, count: 16)          // nur 16 Byte Klartext: 2 + 15 > 16
        let body = try MideaCrypto.encryptCBC(key: key, plain)
        let packet = hdr + body + MideaCrypto.sha256(hdr + plain)
        XCTAssertThrowsError(try c.decode(packet))
    }

    func testDecodeRandomWithKeyNeverCrashes() {
        var rng = Rng(state: 0xBEEF)
        var c = V3Codec()
        c.localKey = Data(repeating: 0x22, count: 32)
        for _ in 0..<2000 {
            var b = [0x83, 0x70, 0x00, 0x00, 0x20, UInt8.random(in: 0...255, using: &rng)] + rng.bytes(Int.random(in: 0...90, using: &rng))
            b[3] = UInt8(truncatingIfNeeded: b.count - 8)
            _ = try? c.decode(Data(b))
        }
    }

    func testHandshakeResponseWrongLengthThrows() {
        for n in [0, 1, 32, 63, 65, 128] {
            XCTAssertThrowsError(try V3Codec.localKey(key: Data(repeating: 1, count: 32), response: Data(repeating: 0, count: n)))
        }
    }

    // MARK: Hex

    func testHexParser() {
        XCTAssertEqual(Data(hex: "00aBcDeF"), Data([0x00, 0xAB, 0xCD, 0xEF]))
        XCTAssertEqual(Data(hex: ""), Data())
        XCTAssertNil(Data(hex: "abc"))
        XCTAssertNil(Data(hex: "zz"))
        XCTAssertNil(Data(hex: "+1"))
        XCTAssertNil(Data(hex: "ä0"))
    }
}
