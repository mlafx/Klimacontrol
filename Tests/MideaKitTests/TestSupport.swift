import Foundation
import Synchronization
import XCTest
@testable import MideaKit

// Gemeinsame Hilfen der MideaKit-Tests: Testvektoren, Mutex-Fächer, Testuhr, Rahmen-Bauer, nachgebildeter Weg.

/// `vectors.json` neben dieser Datei (über `#filePath`, nicht als Ressource – siehe `exclude` in Package.swift).
enum TestVectors {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("vectors.json")

    static func data() throws -> Data { try Data(contentsOf: url) }

    static func json() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data()) as? [String: Any])
    }

    /// Ein Hex-Vektor auf oberster Ebene (z. B. `discovery`) als Bytes.
    static func hex(_ name: String) throws -> Data {
        try XCTUnwrap(Data(hex: try XCTUnwrap(try json()[name] as? String)))
    }
}

/// Wert, der von mehreren Threads gelesen und geändert wird (Rückrufe, `concurrentPerform`).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func mutate(_ body: (inout Value) -> Void) { mutex.withLock { body(&$0) } }
}

/// Von Hand vorgerückte Uhr für Zeitabläufe ohne echtes Warten.
final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ s: TimeInterval) { time.withLock { $0 += s } }
}

enum TestFrames {
    /// Rahmen ohne Prüfsumme: 0xAA, Längenbyte, Gerätetyp 0xAC, Nachrichtentyp (Byte 9), Antwort-ID (Byte 10);
    /// alle übrigen Bytes `fill`.
    static func bare(type: UInt8, id: UInt8, count: Int = 11, length: UInt8 = 0x0B, fill: UInt8 = 0) -> [UInt8] {
        var f = [UInt8](repeating: fill, count: count)
        f[0] = 0xAA; f[1] = length; f[2] = 0xAC; f[9] = type; f[10] = id
        return f
    }

    /// Steuerrahmen (Nachrichtentyp 0x02) bzw. Abfrage (0x03).
    static let control = Data(bare(type: 0x02, id: 0x40))
    static let query = Data(bare(type: 0x03, id: 0x41))
}

/// Nachgebildeter Weg (WLAN oder Cloud): antwortet mit `[0xAA, tag]` oder wirft `error`, zählt Aufrufe.
final class FakeTransport: FrameTransport {
    var quietErrors = false
    var fail = false
    /// Fehler, den `send` bei `fail` wirft (Standard: WLAN-Verbindungsfehler; auch `CloudError.api(3123, …)` möglich).
    var error: (any Error)?
    var sends: [Int] = []   // übergebene retries
    var disconnects = 0, idles = 0
    /// Der Rahmen ging hinaus, bevor der Fehler kam (wie `LANClient` nach dem Schreiben).
    var failedAfterWrite = false
    let reply: Data
    init(_ tag: UInt8) { reply = Data([0xAA, tag]) }
    func send(_ frame: Data, retries: Int, expect: UInt8?) throws -> [Data] {
        sends.append(retries)
        if fail { throw error ?? MideaError.connectionFailed("weg") }
        return [reply]
    }
    func idle() { idles += 1 }
    func disconnect() { disconnects += 1 }
}
