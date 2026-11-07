using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

namespace KlimacontrolTray;

/// Fensterhintergrund nach „Darstellung → Hintergrund“. Nur über `Theme.AttachWindow(window)` benutzen.
///
/// Ab Windows 11 22H2 (sonst deckend): „glass“ → Mica, mit Unschärfe ≥ `AcrylicFromBlur` Acrylic (Unschärfe lässt sich
/// nicht stufenlos einstellen); „glassStrong“ → Acrylic; „matte“ und Hoher Kontrast → deckend.
/// „Transparenz“ gilt nur für die Flächen über dem Material (`Theme.SurfaceAlpha`), dessen Durchsicht legt Windows fest.
/// WPF setzt bei jedem Wechsel von `ThemeMode` wieder Mica – darum ruft `Theme` danach `RefreshAll`.
/// Fenster mit `AllowsTransparency` bekommen kein DWM-Material, nur den Pinsel „Surface“ (siehe `Surface.cs`).
/// Acrylic zeigt Windows nur am aktiven Fenster.
static class Backdrop
{
    public enum Kind { Opaque, Mica, Acrylic }

    /// Ab dieser Unschärfe wird „glass“ zu Acrylic.
    public const int AcrylicFromBlur = 1;

    /// DWMWA_SYSTEMBACKDROP_TYPE gibt es ab Windows 11 22H2.
    public static bool Supported { get; } = Environment.OSVersion.Version.Build >= 22621;

    /// Material für eine Einstellung.
    public static Kind Choose(string background, int blur, bool supported, bool highContrast)
    {
        if (!supported || highContrast) return Kind.Opaque;
        return background switch
        {
            "matte" => Kind.Opaque,
            "glassStrong" => Kind.Acrylic,
            _ => blur >= AcrylicFromBlur ? Kind.Acrylic : Kind.Mica,
        };
    }

    public static Kind Current
    {
        get
        {
            var a = Appearance.Current;
            return Choose(a.Background, a.Blur, Supported, SystemParameters.HighContrast);
        }
    }

    static readonly HashSet<Window> windows = new();

    public static void Attach(Window w)
    {
        if (!windows.Add(w)) return;
        w.SourceInitialized += OnSourceInitialized;
        w.Loaded += OnLoaded;
        w.Closed += OnClosed;
        Apply(w);
    }

    static void OnSourceInitialized(object? sender, EventArgs e) { if (sender is Window w) Apply(w); }
    // WPF setzt sein Mica erst beim Erzeugen des Fensters; Loaded kommt danach und vor dem ersten Zeichnen.
    static void OnLoaded(object sender, RoutedEventArgs e) { if (sender is Window w) Apply(w); }

    static void OnClosed(object? sender, EventArgs e)
    {
        if (sender is not Window w) return;
        w.SourceInitialized -= OnSourceInitialized;
        w.Loaded -= OnLoaded;
        w.Closed -= OnClosed;
        windows.Remove(w);
    }

    /// Alle angeschlossenen Fenster neu einstellen (billig).
    public static void RefreshAll()
    {
        if (windows.Count == 0) return;
        foreach (var w in windows.ToArray()) Apply(w);
    }

    static void Apply(Window w)
    {
        try
        {
            if (w.AllowsTransparency)
            {
                // Randlos/transparent: kein DWM-Material möglich, nur der Fensterhintergrund.
                w.SetResourceReference(Control.BackgroundProperty, "Surface");
                return;
            }
            var kind = Current;
            var hwnd = new WindowInteropHelper(w).Handle;
            if (kind == Kind.Opaque) w.SetResourceReference(Control.BackgroundProperty, "Bg");
            else w.Background = Brushes.Transparent;
            if (hwnd == IntPtr.Zero || !Supported) return;

            var dark = Theme.Dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
            var source = HwndSource.FromHwnd(hwnd);
            if (kind == Kind.Opaque)
            {
                var none = DWMSBT_NONE;
                DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref none, sizeof(int));
                var zero = new Margins();
                DwmExtendFrameIntoClientArea(hwnd, ref zero);
                if (source?.CompositionTarget != null)
                    source.CompositionTarget.BackgroundColor = (w.TryFindResource("Bg") as SolidColorBrush)?.Color ?? SystemColors.WindowColor;
                return;
            }
            if (source?.CompositionTarget != null) source.CompositionTarget.BackgroundColor = Colors.Transparent;
            var all = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            DwmExtendFrameIntoClientArea(hwnd, ref all);
            var type = kind == Kind.Acrylic ? DWMSBT_TRANSIENTWINDOW : DWMSBT_MAINWINDOW;
            if (DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref type, sizeof(int)) != 0)
                w.SetResourceReference(Control.BackgroundProperty, "Bg"); // abgelehnt: sauber deckend
        }
        catch (Exception ex) { App.Trace("Fensterhintergrund: " + ex.GetType().Name); }
    }

    const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    const int DWMSBT_NONE = 1;
    const int DWMSBT_MAINWINDOW = 2;      // Mica
    const int DWMSBT_TRANSIENTWINDOW = 3; // Acrylic

    [StructLayout(LayoutKind.Sequential)]
    struct Margins { public int Left, Right, Top, Bottom; }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
}
