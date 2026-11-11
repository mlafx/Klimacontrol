import Foundation
import MideaKit

// MideaKit behält seine deutschen Texte (`label`, `summary`, `errorDescription`) für Protokoll und Datenbank.
// Was die Oberfläche zeigt, kommt von hier und aus dem Katalog.

extension OperationalMode {
    /// Name des Modus in der Sprache der Oberfläche („Kühlen“ / „Cool“).
    public var title: String {
        switch self {
        case .cool: L.Mode.cool
        case .heat: L.Mode.heat
        case .dry: L.Mode.dry
        case .fan: L.Mode.fan
        case .auto: L.Mode.auto
        }
    }

    /// Tätigkeit im Satz („Kühlt“ / „Cooling“).
    public var verb: String {
        switch self {
        case .cool: L.Mode.Verb.cool
        case .heat: L.Mode.Verb.heat
        case .dry: L.Mode.Verb.dry
        case .fan: L.Mode.Verb.fan
        case .auto: L.Mode.Verb.auto
        }
    }
}

extension FanSpeed {
    public var title: String {
        switch self {
        case .silent: L.Fan.quiet
        case .low: L.Fan.low
        case .medium: L.Fan.medium
        case .high: L.Fan.high
        case .max: L.Fan.max
        case .auto: L.Fan.auto
        }
    }
}

extension ACState {
    /// Lüfter als Text: benannte Stufe oder „37 %“ (Anzeige; `fanLabel` bleibt fürs Protokoll).
    public var fanTitle: String {
        FanSpeed(rawValue: fanSpeed)?.title ?? L.Fan.percent(value: "\(fanSpeed)")
    }
}

extension ConnectionMode {
    public var title: String {
        switch self {
        case .auto: L.Connection.Mode.auto
        case .lan: L.Connection.Mode.lan
        case .cloud: L.Connection.Mode.cloud
        }
    }
}

extension ConnectionPath {
    public var title: String {
        switch self {
        case .lan: L.Connection.Path.lan
        case .cloud: L.Connection.Path.cloud
        }
    }
}

extension ACScene {
    /// „Kühlen · 18° · Max“ bzw. „Aus“ (Anzeige; `summary` bleibt in MideaKit).
    public var summaryText: String {
        guard powerOn else { return L.Common.off }
        let modeText = OperationalMode(rawValue: mode)?.title ?? L.Mode.unknown(value: "\(mode)")
        let fanText = FanSpeed(rawValue: fan)?.title ?? L.Fan.percent(value: "\(fan)")
        return L.Scene.summary(mode: modeText, temp: Fmt.target(tempC), fan: fanText)
    }
}

/// Wochentage, Monate, heute/morgen – aus dem Katalog statt aus Foundation (unter Windows unzuverlässig).
public enum DateWords {
    public static var today: String { L.Date.today }
    public static var tomorrow: String { L.Date.tomorrow }

    /// `weekday` wie `Calendar` (1 = Sonntag); außerhalb 1–7 leer.
    public static func weekdayShort(_ weekday: Int) -> String {
        switch weekday {
        case 1: L.Date.WeekdayShort.sun
        case 2: L.Date.WeekdayShort.mon
        case 3: L.Date.WeekdayShort.tue
        case 4: L.Date.WeekdayShort.wed
        case 5: L.Date.WeekdayShort.thu
        case 6: L.Date.WeekdayShort.fri
        case 7: L.Date.WeekdayShort.sat
        default: ""
        }
    }

    public static func weekdayLong(_ weekday: Int) -> String {
        switch weekday {
        case 1: L.Date.WeekdayLong.sun
        case 2: L.Date.WeekdayLong.mon
        case 3: L.Date.WeekdayLong.tue
        case 4: L.Date.WeekdayLong.wed
        case 5: L.Date.WeekdayLong.thu
        case 6: L.Date.WeekdayLong.fri
        case 7: L.Date.WeekdayLong.sat
        default: ""
        }
    }

    /// `month` 1–12; außerhalb leer.
    public static func monthShort(_ month: Int) -> String {
        switch month {
        case 1: L.Date.MonthShort.jan
        case 2: L.Date.MonthShort.feb
        case 3: L.Date.MonthShort.mar
        case 4: L.Date.MonthShort.apr
        case 5: L.Date.MonthShort.may
        case 6: L.Date.MonthShort.jun
        case 7: L.Date.MonthShort.jul
        case 8: L.Date.MonthShort.aug
        case 9: L.Date.MonthShort.sep
        case 10: L.Date.MonthShort.oct
        case 11: L.Date.MonthShort.nov
        case 12: L.Date.MonthShort.dec
        default: ""
        }
    }

    public static func monthLong(_ month: Int) -> String {
        switch month {
        case 1: L.Date.MonthLong.jan
        case 2: L.Date.MonthLong.feb
        case 3: L.Date.MonthLong.mar
        case 4: L.Date.MonthLong.apr
        case 5: L.Date.MonthLong.may
        case 6: L.Date.MonthLong.jun
        case 7: L.Date.MonthLong.jul
        case 8: L.Date.MonthLong.aug
        case 9: L.Date.MonthLong.sep
        case 10: L.Date.MonthLong.oct
        case 11: L.Date.MonthLong.nov
        case 12: L.Date.MonthLong.dec
        default: ""
        }
    }
}

/// Gründe aus MideaKit für Texte der Oberfläche. Der Fall bestimmt den Katalogtext; nur freie Texte (Systemfehler,
/// Hinweise der Suche, Fehlertexte aus Teilen der Cloud-Anbindung) bleiben im Deutschen unverändert, in jeder anderen
/// Sprache steht ein allgemeiner Katalogtext. Texte von Midea selbst (`CloudError.api`) sind Daten und bleiben immer
/// unverändert.
enum ReasonText {
    /// Deutsche Oberfläche ohne Pseudo-Sprache: freie Texte unverändert zeigen.
    static var showsRawGerman: Bool { Localizer.language == .de && !Localizer.isPseudo }

    /// Freier Text: Deutsch unverändert, sonst „nicht erreichbar“.
    static func free(_ raw: String) -> String {
        showsRawGerman ? raw : L.Reason.unreachable
    }

    static func busy(_ cause: BusyCause) -> String {
        cause == .unknown ? L.Reason.busyShort : L.Reason.busy(hint: L.Reason.busyHint)
    }
}

extension ConnectionReason {
    public var displayText: String {
        switch self {
        case .closed: L.Reason.closed
        case .noLAN: L.Reason.noLan
        case .noCloud: L.Reason.noCloud
        case .noPath: L.Reason.noPath
        case .notConnected: L.Kit.Lan.notConnected
        case .budget: L.Kit.Lan.budget
        case .localNetwork: localNetworkText()
        case .other: ReasonText.free(text)
        }
    }
}

/// Hinweis, wenn das System die App nicht ins lokale Netz lässt: Freigabe am Mac, Firewall bzw. Netzwerkprofil unter Windows.
func localNetworkText(host: HostWords = .current) -> String {
    host.isWindows ? L.Kit.Lan.localNetworkWindows : L.Kit.Lan.localNetworkMac
}

extension MideaError {
    /// Anzeige-Fassung von `connectionDetail` (nil, wo `connectionDetail` nil ist).
    public var connectionDetailText: String? {
        switch self {
        case .connectionFailed(let reason): reason.displayText
        case .unreachable(let msg): ReasonText.free(msg)
        case .refused: L.Reason.refused
        case .allPathsFailed(let failures):
            failures.isEmpty ? L.Reason.noPath
                : failures.map { "\($0.path.title): \($0.displayText)" }.joined(separator: " · ")
        default: nil
        }
    }
}

extension PathFailure {
    /// Anzeige-Fassung von `text`, ohne den Weg (der kommt von `path.title`).
    public var displayText: String {
        switch reason {
        case .applianceOffline(let next):
            next.map { L.Reason.applianceOffAt(time: Fmt.clock($0)) } ?? L.Reason.applianceOffline
        case .refused: L.Reason.refused
        case .timeout: L.Reason.timeout
        case .unreachable: L.Reason.unreachable
        case .busy(let cause): ReasonText.busy(cause)
        case .connection(let reason): reason.displayText
        case .cloud(let kind, let code):
            code != nil ? text : cloudText(kind)
        case .other: ReasonText.free(text)
        }
    }

    private func cloudText(_ kind: CloudErrorKind) -> String {
        if kind == .network { return L.Reason.Cloud.unreachable }
        if ReasonText.showsRawGerman { return text }
        switch kind {
        case .noToken: return L.Reason.Cloud.noToken
        case .tokenRejected: return L.Reason.Cloud.tokenRejected
        case .notInAccount: return L.Reason.Cloud.notInAccount
        case .badReply: return L.Reason.Cloud.badReply
        case .sessionExpired: return L.Reason.Cloud.session
        case .keychainLocked: return keychainLockedText()
        default: return L.Reason.Cloud.error
        }
    }
}

extension MideaCloud.CloudError {
    /// Anzeige-Fassung von `message` (bei `.api` Mideas Text; `.paused` mit Uhrzeit über `Fmt.clock`).
    public var displayMessage: String {
        switch self {
        case .api(_, let msg): msg
        case .noToken: L.Reason.Cloud.noToken
        case .tokenRejected: L.Reason.Cloud.tokenRejected
        case .notInAccount: L.Reason.Cloud.notInAccount
        case .paused(let until): L.Reason.Cloud.paused(time: Fmt.clock(until))
        case .keychainLocked: keychainLockedText()
        case .network(let msg): ReasonText.showsRawGerman ? msg : L.Reason.Cloud.unreachable
        case .badReply(let msg): ReasonText.showsRawGerman ? msg : L.Reason.Cloud.badReply
        case .sessionKeys(let msg), .incompleteLogin(let msg): ReasonText.showsRawGerman ? msg : L.Reason.Cloud.session
        }
    }
}

/// Wo die Cloud-Sitzung liegt, hängt vom Rechner ab: Schlüsselbund (Mac) bzw. Anmeldeinformationsverwaltung (Windows).
func keychainLockedText(host: HostWords = .current) -> String {
    host.isWindows ? L.Reason.Cloud.Windows.keychainLocked : L.Reason.Cloud.keychainLocked
}
