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
    var motionAllowed: Bool { !appearance.reduceMotion && !systemReduceMotion }
    /// Lebendiger Hintergrund eingeschaltet und erlaubt (ob die Anlage arbeitet, entscheidet der Aufrufer).
    var livelyEnabled: Bool { appearance.lively && motionAllowed }
    /// Wetter-Effekte eingeschaltet und erlaubt.
    var weatherEnabled: Bool { appearance.weather && motionAllowed }

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

    /// Schrift auf einer Fläche in `tint(for:)`: weiß oder schwarz, je nachdem, was besser lesbar ist (WCAG-AA).
    func onTint(for mode: OperationalMode?) -> Color {
        Self.luminance(tint(for: mode)) > 0.18 ? .black : .white
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

    /// Schrift der großen Zahl; `size` ist die Grundgröße (z. B. 68), Größe und Ziffernstil kommen dazu.
    func heroFont(size: CGFloat) -> Font {
        .system(size: (size * scale).rounded(), weight: fontWeight, design: fontDesign).monospacedDigit()
    }
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

// MARK: - Wurzel: Thema aus dem Modell in die Umgebung

/// An jede Szene (Hauptfenster, Menüleisten-Fenster, Einstellungen, Mini-Fenster): liest nur `model.appearance`,
/// rechnet also nur neu, wenn sich die Darstellung ändert – nicht bei jeder Abfrage.
struct KlimaThemeRoot: ViewModifier {
    /// false für das Menüleisten-Symbol: nur Umgebung, kein eigenes Hell/Dunkel.
    var applyScheme = true
    @Environment(ACController.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let style = ThemeStyle(appearance: model.appearance, colorScheme: colorScheme, reduceMotion: reduceMotion)
        content
            .environment(\.klimaTheme, style)
            .preferredColorScheme(applyScheme ? style.preferredColorScheme : nil)
    }
}

extension View {
    /// Thema setzen; braucht `ACController` in der Umgebung (also nach `.environment(model)` anhängen).
    func klimaThemeRoot(applyScheme: Bool = true) -> some View { modifier(KlimaThemeRoot(applyScheme: applyScheme)) }

    /// Karte im Thema (Glas oder matte Fläche, optional getönt) – für alle Karten, Knöpfe und Banner.
    func klimaCard(tint: Color? = nil, radius: CGFloat = 14, interactive: Bool = false) -> some View {
        modifier(KlimaCard(tint: tint, radius: radius, interactive: interactive))
    }

    /// Schein in `color` um die große Zahl; Stärke aus der Darstellung (0 = nichts).
    func klimaGlow(_ color: Color) -> some View { modifier(KlimaGlow(color: color)) }
}

struct KlimaCard: ViewModifier {
    @Environment(\.klimaTheme) private var theme
    let tint: Color?
    let radius: CGFloat
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        styled(content, shape)
            .overlay {
                if theme.edgeGlow, let tint {
                    shape.strokeBorder(tint.opacity(0.9), lineWidth: 1)
                        .shadow(color: tint.opacity(0.8), radius: 4)
                        .allowsHitTesting(false)
                } else if theme.isContrast {
                    shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func styled(_ content: Content, _ shape: RoundedRectangle) -> some View {
        let f = theme.tintFactor
        if theme.cardFillOpacity > 0 {
            // Matt bzw. Kontrast: deckende Fläche, Tönung darüber (getönte Knöpfe kräftig wie unter macOS 15).
            content.background(
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(theme.cardFillOpacity))
                    .overlay(shape.fill((tint ?? .clear).opacity(theme.isContrast
                        ? (interactive ? 1 : 0.18) : min(1, (interactive ? 0.9 : 0.25) * f))))
            )
        } else if #available(macOS 26, *) {
            let strong = theme.appearance.background == .glassStrong
            let amount = min(1, 0.45 * f * (strong ? 1.5 : 1))
            let tinted: Glass = tint.map { Glass.regular.tint($0.opacity(amount)) } ?? .regular
            // Wenig Unschärfe → klares Glas; mehr als Standard bzw. „Glas kräftig“ → Material in der Karte.
            let base: Glass = theme.blurFactor < 0.5 ? (tint.map { Glass.clear.tint($0.opacity(amount)) } ?? .clear) : tinted
            let glass = interactive ? base.interactive() : base
            if strong || theme.blurFactor > 1.5, let m = theme.material {
                content.background(shape.fill(m).opacity(strong ? 0.8 : 0.5)).glassEffect(glass, in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        } else {
            // macOS 15 wie `.glass`: getönte Knöpfe kräftig, Flächen zart.
            let m = theme.appearance.background == .glassStrong ? Material.regularMaterial
                : (theme.blurFactor == 1 ? .ultraThinMaterial : theme.material ?? .ultraThinMaterial)
            content.background(
                shape.fill(m)
                    .overlay(shape.fill((tint ?? .clear).opacity(min(1, (interactive ? 0.9 : 0.25) * f))))
            )
        }
    }
}

struct KlimaGlow: ViewModifier {
    @Environment(\.klimaTheme) private var theme
    let color: Color

    func body(content: Content) -> some View {
        if theme.glowRadius > 0 {
            content
                .shadow(color: color.opacity(theme.glowOpacity), radius: theme.glowRadius / 2)
                .shadow(color: color.opacity(theme.glowOpacity * 0.6), radius: theme.glowRadius)
        } else {
            content
        }
    }
}

// MARK: - Lebendiger Hintergrund

/// Grenzen der bewegten Effekte bei großen Fenstern (Vollbild): weniger Bilder je Sekunde, Teilchen nach Fläche.
enum EffectsBudget {
    /// Über etwa 2 Megapixel genügen 20 Bilder je Sekunde.
    static func interval(size: CGSize, scale: CGFloat) -> Double {
        size.width * size.height * scale * scale > 2_000_000 ? 1.0 / 20 : 1.0 / 30
    }

    /// Teilchenzahl des Schneefalls: 28 bei der Fläche des bisherigen Fensters, nach Fläche begrenzt.
    static func particles(size: CGSize) -> Int {
        min(120, max(12, Int(28 * size.width * size.height / 340_000)))
    }
}

/// Langsam fließender Farbverlauf in der Modusfarbe hinter dem Fenster. Zeichnet nur, wenn eingeschaltet, `active`
/// (Anlage arbeitet), Bewegung erlaubt und das Fenster sichtbar ist – sonst eine leere Fläche ohne Zeitgeber.
/// Höchstens 30 Bilder je Sekunde, für VoiceOver ausgeblendet.
struct LivelyBackground: View {
    @Environment(\.klimaTheme) private var theme
    let active: Bool
    var mode: OperationalMode? = nil
    @State private var visible = false
    @Environment(\.displayScale) private var displayScale

    private static let reduction: CGFloat = 3

    var body: some View {
        let run = active && visible && theme.livelyEnabled
        let tint = theme.tint(for: mode)
        ZStack {
            if run {
                // Weiche Flecken brauchen keine volle Auflösung: auf ein Drittel zeichnen und hochskalieren.
                GeometryReader { geo in
                    TimelineView(.animation(minimumInterval: EffectsBudget.interval(size: geo.size, scale: displayScale))) { ctx in
                        Canvas { g, size in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            Self.draw(g, size: size, t: t, tint: tint, strength: theme.isDark ? 0.32 : 0.22)
                        }
                        .frame(width: geo.size.width / Self.reduction, height: geo.size.height / Self.reduction)
                        .scaleEffect(Self.reduction, anchor: .topLeading)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisibilityProbe { visible = $0 })
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 1.2), value: run)
    }

    /// Drei weiche Farbflecken auf langsamen Lissajous-Bahnen (Periode 20–40 s).
    static func draw(_ g: GraphicsContext, size: CGSize, t: Double, tint: Color, strength: Double) {
        let r = max(size.width, size.height) * 0.75
        let blobs: [(Double, Double, Double, Double)] = [(0.031, 0.023, 0, 1), (0.019, 0.037, 2.1, 0.7), (0.027, 0.017, 4.2, 0.5)]
        for (fx, fy, phase, w) in blobs {
            let x = size.width * (0.5 + 0.4 * sin(t * fx * 2 * .pi / 1.2 + phase))
            let y = size.height * (0.5 + 0.4 * cos(t * fy * 2 * .pi / 1.2 + phase * 0.7))
            let rect = CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)
            g.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [tint.opacity(strength * w), tint.opacity(0)]),
                center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r / 2))
        }
    }
}

// MARK: - Wetter-Effekte

/// Dezent: Schneeflocken beim Kühlen, aufsteigende Wärme beim Heizen, sonst nichts. Gleiche Regeln wie
/// `LivelyBackground` (nur sichtbar, eingeschaltet, Bewegung erlaubt; ≤ 30 fps; für VoiceOver ausgeblendet).
struct WeatherEffect: View {
    @Environment(\.klimaTheme) private var theme
    let mode: OperationalMode?
    let active: Bool
    @State private var visible = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let kind: OperationalMode? = mode == .cool || mode == .heat ? mode : nil
        let run = active && visible && theme.weatherEnabled && kind != nil
        let tint = theme.tint(for: .heat)
        let snow = theme.isDark ? Color.white : Color(white: 0.55)
        ZStack {
            if run, let kind {
                GeometryReader { geo in
                    TimelineView(.animation(minimumInterval: EffectsBudget.interval(size: geo.size, scale: displayScale))) { ctx in
                        Canvas { g, size in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            let count = EffectsBudget.particles(size: size)
                            if kind == .cool { Self.snow(g, size: size, t: t, color: snow, count: count) }
                            else { Self.warmth(g, size: size, t: t, color: tint, count: count / 2) }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisibilityProbe { visible = $0 })
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 1), value: run)
    }

    /// Feste Pseudozufallswerte je Teilchen (ohne Zustand, gleich bei jedem Bild).
    private static func rnd(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i * 127 + k * 311) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    static func snow(_ g: GraphicsContext, size: CGSize, t: Double, color: Color, count: Int) {
        for i in 0..<count {
            let speed = 12 + rnd(i, 1) * 18            // pt je Sekunde
            let h = size.height + 20
            let y = (rnd(i, 2) * h + t * speed).truncatingRemainder(dividingBy: h) - 10
            let x = size.width * rnd(i, 3) + sin(t * 0.6 + Double(i)) * 8
            let d = 2 + rnd(i, 4) * 3
            g.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                   with: .color(color.opacity(0.25 + rnd(i, 5) * 0.35)))
        }
    }

    static func warmth(_ g: GraphicsContext, size: CGSize, t: Double, color: Color, count: Int) {
        for i in 0..<count {
            let period = 6 + rnd(i, 1) * 6
            let p = (t / period + rnd(i, 2)).truncatingRemainder(dividingBy: 1)   // 0 unten … 1 oben
            let y = size.height * (1 - p)
            let x = size.width * rnd(i, 3) + sin(t * 0.8 + Double(i) * 1.7) * 12
            let d = 14 + rnd(i, 4) * 22
            let a = sin(p * .pi) * 0.22
            g.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                   with: .radialGradient(Gradient(colors: [color.opacity(a), color.opacity(0)]),
                                         center: CGPoint(x: x, y: y), startRadius: 0, endRadius: d / 2))
        }
    }
}
