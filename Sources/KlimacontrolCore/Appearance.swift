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
            case .standard: L.Appearance.Theme.standard
            case .night: L.Appearance.Theme.night
            case .neon: L.Appearance.Theme.neon
            case .minimal: L.Appearance.Theme.minimal
            case .contrast: L.Appearance.Theme.contrast
            }
        }
    }

    /// Hell/Dunkel: wie das System oder fest.
    public enum Scheme: String, CaseIterable, Codable, Sendable {
        case system, light, dark
        public var label: String {
            switch self {
            case .system: L.Appearance.Scheme.system
            case .light: L.Appearance.Scheme.light
            case .dark: L.Appearance.Scheme.dark
            }
        }
    }

    /// Farben: nach Betriebsart (Kühlen blau, Heizen orange …), Systemfarbe oder eine eigene Farbe (`customColor`).
    public enum Accent: String, CaseIterable, Codable, Sendable {
        case byMode, system, custom
        public var label: String {
            switch self {
            case .byMode: L.Appearance.Accent.byMode
            case .system: L.Appearance.Accent.system
            case .custom: L.Appearance.Accent.custom
            }
        }
    }

    public enum CustomColor: String, CaseIterable, Codable, Sendable {
        case orange, blue, green, purple, gray
        public var label: String {
            switch self {
            case .orange: L.Appearance.Color.orange
            case .blue: L.Appearance.Color.blue
            case .green: L.Appearance.Color.green
            case .purple: L.Appearance.Color.purple
            case .gray: L.Appearance.Color.gray
            }
        }
    }

    public enum Background: String, CaseIterable, Codable, Sendable {
        case glass, glassStrong, matte
        public var label: String {
            switch self {
            case .glass: L.Appearance.Background.glass
            case .glassStrong: L.Appearance.Background.glassStrong
            case .matte: L.Appearance.Background.matte
            }
        }
    }

    public enum SizeClass: String, CaseIterable, Codable, Sendable {
        case compact, normal, large
        public var label: String {
            switch self {
            case .compact: L.Appearance.Size.compact
            case .normal: L.Appearance.Size.normal
            case .large: L.Appearance.Size.large
            }
        }
    }

    public enum DigitStyle: String, CaseIterable, Codable, Sendable {
        case thin, normal, bold, rounded
        public var label: String {
            switch self {
            case .thin: L.Appearance.Digits.thin
            case .normal: L.Appearance.Digits.normal
            case .bold: L.Appearance.Digits.bold
            case .rounded: L.Appearance.Digits.rounded
            }
        }
    }

    /// Welche Temperatur groß angezeigt wird.
    public enum HeroValue: String, CaseIterable, Codable, Sendable {
        case target, room
        public var label: String {
            switch self {
            case .target: L.Appearance.Hero.target
            case .room: L.Appearance.Hero.room
            }
        }
    }

    /// Umfang: „Einfach“ = nur Ein/Aus, Modus, Temperatur, Lüfter, Timer; der Rest unter „Mehr …“.
    public enum Scope: String, CaseIterable, Codable, Sendable {
        case simple, all
        public var label: String {
            switch self {
            case .simple: L.Appearance.Scope.simple
            case .all: L.Appearance.Scope.all
            }
        }
    }

    /// Text in der Menüleiste (bzw. im Infobereich unter Windows).
    public enum MenuBarText: String, CaseIterable, Codable, Sendable {
        case iconOnly, iconTarget, iconRoom, roomTarget
        public var label: String {
            switch self {
            case .iconOnly: L.Appearance.MenuBar.iconOnly
            case .iconTarget: L.Appearance.MenuBar.iconTarget
            case .iconRoom: L.Appearance.MenuBar.iconRoom
            case .roomTarget: L.Appearance.MenuBar.roomTarget
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
    /// Außentemperatur im Temperaturgraphen statt in einem eigenen Graphen. Standard aus: Außen liegt meist weit unter
    /// Raum und Soll und staucht beide sonst auf einen schmalen Streifen.
    public var temperatureCombined = false

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
    /// Bedienung: Größe, Groß angezeigt, Umfang, Animationen reduzieren, Vordergrund, Menüleisten-Text, animiertes Symbol,
    /// Außentemperatur im Temperaturgraphen.
    public func applying(_ theme: Theme) -> Appearance {
        var a = Appearance.preset(theme)
        a.size = size
        a.hero = hero
        a.scope = scope
        a.reduceMotion = reduceMotion
        a.alwaysOnTop = alwaysOnTop
        a.menuBarText = menuBarText
        a.menuBarAnimated = menuBarAnimated
        a.temperatureCombined = temperatureCombined
        return a
    }

    /// Ein Aussehens-Wert weicht vom Thema ab (Größe, Groß angezeigt, Umfang und die übrigen Bedienwerte zählen nicht).
    public var isCustomized: Bool {
        let own = clamped()
        var base = applying(theme)
        // Regler liefern Werte wie 0.15000000000000002; Abweichungen unter einer halben Reglerstufe zählen nicht.
        if abs(base.transparency - own.transparency) < 0.001 { base.transparency = own.transparency }
        if abs(base.blur - own.blur) < 0.001 { base.blur = own.blur }
        if abs(base.glow - own.glow) < 0.001 { base.glow = own.glow }
        return own != base
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
             lively, weather, reduceMotion, alwaysOnTop, menuBarText, menuBarColored, menuBarAnimated, temperatureCombined
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
        temperatureCombined = value(.temperatureCombined, temperatureCombined)
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
