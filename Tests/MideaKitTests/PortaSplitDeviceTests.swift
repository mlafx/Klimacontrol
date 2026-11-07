import XCTest
@testable import MideaKit

/// PortaSplitDevice über nachgebildete Wege (kein echtes Netz).
final class PortaSplitDeviceTests: XCTestCase {

    /// Nachgebildete Anlage: antwortet auf Zustandsabfrage, Stellbefehl und Display-Umschalten.
    /// `@unchecked Sendable` ohne Lock: `PortaSplitDevice` ruft den Weg nur auf seiner seriellen Queue auf, und der
    /// Test setzt bzw. liest die Felder nur vor bzw. nach einem abgewarteten Gerätevorgang (Ordnung über die Queue).
    final class DeviceFake: FrameTransport, @unchecked Sendable {
        var quietErrors = false
        var temp = 22.5, fan = 102, displayOn = true
        /// Was die Anlage nach einem Stellbefehl meldet (nil = Wert aus dem Befehl unverändert lassen).
        var fanAfterSet: Int?
        var tempAfterSet: Double?
        /// Display-Umschalten: wirkt es, und geht die Antwort verloren?
        var toggleWorks = true, toggleReplyLost = false
        /// Gemeldete Leistungsbegrenzung (%).
        var rate = 100
        var getStates = 0, sets: [Data] = [], toggles = 0, singles = 0
        var deadlines: [Date?] = []
        var deadlineDuringSend: Date??

        static func stateFrame(temp: Double, fan: Int, display: Bool) -> Data {
            var p = [UInt8](repeating: 0, count: 23)
            p[0] = 0xC0; p[1] = 0x01
            let whole = Int(temp)
            p[2] = UInt8((whole - 16) & 0xF) | (temp - Double(whole) > 0 ? 0x10 : 0) | (2 << 5)
            p[3] = UInt8(fan)
            p[14] = display ? 0x00 : 0x70
            return Frame.build(.query, p, id: 1)
        }

        var reply: Data { Self.stateFrame(temp: temp, fan: fan, display: displayOn) }

        func send(_ frame: Data, retries: Int, expect: UInt8?) throws -> [Data] {
            deadlineDuringSend = deadlines.last
            let f = [UInt8](frame)
            if f[10] == 0x40 {
                sets.append(frame)
                if let fanAfterSet { fan = fanAfterSet }
                if let tempAfterSet { temp = tempAfterSet }
                return [reply]
            }
            if f[10] == 0x41, f[11] != 0x21, f[14] == 0x02 {
                toggles += 1
                if toggleWorks { displayOn.toggle() }
                if toggleReplyLost { throw MideaError.timeout }
                return [reply]
            }
            if f[10] == 0x41, f[11] != 0x21 { getStates += 1; return [reply] }
            if f[10] == 0xB0 { return [] }   // Eigenschaft setzen: die Anlage übernimmt `rate` nicht
            if f[10] == 0xB1 {
                let id = PropertyId.rateSelect.rawValue
                return [Frame.build(.query, [0xB1, 1, UInt8(id & 0xFF), UInt8(id >> 8), 0, 1, UInt8(rate)], id: 2)]
            }
            throw MideaError.timeout   // Gruppen: hier ohne Antwort
        }

        func sendSingle(_ frame: Data, expect: UInt8?) throws -> [Data] {
            singles += 1
            return try send(frame, retries: 0, expect: expect)
        }

        func setDeadline(_ deadline: Date?) { deadlines.append(deadline) }
        func idle() {}
        func disconnect() {}
    }

    static let config = DeviceConfig(name: "Test", ip: "192.168.1.10", port: 6444, deviceId: 0x1234,
                                     token: String(repeating: "a", count: 128), key: String(repeating: "b", count: 64))

    private func device(_ fake: DeviceFake, mode: ConnectionMode = .lan) -> PortaSplitDevice {
        let d = PortaSplitDevice(config: Self.config, transport: AutoTransport(lan: fake, mode: mode))
        d.idleDisconnect = 0.01
        return d
    }

    // MARK: Wegwahl und Wartezeiten

    func testOptionalQueryFailureDoesNotSwitchToCloud() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply])
        lan.fail = true
        XCTAssertThrowsError(try t.sendSingle(Data(), expect: nil))
        XCTAssertTrue(cloud.sends.isEmpty, "optionale Abfrage: kein Rückfall auf die Cloud")
        lan.fail = false
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply], "WLAN bleibt frei")
        XCTAssertEqual(t.path, .lan)
    }

    func testAllPathsFailedResetsRetryInterval() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        lan.fail = true
        _ = try t.send(Data(), retries: 2, expect: nil)                 // WLAN gesperrt (60 s)
        clock = clock.addingTimeInterval(61)
        _ = try t.send(Data(), retries: 2, expect: nil)                 // erneut gescheitert → 120 s
        clock = clock.addingTimeInterval(1)
        cloud.fail = true
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil)) // alles weg → Sperren und Wartezeiten fallen
        cloud.fail = false
        clock = clock.addingTimeInterval(1)
        _ = try t.send(Data(), retries: 2, expect: nil)                 // WLAN scheitert, Sperre neu: 60 s
        let tries = lan.sends.count
        clock = clock.addingTimeInterval(61)
        lan.fail = false
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply], "nach 60 s (nicht 120 s) wieder WLAN")
        XCTAssertEqual(lan.sends.count, tries + 1)
    }

    func testRefreshSendsOptionalQueriesSingly() async throws {
        let fake = DeviceFake()
        let dev = device(fake)
        let s = try await dev.refresh()
        XCTAssertEqual(s.targetTemperature, 22.5)
        XCTAssertEqual(fake.singles, 2, "Eigenschaften und Verbrauch nur einmal, ohne Rückfall")
    }

    // MARK: Zeitbudget

    func testRunSetsAndClearsDeadline() async throws {
        let fake = DeviceFake()
        let dev = device(fake)
        dev.commandBudget = 10
        _ = try await dev.refreshFast(extras: false)
        guard let during = fake.deadlineDuringSend, let d = during else { return XCTFail("kein Zeitlimit gesetzt") }
        XCTAssertLessThanOrEqual(d.timeIntervalSinceNow, 10.5)
        XCTAssertNil(fake.deadlines.last ?? nil, "nach dem Auftrag wieder ohne Limit")
    }

    func testBudgetedWaitIsClampedAndExpires() throws {
        let lan = LANClient(host: "192.0.2.1", port: 6444, deviceId: 1, token: Data(), key: Data())
        XCTAssertEqual(try lan.budgeted(4), 4)
        lan.deadline = Date().addingTimeInterval(2)
        XCTAssertLessThanOrEqual(try lan.budgeted(4), 2)
        lan.deadline = Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try lan.budgeted(4)) { error in
            XCTAssertEqual(error as? MideaError, .connectionFailed(LANClient.budgetHint))
        }
    }

    func testUpdateUsesRecentStateWithoutExtraQuery() async throws {
        let fake = DeviceFake()
        fake.fanAfterSet = 40
        let dev = device(fake)
        _ = try await dev.refreshFast(extras: false)
        _ = try await dev.update { $0.fanSpeed = 40 }
        XCTAssertEqual(fake.getStates, 1, "Stand ist Sekunden alt – keine zweite Abfrage vor dem Befehl")
        XCTAssertEqual(fake.sets.count, 1)
    }

    func testUnclearOutcomeAfterSend() {
        let e = PortaSplitDevice.unclearOutcome(MideaError.timeout) as? MideaError
        XCTAssertEqual(e, .outcomeUnknown("Die Anlage antwortet nicht."))
        XCTAssertEqual(e?.errorDescription, "Keine Verbindung zur Anlage: Die Anlage antwortet nicht. Ob die Änderung "
                       + "angekommen ist, ist unklar – bitte die Anzeige prüfen. (nach dem Senden)")
        let applied = MideaError.commandNotApplied(ACState())
        XCTAssertEqual(PortaSplitDevice.unclearOutcome(applied) as? MideaError, applied)
        // Meldet die Cloud die Anlage als aus, kam der Befehl sicher nicht an.
        let off = MideaError.allPathsFailed([PathFailure.from(MideaCloud.CloudError.api(3123, "offline"), path: .cloud)])
        XCTAssertEqual(PortaSplitDevice.unclearOutcome(off) as? MideaError, off)
    }

    // MARK: Temperatur halbe Grad

    func testUpdateKeepsHalfDegreeWhenTemperatureUnchanged() async throws {
        let fake = DeviceFake()
        fake.fanAfterSet = 40
        let dev = device(fake)
        let s = try await dev.update { $0.fanSpeed = 40 }
        XCTAssertEqual(s.targetTemperature, 22.5)
        guard case .state(var expected) = try Response.parse(fake.reply) else { return XCTFail() }
        expected.fanSpeed = 40
        expected.targetTemperature = 22.5
        let sent = try XCTUnwrap(fake.sets.first)
        XCTAssertEqual(sent, Frame.setState(expected, beep: true, id: sent[sent.count - 3]), "22,5 °C nicht still gerundet")
    }

    func testUpdateRoundsChangedTemperature() async throws {
        let fake = DeviceFake()
        fake.tempAfterSet = 24
        let dev = device(fake)
        let s = try await dev.update { $0.targetTemperature = 23.5 }
        XCTAssertEqual(s.targetTemperature, 24)
        guard case .state(var expected) = try Response.parse(DeviceFake.stateFrame(temp: 22.5, fan: 102, display: true)) else { return XCTFail() }
        expected.targetTemperature = 24
        let sent = try XCTUnwrap(fake.sets.first)
        XCTAssertEqual(sent, Frame.setState(expected, beep: true, id: sent[sent.count - 3]))
    }

    // MARK: Display umschalten

    func testToggleDisplayOnce() async throws {
        let fake = DeviceFake()
        let s = try await device(fake).toggleDisplay()
        XCTAssertFalse(s.displayOn)
        XCTAssertEqual(fake.toggles, 1)
    }

    func testToggleDisplayLostReplyDoesNotToggleBack() async throws {
        let fake = DeviceFake()
        fake.toggleReplyLost = true
        let s = try await device(fake).toggleDisplay()
        XCTAssertFalse(s.displayOn)
        XCTAssertEqual(fake.toggles, 1, "Antwort verloren, Display aber umgeschaltet: nicht noch einmal senden")
    }

    func testToggleDisplayRetriesOnceWhenUnchanged() async throws {
        let fake = DeviceFake()
        fake.toggleWorks = false
        let s = try await device(fake).toggleDisplay()
        XCTAssertTrue(s.displayOn)
        XCTAssertEqual(fake.toggles, 2, "genau einmal nachfassen")
    }

    // MARK: Leistungsbegrenzung

    func testSetRateThrowsWhenNotApplied() async throws {
        let fake = DeviceFake()
        let dev = device(fake)
        do {
            _ = try await dev.setRate(75)
            XCTFail("75 % nicht übernommen – Fehler erwartet")
        } catch MideaError.commandNotApplied(let s) {
            XCTAssertEqual(s.ratePercent, 100)
        }
        let ok = try await dev.setRate(100)
        XCTAssertEqual(ok.ratePercent, 100)
    }

    // MARK: Gruppenantworten

    func testGroupReplyChecksGroupByte() {
        var f = [UInt8](repeating: 0, count: 20)
        f[10] = 0xC1; f[13] = 0x44
        XCTAssertTrue(PortaSplitDevice.isGroupReply(Data(f), 4))
        XCTAssertFalse(PortaSplitDevice.isGroupReply(Data(f), 5), "verspätete Antwort einer anderen Gruppe verwerfen")
        f[10] = 0xC0
        XCTAssertFalse(PortaSplitDevice.isGroupReply(Data(f), 4))
    }

    // MARK: „Belegt“

    func testBusyMessageNamesBothApps() {
        let text = MideaError.busy(LANClient.busyHint).errorDescription ?? ""
        XCTAssertTrue(text.contains("belegt"))
        XCTAssertTrue(text.contains("Klimacontrol-App"))
        XCTAssertTrue(text.contains("Midea-App"))
    }

    // MARK: Phasen

    func testCloudModeReportsReadingPhase() async throws {
        let fake = DeviceFake()
        let dev = PortaSplitDevice(config: Self.config, transport: AutoTransport(lan: nil, cloud: fake, mode: .cloud))
        let seen = Locked<[ConnectPhase]>([])
        dev.onPhase = { phase in seen.mutate { $0.append(phase) } }
        _ = try await dev.refreshFast(extras: false)
        XCTAssertEqual(seen.value, [.reading])
    }

    #if !os(Windows)
    /// Eine vorhandene, für alle lesbare Datei (z. B. alte Sicherung) wird mit 0600 ersetzt, nicht mit ihren Rechten.
    func testWritePrivateReplacesWithOwnerOnlyPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klimacontrol-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sicherung.json")
        FileManager.default.createFile(atPath: url.path, contents: Data("alt".utf8), attributes: [.posixPermissions: 0o644])
        try DeviceConfig.writePrivate(Data("neu".utf8), to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "neu")
    }
    #endif
}
