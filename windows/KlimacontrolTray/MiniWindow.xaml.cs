using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Kleines, schwebendes Fenster mit großer Temperatur und Ein/Aus, immer im Vordergrund, nicht in Taskleiste und
/// Alt+Tab. Meldet sich als sichtbare Oberfläche „mini“, damit der Kern regelmäßig abfragt.
public partial class MiniWindow : Window
{
    const string PosPref = "MiniWindowPos";
    /// Abstand zur Ecke des Arbeitsbereichs beim ersten Öffnen (WPF-Einheiten).
    const double DefaultGap = 24;
    readonly DispatcherTimer saveTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    (Color, int)? glowKey;

    public MiniWindow()
    {
        InitializeComponent();
        Icon = TrayIcon.WindowIcon();
        PowerButton.Content = Icons.Make(Icons.Power, 16, thickness: 1.8);
        Theme.AttachWindow(this);
        Surface.Keep(this);
        MouseLeftButtonDown += OnMouseDown;
        saveTimer.Tick += (_, _) => { saveTimer.Stop(); SavePos(); };
        LocationChanged += (_, _) =>
        {
            if (!IsLoaded) return;
            saveTimer.Stop();
            saveTimer.Start();
        };
        Core.Shared.Changed += Update;
        Appearance.Changed += Update;
        Theme.Changed += Update;
        App.TrackVisibility(this, "mini");
        Update();
    }

    void Update()
    {
        var s = Core.Shared.Snap;
        var st = s.State;
        var a = Appearance.Current;
        var on = st?.Power == true;
        var hc = Theme.HighContrast;
        var accent = Theme.Accent(Codes.Tint(st?.Mode ?? 2));

        // Texte aus dem Kern (wie am Mac): bei alten Werten „Stand HH:MM“ statt eines Flackerns je Abfrage.
        BigText.Text = s.MiniValue;
        Caption.Text = s.MiniCaption;
        TextArea.ToolTip = s.StatusLine.Length > 0 ? L.F("tray.tip.line", ("name", s.DisplayName), ("text", s.StatusLine)) : s.DisplayName;
        var (family, weight) = Theme.DigitFont;
        if (BigText.FontFamily?.Source != family.Source) BigText.FontFamily = family;
        BigText.FontWeight = weight;

        if (on && hc)
        {
            BorderBrush = SystemColors.HighlightBrush;
            BorderThickness = new Thickness(2);
            TintFill.Background = null;
        }
        else if (on)
        {
            BorderBrush = Paints.Of(accent);
            BorderThickness = new Thickness(2);
            TintFill.Background = Paints.Of(Color.FromArgb(0x24, accent.R, accent.G, accent.B));
        }
        else
        {
            SetResourceReference(BorderBrushProperty, "Line");
            BorderThickness = new Thickness(1);
            TintFill.Background = null;
        }

        PowerButton.IsEnabled = st != null;
        if (on)
        {
            PowerButton.Background = Theme.ActiveFillBrush(accent);
            PowerButton.Foreground = Theme.ActiveText;
        }
        else
        {
            PowerButton.SetResourceReference(BackgroundProperty, "Tile");
            PowerButton.SetResourceReference(ForegroundProperty, "Fg");
        }
        var label = L.T(on ? "settings.appearance.mini.turnOff" : "settings.appearance.mini.turnOn");
        AutomationProperties.SetName(PowerButton, label);
        PowerButton.ToolTip = label;

        ApplyGlow(on && !hc && a.Glow > 0, accent, a.Glow);
    }

    /// Gleiche Werte → kein neuer Effekt, sonst zeichnet das Fenster neu.
    void ApplyGlow(bool show, Color c, int level)
    {
        if (!show)
        {
            if (BigText.Effect != null) BigText.Effect = null;
            glowKey = null;
            return;
        }
        if (glowKey == (c, level)) return;
        glowKey = (c, level);
        var fx = new DropShadowEffect
        {
            Color = c, ShadowDepth = 0, BlurRadius = 4 + level * 0.16, Opacity = Math.Clamp(level / 100.0, 0, 1),
        };
        fx.Freeze();
        BigText.Effect = fx;
    }

    void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        // Der Knopf behandelt seinen Klick selbst; hier kommt nur der Hintergrund an.
        if (e.ClickCount == 2)
        {
            e.Handled = true;
            ((App)Application.Current).ShowMain();
            return;
        }
        if (e.ButtonState != MouseButtonState.Pressed) return;
        try { DragMove(); }
        catch (InvalidOperationException) { }
    }

    void Power_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).TogglePower();
    void Open_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).ShowMain();
    void CloseMini_Click(object sender, RoutedEventArgs e) => Appearance.Update(a => a with { MiniWindow = false });

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
    delegate bool MonitorEnum(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnum callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, int flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtrW(IntPtr hWnd, int index);
    [DllImport("user32.dll")] static extern IntPtr SetWindowLongPtrW(IntPtr hWnd, int index, IntPtr value);
    const int MonitorDefaultToPrimary = 1, GwlExStyle = -20, WsExToolWindow = 0x80, WsExAppWindow = 0x40000;
    const uint SwpNoSize = 0x1, SwpNoZOrder = 0x4, SwpNoActivate = 0x10;

    /// Vor dem Zeigen: Werkzeugfenster (nicht in Alt+Tab) und gemerkte Lage, sonst oben rechts auf dem Hauptbildschirm.
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var h = new WindowInteropHelper(this).Handle;
        if (h == IntPtr.Zero) return;
        var ex = (long)GetWindowLongPtrW(h, GwlExStyle);
        SetWindowLongPtrW(h, GwlExStyle, new IntPtr((ex | WsExToolWindow) & ~(long)WsExAppWindow));

        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        double w = Width * scale, ht = Height * scale;
        var works = new List<PxRect>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(m, ref mi)) works.Add(new PxRect(mi.rcWork.L, mi.rcWork.T, mi.rcWork.R, mi.rcWork.B));
            return true;
        }, IntPtr.Zero);
        PxRect? fit = Layout.ParseBounds(Prefs.Get(PosPref)) is { } saved
            ? Layout.FitSaved(new PxRect(saved.Left, saved.Top, saved.Left + w, saved.Top + ht), works) : null;
        double x, y;
        if (fit is { } f) (x, y) = (f.Left, f.Top);
        else
        {
            var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (!GetMonitorInfo(MonitorFromPoint(default, MonitorDefaultToPrimary), ref mi)) return;
            x = mi.rcWork.R - w - DefaultGap * scale;
            y = mi.rcWork.T + DefaultGap * scale;
        }
        SetWindowPos(h, IntPtr.Zero, (int)Math.Round(x), (int)Math.Round(y), 0, 0, SwpNoSize | SwpNoZOrder | SwpNoActivate);
    }

    void SavePos()
    {
        var h = new WindowInteropHelper(this).Handle;
        if (h == IntPtr.Zero || !GetWindowRect(h, out var r) || r.R <= r.L || r.B <= r.T) return;
        var text = Layout.FormatBounds(new PxRect(r.L, r.T, r.R, r.B));
        if (text != Prefs.Get(PosPref)) Prefs.Set(PosPref, text);
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        base.OnClosing(e);
        if (!e.Cancel) SavePos();
    }

    protected override void OnClosed(EventArgs e)
    {
        saveTimer.Stop();
        Core.Shared.Changed -= Update;
        Appearance.Changed -= Update;
        Theme.Changed -= Update;
        base.OnClosed(e);
    }
}
