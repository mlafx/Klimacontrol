using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;

namespace KlimacontrolTray;

/// Reiter „Protokoll“.
public partial class SettingsWindow
{
    // Protokoll: letzter Dateistempel und rohes Dateiende (null = noch nicht gelesen).
    DateTime logStamp;
    string? logRaw;
    bool eventsOnly = true;

    // Zeitstempel im Protokoll-Reiter bleiben deutsch (wie das Protokoll selbst).
    static readonly CultureInfo De = CultureInfo.GetCultureInfo("de-DE");

    static string LogPath => Path.Combine(Native.SupportDir(), "klimacontrol.log");

    static DateTime LogStamp()
    {
        var file = new FileInfo(LogPath);
        return file.Exists ? file.LastWriteTimeUtc.AddTicks(file.Length) : DateTime.MinValue;
    }

    /// Liest das Protokollende nur bei geändertem Stempel (oder auf Knopfdruck). Mit „Nur Ereignisse“ werden mehr
    /// Zeilen gelesen, damit nach dem Ausblenden der DEBUG-Zeilen genug übrig bleibt.
    bool Filtering => eventsOnly && Core.Snap.DebugLog;

    void LoadLog(bool force)
    {
        var stamp = LogStamp();
        if (!force && logRaw != null && stamp == logStamp) return;
        logStamp = stamp;
        var fresh = Native.LogTail(Filtering ? 3000 : 300);
        if (!force && fresh == logRaw) return;
        logRaw = fresh;
        ShowLog();
    }

    void ShowLog()
    {
        var shown = RenderLog(logRaw ?? "", Filtering);
        if (shown.Length == 0) shown = L.T("settings.log.empty");
        if (shown == LogBox.Text) return;
        // Nur ans Ende springen, wenn man schon unten war – sonst bleibt die Leseposition stehen.
        var atEnd = LogBox.ExtentHeight == 0 || LogBox.VerticalOffset + LogBox.ViewportHeight >= LogBox.ExtentHeight - 4;
        LogBox.Text = shown;
        if (atEnd) LogBox.ScrollToEnd();
    }

    /// Zeitstempel in Ortszeit (die Datei schreibt UTC); mit `eventsOnly` fallen DEBUG-Zeilen samt Folgezeilen
    /// (Hex ohne Zeitstempel) weg. Höchstens die letzten 300 Zeilen.
    static string RenderLog(string raw, bool eventsOnly)
    {
        var lines = raw.Replace("\r\n", "\n").Split('\n');
        var output = new List<string>(lines.Length);
        var dropping = false;
        foreach (var line in lines)
        {
            if (line.Length > 21 && line[19] == 'Z'
                && DateTime.TryParseExact(line[..20], "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture,
                                          DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var utc))
            {
                var rest = line[20..].TrimStart(' ');
                dropping = eventsOnly && rest.StartsWith("DEBUG", StringComparison.Ordinal);
                if (!dropping) output.Add(utc.ToLocalTime().ToString("dd.MM. HH:mm:ss", De) + " " + rest);
            }
            else if (!dropping)
            {
                output.Add(line);
            }
        }
        // Leere Schlusszeile (Datei endet mit Zeilenumbruch) nicht mitzählen.
        while (output.Count > 0 && output[^1].Length == 0) output.RemoveAt(output.Count - 1);
        return string.Join("\n", output.Skip(Math.Max(0, output.Count - 300)));
    }

    void LogRefresh_Click(object sender, RoutedEventArgs e) => LoadLog(force: true);

    void LogShow_Click(object sender, RoutedEventArgs e) => ShowInExplorer(LogPath);

    async void LogClear_Click(object sender, RoutedEventArgs e)
    {
        if (!await Confirm(L.T("settings.log.clear.title"), L.T("settings.log.clear.message"), L.T("settings.log.clear.confirm"))) return;
        Warn(L.T("settings.log.windows.notCleared"), Core.Send(Cmd.ClearLog));
        logRaw = null;
        LoadLog(force: true);
    }

    void Debug_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.DebugLog, ("on", DebugBox.IsChecked == true));

    void EventsOnly_Click(object sender, RoutedEventArgs e)
    {
        eventsOnly = EventsOnlyBox.IsChecked == true;
        Prefs.SetBool("LogEventsOnly", eventsOnly);
        // Mit „Nur Ereignisse“ wird mehr gelesen – darum neu lesen statt nur neu aufbereiten.
        LoadLog(force: true);
    }
}
