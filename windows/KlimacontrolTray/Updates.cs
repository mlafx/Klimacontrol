using System;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// App-Updates über WinSparkle (res\WinSparkle.dll). Aktiv nur, wenn die App per Setup installiert ist: WinSparkle
/// startet das neue Setup, und das ersetzt nur einen Setup-Ordner. Feed und Intervall kommen aus dem Kern, der
/// öffentliche Schlüssel aus tools/UPDATE_PUBLIC_KEY (beim Bauen eingelesen).
static class Updates
{
    /// Muss zur AppId in windows/installer/Klimacontrol.iss passen.
    public const string SetupAppId = "{1EAA2BD1-F86E-420F-A62C-4057C87B34F8}";
    const string RegistryPath = @"Software\Klimacontrol\WinSparkle";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void VoidFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int IntFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void SetIntFn(int value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SetUtf8Fn([MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void SetUtf8VoidFn([MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    delegate void SetDetailsFn(string company, string app, string version);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void SetCallbackFn(IntPtr callback);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int RunInstallerFn(IntPtr path);

    /// Schalter, mit denen WinSparkle das Setup startet (sparkle:installerArguments im Appcast, tools/make_release.py).
    /// WinSparkle reicht sie dem Rückruf nicht weiter; „Jetzt installieren“ startet das Setup genauso.
    public const string InstallerArguments = "/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS";

    static IntPtr lib;
    static bool running;
    // Rückrufe bleiben referenziert, solange WinSparkle sie aufrufen kann.
    static IntFn? canShutdown;
    static VoidFn? shutdownRequest;
    static RunInstallerFn? runInstaller;

    // Updates nicht automatisch installieren: Das Setup aus WinSparkle wird in `holdDir` zurückgehalten.
    // `autoInstall` liest der Rückruf auf WinSparkles Thread. `skipShutdown`: Nach einem zurückgehaltenen Setup bittet
    // WinSparkle trotzdem ums Beenden; das wird dann einmal übergangen.
    static volatile bool autoInstall = true;
    static int skipShutdown;
    static string holdDir = "";
    static int checkInterval;
    static HeldUpdate? held;
    static bool asking;
    static Action? quitApp;
    static DispatcherTimer? reminderTimer;

    /// Neuer Stand des zurückgehaltenen Updates (Einstellungen zeigen Status und „Jetzt installieren“).
    public static event Action? HeldChanged;

    /// Version des geladenen, noch nicht installierten Updates (null = keins).
    public static string? HeldVersion => held?.Version;

    static double Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    /// Per Setup installiert: Der Uninstall-Eintrag des Setups zeigt auf den Ordner dieser exe.
    public static bool InstalledBySetup
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(
                    $@"Software\Microsoft\Windows\CurrentVersion\Uninstall\{SetupAppId}_is1");
                if (key?.GetValue("InstallLocation") is not string dir || dir.Length == 0) return false;
                return SameDir(dir, AppContext.BaseDirectory);
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException
                                          or ArgumentException) { return false; }
        }
    }

    /// WinSparkle läuft (Setup-Installation, DLL geladen, Feed vom Kern).
    public static bool Running => running;

    static bool SameDir(string a, string b)
    {
        static string Norm(string p) => Path.GetFullPath(p).TrimEnd('\\', '/');
        return string.Equals(Norm(a), Norm(b), StringComparison.OrdinalIgnoreCase);
    }

    static string PublicKey
    {
        get
        {
            foreach (var a in typeof(Updates).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>())
                if (a.Key == "UpdatePublicKey") return a.Value ?? "";
            return "";
        }
    }

    static T Fn<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(lib, name));

    static readonly Regex TestFeedPattern = new(@"^http://127\.0\.0\.1:([0-9]{1,5})/[A-Za-z0-9._/-]*\z",
        RegexOptions.CultureInvariant);

    /// Nur für die Update-Prüfungen vor dem Release (D3): Die Variable KLIMACONTROL_UPDATE_TEST_FEED darf den Feed auf
    /// einen lokalen Server umbiegen. Nur Loopback mit Port; ohne die Variable oder mit anderem Wert bleibt es wirkungslos.
    internal static string? TestFeedOverride(string? value)
    {
        if (value == null) return null;
        var m = TestFeedPattern.Match(value);
        if (!m.Success) return null;
        return int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) is >= 1 and <= 65535 ? value : null;
    }

    /// Startet WinSparkle; ohne Setup-Installation, DLL, Feed oder Schlüssel bleibt alles aus.
    /// `quit` beendet die App geordnet (wie „Beenden“), aufgerufen auf dem UI-Thread.
    public static void Start(string feedUrl, int interval, Action quit)
    {
        if (running) return;
        var key = PublicKey;
        if (!InstalledBySetup || feedUrl.Length == 0 || key.Length == 0) return;
        var file = Path.Combine(Native.ResDir, "WinSparkle.dll");
        if (!File.Exists(file) || !NativeLibrary.TryLoad(file, out lib)) { App.Trace("Updates: WinSparkle.dll fehlt"); return; }
        try
        {
            Fn<SetUtf8VoidFn>("win_sparkle_set_registry_path")(RegistryPath);
            Fn<SetUtf8VoidFn>("win_sparkle_set_appcast_url")(
                TestFeedOverride(Environment.GetEnvironmentVariable("KLIMACONTROL_UPDATE_TEST_FEED")) ?? feedUrl);
            if (Fn<SetUtf8Fn>("win_sparkle_set_eddsa_public_key")(key) == 0)
            {
                App.Trace("Updates: öffentlicher Schlüssel ungültig");
                return;
            }
            // Version genau wie tools/VERSION: WinSparkle vergleicht sie mit sparkle:version im Appcast.
            Fn<SetDetailsFn>("win_sparkle_set_app_details")("Klimacontrol", "Klimacontrol", App.Version);
            Fn<SetUtf8VoidFn>("win_sparkle_set_lang")(L.Language == "de" ? "de" : "en");
            checkInterval = interval;
            if (interval > 0) Fn<SetIntFn>("win_sparkle_set_update_check_interval")(interval);
            // Nicht abschaltbar (Entscheidung des Autors): eine früher gewählte Abwahl oder übersprungene Version
            // zählt nicht mehr.
            ClearSkippedVersion();
            Fn<SetIntFn>("win_sparkle_set_automatic_check_for_updates")(1);
            var dispatcher = Application.Current.Dispatcher;
            quitApp = quit;
            holdDir = Path.Combine(Native.SupportDir(), "update");
            autoInstall = Core.Shared.Snap.UpdateAutoInstall;
            canShutdown = () => 1;
            shutdownRequest = () =>
            {
                if (Interlocked.Exchange(ref skipShutdown, 0) == 1)
                {
                    dispatcher.BeginInvoke(() => App.Trace("Updates: Setup zurückgehalten, App bleibt offen"));
                    return;
                }
                dispatcher.BeginInvoke(() => { App.Trace("Beenden für Update"); quit(); });
            };
            runInstaller = path => OnRunInstaller(path, dispatcher);
            Fn<SetCallbackFn>("win_sparkle_set_can_shutdown_callback")(Marshal.GetFunctionPointerForDelegate(canShutdown));
            Fn<SetCallbackFn>("win_sparkle_set_shutdown_request_callback")(Marshal.GetFunctionPointerForDelegate(shutdownRequest));
            Fn<SetCallbackFn>("win_sparkle_set_user_run_installer_callback")(Marshal.GetFunctionPointerForDelegate(runInstaller));
            Fn<VoidFn>("win_sparkle_init")();
            running = true;
            App.Trace($"Updates: WinSparkle gestartet (automatisch installieren: {(autoInstall ? "an" : "aus")})");
            Core.Shared.Changed += SyncSettings;
            LoadHeld();
            reminderTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
            reminderTimer.Tick += (_, _) => AskIfDue();
            reminderTimer.Start();
            // Zusätzlich zur täglichen Suche einmal beim Start, kurz verzögert; ohne Update bleibt es still. Liegt schon
            // ein zurückgehaltenes Update bereit, kommt stattdessen dessen Hinweis (sonst erschiene WinSparkles Fenster
            // für dieselbe Version noch einmal).
            var startCheck = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            startCheck.Tick += (_, _) =>
            {
                startCheck.Stop();
                if (!running) return;
                if (held != null) AskIfDue();
                else Fn<VoidFn>("win_sparkle_check_update_without_ui")();
            };
            startCheck.Start();
        }
        catch (Exception e) when (e is EntryPointNotFoundException or MarshalDirectiveException)
        {
            App.Trace("Updates: WinSparkle passt nicht: " + e.Message);
        }
    }

    public static void Stop()
    {
        if (!running) return;
        running = false;
        Core.Shared.Changed -= SyncSettings;
        reminderTimer?.Stop();
        try { Fn<VoidFn>("win_sparkle_cleanup")(); }
        catch (Exception e) { App.Trace("Updates beenden: " + e.Message); }
    }

    /// Entfernt WinSparkles Merker „Diese Version überspringen“ (Wert SkipThisVersion unter unserem Registry-Pfad).
    static void ClearSkippedVersion()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
            if (key?.GetValue("SkipThisVersion") == null) return;
            key.DeleteValue("SkipThisVersion", throwOnMissingValue: false);
            App.Trace("Updates: Merker für übersprungene Version entfernt");
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException
                                      or ArgumentException) { App.Trace("Updates: Merker nicht entfernt: " + e.Message); }
    }

    /// „Jetzt suchen …“: WinSparkle zeigt Fortschritt, Ergebnis oder Fehler in seinem eigenen Fenster.
    public static void CheckNow()
    {
        if (running) Fn<VoidFn>("win_sparkle_check_update_with_ui")();
    }

    /// Einstellungen aus dem Kern übernehmen: „automatisch installieren“ für den nächsten Rückruf, Suchintervall an
    /// WinSparkle (gespeichert unter unserem Registry-Pfad, wirkt spätestens ab dem nächsten Start).
    static void SyncSettings()
    {
        if (!running) return;
        var s = Core.Shared.Snap;
        if (autoInstall != s.UpdateAutoInstall)
        {
            autoInstall = s.UpdateAutoInstall;
            App.Trace($"Updates: automatisch installieren {(autoInstall ? "an" : "aus")}");
        }
        if (s.UpdateCheckInterval > 0 && s.UpdateCheckInterval != checkInterval)
        {
            checkInterval = s.UpdateCheckInterval;
            try { Fn<SetIntFn>("win_sparkle_set_update_check_interval")(checkInterval); }
            catch (Exception e) when (e is EntryPointNotFoundException or MarshalDirectiveException)
            {
                App.Trace("Updates: Intervall nicht gesetzt: " + e.Message);
            }
        }
    }

    /// WinSparkle will das geladene, geprüfte Setup starten (auf WinSparkles Thread). 0 = WinSparkle startet es selbst,
    /// 1 = übernommen, -1 = Fehler (WinSparkle meldet ihn). Aus: Kopie zurückhalten und den Hinweis zeigen.
    static int OnRunInstaller(IntPtr pathPtr, Dispatcher ui)
    {
        if (autoInstall)
        {
            Interlocked.Exchange(ref skipShutdown, 0);
            return 0;
        }
        try
        {
            var path = Marshal.PtrToStringUni(pathPtr) ?? "";
            var version = UpdateHold.VersionFromFileName(path) ?? FileVersion(path) ?? "?";
            var h = UpdateHold.Hold(holdDir, path, version, Now);
            Interlocked.Exchange(ref skipShutdown, 1);
            ui.BeginInvoke(() =>
            {
                App.Trace($"Updates: Version {h.Version} geladen, Installation erst nach Bestätigung");
                SetHeld(h);
                AskIfDue();
            });
            return 1;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            var text = e.GetType().Name + ": " + e.Message;
            ui.BeginInvoke(() => App.Trace("Updates: Setup nicht zurückgehalten: " + text));
            return -1;
        }
    }

    static string? FileVersion(string path)
    {
        try { return FileVersionInfo.GetVersionInfo(path).ProductVersion is { Length: > 0 } v ? v : null; }
        catch (FileNotFoundException) { return null; }
    }

    static void SetHeld(HeldUpdate? h)
    {
        held = h;
        HeldChanged?.Invoke();
    }

    /// Beim Start: ein gemerktes Update weiter anbieten; ist es nicht neuer als diese Fassung (schon installiert), beiseite.
    static void LoadHeld()
    {
        try
        {
            var h = UpdateHold.Load(holdDir);
            if (h != null && UpdateHold.IsNewer(h.Version, App.Version))
            {
                SetHeld(h);
                return;
            }
            if (File.Exists(Path.Combine(holdDir, UpdateHold.StateFile)))
            {
                UpdateHold.Discard(holdDir, h, Now);
                App.Trace("Updates: altes zurückgehaltenes Update beiseitegelegt");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            App.Trace("Updates: Ablage nicht lesbar: " + e.Message);
        }
    }

    /// Hinweis „Update bereit · Jetzt installieren · Später“, sobald die Erinnerung fällig ist; nicht über anderen
    /// Rückfragen (der Takt fragt dann eine Minute später erneut).
    static async void AskIfDue()
    {
        if (held is not { } h || asking || Dialogs.IsOpen || !UpdateHold.ReminderDue(Now, h.RemindAt)) return;
        var u = Core.Shared.Snap.Options.Updates;
        if (u.HeldBackTitle.Length == 0) return;
        asking = true;
        int choice;
        try
        {
            choice = await Dialogs.Ask(null, u.HeldBackTitle, u.HeldBackMessageTemplate.Replace("{version}", h.Version),
                                       u.InstallNow, u.Later);
        }
        finally { asking = false; }
        if (held != h) return;
        if (choice == 0)
        {
            InstallHeld();
            return;
        }
        var later = h with { RemindAt = Now + Math.Max(60, u.ReminderSeconds) };
        try { UpdateHold.Save(holdDir, later); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            App.Trace("Updates: Erinnerung nicht gespeichert: " + e.Message);
        }
        SetHeld(later);
        App.Trace("Updates: später erinnern");
    }

    /// „Jetzt installieren“: Prüfsumme erneut prüfen (sonst verwerfen und neu suchen), Setup wie WinSparkle starten und
    /// die App geordnet beenden (ohne Rückfrage zu Timern; sie sind gespeichert).
    public static void InstallHeld()
    {
        if (held is not { } h) return;
        var file = UpdateHold.OpenVerified(holdDir, h);
        if (file == null)
        {
            App.Trace($"Updates: Prüfsumme von Version {h.Version} stimmt nicht, verworfen");
            try { UpdateHold.Discard(holdDir, h, Now); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { App.Trace("Updates: " + e.Message); }
            SetHeld(null);
            _ = Dialogs.Warn(null, L.T("settings.general.updatesSection"), L.T("settings.general.windows.updateHeldInvalid"));
            CheckNow();
            return;
        }
        using (file)
        {
            try
            {
                Process.Start(new ProcessStartInfo(file.Name, InstallerArguments)
                {
                    UseShellExecute = true,
                    WorkingDirectory = holdDir,
                });
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                App.Trace("Updates: Setup nicht gestartet: " + e.Message);
                _ = Dialogs.Warn(null, L.T("settings.general.updatesSection"), L.T("settings.general.windows.updateStartFailed"));
                return;
            }
        }
        App.Trace($"Updates: Version {h.Version} wird installiert");
        quitApp?.Invoke();
    }
}

