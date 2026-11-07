using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Fenster über dem Infobereich. Schließt sich wie ein Windows-Flyout, sobald woanders hingeklickt wird.
public partial class FlyoutWindow : Window
{
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    // Windows meldet einem nie aktivierten Fenster keinen Fokusverlust. Darum selbst nachsehen: Maustaste gedrückt
    // außerhalb des Fensters (und nicht auf einem eigenen Menü/Popup) → schließen.
    readonly DispatcherTimer outsideClick = new() { Interval = TimeSpan.FromMilliseconds(80) };
    DateTime shownAt, hiddenAt;

    /// Gerade eben geschlossen – derselbe Klick aufs Symbol soll es nicht gleich wieder öffnen.
    public bool JustHidden => (DateTime.Now - hiddenAt).TotalMilliseconds < 400;

    public FlyoutWindow()
    {
        InitializeComponent();
        Icon = TrayIcon.WindowIcon();
        Theme.AttachWindow(this);
        Surface.Keep(this);
        Appearance.Changed += OnAppearanceChanged;
        // Ohne Einrichtung nur der Hinweis aufs Hauptfenster.
        Controls.InlineSetup = false;
        Controls.NavigatedAway += Close;
        outsideClick.Tick += (_, _) => CheckOutsideClick();
        SizeChanged += (_, _) => { if (IsVisible) Place(); };
        DpiChanged += (_, _) => { if (IsVisible) Place(); };
        Controls.SizeChanged += (_, _) => { if (IsVisible) QueueDensity(); };
        App.TrackVisibility(this, "flyout");
        Shortcuts.Attach(this, Controls, leaving: Close);
        // KeyDown statt PreviewKeyDown: ein offenes Auswahlfeld soll Esc vorher abfangen.
        KeyDown += (_, e) =>
        {
            if (e.Key != System.Windows.Input.Key.Escape || e.Handled) return;
            e.Handled = true;
            Close();
        };
    }

    bool densityQueued;
    /// Größe und Umfang beim letzten Mal.
    (string Size, string Scope) appearanceLayout = (Appearance.Current.Size, Appearance.Current.Scope);

    void QueueDensity()
    {
        if (densityQueued) return;
        densityQueued = true;
        Dispatcher.BeginInvoke(() => { densityQueued = false; UpdateDensity(); }, DispatcherPriority.Loaded);
    }

    /// Immer die normale Dichte messen, damit es nicht pendelt.
    void UpdateDensity()
    {
        // DesiredSize enthält den Rand der Steuerung schon; 2 = Fensterrahmen.
        var need = Controls.NaturalHeight(Width - 2);
        Controls.Compact = need > Scroller.MaxHeight;
    }

    /// Öffnet das Fenster am Infobereich-Symbol, ohne bekanntes Symbol am Mauszeiger bzw. (`fromKeyboard`) in der
    /// Ecke am Infobereich. Der Fokus steht danach auf Ein/Aus.
    public void ShowNearTray(bool fromKeyboard = false)
    {
        shownAt = DateTime.Now;
        target = FindTarget(fromKeyboard);
        // Platz über dem Infobereich abzüglich Rand und Fußzeile.
        Scroller.MaxHeight = Math.Max(200, WorkAreaDip() - 24 - 52);
        UpdateDensity();
        Show();
        UpdateLayout();
        Place();
        BringToFront();
        Controls.FocusFirst();
        Dispatcher.InvokeAsync(() =>
        {
            BringToFront();
            if (IsVisible && !IsKeyboardFocusWithin) Controls.FocusFirst();
        }, DispatcherPriority.ApplicationIdle);
        outsideClick.Start();
        App.Trace($"Fenster zeigen bei {Left:0},{Top:0} Größe {ActualWidth:0}x{ActualHeight:0}"
                  + $" ({(target.Anchor == null ? "ohne Symbol" : "am Symbol")}, Taskleiste {target.Edge})");
    }

    /// Die Höhe folgt über SizeToContent, die Lage über SizeChanged; nur Kompakt neu entscheiden.
    void OnAppearanceChanged()
    {
        var a = Appearance.Current;
        if ((a.Size, a.Scope) == appearanceLayout) return;
        appearanceLayout = (a.Size, a.Scope);
        if (IsVisible) QueueDensity();
    }

    /// Das Fenster lebt so lange wie die App (`Close` blendet nur aus); schließt Windows es doch, hier abmelden.
    protected override void OnClosed(EventArgs e)
    {
        Appearance.Changed -= OnAppearanceChanged;
        base.OnClosed(e);
    }

    public new void Close()
    {
        outsideClick.Stop();
        hiddenAt = DateTime.Now;
        Hide();
        ((App)Application.Current).TrimSoon();
    }

    // Lage in Bildschirm-Pixeln per SetWindowPos: WPF-Einheiten hängen bei verschiedener Skalierung davon ab, wo das
    // Fenster gerade steht.

    /// Wo das Fenster hingehört: Bildschirm, Symbol (bzw. Mauszeiger), Seite der Taskleiste.
    sealed record Target(IntPtr Monitor, PxRect? Anchor, TaskbarEdge Edge);
    Target target = new(IntPtr.Zero, null, TaskbarEdge.Bottom);
    bool placing, placeAgain;

    Target FindTarget(bool fromKeyboard)
    {
        PxRect? anchor = App.TrayIconRect() is { } r && r.Width > 0 && r.Height > 0
            ? new PxRect(r.Left, r.Top, r.Right, r.Bottom) : null;
        if (anchor == null && !fromKeyboard && GetCursorPos(out var c)) anchor = new PxRect(c.X, c.Y, c.X, c.Y);
        var bar = TaskbarPos();
        IntPtr mon;
        if (anchor is { } a) mon = MonitorFromPoint(new POINT { X = (int)a.CenterX, Y = (int)a.CenterY }, MonitorDefaultToNearest);
        else if (bar is { } b) { var rc = b.Rect; mon = MonitorFromRect(ref rc, MonitorDefaultToNearest); }
        else mon = MonitorFromPoint(default, MonitorDefaultToPrimary);
        TaskbarEdge edge = TaskbarEdge.Bottom;
        if (Areas(mon) is { } m)
        {
            // Die Lage der Taskleiste laut Windows gilt nur, wenn sie auf diesem Bildschirm liegt.
            TaskbarEdge? barEdge = null;
            if (bar is { } b2) { var rc = b2.Rect; if (MonitorFromRect(ref rc, MonitorDefaultToNearest) == mon) barEdge = b2.Edge; }
            edge = Layout.EdgeOf(m.Monitor, m.Work, anchor, barEdge);
        }
        return new Target(mon, anchor, edge);
    }

    /// Höhe des Arbeitsbereichs des Ziel-Bildschirms in WPF-Einheiten.
    double WorkAreaDip() =>
        Areas(target.Monitor) is { } m ? m.Work.Height / Scale(target.Monitor) : SystemParameters.WorkArea.Height;

    /// Skalierung des Bildschirms (1 = 96 dpi). Rückfall: die des Fensters.
    double Scale(IntPtr monitor) =>
        monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out var dx, out _) == 0 && dx > 0
            ? dx / 96.0 : VisualTreeHelper.GetDpi(this).DpiScaleX;

    void Place()
    {
        // SetWindowPos auf einen Bildschirm mit anderer Skalierung löst DpiChanged mitten im Aufruf aus – dann danach
        // noch einmal mit der neuen Größe rechnen, statt verschachtelt.
        if (placing) { placeAgain = true; return; }
        placing = true;
        try
        {
            for (var i = 0; i < 3; i++)
            {
                placeAgain = false;
                PlaceOnce();
                if (!placeAgain) break;
            }
        }
        finally { placing = false; }
    }

    void PlaceOnce()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero || Areas(target.Monitor) is not { } m)
        {
            // Bildschirm unbekannt: unten rechts auf dem Hauptbildschirm.
            var area = SystemParameters.WorkArea;
            Left = area.Right - Width - Layout.FlyoutGap;
            Top = Math.Max(area.Top + Layout.FlyoutGap, area.Bottom - ActualHeight - Layout.FlyoutGap);
            return;
        }
        var scale = Scale(target.Monitor);
        var (x, y) = Layout.FlyoutPosition(m.Work, target.Edge, target.Anchor,
                                           ActualWidth * scale, ActualHeight * scale, Layout.FlyoutGap * scale);
        SetWindowPos(hwnd, IntPtr.Zero, (int)Math.Round(x), (int)Math.Round(y), 0, 0,
                     SwpNoSize | SwpNoZOrder | SwpNoActivate);
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA { public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, int flags);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref RECT r, int flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO mi);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    const int MonitorDefaultToPrimary = 1, MonitorDefaultToNearest = 2;
    const uint AbmGetTaskbarPos = 5, SwpNoSize = 0x1, SwpNoZOrder = 0x4, SwpNoActivate = 0x10;

    static PxRect Px(RECT r) => new(r.L, r.T, r.R, r.B);

    static (PxRect Monitor, PxRect Work)? Areas(IntPtr monitor)
    {
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref mi)) return null;
        return (Px(mi.rcMonitor), Px(mi.rcWork));
    }

    /// Lage und Seite der (Haupt-)Taskleiste laut Windows; null, wenn unbekannt.
    static (RECT Rect, TaskbarEdge Edge)? TaskbarPos()
    {
        var d = new APPBARDATA { cbSize = Marshal.SizeOf<APPBARDATA>() };
        if (SHAppBarMessage(AbmGetTaskbarPos, ref d) == UIntPtr.Zero) return null;
        var edge = d.uEdge switch { 0 => TaskbarEdge.Left, 1 => TaskbarEdge.Top, 2 => TaskbarEdge.Right, _ => TaskbarEdge.Bottom };
        return (d.rc, edge);
    }

    void BringToFront()
    {
        if (!IsVisible || IsActive) return;
        // Vordergrund gibt Windows nur dem, der gerade Eingaben bekommt (Taskleiste): kurz an deren Eingabe hängen.
        var hwnd = new WindowInteropHelper(this).Handle;
        uint me = GetCurrentThreadId(), fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        var attached = fg != 0 && fg != me && AttachThreadInput(me, fg, true);
        SetForegroundWindow(hwnd);
        Activate();
        if (attached) AttachThreadInput(me, fg, false);
    }

    void CheckOutsideClick()
    {
        if (!IsVisible) { outsideClick.Stop(); return; }
        if ((DateTime.Now - shownAt).TotalMilliseconds < 400 || Controls.IsTyping || Dialogs.IsOpen) return;
        var pressed = (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0;
        if (!pressed || !GetCursorPos(out var p)) return;
        // Eigene Popups (Menüs, Rückfragen) sind eigene Fenster desselben Prozesses.
        if (IsOwnProcessWindow(WindowFromPoint(p))) return;
        App.Trace("Klick daneben – Fenster zu");
        Close();
    }

    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);

    static bool IsOwnProcessWindow(IntPtr hwnd)
    {
        GetWindowThreadProcessIdPid(hwnd, out var pid);
        return pid == (uint)Environment.ProcessId;
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    static extern uint GetWindowThreadProcessIdPid(IntPtr hWnd, out uint processId);

    void Open_Click(object sender, RoutedEventArgs e)
    {
        Close();
        ((App)Application.Current).ShowMain();
    }

    void Quit_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).QuitAsk();
}
