import XCTest
@testable import MideaKit

/// Prüft die Swift-Implementierung Byte für Byte gegen msmart-ng (vectors.json aus scripts/make_vectors.py).
final class MideaKitTests: XCTestCase {
    struct Vectors: Decodable {
        struct SetState: Decodable {
            let power: Bool, temp: Double, mode: Int, fan: Int, eco: Bool, turbo: Bool, swing: Int, beep: Bool, frame: String
        }
        struct V2: Decodable { let deviceId: UInt64, frame: String, epoch: Double, packet: String }
        struct V3: Decodable { let localKey: String, packetId: Int, data: String, packet: String }
        struct Handshake: Decodable { let key: String, response: String, localKey: String }
        let getState, getCapabilities, getGroup4, toggleDisplay, getOutSilent, setOutSilentOn: String
        let setIECOOn, setSelfCleanOn, setSoundOff, getProps3, setStateIonFrost: String
        let setState: [SetState]
        let v2: V2
        let v3: V3
        let handshake: Handshake
    }

    static let vectors: Vectors = try! JSONDecoder().decode(Vectors.self, from: TestVectors.data())

    var v: Vectors { Self.vectors }

    func testQueryFrames() {
        XCTAssertEqual(Frame.getState(id: 0x10).hex, v.getState)
        XCTAssertEqual(Frame.getCapabilities(id: 0x10).hex, v.getCapabilities)
        XCTAssertEqual(Frame.getGroupData(4, id: 0x10).hex, v.getGroup4)
        XCTAssertEqual(Frame.toggleDisplay(beep: true, id: 0x10).hex, v.toggleDisplay)
        XCTAssertEqual(Frame.getProperties([.outSilent], id: 0x10).hex, v.getOutSilent)
        XCTAssertEqual(Frame.setOutSilent(true, id: 0x10).hex, v.setOutSilentOn)
    }

    func testPropertyFrames() {
        XCTAssertEqual(Frame.setProperty(.ieco, true, id: 0x10).hex, v.setIECOOn)
        XCTAssertEqual(Frame.setProperty(.selfClean, true, id: 0x10).hex, v.setSelfCleanOn)
        XCTAssertEqual(Frame.setProperty(.sound, false, id: 0x10).hex, v.setSoundOff)
        XCTAssertEqual(Frame.getProperties([.ieco, .outSilent, .selfClean], id: 0x10).hex, v.getProps3)
        var s = ACState()
        s.power = true; s.targetTemperature = 21; s.mode = .heat; s.fanSpeed = 40
        s.freezeProtection = true; s.purifier = true
        XCTAssertEqual(Frame.setState(s, beep: true, id: 0x10).hex, v.setStateIonFrost)
    }

    /// Eigenschaften-Antwort, nachgebildet nach echter Antwort der PortaSplit (nur Zustandsbytes): iECO aus, Außen leise aus, Selbstreinigung aus.
    func testRealPropertiesResponse() {
        let p: [UInt8] = [0xb1, 0x05, 0xe3, 0x00, 0x00, 0x02, 0x00, 0x00, 0x48, 0x00, 0x00, 0x01, 0x64, 0x2c, 0x02,
                          0x00, 0x01, 0x01, 0xcd, 0x00, 0x00, 0x01, 0x00, 0x39, 0x00, 0x00, 0x01, 0x00]
        let props = Response.parseProperties(p)
        XCTAssertEqual(props[.ieco], false)
        XCTAssertEqual(props[.outSilent], false)
        XCTAssertEqual(props[.selfClean], false)
        XCTAssertEqual(props[.sound], true)
        XCTAssertEqual(Response.parsePropertyBytes(p)[.rateSelect], [0x64]) // 100 % = keine Begrenzung
        XCTAssertEqual(Frame.setRateSelect(75, id: 1).dropFirst(10).prefix(6).map { $0 }, [0xB0, 1, 0x48, 0x00, 1, 75])
    }

    func testSetStateFrames() {
        for t in v.setState {
            var s = ACState()
            s.power = t.power
            s.targetTemperature = t.temp
            s.mode = OperationalMode(rawValue: t.mode)!
            s.fanSpeed = t.fan
            s.eco = t.eco
            s.turbo = t.turbo
            s.swing = SwingMode(rawValue: t.swing)!
            XCTAssertEqual(Frame.setState(s, beep: t.beep, id: 0x10).hex, t.frame, "Sollzustand \(t)")
        }
    }

    func testV2PacketRoundTrip() throws {
        let frame = Data(hex: v.v2.frame)!
        let packet = try V2Packet.encode(deviceId: v.v2.deviceId, frame: frame, date: Date(timeIntervalSince1970: v.v2.epoch))
        XCTAssertEqual(packet.hex, v.v2.packet)
        XCTAssertEqual(try V2Packet.decode(packet), frame)
    }

    func testV3Encryption() throws {
        var codec = V3Codec()
        codec.localKey = Data(hex: v.v3.localKey)
        codec.randomBytes = { Data(repeating: 0xAB, count: $0) }
        for _ in 0..<v.v3.packetId { _ = codec.encodeHandshake(token: Data()) }
        let packet = try codec.encodeEncrypted(Data(hex: v.v3.data)!)
        XCTAssertEqual(packet.hex, v.v3.packet)
    }

    func testV3ResponseDecoding() throws {
        // Eine verschlüsselte Antwort hat denselben Aufbau wie eine Anfrage, nur Typ 0x3.
        var codec = V3Codec()
        codec.localKey = Data(hex: v.v3.localKey)
        codec.randomBytes = { Data(repeating: 0xAB, count: $0) }
        var packet = [UInt8](try codec.encodeEncrypted(Data(hex: v.v3.data)!))
        packet[5] = (packet[5] & 0xF0) | 0x3
        let hdr = Data(packet[0..<6])
        let plain = try MideaCrypto.decryptCBC(key: codec.localKey!, Data(packet[6..<(packet.count - 32)]))
        packet.replaceSubrange((packet.count - 32)..., with: MideaCrypto.sha256(hdr + plain))
        let frames = codec.feed(Data(packet.prefix(10))) + codec.feed(Data(packet.dropFirst(10)))
        XCTAssertEqual(frames.count, 1)
        let (type, payload) = try codec.decode(frames[0])
        XCTAssertEqual(type, .encryptedResponse)
        XCTAssertEqual(payload.hex, v.v3.data)
    }

    func testHandshakeLocalKey() throws {
        let key = try V3Codec.localKey(key: Data(hex: v.handshake.key)!, response: Data(hex: v.handshake.response)!)
        XCTAssertEqual(key.hex, v.handshake.localKey)
        var bad = Data(hex: v.handshake.response)!
        bad[0] ^= 1
        XCTAssertThrowsError(try V3Codec.localKey(key: Data(hex: v.handshake.key)!, response: bad))
    }

    /// Beispielantworten aus den Tests von msmart-ng.
    func testStateResponses() throws {
        let cases: [(String, Double, Double?, Double?)] = [
            ("aa22ac00000000000303c0014566000000300010045eff00000000000000000069fdb9", 21.0, 22.0, nil),
            ("aa23ac00000000000303c00145660000003c0010045c6b20000000000000000000020d79", 21.0, 21.0, 28.5),
            ("aa23ac00000000000203c00188647f7f000000000063450c0056190000000000000497c3", 24.0, 24.6, 9.5),
            ("aa1eac00000000000003c0004b1e7f7f000000000069630000000000000d33", 27.0, 27.5, 24.5),
        ]
        for (hex, target, indoor, outdoor) in cases {
            guard case .state(let s) = try Response.parse(Data(hex: hex)!) else { return XCTFail("keine Zustandsantwort: \(hex)") }
            XCTAssertEqual(s.targetTemperature, target)
            XCTAssertEqual(s.indoorTemperature ?? -99, indoor ?? -99, accuracy: 0.01)
            XCTAssertEqual(s.outdoorTemperature ?? -99, outdoor ?? -99, accuracy: 0.01)
        }
    }

    /// PortaSplit aus: Außenwert 10,0 °C ist ein Platzhalter (Byte 12 = 0x46) → unbekannt; eingeschaltet bleibt er.
    func testStandbyOutdoorPlaceholder() {
        var p: [UInt8] = [0xC0, 0x00, 0x8A, 0x01, 0x7F, 0x7F, 0x00, 0x30, 0x80, 0x80, 0x00, 0x5C, 0x46, 0x0E,
                          0, 0, 0, 0, 0, 0, 0]
        XCTAssertNil(Response.parseState(p).outdoorTemperature)
        p[1] = 0x01
        XCTAssertEqual(Response.parseState(p).outdoorTemperature, 10.0)
        var d = Diagnostics()
        d.t4OutdoorAir = 10.0
        d.dropStandbyPlaceholders(power: false)
        XCTAssertNil(d.t4OutdoorAir)
    }

    func testEnergyResponse() throws {
        guard case .energy(let watts, let kwh) = try Response.parse(Data(hex: "aa22ac00000000000803c1210144000005e00000000000000006000aeb000000487a5e")!) else {
            return XCTFail("keine Verbrauchsantwort")
        }
        // Gesamt binär 0x000005E0 = 1504 Schritte à 0,01 kWh (an echtem Verlauf geprüft); Leistung binär 279,5 W
        XCTAssertEqual(kwh ?? 0, 15.04, accuracy: 0.001)
        XCTAssertEqual(watts ?? 0, 279.5, accuracy: 0.001)
    }

    func testOutSilentProperty() {
        XCTAssertEqual(Response.parseOutSilent([0xB1, 1, 0xCD, 0x00, 0x00, 1, 3]), true)
        XCTAssertEqual(Response.parseOutSilent([0xB1, 1, 0xCD, 0x00, 0x00, 1, 0]), false)
        XCTAssertNil(Response.parseOutSilent([0xB1, 1, 0x1A, 0x00, 0x00, 0]))
    }

    func testControlVerification() {
        var before = ACState()
        before.power = true; before.mode = .heat; before.targetTemperature = 20; before.fanSpeed = 40
        var target = before; target.targetTemperature = 23
        let changed = PortaSplitDevice.changedControls(before, target)
        XCTAssertEqual(changed, [.temp])
        // Anlage hat übernommen
        var ok = target
        XCTAssertTrue(PortaSplitDevice.controlsMatch(ok, target, changed))
        // Anlage steht noch auf dem alten Soll -> nicht übernommen
        ok.targetTemperature = 20
        XCTAssertFalse(PortaSplitDevice.controlsMatch(ok, target, changed))
        XCTAssertEqual(PortaSplitDevice.mismatch(ok, target, changed), ["soll"])
        // Lüfter wird im Trocknen-Modus von der Anlage geregelt -> kein Mismatch
        var dryBefore = ACState(); dryBefore.power = true; dryBefore.mode = .dry; dryBefore.fanSpeed = 40
        var dryTarget = dryBefore; dryTarget.fanSpeed = 80
        let dryChanged = PortaSplitDevice.changedControls(dryBefore, dryTarget)
        var dryResult = dryTarget; dryResult.fanSpeed = 102 // Anlage hat Auto gewählt
        XCTAssertTrue(PortaSplitDevice.controlsMatch(dryResult, dryTarget, dryChanged))
        // Ausschalten: nur Ein/Aus zählt, Reihenfolge der Felder wie im Befehl
        var off = before; off.power = false; off.mode = .cool
        var offResult = before; offResult.mode = .heat
        XCTAssertEqual(PortaSplitDevice.mismatch(offResult, off, PortaSplitDevice.changedControls(before, off)), ["ein/aus"])
        var many = before; many.mode = .cool; many.eco = true; many.swing = .vertical
        XCTAssertEqual(PortaSplitDevice.mismatch(before, many, PortaSplitDevice.changedControls(before, many)),
                       ["modus", "swing", "eco"])
    }

    func testNearestRate() {
        XCTAssertEqual([0, 50, 62, 63, 75, 87, 88, 100, 150].map(PortaSplitDevice.nearestRate),
                       [50, 50, 50, 75, 75, 75, 100, 100, 100])
    }

    func testTimerEncoding() {
        // 10 h 37 min aus: 0x80 | 10<<2 | 2 Viertel = 0xAA, Rest 7
        let (on, off, rest) = DeviceTimer.encode(on: nil, off: 637)
        XCTAssertEqual([on, off, rest], [0x7F, 0xAA, 0x07])
        XCTAssertEqual(DeviceTimer.decode(on, off, rest).0, nil)
        XCTAssertEqual(DeviceTimer.decode(on, off, rest).1, 637)
        for m in [1, 14, 15, 59, 60, 61, 90, 479, 1439, 1440] {
            let e = DeviceTimer.encode(on: m, off: m)
            let d = DeviceTimer.decode(e.0, e.1, e.2)
            XCTAssertEqual(d.0, m); XCTAssertEqual(d.1, m)
        }
        XCTAssertEqual(DeviceTimer.decode(0x7F, 0x7F, 0x00).0, nil)
    }

    /// Ein Stellbefehl muss einen laufenden Timer erhalten (sonst löscht jeder Klick einen gestellten Timer).
    func testSetStateKeepsTimer() {
        var s = ACState()
        s.power = true; s.offTimerMinutes = 120
        let f = [UInt8](Frame.setState(s, beep: false, id: 1))
        XCTAssertEqual(Array(f[14...16]), [0x7F, 0x80 | 2 << 2, 0x00])
    }

    func testUdpid() throws {
        let v = try TestVectors.json()
        let u = v["udpid"] as! [String: Any]
        let id = (u["deviceId"] as! NSNumber).uint64Value
        XCTAssertEqual(Discovery.udpid(deviceId: id, bigEndian: false), u["little"] as? String)
        XCTAssertEqual(Discovery.udpid(deviceId: id, bigEndian: true), u["big"] as? String)
    }

    func testCloudSignatures() throws {
        let v = try TestVectors.json()
        let n = v["nethomeSign"] as! [String: Any]
        XCTAssertEqual(NetHomePlusClient.sign(endpoint: n["endpoint"] as! String, fields: n["body"] as! [String: String]),
                       n["sign"] as? String)
        XCTAssertEqual(NetHomePlusClient.encryptPassword(loginId: "LOGIN-ID", password: "geheim"), n["pwd"] as? String)
        let h = v["smarthome"] as! [String: String]
        XCTAssertEqual(SmartHomeClient.sign("{\"a\":1}", random: "00ff"), h["sign"])
        XCTAssertEqual(SmartHomeClient.encryptPassword(loginId: "LOGIN-ID", password: "geheim"), h["pwd"])
        XCTAssertEqual(SmartHomeClient.iamPassword(loginId: "LOGIN-ID", password: "geheim"), h["iam"])
    }

    /// Cloud-Steuerung (NetHome-Plus-„transparent send“): data_key-Ableitung, CSV, AES-String, Paket.
    func testCloudDataKeyRoundtrip() throws {
        let appKey = NetHomePlusClient.appKey
        let key = Data(MideaCrypto.md5(Data(appKey.utf8)).hex.prefix(16).utf8)
        let dataKey = Data((0..<32).map { UInt8($0) })
        let tokenHex = try MideaCrypto.encryptECB(key: key, dataKey).hex
        XCTAssertEqual(try CloudControlClient.deriveDataKey(accessTokenHex: tokenHex, appKey: appKey), dataKey)
    }

    func testCloudCSVRoundtrip() {
        let data = Data([0x00, 0x7F, 0x80, 0xFF, 0xAA, 0x01])
        XCTAssertEqual(CloudControlClient.csv(data), "0,127,-128,-1,-86,1")
        XCTAssertEqual(CloudControlClient.fromCSV("0,127,-128,-1,-86,1"), data)
    }

    func testCloudStringRoundtrip() throws {
        let dataKey = MideaCrypto.md5(Data("test".utf8)) // 16-Byte-Schlüssel
        let s = "1,2,3,-4,-5"
        let enc = try CloudControlClient.encryptString(s, dataKey: dataKey)
        XCTAssertEqual(try CloudControlClient.decryptString(enc, dataKey: dataKey), s)
    }

    func testCloudPacketRoundtrip() {
        let frame = Data([0xAA, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00]) // 7 Bytes, Längenbyte 0x06
        let packet = CloudPacket.encode(deviceId: 0x1122334455, frame: frame)
        XCTAssertEqual(packet.count, 40 + frame.count + 16) // 40-Byte-Kopf + Rahmen + 16-Byte-Signatur
        XCTAssertEqual(CloudPacket.decode(packet), frame)
    }

    /// Discovery-Antwort, nachgebildet nach echter Antwort der PortaSplit mit erfundener Geräte-ID, Seriennummer, MAC, Name und IP.
    func testDiscoveryParse() throws {
        let v = try TestVectors.json()
        let dev = try Discovery.parse(Data(hex: v["discovery"] as! String)!, ip: "192.168.1.40")
        XCTAssertEqual(dev.name, "net_ac_1A2B")
        XCTAssertEqual(dev.type, 0xAC)
        XCTAssertEqual(dev.version, 3)
        XCTAssertEqual(dev.port, 6444)
        XCTAssertEqual(dev.deviceId, 20015998343868)
        XCTAssertTrue(dev.sn.hasSuffix("1A2B0000"))
    }

    /// Token 64 Byte und Schlüssel 32 Byte als Hex – kürzere Werte weist die Prüfung beim Einlesen ab.
    static let token = String(repeating: "11", count: 64)
    static let key = String(repeating: "00", count: 32)

    func testExportRoundTrip() throws {
        let cfg = DeviceConfig(name: "net_ac_TEST", ip: "10.0.0.9", port: 6444, deviceId: 1234, token: Self.token, key: Self.key)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-test.json")
        let scene = ACScene(id: "x", name: "Test", powerOn: true, mode: 2, tempC: 22, fan: 102, swing: false,
                            eco: false, anion: false, outdoorSilent: false, selfClean: false)
        try cfg.exportBackup(to: url, scenes: [scene])
        XCTAssertEqual(try DeviceConfig.fromBackup(url), cfg)
        XCTAssertEqual(try ACScene.fromBackup(url), [scene])
    }

    /// device.json und szenen.json sind direkt nach dem Speichern nur für den Benutzer lesbar (kein 0644-Fenster).
    func testSaveWritesPrivateFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = DeviceConfig(name: "PortaSplit", ip: "10.0.0.9", port: 6444, deviceId: 1234, token: Self.token, key: Self.key)
        let url = dir.appendingPathComponent("device.json")
        try cfg.save(to: url)
        func perms(_ u: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int }
        XCTAssertEqual(try perms(url), 0o600)
        XCTAssertEqual(try perms(dir), 0o700)
        XCTAssertEqual(DeviceConfig.load(from: url), cfg)
        // Zweites Speichern ersetzt die Datei und bleibt privat.
        try cfg.save(to: url)
        XCTAssertEqual(try perms(url), 0o600)

        let scenes = dir.appendingPathComponent("szenen.json")
        let scene = ACScene(id: "x", name: "Test", powerOn: true, mode: 2, tempC: 22, fan: 102, swing: false,
                            eco: false, anion: false, outdoorSilent: false, selfClean: false)
        try ACScene.save([scene], to: scenes)
        XCTAssertEqual(try perms(scenes), 0o600)
        XCTAssertEqual(ACScene.load(from: scenes), [scene])
    }

    /// Fehlende device.json bleibt still nil; eine unlesbare wird beiseitegelegt statt still übergangen.
    func testUnreadableDeviceConfigIsMovedAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("device.json")
        XCTAssertNil(DeviceConfig.load(from: url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

        try Data("{\"name\": 1".utf8).write(to: url)
        XCTAssertNil(DeviceConfig.load(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "defekte Datei nicht liegen lassen")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("device.json.defekt-"), files[0])
        XCTAssertFalse(files[0].contains(":"), "Zeitstempel ohne Doppelpunkte: \(files[0])")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(files[0])), Data("{\"name\": 1".utf8), "Inhalt bleibt erhalten")
    }

    func testLogRedaction() {
        let json = #"{"tokenlist":[{"udpId":"ab","token":"SECRET1","key":"SECRET2"}],"mdata":{"accessToken":"SECRET3"}}"#
        let r = AppLog.redact(json)
        XCTAssertFalse(r.contains("SECRET"))
        XCTAssertTrue(r.contains("\"udpId\":\"ab\""))
        let form = "appId=1017&password=SECRET4&sessionId=SECRET5&loginAccount=nutzer%40example.com"
        let f = AppLog.redact(form)
        XCTAssertFalse(f.contains("SECRET"))
        XCTAssertTrue(f.contains("appId=1017"))
        XCTAssertFalse(f.contains("nutzer%40example.com"), "volle E-Mail nicht ins Protokoll")
    }

    /// Liest das Protokoll, nachdem `body` geschrieben hat (`tail()` wartet auf die Queue).
    private func loggedText(_ body: () -> Void) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppLog.redirect(to: dir)
        defer { AppLog.redirect(to: nil); try? FileManager.default.removeItem(at: dir) }
        body()
        return AppLog.tail()
    }

    func testWriteRedactsSecretsCentrally() throws {
        let text = try loggedText {
            AppLog.write(#"Antwort {"token":"abc","password":"x"}"#)
            AppLog.write("Anfrage password=geheim&sessionId=1")
            AppLog.write(#"maskiert {\"token\":\"abc\",\"userInfo\":{\"email\":\"a@b.de\"}}"#)
        }
        XCTAssertFalse(text.contains("abc"), text)
        XCTAssertFalse(text.contains("geheim"), text)
        XCTAssertFalse(text.contains("a@b.de"), text)
        XCTAssertTrue(text.contains(#"{"token":"***","password":"***"}"#), text)
        XCTAssertTrue(text.contains("password=***&sessionId=***"), text)
        XCTAssertTrue(text.contains(#"\"token\":\"***\""#), text)
    }

    func testErrorAndDebugAreRedacted() throws {
        let before = AppLog.debugEnabled
        AppLog.debugEnabled = true
        defer { AppLog.debugEnabled = before }
        let text = try loggedText {
            AppLog.error(#"Fehler {"token":"abc"}"#)
            AppLog.debug("Rahmen password=geheim")
        }
        XCTAssertFalse(text.contains("abc") || text.contains("geheim"), text)
        XCTAssertEqual(text.components(separatedBy: "***").count - 1, 2, text)
    }

    func testNormalLogLinesStayUnchanged() throws {
        let lines = ["Befehl: Soll 19°", "Verbindung über WLAN",
                     "Netz-Scan über 254 Adressen: net_ac_1A2B 192.168.1.40 V3",
                     "key ist hier nur ein Wort, token auch", "→ aa 23 ac 00 00 00 00 00 03 41 81 00 ff 03 ff 00 20: x",
                     "Uhrzeit 12:30 Modus Kühlen"]
        for l in lines { XCTAssertEqual(AppLog.redact(l), l) }
        let text = try loggedText { lines.forEach { AppLog.write($0) } }
        for l in lines { XCTAssertTrue(text.contains(" INFO \(l)\n") || text.hasSuffix(" INFO \(l)"), l) }
    }

    func testEscapedJSONRedaction() {
        XCTAssertEqual(AppLog.redact(#"{\"token\":\"abc\",\"id\":\"7\"}"#), #"{\"token\":\"***\",\"id\":\"7\"}"#)
        XCTAssertEqual(AppLog.redact(#"x \"userInfo\":{\"uid\":\"1\"} y"#), #"x \"userInfo\":\"***\" y"#)
        XCTAssertEqual(AppLog.redact(#"{\"count\":5,\"uid\":12345}"#), #"{\"count\":5,\"uid\":\"***\"}"#)
    }

    /// Vorkompilierte Schwärzung liefert dasselbe wie 26 Einzel-Regexe nacheinander.
    func testLogRedactionMatchesReference() {
        func reference(_ text: String) -> String {
            let keys = ["token", "key", "accessToken", "sessionId", "password", "iampwd", "pushToken", "refreshToken",
                        "loginId", "loginAccount", "randomData", "tokenPwd", "secretKey"]
            var out = text
            for k in keys {
                out = out.replacingOccurrences(of: "\"\(k)\"\\s*:\\s*\"[^\"]*\"", with: "\"\(k)\":\"***\"",
                                               options: [.regularExpression, .caseInsensitive])
            }
            for k in keys {
                out = out.replacingOccurrences(of: "(^|&)\(k)=[^&]*", with: "$1\(k)=***", options: [.regularExpression, .caseInsensitive])
            }
            return out
        }
        let samples = [
            #"{"tokenlist":[{"udpId":"ab","token":"SECRET1","key":"SECRET2"}],"mdata":{"accessToken":"SECRET3"}}"#,
            #"{"Token" : "a", "SECRETKEY":"b","tokenPwd":"c","secretKey":"","x":"key"}"#,
            "appId=1017&password=SECRET4&sessionId=SECRET5&loginAccount=nutzer%40example.com&tokenPwd=z&Key=k",
            "key=1&token=&tokenPwd=2&x=token=3",
            "ohne Doppelpunkt oder Gleichheitszeichen", "", "ä:ö=ü \"key\":\"€\" 🌡️&key=👍",
        ]
        for s in samples { XCTAssertEqual(AppLog.redact(s), reference(s), s) }
    }

    func testHexLookupTable() {
        XCTAssertEqual(Data([0x00, 0x0f, 0xa0, 0xff, 0x12]).hex, "000fa0ff12")
        XCTAssertEqual(Data().hex, "")
        let all = Data((0...255).map { UInt8($0) })
        XCTAssertEqual(all.hex, all.map { b in String(b, radix: 16).count == 1 ? "0" + String(b, radix: 16) : String(b, radix: 16) }.joined())
        XCTAssertEqual(Data(hex: all.hex), all)
    }

    func testBackupImport() throws {
        func backup(ip: String = "10.0.0.9", token: String = Self.token, name: String = "net_ac_TEST") throws -> URL {
            let json = """
            {"devices":[{"deviceId":1234,"discoveredName":"\(name)","ip":"\(ip)","key":"\(Self.key)","port":6444,"token":"\(token)","type":172,"version":3}],"region":"DE","scenes":[{"id":"s","name":"Nacht","powerOn":true,"mode":2,"tempC":1e300,"fan":102,"swing":false,"eco":false,"anion":false,"outdoorSilent":false,"selfClean":false}],"version":1}
            """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cp-backup-test.json")
            try Data(json.utf8).write(to: url)
            return url
        }
        let cfg = try DeviceConfig.fromBackup(backup())
        XCTAssertEqual(cfg, DeviceConfig(name: "net_ac_TEST", ip: "10.0.0.9", port: 6444, deviceId: 1234, token: Self.token, key: Self.key))
        XCTAssertEqual(try ACScene.fromBackup(backup()).first?.tempC, 30, "unsinnige Temperatur wird begrenzt")
        XCTAssertThrowsError(try DeviceConfig.fromBackup(backup(ip: "evil.example.com")))
        XCTAssertThrowsError(try DeviceConfig.fromBackup(backup(token: "11")))
        XCTAssertEqual(try DeviceConfig.fromBackup(backup(name: "a\\nINFO gefälscht")).name.contains("\n"), false)
    }

    func testSubnetHosts() throws {
        // /24: alle Hosts außer der eigenen Adresse, Broadcast des Netzes.
        let n24 = try XCTUnwrap(Discovery.hosts(ip: "192.168.1.208", mask: "255.255.255.0"))
        XCTAssertEqual(n24.hosts.count, 253)
        XCTAssertEqual(n24.hosts.first, "192.168.1.1")
        XCTAssertEqual(n24.hosts.last, "192.168.1.254")
        XCTAssertFalse(n24.hosts.contains("192.168.1.208"), "eigene Adresse wird nicht gefragt")
        XCTAssertFalse(n24.hosts.contains("192.168.1.0"))
        XCTAssertFalse(n24.hosts.contains("192.168.1.255"))
        XCTAssertEqual(n24.broadcast, "192.168.1.255")
        XCTAssertEqual(Set(n24.hosts).count, 253, "keine Doppelten")

        // /22: 1022 Hosts (ohne die eigene 1021), Broadcast am Ende des Blocks.
        let n22 = try XCTUnwrap(Discovery.hosts(ip: "192.168.1.208", mask: "255.255.252.0"))
        XCTAssertEqual(n22.hosts.count, 1021)
        XCTAssertEqual(n22.hosts.first, "192.168.0.1")
        XCTAssertEqual(n22.hosts.last, "192.168.3.254")
        XCTAssertEqual(n22.broadcast, "192.168.3.255")

        // Größer als /22 → auf das /24 des eigenen Hosts beschränkt.
        let n16 = try XCTUnwrap(Discovery.hosts(ip: "10.7.42.9", mask: "255.255.0.0"))
        XCTAssertEqual(n16.hosts.count, 253)
        XCTAssertEqual(n16.hosts.first, "10.7.42.1")
        XCTAssertEqual(n16.broadcast, "10.7.42.255")
        let n8 = try XCTUnwrap(Discovery.hosts(ip: "10.7.42.9", mask: "255.0.0.0"))
        XCTAssertEqual(n8.hosts.count, 253)

        // /30 hat zwei Hosts; /31, /32, kaputte Masken und kaputte Adressen liefern nichts.
        let n30 = try XCTUnwrap(Discovery.hosts(ip: "192.168.1.1", mask: "255.255.255.252"))
        XCTAssertEqual(n30.hosts, ["192.168.1.2"])
        XCTAssertNil(Discovery.hosts(ip: "192.168.1.1", mask: "255.255.255.254"))
        XCTAssertNil(Discovery.hosts(ip: "192.168.1.1", mask: "255.255.255.255"))
        XCTAssertNil(Discovery.hosts(ip: "192.168.1.1", mask: "255.0.255.0"))
        XCTAssertNil(Discovery.hosts(ip: "192.168.1.1", mask: "0.0.0.0"))
        XCTAssertNil(Discovery.hosts(ip: "192.168.2", mask: "255.255.255.0"))
        XCTAssertNil(Discovery.hosts(ip: "192.168.1.300", mask: "255.255.255.0"))
        XCTAssertEqual(Discovery.dotted(0xC0A80128), "192.168.1.40")
        XCTAssertEqual(Discovery.ipv4Value("192.168.1.40"), 0xC0A80128)
    }

    /// Einmaliger Live-Lauf (nur lesend, UDP) – nur mit KLIMACONTROL_LIVE_SCAN=1, sonst übersprungen.
    func testLiveSubnetScan() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KLIMACONTROL_LIVE_SCAN"] == "1", "Live-Scan nur auf Wunsch")
        let nets = NetSocket.localNetworks()
        print("Netz-Scan: Netze \(nets)")
        XCTAssertFalse(nets.isEmpty)
        let start = Date()
        let found = try await Discovery.scanSubnet(timeout: 3) { sent, total in
            if sent % 128 == 0 || sent == total { print("Netz-Scan: \(sent) von \(total)") }
        }
        print("Netz-Scan: \(found.count) gefunden in \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(found.map { "\($0.name) \($0.ip) V\($0.version)" })")
    }
}
