import Foundation

/// Zustand der Anlage, so wie sie ihn meldet (Antwort 0xC0) plus Zusatzwerte.
public struct ACState: Equatable, Sendable {
    public var power = false
    public var mode: OperationalMode = .cool
    public var targetTemperature = 22.0
    public var fanSpeed = FanSpeed.auto.rawValue
    public var swing: SwingMode = .off
    public var eco = false
    public var turbo = false
    public var sleep = false
    public var fahrenheit = false
    public var followMe = false
    public var purifier = false
    public var freezeProtection = false
    public var displayOn = true
    public var filterAlert = false
    public var indoorTemperature: Double?
    public var outdoorTemperature: Double?
    public var errorCode = 0
    /// Außengerät leise (Klimacontrol, Eigenschaft 0x00CD); nil = nicht gelesen.
    public var outSilent: Bool?
    /// Selbstreinigung läuft (Eigenschaft 0x0039).
    public var selfClean: Bool?
    /// iECO, Sparprogramm der Anlage (Eigenschaft 0x00E3).
    public var ieco: Bool?
    /// Einschalt-/Ausschalt-Timer in Minuten ab jetzt (Restlaufzeit laut Anlage); nil = kein Timer.
    public var onTimerMinutes: Int?
    public var offTimerMinutes: Int?
    /// Leistungsbegrenzung in Prozent (100 = keine; Eigenschaft 0x0048).
    public var ratePercent: Int?
    /// Signalton der Anlage (Eigenschaft 0x022C).
    public var sound: Bool?
    /// Aktuelle Leistungsaufnahme in Watt; nil = unbekannt.
    public var powerWatts: Double?
    /// Gesamtverbrauch in kWh; nil = unbekannt.
    public var totalEnergyKWh: Double?

    public init() {}

    /// Protokoll und Datenbank (deutsch); Anzeige über `fanTitle` im Kern (`DisplayNames.swift`).
    public var fanLabel: String {
        FanSpeed(rawValue: fanSpeed)?.label ?? "\(fanSpeed) %"
    }
}

enum Response {
    case state(ACState)
    case properties([PropertyId: Bool], raw: [PropertyId: [UInt8]])
    case energy(powerWatts: Double?, totalKWh: Double?)
    case other(UInt8)

    /// Rahmen prüfen (Prüfsumme, Gerätetyp) und nach Antwort-ID zerlegen.
    static func parse(_ frame: Data) throws -> Response {
        let f = [UInt8](frame)
        guard f.count >= 12 else { throw MideaError.invalidResponse("Rahmen zu kurz") }
        guard Frame.checksum(f[1..<(f.count - 1)]) == f[f.count - 1] else {
            throw MideaError.invalidResponse("Prüfsumme falsch")
        }
        guard f[2] == Frame.deviceType else { throw MideaError.invalidResponse("Gerätetyp 0x\(String(f[2], radix: 16))") }
        // Kopf 10 Byte + mindestens 1 Byte Nutzdaten + Nachrichten-ID/CRC + Prüfsumme. Ein Rahmen mit genau 12 Byte
        // (auch über die Cloud erreichbar) hat keine Nutzdaten.
        guard f.count >= 13 else { throw MideaError.invalidResponse("Rahmen ohne Nutzdaten") }
        let payload = Array(f[10..<(f.count - 2)])
        guard let kind = payload.first else { throw MideaError.invalidResponse("Rahmen ohne Nutzdaten") }
        switch kind {
        case 0xC0 where payload.count >= 17:
            return .state(parseState(payload))
        case 0xB0, 0xB1:
            return .properties(parseProperties(payload), raw: parsePropertyBytes(payload))
        case 0xC1 where payload.count > 19 && (f[13] & 0xF) == 4:
            return parseEnergy(payload)
        default:
            return .other(kind)
        }
    }

    /// Außentemperatur, die die PortaSplit bei ausgeschalteter Anlage statt eines Messwerts meldet.
    static let standbyPlaceholder = 10.0

    static func parseState(_ p: [UInt8]) -> ACState {
        var s = ACState()
        s.power = p[1] & 0x1 != 0
        s.targetTemperature = Double(p[2] & 0xF) + 16 + (p[2] & 0x10 != 0 ? 0.5 : 0)
        s.mode = OperationalMode(rawValue: Int(p[2] >> 5) & 0x7) ?? .auto
        s.fanSpeed = Int(p[3] & 0x7F)
        (s.onTimerMinutes, s.offTimerMinutes) = DeviceTimer.decode(p[4], p[5], p[6])
        s.swing = SwingMode(rawValue: Int(p[7] & 0xF)) ?? .off
        s.turbo = p[8] & 0x20 != 0 || p[10] & 0x2 != 0
        s.followMe = p[8] & 0x80 != 0
        s.eco = p[9] & 0x10 != 0
        s.purifier = p[9] & 0x20 != 0
        s.sleep = p[10] & 0x1 != 0
        s.fahrenheit = p[10] & 0x4 != 0
        s.indoorTemperature = temperature(p[11], decimals: Double(p[15] & 0xF) / 10, fahrenheit: s.fahrenheit)
        s.outdoorTemperature = temperature(p[12], decimals: Double(p[15] >> 4) / 10, fahrenheit: s.fahrenheit)
        // Ausgeschaltet schläft das Außengerät der PortaSplit; sie meldet dann immer genau 10,0 °C – also „unbekannt“.
        if !s.power, s.outdoorTemperature == standbyPlaceholder { s.outdoorTemperature = nil }
        let alt = p[13] & 0x1F
        if alt != 0 {
            s.targetTemperature = Double(alt) + 12 + (p[2] & 0x10 != 0 ? 0.5 : 0)
        }
        s.filterAlert = p[13] & 0x20 != 0
        s.displayOn = p[14] != 0x70
        s.errorCode = Int(p[16])
        if p.count >= 22 { s.freezeProtection = p[21] & 0x80 != 0 }
        return s
    }

    static func temperature(_ raw: UInt8, decimals: Double, fahrenheit: Bool) -> Double? {
        if raw == 0xFF { return nil }
        let t = (Double(raw) - 50) / 2
        let whole = Double(Int(t))
        if !fahrenheit && decimals != 0 {
            return whole + (t >= 0 ? decimals : -decimals)
        }
        if decimals >= 0.5 { return whole + (t >= 0 ? 0.5 : -0.5) }
        return t
    }

    /// Eigenschaften-Antwort (0xB0/0xB1): je Eintrag ID (2 Byte LE), Ergebnis, Länge, Daten.
    static func parseProperties(_ p: [UInt8]) -> [PropertyId: Bool] {
        var out: [PropertyId: Bool] = [:]
        for (prop, data) in parsePropertyBytes(p) {
            if let v = prop.decode(data) { out[prop] = v }
        }
        return out
    }

    static func parsePropertyBytes(_ p: [UInt8]) -> [PropertyId: [UInt8]] {
        var out: [PropertyId: [UInt8]] = [:]
        guard p.count >= 2 else { return out }
        var i = 2
        for _ in 0..<Int(p[1]) {
            guard i + 4 <= p.count else { break }
            let id = UInt16(p[i]) | UInt16(p[i + 1]) << 8
            let size = Int(p[i + 3])
            let end = min(p.count, i + 4 + size)
            if size > 0, p[i + 2] & 0x10 == 0, let prop = PropertyId(rawValue: id), i + 4 < end {
                out[prop] = Array(p[(i + 4)..<end])
            }
            i += 4 + size
        }
        return out
    }

    static func parseOutSilent(_ p: [UInt8]) -> Bool? {
        parseProperties(p)[.outSilent]
    }

    /// Gruppe 4: Verbrauch. Die PortaSplit zählt **binär**, nicht BCD (msmart-ng `energy_bcd: false`; gegen
    /// Leistung × Zeit nachgemessen): Byte 4–7 = Gesamtzähler, Byte 12–15 = laufender Betrieb, 1 Schritt = 0,01 kWh;
    /// Byte 16–18 = Leistung / 10 W. Zählerstand 0 oder 0xFFFFFFFF gilt als unbekannt, nie als 0 kWh.
    static func parseEnergy(_ p: [UInt8]) -> Response {
        let raw = counter(p, at: 4)
        let run = counter(p, at: 12)
        let power = Double(Int(p[16]) << 16 | Int(p[17]) << 8 | Int(p[18])) / 10
        let valid = raw != 0 || run != 0 || power != 0
        let totalKnown = raw != 0 && raw != 0xFFFF_FFFF
        return .energy(powerWatts: valid ? (power * 10).rounded() / 10 : nil,
                       totalKWh: valid && totalKnown ? Double(raw) / 100 : nil)
    }

    /// 32-Bit-Zähler, höchstwertiges Byte zuerst (Gruppe 4). Vorher Länge prüfen (`p.count >= i + 4`).
    static func counter(_ p: [UInt8], at i: Int) -> Int {
        Int(p[i]) << 24 | Int(p[i + 1]) << 16 | Int(p[i + 2]) << 8 | Int(p[i + 3])
    }

    /// Zählerschritt in kWh (siehe `parseEnergy`).
    public static let energyCounterStepKWh = 0.01
}

/// Gerätetimer in den Zustandsbytes 4–6 (wie midea-beautiful-air):
/// Byte 4/5 = 0x80 aktiv | Stunden << 2 | Viertelstunden, Byte 6 = Restminuten Ein (hoch) / Aus (niedrig).
/// Nicht `Timer` nennen – das verdeckt `Foundation.Timer` im ganzen Modul.
enum DeviceTimer {
    static let maxMinutes = 24 * 60

    /// Werte über 24 h (z. B. 0xFF = 31 h 45 min + Rest) kann die Anlage nicht stellen: als „kein Timer“ lesen,
    /// sonst schickt `setState` sie bei jedem Befehl gekappt auf 24 h zurück und stellt so einen Timer neu.
    static func decode(_ on: UInt8, _ off: UInt8, _ rest: UInt8) -> (Int?, Int?) {
        func minutes(_ b: UInt8, _ r: UInt8) -> Int? {
            guard b & 0x80 != 0 else { return nil }
            let m = Int((b & 0x7C) >> 2) * 60 + Int(b & 0x3) * 15 + Int(r)
            return (1...maxMinutes).contains(m) ? m : nil
        }
        return (minutes(on, rest >> 4), minutes(off, rest & 0xF))
    }

    static func encode(on: Int?, off: Int?) -> (UInt8, UInt8, UInt8) {
        func parts(_ m: Int?) -> (UInt8, UInt8) {
            guard let m, m > 0 else { return (0x7F, 0) }
            let total = min(m, maxMinutes)
            let hours = UInt8(min(31, total / 60))
            let quarters = UInt8((total % 60) / 15)
            return (0x80 | hours << 2 | quarters, UInt8(total % 15))
        }
        let (onByte, onRest) = parts(on)
        let (offByte, offRest) = parts(off)
        return (onByte, offByte, onRest << 4 | offRest)
    }
}
