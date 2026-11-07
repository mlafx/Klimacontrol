import XCTest
@testable import MideaKit

/// Brücke synchron ↔ async und sparsamere Cloud-Hilfen (ohne Netz).
final class ConcurrencyTests: XCTestCase {
    func testAwaitBlockingReturnsValue() throws {
        // Echte Unterbrechung, die erst ein anderer Thread beendet: `awaitBlocking` muss auf sie warten.
        let v = try awaitBlocking { () async throws -> Int in
            await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                DispatchQueue.global().async { c.resume(returning: 42) }
            }
        }
        XCTAssertEqual(v, 42)
    }

    func testAwaitBlockingPropagatesError() {
        XCTAssertThrowsError(try awaitBlocking { () async throws -> Int in throw MideaError.timeout }) { e in
            guard case .timeout? = e as? MideaError else { return XCTFail("falscher Fehler \(e)") }
        }
    }

    func testAwaitBlockingFromManyThreads() {
        let n = 32
        let results = Locked([Int](repeating: 0, count: n))
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let v = (try? awaitBlocking { () async throws -> Int in i * 2 }) ?? -1
            results.mutate { $0[i] = v }
        }
        XCTAssertEqual(results.value, (0..<n).map { $0 * 2 })
    }

    /// Der Zeitstempel ohne DateFormatter liefert genau dasselbe wie ein DateFormatter.
    func testStampMatchesFormatter() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        let dates = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_793_000_000.9),
                     Date(timeIntervalSince1970: 951_782_400), // 29.02.2000
                     Date(timeIntervalSince1970: 1_798_761_599), Date()]
        for d in dates {
            XCTAssertEqual(MideaCloud.stamp(d), f.string(from: d))
            XCTAssertEqual(MideaCloud.stamp(d).count, 14)
        }
    }

    /// Appliance-Liste der Cloud: Geräte-ID, Name, Typ und Online-Status; leere/ungültige IDs fallen weg.
    func testCloudApplianceListParsing() {
        let raw: [[String: Any]] = [
            ["id": "111122223333444", "name": "PortaSplit\u{0007}", "type": "0xAC", "onlineStatus": "0"],
            ["applianceCode": 42, "name": "", "type": "0000CC", "onlineStatus": 1],
            ["id": "", "name": "kaputt"],
            ["id": "abc"],
        ]
        let list = raw.compactMap(MideaCloud.parseAppliance)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0], CloudAppliance(deviceId: 111122223333444, name: "PortaSplit", type: 0xAC, online: false))
        XCTAssertTrue(list[0].isAirConditioner)
        XCTAssertEqual(list[1].deviceId, 42)
        XCTAssertEqual(list[1].name, "PortaSplit")
        XCTAssertEqual(list[1].type, 0xCC)
        XCTAssertTrue(list[1].online)

        let dev = DiscoveredDevice(cloud: list[0])
        XCTAssertTrue(dev.isCloudOnly)
        XCTAssertEqual(dev.deviceId, 111122223333444)
        XCTAssertEqual(dev.cloudOnline, false)
    }

    func testCloudTypeParsing() {
        XCTAssertEqual(MideaCloud.parseType("0xAC"), 0xAC)
        XCTAssertEqual(MideaCloud.parseType("ac"), 0xAC)
        XCTAssertEqual(MideaCloud.parseType("0000AC"), 0xAC)
        XCTAssertEqual(MideaCloud.parseType(""), 0)
        XCTAssertEqual(MideaCloud.parseType("Klima"), 0)
    }
}
