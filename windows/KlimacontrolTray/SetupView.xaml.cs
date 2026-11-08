using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Einrichtung nach `Setup.Path`: Startseite (null bzw. "backup"), "account" oder "manual". Steht in der Steuerspalte,
/// solange `Snap.Configured` falsch ist.
public partial class SetupView : UserControl
{
    static Core Core => Core.Shared;

    const string NothingShown = "\u0000";
    /// Zuletzt gezeigter Weg ("account", "manual" oder null = Startseite).
    string? shown = NothingShown;
    bool autoScanned;

    public SetupView()
    {
        InitializeComponent();

        // Erst abmelden: Loaded kann beim Umhängen zwischen Spalten ohne Unloaded dazwischen kommen.
        Loaded += (_, _) =>
        {
            Core.Changed -= Render;
            Core.Changed += Render;
            Render();
            AutoScan();
        };
        Unloaded += (_, _) => Core.Changed -= Render;
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible) return;
            Render();
            AutoScan();
        };
        // Esc: zurück zur Startseite.
        KeyDown += (_, e) =>
        {
            if (e.Handled || e.Key != Key.Escape || shown == null || shown == NothingShown) return;
            e.Handled = true;
            Back();
        };
    }

    internal static void Back() => Core.Send(Cmd.SetupPath);

    /// Beim Schließen des Fensters: abmelden, Passwort und Zugangsdaten nicht in den Feldern lassen.
    public void Detach()
    {
        Core.Changed -= Render;
        Account.Detach();
        Manual.Detach();
    }

    /// Einmal gleich im WLAN suchen, wenn noch nichts gefunden ist – beide Wege brauchen die gefundene Anlage.
    void AutoScan()
    {
        var snap = Core.Snap;
        var s = snap.Setup;
        if (autoScanned || !IsVisible || snap.Configured || s.Discovered.Count > 0 || s.Scanning) return;
        autoScanned = true;
        Core.Send(Cmd.Scan);
    }

    static string? Normalize(string? path) => path is "account" or "manual" ? path : null;

    /// Statisch, weil Hauptfenster und Flyout je eine Ansicht haben: nur eine fragt, und keine ein zweites Mal, solange
    /// der Schnappschuss nach `dismissCompletion` noch den alten Stand zeigt.
    static bool completionTaken;

    void Render()
    {
        var snap = Core.Snap;
        // Vor `Show`: Die Ansicht verschwindet gleich (eingerichtet), der Abschluss kommt als eine Rückfrage.
        if (snap.Setup.Completion is not { } completion) completionTaken = false;
        else if (!completionTaken)
        {
            completionTaken = true;
            _ = Complete(completion);
        }

        var path = Normalize(snap.Setup.Path);
        if (path != shown) Show(path);
        if (path == "account") Account.Render();
        else if (path == "manual") Manual.Render();
    }

    // MARK: Abschluss der Einrichtung

    /// Abschluss der Einrichtung als eine Rückfrage (Titel, Absätze, Knöpfe und das Häkchen „Nur WLAN“ liefert der Kern in
    /// `Completion.Prompt`); danach immer `dismissCompletion`. Das Häkchen ist zu Beginn gesetzt und gilt wie am Mac
    /// unabhängig vom Knopf („Später“ lässt es nicht verfallen).
    async Task Complete(CompletionInfo c)
    {
        try
        {
            await Dialogs.AfterPump();
            if (c.Prompt is not { } p) return;
            var text = string.Join("\n\n", p.Paragraphs);
            var buttons = p.Secondary is { Length: > 0 } secondary ? new[] { p.Primary, secondary } : new[] { p.Primary };
            int choice;
            var lan = false;
            if (p.LanOnlyChoice is { Length: > 0 } lanText)
                (choice, lan) = await Dialogs.AskWithOption(DialogOwner(), p.Title, text, lanText, buttons);
            else
                choice = await Dialogs.Ask(DialogOwner(), p.Title, text, buttons);
            var save = c.OfferBackup && choice == 0;
            if (lan && Core.Send(Cmd.ApplySuggestedMode) is { } err)
                await Dialogs.Warn(DialogOwner(), L.T("setup.view.windows.modeFailedTitle"), err);
            if (save) await SaveBackup();
        }
        catch (Exception ex) { App.Trace("Abschluss der Einrichtung: " + ex.GetType().Name); }
        finally { Core.Send(Cmd.DismissCompletion); }
    }

    /// Speichern-Dialog in einem lokalen Ordner (nie Dokumente/Cloud-Ordner), Warnung bei Cloud-Ordnern, dann
    /// `exportBackup`. Liefert den Pfad bei Erfolg, sonst null (abgebrochen bzw. Fehler schon gemeldet).
    async Task<string?> SaveBackup()
    {
        var folder = Dialogs.SaveFolder();
        while (true)
        {
            await Dialogs.AfterPump();
            var texts = Core.Snap.Options.Texts;
            var dlg = new Microsoft.Win32.SaveFileDialog
            {
                Title = texts.ExportBackupPanelTitle,
                FileName = texts.ExportBackupFileName,
                Filter = L.T("settings.device.windows.backupFilter"),
                InitialDirectory = folder,
            };
            var owner = DialogOwner();
            if ((owner != null ? dlg.ShowDialog(owner) : dlg.ShowDialog()) != true) return null;
            if (Dialogs.IsCloudFolder(dlg.FileName))
            {
                var c = await Dialogs.AskCloudFolder(DialogOwner(), dlg.FileName);
                if (c == 0) continue;
                if (c != 1) return null;
            }
            if (Core.Send(Cmd.ExportBackup, ("path", dlg.FileName)) is { } err)
            {
                await Dialogs.Warn(DialogOwner(), L.T("file.notBackedUpTitle"), err);
                return null;
            }
            return dlg.FileName;
        }
    }

    /// Fenster für Dialoge: das eigene, solange es offen ist.
    Window? DialogOwner() => Window.GetWindow(this) is { IsVisible: true } w ? w : null;

    /// Weg wechseln: nur der passende Baustein ist sichtbar; Tastaturfokus wandert mit (Enter/Esc bleiben im Ablauf).
    void Show(string? path)
    {
        var first = shown == NothingShown;
        if (shown == "account") Account.Detach(); // Passwort beim Verlassen nicht im Speicher lassen
        shown = path;
        if (path == "account") Account.Enter();
        else if (path == "manual") Manual.Enter();
        else Start.Reset();
        Start.Visibility = path == null ? Visibility.Visible : Visibility.Collapsed;
        Account.Visibility = path == "account" ? Visibility.Visible : Visibility.Collapsed;
        Manual.Visibility = path == "manual" ? Visibility.Visible : Visibility.Collapsed;
        // Beim ersten Anzeigen nur in einen Ablauf fokussieren, nicht in die Startseite.
        if (first && path == null) return;
        Dispatcher.BeginInvoke(() =>
        {
            if (!IsVisible || shown != path) return;
            if (path == "account") Account.FocusFirst();
            else if (path == "manual") Manual.FocusFirst();
            else Start.FocusFirst();
        }, DispatcherPriority.Input);
    }
}
