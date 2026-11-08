import Foundation
import MideaKit

/// Zahlen und Kurztexte – in allen Oberflächen gleich; Trennzeichen und Uhrzeit folgen dem `FormatProfile`.
public enum Fmt {
    /// Locale des aktuellen Profils (nur noch für Eingabefelder der Mac-Oberfläche).
    public static var locale: Locale { FormatProfile.current.locale }

    private static let neutral = Locale(identifier: "en_US")

    /// Gruppen zu je drei Stellen; Sonderfälle wie die indische Gruppierung sind bewusst nicht abgebildet.
    public static func num(_ v: Double, _ digits: Int, profile: FormatProfile = .current) -> String {
        let text = v.formatted(.number.rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(digits)).locale(neutral))
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

    /// Was sich zwischen zwei Zuständen geändert hat, fürs Protokoll in der Sprache der Oberfläche mit deutschem Zahlenformat („ein, Modus Kühlen, Soll 22°“).
    public static func change(from a: ACState, to b: ACState) -> String {
        func onOff(_ v: Bool) -> String { v ? L.Log.Common.on : L.Log.Common.off }
        var parts: [String] = []
        if a.power != b.power { parts.append(b.power ? L.Log.Change.on : L.Log.Change.off) }
        if a.mode != b.mode { parts.append(L.Log.Change.mode(value: b.mode.title)) }
        if a.targetTemperature != b.targetTemperature { parts.append(L.Log.Change.target(value: target(b.targetTemperature, profile: .germany))) }
        if a.fanSpeed != b.fanSpeed { parts.append(L.Log.Change.fan(value: b.fanTitle)) }
        if a.swing != b.swing { parts.append(L.Log.Change.swing(state: onOff(b.swing == .vertical))) }
        if a.eco != b.eco { parts.append(L.Log.Change.eco(state: onOff(b.eco))) }
        if a.turbo != b.turbo { parts.append(L.Log.Change.turbo(state: onOff(b.turbo))) }
        if a.purifier != b.purifier { parts.append(L.Log.Change.purifier(state: onOff(b.purifier))) }
        if a.freezeProtection != b.freezeProtection { parts.append(L.Log.Change.freeze(state: onOff(b.freezeProtection))) }
        return parts.joined(separator: ", ")
    }

    /// Eine Zeile Zustand fürs Ausführliches Protokoll.
    public static func stateLine(_ s: ACState) -> String {
        L.Log.StateLine.line(
            power: s.power ? L.Log.Change.on : L.Log.Change.off, mode: s.mode.title,
            target: target(s.targetTemperature, profile: .germany), indoor: temp(s.indoorTemperature, profile: .germany),
            outdoor: temp(s.outdoorTemperature, profile: .germany), fan: s.fanTitle,
            watts: watts(s.powerWatts, profile: .germany), rate: s.ratePercent.map { "\($0) %" } ?? "–")
    }

    /// Eine Zeile Diagnose fürs Ausführliches Protokoll (-1 bzw. nan = nicht geliefert).
    public static func diagnosticsLine(_ d: Diagnostics) -> String {
        L.Log.StateLine.diagnostics(
            hz: "\(d.compressorHz ?? -1)", targetHz: "\(d.compressorTargetHz ?? -1)", watts: "\(d.compressorPowerW ?? -1)",
            amps: "\(d.currentA ?? -1)", volts: "\(d.voltageV ?? -1)", t1: "\(d.t1IndoorAir ?? .nan)", t2: "\(d.t2IndoorCoil ?? .nan)",
            t3: "\(d.t3OutdoorCoil ?? .nan)", t4: "\(d.t4OutdoorAir ?? .nan)", tp: "\(d.tpDischarge ?? -1)",
            eev: "\(d.eevOpening ?? -1)", indoorFan: "\(d.indoorFanRpm ?? -1)", outdoorFan: "\(d.outdoorFanRpm ?? -1)")
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
        if let e = error as? KeychainError { return from(e) }
        return UserMessage(what: error.localizedDescription, todo: "")
    }

    static func deviceOff(detail: String?) -> UserMessage {
        UserMessage(what: L.Message.Device.Off.what, todo: L.Message.Device.Off.todo, code: "3123", detail: detail)
    }

    static func from(_ e: MideaError) -> UserMessage {
        let raw = e.errorDescription
        if isDeviceOff(e) { return deviceOff(detail: raw) }
        switch e {
        case .timeout:
            return UserMessage(what: L.Message.Device.Timeout.what, todo: L.Message.Device.Timeout.todo, detail: raw)
        case .outcomeUnknown:
            return UserMessage(what: L.Message.Device.OutcomeUnknown.what, todo: L.Message.Device.OutcomeUnknown.todo, detail: raw)
        case .busy:
            return UserMessage(what: L.Message.Device.Busy.what, todo: L.Message.Device.Busy.todo, detail: raw)
        case .connectionFailed, .refused, .unreachable, .allPathsFailed:
            var code: String?
            if case .allPathsFailed(let failures) = e { code = failures.compactMap(\.code).last }
            return UserMessage(what: L.Message.Device.NoConnection.what, todo: L.Message.Device.NoConnection.todo,
                               code: code, detail: raw)
        case .authenticationFailed:
            return UserMessage(what: L.Message.Device.AuthFailed.what, todo: L.Message.Device.AuthFailed.todo, detail: raw)
        case .crypto(let c):
            return UserMessage(what: L.Message.Device.Crypto.what, todo: L.Message.Device.tryAgain,
                               code: String(c), detail: raw)
        case .protocolError, .invalidResponse:
            return UserMessage(what: L.Message.Device.Unexpected.what, todo: L.Message.Device.tryAgain, detail: raw)
        case .commandNotApplied:
            return UserMessage(what: L.Message.Device.CommandNotApplied.what, todo: L.Message.Device.CommandNotApplied.todo,
                               detail: raw)
        }
    }

    static func from(_ e: MideaCloud.CloudError) -> UserMessage {
        let (what, todo): (String, String)
        switch e.kind {
        case .wrongCredentials: (what, todo) = (L.Message.Cloud.WrongCredentials.what, L.Message.Cloud.WrongCredentials.todo)
        case .accountLocked: (what, todo) = (L.Message.Cloud.AccountLocked.what, L.Message.Cloud.AccountLocked.todo)
        case .serviceUnavailable:
            (what, todo) = (L.Message.Cloud.ServiceUnavailable.what, L.Message.Cloud.ServiceUnavailable.todo)
        case .sessionExpired: (what, todo) = (L.Message.Cloud.SessionExpired.what, L.Message.Cloud.SessionExpired.todo)
        case .applianceOffline:
            (what, todo) = (L.Message.Cloud.ApplianceOffline.what, L.Message.Cloud.ApplianceOffline.todo)
        case .notInAccount, .noToken:
            (what, todo) = (L.Message.Cloud.UnknownAppliance.what, L.Message.Cloud.UnknownAppliance.todo)
        case .tokenRejected: (what, todo) = (L.Message.Cloud.TokenRejected.what, L.Message.Cloud.TokenRejected.todo)
        case .network: (what, todo) = (L.Message.Cloud.Network.what, L.Message.Cloud.Network.todo)
        case .badReply: (what, todo) = (L.Message.Cloud.BadReply.what, L.Message.Cloud.retryLater)
        case .other:
            if case .api(_, let msg) = e {
                let text = DeviceConfig.cleanText(msg, fallback: L.Message.Cloud.noText)
                (what, todo) = (L.Message.Cloud.OtherText.what(text: text), L.Message.Cloud.retryLater)
            } else {
                (what, todo) = (L.Message.Cloud.Other.what, L.Message.Cloud.retryLater)
            }
        case .paused, .keychainLocked: (what, todo) = (e.displayMessage, "")
        }
        return UserMessage(what: what, todo: todo, code: e.codeText, detail: e.errorDescription)
    }

    static func from(_ e: ConfigError) -> UserMessage {
        let raw = e.errorDescription
        switch e {
        case .noDevice:
            return UserMessage(what: L.Message.Config.NoDevice.what, todo: L.Message.Config.NoDevice.todo, detail: raw)
        case .unsupportedVersion(let v):
            return UserMessage(what: L.Message.Config.Unsupported.what, todo: L.Message.Config.Unsupported.todo,
                               code: "V\(v)", detail: raw)
        case .invalidHex:
            return UserMessage(what: L.Message.Config.InvalidHex.what, todo: L.Message.Config.InvalidHex.todo, detail: raw)
        case .invalidAddress:
            return UserMessage(what: L.Message.Config.InvalidAddress.what, todo: L.Message.Config.InvalidAddress.todo,
                               detail: raw)
        }
    }

    static func from(_ e: KeychainError) -> UserMessage { from(e, host: .current) }

    static func from(_ e: KeychainError, host: HostWords) -> UserMessage {
        let raw = e.errorDescription
        switch e {
        case .unavailable(let s):
            return UserMessage(what: host.isWindows ? L.Message.Keychain.Windows.Unavailable.what : L.Message.Keychain.Unavailable.what,
                               todo: host.isWindows ? L.Message.Keychain.Windows.Unavailable.todo : L.Message.Keychain.Unavailable.todo,
                               code: L.Message.Keychain.codeStatus(status: String(s)), detail: raw)
        case .saveFailed(let s):
            return UserMessage(what: host.isWindows ? L.Message.Keychain.Windows.SaveFailed.what : L.Message.Keychain.SaveFailed.what,
                               todo: L.Message.Keychain.SaveFailed.todo,
                               code: L.Message.Keychain.codeStatus(status: String(s)), detail: raw)
        case .tooLarge(let n):
            return UserMessage(what: L.Message.Keychain.TooLarge.what, todo: L.Message.Keychain.TooLarge.todo,
                               code: L.Message.Keychain.codeBytes(bytes: String(n)), detail: raw)
        case .unreadable:
            return UserMessage(what: L.Message.Keychain.Unreadable.what, todo: L.Message.Keychain.Unreadable.todo, detail: raw)
        }
    }
}
