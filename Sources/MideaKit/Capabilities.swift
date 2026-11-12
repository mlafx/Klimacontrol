import Foundation

/// Fähigkeiten der Anlage (Antwort 0xB5, bis zu zwei Seiten), ausgewertet wie msmart-ng `CapabilitiesResponse`.
/// Nur gelesen; die Werte steuern, welche Schalter die Oberfläche anbietet.
public struct ACCapabilities: Equatable, Sendable {
    /// Rohdaten je Fähigkeit (ID → Wert), Fähigkeiten mit Länge 0 fehlen.
    public var raw: [UInt16: [UInt8]] = [:]

    public init(raw: [UInt16: [UInt8]] = [:]) { self.raw = raw }

    static let iecoId: UInt16 = 0x00E3

    /// iECO-Fähigkeit: Byte 0 (1, 3, 8 = Kühlen; 3, 4, 8 = Heizen; 8 = „ECOMaster“), nil = nicht gemeldet.
    public var ieco: UInt8? { raw[Self.iecoId]?.first }
    /// Zweites Byte der iECO-Fähigkeit („ieco_end“: 1, 2, 8 = Kühlen; 2, 3, 8 = Heizen).
    public var iecoEnd: UInt8? {
        guard let v = raw[Self.iecoId], v.count > 1 else { return nil }
        return v[1]
    }
    /// Die Anlage meldet die iECO-Fähigkeit überhaupt.
    public var reportsIECO: Bool { raw[Self.iecoId] != nil }
    public var iecoCool: Bool { [1, 3, 8].contains(ieco ?? 0) || [1, 2, 8].contains(iecoEnd ?? 0) }
    public var iecoHeat: Bool { [3, 4, 8].contains(ieco ?? 0) || [2, 3, 8].contains(iecoEnd ?? 0) }
    /// Erstes Datenbyte des Setz-Befehls für 0x00E3 („ieco_number“ in msmart-ng): 8 bei ECOMaster, 3 bei
    /// gemeldetem „ieco_end“ 1–3, sonst 1.
    public var iecoNumber: UInt8 {
        switch iecoEnd {
        case 8: return 8
        case 1, 2, 3: return 3
        default: return 1
        }
    }

    /// Kurzfassung fürs Protokoll: je Fähigkeit „ID=Wert“ in hex, nach ID sortiert.
    public var summary: String {
        func hex<T: BinaryInteger>(_ v: T, _ width: Int) -> String {
            let s = String(v, radix: 16)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return raw.keys.sorted().map { id in
            hex(id, 4) + "=" + (raw[id] ?? []).map { hex($0, 2) }.joined()
        }.joined(separator: " ")
    }

    mutating func merge(_ other: ACCapabilities) {
        raw.merge(other.raw) { $1 }
    }

    /// Eine Seite zerlegen: Nutzdaten ab 0xB5 (ohne CRC und Prüfsumme). `more`: Die Anlage hat eine weitere Seite.
    static func parsePage(_ p: [UInt8]) -> (capabilities: ACCapabilities, more: Bool) {
        var caps = ACCapabilities()
        guard p.count >= 2, p[0] == 0xB5 else { return (caps, false) }
        let count = Int(p[1])
        var i = 2
        for _ in 0..<count {
            guard p.count - i >= 3 else { break }
            let size = Int(p[i + 2])
            if size == 0 { i += 3; continue }
            let id = UInt16(p[i]) | UInt16(p[i + 1]) << 8
            let end = i + 3 + size
            guard end <= p.count else { break }
            caps.raw[id] = Array(p[(i + 3)..<end])
            i = end
        }
        // Wie msmart-ng: Bleiben mehr als ein Byte übrig, sagt das vorletzte, ob eine weitere Seite folgt.
        let rest = p.count - i
        let more = rest > 1 && p[p.count - 2] != 0
        return (caps, more)
    }
}
