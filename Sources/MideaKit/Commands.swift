import Foundation
import Synchronization

/// Befehlsrahmen für Klimaanlagen (Gerätetyp 0xAC), nach msmart-ng `device/AC/command.py`.
public enum OperationalMode: Int, CaseIterable, Sendable {
    case auto = 1, cool = 2, dry = 3, heat = 4, fan = 5

    /// Protokoll und Datenbank (deutsch); Anzeige über `title` im Kern (`DisplayNames.swift`).
    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .cool: return "Kühlen"
        case .dry: return "Trocknen"
        case .heat: return "Heizen"
        case .fan: return "Lüften"
        }
    }
}

public enum FanSpeed: Int, CaseIterable, Sendable {
    case silent = 20, low = 40, medium = 60, high = 80, max = 100, auto = 102

    /// Protokoll und Datenbank (deutsch); Anzeige über `title` im Kern (`DisplayNames.swift`).
    public var label: String {
        switch self {
        case .silent: return "Leise"
        case .low: return "Niedrig"
        case .medium: return "Mittel"
        case .high: return "Hoch"
        case .max: return "Max"
        case .auto: return "Auto"
        }
    }
}

public enum SwingMode: Int, Sendable {
    case off = 0, vertical = 0x0C
}

enum FrameType: UInt8 {
    case control = 0x02, query = 0x03, report = 0x04
}

enum PropertyId: UInt16, CaseIterable {
    case selfClean = 0x0039
    case rateSelect = 0x0048
    case outSilent = 0x00CD
    case ieco = 0x00E3
    case sound = 0x022C

    /// Werte kodieren wie msmart-ng `PropertyId.encode`.
    func encode(_ on: Bool, iecoNumber: UInt8 = 1) -> [UInt8] {
        switch self {
        case .outSilent: return [on ? 3 : 0]
        case .ieco: return [0, iecoNumber, on ? 1 : 0] + [UInt8](repeating: 0, count: 10)
        case .selfClean, .sound: return [on ? 1 : 0]
        case .rateSelect: return [on ? 100 : 50]
        }
    }

    func decode(_ data: [UInt8]) -> Bool? {
        switch self {
        case .outSilent: return data.first.map { $0 == 3 }
        case .ieco: return data.count >= 2 ? data[1] != 0 : nil
        case .selfClean, .sound: return data.first.map { $0 != 0 }
        case .rateSelect: return data.first.map { $0 >= 100 }
        }
    }
}

enum Frame {
    static let deviceType: UInt8 = 0xAC
    static let controlSource: UInt8 = 0x02
    /// Laufende Nachrichten-ID; mehrere Geräte-Queues bauen Rahmen gleichzeitig – darum im `Mutex`.
    private static let messageId = Mutex<UInt8>(0)

    static func nextMessageId() -> UInt8 {
        messageId.withLock { id in
            id &+= 1
            return id
        }
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        UInt8(truncatingIfNeeded: 0 &- bytes.reduce(0) { $0 &+ Int($1) })
    }

    /// Rahmen mit Nachrichten-ID, CRC8 und Prüfsumme bauen. `id` nur für Tests fest vorgeben.
    static func build(_ type: FrameType, _ payload: [UInt8], id: UInt8? = nil) -> Data {
        let mid: UInt8
        if let id { mid = id } else { mid = nextMessageId() }
        var body = payload + [mid]
        body.append(CRC8.calculate(body))
        var frame: [UInt8] = [0xAA, UInt8(body.count + 10), deviceType, 0, 0, 0, 0, 0, 0, type.rawValue]
        frame += body
        frame.append(checksum(frame.dropFirst()))
        return Data(frame)
    }

    static func getState(id: UInt8? = nil) -> Data {
        build(.query, [0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00, 0x02,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03], id: id)
    }

    static func getCapabilities(id: UInt8? = nil) -> Data {
        build(.query, [0xB5, 0x01, 0x00], id: id)
    }

    static func getGroupData(_ group: UInt8, id: UInt8? = nil) -> Data {
        var p = [UInt8](repeating: 0, count: 20)
        p[0] = 0x41; p[1] = 0x21; p[2] = 0x01; p[3] = 0x40 | group
        return build(.query, p, id: id)
    }

    static func toggleDisplay(beep: Bool, id: UInt8? = nil) -> Data {
        build(.query, [0x41, controlSource | (beep ? 0x40 : 0), 0x00, 0xFF, 0x02,
                       0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], id: id)
    }

    static func getProperties(_ props: [PropertyId], id: UInt8? = nil) -> Data {
        var p: [UInt8] = [0xB1, UInt8(props.count)]
        for prop in props { p += [UInt8(prop.rawValue & 0xFF), UInt8(prop.rawValue >> 8)] }
        return build(.query, p, id: id)
    }

    static func setProperty(_ prop: PropertyId, _ on: Bool, id: UInt8? = nil) -> Data {
        let value = prop.encode(on)
        let id16 = prop.rawValue
        return build(.control, [0xB0, 1, UInt8(id16 & 0xFF), UInt8(id16 >> 8), UInt8(value.count)] + value, id: id)
    }

    /// Leistungsbegrenzung: 100 = keine, sonst 75 oder 50 %. Die Fähigkeiten-Antwort (0xB5) nennt nur die
    /// Stufenzahl, keine Prozentwerte – darum gilt der zurückgemeldete Wert (`ACState.ratePercent`); Abweichung = Fehler.
    static func setRateSelect(_ percent: Int, id: UInt8? = nil) -> Data {
        let id16 = PropertyId.rateSelect.rawValue
        return build(.control, [0xB0, 1, UInt8(id16 & 0xFF), UInt8(id16 >> 8), 1, UInt8(percent)], id: id)
    }

    static func setOutSilent(_ on: Bool, id: UInt8? = nil) -> Data {
        setProperty(.outSilent, on, id: id)
    }

    static func setState(_ s: ACState, beep: Bool, id: UInt8? = nil) -> Data {
        // Nie abstürzen bei unsinnigen Werten (NaN, 1e300): in den Bereich der Anlage holen.
        let target = s.targetTemperature.isFinite ? min(30, max(16, s.targetTemperature)) : 24
        let integral = Int(target.rounded(.down))
        let half = target - Double(integral) > 0
        var temp: UInt8 = 0
        var tempAlt: UInt8 = 0
        if (17...30).contains(integral) {
            temp = UInt8((integral - 16) & 0xF)
        } else {
            tempAlt = UInt8((integral - 12) & 0x1F)
        }
        if half { temp |= 0x10 }
        let mode = UInt8((s.mode.rawValue & 0x7) << 5)
        // Vorhandene Timer immer mitschicken – 0x7F 0x7F 0x00 würde sie löschen.
        let timer = DeviceTimer.encode(on: s.onTimerMinutes, off: s.offTimerMinutes)
        let payload: [UInt8] = [
            0x40,
            controlSource | (beep ? 0x40 : 0) | (s.power ? 0x01 : 0),
            temp | mode,
            UInt8(s.fanSpeed & 0x7F),
            timer.0, timer.1, timer.2,
            0x30 | UInt8(s.swing.rawValue & 0x3F),
            (s.followMe ? 0x80 : 0) | (s.turbo ? 0x20 : 0),
            (s.eco ? 0x80 : 0) | (s.purifier ? 0x20 : 0),
            (s.sleep ? 0x01 : 0) | (s.turbo ? 0x02 : 0) | (s.fahrenheit ? 0x04 : 0),
            0, 0, 0, 0, 0, 0, 0,
            tempAlt,
            40,
            0x00,
            s.freezeProtection ? 0x80 : 0,
            0x00,
            0x00,
        ]
        return build(.control, payload, id: id)
    }
}

enum CRC8 {
    private static let table: [UInt8] = [
        0x00, 0x5E, 0xBC, 0xE2, 0x61, 0x3F, 0xDD, 0x83, 0xC2, 0x9C, 0x7E, 0x20, 0xA3, 0xFD, 0x1F, 0x41,
        0x9D, 0xC3, 0x21, 0x7F, 0xFC, 0xA2, 0x40, 0x1E, 0x5F, 0x01, 0xE3, 0xBD, 0x3E, 0x60, 0x82, 0xDC,
        0x23, 0x7D, 0x9F, 0xC1, 0x42, 0x1C, 0xFE, 0xA0, 0xE1, 0xBF, 0x5D, 0x03, 0x80, 0xDE, 0x3C, 0x62,
        0xBE, 0xE0, 0x02, 0x5C, 0xDF, 0x81, 0x63, 0x3D, 0x7C, 0x22, 0xC0, 0x9E, 0x1D, 0x43, 0xA1, 0xFF,
        0x46, 0x18, 0xFA, 0xA4, 0x27, 0x79, 0x9B, 0xC5, 0x84, 0xDA, 0x38, 0x66, 0xE5, 0xBB, 0x59, 0x07,
        0xDB, 0x85, 0x67, 0x39, 0xBA, 0xE4, 0x06, 0x58, 0x19, 0x47, 0xA5, 0xFB, 0x78, 0x26, 0xC4, 0x9A,
        0x65, 0x3B, 0xD9, 0x87, 0x04, 0x5A, 0xB8, 0xE6, 0xA7, 0xF9, 0x1B, 0x45, 0xC6, 0x98, 0x7A, 0x24,
        0xF8, 0xA6, 0x44, 0x1A, 0x99, 0xC7, 0x25, 0x7B, 0x3A, 0x64, 0x86, 0xD8, 0x5B, 0x05, 0xE7, 0xB9,
        0x8C, 0xD2, 0x30, 0x6E, 0xED, 0xB3, 0x51, 0x0F, 0x4E, 0x10, 0xF2, 0xAC, 0x2F, 0x71, 0x93, 0xCD,
        0x11, 0x4F, 0xAD, 0xF3, 0x70, 0x2E, 0xCC, 0x92, 0xD3, 0x8D, 0x6F, 0x31, 0xB2, 0xEC, 0x0E, 0x50,
        0xAF, 0xF1, 0x13, 0x4D, 0xCE, 0x90, 0x72, 0x2C, 0x6D, 0x33, 0xD1, 0x8F, 0x0C, 0x52, 0xB0, 0xEE,
        0x32, 0x6C, 0x8E, 0xD0, 0x53, 0x0D, 0xEF, 0xB1, 0xF0, 0xAE, 0x4C, 0x12, 0x91, 0xCF, 0x2D, 0x73,
        0xCA, 0x94, 0x76, 0x28, 0xAB, 0xF5, 0x17, 0x49, 0x08, 0x56, 0xB4, 0xEA, 0x69, 0x37, 0xD5, 0x8B,
        0x57, 0x09, 0xEB, 0xB5, 0x36, 0x68, 0x8A, 0xD4, 0x95, 0xCB, 0x29, 0x77, 0xF4, 0xAA, 0x48, 0x16,
        0xE9, 0xB7, 0x55, 0x0B, 0x88, 0xD6, 0x34, 0x6A, 0x2B, 0x75, 0x97, 0xC9, 0x4A, 0x14, 0xF6, 0xA8,
        0x74, 0x2A, 0xC8, 0x96, 0x15, 0x4B, 0xA9, 0xF7, 0xB6, 0xE8, 0x0A, 0x54, 0xD7, 0x89, 0x6B, 0x35,
    ]

    static func calculate<C: Collection>(_ data: C) -> UInt8 where C.Element == UInt8 {
        data.reduce(0) { table[Int($0 ^ $1)] }
    }
}
