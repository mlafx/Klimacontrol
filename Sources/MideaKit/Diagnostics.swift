import Foundation

/// Diagnosewerte aus den Gruppenabfragen (0xC1). Zuordnung nach msmart-ng; EEV aus Gruppe 3 Byte 11
/// (eigene Analyse, Wert mit Servicemenü-Anzeige abgeglichen). nil = nicht gemeldet.
public struct Diagnostics: Equatable, Sendable {
    // Gruppe 1 – Außeneinheit / Verdichter
    public var compressorHz: Int?
    public var compressorTargetHz: Int?
    public var currentA: Int?
    public var voltageV: Int?
    public var t1IndoorAir: Double?
    public var t2IndoorCoil: Double?
    /// Zweiter Innenfühler aus 0x00E0 (1/100 °C). Misst meist wie T1, kann aber abweichen.
    public var indoorTemp2: Double?
    public var t3OutdoorCoil: Double?
    public var t4OutdoorAir: Double?

    /// Bei ausgeschalteter Anlage ist T4 (Außenluft) nur der Platzhalter 10,0 °C – dann verwerfen.
    public mutating func dropStandbyPlaceholders(power: Bool) {
        if !power, t4OutdoorAir == Response.standbyPlaceholder { t4OutdoorAir = nil }
    }
    public var tpDischarge: Int?
    // Gruppe 2 – Innengerät
    public var indoorFanRpm: Int?
    public var indoorFanTargetRpm: Int?
    public var condensatePump: Bool?
    // Gruppe 3
    public var eevOpening: Int?
    // Gruppe 5
    public var outdoorFanRpm: Int?
    public var defrost: Bool?
    public var humidity: Int?
    // Gruppe 7 – Leistungsaufnahme
    public var compressorPowerW: Int?
    // Gruppe 4 – Verbrauch des laufenden Betriebs
    public var currentRunKWh: Double?
    /// Rohzählerstand (Gruppe 4, Byte 4–7, binär; 1 Schritt = 0,01 kWh, siehe `Response.parseEnergy`).
    public var energyCounterRaw: Int? {
        guard let p = raw[4], p.count >= 8 else { return nil }
        return Int(p[4]) << 24 | Int(p[5]) << 16 | Int(p[6]) << 8 | Int(p[7])
    }
    /// Rohdaten aller Gruppen (für Analyse/Export).
    public var raw: [UInt8: [UInt8]] = [:]

    public init() {}

    public mutating func apply(group: UInt8, payload p: [UInt8]) {
        raw[group] = p
        guard p.count >= 15 else { return }
        switch group {
        case 1:
            compressorHz = Int(p[4]); compressorTargetHz = Int(p[5])
            currentA = Int(p[7]); voltageV = Int(p[8])
            t1IndoorAir = (Double(p[10]) - 30) / 2
            t2IndoorCoil = (Double(p[11]) - 30) / 2
            t3OutdoorCoil = (Double(p[12]) - 50) / 2
            t4OutdoorAir = (Double(p[13]) - 50) / 2
            tpDischarge = Int(p[14])
        case 2:
            indoorFanTargetRpm = Int(p[4]) * 8; indoorFanRpm = Int(p[5]) * 8
            condensatePump = p[8] & 0x10 != 0
        case 3:
            eevOpening = Int(p[11])
        case 4:
            // Binär wie der Gesamtzähler (die PortaSplit zählt nicht BCD).
            if p.count >= 16 {
                currentRunKWh = Double(Response.counter(p, at: 12)) / 100 // 0,01 kWh je Schritt
            }
        case 5:
            humidity = p[4] != 0 ? Int(p[4]) : nil
            outdoorFanRpm = Int(p[8]) * 8
            defrost = p[10] != 0
        case 7:
            compressorPowerW = Int(p[10]) + 256 * Int(p[11])
        default:
            break
        }
    }

    public static let groups: [UInt8] = [1, 2, 3, 4, 5, 7]
}

extension PortaSplitDevice {
    /// `full == false` lässt die Zusatzabfrage des zweiten Innenfühlers (0x00E0) weg – die braucht nur die
    /// sichtbare Diagnosetafel, nicht der Verlauf (spart einen Round-Trip je Abfrage).
    public func diagnostics(full: Bool = true) async throws -> Diagnostics {
        var d = Diagnostics()
        for (g, frame) in try await rawGroups(Diagnostics.groups) {
            d.apply(group: g, payload: Array(frame.dropFirst(10).dropLast(2)))
        }
        // Zweiter Innenfühler aus 0x00E0: Zähler-Byte, dann 6 Temperaturen als 16-Bit-LE in 1/100 °C;
        // Wert 2 ist der zweite Innenfühler (Wert 1 = T1, Wert 3 = T2, …).
        if full, let e0 = try? await propertyData(0x00E0), e0.count >= 5 {
            let v = Int(e0[3]) | Int(e0[4]) << 8
            if v > 0, v < 12000 { d.indoorTemp2 = Double(v) / 100 }
        }
        return d
    }

    /// Rohdaten einer einzelnen Eigenschaft (0xB1), ab dem ersten Datenbyte (ohne Kopf/Prüfsumme).
    func propertyData(_ id: UInt16) async throws -> [UInt8] {
        let lo = UInt8(id & 0xFF), hi = UInt8(id >> 8)
        for f in try await query([0xB1, 1, lo, hi]) {
            let b = [UInt8](f.dropFirst(10).dropLast(2))
            if b.count > 6, b[0] == 0xB1, b[2] == lo, b[3] == hi {
                let size = Int(b[5]); return Array(b[6..<min(b.count, 6 + size)]) // b.count > 6 geprüft
            }
        }
        return []
    }
}
