import Foundation

extension SettingsKey {
    /// Darstellung (Reiter „Darstellung“) als JSON-Text.
    public static let appearance = "appearance"
}

/// Aussehen der Oberfläche (Reiter „Darstellung“). Nur Werte, keine Farben oder Schriften – die leitet jede Oberfläche
/// selbst ab (Mac: `ThemeStyle`, Windows: eigene Umsetzung).
///
/// Decoding ist robust: fehlende, unbekannte oder falsch getippte Felder werden zum Standardwert, Zahlen werden in
/// ihre Grenzen geklemmt, nie ein Fehler – eine kaputte Einstellung darf die App nie am Start hindern.
public struct Appearance: Codable, Equatable, Sendable {
    /// Thema: ein Paket, das die Aussehens-Werte setzt (`applyTheme`); Aufbau und Menüleiste bleiben.
    public enum Theme: String, CaseIterable, Codable, Sendable {
        case standard, night, neon, minimal, contrast
        public var label: String {
            switch self {
            case .standard: "Standard"
            case .night: "Nacht"
            case .neon: "Neon"
            case .minimal: "Minimal"
            case .contrast: "Kontrast"
            }
        }
    }

    /// Hell/Dunkel: wie das System oder fest.
    public enum Scheme: String, CaseIterable, Codable, Sendable {
        case system, light, dark
        public var label: String {
            switch self {
            case .system: "System"
            case .light: "Hell"
            case .dark: "Dunkel"
            }
        }
    }

    /// Farben: nach Betriebsart (Kühlen blau, Heizen orange …), Systemfarbe oder eine eigene Farbe (`customColor`).
    public enum Accent: String, CaseIterable, Codable, Sendable {
        case byMode, system, custom
        public var label: String {
            switch self {
            case .byMode: "Nach Modus"
            case .system: "Systemfarbe"
            case .custom: "Eigene"
            }
        }
    }

    public enum CustomColor: String, CaseIterable, Codable, Sendable {
        case orange, blue, green, purple, gray
        public var label: String {
            switch self {
            case .orange: "Orange"
            case .blue: "Blau"
            case .green: "Grün"
            case .purple: "Lila"
            case .gray: "Grau"
            }
        }
    }

    public enum Background: String, CaseIterable, Codable, Sendable {
        case glass, glassStrong, matte
        public var label: String {
            switch self {
            case .glass: "Glas"
            case .glassStrong: "Glas kräftig"
            case .matte: "Matt"
            }
        }
    }

    public enum SizeClass: String, CaseIterable, Codable, Sendable {
        case compact, normal, large
        public var label: String {
            switch self {
            case .compact: "Kompakt"
            case .normal: "Normal"
            case .large: "Groß"
            }
        }
    }

    public enum DigitStyle: String, CaseIterable, Codable, Sendable {
        case thin, normal, bold, rounded
        public var label: String {
            switch self {
            case .thin: "Dünn"
            case .normal: "Normal"
            case .bold: "Fett"
            case .rounded: "Abgerundet"
            }
        }
    }

    /// Welche Temperatur groß angezeigt wird.
    public enum HeroValue: String, CaseIterable, Codable, Sendable {
        case target, room
        public var label: String {
            switch self {
            case .target: "Solltemperatur"
            case .room: "Raumtemperatur"
            }
        }
    }

    /// Umfang: „Einfach“ = nur Ein/Aus, Modus, Temperatur, Lüfter, Timer; der Rest unter „Mehr …“.
    public enum Scope: String, CaseIterable, Codable, Sendable {
        case simple, all
        public var label: String {
            switch self {
            case .simple: "Einfach"
            case .all: "Alles"
            }
        }
    }

    /// Text in der Menüleiste (bzw. im Infobereich unter Windows).
    public enum MenuBarText: String, CaseIterable, Codable, Sendable {
        case iconOnly, iconTarget, iconRoom, roomTarget
        public var label: String {
            switch self {
            case .iconOnly: "Nur Symbol"
            case .iconTarget: "Symbol + Soll"
            case .iconRoom: "Symbol + Raum"
            case .roomTarget: "Raum + Soll"
            }
        }
    }

    /// Grenzen der Regler.
    public static let transparencyRange: ClosedRange<Double> = 0...0.95
    public static let blurRange: ClosedRange<Double> = 0...40
    public static let glowRange: ClosedRange<Double> = 0...1

    public var theme: Theme = .standard
    public var scheme: Scheme = .system
    public var accent: Accent = .byMode
    /// Nur bei `accent == .custom` wirksam.
    public var customColor: CustomColor = .orange
    public var background: Background = .glass
    /// Durchsichtigkeit der Karten, 0…0,95 (Anteil). Standard 0,4 = Glas.
    public var transparency: Double = 0.4
    /// Unschärfe hinter den Karten in pt, 0…40. Standard 20 = Material.
    public var blur: Double = 20
    /// Leuchten um die große Zahl, 0…1 (Anteil). Standard 0 = kein Leuchten.
    public var glow: Double = 0
    public var size: SizeClass = .normal
    public var digits: DigitStyle = .normal
    public var hero: HeroValue = .target
    public var scope: Scope = .all
    /// Lebendiger Hintergrund (fließender Farbverlauf, nur solange die Anlage arbeitet).
    public var lively = false
    /// Wetter-Effekte (Schnee beim Kühlen, Wärme beim Heizen).
    public var weather = false
    /// Animationen reduzieren: schaltet `lively` und `weather` ab (siehe `motionAllowed`).
    public var reduceMotion = false
    public var alwaysOnTop = false
    /// Standard `iconTarget` = Modus-Symbol + Solltemperatur.
    public var menuBarText: MenuBarText = .iconTarget
    /// Symbol in Modusfarbe. Standard je Plattform: am Mac einfarbiges Vorlage-Symbol, unter Windows farbige Kachel.
    public var menuBarColored = Appearance.platformColoredIcon
    /// Lüfter-Symbol dreht, solange die Anlage läuft.
    public var menuBarAnimated = false

    public init() {}

    /// Standard des Infobereich-/Menüleisten-Symbols: Windows farbig, Mac einfarbig.
    public static let platformColoredIcon: Bool = {
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }()

    public static let standard = Appearance()

    /// Bewegte Effekte erlaubt? Aus, wenn „Animationen reduzieren“ an ist oder das System „Bewegung reduzieren“ meldet.
    public func motionAllowed(systemReduceMotion: Bool) -> Bool { !reduceMotion && !systemReduceMotion }
    /// Lebendiger Hintergrund bzw. Wetter-Effekte wirklich zeichnen (Schalter an und Bewegung erlaubt).
    public func livelyActive(systemReduceMotion: Bool) -> Bool { lively && motionAllowed(systemReduceMotion: systemReduceMotion) }
    public func weatherActive(systemReduceMotion: Bool) -> Bool { weather && motionAllowed(systemReduceMotion: systemReduceMotion) }

    /// Vollständiges Aussehen eines Themas (vom Standard aus).
    public static func preset(_ theme: Theme) -> Appearance {
        var a = Appearance.standard
        a.theme = theme
        switch theme {
        case .standard:
            break
        case .night:
            // Gedimmt und rotarm: dunkel, matt, kühle eigene Farbe statt Orange/Rot beim Heizen, dünne Ziffern.
            a.scheme = .dark
            a.accent = .custom
            a.customColor = .blue
            a.background = .matte
            a.transparency = 0.15
            a.blur = 10
            a.digits = .thin
            a.menuBarColored = false
        case .neon:
            // Leuchtende Kanten, kräftige Sättigung.
            a.scheme = .dark
            a.background = .glassStrong
            a.transparency = 0.55
            a.blur = 30
            a.glow = 0.8
            a.digits = .bold
            a.lively = true
            a.menuBarColored = true
        case .minimal:
            // Dünne Schrift, fast farblos.
            a.accent = .custom
            a.customColor = .gray
            a.transparency = 0.6
            a.blur = 16
            a.digits = .thin
            a.menuBarColored = false
        case .contrast:
            // Deckend und gut lesbar (WCAG-AA): kein Durchscheinen, keine Unschärfe, fette Ziffern.
            a.background = .matte
            a.transparency = 0
            a.blur = 0
            a.digits = .bold
        }
        return a
    }

    /// Das Thema auf dieses Aussehen anwenden: setzt die Aussehens-Werte des Themas (Thema, Modus, Farben, Hintergrund,
    /// Transparenz, Unschärfe, Leuchten, Ziffernstil, Lebendig, Wetter, farbiges Symbol). Unverändert bleiben Aufbau und
    /// Bedienung: Größe, Groß angezeigt, Umfang, Animationen reduzieren, Vordergrund, Menüleisten-Text, animiertes Symbol.
    public func applying(_ theme: Theme) -> Appearance {
        var a = Appearance.preset(theme)
        a.size = size
        a.hero = hero
        a.scope = scope
        a.reduceMotion = reduceMotion
        a.alwaysOnTop = alwaysOnTop
        a.menuBarText = menuBarText
        a.menuBarAnimated = menuBarAnimated
        return a
    }

    /// Zahlen in ihre Grenzen; nicht endliche Werte werden zum Standard.
    public func clamped() -> Appearance {
        var a = self
        a.transparency = Self.clamp(transparency, Self.transparencyRange, Self.standard.transparency)
        a.blur = Self.clamp(blur, Self.blurRange, Self.standard.blur)
        a.glow = Self.clamp(glow, Self.glowRange, Self.standard.glow)
        return a
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback
    }

    // MARK: Codable (robust)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case theme, scheme, accent, customColor, background, transparency, blur, glow, size, digits, hero, scope,
             lively, weather, reduceMotion, alwaysOnTop, menuBarText, menuBarColored, menuBarAnimated
    }

    /// Ausgangswert für fehlende oder unlesbare Felder (Standard, wenn nicht gesetzt).
    static let baseKey = CodingUserInfoKey(rawValue: "klimacontrol.appearance.base")!

    public init(from decoder: any Decoder) throws {
        let base = decoder.userInfo[Self.baseKey] as? Appearance ?? .standard
        self = base
        // Kein Objekt (z. B. Zahl oder Liste) → Ausgangswert.
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        theme = value(.theme, theme)
        scheme = value(.scheme, scheme)
        accent = value(.accent, accent)
        customColor = value(.customColor, customColor)
        background = value(.background, background)
        transparency = value(.transparency, transparency)
        blur = value(.blur, blur)
        glow = value(.glow, glow)
        size = value(.size, size)
        digits = value(.digits, digits)
        hero = value(.hero, hero)
        scope = value(.scope, scope)
        lively = value(.lively, lively)
        weather = value(.weather, weather)
        reduceMotion = value(.reduceMotion, reduceMotion)
        alwaysOnTop = value(.alwaysOnTop, alwaysOnTop)
        menuBarText = value(.menuBarText, menuBarText)
        menuBarColored = value(.menuBarColored, menuBarColored)
        menuBarAnimated = value(.menuBarAnimated, menuBarAnimated)
        self = clamped()
    }

    // MARK: JSON

    /// JSON-Text (Schlüssel sortiert), wie er gespeichert und an Windows gegeben wird.
    public var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Aus JSON lesen; nie ein Fehler. Fehlende, unbekannte oder falsch getippte Felder (auch `null`) bleiben wie in
    /// `base` – so wirkt ein Teil-Objekt wie `{"blur": 12}` als Änderung; kaputtes JSON liefert `base`.
    public static func decode(_ data: Data, base: Appearance = .standard) -> Appearance {
        let dec = JSONDecoder()
        dec.userInfo[baseKey] = base
        return ((try? dec.decode(Appearance.self, from: data)) ?? base).clamped()
    }

    public static func decode(_ text: String, base: Appearance = .standard) -> Appearance {
        decode(Data(text.utf8), base: base)
    }
}
