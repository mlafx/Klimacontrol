using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
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

    static IntPtr lib;
    static bool running;
    // Rückrufe bleiben referenziert, solange WinSparkle sie aufrufen kann.
    static IntFn? canShutdown;
    static VoidFn? shutdownRequest;

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

    /// Startet WinSparkle; ohne Setup-Installation, DLL, Feed oder Schlüssel bleibt alles aus.
    /// `quit` beendet die App geordnet (wie „Beenden“), aufgerufen auf dem UI-Thread.
    public static void Start(string feedUrl, int checkInterval, Action quit)
    {
        if (running) return;
        var key = PublicKey;
        if (!InstalledBySetup || feedUrl.Length == 0 || key.Length == 0) return;
        var file = Path.Combine(Native.ResDir, "WinSparkle.dll");
        if (!File.Exists(file) || !NativeLibrary.TryLoad(file, out lib)) { App.Trace("Updates: WinSparkle.dll fehlt"); return; }
        try
        {
            Fn<SetUtf8VoidFn>("win_sparkle_set_registry_path")(RegistryPath);
            Fn<SetUtf8VoidFn>("win_sparkle_set_appcast_url")(feedUrl);
            if (Fn<SetUtf8Fn>("win_sparkle_set_eddsa_public_key")(key) == 0)
            {
                App.Trace("Updates: öffentlicher Schlüssel ungültig");
                return;
            }
            // Version genau wie tools/VERSION: WinSparkle vergleicht sie mit sparkle:version im Appcast.
            Fn<SetDetailsFn>("win_sparkle_set_app_details")("Klimacontrol", "Klimacontrol", App.Version);
            Fn<SetUtf8VoidFn>("win_sparkle_set_lang")("de");
            if (checkInterval > 0) Fn<SetIntFn>("win_sparkle_set_update_check_interval")(checkInterval);
            // Nicht abschaltbar (Entscheidung des Autors): eine früher gewählte Abwahl oder übersprungene Version
            // zählt nicht mehr.
            ClearSkippedVersion();
            Fn<SetIntFn>("win_sparkle_set_automatic_check_for_updates")(1);
            var dispatcher = Application.Current.Dispatcher;
            canShutdown = () => 1;
            shutdownRequest = () => dispatcher.BeginInvoke(() => { App.Trace("Beenden für Update"); quit(); });
            Fn<SetCallbackFn>("win_sparkle_set_can_shutdown_callback")(Marshal.GetFunctionPointerForDelegate(canShutdown));
            Fn<SetCallbackFn>("win_sparkle_set_shutdown_request_callback")(Marshal.GetFunctionPointerForDelegate(shutdownRequest));
            Fn<VoidFn>("win_sparkle_init")();
            running = true;
            App.Trace("Updates: WinSparkle gestartet");
            // Zusätzlich zur täglichen Suche einmal beim Start, kurz verzögert; ohne Update bleibt es still.
            var startCheck = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            startCheck.Tick += (_, _) =>
            {
                startCheck.Stop();
                if (running) Fn<VoidFn>("win_sparkle_check_update_without_ui")();
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
}
