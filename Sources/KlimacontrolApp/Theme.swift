import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Darstellung: aus `Appearance` abgeleitete Werte für alle Ansichten

/// Alles, was die Ansichten zum Zeichnen brauchen – abgeleitet aus `Appearance` (Kern), dem tatsächlichen Hell/Dunkel
/// und der Systemeinstellung „Bewegung reduzieren“. Kommt über `\.klimaTheme` in die Umgebung (`.klimaThemeRoot`).
struct ThemeStyle: Equatable, Sendable {
    var appearance: Appearance
    /// Modus für `tint` (ohne Argument); an der Wurzel nil, Stellen mit Zustand bauen sich selbst einen Stil.
    var mode: OperationalMode?
    var colorScheme: ColorScheme
    var systemReduceMotion: Bool

    init(appearance: Appearance, mode: OperationalMode? = nil, colorScheme: ColorScheme, reduceMotion: Bool) {
        self.appearance = appearance
        self.mode = mode
        self.colorScheme = colorScheme
        self.systemReduceMotion = reduceMotion
    }

    static let standard = ThemeStyle(appearance: .standard, colorScheme: .light, reduceMotion: false)

    /// Farbe des eigenen Modus (`mode`).
    var tint: Color { tint(for: mode) }

    var theme: Appearance.Theme { appearance.theme }
    var isContrast: Bool { theme == .contrast }
    var isDark: Bool { colorScheme == .dark }

    /// Bewegte Effekte erlaubt? Aus bei „Animationen reduzieren“ (App) oder „Bewegung reduzieren“ (System).
    var motionAllowed: Bool { appearance.motionAllowed(systemReduceMotion: systemReduceMotion) }
    /// Lebendiger Hintergrund eingeschaltet und erlaubt (ob die Anlage arbeitet, entscheidet der Aufrufer).
    var livelyEnabled: Bool { appearance.livelyActive(systemReduceMotion: systemReduceMotion) }
    /// Wetter-Effekte eingeschaltet und erlaubt.
    var weatherEnabled: Bool { appearance.weatherActive(systemReduceMotion: systemReduceMotion) }

    /// Für `.preferredColorScheme`: nil = wie das System.
    var preferredColorScheme: ColorScheme? {
        switch appearance.scheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: Farben

    /// Farbe je Modus nach Farbwahl und Thema. nil = ohne Modus (z. B. aus) → neutrales Grau.
    func tint(for mode: OperationalMode?) -> Color {
        let base: Color
        switch appearance.accent {
        case .byMode: base = mode?.tint ?? OperationalMode.fan.tint
        case .system: base = .accentColor
        case .custom: base = Self.customColor(appearance.customColor)
        }
        return adjusted(base)
    }

    /// Farbe einer Graphen-Linie im Thema (gleiche Abwandlung wie die Modusfarben).
    func series(_ color: Color) -> Color { adjusted(color) }

    static func customColor(_ c: Appearance.CustomColor) -> Color {
        switch c {
        case .orange: return Color(red: 0.96, green: 0.52, blue: 0.14)
        case .blue: return Color(red: 0.20, green: 0.50, blue: 0.95)
        case .green: return Color(red: 0.20, green: 0.66, blue: 0.38)
        case .purple: return Color(red: 0.58, green: 0.40, blue: 0.90)
        case .gray: return Color(red: 0.50, green: 0.53, blue: 0.58)
        }
    }

    /// Thema auf eine Farbe anwenden: Nacht gedimmt und rotarm, Neon kräftig, Minimal fast farblos, Kontrast
    /// dunkel (hell) bzw. hell (dunkel) genug für WCAG-AA. Standard und Systemfarbe bleiben unverändert.
    private func adjusted(_ color: Color) -> Color {
        guard theme != .standard, appearance.accent != .system,
              let c = NSColor(color).usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        switch theme {
        case .standard: break
        case .night:
            // Rotarm: Rot- und Orangetöne Richtung Bernstein schieben, alles gedimmt.
            if h < 0.08 || h > 0.92 { h = 0.09 }
            s *= 0.7; b *= 0.62
        case .neon:
            s = min(1, s * 1.35 + 0.1); b = max(b, 0.98)
        case .minimal:
            s *= 0.18; b = 0.35 + b * 0.35
        case .contrast:
            s = min(1, s * 1.1)
            b = Self.contrastBrightness(h: h, s: s, b: b, dark: isDark)
        }
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(b), opacity: Double(a))
    }

    /// Helligkeit so wählen, dass die Farbe auf weißem (hell) bzw. fast schwarzem (dunkel) Grund 4,5 : 1 erreicht.
    private static func contrastBrightness(h: CGFloat, s: CGFloat, b: CGFloat, dark: Bool) -> CGFloat {
        var b = b
        for _ in 0..<40 {
            let l = luminance(Color(hue: Double(h), saturation: Double(s), brightness: Double(b)))
            if dark ? l >= 0.27 : l <= 0.18 { break }
            b = dark ? min(1, b + 0.025) : max(0, b - 0.025)
            if b == 0 || b == 1 { break }
        }
        return b
    }

    /// Relative Leuchtdichte (WCAG 2.x) einer Farbe in sRGB.
    static func luminance(_ color: Color) -> Double {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    // MARK: Karten

    /// Faktor für die Tönung der Karten: 1 bei der Standard-Transparenz, weniger bei mehr Transparenz.
    var tintFactor: Double {
        let t0 = min(0.95, max(0, Appearance.standard.transparency))
        let t = min(0.95, max(0, appearance.transparency))
        return min(2, max(0, (1 - t) / max(0.05, 1 - t0)))
    }

    /// Deckende Karten (Matt oder Kontrast): Deckkraft der Fläche, 0 = Glas.
    var cardFillOpacity: Double {
        if isContrast { return 1 }
        guard appearance.background == .matte else { return 0 }
        return min(1, max(0.05, 1 - appearance.transparency))
    }

    /// Unschärfe relativ zum Standard (1 = Standard).
    var blurFactor: Double {
        let b0 = max(1, Appearance.standard.blur)
        return min(4, max(0, appearance.blur / b0))
    }

    /// Material hinter Karten ohne Liquid Glass (macOS 15, Matt) und hinter dem Fenster – aus der Unschärfe.
    var material: Material? {
        switch appearance.blur {
        case ..<2: return nil
        case ..<10: return .ultraThinMaterial
        case ..<20: return .thinMaterial
        case ..<28: return .regularMaterial
        case ..<35: return .thickMaterial
        default: return .ultraThickMaterial
        }
    }

    /// Fensterhintergrund (Hauptfenster, Mini-Fenster): Standard `.ultraThinMaterial`.
    var windowBackground: AnyShapeStyle {
        if isContrast || appearance.background == .matte {
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
        if appearance == .standard || appearance.background == .glass && blurFactor == 1 {
            return AnyShapeStyle(.ultraThinMaterial)
        }
        if appearance.background == .glassStrong { return AnyShapeStyle(.regularMaterial) }
        return material.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.clear)
    }

    /// Trennlinie zwischen den Spalten des Hauptfensters.
    var separator: Color { isContrast ? Color.primary.opacity(0.6) : Color(nsColor: .separatorColor) }

    /// Feine Linie innerhalb einer Karte (Kennzahlen im Kopf, Szenen/Timer, Modus/Lüfter).
    var hairline: Color { isContrast ? Color.primary.opacity(0.6) : Color.primary.opacity(0.12) }

    /// Fläche eines Knopfs innerhalb einer Glaskarte: kein zweites Glas, nur eine zarte Fläche.
    var innerFill: Color { Color.primary.opacity(isContrast ? 0.08 : (isDark ? 0.07 : 0.05)) }

    /// Deckender Fensterhintergrund (Vollbild).
    var opaqueWindowBackground: Color { Color(nsColor: .windowBackgroundColor) }

    /// Neon: leuchtende Kanten an getönten Karten.
    var edgeGlow: Bool { theme == .neon }

    // MARK: Leuchten, Schrift, Größe

    /// Schein um die große Zahl (0 = aus).
    var glowRadius: CGFloat { CGFloat(min(1, max(0, appearance.glow))) * 22 }
    var glowOpacity: Double { min(1, max(0, appearance.glow)) * (theme == .night ? 0.5 : 0.9) }

    /// Ziffern der großen Zahl. Normal = leicht, abgerundet.
    var fontWeight: Font.Weight {
        if theme == .minimal && appearance.digits == .normal { return .ultraLight }
        switch appearance.digits {
        case .thin: return .thin
        case .normal: return .light
        case .bold: return .semibold
        case .rounded: return .regular
        }
    }

    var fontDesign: Font.Design { appearance.digits == .thin ? .default : .rounded }

    /// Größenfaktor für große Zahl und Abstände: Kompakt 0,85 · Normal 1 · Groß 1,2.
    var scale: CGFloat {
        switch appearance.size {
        case .compact: return 0.85
        case .normal: return 1
        case .large: return 1.2
        }
    }

    /// Größe der Bedienelemente nach „Größe“ (Knöpfe, Schalter, Regler).
    var controlSize: ControlSize {
        switch appearance.size {
        case .compact: return .small
        case .normal: return .regular
        case .large: return .large
        }
    }

    /// Radius der großen Karten (Kopf, Modus und Lüfter, Szenen und Timer, Startanzeige).
    static let cardRadius: CGFloat = 20
    /// Radius der Elemente in einer Karte (Modus-Knöpfe, Szenen).
    static let innerRadius: CGFloat = 12
}

extension EnvironmentValues {
    @Entry var klimaTheme: ThemeStyle = .standard
}

// MARK: - Farben und Symbole je Modus

extension OperationalMode {
    /// SF-Symbol je Modus.
    var symbol: String {
        switch self {
        case .cool: return "snowflake"
        case .heat: return "flame"
        case .dry: return "drop"
        case .fan: return "fan"
        case .auto: return "a.circle"
        }
    }

    var tint: Color {
        switch self {
        case .cool: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .heat: return Color(red: 0.96, green: 0.45, blue: 0.18)
        case .dry: return Color(red: 0.15, green: 0.68, blue: 0.62)
        case .fan: return Color(red: 0.45, green: 0.52, blue: 0.60)
        case .auto: return Color(red: 0.55, green: 0.42, blue: 0.90)
        }
    }
}

extension ThemeStyle {
    /// Schrift auf einer getönten Fläche: weiß; im Kontrast-Thema weiß oder schwarz nach Lesbarkeit (WCAG-AA).
    func label(on color: Color) -> Color {
        isContrast && Self.luminance(color) > 0.18 ? .black : .white
    }
}

struct GlassContainer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}
