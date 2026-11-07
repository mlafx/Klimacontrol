import Foundation
import Synchronization

/// Wie Zahlen und Uhrzeiten aussehen – nach den Regionseinstellungen des Systems, unabhängig von der Sprache.
/// Mac: aus `Locale.autoupdatingCurrent`; Windows: aus `CultureInfo` über `kc_set_locale`. Standard de-DE.
public struct FormatProfile: Codable, Equatable, Sendable {
    /// Für Foundation-Eingabefelder der Mac-Oberfläche, z. B. "de_DE".
    public var localeIdentifier: String
    public var decimalSeparator: String
    /// Leer = keine Tausendertrennung.
    public var groupingSeparator: String
    public var uses24HourClock: Bool
    /// Leer = „AM“ bzw. „PM“.
    public var amSymbol: String
    public var pmSymbol: String
    /// Tag und Monat ohne Jahr: `d`/`dd`, `M`/`MM` (`L` wie `M`, drei und mehr wie zwei), Text in '…' wörtlich,
    /// alles andere unverändert. Beispiele "dd.MM.", "MM/dd", "dd/MM".
    public var dayMonthPattern: String

    public init(localeIdentifier: String, decimalSeparator: String, groupingSeparator: String, uses24HourClock: Bool,
                amSymbol: String, pmSymbol: String, dayMonthPattern: String) {
        self.localeIdentifier = localeIdentifier
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.uses24HourClock = uses24HourClock
        self.amSymbol = amSymbol
        self.pmSymbol = pmSymbol
        self.dayMonthPattern = dayMonthPattern
    }

    public static let germany = FormatProfile(localeIdentifier: "de_DE", decimalSeparator: ",", groupingSeparator: ".",
                                              uses24HourClock: true, amSymbol: "AM", pmSymbol: "PM",
                                              dayMonthPattern: "dd.MM.")
    public static let unitedStates = FormatProfile(localeIdentifier: "en_US", decimalSeparator: ".",
                                                   groupingSeparator: ",", uses24HourClock: false, amSymbol: "AM",
                                                   pmSymbol: "PM", dayMonthPattern: "MM/dd")

    private static let storage = Mutex(FormatProfile.germany)

    /// Gilt für den ganzen Prozess; Standard `.germany`.
    public static var current: FormatProfile { storage.withLock { $0 } }

    /// Darf jederzeit neu gesetzt werden (Mac: bei Änderung der Regionseinstellungen).
    public static func setCurrent(_ profile: FormatProfile) {
        storage.withLock { $0 = profile }
    }

    /// Test-Haken: `body` mit diesem Profil, danach das vorige wieder.
    static func withProfile<T>(_ profile: FormatProfile, _ body: () throws -> T) rethrows -> T {
        let previous = current
        setCurrent(profile)
        defer { setCurrent(previous) }
        return try body()
    }

    public static func from(locale: Locale) -> FormatProfile {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
        let formatter = DateFormatter()
        formatter.locale = locale
        let pattern = DateFormatter.dateFormat(fromTemplate: "ddMM", options: 0, locale: locale)
        return FormatProfile(
            localeIdentifier: locale.identifier,
            decimalSeparator: locale.decimalSeparator ?? ".",
            groupingSeparator: locale.groupingSeparator ?? "",
            uses24HourClock: !template.contains("a"),
            amSymbol: formatter.amSymbol ?? "AM",
            pmSymbol: formatter.pmSymbol ?? "PM",
            dayMonthPattern: pattern.flatMap { isValid(dayMonthPattern: $0) ? $0 : nil } ?? "dd.MM.")
    }

    /// JSON von `kc_set_locale` (Felder wie oben). nil bei fehlendem oder falsch getipptem Feld, leerem
    /// `decimalSeparator`, zu langem Trennzeichen oder einem Muster ohne Tag und Monat.
    public static func decode(_ data: Data) -> FormatProfile? {
        guard let p = try? JSONDecoder().decode(FormatProfile.self, from: data),
              !p.decimalSeparator.isEmpty,
              p.decimalSeparator.count <= 4, p.groupingSeparator.count <= 4,
              isValid(dayMonthPattern: p.dayMonthPattern) else { return nil }
        return p
    }

    private static func isValid(dayMonthPattern: String) -> Bool {
        dayMonthPattern.contains("d") && (dayMonthPattern.contains("M") || dayMonthPattern.contains("L"))
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }
}
