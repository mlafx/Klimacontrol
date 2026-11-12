import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI

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
