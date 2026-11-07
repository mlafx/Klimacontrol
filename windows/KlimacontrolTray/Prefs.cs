using System;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// Kleine, nicht geheime Einstellungen der Oberfläche unter HKCU\Software\Klimacontrol. Fehler beim Lesen/Schreiben
/// werden still ignoriert (dann gilt der Standardwert).
///
/// Vergebene Namen (neue hier eintragen, damit nichts doppelt belegt wird):
/// - "LogEventsOnly" (bool/DWORD, SettingsWindow)
/// - "MainWindowBounds" (string "x;y;w;h", MainWindow) · "ShowCharts"/"ShowDiagnostics" (bool/DWORD, MainWindow)
/// - "ChartRange" (int Sekunden, ChartsPanel) · "ScenesOpen" (bool, ScenesSection)
/// - "FlyoutHotkey" (string, z. B. "Ctrl+Alt+K"; leer = aus; App registriert, SettingsWindow bearbeitet)
/// - "TrayHintShown" (bool, App: Hinweis „läuft im Infobereich weiter“ nur einmal)
/// - "MiniWindow" (bool, Appearance.cs – das Mini-Fenster ist kein Kernwert)
/// - "MiniWindowPos" (string "x;y;w;h" in Bildschirm-Pixeln, MiniWindow)
/// - "TimerResultShown" (App: zuletzt als Benachrichtigung gezeigtes Timer-Ergebnis, nicht doppelt zeigen)
static class Prefs
{
    const string Key = @"Software\Klimacontrol";
    /// Alter Ort: beim ersten Start einmal nach `Key` kopiert, der alte Schlüssel bleibt stehen.
    const string LegacyKey = @"Software\PortaSplit";

    static Prefs()
    {
        try
        {
            using var existing = Registry.CurrentUser.OpenSubKey(Key);
            if (existing != null) return;
            using var legacy = Registry.CurrentUser.OpenSubKey(LegacyKey);
            if (legacy == null) return;
            using var target = Registry.CurrentUser.CreateSubKey(Key);
            foreach (var name in legacy.GetValueNames())
                if (legacy.GetValue(name) is { } v) target.SetValue(name, v, legacy.GetValueKind(name));
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException) { }
    }

    public static string? Get(string name, string? fallback = null)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(name)?.ToString() ?? fallback;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException) { return fallback; }
    }

    public static void Set(string name, string? value)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            if (value == null) k.DeleteValue(name, false); else k.SetValue(name, value);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException) { }
    }

    /// Rohwert (string oder int/DWORD).
    static object? Raw(string name)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(name);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException) { return null; }
    }

    public static bool GetBool(string name, bool fallback) => Raw(name) switch
    {
        int i => i != 0,
        string s => s == "1" || s.Equals("true", StringComparison.OrdinalIgnoreCase),
        _ => fallback,
    };

    /// Als DWORD (0/1).
    public static void SetBool(string name, bool value) => SetInt(name, value ? 1 : 0);

    public static int GetInt(string name, int fallback) => Raw(name) switch
    {
        int i => i,
        string s when int.TryParse(s, out var v) => v,
        _ => fallback,
    };

    public static void SetInt(string name, int value)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            k.SetValue(name, value, RegistryValueKind.DWord);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException) { }
    }
}
