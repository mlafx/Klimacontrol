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

    // Kennungen und Lesart wie msmart-ng (`CapabilityId`, Leser in `CapabilitiesResponse._parse_capabilities`).
    // Jede Fähigkeit: nil = nicht gemeldet (unbekannt), sonst ob die Anlage sie laut Byte 0 hat.
    static let selfCleanId: UInt16 = 0x0039
    static let rateSelectId: UInt16 = 0x0048
    static let parentControlId: UInt16 = 0x0051
    static let outSilentId: UInt16 = 0x00CD
    static let ecoId: UInt16 = 0x0212
    static let freezeProtectionId: UInt16 = 0x0213
    static let swingModesId: UInt16 = 0x0215
    static let turboId: UInt16 = 0x021A
    static let anionId: UInt16 = 0x021E
    static let displayControlId: UInt16 = 0x0224
    static let soundId: UInt16 = 0x022C

    private func flag(_ id: UInt16, _ values: Set<UInt8>) -> Bool? {
        raw[id]?.first.map { values.contains($0) }
    }

    public var selfClean: Bool? { flag(Self.selfCleanId, [1]) }
    /// Stufen von „Leistung begrenzen“: 2 (Wert 1), 5 (Wert 2 oder 3), 0 = gemeldet, aber keine; nil = nicht gemeldet.
    public var rateSelectLevels: Int? {
        guard let v = raw[Self.rateSelectId]?.first else { return nil }
        return [2, 3].contains(v) ? 5 : v == 1 ? 2 : 0
    }
    public var rateSelect: Bool? { rateSelectLevels.map { $0 > 0 } }
    /// Kindersicherung; msmart-ng kennt die Kennung, liest sie aber nicht aus. Annahme: Wert 1 = vorhanden.
    public var parentControl: Bool? { flag(Self.parentControlId, [1]) }
    public var outSilent: Bool? { flag(Self.outSilentId, [1, 3]) }
    public var eco: Bool? { flag(Self.ecoId, [1, 2]) }
    public var freezeProtection: Bool? { flag(Self.freezeProtectionId, [1]) }
    public var swingVertical: Bool? { flag(Self.swingModesId, [0, 1]) }
    public var swingHorizontal: Bool? { flag(Self.swingModesId, [1, 3]) }
    public var turboCool: Bool? { flag(Self.turboId, [0, 1]) }
    public var turboHeat: Bool? { flag(Self.turboId, [1, 3]) }
    /// Ionisierer („anion“).
    public var anion: Bool? { flag(Self.anionId, [1]) }
    public var displayControl: Bool? { flag(Self.displayControlId, [1, 2, 100]) }
    public var sound: Bool? { flag(Self.soundId, [1]) }
    /// iECO überhaupt (beim Kühlen oder Heizen); nil = nicht gemeldet.
    public var iecoSupported: Bool? { reportsIECO ? (iecoCool || iecoHeat) : nil }

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
