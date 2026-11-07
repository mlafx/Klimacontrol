using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Hauptfenster mit responsiven Spalten (Regeln in `Layout`). Reicht die Höhe nicht, wird die Steuerung kompakt;
/// erst danach scrollt eine Spalte.
public partial class MainWindow : Window
{
    readonly ControlPanel Controls = new() { VerticalAlignment = VerticalAlignment.Top, MaxWidth = Layout.ControlsMaxContent };
    readonly ChartsPanel Charts = new();
    readonly DiagnosticsPanel Diag = new() { VerticalAlignment = VerticalAlignment.Top };

    bool wantCharts, wantDiag, hadState, updatingButtons, compact, relayoutQueued, densityQueued, updatingTabs, spinning;
    Pane selectedTab = Pane.Controls;
    string layoutKey = "";
    readonly List<ColumnView> columns = new();

    sealed class ColumnView
    {
        public required List<Pane> Panes;
        public required bool Tabbed;
        public required ScrollViewer Scroll;
        public required Grid Fill;
        public required List<RadioButton> Tabs;
        public double Width;
    }

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
        wantCharts = Prefs.GetBool("ShowCharts", false);
        wantDiag = Prefs.GetBool("ShowDiagnostics", false);
        // Standardlage, falls keine gemerkte Lage passt (OnSourceInitialized).
        var area = SystemParameters.WorkArea;
        Width = Math.Min(area.Width, Layout.NaturalWidth(wantCharts, wantDiag) + 16);
        Height = Math.Min(area.Height, 940);

        Charts.CloseRequested += () => SetPanels(false, wantDiag);
        Diag.CloseRequested += () => SetPanels(wantCharts, false);
        AreaHost.SizeChanged += (_, _) => Relayout();
        Controls.SizeChanged += (_, _) => QueueDensity();
        Diag.SizeChanged += (_, _) => { if (columns.Any(c => c.Panes.Count > 1 && !c.Panes.Contains(Pane.Controls))) QueueRelayout(); };
        Core.Shared.Changed += UpdateFooter;
        UpdateButtons();
        UpdateFooter();
        Shortcuts.Attach(this, Controls, () => SetPanels(!wantCharts, wantDiag), () => SetPanels(wantCharts, !wantDiag));
        // Lage laufend speichern: beim Abmelden/Herunterfahren kommt Closing nicht sicher.
        boundsTimer.Tick += (_, _) => { boundsTimer.Stop(); SaveBounds(); };
        LocationChanged += (_, _) => QueueSaveBounds();
        SizeChanged += (_, _) => QueueSaveBounds();
        StateChanged += (_, _) => QueueSaveBounds();
        App.TrackVisibility(this, "main");
    }

    static bool HasState => Core.Shared.Snap.State != null;

    void SetPanels(bool charts, bool diag)
    {
        var (oldCharts, oldDiag) = (wantCharts, wantDiag);
        wantCharts = charts;
        wantDiag = diag;
        if (charts && !oldCharts) selectedTab = Pane.Charts;
        else if (diag && !oldDiag) selectedTab = Pane.Diag;
        UpdateButtons();
        Prefs.SetBool("ShowCharts", charts);
        Prefs.SetBool("ShowDiagnostics", diag);
        if (HasState) ResizeForPanels(oldCharts, oldDiag);
        Relayout();
    }

    void UpdateButtons()
    {
        updatingButtons = true;
        ChartsToggle.IsChecked = wantCharts;
        DiagToggle.IsChecked = wantDiag;
        updatingButtons = false;
        ChartsToggle.ToolTip = wantCharts ? "Verlauf ausblenden (Strg+G)" : "Verlauf links einblenden (Strg+G)";
        DiagToggle.ToolTip = wantDiag ? "Diagnose ausblenden (Strg+D)" : "Diagnose rechts einblenden (Strg+D)";
    }

    /// Maximierte oder angedockte Fenster behalten ihre Größe; nur frei liegende wachsen bzw. schrumpfen.
    void ResizeForPanels(bool oldCharts, bool oldDiag)
    {
        if (!IsLoaded || !IsFloating()) return;
        var client = AreaHost.ActualWidth;
        var chrome = Math.Max(0, ActualWidth - client);
        var target = Layout.ResizeClient(client, oldCharts, oldDiag, wantCharts, wantDiag, WorkArea().Right - Left - chrome);
        if (target is { } t) Width = Math.Max(MinWidth, t + chrome);
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

    /// Weder maximiert noch an einer Andock-Zone (Snap): dort weicht die tatsächliche Größe von der „normalen“ ab.
    bool IsFloating()
    {
        if (WindowState != WindowState.Normal) return false;
        var h = new WindowInteropHelper(this).Handle;
        var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf<WINDOWPLACEMENT>() };
        if (h == IntPtr.Zero || !GetWindowPlacement(h, ref wp) || !GetWindowRect(h, out var r)) return true;
        return Math.Abs(wp.normal.R - wp.normal.L - (r.R - r.L)) <= 2 && Math.Abs(wp.normal.B - wp.normal.T - (r.B - r.T)) <= 2;
    }

    /// Arbeitsbereich des Bildschirms, auf dem das Fenster liegt (SystemParameters kennt nur den Hauptbildschirm).
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

    void QueueRelayout()
    {
        if (relayoutQueued) return;
        relayoutQueued = true;
        Dispatcher.BeginInvoke(() => { relayoutQueued = false; Relayout(); }, DispatcherPriority.Loaded);
    }

    void Relayout()
    {
        double w = AreaHost.ActualWidth, h = AreaHost.ActualHeight;
        if (w <= 0 || h <= 0) return;
        var cols = Layout.Arrange(w, wantCharts && HasState, wantDiag && HasState, width => StackFits(width, h));
        var key = Layout.Key(cols);
        if (key != layoutKey)
        {
            Build(cols);
            layoutKey = key;
        }
        var widths = Layout.Distribute(columns.Select(c => Layout.ColumnSpan(c.Panes)).ToList(), w);
        for (var i = 0; i < columns.Count; i++)
        {
            columns[i].Width = widths[i];
            Area.ColumnDefinitions[i].Width = new GridLength(widths[i]);
        }
        ApplyPadding();
        UpdateTabs();
        QueueDensity();
    }

    /// Gemessen ohne Höhengrenze: die Stern-Zeilen des Verlaufs zählen dann mit der Mindesthöhe ihrer Graphen.
    bool StackFits(double width, double height)
    {
        var inner = new Size(Math.Max(100, width - 32), double.PositiveInfinity);
        Charts.Measure(inner);
        Diag.Measure(inner);
        return Layout.StackFits(Charts.DesiredSize.Height, Diag.DesiredSize.Height, height);
    }

    FrameworkElement Element(Pane p) => p switch { Pane.Controls => Controls, Pane.Charts => Charts, _ => Diag };
    static string PaneTitle(Pane p) => p switch { Pane.Controls => "Steuerung", Pane.Charts => "Verlauf", _ => "Diagnose" };

    void Build(List<LayoutColumn> cols)
    {
        foreach (var el in new FrameworkElement[] { Controls, Charts, Diag })
        {
            if (el.Parent is Panel parent) parent.Children.Remove(el);
            Grid.SetRow(el, 0);
            el.Margin = new Thickness(0);
            el.Visibility = Visibility.Visible;
        }
        Area.Children.Clear();
        Area.ColumnDefinitions.Clear();
        columns.Clear();
        var line = (Brush)FindResource("Line");
        for (var i = 0; i < cols.Count; i++)
        {
            var (panes, tabbed) = cols[i];
            var fill = new Grid();
            var scroll = new ScrollViewer
            {
                Content = fill, Focusable = false, PanningMode = PanningMode.VerticalOnly,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            };
            // Inhalt mindestens so hoch wie die Spalte: so wachsen die Graphen mit der freien Höhe.
            scroll.SizeChanged += (_, _) => FitFill(scroll, fill);
            var dock = new DockPanel();
            var tabs = new List<RadioButton>();
            if (tabbed)
            {
                var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 8, 12, 0) };
                foreach (var p in panes)
                {
                    var rb = new RadioButton { Content = PaneTitle(p), Tag = p, GroupName = "Bereiche", Style = (Style)FindResource("PaneTab") };
                    rb.Checked += (_, _) =>
                    {
                        if (updatingTabs) return;
                        selectedTab = (Pane)rb.Tag;
                        UpdateTabs();
                        QueueDensity();
                    };
                    tabs.Add(rb);
                    bar.Children.Add(rb);
                }
                DockPanel.SetDock(bar, Dock.Top);
                dock.Children.Add(bar);
            }
            dock.Children.Add(scroll);
            var host = new Border { Child = dock, BorderBrush = line, BorderThickness = new Thickness(i > 0 ? 1 : 0, 0, 0, 0) };
            Grid.SetColumn(host, i);
            Area.ColumnDefinitions.Add(new ColumnDefinition());
            Area.Children.Add(host);

            if (tabbed || panes.Count == 1)
                foreach (var p in panes) fill.Children.Add(Element(p));
            else
            {
                // Untereinander: Verlauf nimmt die freie Höhe, darunter Trennlinie und Diagnose.
                fill.RowDefinitions.Add(new RowDefinition());
                fill.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                fill.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                fill.Children.Add(Element(panes[0]));
                var sep = new Border { Height = 1, Background = line, Margin = new Thickness(0, 20, 0, 20) };
                Grid.SetRow(sep, 1);
                fill.Children.Add(sep);
                var second = Element(panes[1]);
                Grid.SetRow(second, 2);
                fill.Children.Add(second);
            }
            columns.Add(new ColumnView { Panes = panes, Tabbed = tabbed, Scroll = scroll, Fill = fill, Tabs = tabs });
        }
    }

    static void FitFill(ScrollViewer scroll, Grid fill) =>
        fill.MinHeight = Math.Max(0, scroll.ActualHeight - fill.Margin.Top - fill.Margin.Bottom);

    void ApplyPadding()
    {
        var pad = compact ? Layout.PadCompact : Layout.PadNormal;
        foreach (var c in columns)
        {
            var x = Layout.PadX(c.Width);
            c.Fill.Margin = new Thickness(x, c.Tabbed ? 8 : pad, x, pad);
            FitFill(c.Scroll, c.Fill);
        }
    }

    void UpdateTabs()
    {
        updatingTabs = true;
        try
        {
            foreach (var c in columns.Where(c => c.Tabbed))
            {
                if (!c.Panes.Contains(selectedTab)) selectedTab = c.Panes[0];
                foreach (var p in c.Panes) Element(p).Visibility = p == selectedTab ? Visibility.Visible : Visibility.Collapsed;
                foreach (var rb in c.Tabs) rb.IsChecked = (Pane)rb.Tag == selectedTab;
            }
        }
        finally { updatingTabs = false; }
    }

    (double, double, bool, double) densityKey;

    void QueueDensity()
    {
        if (densityQueued) return;
        densityQueued = true;
        Dispatcher.BeginInvoke(() => { densityQueued = false; UpdateDensity(); }, DispatcherPriority.Loaded);
    }

    /// Gemessen wird immer die normale Dichte, damit die Entscheidung nicht zwischen beiden Zuständen pendelt.
    void UpdateDensity()
    {
        var col = columns.FirstOrDefault(c => c.Panes.Contains(Pane.Controls));
        if (col == null || col.Tabbed && selectedTab != Pane.Controls) return;
        var avail = col.Scroll.ActualHeight;
        if (avail <= 0) return;
        var width = Layout.ControlsWidth(col.Width);
        // NaturalHeight ist das Teuerste am Layout – nur nachmessen, wenn sich etwas geändert hat.
        var key = (avail, width, col.Tabbed, Controls.ActualHeight);
        if (key == densityKey) return;
        densityKey = key;
        var natural = Controls.NaturalHeight(width);
        var was = compact;
        compact = Layout.NeedsCompact(natural, col.Tabbed, avail);
        Controls.Compact = compact;
        if (compact != was) App.Trace($"Layout: Steuerung {(compact ? "kompakt" : "normal")} (Platz {avail:0}, braucht {natural + (col.Tabbed ? 8 : Layout.PadNormal) + Layout.PadNormal:0})");
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
        // Neue Verlaufspunkte können einen Graphen einblenden und den Höhenbedarf der gemeinsamen Spalte ändern.
        if (snap.HistoryRevision != historyRev)
        {
            historyRev = snap.HistoryRevision;
            if (columns.Any(c => c.Panes.Contains(Pane.Charts) && c.Panes.Contains(Pane.Diag))) QueueRelayout();
        }
    }

    int historyRev = -1;

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

    /// Größe und Umfang beim letzten Mal – ändert sich eins davon, Anordnung und Dichte neu bestimmen.
    (string Size, string Scope) appearanceLayout = (Appearance.Current.Size, Appearance.Current.Scope);

    void OnAppearanceChanged()
    {
        var a = Appearance.Current;
        if (Topmost != a.AlwaysOnTop) Topmost = a.AlwaysOnTop;
        if ((a.Size, a.Scope) == appearanceLayout) return;
        appearanceLayout = (a.Size, a.Scope);
        densityKey = default;
        QueueRelayout();
    }

    /// Schließen gibt das Fenster ganz frei; die Abmeldung ist nötig, sonst hielten die statischen Ereignisse es fest.
    protected override void OnClosed(EventArgs e)
    {
        Core.Shared.Changed -= UpdateFooter;
        Appearance.Changed -= OnAppearanceChanged;
        boundsTimer.Stop();
        UpdateBusy(false);
        // Nicht auf Unloaded verlassen: auch Bereiche, die gerade in keiner Spalte hängen, sauber abmelden.
        Controls.Detach();
        Charts.Detach();
        Diag.Detach();
        base.OnClosed(e);
    }
}
