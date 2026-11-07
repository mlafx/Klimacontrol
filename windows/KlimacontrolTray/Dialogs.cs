using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Rückfragen und Hinweise mit benannten Knöpfen – nie innerhalb von kc_pump: Ein Klick-Handler kann mitten in kc_pump
/// laufen, ein modaler Dialog dort hielte den Kern an. Darum geben alle Methoden zuerst den Dispatcher frei (`AfterPump`).
///
/// Oberflächen benutzen nur diese API, nie MessageBox/ShowDialog direkt aus Klick-Handlern:
/// - `await Dialogs.AfterPump()` – vor jedem OpenFileDialog/SaveFileDialog bzw. eigenen modalen Fenster.
/// - `await Dialogs.Ask(owner, title, text, "Starten", "Abbrechen")` → Index des Knopfs (0 = erster = Standard,
///   Enter), -1 = Esc/Schließen. Den Abbrechen-Knopf als letzten übergeben.
/// - `await Dialogs.Info(owner, title, text)` / `Dialogs.Warn(owner, title, text)` – Hinweis mit „OK“.
/// - `await Dialogs.AskWarn(owner, title, text, "Neu einrichten", "Abbrechen")` – wie Ask, aber mit Warnsymbol.
/// - `Dialogs.IsOpen` – gerade ist eine Rückfrage offen (das Fenster am Infobereich soll dann nicht zuklappen).
/// - `Dialogs.SaveFolder()` – Startordner für Speichern-Dialoge mit Zugangsdaten: lokal, nie Dokumente/OneDrive.
/// - `Dialogs.IsCloudFolder(path)` – liegt der Pfad in einem Cloud-Ordner (Liste vom Kern)?
/// - `await Dialogs.AskCloudFolder(owner, path)` – Rückfrage des Kerns vor dem Sichern in einen Cloud-Ordner (0 = anderer Ort, 1 = trotzdem).
static class Dialogs
{
    /// Gibt den Dispatcher frei: Läuft der Aufrufer gerade innerhalb von kc_pump, kehrt dieses zuerst zurück.
    public static async Task AfterPump() =>
        await Dispatcher.Yield(DispatcherPriority.Background);

    public static int OpenCount { get; private set; }
    public static bool IsOpen => OpenCount > 0;

    public static async Task<int> Ask(Window? owner, string title, string text, params string[] buttons)
    {
        await AfterPump();
        return Show(owner, DialogWindow.Kind.Question, title, text, buttons.Length > 0 ? buttons : new[] { "OK", "Abbrechen" }).Result;
    }

    /// Wie `Ask`, dazu ein Häkchen (zu Beginn gesetzt) mit der Beschriftung `option` → Index des Knopfs und Stand des Häkchens.
    public static async Task<(int Result, bool Option)> AskWithOption(Window? owner, string title, string text, string option, params string[] buttons)
    {
        await AfterPump();
        return Show(owner, DialogWindow.Kind.Question, title, text, buttons.Length > 0 ? buttons : new[] { "OK" }, option);
    }

    public static async Task Info(Window? owner, string title, string text)
    {
        await AfterPump();
        _ = Show(owner, DialogWindow.Kind.Info, title, text, new[] { "OK" });
    }

    public static async Task Warn(Window? owner, string title, string text)
    {
        await AfterPump();
        _ = Show(owner, DialogWindow.Kind.Warning, title, text, new[] { "OK" });
    }

    /// Wie `Ask`, aber mit Warnsymbol (z. B. vor „Neu einrichten“) → Index des Knopfs, -1 = Esc/Schließen.
    public static async Task<int> AskWarn(Window? owner, string title, string text, params string[] buttons)
    {
        await AfterPump();
        return Show(owner, DialogWindow.Kind.Warning, title, text, buttons.Length > 0 ? buttons : new[] { "OK", "Abbrechen" }).Result;
    }

    static (int Result, bool Option) Show(Window? owner, DialogWindow.Kind kind, string title, string text, string[] buttons, string? option = null)
    {
        var app = Application.Current;
        if (app == null || app.Dispatcher.HasShutdownStarted) return (-1, false);
        // Nur ein sichtbares, geladenes Fenster taugt als Besitzer; sonst das aktive, sonst keins (Bildschirmmitte).
        static bool Usable(Window? w) => w != null && w.IsVisible && w.IsLoaded && w.WindowState != WindowState.Minimized;
        if (!Usable(owner))
            owner = app.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive && Usable(w) && w is not DialogWindow);
        OpenCount++;
        try
        {
            var dlg = new DialogWindow(owner, kind, title, text, buttons, option);
            dlg.ShowDialog();
            return (dlg.Result, dlg.OptionChecked);
        }
        catch (Exception ex)
        {
            App.Trace("Dialog nicht gezeigt: " + ex.GetType().Name);
            return (-1, false);
        }
        finally { OpenCount--; }
    }

    /// Rückfrage „In einem Cloud-Ordner sichern?“ (Titel, Text und Knöpfe vom Kern) → 0 = anderen Ort wählen,
    /// 1 = trotzdem dort sichern, -1 = Esc/Schließen (abbrechen).
    public static Task<int> AskCloudFolder(Window? owner, string path)
    {
        var f = Core.Shared.Snap.Options.CloudFolder;
        var folder = Path.GetFileName(Path.GetDirectoryName(Path.GetFullPath(path)) ?? "");
        // Erster Knopf = Standard (Enter): der sichere „Anderen Ort wählen“.
        return AskWarn(owner, f.Title, f.MessageTemplate.Replace("{folder}", folder, StringComparison.Ordinal), f.Cancel, f.Confirm);
    }

    /// Lokaler Startordner für Dateien mit Zugangsdaten (Downloads, sonst Desktop, sonst Benutzerordner) – nie in OneDrive.
    public static string SaveFolder()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var dir in new[] { Path.Combine(home, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), home })
            if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir) && !IsCloudFolder(dir)) return dir;
        return home;
    }

    /// Liegt der Pfad in einem Cloud-Ordner? Die Pfadteile, an denen man ihn erkennt (OneDrive, iCloud, Dropbox,
    /// Google Drive), gibt der Kern vor (`options.cloudFolder.markers`); `\` zählt wie `/`.
    public static bool IsCloudFolder(string path)
    {
        var p = Path.GetFullPath(path).Replace('\\', '/');
        return Core.Shared.Snap.Options.CloudFolder.Markers.Any(m => p.Contains(m, StringComparison.Ordinal));
    }
}
