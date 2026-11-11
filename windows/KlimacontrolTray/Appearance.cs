using System;
using System.Collections.Generic;

namespace KlimacontrolTray;

/// Darstellung (Reiter „Darstellung“): alle Optionen an einer Stelle.
///
/// Oberflächen benutzen nur diese API:
/// - `Appearance.Current` – aktuelle Werte (nie null). `Appearance.Changed` – nach jeder Änderung (auf dem UI-Thread).
/// - `Appearance.Update(a => a with { Size = "large" })` – Wert ändern (wirkt sofort, wird im Kern gespeichert).
/// - `Appearance.ApplyTheme("night")` – Thema wählen (der Kern setzt die zugehörigen Werte). `Appearance.Reset()`.
/// - `Appearance.ReduceMotion` – Animationen aus (Option oder Windows-Einstellung „Animationseffekte“ aus).
///
/// Gespeichert wird im Kern, ebenso die Standardwerte und Themen. Die Werte heißen wie im Kern; umgerechnet werden
/// nur Transparenz und Leuchten (Prozent statt 0–1). Angezeigt werden nie diese Werte, sondern die deutschen Texte
/// wie am Mac (`Appearance.*.label` im Kern; geprüft in `AppearanceTextTests`).
/// Nur das Mini-Fenster ist kein Kernwert und steht in Prefs "MiniWindow".
///
/// Werte der C#-Seite:
/// - Theme: "standard" | "night" | "neon" | "minimal" | "contrast"
/// - Mode: "system" | "light" | "dark" · Colors: "byMode" (nach Modus) | "system" | "custom"; CustomColor: "orange" |
///   "blue" | "green" | "purple" | "gray"
/// - Background: "glass" | "glassStrong" | "matte" (Windows: Mica / Acrylic / deckend) · Transparency 0–95 (%) ·
///   Blur 0–40 · Glow 0–100 (%, Schein um die große Temperatur)
/// - Size: "compact" | "normal" | "large" · Digits: "thin" | "normal" | "bold" | "rounded" · BigValue: "target" | "room"
///   · Scope: "simple" | "all"
/// - LivingBackground, WeatherEffects, ReduceAnimations, AlwaysOnTop, MiniWindow (bool)
/// - TrayColored, TrayAnimated (bool) · TrayTooltip: "iconOnly" | "iconTarget" (Standard) | "iconRoom" | "roomTarget"
/// Die Vorgaben unten gelten nur bis zum ersten Schnappschuss des Kerns.
public sealed record AppearanceSettings
{
    public string Theme { get; init; } = "standard";
    public string Mode { get; init; } = "system";
    public string Colors { get; init; } = "byMode";
    public string CustomColor { get; init; } = "orange";
    public string Background { get; init; } = "glass";
    public int Transparency { get; init; } = 40;
    public int Blur { get; init; } = 20;
    public int Glow { get; init; } = 0;
    public string Size { get; init; } = "normal";
    public string Digits { get; init; } = "normal";
    public string BigValue { get; init; } = "target";
    public string Scope { get; init; } = "all";
    public bool LivingBackground { get; init; }
    public bool WeatherEffects { get; init; }
    public bool ReduceAnimations { get; init; }
    public bool AlwaysOnTop { get; init; }
    public bool MiniWindow { get; init; }
    public bool TrayColored { get; init; } = true;
    public bool TrayAnimated { get; init; }
    public string TrayTooltip { get; init; } = "iconTarget";
    public bool TemperatureCombined { get; init; }
}

static class Appearance
{
    static AppearanceSettings current = new() { MiniWindow = Prefs.GetBool("MiniWindow", false) };
    static bool subscribed;

    public static AppearanceSettings Current
    {
        get { EnsureSubscribed(); return current; }
    }

    /// Nach jeder Änderung (Option, Thema, Zurücksetzen, neuer Stand vom Kern).
    public static event Action? Changed;

    /// Animationen aus: eigene Option oder Windows „Animationseffekte“ aus.
    public static bool ReduceMotion => Current.ReduceAnimations || !System.Windows.SystemParameters.ClientAreaAnimation;

    public static void Update(Func<AppearanceSettings, AppearanceSettings> change)
    {
        var before = Current;
        var next = change(before);
        if (next == before) return;
        if (next.MiniWindow != before.MiniWindow) Prefs.SetBool("MiniWindow", next.MiniWindow);
        // Sofort zeigen (der Kern bestätigt mit dem nächsten Schnappschuss), dann nur die Kernwerte schicken.
        Set(next);
        if (ToCore(next) is var core && !SameCore(core, ToCore(before)))
        {
            var err = Core.Shared.Send(Cmd.Appearance, ("value", core));
            if (err != null) App.Trace("Darstellung nicht übernommen: " + err);
        }
    }

    /// Thema wählen: Der Kern setzt die Werte des Themas; der neue Stand kommt mit dem nächsten Schnappschuss.
    public static void ApplyTheme(string theme)
    {
        // Nur die Auswahl sofort zeigen (sonst spränge sie zurück, bis der Kern antwortet). Die Werte des Themas
        // setzt allein der Kern (Appearance.preset/applying); sie kommen mit dem nächsten Schnappschuss.
        Set(Current with { Theme = theme });
        var err = Core.Shared.Send(Cmd.AppearanceTheme, ("theme", theme));
        if (err != null) App.Trace("Thema nicht übernommen: " + err);
    }

    /// Zurücksetzen: Die Standardwerte kennt allein der Kern; sie kommen mit dem nächsten Schnappschuss (das lokale
    /// Mini-Fenster bleibt, wie bei jedem Stand vom Kern).
    public static void Reset()
    {
        var err = Core.Shared.Send(Cmd.AppearanceReset);
        if (err != null) App.Trace("Darstellung nicht zurückgesetzt: " + err);
    }

    static void EnsureSubscribed()
    {
        if (subscribed) return;
        subscribed = true;
        Core.Shared.Changed += FromCore;
        FromCore();
    }

    /// Neuer Schnappschuss: Kernwerte übernehmen (das lokale Mini-Fenster bleibt).
    static void FromCore()
    {
        if (Core.Shared.Snap.Appearance is not { } a) return;
        Set(FromCore(a) with { MiniWindow = current.MiniWindow });
    }

    static void Set(AppearanceSettings next)
    {
        if (next == current) return;
        current = next;
        Changed?.Invoke();
    }

    static AppearanceSettings FromCore(AppearanceInfo a) => new()
    {
        Theme = a.Theme,
        Mode = a.Scheme,
        Colors = a.Accent,
        CustomColor = a.CustomColor,
        Background = a.Background,
        Transparency = (int)Math.Round(Math.Clamp(a.Transparency, 0, 0.95) * 100),
        Blur = (int)Math.Round(Math.Clamp(a.Blur, 0, 40)),
        Glow = (int)Math.Round(Math.Clamp(a.Glow, 0, 1) * 100),
        Size = a.Size,
        Digits = a.Digits,
        BigValue = a.Hero,
        Scope = a.Scope,
        LivingBackground = a.Lively,
        WeatherEffects = a.Weather,
        ReduceAnimations = a.ReduceMotion,
        AlwaysOnTop = a.AlwaysOnTop,
        TrayColored = a.MenuBarColored,
        TrayAnimated = a.MenuBarAnimated,
        TrayTooltip = a.MenuBarText,
        TemperatureCombined = a.TemperatureCombined,
    };

    static Dictionary<string, object?> ToCore(AppearanceSettings s) => new()
    {
        ["theme"] = s.Theme,
        ["scheme"] = s.Mode,
        ["accent"] = s.Colors,
        ["customColor"] = s.CustomColor,
        ["background"] = s.Background,
        ["transparency"] = Math.Clamp(s.Transparency, 0, 95) / 100.0,
        ["blur"] = (double)Math.Clamp(s.Blur, 0, 40),
        ["glow"] = Math.Clamp(s.Glow, 0, 100) / 100.0,
        ["size"] = s.Size,
        ["digits"] = s.Digits,
        ["hero"] = s.BigValue,
        ["scope"] = s.Scope,
        ["lively"] = s.LivingBackground,
        ["weather"] = s.WeatherEffects,
        ["reduceMotion"] = s.ReduceAnimations,
        ["alwaysOnTop"] = s.AlwaysOnTop,
        ["menuBarText"] = s.TrayTooltip,
        ["menuBarColored"] = s.TrayColored,
        ["menuBarAnimated"] = s.TrayAnimated,
        ["temperatureCombined"] = s.TemperatureCombined,
    };

    static bool SameCore(Dictionary<string, object?> a, Dictionary<string, object?> b)
    {
        foreach (var (k, v) in a) if (!Equals(v, b[k])) return false;
        return true;
    }
}
