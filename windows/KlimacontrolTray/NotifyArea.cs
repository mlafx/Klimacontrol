using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Symbol im Infobereich ohne WinForms: `Shell_NotifyIconW` mit `NOTIFYICON_VERSION_4` (meldet Tastatur und Maus
/// getrennt) über ein verstecktes Fenster, dazu das globale Kürzel. Legt sich nach einem Explorer-Neustart selbst
/// wieder an. Alles auf dem UI-Thread.
sealed class NotifyArea : IDisposable
{
    const int WM_USER = 0x0400, CallbackMessage = WM_USER + 0x50;
    const int WM_CONTEXTMENU = 0x007B, WM_LBUTTONDBLCLK = 0x0203, WM_HOTKEY = 0x0312, WM_DPICHANGED = 0x02E0,
        WM_DISPLAYCHANGE = 0x007E, WM_SETTINGCHANGE = 0x001A;
    const int NIN_SELECT = WM_USER, NIN_KEYSELECT = WM_USER + 1, NIN_BALLOONUSERCLICK = WM_USER + 5;
    const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETFOCUS = 3, NIM_SETVERSION = 4;
    const uint NIF_MESSAGE = 0x01, NIF_ICON = 0x02, NIF_TIP = 0x04, NIF_INFO = 0x10, NIF_SHOWTIP = 0x80;
    const uint NIIF_INFO = 0x01, NIIF_WARNING = 0x02, NOTIFYICON_VERSION_4 = 4;
    const uint IconId = 1;
    const int HotkeyId = 1;
    const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_WIN = 0x8, MOD_NOREPEAT = 0x4000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion; // Union mit uTimeout
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);
    [DllImport("shell32.dll")]
    static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")]
    static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowW(string cls, string? title);
    [DllImport("user32.dll")]
    static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    static extern uint GetDpiForSystem();
    [DllImport("user32.dll")]
    static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("shcore.dll")]
    static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);

    readonly HwndSource source;
    readonly uint taskbarCreated;
    readonly DispatcherTimer retry = new() { Interval = TimeSpan.FromSeconds(2) };
    int retries;
    bool added, disposed;
    System.Drawing.Icon? icon;
    string tip = "Klimacontrol";
    DateTime lastSelect, suppressSelectUntil;
    string? failedHotkey;

    /// Linksklick oder Enter/Leertaste (true = per Tastatur).
    public event Action<bool>? Select;
    public event Action? DoubleClick;
    /// Menü öffnen: Ankerpunkt in Bildschirm-Pixeln, true = per Tastatur (Umschalt+F10/Menütaste).
    public event Action<Point, bool>? Menu;
    public event Action? Hotkey;
    /// Die Sprechblase wurde angeklickt.
    public event Action? BalloonClick;
    /// Größe, Taskleistenfarbe oder eine Windows-Einstellung kann sich geändert haben – Bild neu zeichnen.
    public event Action? SizeChanged;

    /// Kantenlänge des Symbols in Pixeln (SM_CXSMICON bei der DPI der Taskleiste).
    public int IconSize { get; private set; } = 16;

    /// Taskleiste hell (SystemUsesLightTheme, unabhängig vom App-Modus) – einfarbige Symbole dann schwarz.
    public bool TaskbarLight { get; private set; } = ReadTaskbarLight();

    bool refreshQueued;

    public IntPtr Handle => source.Handle;

    public NotifyArea()
    {
        // Verstecktes Fenster der obersten Ebene (kein „Message-only“-Fenster: das bekäme TaskbarCreated nicht).
        var p = new HwndSourceParameters("KlimacontrolNotifyArea")
        {
            Width = 0, Height = 0, PositionX = 0, PositionY = 0,
            WindowStyle = unchecked((int)0x80000000),   // WS_POPUP, nicht sichtbar
            ExtendedWindowStyle = 0x00000080,           // WS_EX_TOOLWINDOW: nie in Taskleiste/Alt+Tab
        };
        source = new HwndSource(p);
        source.AddHook(Hook);
        taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        retry.Tick += (_, _) => { if (Add() || ++retries >= 60) retry.Stop(); };
        UpdateIconSize();
    }

    /// Symbol anzeigen. Gelingt es nicht (Explorer startet gerade erst), noch bis zu 2 min alle 2 s versuchen.
    public void Show()
    {
        if (Add()) return;
        App.Trace("Infobereich: Symbol konnte noch nicht angelegt werden – neuer Versuch alle 2 s");
        retries = 0;
        retry.Start();
    }

    NOTIFYICONDATAW Data(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
        hWnd = source.Handle,
        uID = IconId,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = icon?.Handle ?? IntPtr.Zero,
        szTip = tip,
        szInfo = "",
        szInfoTitle = "",
    };

    bool Add()
    {
        if (disposed) return true;
        var d = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        if (!Shell_NotifyIconW(NIM_ADD, ref d))
        {
            // Nach einem Absturz/Explorer-Neustart kann ein altes Symbol mit derselben Kennung übrig sein.
            Shell_NotifyIconW(NIM_DELETE, ref d);
            if (!Shell_NotifyIconW(NIM_ADD, ref d)) { added = false; return false; }
        }
        // Ohne Version 4 kämen Enter/Umschalt+F10 als Mausklicks an und der Ankerpunkt fehlte.
        d.uVersion = NOTIFYICON_VERSION_4;
        if (!Shell_NotifyIconW(NIM_SETVERSION, ref d)) App.Trace("Infobereich: NOTIFYICON_VERSION_4 nicht angenommen");
        added = true;
        return true;
    }

    public void SetIcon(System.Drawing.Icon value)
    {
        if (ReferenceEquals(icon, value)) return;
        icon = value;
        if (!added) return;
        var d = Data(NIF_ICON);
        Shell_NotifyIconW(NIM_MODIFY, ref d);
    }

    /// Tooltip; der Infobereich nimmt höchstens 127 Zeichen.
    public void SetTip(string text)
    {
        text = text.Length > 127 ? text[..126] + "…" : text;
        if (text == tip) return;
        tip = text;
        if (!added) return;
        var d = Data(NIF_TIP | NIF_SHOWTIP);
        Shell_NotifyIconW(NIM_MODIFY, ref d);
    }

    /// Sprechblase (unter Windows 11 eine Benachrichtigung). Titel ≤ 63, Text ≤ 255 Zeichen (gekürzt mit „…“).
    /// `warning`: Warnsymbol statt Info (z. B. Timer nicht ausgeführt). false, wenn es kein Symbol gibt.
    public bool ShowBalloon(string title, string text, bool warning = false)
    {
        if (!added) return false;
        var d = Data(NIF_INFO);
        d.szInfoTitle = title.Length > 63 ? title[..62] + "…" : title;
        d.szInfo = text.Length > 255 ? text[..254] + "…" : text;
        d.dwInfoFlags = warning ? NIIF_WARNING : NIIF_INFO;
        return Shell_NotifyIconW(NIM_MODIFY, ref d);
    }

    /// Tastaturfokus zurück aufs Symbol (nach einem per Tastatur geöffneten und mit Esc geschlossenen Menü).
    public void FocusIcon()
    {
        if (!added) return;
        var d = Data(0);
        Shell_NotifyIconW(NIM_SETFOCUS, ref d);
    }

    /// Damit ein Menü sich beim Klick daneben schließt und die Tastatur bekommt, muss die App vorne sein.
    public void TakeForeground() => SetForegroundWindow(source.Handle);

    /// Lage des Symbols in Bildschirm-Pixeln; null, wenn unbekannt (kein Symbol, Explorer läuft nicht).
    public Rect? GetRect()
    {
        if (!added) return null;
        var id = new NOTIFYICONIDENTIFIER { cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(), hWnd = source.Handle, uID = IconId };
        if (Shell_NotifyIconGetRect(ref id, out var r) != 0 || r.Right <= r.Left || r.Bottom <= r.Top) return null;
        return new Rect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }

    /// Liegt der Mauszeiger gerade auf dem Symbol? (Unterscheidet Rechtsklick von Umschalt+F10.)
    public bool CursorOnIcon()
    {
        if (GetRect() is not { } r || !GetCursorPos(out var p)) return false;
        r.Inflate(2, 2);
        return r.Contains(new Point(p.X, p.Y));
    }

    /// Bildschirm-Pixel → WPF-Einheiten nach der DPI des Bildschirms an dieser Stelle.
    public static Point ToDip(Point px)
    {
        var monitor = MonitorFromPoint(new POINT { X = (int)px.X, Y = (int)px.Y }, 2 /* MONITOR_DEFAULTTONEAREST */);
        uint dpi = 96;
        if (monitor == IntPtr.Zero || GetDpiForMonitor(monitor, 0, out dpi, out _) != 0 || dpi == 0) dpi = GetDpiForSystem();
        var f = dpi / 96.0;
        return new Point(px.X / f, px.Y / f);
    }

    void UpdateIconSize()
    {
        var taskbar = FindWindowW("Shell_TrayWnd", null);
        var dpi = taskbar != IntPtr.Zero ? GetDpiForWindow(taskbar) : 0;
        if (dpi == 0) dpi = GetDpiForSystem();
        var size = GetSystemMetricsForDpi(49 /* SM_CXSMICON */, dpi);
        if (size <= 0) size = (int)Math.Round(16 * dpi / 96.0);
        if (size == IconSize) return;
        IconSize = size;
        SizeChanged?.Invoke();
    }

    static bool ReadTaskbarLight()
    {
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("SystemUsesLightTheme") is int v && v != 0;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException) { return false; }
    }

    /// Immer einmal neu zeichnen lassen, auch ohne erkannte Änderung (z. B. „Animationseffekte“ aus).
    void Refresh()
    {
        refreshQueued = false;
        if (disposed) return;
        TaskbarLight = ReadTaskbarLight();
        var before = IconSize;
        UpdateIconSize();
        if (IconSize == before) SizeChanged?.Invoke();
    }

    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == CallbackMessage)
        {
            handled = true;
            var ev = (int)((long)lParam & 0xFFFF);
            // Version 4: Ankerpunkt (Symbol bzw. Maus) in wParam, x/y je 16 bit mit Vorzeichen.
            var anchor = new Point((short)((long)wParam & 0xFFFF), (short)(((long)wParam >> 16) & 0xFFFF));
            var now = DateTime.UtcNow;
            switch (ev)
            {
                case NIN_SELECT:
                case NIN_KEYSELECT:
                    // Enter meldet Windows teils doppelt; nach einem Doppelklick kein weiteres Umschalten.
                    if (now < suppressSelectUntil || (now - lastSelect).TotalMilliseconds < 250) break;
                    lastSelect = now;
                    // Noch in der Nachricht nach vorn: nur jetzt hat die App das Vordergrundrecht der Shell. Später
                    // bliebe bei Enter die Taskleiste vorn und das Fenster ohne Tastaturfokus.
                    SetForegroundWindow(hwnd);
                    Post(() => Select?.Invoke(ev == NIN_KEYSELECT));
                    break;
                case WM_LBUTTONDBLCLK:
                    suppressSelectUntil = now.AddMilliseconds(500);
                    Post(() => DoubleClick?.Invoke());
                    break;
                case WM_CONTEXTMENU:
                    SetForegroundWindow(hwnd);
                    // Maus oder Tastatur? Erst außerhalb der Fensterprozedur nachsehen (fragt den Explorer).
                    Post(() => Menu?.Invoke(anchor, !CursorOnIcon()));
                    break;
                case NIN_BALLOONUSERCLICK:
                    Post(() => BalloonClick?.Invoke());
                    break;
            }
        }
        else if (taskbarCreated != 0 && (uint)msg == taskbarCreated)
        {
            // Explorer neu gestartet: Das alte Symbol ist weg.
            App.Trace("Infobereich: Explorer neu gestartet – Symbol neu anlegen");
            added = false;
            UpdateIconSize();
            Show();
        }
        else if (msg == WM_HOTKEY && (int)wParam == HotkeyId)
        {
            handled = true;
            // Die App hat die letzte Eingabe bekommen und darf jetzt nach vorn – gleich nutzen (wie bei NIN_KEYSELECT).
            SetForegroundWindow(hwnd);
            Post(() => Hotkey?.Invoke());
        }
        else if (msg is WM_DPICHANGED or WM_DISPLAYCHANGE or WM_SETTINGCHANGE)
        {
            if (!refreshQueued)
            {
                refreshQueued = true;
                source.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(Refresh));
            }
        }
        return IntPtr.Zero;
    }

    /// Aktionen nicht im Fensterprozedur-Aufruf ausführen: Er kann mitten in kc_pump laufen.
    void Post(Action a) => source.Dispatcher.BeginInvoke(DispatcherPriority.Normal, a);

    /// Kürzel registrieren ("Ctrl+Alt+K"; leer/null = aus). false, wenn ungültig oder schon von einem anderen
    /// Programm belegt (dann einmal protokolliert).
    public bool SetHotkey(string? text)
    {
        UnregisterHotKey(source.Handle, HotkeyId);
        if (string.IsNullOrWhiteSpace(text)) return true;
        if (!TryParseHotkey(text, out var mods, out var vk))
        {
            LogHotkeyOnce(text, "nicht lesbar"); // kein Anzeigetext: Protokoll
            return false;
        }
        if (RegisterHotKey(source.Handle, HotkeyId, mods | MOD_NOREPEAT, vk)) { failedHotkey = null; return true; }
        LogHotkeyOnce(text, $"schon belegt (Fehler {Marshal.GetLastWin32Error()})");
        return false;
    }

    void LogHotkeyOnce(string text, string why)
    {
        if (failedHotkey == text) return;
        failedHotkey = text;
        App.Trace($"Kürzel {text} für die Schnellsteuerung nicht aktiv: {why}");
    }

    /// Gleicher Parser wie die Einstellungen, damit beide dasselbe verstehen.
    static bool TryParseHotkey(string text, out uint mods, out uint vk)
    {
        mods = 0;
        vk = 0;
        if (!SettingsWindow.TryParseHotkey(text, out var m, out var key)) return false;
        // ModifierKeys hat dieselben Bits wie RegisterHotKey (Alt 1, Control 2, Shift 4, Windows 8).
        mods = (uint)m & (MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN);
        vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        return vk != 0;
    }

    /// Anzeigeform wie in Windows-Menüs: "Ctrl+Alt+K" → "Strg+Alt+K" bzw. "Ctrl+Alt+K"; leer bei ungültig/aus.
    public static string HotkeyDisplay(string? text) =>
        string.IsNullOrWhiteSpace(text) || !SettingsWindow.TryParseHotkey(text, out var m, out var key) ? "" : Hotkeys.Display(m, key);

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        retry.Stop();
        UnregisterHotKey(source.Handle, HotkeyId);
        if (added)
        {
            var d = Data(0);
            Shell_NotifyIconW(NIM_DELETE, ref d);
            added = false;
        }
        source.RemoveHook(Hook);
        source.Dispose();
    }
}

/// Tastennamen in der Sprache der App (Katalog `keys.windows.*`). Gespeichert wird das Kürzel weiter als „Ctrl+Alt+K“.
static class Hotkeys
{
    /// „Strg+Alt+“ usw. (mit abschließendem Plus), leer ohne Modifikatoren.
    public static string Mods(ModifierKeys mods)
    {
        var text = "";
        if (mods.HasFlag(ModifierKeys.Control)) text += L.T("keys.windows.ctrl") + "+";
        if (mods.HasFlag(ModifierKeys.Alt)) text += L.T("keys.windows.alt") + "+";
        if (mods.HasFlag(ModifierKeys.Shift)) text += L.T("keys.windows.shift") + "+";
        if (mods.HasFlag(ModifierKeys.Windows)) text += L.T("keys.windows.win") + "+";
        return text;
    }

    public static string KeyName(Key key) => key switch
    {
        >= Key.D0 and <= Key.D9 => ((char)('0' + (key - Key.D0))).ToString(),
        >= Key.NumPad0 and <= Key.NumPad9 => L.F("keys.windows.numpad", ("digit", (key - Key.NumPad0).ToString(System.Globalization.CultureInfo.InvariantCulture))),
        Key.Space => L.T("keys.windows.space"),
        Key.Enter => L.T("keys.windows.enter"),
        Key.Back => L.T("keys.windows.backspace"),
        Key.Delete => L.T("keys.windows.delete"),
        Key.Insert => L.T("keys.windows.insert"),
        Key.Home => L.T("keys.windows.home"),
        Key.End => L.T("keys.windows.end"),
        Key.PageUp => L.T("keys.windows.pageUp"),
        Key.PageDown => L.T("keys.windows.pageDown"),
        Key.Up => "↑",
        Key.Down => "↓",
        Key.Left => "←",
        Key.Right => "→",
        Key.OemComma => ",",
        Key.OemPeriod => ".",
        Key.OemMinus => "-",
        Key.OemPlus => "+",
        _ => key.ToString(),
    };

    public static string Display(ModifierKeys mods, Key key) => Mods(mods) + KeyName(key);

    /// „Strg+P“ bzw. „Ctrl+P“ für Kurzinfos.
    public static string Ctrl(string key) => L.T("keys.windows.ctrl") + "+" + key;
}
