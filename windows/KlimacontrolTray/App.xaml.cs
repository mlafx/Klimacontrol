using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using Microsoft.Win32;

namespace KlimacontrolTray;

public partial class App : Application
{
    public static string Version =>
        Assembly.GetExecutingAssembly().GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}.{v.Revision}" : "?";

    /// Oberflächen-Ereignisse nach %TEMP%\klimacontrol-ui.log (ohne Geheimnisse); ab 1 MB eine Sicherung *.1.log.
    public static void Trace(string line)
    {
        try
        {
            var file = Path.Combine(Path.GetTempPath(), "klimacontrol-ui.log");
            var info = new FileInfo(file);
            if (info.Exists && info.Length > TraceLimit) File.Move(file, Path.Combine(Path.GetTempPath(), "klimacontrol-ui.1.log"), true);
            File.AppendAllText(file, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}\n");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    const long TraceLimit = 1 << 20;
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string DefaultHotkey = "Ctrl+Alt+K";

    static int errorShown;
    Mutex? single;
    EventWaitHandle? showSignal, quitSignal;
    NotifyArea? notify;
    ContextMenu? trayMenu;
    FlyoutWindow? flyout;
    SettingsWindow? settings;
    MainWindow? main;
    /// Mini-Fenster, offen solange Appearance.Current.MiniWindow an ist.
    MiniWindow? miniWindow;
    /// Drehender Lüfter im Infobereich (TrayIcon.Spins): Takt nur, solange er dreht.
    System.Windows.Threading.DispatcherTimer? spinTimer;
    int spinFrame;
    /// Kern gestartet (kc_init lief) bzw. ganze Oberfläche bereit; quitting: „Beenden“ läuft.
    bool coreStarted, ready, quitting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Autostart startet nur im Infobereich: kein Hauptfenster, auch kein Nach-vorn-Holen einer laufenden App.
        var trayOnly = e.Args.Any(a => a.Equals("--tray", StringComparison.OrdinalIgnoreCase));
        // Läuft Klimacontrol schon, bittet ein zweiter Start nur die laufende App, ihr Fenster zu zeigen.
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "KlimacontrolTray.Show", out var created);
        single = new Mutex(true, "KlimacontrolTray.SingleInstance", out var first);
        if (!first || !created)
        {
            if (!trayOnly) showSignal.Set();
            Shutdown();
            return;
        }
        // Geordnet beenden von außen (Build-Skript): wird dieses Ereignis gesetzt, läuft dasselbe wie „Beenden“.
        quitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "KlimacontrolTray.Quit");
        // Ereignisse bewusst nicht freigeben: ein Dispose während WaitAny würfe im Thread und beendete die App hart.
        var signals = new WaitHandle[] { showSignal, quitSignal };
        var listener = new Thread(() =>
        {
            while (true)
            {
                var which = WaitHandle.WaitAny(signals);
                if (Dispatcher.HasShutdownStarted) continue;
                if (which == 1) Dispatcher.InvokeAsync(() => { Trace("Beenden von außen angefordert"); Quit(); });
                else Dispatcher.InvokeAsync(() => { if (ready) ShowMain(); });
            }
        }) { IsBackground = true };
        listener.Start();
        // Software-Zeichnen: Direct3D hält Grafiktreiber und Shader-Compiler bis zum Beenden im Speicher.
        System.Windows.Media.RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
        CatchErrors();
        // Abmelden/Herunterfahren: Kern sauber beenden, bevor Windows den Prozess beendet.
        SessionEnding += (_, a) =>
        {
            Trace($"Windows wird beendet ({a.ReasonSessionEnding}) – Kern beenden");
            quitting = true;
            StopCore();
        };

        // Ganzer Start in einem Block: Ein Fehler hinterlässt sonst einen unsichtbaren Prozess, der den
        // Mutex hält – jeder weitere Start holte dann nur ein Fenster nach vorn, das es nicht gibt.
        try
        {
            Theme.Apply(this);
            Theme.Watch(this);
            Theme.Changed += OnThemeChanged;
            try
            {
                Native.UseResFolder();
                Core.Shared.Start(Version);
                coreStarted = true;
            }
            catch (BridgeVersionException ex)
            {
                FailStart(ex.Message, ex, details: false);
                return;
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
            {
                FailStart("Klimacontrol kann nicht starten: Im Ordner „" + Native.ResFolder + "“ neben Klimacontrol.exe fehlen "
                          + "Dateien oder sie sind unvollständig. Bitte den ganzen Ordner aus dem ZIP neu entpacken.", ex);
                return;
            }

            notify = new NotifyArea();
            notify.Select += keyboard => ToggleFlyout(keyboard);
            notify.DoubleClick += () => { flyout?.Close(); ShowMain(); };
            notify.Menu += OpenTrayMenu;
            notify.Hotkey += () => ToggleFlyout(fromKeyboard: true);
            notify.BalloonClick += () => { flyout?.Close(); ShowMain(); };
            notify.SizeChanged += UpdateTray;
            Core.Shared.Changed += UpdateTray;
            Appearance.Changed += OnAppearanceChanged;
            UpdateTray();
            notify.Show();
            // Ein beim Start gemeldetes Timer-Ergebnis („verpasst“) erst jetzt zeigen – vorher gab es kein Symbol.
            ShowTimerResult(Core.Shared.Snap);
            ApplyHotkey();

            flyout = new FlyoutWindow();
            KeepAutostartPath();
            Updates.Start(Core.Shared.Snap.UpdateFeedURL, Core.Shared.Snap.UpdateCheckInterval, Quit);
            ready = true;
            ShowWhatsNew(Core.Shared.Snap);
            ApplyMiniWindow();
            Trace($"Gestartet{(trayOnly ? " (nur Infobereich)" : "")}");
            // Autostart: nur das Symbol.
            if (!trayOnly) ShowMain();
        }
        catch (Exception ex)
        {
            FailStart("Klimacontrol konnte nicht starten. Bitte noch einmal starten; hilft das nicht, den Ordner aus dem "
                      + "ZIP neu entpacken.", ex);
        }
    }

    /// Startfehler: Meldung zeigen, dann ganz beenden (kein Prozess ohne Symbol, der den Mutex hält). `details`: Art
    /// und Text der Ausnahme klein am Ende (aus, wenn `text` schon alles sagt).
    void FailStart(string text, Exception ex, bool details = true)
    {
        Trace("FEHLER beim Start: " + ex);
        try
        {
            Core.Shared.Changed -= UpdateTray;
            Appearance.Changed -= OnAppearanceChanged;
            RemoveTrayIcon();
            StopCore();
        }
        catch (Exception cleanup) { Trace("Aufräumen nach Startfehler: " + cleanup.GetType().Name); }
        _ = ShowAndExit();

        async Task ShowAndExit()
        {
            try { await Dialogs.Warn(null, "Klimacontrol", details ? text + $"\n\n({ex.GetType().Name}: {ex.Message})" : text); }
            catch (Exception dialog) { Trace("Startfehler-Dialog: " + dialog.GetType().Name); }
            finally { Shutdown(1); }
        }
    }

    /// Alle unerwarteten Fehler auf einen Weg: ins Protokoll, höchstens einmal ein Dialog.
    void CatchErrors()
    {
        DispatcherUnhandledException += (_, a) =>
        {
            a.Handled = true;
            ReportError("Oberfläche", a.Exception);
        };
        // Fehler in nicht abgewarteten Aufgaben (async ohne await): erst beim Aufräumen bemerkt, auf dem Finalizer-Thread.
        TaskScheduler.UnobservedTaskException += (_, a) =>
        {
            a.SetObserved();
            var ex = a.Exception.InnerExceptions.Count == 1 ? a.Exception.InnerExceptions[0] : a.Exception;
            if (!Dispatcher.HasShutdownStarted) Dispatcher.InvokeAsync(() => ReportError("Hintergrund", ex));
        };
        // Danach beendet .NET den Prozess; ein Dialog käme nicht mehr sicher an – nur protokollieren.
        AppDomain.CurrentDomain.UnhandledException += (_, a) =>
            Trace($"FEHLER (Absturz{(a.IsTerminating ? ", Programm endet" : "")}): {a.ExceptionObject}");
    }

    void ReportError(string where, Exception ex)
    {
        Trace($"FEHLER {where}: {ex}");
        // Höchstens ein Dialog: Timer laufen weiter, ein wiederkehrender Fehler öffnete sonst Dutzende.
        if (Interlocked.Exchange(ref errorShown, 1) != 0 || quitting) return;
        // Dialogs wartet, bis der Dispatcher frei ist: Der Fehler kann mitten im Layout oder in kc_pump fallen.
        _ = Dialogs.Warn(null, "Klimacontrol",
            "In der Oberfläche ist etwas schiefgelaufen. Klimacontrol läuft weiter. Reagiert etwas nicht mehr, Klimacontrol "
            + "über das Symbol im Infobereich beenden und neu starten. Weitere Fehler stehen nur in der Datei "
            + $"klimacontrol-ui.log im Temp-Ordner.\n\n({ex.GetType().Name}: {ex.Message})");
    }

    void UpdateTray()
    {
        if (notify == null) return;
        var s = Core.Shared.Snap;
        var spin = TrayIcon.Spins(s);
        notify.SetIcon(TrayIcon.Make(s, notify.IconSize, notify.TaskbarLight, spin ? spinFrame : -1));
        if (spin) StartSpin(); else StopSpin();
        notify.SetTip(TipText(s, Appearance.Current.TrayTooltip));
        ShowTimerResult(s);
        if (ready) ShowWhatsNew(s);
    }

    /// „Neu in dieser Version“: höchstens ein Fenster; wer es ohne OK schließt, sieht es in diesem Prozess nicht noch einmal.
    bool whatsNewShown;

    void ShowWhatsNew(Snapshot s)
    {
        if (whatsNewShown || quitting || s.WhatsNew is not { } info) return;
        whatsNewShown = true;
        Dispatcher.InvokeAsync(async () =>
        {
            await Dialogs.AfterPump();
            if (quitting) return;
            var w = new WhatsNewWindow(info);
            w.ShowDialog();
            if (w.Confirmed) Core.Shared.Send(Cmd.DismissWhatsNew);
        });
    }

    /// Lüfter drehen: alle `TrayIcon.SpinInterval` das nächste vorab gezeichnete Bild. Der Takt läuft nur, solange er dreht.
    void StartSpin()
    {
        if (spinTimer == null)
        {
            spinTimer = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Background)
            { Interval = TrayIcon.SpinInterval };
            spinTimer.Tick += (_, _) =>
            {
                if (notify == null) { StopSpin(); return; }
                spinFrame = (spinFrame + 1) % TrayIcon.SpinFrames;
                notify.SetIcon(TrayIcon.Make(Core.Shared.Snap, notify.IconSize, notify.TaskbarLight, spinFrame));
            };
        }
        if (!spinTimer.IsEnabled) spinTimer.Start();
    }

    /// Symbol aus dem Infobereich nehmen und erst danach die Lüfterbilder freigeben: Beim Entfernen liest der
    /// Infobereich noch das aktuelle Bild – war es ein schon freigegebenes Lüfterbild, warf das und „Beenden“ blieb
    /// hängen.
    void RemoveTrayIcon()
    {
        spinTimer?.Stop();
        notify?.Dispose();
        notify = null;
        TrayIcon.ReleaseFrames();
    }

    /// Takt anhalten und die Lüfterbilder freigeben – erst nachdem der Infobereich wieder ein festes Symbol hat
    /// (UpdateTray setzt es vorher), damit er nie auf ein freigegebenes Bild zeigt.
    void StopSpin()
    {
        if (spinTimer?.IsEnabled != true) return;
        spinTimer.Stop();
        TrayIcon.ReleaseFrames();
    }

    void OnAppearanceChanged()
    {
        if (quitting) return;
        UpdateTray();
        ApplyMiniWindow();
    }

    /// Mini-Fenster nach `Appearance.Current.MiniWindow` öffnen bzw. schließen. Schließt es der Nutzer selbst (Alt+F4),
    /// gilt das wie „Mini-Fenster schließen“.
    void ApplyMiniWindow()
    {
        if (!ready || quitting || !coreStarted) return;
        var want = Appearance.Current.MiniWindow;
        if (want && miniWindow == null)
        {
            var w = new MiniWindow();
            w.Closed += (_, _) =>
            {
                if (miniWindow != w) return;
                miniWindow = null;
                if (!quitting && Appearance.Current.MiniWindow) Appearance.Update(a => a with { MiniWindow = false });
            };
            miniWindow = w;
            w.Show();
            Trace("Mini-Fenster geöffnet");
        }
        else if (!want && miniWindow != null)
        {
            var w = miniWindow;
            miniWindow = null;
            w.Close();
            Trace("Mini-Fenster geschlossen");
        }
    }

    /// Tooltip nach Darstellung „Tooltip-Text“. Vorrang haben: nicht eingerichtet, eine Meldung, beim Verbinden der Schritt.
    static string TipText(Snapshot s, string tooltip)
    {
        if (!s.Configured) return "Klimacontrol – nicht eingerichtet";
        if (s.MessageDetail is { What.Length: > 0 } m) return $"{s.DisplayName}: {m.What}";
        if (s.Message != null) return $"{s.DisplayName}: {s.Message}";
        if (s.ConnectionState == "connecting" || s.State == null || s.StatusLine.Length == 0)
        {
            var step = s.ConnectPhase switch
            {
                "searching" => "sucht die Anlage …",
                "handshake" => "meldet sich an der Anlage an …",
                "reading" => "liest die Werte …",
                _ => "verbindet …",
            };
            return $"{s.DisplayName}: {step}";
        }
        return $"{s.DisplayName}: {TipDetail(s.State, tooltip) ?? s.StatusLine}";
    }

    /// Tooltip-Text nach `TrayTooltip` ohne den Namen; null = Statuszeile des Kerns (Standard "iconTarget").
    internal static string? TipDetail(AcState st, string tooltip)
    {
        var status = st.Power ? Codes.Verb(st.Mode) : "Aus";
        string? room = st.Indoor is { } r ? "Raum " + Fmt.Temp(r) : null;
        // Soll nur bei laufender Anlage und nicht beim Lüften.
        string? target = st.Power && st.Mode != 5 ? "Soll " + Fmt.Target(st.Target) : null;
        return tooltip switch
        {
            "iconOnly" => status,
            "iconRoom" => room == null ? status : $"{status} · {room}",
            "roomTarget" => (room, target) switch
            {
                ({ } ro, { } ta) => $"{ro} · {ta}",
                ({ } ro, null) => $"{status} · {ro}",
                (null, { } ta) => $"{status} · {ta}",
                _ => status,
            },
            _ => null,
        };
    }

    /// Ergebnis eines App-Timers einmal als Benachrichtigung; das zuletzt gezeigte steht in Prefs "TimerResultShown",
    /// damit es auch nach einem Neustart nicht doppelt erscheint.
    void ShowTimerResult(Snapshot s)
    {
        if (notify == null || s.TimerResult is not { } r || r.Title.Length == 0) return;
        var key = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{r.Kind}|{(r.PowerOn ? "on" : "off")}|{r.Due:0.###}");
        if (key == timerResultShown) return;
        timerResultShown ??= Prefs.Get("TimerResultShown");
        if (key == timerResultShown) return;
        if (!notify.ShowBalloon(r.Title, r.Message, warning: !r.Succeeded)) return;
        timerResultShown = key;
        Prefs.Set("TimerResultShown", key);
        Trace($"Mitteilung Timer: {r.Kind}");
    }

    /// Zuletzt als Mitteilung gezeigtes Timer-Ergebnis (null = noch nicht aus Prefs gelesen).
    string? timerResultShown;

    /// Hell/Dunkel gewechselt: Symbol neu zeichnen, offenes Menü schließen (wird beim nächsten Öffnen neu gebaut).
    void OnThemeChanged()
    {
        if (trayMenu != null) trayMenu.IsOpen = false;
        UpdateTray();
    }

    /// Lage des Infobereich-Symbols in Bildschirm-Pixeln, null wenn unbekannt.
    public static Rect? TrayIconRect() => (Current as App)?.notify?.GetRect();

    /// Globales Kürzel fürs Flyout aus Prefs "FlyoutHotkey" registrieren (leer = aus). false, wenn ungültig oder belegt.
    public bool ApplyHotkey() => notify?.SetHotkey(Prefs.Get("FlyoutHotkey", DefaultHotkey)) ?? false;

    /// Kürzel in Anzeigeform („Strg+Alt+K“) oder leer, wenn aus.
    static string HotkeyText => NotifyArea.HotkeyDisplay(Prefs.Get("FlyoutHotkey", DefaultHotkey));

    public void TogglePower()
    {
        var st = Core.Shared.Snap.State;
        if (st != null) Core.Shared.Send(Cmd.Power, ("on", !st.Power));
    }

    void ToggleFlyout(bool fromKeyboard)
    {
        if (flyout == null) return;
        trayMenu?.SetCurrentValue(ContextMenu.IsOpenProperty, false);
        // Ist das Fenster offen, schließt es der Klick schon über den Fokusverlust (JustHidden) – nicht wieder öffnen.
        if (flyout.IsVisible || flyout.JustHidden) flyout.Close(); else ShowFlyout(fromKeyboard);
    }

    void ShowFlyout(bool fromKeyboard = false)
    {
        Core.Shared.Hurry();
        flyout?.ShowNearTray(fromKeyboard);
    }

    // Menü am Symbol: bei jedem Öffnen neu gebaut, damit es zum Zustand passt.

    void OpenTrayMenu(Point anchorPx, bool keyboard)
    {
        if (flyout?.IsVisible == true) flyout.Close();
        if (trayMenu != null) trayMenu.IsOpen = false;
        var menu = BuildTrayMenu();
        trayMenu = menu;
        if (keyboard)
        {
            // Umschalt+F10/Menütaste: am Symbol öffnen (Ankerpunkt in Pixeln → WPF-Einheiten dieses Bildschirms).
            var dip = NotifyArea.ToDip(anchorPx);
            menu.Placement = PlacementMode.AbsolutePoint;
            menu.HorizontalOffset = dip.X;
            menu.VerticalOffset = dip.Y;
            menu.Opened += (_, _) => menu.Dispatcher.InvokeAsync(() =>
                menu.MoveFocus(new TraversalRequest(FocusNavigationDirection.First)), System.Windows.Threading.DispatcherPriority.Input);
            // Mit Esc geschlossen: Fokus zurück aufs Symbol, wie bei Windows-eigenen Symbolen.
            menu.Closed += (_, _) => { if (!quitting) notify?.FocusIcon(); };
        }
        else menu.Placement = PlacementMode.MousePoint;
        menu.Closed += (_, _) => { if (trayMenu == menu) trayMenu = null; };
        // Vorn sein, damit das Menü die Tastatur bekommt und sich beim Klick daneben schließt.
        notify?.TakeForeground();
        menu.IsOpen = true;
    }

    ContextMenu BuildTrayMenu()
    {
        var s = Core.Shared.Snap;
        var st = s.State;
        var menu = new ContextMenu();

        MenuItem Item(string header, Action click, bool enabled = true, string? gesture = null)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            if (!string.IsNullOrEmpty(gesture)) item.InputGestureText = gesture;
            item.Click += (_, _) => click();
            return item;
        }

        menu.Items.Add(Item("_Schnellsteuerung", () => ShowFlyout(fromKeyboard: true), gesture: HotkeyText));
        menu.Items.Add(Item("Klimacontrol _öffnen", () => { flyout?.Close(); ShowMain(); }));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(st?.Power == true ? "_Ausschalten" : "_Einschalten", TogglePower, st != null));
        if (s.Configured && s.Scenes.Count > 0)
        {
            var scenes = new MenuItem { Header = "S_zenen", IsEnabled = st != null };
            foreach (var scene in s.Scenes)
            {
                var id = scene.Id;
                var item = Item(scene.Name.Replace("_", "__"), () => Core.Shared.Send(Cmd.ApplyScene, ("id", id)));
                item.IsChecked = scene.Active;
                if (scene.Summary.Length > 0) item.ToolTip = scene.Summary;
                scenes.Items.Add(item);
            }
            menu.Items.Add(scenes);
        }
        if (s.OffAt is { } off)
            menu.Items.Add(Item($"Aus-_Timer löschen (aus um {Fmt.Clock(off)})", () => Core.Shared.Send(Cmd.OffTimer)));
        else
            menu.Items.Add(Item("Aus in _1 Stunde", () => Core.Shared.Send(Cmd.OffTimer, ("minutes", 60)), st?.Power == true));
        // „refresh“ hebt auch alle Sperren der Wegwahl auf – wie „Erneut versuchen“ im Fehlerbanner.
        menu.Items.Add(Item("Jetzt a_ktualisieren", () => Core.Shared.Send(Cmd.Refresh), s.Configured));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("E_instellungen", () => ShowSettings(SettingsTab.General)));
        menu.Items.Add(Item("_Protokoll", () => ShowSettings(SettingsTab.Log)));
        if (Updates.Running) menu.Items.Add(Item("Nach _Updates suchen …", Updates.CheckNow));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("_Beenden", QuitAsk));
        return menu;
    }

    public void ShowSettings(SettingsTab tab)
    {
        if (settings == null)
        {
            var w = new SettingsWindow();
            w.Closed += (_, _) => { if (settings == w) settings = null; TrimSoon(); };
            settings = w;
        }
        Core.Shared.Hurry();
        settings.SelectTab(tab);
        settings.Show();
        if (settings.WindowState == WindowState.Minimized) settings.WindowState = WindowState.Normal;
        settings.Activate();
    }

    public void ShowMain()
    {
        if (quitting || !coreStarted) return;
        if (main == null)
        {
            var w = new MainWindow();
            w.Closed += (_, _) =>
            {
                if (main == w) main = null;
                TrimSoon();
                ShowTrayHintOnce();
            };
            main = w;
        }
        Core.Shared.Hurry();
        main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
    }

    /// Beim ersten Schließen des Hauptfensters einmal sagen, dass Klimacontrol im Infobereich weiterläuft.
    void ShowTrayHintOnce()
    {
        if (quitting || notify == null || Prefs.GetBool("TrayHintShown", false)) return;
        var hotkey = HotkeyText;
        var text = "Das Fenster ist zu, Klimacontrol läuft im Infobereich weiter (evtl. hinter dem Pfeil ^). "
                   + "Klick aufs Symbol öffnet die Schnellsteuerung, Rechtsklick das Menü mit „Beenden“."
                   + (hotkey.Length > 0 ? $" Tastenkürzel: {hotkey}." : "");
        if (notify.ShowBalloon("Klimacontrol läuft weiter", text)) Prefs.SetBool("TrayHintShown", true);
        else Trace("Hinweis „läuft im Infobereich weiter“ nicht gezeigt (kein Symbol)");
    }

    const string LegacyRunValue = "PortaSplit";

    /// Vorhandenen Autostart-Eintrag auf diese exe mit --tray nachführen (z. B. nach Verschieben des Ordners);
    /// nie auf eine Kopie im OneDrive oder einen Entwickler-Build.
    static void KeepAutostartPath()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (exe == null || !Path.GetFileName(exe).Equals("Klimacontrol.exe", StringComparison.OrdinalIgnoreCase)) return;
            if (Dialogs.IsCloudFolder(exe) || exe.Contains(@"\bin\Debug\", StringComparison.OrdinalIgnoreCase)
                || exe.Contains(@"\bin\Release\", StringComparison.OrdinalIgnoreCase)) return;
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null) return;
            // Alten Eintrag „PortaSplit“ entfernen; war der Autostart an, gilt er für Klimacontrol weiter.
            if (key.GetValue(LegacyRunValue) is string legacy)
            {
                key.DeleteValue(LegacyRunValue, false);
                if (key.GetValue("Klimacontrol") == null) key.SetValue("Klimacontrol", $"\"{exe}\" --tray");
                Trace($"Mit Windows starten: alten Eintrag „{LegacyRunValue}“ ({legacy}) durch „Klimacontrol“ ersetzt");
            }
            if (key.GetValue("Klimacontrol") is not string old) return;
            var want = $"\"{exe}\" --tray";
            if (string.Equals(old, want, StringComparison.OrdinalIgnoreCase)) return;
            key.SetValue("Klimacontrol", want);
            Trace($"Mit Windows starten: Eintrag nachgeführt ({old} → {want})");
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            Trace($"Mit Windows starten: Eintrag nicht nachgeführt ({e.GetType().Name})");
        }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

    System.Windows.Threading.DispatcherTimer? trimTimer;

    /// Sind alle Fenster zu, Speicher einsammeln und an Windows zurückgeben – kurz verzögert, falls gleich wieder eins
    /// aufgeht.
    public void TrimSoon()
    {
        trimTimer ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        trimTimer.Stop();
        trimTimer.Tick -= Trim;
        trimTimer.Tick += Trim;
        trimTimer.Start();
    }

    void Trim(object? sender, EventArgs e)
    {
        trimTimer?.Stop();
        if (main != null || settings != null || flyout?.IsVisible == true || trayMenu != null) return;
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        var info = GC.GetGCMemoryInfo();
        using var me = Process.GetCurrentProcess();
        Trace($"Speicher freigegeben: .NET-Heap {GC.GetTotalMemory(false) / 1048576} MB, belegt {info.TotalCommittedBytes / 1048576} MB, "
              + $"privat gesamt {me.PrivateMemorySize64 / 1048576} MB");
        SetProcessWorkingSetSize(me.Handle, -1, -1);
    }

    /// Meldet dem Kern, ob die Oberfläche `id` gezeigt und nicht minimiert ist (ohne sichtbare fragt er seltener ab).
    public static void TrackVisibility(Window w, string id)
    {
        bool? last = null;
        void Report(bool visible)
        {
            if (last == visible) return;
            last = visible;
            Core.Shared.SetUIVisible(id, visible);
        }
        w.IsVisibleChanged += (_, _) => Report(w.IsVisible && w.WindowState != WindowState.Minimized);
        w.StateChanged += (_, _) => Report(w.IsVisible && w.WindowState != WindowState.Minimized);
        w.Closed += (_, _) => Report(false);
    }

    public static void OpenFolder(string path)
    {
        if (Directory.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"\"{RealPath(path)}\"") { UseShellExecute = true });
    }

    /// Ordner der Datei im Explorer öffnen und die Datei markieren; fehlt sie, nur den Ordner.
    public static void ShowInExplorer(string file)
    {
        if (File.Exists(file)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{RealPath(file)}\"") { UseShellExecute = true });
        else if (Path.GetDirectoryName(file) is { } dir) OpenFolder(dir);
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
                                                                        uint creation, uint flags, IntPtr template);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(Microsoft.Win32.SafeHandles.SafeFileHandle handle, char[] buffer, uint size, uint flags);

    /// Tatsächlicher Ort einer Datei bzw. eines Ordners: Aus einer MSIX-App gestartet, leitet Windows %LOCALAPPDATA% in
    /// deren Paket-Ordner um, den der Explorer nicht findet. Bei Fehlern der ursprüngliche Pfad.
    static string RealPath(string path)
    {
        // Nur Metadaten lesen (Zugriff 0), Ordner brauchen FILE_FLAG_BACKUP_SEMANTICS; alles teilen.
        using var h = CreateFileW(path, 0, 7, IntPtr.Zero, 3 /* OPEN_EXISTING */, 0x02000000, IntPtr.Zero);
        if (h.IsInvalid) return path;
        var buffer = new char[1024];
        var n = GetFinalPathNameByHandleW(h, buffer, (uint)buffer.Length, 0);
        if (n == 0 || n >= buffer.Length) return path;
        var real = new string(buffer, 0, (int)n);
        // „\\?\C:\…“ → „C:\…“; Netzwerkpfade „\\?\UNC\server\…“ → „\\server\…“.
        if (real.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + real[8..];
        return real.StartsWith(@"\\?\", StringComparison.Ordinal) ? real[4..] : real;
    }

    /// Kern beenden – darf mehrfach laufen (Beenden, Abmelden, OnExit).
    void StopCore()
    {
        if (!coreStarted) return;
        try { Core.Shared.Stop(); }
        catch (Exception e) { Trace("Kern beenden: " + e.GetType().Name + ": " + e.Message); }
    }

    bool quitAsking;

    /// „Beenden“ von Hand (Menü, Schnellsteuerung): Ist ein App-Timer gestellt, fragt Klimacontrol erst nach (Text und
    /// Knöpfe vom Kern, `QuitPrompt`). Bestätigen beendet, sonst bleibt alles offen. Ohne Timer gleich beenden. Von außen
    /// angeforderte Beendigungen (Update, Build-Skript) rufen `Quit` direkt und fragen nie.
    public async void QuitAsk()
    {
        if (quitAsking || quitting) return;
        if (Core.Shared.Snap.QuitPrompt is { } p)
        {
            quitAsking = true;
            try
            {
                var choice = p.Warning ? await Dialogs.AskWarn(null, p.Title, p.Message, p.Confirm, p.Cancel)
                                       : await Dialogs.Ask(null, p.Title, p.Message, p.Confirm, p.Cancel);
                if (choice != 0) return;
            }
            finally { quitAsking = false; }
        }
        Quit();
    }

    public void Quit()
    {
        quitting = true;
        Core.Shared.Changed -= UpdateTray;
        Appearance.Changed -= OnAppearanceChanged;
        if (trayMenu != null) trayMenu.IsOpen = false;
        Updates.Stop();
        StopCore();
        RemoveTrayIcon();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        quitting = true;
        Theme.Changed -= OnThemeChanged;
        Core.Shared.Changed -= UpdateTray;
        Appearance.Changed -= OnAppearanceChanged;
        // Auch wenn nicht über „Beenden“ (Abmelden, Fehler): Kern geordnet beenden, Symbol entfernen.
        Updates.Stop();
        StopCore();
        RemoveTrayIcon();
        single?.Dispose();
        base.OnExit(e);
    }
}
