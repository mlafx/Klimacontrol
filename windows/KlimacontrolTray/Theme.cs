using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// Farben, Schrift und Fensterhintergrund nach Windows (hell/dunkel, Hoher Kontrast, Akzentfarbe) und nach
/// „Darstellung“ (`Appearance`).
///
/// - `Apply(app)` setzt die Pinsel (Bg, Card, Tile, Surface, Fg, Sub, Line, Edge, Accent, Ok, Warn, Bad, BadBg),
///   Schriftgrößen (FontSize…) und Ziffernschrift (DigitFont…) in `app.Resources`. Darum mit `{DynamicResource …}`
///   bzw. `SetResourceReference` benutzen; wer Werte im Code holt, hört auf `Changed`.
/// - `Watch(app)` folgt Windows-Wechseln und `Appearance.Changed` und löst danach `Changed` auf dem UI-Thread aus.
/// - `Changed` kommt nicht bei Hintergrund/Transparenz/Unschärfe – die wirken nur über Ressourcen und `AttachWindow`
///   (sonst zeichnete z. B. der Verlauf bei jedem Reglerschritt neu). Abonnenten melden sich beim Schließen ab.
/// - Bei Hohem Kontrast gelten immer die Systemfarben, Thema/Farben/Material nicht.
/// - `ActiveFill`/`ActiveFillBrush`/`ActiveText`: Flächen in Modusfarbe mit weißer Schrift (mindestens 4,5:1).
/// - `Accent(modeTint)`: Farbe nach „Farben“ und Thema. Bei „Eigene“ und den Themen Nacht/Neon/Minimal werden auch die
///   Fluent-Akzentpinsel umgefärbt, sonst bleibt Fluent bei Windows.
/// - `SizeFactor` skaliert nur Schriften; Abstände skaliert der Aufrufer selbst.
/// - Formen wie am Mac (`ThemeStyle.cardRadius`/`innerRadius`): Ressourcen `CardRadius`, `InnerRadius` (CornerRadius)
///   und `CardPadding` (Thickness), im Code `Theme.CardCorner`, `Theme.InnerCorner`, `Theme.CardInset`. Fest, unabhängig
///   von Thema, Größe und Hohem Kontrast; eine Karte liegt auf dem Fenster, darin nur `Tile`-Flächen (kein Glas auf Glas).
/// - `EdgeGlow` (Neon): Effekte kosten beim Software-Zeichnen spürbar CPU – nur an wenigen, ruhigen Flächen setzen.
static class Theme
{
    /// Windows-Einstellung „App-Modus“ dunkel.
    public static bool SystemDark
    {
        get
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
            }
            catch { return false; }
        }
    }

    /// Wirksam dunkel: Modus „Dunkel“, oder „System“ und Windows dunkel.
    public static bool Dark => EffectiveDark(Appearance.Current.Mode, SystemDark);

    internal static bool EffectiveDark(string mode, bool systemDark) => mode switch
    {
        "light" => false,
        "dark" => true,
        _ => systemDark,
    };

    public static bool HighContrast => SystemParameters.HighContrast;

    /// Nach einem Wechsel hell/dunkel, Hoher Kontrast, Farben, Thema, Größe, Ziffernstil.
    public static event Action? Changed;

    internal static void RaiseChanged() => Changed?.Invoke();

    static Application? watched;
    static UserPreferenceChangedEventHandler? onPreference;
    static bool pending;
    static (bool Dark, bool HighContrast, Color Accent) applied;
    static string appliedLook = "";

    /// Folgt Windows-Wechseln und der Darstellung. Mehrfacher Aufruf schadet nicht.
    public static void Watch(Application app)
    {
        if (watched != null) return;
        watched = app;
        applied = SystemState();
        onPreference = (_, e) =>
        {
            if (e.Category is not (UserPreferenceCategory.General or UserPreferenceCategory.Color
                                   or UserPreferenceCategory.VisualStyle or UserPreferenceCategory.Accessibility)) return;
            // Windows meldet einen Wechsel oft mehrfach hintereinander (und nicht auf dem UI-Thread): einmal nachziehen.
            if (pending) return;
            pending = true;
            app.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(Refresh));
        };
        SystemEvents.UserPreferenceChanged += onPreference;
        Appearance.Changed += OnAppearance;
        app.Exit += (_, _) => Unwatch();
    }

    static void Unwatch()
    {
        if (onPreference != null) SystemEvents.UserPreferenceChanged -= onPreference;
        onPreference = null;
        Appearance.Changed -= OnAppearance;
        watched = null;
    }

    /// Hell/dunkel, Hoher Kontrast, Akzentfarbe. Akzent aus der Registry: WPF zieht `SystemColors.AccentColor` erst über
    /// Fenster-Nachrichten nach.
    static (bool, bool, Color) SystemState() => (SystemDark, HighContrast, SystemAccent);

    /// Windows-Akzentfarbe (Registry „AccentColorMenu“, sonst `SystemColors.AccentColor`).
    public static Color SystemAccent
    {
        get
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Accent");
                if (k?.GetValue("AccentColorMenu") is int abgr)
                    return Color.FromRgb((byte)abgr, (byte)(abgr >> 8), (byte)(abgr >> 16));
            }
            catch { }
            return SystemColors.AccentColor;
        }
    }

    static void Refresh()
    {
        pending = false;
        var app = watched;
        if (app == null) return;
        var now = SystemState();
        if (now == applied)
        {
            // WPF setzt bei manchen Systemmeldungen sein Mica neu; das Material der Fenster billig nachziehen.
            Backdrop.RefreshAll();
            return;
        }
        applied = now;
        try
        {
            // Fluent folgt Windows nur über Nachrichten an offene Fenster. Ohne offenes Fenster kurz fest setzen und
            // zurück auf „System“, dann lädt WPF die Fluent-Farben neu – vor Apply, das die neuen Akzentpinsel liest.
            if (app.ThemeMode == ThemeMode.System)
            {
                app.ThemeMode = now.Item1 ? ThemeMode.Dark : ThemeMode.Light;
                app.ThemeMode = ThemeMode.System;
            }
            Apply(app);
        }
        catch (Exception ex) { App.Trace("Hell/Dunkel nachziehen: " + ex.GetType().Name); }
        RaiseChanged();
    }

    static void OnAppearance()
    {
        var app = watched;
        if (app == null) return;
        try
        {
            if (Look(Appearance.Current) != appliedLook)
            {
                Apply(app);
                RaiseChanged();
                return;
            }
            // Nur Hintergrund/Transparenz/Unschärfe (oder etwas, das Theme nicht betrifft): Flächen und Fenster.
            ApplySurfaces(app);
            Backdrop.RefreshAll();
        }
        catch (Exception ex) { App.Trace("Darstellung anwenden: " + ex.GetType().Name); }
    }

    /// Alles, was Farben/Schrift/Modus bestimmt (ohne Hintergrund, Transparenz, Unschärfe).
    static string Look(AppearanceSettings a) => string.Join("|", a.Theme, a.Mode, a.Colors, a.CustomColor, a.Size, a.Digits);

    /// Fenster an die Darstellung anschließen (Material, Transparenz, Rahmen); einmal im Konstruktor aufrufen.
    public static void AttachWindow(Window w) => Backdrop.Attach(w);

    static readonly Dictionary<Color, Color> accents = new();

    /// Akzentfarbe nach Darstellung („Farben“: nach Modus → `modeTint`, Systemfarbe, eigene Farbe; dazu das Thema).
    public static Color Accent(Color modeTint)
    {
        if (HighContrast) return SystemColors.HighlightColor;
        if (accents.TryGetValue(modeTint, out var known)) return known;
        var a = Appearance.Current;
        var c = BaseAccent(a, modeTint, Dark);
        c = ThemeTint(c, a.Theme);
        if (accents.Count > 64) accents.Clear();
        accents[modeTint] = c;
        return c;
    }

    static Color BaseAccent(AppearanceSettings a, Color modeTint, bool dark) => a.Colors switch
    {
        "system" => SystemAccent,
        "custom" => CustomColor(a.CustomColor, dark),
        _ => modeTint,
    };

    /// Eigene Farben wie am Mac (Systemfarben von macOS, hell/dunkel).
    internal static Color CustomColor(string name, bool dark) => name switch
    {
        "orange" => dark ? Rgb(0xFF, 0x9F, 0x0A) : Rgb(0xFF, 0x95, 0x00),
        "green" => dark ? Rgb(0x30, 0xD1, 0x58) : Rgb(0x34, 0xC7, 0x59),
        "purple" => dark ? Rgb(0xBF, 0x5A, 0xF2) : Rgb(0xAF, 0x52, 0xDE),
        "grey" or "gray" => dark ? Rgb(0x98, 0x98, 0x9D) : Rgb(0x8E, 0x8E, 0x93),
        _ => dark ? Rgb(0x0A, 0x84, 0xFF) : Rgb(0x00, 0x7A, 0xFF),
    };

    /// Reihenfarbe eines Graphen im Thema (wie `ThemeStyle.series` am Mac); im Kontrastmodus die Systemfarbe.
    public static Color Series(Color c) =>
        HighContrast ? SystemColors.WindowTextColor : ThemeTint(c, Appearance.Current.Theme);

    /// Vordergrundfarbe des Themas (Ressource „Fg“).
    public static Color Foreground =>
        Application.Current?.TryFindResource("Fg") is SolidColorBrush b ? b.Color : (Dark ? Colors.White : Colors.Black);

    /// Abwandlung je Thema: Nacht gedimmt und weniger satt, Neon kräftig und hell, Minimal fast farblos.
    internal static Color ThemeTint(Color c, string theme)
    {
        if (theme is not ("night" or "neon" or "minimal")) return c;
        var (h, s, v) = ToHsv(c);
        switch (theme)
        {
            case "night": s *= 0.8; v *= 0.72; break;
            case "neon": s = Math.Min(1, s * 1.35 + 0.1); v = Math.Max(v, 0.95); break;
            case "minimal": s *= 0.3; break;
        }
        return FromHsv(h, s, v, c.A);
    }

    /// Radius der großen Karten (Kopf, Modus und Lüfter, Szenen und Timer, Verlauf, Verbrauch).
    public const double CardRadius = 20;
    /// Radius der Elemente in einer Karte (Modus-Knöpfe, Szenen, Timer, Kacheln).
    public const double InnerRadius = 12;
    /// Innenabstand einer Karte.
    public const double CardPadding = 16;

    public static CornerRadius CardCorner => new(CardRadius);
    public static CornerRadius InnerCorner => new(InnerRadius);
    public static Thickness CardInset => new(CardPadding);

    /// Formen als Ressourcen; gleiche Werte bleiben stehen, damit DynamicResource-Nutzer nicht neu zeichnen.
    internal static void ApplyShapes(ResourceDictionary r)
    {
        void Put(string key, object value) { if (!Equals(r[key], value)) r[key] = value; }
        Put("CardRadius", CardCorner);
        Put("InnerRadius", InnerCorner);
        Put("CardPadding", CardInset);
    }

    /// Schriftfaktor für „Größe“: compact 0,9 · normal 1 · large 1,15 (Abstände skaliert der Aufrufer selbst).
    public static double SizeFactor => SizeFactorFor(Appearance.Current.Size);

    internal static double SizeFactorFor(string size) => size switch
    {
        "compact" => 0.9,
        "large" => 1.15,
        _ => 1.0,
    };

    static readonly FontFamily Variable = new("Segoe UI Variable Display, Segoe UI");
    static readonly FontFamily Rounded = new("Arial Rounded MT Bold, Arial Rounded MT, Segoe UI Variable Display, Segoe UI");

    /// Schrift der großen Temperatur nach „Ziffernstil“, immer frisch aus `Appearance.Current` (auch für eine Vorschau).
    public static (FontFamily Family, FontWeight Weight) DigitFont => DigitFontFor(Appearance.Current.Digits);

    /// Standardschrift der App (Fluent), sonst die Windows-Meldungsschrift.
    static FontFamily DefaultFont =>
        Application.Current?.TryFindResource("ContentControlThemeFontFamily") as FontFamily ?? SystemFonts.MessageFontFamily;

    internal static (FontFamily Family, FontWeight Weight) DigitFontFor(string digits) => digits switch
    {
        "thin" => (Variable, FontWeights.Light),
        "bold" => (DefaultFont, FontWeights.SemiBold),
        "rounded" => (Rounded, FontWeights.Normal),
        _ => (DefaultFont, FontWeights.Light),
    };

    /// Deckkraft der Flächen (Card, Tile, Surface) über dem Material: Matt deckend, sonst 1 − Transparenz.
    public static byte SurfaceAlpha(string background, int transparency)
    {
        if (background == "matte") return 255;
        var t = Math.Clamp(transparency, 0, 95);
        return (byte)Math.Round(255 * (1 - t / 100.0));
    }

    /// Neon: leuchtende Kanten an. Sonst (und bei Hohem Kontrast) aus.
    public static bool Glowing => !HighContrast && Appearance.Current.Theme == "neon";

    static readonly Dictionary<Color, DropShadowEffect> glows = new();
    static readonly Dictionary<Color, SolidColorBrush> edgeBrushes = new();

    /// Schein um eine Karte bei Neon (eingefroren, je Farbe ein Objekt), sonst null.
    public static Effect? EdgeGlow(Color tint)
    {
        if (!Glowing) return null;
        var c = Accent(tint);
        if (!glows.TryGetValue(c, out var e))
        {
            e = new DropShadowEffect { Color = c, BlurRadius = 14, ShadowDepth = 0, Opacity = 0.7, RenderingBias = RenderingBias.Performance };
            e.Freeze();
            glows[c] = e;
        }
        return e;
    }

    /// Leuchtender Rahmen bei Neon (eingefroren), sonst null (dann „Line“ bzw. „Edge“ lassen).
    public static Brush? EdgeGlowBrush(Color tint)
    {
        if (!Glowing) return null;
        var c = Mix(Accent(tint), Colors.White, Dark ? 0.15 : 0);
        if (!edgeBrushes.TryGetValue(c, out var b))
        {
            b = new SolidColorBrush(c);
            b.Freeze();
            edgeBrushes[c] = b;
        }
        return b;
    }

    internal readonly record struct Palette(Color Bg, Color Card, Color Tile, Color Fg, Color Sub, Color Line, Color Accent,
                                            Color Ok, Color Warn, Color Bad, Color BadBg, Color Edge);

    static Palette P(string bg, string card, string tile, string fg, string sub, string line, string accent,
                     string ok, string warn, string bad, string badBg, string? edge = null)
        => new(Hex(bg), Hex(card), Hex(tile), Hex(fg), Hex(sub), Hex(line), Hex(accent), Hex(ok), Hex(warn), Hex(bad),
               Hex(badBg), Hex(edge ?? line));

    /// Farben eines Themas (die Platzhalter in App.xaml tragen die hellen Standardwerte).
    internal static Palette PaletteFor(string theme, bool dark) => (theme, dark) switch
    {
        // Nacht: gedimmt, warm-dunkle Flächen, gedämpfte Schrift, kühler Akzent statt Rot/Orange.
        ("night", true) => P("#14110F", "#1A1614", "#241F1B", "#CFC6BA", "#8F867B", "#2E2823", "#8FA9C9",
                             "#6E9F68", "#B59A4A", "#B8736F", "#2A1C1A"),
        ("night", false) => P("#EDE7DE", "#F1ECE4", "#E4DDD2", "#3A332C", "#6A6157", "#D6CEC2", "#3F5F86",
                              "#3F6E3A", "#7A5A12", "#8E3A33", "#F0DCD6"),
        // Neon: tiefe Flächen, kräftige Farben, leuchtende Kanten („Edge“).
        ("neon", true) => P("#0A0A12", "#10101C", "#191928", "#FFFFFF", "#B4B4D6", "#2E2A55", "#00E5FF",
                            "#39FF88", "#FFE14D", "#FF4D8D", "#3A0F22", "#A35CFF"),
        ("neon", false) => P("#F6F5FF", "#FFFFFF", "#ECEAFF", "#0E0E1A", "#4B4B6E", "#CFC6FF", "#6A00F4",
                             "#00873E", "#8A6A00", "#D0004F", "#FFE3EE", "#8A5CFF"),
        // Minimal: fast farblos, leise Linien.
        ("minimal", true) => P("#1C1C1C", "#202020", "#282828", "#E4E4E4", "#8E8E8E", "#2C2C2C", "#B0B0B0",
                               "#8FB38F", "#C8B27A", "#D69A94", "#33262A"),
        ("minimal", false) => P("#FAFAFA", "#FFFFFF", "#F4F4F4", "#262626", "#707070", "#EEEEEE", "#5E5E5E",
                                "#4F7A4F", "#806A3A", "#A04A44", "#F6E9E8"),
        // Kontrast: deckend, Schwarz/Weiß, deutliche Linien (WCAG AA und mehr).
        ("contrast", true) => P("#000000", "#000000", "#1C1C1C", "#FFFFFF", "#E6E6E6", "#9A9A9A", "#7FD7FF",
                                "#7CE07C", "#FFE45C", "#FF9EA8", "#3A0008"),
        ("contrast", false) => P("#FFFFFF", "#FFFFFF", "#F0F0F0", "#000000", "#1F1F1F", "#5A5A5A", "#003E92",
                                 "#0B5D0B", "#6B3F00", "#A0140B", "#FFE5E5"),
        // Standard: Werte wie die Windows-11-Flächen (Flyout, Karte, Text, Trennlinie) in hell und dunkel.
        (_, true) => P("#2C2C2C", "#2B2B2B", "#383838", "#FFFFFF", "#C5C5C5", "#3F3F3F", "#60CDFF",
                       "#6CCB5F", "#FCE100", "#FF99A4", "#442726"),
        // Sub hell: #505050 statt Fluent-Grau #616161, damit Nebentext auch auf der getönten großen Karte klar lesbar bleibt.
        _ => P("#F9F9F9", "#FBFBFB", "#F3F3F3", "#1B1B1B", "#505050", "#E5E5E5", "#005FB8",
               "#0F7B0F", "#9D5D00", "#C42B1C", "#FDE7E9"),
    };

    static Palette palette = PaletteFor("standard", false);

    /// Fluent-Modus nach „Modus“; bei Hohem Kontrast immer System (dann wählt WPF das Kontrastdesign).
    internal static ThemeMode ThemeModeFor(string mode, bool highContrast)
    {
        if (highContrast) return ThemeMode.System;
        return mode switch { "light" => ThemeMode.Light, "dark" => ThemeMode.Dark, _ => ThemeMode.System };
    }

    public static void Apply(Application app)
    {
        var a = Appearance.Current;
        var hc = HighContrast;
        var dark = Dark;
        appliedLook = Look(a);
        accents.Clear();

        var mode = ThemeModeFor(a.Mode, hc);
        if (app.ThemeMode != mode) app.ThemeMode = mode;

        ApplyFonts(app);
        ApplyShapes(app.Resources);

        void Sys(string key, SolidColorBrush brush) => app.Resources[key] = brush;
        if (hc)
        {
            // Hoher Kontrast: nur Systemfarben, damit das gewählte Kontrastdesign gilt.
            Sys("Bg", SystemColors.WindowBrush);
            Sys("Card", SystemColors.WindowBrush);
            Sys("Tile", SystemColors.ControlBrush);
            Sys("Surface", SystemColors.WindowBrush);
            Sys("Fg", SystemColors.WindowTextBrush);
            Sys("Sub", SystemColors.WindowTextBrush);
            Sys("Line", SystemColors.WindowTextBrush);
            Sys("Edge", SystemColors.WindowTextBrush);
            Sys("Accent", SystemColors.HotTrackBrush);
            Sys("Ok", SystemColors.WindowTextBrush);
            Sys("Warn", SystemColors.WindowTextBrush);
            Sys("Bad", SystemColors.WindowTextBrush);
            Sys("BadBg", SystemColors.WindowBrush);
            ApplyFluentAccent(app, null, dark);
            Backdrop.RefreshAll();
            return;
        }

        palette = PaletteFor(a.Theme, dark);
        var p = palette;
        Set(app, "Bg", p.Bg);
        Set(app, "Fg", p.Fg);
        Set(app, "Sub", p.Sub);
        Set(app, "Line", p.Line);
        Set(app, "Edge", p.Edge);
        Set(app, "Ok", p.Ok);
        Set(app, "Warn", p.Warn);
        Set(app, "Bad", p.Bad);
        Set(app, "BadBg", p.BadBg);

        // „Accent“ (Linien, Symbole, Links): nach „Farben“, mit Thema, lesbar auf Bg.
        var accent = a.Colors switch
        {
            "system" => dark ? Mix(SystemAccent, Colors.White, 0.45) : FillForWhite(SystemAccent),
            "custom" => CustomColor(a.CustomColor, dark),
            _ => p.Accent,
        };
        if (a.Colors != "byMode") accent = ThemeTint(accent, a.Theme);
        Set(app, "Accent", Readable(accent, p.Bg, 4.5));

        ApplySurfaces(app);

        // Fluent-Akzent (Schalter, Häkchen, Regler, Primary-Knöpfe) nur umfärben, wenn er vom Windows-Akzent abweicht.
        Color? fluent = a.Colors == "custom" || a.Theme is "night" or "neon" or "minimal"
            ? ThemeTint(a.Colors == "custom" ? CustomColor(a.CustomColor, dark) : SystemAccent, a.Theme)
            : null;
        ApplyFluentAccent(app, fluent, dark);

        Backdrop.RefreshAll();
    }

    /// Flächen mit der Deckkraft aus „Transparenz“ (Card, Tile, Surface). Billig: nur drei Pinsel.
    static void ApplySurfaces(Application app)
    {
        if (HighContrast) return;
        var a = Appearance.Current;
        var alpha = SurfaceAlpha(a.Background, a.Transparency);
        Set(app, "Card", WithAlpha(palette.Card, alpha));
        Set(app, "Tile", WithAlpha(palette.Tile, alpha));
        Set(app, "Surface", WithAlpha(palette.Bg, alpha));
    }

    static void ApplyFonts(Application app)
    {
        var f = SizeFactor;
        var digitFont = DigitFont;
        void Size(string key, double pt) => app.Resources[key] = Math.Round(pt * f * 2) / 2;
        Size("FontSizeCaption", 11);
        Size("FontSizeSmall", 12);
        Size("FontSizeBody", 13);
        Size("FontSizeNormal", 14);
        Size("FontSizeLarge", 17);
        Size("FontSizeTitle", 20);
        Size("FontSizeHero", 64);
        app.Resources["DigitFontFamily"] = digitFont.Family;
        app.Resources["DigitFontWeight"] = digitFont.Weight;
    }

    static void Set(Application app, string key, Color c)
    {
        // Gleiche Farbe: alten Pinsel lassen, sonst zeichnen alle DynamicResource-Nutzer neu.
        if (app.Resources[key] is SolidColorBrush old && old.IsFrozen && old.Color == c) return;
        var b = new SolidColorBrush(c);
        b.Freeze();
        app.Resources[key] = b;
    }

    /// Fluent-Pinsel aus der Windows-Akzentfarbe (Liste aus .NET 10.0.14). Ihre Abstufung liest `ApplyFluentAccent`
    /// zur Laufzeit aus dem Fluent-Wörterbuch.
    static readonly string[] FluentAccentKeys =
    {
        "AccentButtonBackground", "AccentButtonBackgroundPointerOver", "AccentButtonBackgroundPressed",
        "AccentFillColorDefaultBrush", "AccentFillColorSecondaryBrush", "AccentFillColorTertiaryBrush",
        "AccentFillColorSelectedTextBackgroundBrush", "AccentTextFillColorPrimaryBrush",
        "AccentTextFillColorSecondaryBrush", "AccentTextFillColorTertiaryBrush",
        "CalendarViewSelectedBackground", "CalendarViewSelectedBorderBrush", "CalendarViewTodayBackground",
        "CheckBoxCheckBackgroundFillChecked", "CheckBoxCheckBackgroundFillCheckedPointerOver",
        "CheckBoxCheckBackgroundFillCheckedPressed", "CheckBoxCheckBackgroundFillIndeterminate",
        "CheckBoxCheckBackgroundFillIndeterminatePointerOver", "CheckBoxCheckBackgroundFillIndeterminatePressed",
        "CheckBoxCheckBackgroundStrokeChecked", "CheckBoxCheckBackgroundStrokeCheckedPointerOver",
        "CheckBoxCheckBackgroundStrokeCheckedPressed", "CheckBoxCheckBackgroundStrokeIndeterminate",
        "CheckBoxCheckBackgroundStrokeIndeterminatePointerOver", "CheckBoxCheckBackgroundStrokeIndeterminatePressed",
        "ComboBoxBorderBrushFocused", "ComboBoxItemPillFillBrush", "DataGridRowSelectedBackgroundThemeBrush",
        "DatePickerBorderBrushFocused", "DatePickerFocusedBorderBrush",
        "HyperlinkButtonForeground", "HyperlinkButtonForegroundPointerOver", "HyperlinkButtonForegroundPressed",
        "HyperlinkForeground", "HyperlinkForegroundPointerOver", "InfoBarInformationalSeverityIconBackground",
        "ListBoxItemBackgroundSelectedPressedThemeBrush", "ListBoxItemSelectedBackgroundPointerOverThemeBrush",
        "ListBoxItemSelectedBackgroundPressedThemeBrush", "ListBoxItemSelectedBackgroundThemeBrush",
        "ListViewItemPillFillBrush", "NavigationViewSelectionIndicatorForeground", "ProgressBarForeground",
        "ProgressRingForegroundThemeBrush", "RadioButtonCheckOuterEllipseCheckedFillPointerOver",
        "RadioButtonCheckOuterEllipseCheckedFillPressed", "RadioButtonCheckOuterEllipseCheckedStrokePressed",
        "RadioButtonOuterEllipseCheckedFill", "RadioButtonOuterEllipseCheckedStroke",
        "RadioButtonOuterEllipseCheckedStrokePointerOver", "RatingControlSelectedForeground",
        "SliderThumbBackground", "SliderThumbBackgroundPointerOver", "SystemFillColorAttentionBrush",
        "TextControlFocusedBorderBrush", "TextControlSelectionHighlightColor", "ThumbRateForeground",
        "ToggleButtonBackgroundChecked", "ToggleButtonBackgroundCheckedPointerOver", "ToggleButtonBackgroundCheckedPressed",
        "ToggleSwitchFillOn", "ToggleSwitchFillOnPointerOver", "ToggleSwitchStrokeOn", "ToggleSwitchStrokeOnPointerOver",
        "TreeViewItemSelectionIndicatorForeground",
    };

    static bool fluentOverridden;

    /// Fluent-Akzentpinsel auf `baseColor` umstellen (null = zurück zu Windows). Die eigenen Pinsel liegen oben in
    /// `app.Resources` und überdecken das Fluent-Wörterbuch; dessen Pinsel bleiben unverändert.
    static void ApplyFluentAccent(Application app, Color? baseColor, bool dark)
    {
        if (fluentOverridden)
        {
            foreach (var k in FluentAccentKeys) app.Resources.Remove(k);
            fluentOverridden = false;
        }
        if (baseColor is not { } b) return;
        ResourceDictionary? fluent = null;
        foreach (var d in app.Resources.MergedDictionaries)
            if (d.Source?.OriginalString.Contains("PresentationFramework.Fluent", StringComparison.OrdinalIgnoreCase) == true) fluent = d;
        if (fluent == null) return;

        var family = new Dictionary<Color, Color>
        {
            [Opaque(SystemColors.AccentColorDark3)] = Scale(FillForWhite(b), 0.62),
            [Opaque(SystemColors.AccentColorDark2)] = Scale(FillForWhite(b), 0.8),
            [Opaque(SystemColors.AccentColorDark1)] = FillForWhite(b),
            [Opaque(SystemColors.AccentColorLight3)] = Mix(FillForBlack(b), Colors.White, 0.45),
            [Opaque(SystemColors.AccentColorLight2)] = FillForBlack(b),
            [Opaque(SystemColors.AccentColorLight1)] = Mix(b, Colors.White, 0.25),
            [Opaque(SystemColors.AccentColor)] = b, // zuletzt: gewinnt, falls zwei Abstufungen gleich sind
        };
        foreach (var k in FluentAccentKeys)
        {
            if (!fluent.Contains(k) || fluent[k] is not SolidColorBrush orig) continue;
            if (!family.TryGetValue(Opaque(orig.Color), out var c)) continue;
            var nb = new SolidColorBrush(Color.FromArgb(orig.Color.A, c.R, c.G, c.B)) { Opacity = orig.Opacity };
            nb.Freeze();
            app.Resources[k] = nb;
            fluentOverridden = true;
        }
    }

    /// Abgedunkelt, bis weiße Schrift 4,5:1 erreicht (Fluent hell: weiße Schrift auf Akzentflächen).
    static Color FillForWhite(Color c)
    {
        var x = Opaque(c);
        for (var f = 1.0; Contrast(x, Colors.White) < 4.5 && f > 0; f -= 0.02) x = Scale(Opaque(c), f);
        return x;
    }

    /// Aufgehellt, bis schwarze Schrift 8:1 erreicht (Fluent dunkel: schwarze Schrift auf Akzentflächen).
    static Color FillForBlack(Color c)
    {
        var x = Opaque(c);
        for (var t = 0.0; Contrast(x, Colors.Black) < 8 && t <= 1; t += 0.04) x = Mix(Opaque(c), Colors.White, t);
        return x;
    }

    /// Farbe zum Hintergrund hin abgedunkelt bzw. aufgehellt, bis sie `ratio` erreicht.
    internal static Color Readable(Color c, Color bg, double ratio)
    {
        var target = Luminance(bg) > 0.4 ? Colors.Black : Colors.White;
        var x = Opaque(c);
        for (var t = 0.0; Contrast(x, bg) < ratio && t <= 1; t += 0.04) x = Mix(Opaque(c), target, t);
        return x;
    }

    static readonly Dictionary<Color, Color> fills = new();
    static readonly Dictionary<Color, SolidColorBrush> fillBrushes = new();

    /// Modusfarbe so weit abgedunkelt, dass weiße Schrift darauf mindestens 4,5:1 erreicht.
    public static Color ActiveFill(Color tint)
    {
        if (HighContrast) return SystemColors.HighlightColor;
        if (fills.TryGetValue(tint, out var known)) return known;
        var c = tint;
        for (var f = 1.0; Contrast(c, Colors.White) < 4.5 && f > 0; f -= 0.02)
            c = Color.FromArgb(255, (byte)Math.Round(tint.R * f), (byte)Math.Round(tint.G * f), (byte)Math.Round(tint.B * f));
        fills[tint] = c;
        return c;
    }

    /// `ActiveFill` als eingefrorener Pinsel (gleiche Farbe = gleiches Objekt, dann zeichnet WPF nichts neu).
    public static SolidColorBrush ActiveFillBrush(Color tint)
    {
        if (HighContrast) return SystemColors.HighlightBrush;
        if (!fillBrushes.TryGetValue(tint, out var b))
        {
            b = new SolidColorBrush(ActiveFill(tint));
            b.Freeze();
            fillBrushes[tint] = b;
        }
        return b;
    }

    /// Modusfarbe als Schrift auf der getönten großen Karte (Modusfarbe mit 25 % über Card): im Hellen so weit
    /// abgedunkelt, dass `ratio` erreicht wird (große Zahl 3, kleine Schrift 4,5); im Dunkeln unverändert.
    public static Color TextTint(Color tint, double ratio)
    {
        if (HighContrast || Dark) return tint;
        return TextTintOn(tint, palette.Bg, ratio);
    }

    /// Wie `TextTint`, gerechnet gegen den dunkleren hellen Grund (Fenster `Bg` statt der helleren Karte), damit es auch auf
    /// getöntem Glas über einem nicht ganz weißen Fenster reicht.
    internal static Color TextTintOn(Color tint, Color ground, double ratio) =>
        Readable(tint, Mix(ground, tint, 0x40 / 255.0), ratio);

    /// Schrift auf `ActiveFill`-Flächen.
    public static Brush ActiveText => HighContrast ? SystemColors.HighlightTextBrush : Brushes.White;

    /// Kontrastverhältnis nach WCAG 2 (1 = gleich, 21 = schwarz/weiß).
    public static double Contrast(Color a, Color b)
    {
        double la = Luminance(a), lb = Luminance(b);
        return (Math.Max(la, lb) + 0.05) / (Math.Min(la, lb) + 0.05);
    }

    static double Luminance(Color c)
    {
        static double Lin(byte v)
        {
            var s = v / 255.0;
            return s <= 0.04045 ? s / 12.92 : Math.Pow((s + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Lin(c.R) + 0.7152 * Lin(c.G) + 0.0722 * Lin(c.B);
    }

    static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);
    static Color Hex(string s) => (Color)ColorConverter.ConvertFromString(s);
    static Color Opaque(Color c) => Color.FromRgb(c.R, c.G, c.B);
    static Color WithAlpha(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);

    static Color Scale(Color c, double f) =>
        Color.FromArgb(c.A, (byte)Math.Round(c.R * f), (byte)Math.Round(c.G * f), (byte)Math.Round(c.B * f));

    internal static Color Mix(Color a, Color b, double t)
    {
        t = Math.Clamp(t, 0, 1);
        byte M(byte x, byte y) => (byte)Math.Round(x + (y - x) * t);
        return Color.FromArgb(a.A, M(a.R, b.R), M(a.G, b.G), M(a.B, b.B));
    }

    static (double H, double S, double V) ToHsv(Color c)
    {
        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), d = max - min;
        double h = d == 0 ? 0 : max == r ? 60 * (((g - b) / d) % 6) : max == g ? 60 * ((b - r) / d + 2) : 60 * ((r - g) / d + 4);
        if (h < 0) h += 360;
        return (h, max == 0 ? 0 : d / max, max);
    }

    static Color FromHsv(double h, double s, double v, byte alpha)
    {
        s = Math.Clamp(s, 0, 1);
        v = Math.Clamp(v, 0, 1);
        double c = v * s, x = c * (1 - Math.Abs(h / 60 % 2 - 1)), m = v - c;
        var (r, g, b) = (h % 360) switch
        {
            < 60 => (c, x, 0.0),
            < 120 => (x, c, 0.0),
            < 180 => (0.0, c, x),
            < 240 => (0.0, x, c),
            < 300 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        byte B(double t) => (byte)Math.Round((t + m) * 255);
        return Color.FromArgb(alpha, B(r), B(g), B(b));
    }
}
