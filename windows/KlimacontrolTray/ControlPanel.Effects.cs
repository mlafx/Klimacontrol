using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Leuchten der großen Zahl, lebendiger Hintergrund, Wetter-Effekte und Neon-Kante.
public partial class ControlPanel
{
    /// Thema Neon: leuchtende Kanten an Kopfkarte und aktiven Kacheln (nicht bei Hohem Kontrast).
    static bool Neon => Appearance.Current.Theme == "neon" && !Theme.HighContrast;

    /// Ein Schein für die große Zahl (Leuchten 0–100 %); nur an diesem einen Element, Effekte kosten im Software-Zeichnen.
    readonly System.Windows.Media.Effects.DropShadowEffect glow = new() { ShadowDepth = 0 };

    /// Leuchten 0–100 %: weicher Schein in der Modusfarbe um die große Zahl, nur bei laufender Anlage mit aktuellen
    /// Werten. Bei 0 (oder Hohem Kontrast) gar kein Effekt – er kostet im Software-Zeichnen.
    void RenderGlow(Color tint, bool lit)
    {
        var g = Math.Clamp(Appearance.Current.Glow, 0, 100) / 100.0;
        if (!lit || g <= 0 || Theme.HighContrast)
        {
            if (TargetText.Effect != null) TargetText.Effect = null;
            return;
        }
        glow.Color = tint;
        glow.BlurRadius = Math.Round(6 + 24 * g);
        glow.Opacity = g * (Appearance.Current.Theme == "night" ? 0.5 : 0.9);
        if (!ReferenceEquals(TargetText.Effect, glow)) TargetText.Effect = glow;
    }

    /// Lebendiger Hintergrund und Wetter-Effekte (nur wenn die Anlage arbeitet: ein, aktuelle Werte und keine
    /// gemeldete Leistung von 0 W) und bei Neon die leuchtende Kante der Kopfkarte. Die Ebenen prüfen selbst
    /// „Animationen reduzieren“ und ob das Fenster sichtbar ist.
    void RenderEffects(AcState st, Color tint, bool onLive, AppearanceSettings look)
    {
        var working = Core.Snap.Working && !Theme.HighContrast; // gleiche Regel wie am Mac (ACController.isWorking)
        LivelyLayer.Show(working && look.LivingBackground, st.Mode, tint);
        WeatherLayer.Show(working && look.WeatherEffects, st.Mode, tint);
        var edge = Neon && onLive;
        HeroEdge.Visibility = edge ? Visibility.Visible : Visibility.Collapsed;
        if (!edge) return;
        EdgeLine.BorderBrush = Paints.Of(Color.FromArgb(0xE6, tint.R, tint.G, tint.B));
        EdgeHalo1.BorderBrush = Paints.Of(Color.FromArgb(0x48, tint.R, tint.G, tint.B));
        EdgeHalo2.BorderBrush = Paints.Of(Color.FromArgb(0x1C, tint.R, tint.G, tint.B));
    }
}
