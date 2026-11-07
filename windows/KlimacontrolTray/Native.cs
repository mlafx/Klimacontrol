using System;
using System.Runtime.InteropServices;

namespace KlimacontrolTray;

/// C-Schnittstelle von KlimacontrolBridge.dll (Sources/KlimacontrolBridge/Bridge.swift).
/// Alle Aufrufe auf dem UI-Thread (= Hauptthread, dort läuft der MainActor des Kerns).
static class Native
{
    const string Dll = "KlimacontrolBridge.dll";

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern void kc_init([MarshalAs(UnmanagedType.LPUTF8Str)] string version);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void kc_pump();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void kc_stop();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_state_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern long kc_state_rev();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_live_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_history_json(double seconds);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_history_stats_json(double seconds);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_energy_json([MarshalAs(UnmanagedType.LPUTF8Str)] string kind, int count);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_log_tail(int lines);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_support_dir();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_third_party_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr kc_command([MarshalAs(UnmanagedType.LPUTF8Str)] string json);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern void kc_free(IntPtr p);

    /// Unterordner neben Klimacontrol.exe mit Kern, Swift-/VC++-Laufzeit und Lizenzdateien.
    public const string ResFolder = "res";

    public static string ResDir => System.IO.Path.Combine(AppContext.BaseDirectory, ResFolder);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetDllDirectoryW(string path);

    /// Vor dem ersten kc_*-Aufruf: Windows sucht native DLLs sonst nur neben der exe. Laden mit vollem Pfad holt auch
    /// die Abhängigkeiten aus `res`; SetDllDirectory deckt später per Namen nachgeladene DLLs ab.
    public static void UseResFolder()
    {
        var res = ResDir;
        if (!System.IO.File.Exists(System.IO.Path.Combine(res, Dll))) return;
        SetDllDirectoryW(res);
        NativeLibrary.SetDllImportResolver(typeof(Native).Assembly, (name, _, _) =>
            name == Dll || name == "KlimacontrolBridge" ? NativeLibrary.Load(System.IO.Path.Combine(res, Dll)) : IntPtr.Zero);
    }

    static string? Take(IntPtr p)
    {
        if (p == IntPtr.Zero) return null;
        try { return Marshal.PtrToStringUTF8(p); }
        finally { kc_free(p); }
    }

    /// Version der C-Schnittstelle (`bridgeAPIVersion` in Bridge.swift); ein Test prüft die Übereinstimmung.
    public const int ExpectedApi = 2;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int ApiVersionFn();

    /// kc_api_version der DLL; null, wenn sie die Funktion nicht exportiert. Nachgeschlagen statt per DllImport,
    /// damit eine alte DLL eine verständliche Meldung statt EntryPointNotFound bekommt.
    public static int? ApiVersion()
    {
        var lib = NativeLibrary.Load(Dll, typeof(Native).Assembly, null);
        if (!NativeLibrary.TryGetExport(lib, "kc_api_version", out var fn)) return null;
        return Marshal.GetDelegateForFunctionPointer<ApiVersionFn>(fn)();
    }

    public static void Init(string version) => kc_init(version);
    public static string StateJson() => Take(kc_state_json()) ?? "null";
    /// Revisionszähler des Schnappschusses: kc_state_json nur bei geändertem Zähler lesen.
    public static long StateRev() => kc_state_rev();
    /// {"busy":…,"nextRefresh":…} – ändert sich bei jeder Abfrage, darum nicht im Schnappschuss.
    public static string LiveJson() => Take(kc_live_json()) ?? "{}";
    public static string HistoryJson(double seconds) => Take(kc_history_json(seconds)) ?? "[]";
    public static string HistoryStatsJson(double seconds) => Take(kc_history_stats_json(seconds)) ?? "{}";
    /// Verbrauch je Zeitraum (kind: day/week/month) als JSON, oder {"error":…}.
    public static string EnergyJson(string kind, int count) => Take(kc_energy_json(kind, count)) ?? "{}";
    public static string LogTail(int lines) => Take(kc_log_tail(lines)) ?? "";
    /// Swift liefert „C:/…“ – für Explorer und Anzeige in Windows-Schreibweise.
    public static string SupportDir() => System.IO.Path.GetFullPath(Take(kc_support_dir()) ?? ".");
    /// Quellen und Lizenzen (Liste von ThirdPartyNotice).
    public static string ThirdPartyJson() => Take(kc_third_party_json()) ?? "[]";
    /// null = angenommen, sonst Fehlermeldung.
    public static string? Command(string json) => Take(kc_command(json));
}
