using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Hauptfenster mit den Spalten Verlauf · Steuerung · Diagnose nach den Regeln des Kerns (`options.window`,
/// `WindowLayoutMath`): Steuerung fest, zusätzlicher Platz an Verlauf und Diagnose; passt es nicht, bleibt nur die
/// zuletzt geöffnete Seitenspalte. Reicht die Höhe nicht, wird die Steuerung kompakt; erst danach scrollt eine Spalte.
public partial class MainWindow : Window
{
    readonly ControlPanel Controls = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly ChartsPanel Charts = new();
    readonly DiagnosticsPanel Diag = new() { VerticalAlignment = VerticalAlignment.Top };

    /// Breite des Fensterrahmens, bis er gemessen ist (nur für die Startgröße).
    const double ChromeEstimate = 16;
    const string LastOpenedPref = "LastOpenedColumn";

    bool wantCharts, wantDiag, hadState, updatingButtons, compact, relayoutQueued, densityQueued, spinning;
    SideColumn? lastOpened;
    /// Zuletzt gezeigte Seitenspalten; null bis zur ersten Anordnung.
    SideColumns? lastShown;
    /// Beim Einblenden angebaute Breite je Spalte und die Fensterbreite danach: zurückgenommen wird nur, was hier
    /// angebaut wurde und was der Nutzer nicht inzwischen selbst geändert hat.
    readonly Dictionary<SideColumn, double> grown = new();
    double? grownWidth;
    Rect lastWork;
    readonly DispatcherTimer hiddenTimer = new() { Interval = TimeSpan.FromSeconds(10) };

    static WindowOptions Rules => Core.Shared.Snap.Options.Window;

    public MainWindow()
    {
        InitializeComponent();
        Icon = TrayIcon.WindowIcon();
        // Hintergrund (Mica/Acrylic/deckend) setzt das Theme; die Flächen im XAML haben darum keinen eigenen.
        Theme.AttachWindow(this);
        Topmost = Appearance.Current.AlwaysOnTop;
        Appearance.Changed += OnAppearanceChanged;
        RefreshButton.Content = Icons.Glyph(Icons.GlyphRefresh, 18);
        SettingsButton.Content = Icons.Glyph(Icons.GlyphSettings, 18);
        RefreshButton.ToolTip = L.F("main.windows.refreshHelp", ("shortcut", Hotkeys.Ctrl("R")));
        SettingsButton.ToolTip = L.Tip("main.footer.settings", Hotkeys.Ctrl(","));
        HistoryFill.Children.Add(Charts);
        ControlFill.Children.Add(Controls);
        DiagFill.Children.Add(Diag);
        // Inhalt mindestens so hoch wie die Spalte: so wachsen die Graphen mit der freien Höhe.
        foreach (var (scroll, fill) in new[] { (HistoryScroll, HistoryFill), (ControlScroll, ControlFill), (DiagScroll, DiagFill) })
            scroll.SizeChanged += (_, _) => FitFill(scroll, fill);
        wantCharts = Prefs.GetBool("ShowCharts", false);
        wantDiag = Prefs.GetBool("ShowDiagnostics", false);
        lastOpened = WindowLayoutMath.ParseColumn(Prefs.Get(LastOpenedPref));
        // Standardlage, falls keine gemerkte Lage passt (OnSourceInitialized).
        var area = SystemParameters.WorkArea;
        if (WindowLayoutMath.Valid(Rules))
            Width = Math.Min(area.Width, WindowLayoutMath.MinimumWidth(Rules, new SideColumns(wantCharts, wantDiag)) + ChromeEstimate);
        Height = Math.Min(area.Height, 940);

        Charts.CloseRequested += () => SetPanels(false, wantDiag);
        Diag.CloseRequested += () => SetPanels(wantCharts, false);
        AreaHost.SizeChanged += (_, _) => Relayout();
        Controls.SizeChanged += (_, _) => QueueDensity();
        Core.Shared.Changed += UpdateFooter;
        UpdateButtons();
        UpdateFooter();
        Shortcuts.Attach(this, Controls, () => SetPanels(!wantCharts, wantDiag), () => SetPanels(wantCharts, !wantDiag));
        hiddenTimer.Tick += (_, _) => HideHiddenBanner();
        Loaded += (_, _) =>
        {
            lastWork = WorkArea();
            UpdateMinimumHeight(grow: true);
            Relayout();
            // Gemerkte Größen älterer Fassungen: ganz auf den Bildschirm holen, ohne Seitenspalten schmal halten.
            Dispatcher.BeginInvoke(() =>
            {
                if (!IsLoaded || !IsFloating() || !WindowLayoutMath.Valid(Rules)) return;
                var f = WindowLayoutMath.Fit(Frame(), Dip(WorkArea()));
                if (!wantCharts && !wantDiag)
                    f = WindowLayoutMath.LimitWidth(f, Rules.ControlsOnlyMaxWidth + ChromeWidth(), FrameSide.Left);
                ApplyFrame(f);
            }, DispatcherPriority.Loaded);
        };
        // Lage laufend speichern: beim Abmelden/Herunterfahren kommt Closing nicht sicher.
        boundsTimer.Tick += (_, _) => { boundsTimer.Stop(); SaveBounds(); };
        LocationChanged += (_, _) => { QueueSaveBounds(); CheckScreen(); };
        SizeChanged += (_, _) => QueueSaveBounds();
        StateChanged += (_, _) => { QueueSaveBounds(); QueueRelayout(); };
        DpiChanged += (_, _) => CheckScreen();
        App.TrackVisibility(this, "main");
    }

    static bool HasState => Core.Shared.Snap.State != null;

    void SetPanels(bool charts, bool diag)
    {
        if (charts && !wantCharts) lastOpened = SideColumn.History;
        else if (diag && !wantDiag) lastOpened = SideColumn.Diagnostics;
        if (lastOpened is { } last) Prefs.Set(LastOpenedPref, WindowLayoutMath.ColumnName(last));
        wantCharts = charts;
        wantDiag = diag;
        UpdateButtons();
        Prefs.SetBool("ShowCharts", charts);
        Prefs.SetBool("ShowDiagnostics", diag);
        Relayout();
    }

    void UpdateButtons()
    {
        updatingButtons = true;
        ChartsToggle.IsChecked = wantCharts;
        DiagToggle.IsChecked = wantDiag;
        updatingButtons = false;
        ChartsToggle.ToolTip = L.Tip(wantCharts ? "charts.hide" : "main.windows.chartsShow", Hotkeys.Ctrl("G"));
        DiagToggle.ToolTip = L.Tip(wantDiag ? "diagnostics.panel.hide" : "main.windows.diagnosticsShow", Hotkeys.Ctrl("D"));
    }

    void QueueRelayout()
    {
        if (relayoutQueued) return;
        relayoutQueued = true;
        Dispatcher.BeginInvoke(() => { relayoutQueued = false; Relayout(); }, DispatcherPriority.Loaded);
    }

    /// Wählt die Spalten (Regel „passt nicht“), passt bei frei liegenden Fenstern den Rahmen an und verteilt die Breite.
    void Relayout()
    {
        var rules = Rules;
        var w = AreaHost.ActualWidth;
        if (!IsLoaded || w <= 0 || !WindowLayoutMath.Valid(rules)) return;
        var wanted = new SideColumns(wantCharts && HasState, wantDiag && HasState);
        var res = WindowLayoutMath.Resolve(rules, wanted, AvailableWidth(), lastOpened);
        if (res.Hidden.Count > 0) HideColumns(res.Hidden);
        var shown = res.Shown;
        var minWidth = Math.Min(WindowLayoutMath.MinimumWidth(rules, shown) + ChromeWidth(), WorkArea().Width);
        // Erst lockern, dann den Rahmen ändern, dann die neue Grenze: sonst zöge WPF das Fenster selbst nach rechts.
        MinWidth = Math.Min(MinWidth, minWidth);
        if (lastShown is { } old && old != shown) ColumnsChanged(old, shown);
        lastShown = shown;
        MinWidth = minWidth;

        var cw = WindowLayoutMath.Widths(rules, w, shown);
        // Steuerung allein in einem breiten Fenster (maximiert, angedockt): mittig.
        Area.ColumnDefinitions[0].Width = new GridLength(shown.Any ? 0 : cw.Margin / 2);
        Area.ColumnDefinitions[1].Width = new GridLength(cw.History);
        Area.ColumnDefinitions[2].Width = new GridLength(cw.Control);
        Area.ColumnDefinitions[3].Width = new GridLength(cw.Diagnostics);
        HistoryHost.Visibility = shown.History ? Visibility.Visible : Visibility.Collapsed;
        DiagHost.Visibility = shown.Diagnostics ? Visibility.Visible : Visibility.Collapsed;
        ApplyPadding();
        QueueDensity();
    }

    /// Spalten, die nicht auf den Bildschirm passen, gelten als ausgeblendet; die Ansage nennt jede.
    void HideColumns(IReadOnlyList<SideColumn> hidden)
    {
        var texts = new List<string>();
        foreach (var c in hidden)
        {
            if (c == SideColumn.History) wantCharts = false; else wantDiag = false;
            var name = L.T(c == SideColumn.History ? "main.footer.history" : "main.footer.diagnostics");
            texts.Add(L.F("main.column.hidden", ("column", name)));
        }
        Prefs.SetBool("ShowCharts", wantCharts);
        Prefs.SetBool("ShowDiagnostics", wantDiag);
        UpdateButtons();
        App.Trace($"Hauptfenster: {string.Join(", ", hidden)} ausgeblendet, Bildschirm zu schmal");
        HiddenText.Text = string.Join(" ", texts);
        HiddenBanner.Visibility = Visibility.Visible;
        hiddenTimer.Stop();
        hiddenTimer.Start();
        ControlPanel.Announce(HiddenText);
    }

    void HideHiddenBanner()
    {
        hiddenTimer.Stop();
        HiddenBanner.Visibility = Visibility.Collapsed;
    }

    void DismissHidden_Click(object sender, RoutedEventArgs e) => HideHiddenBanner();

    /// Verlauf wächst nach links, Diagnose nach rechts; die Steuerung bleibt am Platz. Maximiert oder angedockt bleibt
    /// die Breite, wie sie ist.
    void ColumnsChanged(SideColumns old, SideColumns now)
    {
        if (!IsFloating()) return;
        var rules = Rules;
        var screen = Dip(WorkArea());
        var chrome = ChromeWidth();
        var f = Frame();
        var needed = WindowLayoutMath.MinimumWidth(rules, now) + chrome;
        foreach (var column in new[] { SideColumn.History, SideColumn.Diagnostics })
        {
            var side = column == SideColumn.History ? FrameSide.Left : FrameSide.Right;
            if (now.Contains(column) && !old.Contains(column))
            {
                if (WindowLayoutMath.Grow(f, needed, side, screen) is not { } g) continue;
                f = g.Frame;
                grown[column] = g.Added;
            }
            else if (!now.Contains(column) && old.Contains(column))
            {
                if (grown.TryGetValue(column, out var amount) && amount > 0 && grownWidth is { } gw && Math.Abs(gw - f.Width) <= 2)
                    f = WindowLayoutMath.Shrink(f, amount, side, needed);
                grown.Remove(column);
                if (!now.Any)
                    f = WindowLayoutMath.LimitWidth(f, rules.ControlsOnlyMaxWidth + chrome,
                                                    column == SideColumn.History ? FrameSide.Right : FrameSide.Left);
            }
        }
        grownWidth = f.Width;
        ApplyFrame(f);
    }

    /// Mindesthöhe nach Darstellungsgröße; ein frei liegendes Fenster wächst bei `grow` nach unten bis dorthin, soweit
    /// der Bildschirm reicht. Der Rahmen zählt dazu, die Ansage „ausgeblendet“ nicht.
    void UpdateMinimumHeight(bool grow)
    {
        var rules = Rules;
        if (!IsLoaded || !WindowLayoutMath.Valid(rules)) return;
        var chrome = Math.Max(0, ActualHeight - Root.ActualHeight);
        var min = WindowLayoutMath.MinimumHeight(rules, Appearance.Current.Size) + chrome;
        var screen = Dip(WorkArea());
        if (grow && IsFloating()) ApplyFrame(WindowLayoutMath.GrowHeight(Frame(), min, screen));
        MinHeight = Math.Min(min, screen.Height);
    }

    /// Breite, die den Spalten zur Verfügung steht: frei liegend der Arbeitsbereich des Bildschirms, maximiert oder
    /// angedockt die Fensterbreite.
    double AvailableWidth() => IsFloating() ? WorkArea().Width - ChromeWidth() : AreaHost.ActualWidth;

    double ChromeWidth() => IsLoaded && Root.ActualWidth > 0 ? Math.Max(0, ActualWidth - Root.ActualWidth) : ChromeEstimate;

    /// Lage und Größe des Fensters; gesetzte Werte zählen vor gemessenen (zwei Änderungen kurz nacheinander).
    DipRect Frame() => new(Left, Top, double.IsNaN(Width) ? ActualWidth : Width, double.IsNaN(Height) ? ActualHeight : Height);

    void ApplyFrame(DipRect f)
    {
        var now = Frame();
        if (Math.Abs(now.X - f.X) < 0.5 && Math.Abs(now.Y - f.Y) < 0.5
            && Math.Abs(now.Width - f.Width) < 0.5 && Math.Abs(now.Height - f.Height) < 0.5)
            return;
        Left = f.X;
        Top = f.Y;
        Width = f.Width;
        Height = f.Height;
    }

    static DipRect Dip(Rect r) => new(r.X, r.Y, r.Width, r.Height);

    /// Anderer Bildschirm oder andere Skalierung: Platz und Grenzen neu bestimmen.
    void CheckScreen()
    {
        if (!IsLoaded) return;
        var work = WorkArea();
        if (work == lastWork) return;
        lastWork = work;
        UpdateMinimumHeight(grow: false);
        QueueRelayout();
    }

    /// Weder maximiert noch angedockt (Snap): Nur solche Fenster wachsen bzw. schrumpfen beim Ein- und Ausblenden.
    /// Angedockt heißt: die tatsächliche Größe weicht von der „normalen“ ab, oder das Fenster ist bildschirmhoch am Rand.
    bool IsFloating()
    {
        if (WindowState != WindowState.Normal) return false;
        var h = new WindowInteropHelper(this).Handle;
        var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf<WINDOWPLACEMENT>() };
        if (h != IntPtr.Zero && GetWindowPlacement(h, ref wp) && GetWindowRect(h, out var r)
            && (Math.Abs(wp.normal.R - wp.normal.L - (r.R - r.L)) > 2 || Math.Abs(wp.normal.B - wp.normal.T - (r.B - r.T)) > 2))
            return false;
        return !WindowLayoutMath.IsConstrained(Frame(), Dip(WorkArea()));
    }

    /// Arbeitsbereich des Bildschirms, auf dem das Fenster liegt, in WPF-Einheiten (SystemParameters kennt nur den
    /// Hauptbildschirm).
    Rect WorkArea()
    {
        var h = new WindowInteropHelper(this).Handle;
        var target = PresentationSource.FromVisual(this)?.CompositionTarget;
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (h == IntPtr.Zero || target == null || !GetMonitorInfo(MonitorFromWindow(h, MonitorDefaultToNearest), ref mi))
            return SystemParameters.WorkArea;
        var m = target.TransformFromDevice;
        return new Rect(m.Transform(new Point(mi.rcWork.L, mi.rcWork.T)), m.Transform(new Point(mi.rcWork.R, mi.rcWork.B)));
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct WINDOWPLACEMENT { public int length, flags, showCmd; public POINT min, max; public RECT normal; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT wp);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hWnd, int flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO mi);
    const int MonitorDefaultToNearest = 2;

    // Normale Lage in Bildschirm-Pixeln über Get/SetWindowPlacement: eindeutig auch bei Bildschirmen mit
    // verschiedener Skalierung. Maximiert/minimiert wird nicht gemerkt.
    const string BoundsPref = "MainWindowBounds";
    readonly DispatcherTimer boundsTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT wp);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, int flags);
    delegate bool MonitorEnum(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnum callback, IntPtr data);
    const int MonitorDefaultToPrimary = 1, SwHide = 0;

    void QueueSaveBounds()
    {
        if (!IsLoaded) return;
        boundsTimer.Stop();
        boundsTimer.Start();
    }

    /// WINDOWPLACEMENT rechnet ab dem Arbeitsbereich des Hauptbildschirms; bei Taskleiste oben/links weicht das um
    /// deren Breite von Bildschirm-Koordinaten ab.
    static (int X, int Y) WorkspaceOffset()
    {
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(MonitorFromPoint(default, MonitorDefaultToPrimary), ref mi)) return (0, 0);
        return (mi.rcWork.L - mi.rcMonitor.L, mi.rcWork.T - mi.rcMonitor.T);
    }

    void SaveBounds()
    {
        var h = new WindowInteropHelper(this).Handle;
        var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf<WINDOWPLACEMENT>() };
        if (h == IntPtr.Zero || !GetWindowPlacement(h, ref wp)) return;
        var (ox, oy) = WorkspaceOffset();
        var n = wp.normal;
        if (n.R <= n.L || n.B <= n.T) return;
        var text = Layout.FormatBounds(new PxRect(n.L + ox, n.T + oy, n.R + ox, n.B + oy));
        if (text != Prefs.Get(BoundsPref)) Prefs.Set(BoundsPref, text);
    }

    /// Gemerkte Lage vor dem Zeigen setzen, damit das Fenster nicht springt.
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (Layout.ParseBounds(Prefs.Get(BoundsPref)) is not { } saved) return;
        var works = new List<PxRect>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(m, ref mi)) works.Add(new PxRect(mi.rcWork.L, mi.rcWork.T, mi.rcWork.R, mi.rcWork.B));
            return true;
        }, IntPtr.Zero);
        if (Layout.FitSaved(saved, works) is not { } fit)
        {
            App.Trace("Hauptfenster: gemerkte Lage liegt auf keinem Bildschirm mehr – Standardlage");
            return;
        }
        var h = new WindowInteropHelper(this).Handle;
        var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf<WINDOWPLACEMENT>() };
        if (h == IntPtr.Zero || !GetWindowPlacement(h, ref wp)) return;
        var (ox, oy) = WorkspaceOffset();
        wp.normal = new RECT { L = (int)fit.Left - ox, T = (int)fit.Top - oy, R = (int)fit.Right - ox, B = (int)fit.Bottom - oy };
        // SW_HIDE: nur die Lage setzen, zeigen tut WPF. Manual, falls WPF die Startlage erst danach rechnet.
        wp.showCmd = SwHide;
        wp.flags = 0;
        WindowStartupLocation = WindowStartupLocation.Manual;
        SetWindowPlacement(h, ref wp);
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        base.OnClosing(e);
        if (!e.Cancel) SaveBounds();
    }

    static void FitFill(ScrollViewer scroll, Grid fill) =>
        fill.MinHeight = Math.Max(0, scroll.ActualHeight - fill.Margin.Top - fill.Margin.Bottom);

    void ApplyPadding()
    {
        var pad = compact ? Layout.PadCompact : Layout.PadNormal;
        foreach (var (scroll, fill, width) in new[]
                 {
                     (HistoryScroll, HistoryFill, Area.ColumnDefinitions[1].Width.Value),
                     (ControlScroll, ControlFill, Area.ColumnDefinitions[2].Width.Value),
                     (DiagScroll, DiagFill, Area.ColumnDefinitions[3].Width.Value),
                 })
        {
            var x = Layout.PadX(width);
            fill.Margin = new Thickness(x, pad, x, pad);
            FitFill(scroll, fill);
        }
    }

    (double, double, double) densityKey;

    void QueueDensity()
    {
        if (densityQueued) return;
        densityQueued = true;
        Dispatcher.BeginInvoke(() => { densityQueued = false; UpdateDensity(); }, DispatcherPriority.Loaded);
    }

    /// Gemessen wird immer die normale Dichte, damit die Entscheidung nicht zwischen beiden Zuständen pendelt.
    void UpdateDensity()
    {
        var avail = ControlScroll.ActualHeight;
        if (avail <= 0) return;
        var width = Layout.ControlsWidth(Area.ColumnDefinitions[2].Width.Value);
        // NaturalHeight ist das Teuerste am Layout – nur nachmessen, wenn sich etwas geändert hat.
        var key = (avail, width, Controls.ActualHeight);
        if (key == densityKey) return;
        densityKey = key;
        var natural = Controls.NaturalHeight(width);
        var was = compact;
        compact = Layout.NeedsCompact(natural, avail);
        Controls.Compact = compact;
        if (compact != was) App.Trace($"Layout: Steuerung {(compact ? "kompakt" : "normal")} (Platz {avail:0}, braucht {natural + 2 * Layout.PadNormal:0})");
        ApplyPadding();
    }

    void UpdateFooter()
    {
        var snap = Core.Shared.Snap;
        var has = HasState;
        ChartsToggle.Visibility = DiagToggle.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
        RefreshButton.Visibility = snap.Configured ? Visibility.Visible : Visibility.Collapsed;
        UpdateBusy(snap.Busy);
        // Verlauf/Diagnose erst zeigen, wenn die Anlage Werte liefert.
        if (has != hadState)
        {
            hadState = has;
            QueueRelayout();
        }
    }

    /// Die Drehung läuft nur, solange sie sichtbar ist – sonst weckte die Animation dauernd die Darstellung.
    void UpdateBusy(bool busy)
    {
        if (busy == spinning) return;
        spinning = busy;
        BusyRing.Visibility = busy ? Visibility.Visible : Visibility.Hidden;
        BusySpin.BeginAnimation(RotateTransform.AngleProperty, busy
            ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever }
            : null);
    }

    // Checked/Unchecked statt Click: so schalten auch Tastatur und Bedienungshilfen (UI Automation) die Bereiche.
    void ChartsToggle_Changed(object sender, RoutedEventArgs e) { if (!updatingButtons) SetPanels(ChartsToggle.IsChecked == true, wantDiag); }
    void DiagToggle_Changed(object sender, RoutedEventArgs e) { if (!updatingButtons) SetPanels(wantCharts, DiagToggle.IsChecked == true); }
    void Refresh_Click(object sender, RoutedEventArgs e) => Shortcuts.Refresh();
    void Settings_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).ShowSettings(SettingsTab.General);

    /// Größe und Umfang beim letzten Mal – ändert sich eins davon, Mindesthöhe, Anordnung und Dichte neu bestimmen.
    (string Size, string Scope) appearanceLayout = (Appearance.Current.Size, Appearance.Current.Scope);

    void OnAppearanceChanged()
    {
        var a = Appearance.Current;
        if (Topmost != a.AlwaysOnTop) Topmost = a.AlwaysOnTop;
        if ((a.Size, a.Scope) == appearanceLayout) return;
        var sizeChanged = a.Size != appearanceLayout.Size;
        appearanceLayout = (a.Size, a.Scope);
        densityKey = default;
        if (sizeChanged) UpdateMinimumHeight(grow: true);
        QueueRelayout();
    }

    /// Schließen gibt das Fenster ganz frei; die Abmeldung ist nötig, sonst hielten die statischen Ereignisse es fest.
    protected override void OnClosed(EventArgs e)
    {
        Core.Shared.Changed -= UpdateFooter;
        Appearance.Changed -= OnAppearanceChanged;
        boundsTimer.Stop();
        hiddenTimer.Stop();
        UpdateBusy(false);
        // Nicht auf Unloaded verlassen: auch ausgeblendete Bereiche sauber abmelden.
        Controls.Detach();
        Charts.Detach();
        Diag.Detach();
        base.OnClosed(e);
    }
}
