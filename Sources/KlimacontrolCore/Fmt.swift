import Foundation
import MideaKit

/// Zahlen und Kurztexte – in allen Oberflächen gleich; Trennzeichen und Uhrzeit folgen dem `FormatProfile`.
public enum Fmt {
    /// Locale des aktuellen Profils (nur noch für Eingabefelder der Mac-Oberfläche).
    public static var locale: Locale { FormatProfile.current.locale }

    private static let neutral = Locale(identifier: "en_US")

    /// Gruppen zu je drei Stellen; Sonderfälle wie die indische Gruppierung sind bewusst nicht abgebildet.
    public static func num(_ v: Double, _ digits: Int, profile: FormatProfile = .current) -> String {
        let text = v.formatted(.number.precision(.fractionLength(digits)).locale(neutral))
        var out = ""
        for ch in text {
            switch ch {
            case ",": out += profile.groupingSeparator
            case ".": out += profile.decimalSeparator
            default: out.append(ch)
            }
        }
        return out
    }

    public static func temp(_ v: Double?, profile: FormatProfile = .current) -> String {
        v.map { num($0, 1, profile: profile) + "°" } ?? "–"
    }

    /// Solltemperatur: nur ganze Grad.
    public static func target(_ v: Double, profile: FormatProfile = .current) -> String {
        num(v.rounded(), 0, profile: profile) + "°"
    }

    public static func watts(_ v: Double?, profile: FormatProfile = .current) -> String {
        v.map { num($0, 0, profile: profile) + " W" } ?? "–"
    }

    public static func kwh(_ v: Double?, profile: FormatProfile = .current) -> String {
        v.map { num($0, 2, profile: profile) + " kWh" } ?? "–"
    }

    /// Betrag mit nachgestellter Währung: "0,30 €", "0.30 CHF"; nil → "–".
    public static func money(_ v: Double?, currency: String, profile: FormatProfile = .current) -> String {
        v.map { num($0, 2, profile: profile) + " " + currency } ?? "–"
    }

    public static func euro(_ v: Double?, profile: FormatProfile = .current) -> String {
        money(v, currency: "€", profile: profile)
    }

    /// Uhrzeit: 24 h "14:32"; 12 h "2:32 PM", "12:05 AM" (Stunde ohne führende Null).
    public static func clock(_ d: Date, calendar: Calendar = .current, profile: FormatProfile = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0
        let minutes = pad(c.minute ?? 0)
        if profile.uses24HourClock { return pad(h) + ":" + minutes }
        let symbol = h < 12 ? profile.amSymbol : profile.pmSymbol
        let fallback = h < 12 ? "AM" : "PM"
        return "\(h % 12 == 0 ? 12 : h % 12):\(minutes) \(symbol.isEmpty ? fallback : symbol)"
    }

    /// Tag und Monat nach `dayMonthPattern`: "03.11.", "11/03".
    public static func dayMonth(_ d: Date, calendar: Calendar = .current, profile: FormatProfile = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: d)
        let chars = Array(profile.dayMonthPattern)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" {
                i += 1
                while i < chars.count, chars[i] != "'" {
                    out.append(chars[i])
                    i += 1
                }
                i += 1
            } else if ch == "d" || ch == "M" || ch == "L" {
                var run = 0
                while i < chars.count, chars[i] == ch {
                    run += 1
                    i += 1
                }
                let value = ch == "d" ? (c.day ?? 0) : (c.month ?? 0)
                out += run == 1 ? "\(value)" : pad(value)
            } else {
                out.append(ch)
                i += 1
            }
        }
        return out
    }

    /// „Stand 14:32“ bzw. „Stand 03.11., 14:32“ (nicht von heute) – für Werte, die nicht mehr live sind.
    public static func stand(_ d: Date, now: Date = Date(), calendar: Calendar = .current,
                             profile: FormatProfile = .current) -> String {
        let time = clock(d, calendar: calendar, profile: profile)
        guard !calendar.isDate(d, inSameDayAs: now) else { return L.Common.asOf(time: time) }
        return L.Common.asOfDay(date: dayMonth(d, calendar: calendar, profile: profile), time: time)
    }

    private static func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// Was sich zwischen zwei Zuständen geändert hat, fürs Protokoll, immer deutsch mit deutschem Zahlenformat („ein, Modus Kühlen, Soll 22°“).
    public static func change(from a: ACState, to b: ACState) -> String {
        func onOff(_ v: Bool) -> String { v ? "an" : "aus" }
        var parts: [String] = []
        if a.power != b.power { parts.append(b.power ? "ein" : "aus") }
        if a.mode != b.mode { parts.append("Modus \(b.mode.label)") }
        if a.targetTemperature != b.targetTemperature { parts.append("Soll \(target(b.targetTemperature, profile: .germany))") }
        if a.fanSpeed != b.fanSpeed { parts.append("Lüfter \(b.fanLabel)") }
        if a.swing != b.swing { parts.append("Schwenken \(onOff(b.swing == .vertical))") }
        if a.eco != b.eco { parts.append("Eco \(onOff(b.eco))") }
        if a.turbo != b.turbo { parts.append("Turbo \(onOff(b.turbo))") }
        if a.purifier != b.purifier { parts.append("Ionisierer \(onOff(b.purifier))") }
        if a.freezeProtection != b.freezeProtection { parts.append("Frostschutz \(onOff(b.freezeProtection))") }
        return parts.joined(separator: ", ")
    }

    /// Eine Zeile Zustand fürs Ausführliches Protokoll.
    public static func stateLine(_ s: ACState) -> String {
        "\(s.power ? "ein" : "aus"), \(s.mode.label), Soll \(target(s.targetTemperature, profile: .germany)), "
            + "innen \(temp(s.indoorTemperature, profile: .germany)), "
            + "außen \(temp(s.outdoorTemperature, profile: .germany)), Lüfter \(s.fanLabel), "
            + "\(watts(s.powerWatts, profile: .germany)), "
            + "Begrenzung \(s.ratePercent.map { "\($0) %" } ?? "–")"
    }

    /// Eine Zeile Diagnose fürs Ausführliches Protokoll (-1 bzw. nan = nicht geliefert).
    public static func diagnosticsLine(_ d: Diagnostics) -> String {
        "Verdichter \(d.compressorHz ?? -1)/\(d.compressorTargetHz ?? -1) Hz, \(d.compressorPowerW ?? -1) W, "
            + "\(d.currentA ?? -1) A, \(d.voltageV ?? -1) V, T1–T4 \(d.t1IndoorAir ?? .nan)/\(d.t2IndoorCoil ?? .nan)/"
            + "\(d.t3OutdoorCoil ?? .nan)/\(d.t4OutdoorAir ?? .nan), TP \(d.tpDischarge ?? -1), EEV \(d.eevOpening ?? -1), "
            + "Lüfter \(d.indoorFanRpm ?? -1)/\(d.outdoorFanRpm ?? -1) U/min"
    }
}

/// Meldung für Menschen nach dem Muster „Was ist passiert. Was tun.“ und dem Code klein in Klammern am Ende.
/// Eine Zuordnung für beide Oberflächen; Fachwörter (Handshake, Hex, JSON) und Rohtexte bleiben im Protokoll
/// (`detail`).
public struct UserMessage: Equatable, Sendable {
    public var what: String
    public var todo: String
    /// Fehlercode (z. B. „3123“), nil ohne Code.
    public var code: String?
    /// Rohtext für Protokoll oder Tooltip (nicht für den Haupttext).
    public var detail: String?

    public init(what: String, todo: String, code: String? = nil, detail: String? = nil) {
        self.what = what
        self.todo = todo
        self.code = code
        self.detail = detail
    }

    /// Ganzer Satz für Banner und Hinweise.
    public var text: String {
        let main = todo.isEmpty ? what : what + " " + todo
        return code.map { main + " (\($0))" } ?? main
    }

    /// Cloud-Hinweis „Anlage ausgeschaltet oder ohne Strom“ – ein Zustand der Anlage, kein Fehler der App.
    public static func isDeviceOff(_ error: any Error) -> Bool {
        if let c = error as? MideaCloud.CloudError { return c.kind == .applianceOffline }
        guard case .allPathsFailed(let failures)? = error as? MideaError else { return false }
        return failures.contains(where: \.isApplianceOffline)
    }

    public static func from(_ error: any Error) -> UserMessage {
        if isDeviceOff(error) { return deviceOff(detail: error.localizedDescription) }
        if let e = error as? MideaError { return from(e) }
        if let e = error as? MideaCloud.CloudError { return from(e) }
        if let e = error as? ConfigError { return from(e) }
        return UserMessage(what: error.localizedDescription, todo: "")
    }

    static func deviceOff(detail: String?) -> UserMessage {
        UserMessage(what: "Die Anlage ist ausgeschaltet oder ohne Strom (laut Midea-Cloud).",
                    todo: "Klimacontrol prüft regelmäßig weiter.", code: "3123", detail: detail)
    }

    static func from(_ e: MideaError) -> UserMessage {
        let raw = e.errorDescription
        if isDeviceOff(e) { return deviceOff(detail: raw) }
        switch e {
        case .timeout:
            return UserMessage(what: "Die Anlage antwortet nicht.",
                               todo: "Prüfe, ob sie Strom hat und im WLAN ist. Klimacontrol versucht es weiter.", detail: raw)
        case .outcomeUnknown:
            return UserMessage(what: "Die Verbindung brach nach dem Senden ab – ob die Änderung angekommen ist, ist unklar.",
                               todo: "Prüfe die Anzeige nach der nächsten Abfrage.", detail: raw)
        case .busy:
            return UserMessage(what: "Die Anlage ist gerade belegt.",
                               todo: "Schließe andere Apps (Midea-App, zweites Klimacontrol mit offener Diagnose) oder warte 10 s.",
                               detail: raw)
        case .connectionFailed, .refused, .unreachable, .allPathsFailed:
            var code: String?
            if case .allPathsFailed(let failures) = e { code = failures.compactMap(\.code).last }
            return UserMessage(what: "Keine Verbindung zur Anlage.",
                               todo: "Prüfe WLAN und Strom der Anlage. Klimacontrol versucht es weiter.",
                               code: code, detail: raw)
        case .authenticationFailed:
            return UserMessage(what: "Die Anmeldung an der Anlage ist fehlgeschlagen.",
                               todo: "Token und Schlüssel passen nicht mehr. Lies eine Sicherung ein oder richte die Anlage neu ein.",
                               detail: raw)
        case .crypto(let c):
            return UserMessage(what: "Die Antwort der Anlage ließ sich nicht entschlüsseln.",
                               todo: "Versuche es noch einmal.", code: String(c), detail: raw)
        case .protocolError, .invalidResponse:
            return UserMessage(what: "Die Anlage hat unerwartet geantwortet.", todo: "Versuche es noch einmal.", detail: raw)
        case .commandNotApplied:
            return UserMessage(what: "Die Anlage hat die Änderung nicht übernommen.",
                               todo: "Vielleicht steuert gerade eine andere App. Versuche es noch einmal.", detail: raw)
        }
    }

    static func from(_ e: MideaCloud.CloudError) -> UserMessage {
        // Text und Code liefert MideaKit (Muster „Was ist passiert. Was tun.“, eigene Fehlerarten ohne Klammer).
        UserMessage(what: e.what, todo: e.todo, code: e.codeText, detail: e.errorDescription)
    }

    static func from(_ e: ConfigError) -> UserMessage {
        let raw = e.errorDescription
        switch e {
        case .noDevice:
            return UserMessage(what: "Die Datei enthält keine Anlage.", todo: "Wähle eine Klimacontrol-Sicherung.", detail: raw)
        case .unsupportedVersion(let v):
            return UserMessage(what: "Diese Anlage wird nicht unterstützt.", todo: "Klimacontrol kann nur Anlagen mit Protokoll V3.",
                               code: "V\(v)", detail: raw)
        case .invalidHex:
            return UserMessage(what: "Token oder Schlüssel sind unvollständig.",
                               todo: "Token hat 128, Schlüssel 64 Zeichen (0–9, a–f).", detail: raw)
        case .invalidAddress:
            return UserMessage(what: "Die Adresse der Anlage ist ungültig.", todo: "Gib sie wie 192.168.1.20 an.", detail: raw)
        }
    }

}
