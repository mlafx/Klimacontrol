import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI

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

    /// Knopf innerhalb einer Glaskarte: zarte Fläche, gewählt in `tint` (Glas auf Glas vermeidet macOS 26).
    func klimaInner(tint: Color? = nil, radius: CGFloat = ThemeStyle.innerRadius) -> some View {
        modifier(KlimaInner(tint: tint, radius: radius))
    }

    /// Gemeinsame Glaskarte für mehrere Bereiche (Modus und Lüfter, Szenen und Timer).
    func klimaGroup() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading).klimaCard(radius: ThemeStyle.cardRadius)
    }
}

struct KlimaInner: ViewModifier {
    @Environment(\.klimaTheme) private var theme
    let tint: Color?
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .background(shape.fill(tint.map { $0.opacity(theme.isContrast ? 1 : 0.85) } ?? theme.innerFill))
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
}

/// Gedrückt leicht abgeblendet: Knöpfe mit `klimaInner` haben kein interaktives Glas, das darauf reagiert.
struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
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
        } else if theme.plainLightCards && !interactive {
            // Hell: Klares Glas hellt große Flächen fast bis Weiß auf; dieselbe Fläche wie die Karten von Verlauf und
            // Diagnose hält alle Karten des Fensters gleich hell. Die Tönung (Kopfkarte) liegt dezent darüber.
            content.background(
                shape.fill(theme.lightCardFill)
                    .overlay(shape.fill((tint ?? .clear).opacity(min(1, 0.45 * f))))
                    .overlay(shape.strokeBorder(theme.lightCardStroke, lineWidth: 0.5))
            )
        } else if #available(macOS 26, *) {
            let strong = theme.appearance.background == .glassStrong
            // Eingeschaltete Knöpfe tragen weiße Schrift: Im hellen Modus hellt das Glas die Tönung so stark auf,
            // dass Schrift und Zustand kaum zu sehen sind – dort kräftiger tönen.
            let base = interactive && tint != nil && !theme.isDark ? 0.9 : 0.45
            let amount = min(1, base * f * (strong ? 1.5 : 1))
            let tinted: Glass = tint.map { Glass.regular.tint($0.opacity(amount)) } ?? .regular
            // Wenig Unschärfe und große Flächen (nicht interaktiv) → klares Glas: Das normale Glas legt im dunklen Modus
            // eine fast deckende dunkle Schicht auf, die bei durchscheinendem Fenster vor hellem Hintergrund schwer
            // gegen die gläsernen Seitenspalten wirkt. Eine leichte Abdunklung hält weiße Schrift dort lesbar.
            // Mehr Unschärfe bzw. „Glas kräftig“ → Material in der Karte.
            let clear = theme.blurFactor < 0.5 || !interactive
            let plain: Glass = clear ? (tint.map { Glass.clear.tint($0.opacity(amount)) } ?? .clear) : tinted
            let glass = interactive ? plain.interactive() : plain
            let dim = Color.black.opacity(clear && theme.isDark ? 0.18 : 0)
            if strong || theme.blurFactor > 1.5, let m = theme.material {
                content.background(shape.fill(m).opacity(strong ? 0.8 : 0.5)).glassEffect(glass, in: shape)
            } else {
                content.background(shape.fill(dim)).glassEffect(glass, in: shape)
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
