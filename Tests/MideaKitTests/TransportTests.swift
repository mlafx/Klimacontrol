import XCTest
@testable import MideaKit

/// Wegwahl WLAN ↔ Cloud mit nachgebildeten Wegen.
final class TransportTests: XCTestCase {
    static let offline = MideaCloud.CloudError.api(3123, "The appliance is offline")

    /// Ging ein Stellbefehl im WLAN schon hinaus, wird er nicht still über die Cloud wiederholt (AGENTS.md 6.3) –
    /// eine Abfrage darf weiter auf die Cloud ausweichen.
    func testSentControlFrameIsNotRepeatedOverCloud() {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        lan.fail = true
        lan.error = MideaError.timeout
        lan.failedAfterWrite = true
        XCTAssertThrowsError(try t.send(TestFrames.control, retries: 2, expect: nil))
        XCTAssertEqual(cloud.sends, [], "Stellbefehl nach dem Senden nicht über die Cloud wiederholt")
    }

    func testQueryStillFallsBackAfterWrite() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        lan.fail = true
        lan.failedAfterWrite = true
        XCTAssertEqual(try t.send(TestFrames.query, retries: 2, expect: nil), [cloud.reply])
    }

    func testControlFrameNotSentFallsBackToCloud() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        lan.fail = true
        lan.failedAfterWrite = false
        XCTAssertEqual(try t.send(TestFrames.control, retries: 2, expect: nil), [cloud.reply], "nichts gesendet: Cloud darf")
    }

    /// Hilfe: Fehlertext einer fehlgeschlagenen Sendung (leer, wenn sie nicht fehlschlug).
    private func failureText(_ t: AutoTransport) -> String {
        do { _ = try t.send(Data(), retries: 2, expect: nil); return "" } catch {
            return (error as? MideaError)?.errorDescription ?? "\(error)"
        }
    }

    func testAutoPrefersLANAndFallsBackToCloud() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply])
        XCTAssertEqual(t.path, .lan)
        XCTAssertEqual(lan.sends, [0], "mit Ausweichweg keine WLAN-Wiederholungen")

        lan.fail = true
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        XCTAssertEqual(t.path, .cloud)
        XCTAssertEqual(cloud.sends, [2], "nur der letzte Weg wiederholt")
        XCTAssertEqual(lan.disconnects, 1, "WLAN beim Wechsel freigeben")

        // innerhalb von 60 s kein neuer WLAN-Versuch (solange die Cloud antwortet)
        clock = clock.addingTimeInterval(30)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        XCTAssertEqual(lan.sends.count, 2)

        // nach 60 s wieder WLAN
        lan.fail = false
        clock = clock.addingTimeInterval(31)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply])
        XCTAssertEqual(t.path, .lan)
        XCTAssertEqual(cloud.disconnects, 0, "die Cloud hält nichts offen")
    }

    /// Internet weg, WLAN nur kurz gestört: scheitert die Cloud mit einem Netzfehler, fällt die WLAN-Sperre
    /// sofort – die nächste Sendung beginnt wieder mit WLAN (sonst bis 60 s nicht steuerbar).
    func testCloudNetworkErrorLiftsLANBlock() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        t.now = { Date(timeIntervalSince1970: 0) }
        lan.fail = true
        cloud.fail = true
        cloud.error = MideaCloud.CloudError.network("offline")
        let text = failureText(t)
        XCTAssertTrue(text.contains("WLAN: weg") && text.contains("Cloud: Cloud nicht erreichbar"), text)
        lan.fail = false
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply], "sofort wieder WLAN, keine Wartezeit")
        XCTAssertEqual(lan.sends.count, 2)
        XCTAssertEqual(t.path, .lan)
    }

    /// „Anlage offline“ (3123): WLAN-Sperre bleibt, die Cloud wird 5 min nicht gefragt, der Grund steht im Text;
    /// nach 5 min wieder ein Cloud-Versuch.
    func testApplianceOfflineBacksOffCloud() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        lan.fail = true
        cloud.fail = true
        cloud.error = Self.offline
        XCTAssertTrue(failureText(t).contains("Cloud: Anlage offline laut Cloud (3123)"))
        XCTAssertEqual(cloud.sends.count, 1)

        clock = clock.addingTimeInterval(30)
        let text = failureText(t)
        XCTAssertTrue(text.contains("ausgeschaltet oder ohne Strom"), text)
        XCTAssertTrue(text.contains("nächste Prüfung in 5 min"), text)
        XCTAssertFalse(text.contains("WLAN"), "WLAN bleibt gesperrt und wird nicht genannt: \(text)")
        XCTAssertEqual(lan.sends.count, 1, "WLAN-Sperre bleibt – die Anlage ist wirklich aus")
        XCTAssertEqual(cloud.sends.count, 1, "Cloud im Rückzug nicht gefragt")

        // Kurz vor Ablauf: Minuten aufgerundet, unter 1 min eigener Text.
        clock = Date(timeIntervalSince1970: 270)
        XCTAssertTrue(failureText(t).contains("in weniger als 1 min"))
        XCTAssertEqual(cloud.sends.count, 1)

        clock = Date(timeIntervalSince1970: 300)
        cloud.fail = false
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply], "nach 5 min wieder Cloud")
        XCTAssertEqual(cloud.sends.count, 2)
        // Erfolg beendet den Rückzug: die nächste Sendung geht sofort an die Cloud.
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        XCTAssertEqual(cloud.sends.count, 3)
    }

    /// Nur Cloud: der Rückzug nach 3123 gilt auch ohne Ausweichweg.
    func testCloudOnlyModeBacksOffAfterOffline() {
        let cloud = FakeTransport(3)
        let t = AutoTransport(lan: nil, cloud: cloud, mode: .cloud)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        cloud.fail = true
        cloud.error = Self.offline
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil))
        clock = clock.addingTimeInterval(60)
        XCTAssertTrue(failureText(t).contains("ausgeschaltet oder ohne Strom"))
        XCTAssertEqual(cloud.sends.count, 1)
        clock = clock.addingTimeInterval(300)
        cloud.fail = false
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
    }

    /// Unterwegs (Cloud läuft): WLAN wird erst nach 60 s nachgeprüft, bei erneutem Fehlschlag 120, 240, dann
    /// höchstens 300 s; ein WLAN-Erfolg setzt auf 60 s zurück.
    func testLANRetryIntervalDoublesWhileCloudWorks() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        lan.fail = true
        /// Sendet zur Zeit `at` und liefert, ob WLAN dabei versucht wurde.
        func triesLAN(at seconds: TimeInterval) throws -> Bool {
            clock = Date(timeIntervalSince1970: seconds)
            let before = lan.sends.count
            XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
            return lan.sends.count > before
        }
        XCTAssertTrue(try triesLAN(at: 0))        // erster Fehlschlag → Wartezeit 60 s
        XCTAssertFalse(try triesLAN(at: 59))
        XCTAssertTrue(try triesLAN(at: 60))       // erneut gescheitert → 120 s
        XCTAssertFalse(try triesLAN(at: 179))
        XCTAssertTrue(try triesLAN(at: 180))      // → 240 s
        XCTAssertFalse(try triesLAN(at: 419))
        XCTAssertTrue(try triesLAN(at: 420))      // → 300 s (Obergrenze, nicht 480)
        XCTAssertFalse(try triesLAN(at: 719))
        lan.fail = false
        clock = Date(timeIntervalSince1970: 720)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply])
        // Zurück auf 60 s: nächster Ausfall wird nach 60 s nachgeprüft, nicht erst nach 300 s.
        lan.fail = true
        XCTAssertTrue(try triesLAN(at: 720))      // Ausfall direkt nach dem Erfolg → wird versucht
        XCTAssertFalse(try triesLAN(at: 779))
        XCTAssertTrue(try triesLAN(at: 780))
    }

    /// `resetBackoff` hebt WLAN-Sperre, verlängerte Wartezeit und Cloud-Rückzug auf.
    func testResetBackoffLiftsEverything() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        // WLAN zweimal gescheitert bei laufender Cloud → Wartezeit 120 s.
        lan.fail = true
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        clock = Date(timeIntervalSince1970: 60)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        XCTAssertEqual(lan.sends.count, 2)
        // Dann Anlage aus → Cloud-Rückzug.
        cloud.fail = true
        cloud.error = Self.offline
        clock = Date(timeIntervalSince1970: 61)
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil))
        XCTAssertEqual(cloud.sends.count, 3)
        clock = Date(timeIntervalSince1970: 62)
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil))
        XCTAssertEqual(lan.sends.count, 2, "WLAN gesperrt")
        XCTAssertEqual(cloud.sends.count, 3, "Cloud im Rückzug")

        t.resetBackoff()
        lan.fail = false
        clock = Date(timeIntervalSince1970: 63)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply], "WLAN sofort wieder versucht")
        // Wartezeit wieder 60 s: nächster Ausfall nach 60 s nachgeprüft (nicht 120).
        lan.fail = true
        cloud.fail = false
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        XCTAssertEqual(cloud.sends.count, 4, "Cloud-Rückzug aufgehoben")
        let sendsBefore = lan.sends.count
        clock = Date(timeIntervalSince1970: 63 + 60)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        XCTAssertEqual(lan.sends.count, sendsBefore + 1)
    }

    /// Kurzgründe für Cloud-Fehler im gemeinsamen Fehlerbild.
    func testShortReasonForCloudErrors() {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        t.now = { Date(timeIntervalSince1970: 0) }
        lan.fail = true
        cloud.fail = true
        cloud.error = MideaCloud.CloudError.api(3004, "token\u{0}expired")
        XCTAssertTrue(failureText(t).contains("Cloud: tokenexpired (3004)"), "Steuerzeichen raus, Code dran")
        cloud.error = MideaCloud.CloudError.noToken
        XCTAssertTrue(failureText(t).contains("Cloud: Die Cloud kennt diese Anlage nicht"))
    }

    /// Alle Wege gescheitert: je Weg ein typisierter Grund, der Text bleibt die gewohnte Zusammenfassung.
    func testAllPathsFailedIsTyped() {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        func failures() -> (MideaError?, [PathFailure]) {
            do { _ = try t.send(Data(), retries: 2, expect: nil); return (nil, []) } catch {
                guard case .allPathsFailed(let f)? = error as? MideaError else { XCTFail("\(error)"); return (nil, []) }
                return (error as? MideaError, f)
            }
        }
        lan.fail = true
        cloud.fail = true
        lan.error = MideaError.timeout
        cloud.error = Self.offline
        var (e, f) = failures()
        XCTAssertEqual(f.map(\.path), [.lan, .cloud])
        XCTAssertEqual(f.map(\.reason), [.timeout, .applianceOffline(nextCheck: nil)])
        XCTAssertEqual(e?.errorDescription, "Keine Verbindung zur Anlage: WLAN: antwortet nicht · Cloud: Anlage offline laut Cloud (3123)")

        clock = clock.addingTimeInterval(30)
        (e, f) = failures()
        XCTAssertEqual(f.map(\.reason), [.applianceOffline(nextCheck: "in 5 min")])
        XCTAssertTrue(f.allSatisfy(\.isApplianceOffline))

        t.resetBackoff()
        lan.error = MideaError.unreachable("Zeitüberschreitung beim Verbinden mit 192.168.1.40")
        cloud.error = MideaCloud.CloudError.api(3004, "token expired")
        (e, f) = failures()
        XCTAssertEqual(f.map(\.reason), [.unreachable, .cloud(.sessionExpired, code: 3004)])
        XCTAssertEqual(f.map(\.text), ["nicht erreichbar", "token expired (3004)"])
        XCTAssertEqual(f.compactMap(\.code), ["3004"])

        lan.error = MideaError.refused
        cloud.error = MideaCloud.CloudError.paused(until: clock)
        (e, f) = failures()
        XCTAssertEqual(f.map(\.reason), [.refused, .cloud(.paused, code: nil)])
        XCTAssertEqual(f.first?.text, NetSocket.refusedText)
        XCTAssertTrue(f.last?.text.hasSuffix("(-1021)") == true, "eigener Code bleibt im Kurzgrund")
        XCTAssertNil(f.last?.code)
    }

    /// „Nur Cloud“ im Rückzug nach 3123: derselbe typisierte Grund wie in „Automatisch“.
    func testCloudOnlyBackoffIsTypedOffline() {
        let cloud = FakeTransport(3)
        let t = AutoTransport(lan: nil, cloud: cloud, mode: .cloud)
        var clock = Date(timeIntervalSince1970: 0)
        t.now = { clock }
        cloud.fail = true
        cloud.error = Self.offline
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil))
        clock = clock.addingTimeInterval(60)
        XCTAssertThrowsError(try t.sendSingle(Data(), expect: nil)) { error in
            XCTAssertTrue(AutoTransport.isApplianceOffline(error))
            XCTAssertEqual((error as? MideaError)?.errorDescription,
                           "Keine Verbindung zur Anlage: Cloud: Anlage ausgeschaltet oder ohne Strom (laut Midea-Cloud) – nächste Prüfung in 4 min")
        }
    }

    /// Moduswechsel setzt die Sperrzeit zurück: nach „Nur Cloud“ → „Automatisch“ wird WLAN sofort wieder versucht.
    func testModeChangeResetsFailures() throws {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        t.now = { Date(timeIntervalSince1970: 0) }
        lan.fail = true
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        t.mode = .cloud
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        lan.fail = false
        t.mode = .auto
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [lan.reply])
        XCTAssertEqual(lan.sends.count, 2)
    }

    /// Fällt auch der letzte Weg aus, wird er trotzdem bei jeder Abfrage versucht (sonst gäbe es gar keinen).
    /// Für WLAN ebenso: scheitert die Cloud nicht mit „Anlage offline“, fällt die WLAN-Sperre (zwei WLAN-Versuche).
    func testLastPathIsAlwaysTried() {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .auto)
        t.now = { Date(timeIntervalSince1970: 0) }
        lan.fail = true
        cloud.fail = true
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil)) { error in
            let text = (error as? MideaError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("WLAN") && text.contains("Cloud"), "beide Wege mit Grund genannt: \(text)")
        }
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil))
        XCTAssertEqual(lan.sends, [0, 0], "WLAN-Sperre fällt, wenn die Cloud nicht an „Anlage offline“ scheitert")
        XCTAssertEqual(cloud.sends, [2, 2])
    }

    func testFixedModes() {
        let lan = FakeTransport(1), cloud = FakeTransport(3)
        let t = AutoTransport(lan: lan, cloud: cloud, mode: .cloud)
        XCTAssertEqual(try t.send(Data(), retries: 2, expect: nil), [cloud.reply])
        XCTAssertTrue(lan.sends.isEmpty)
        t.mode = .lan
        lan.fail = true
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil))
        XCTAssertEqual(lan.sends, [2])
        XCTAssertEqual(cloud.sends.count, 1, "Nur WLAN weicht nie aus")
    }

    func testWithoutCloudUsesLANRetriesAndIdleOnlyClosesLAN() {
        let lan = FakeTransport(1)
        let t = AutoTransport(lan: lan, cloud: nil, mode: .auto)
        lan.fail = true
        XCTAssertThrowsError(try t.send(Data(), retries: 2, expect: nil))
        XCTAssertEqual(lan.sends, [2])
        t.idle()
        XCTAssertEqual(lan.idles, 1)
    }

    /// Gespeicherte Bluetooth-Wege werden „Automatisch“ (WLAN → Cloud).
    func testStoredBluetoothModeLoadsAsAuto() {
        XCTAssertEqual(ConnectionMode.allCases, [.auto, .lan, .cloud])
        XCTAssertEqual(ConnectionMode(stored: "ble"), .auto)
        XCTAssertEqual(ConnectionMode(stored: "blePreferred"), .auto)
        XCTAssertEqual(ConnectionMode(stored: nil), .auto)
        XCTAssertEqual(ConnectionMode(stored: "lan"), .lan)
        XCTAssertEqual(ConnectionMode(stored: "cloud"), .cloud)
    }

    func testConfigWithoutLANAndWithoutCloudHasNoPath() throws {
        let cfg = DeviceConfig(name: "PortaSplit", ip: "", port: 6444, deviceId: 0, token: "", key: "")
        XCTAssertFalse(cfg.hasLAN)
        let dev = try PortaSplitDevice(config: cfg, mode: .auto)
        XCTAssertEqual(dev.connectionMode, .auto)
        // Alte device.json mit und ohne bleSerial bleibt lesbar (die Seriennummer braucht die Cloud).
        let old = #"{"name":"n","ip":"1.2.3.4","port":6444,"deviceId":1,"token":"11","key":"00"}"#
        let decoded = try JSONDecoder().decode(DeviceConfig.self, from: Data(old.utf8))
        XCTAssertNil(decoded.bleSerial)
        XCTAssertTrue(decoded.hasLAN)
        let withSerial = #"{"name":"n","ip":"","port":6444,"deviceId":1,"token":"","key":"","bleSerial":"00000Q1CAC1A2B"}"#
        XCTAssertEqual(try JSONDecoder().decode(DeviceConfig.self, from: Data(withSerial.utf8)).bleSerial, "00000Q1CAC1A2B")
    }
}
