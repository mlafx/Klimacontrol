using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// Reiter „Anlage“: Signalton, Sicherung, Neu einrichten, Adresse neu suchen.
public partial class SettingsWindow
{
    // „Sicherung einlesen“ läuft asynchron; der Auftrag stammt aus diesem Fenster.
    readonly SeqWatch<PendingImport> importSeq;
    sealed record PendingImport(string Path, bool ReplaceScenes, bool AllowOtherDevice);
    // Der Kern meldet `Relocating` erst nach dem nächsten Pumpen; bis dahin merkt `relocateRequested` den Klick.
    readonly SeqWatch relocateSeq;
    bool relocateRequested;
    // Beiseitegelegte Einrichtungsdatei nur einmal je „keine Anlage“ suchen (Render läuft bei jedem neuen Zustand).
    bool setAsideChecked;
    string? setAsideFile;

    void Beep_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.Sound, ("on", BeepBox.IsChecked == true));

    void Export_Click(object sender, RoutedEventArgs e) => _ = ExportBackup();

    /// „Zugangsdaten sichern“: startet in einem lokalen Ordner, warnt vor Cloud-Ordnern. true = gesichert.
    async Task<bool> ExportBackup()
    {
        var folder = Dialogs.SaveFolder();
        while (true)
        {
            await Dialogs.AfterPump();
            // Titel und Dateiname des Dialogs sowie die Rückfrage zu Cloud-Ordnern gibt der Kern vor.
            var texts = Core.Snap.Options.Texts;
            var dlg = new SaveFileDialog
            {
                Title = texts.ExportBackupPanelTitle,
                FileName = texts.ExportBackupFileName,
                Filter = L.T("settings.device.windows.backupFilter"),
                InitialDirectory = folder,
            };
            if (dlg.ShowDialog(this) != true) return false;
            if (Dialogs.IsCloudFolder(dlg.FileName))
            {
                var choice = await Dialogs.AskCloudFolder(this, dlg.FileName);
                if (choice == 0) continue;
                if (choice != 1) return false;
            }
            var err = Core.Send(Cmd.ExportBackup, ("path", dlg.FileName));
            Result(BackupResult, err ?? L.F("result.backupExported", ("name", Path.GetFileName(dlg.FileName))), err == null);
            return err == null;
        }
    }

    /// Noch nicht gesichert → hervorgehoben. Nur mit WLAN-Zugang – über das Midea-Konto gibt es nichts zu verlieren.
    void RenderBackupState(Snapshot s, bool lan)
    {
        BackupState.Visibility = Show(lan);
        if (!lan) return;
        if (s.CredentialsBackedUp)
        {
            BackupState.Text = L.T("settings.device.windows.backupDone");
            BackupState.Foreground = (Brush)FindResource("Sub");
            BackupState.FontWeight = FontWeights.Normal;
        }
        else
        {
            BackupState.Text = L.T("settings.device.windows.backupMissing");
            BackupState.Foreground = (Brush)FindResource("Warn");
            BackupState.FontWeight = FontWeights.SemiBold;
        }
    }

    /// Erst „Szenen ersetzen?“, dann `importBackup`. Rückgabe nil heißt nur „gestartet“ – das Ergebnis kommt über
    /// ImportSeq/ImportResult (RenderImport).
    async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (importSeq.Pending != null) return;
        await Dialogs.AfterPump();
        var dlg = new OpenFileDialog
        {
            Title = Core.Snap.Options.Texts.ImportPanelTitle,
            Filter = L.T("settings.device.windows.importFilter"),
            InitialDirectory = Dialogs.SaveFolder(),
        };
        if (dlg.ShowDialog(this) != true) return;
        var replace = false;
        if (Core.Snap.Scenes.Count > 0)
        {
            // Rückfrage vom Kern: Cancel = Szenen behalten, Confirm = ersetzen; Esc bricht das Einlesen ab.
            var p = Core.Snap.Options.Prompts.ReplaceScenes;
            var choice = await Dialogs.Ask(this, p.Title, p.Message, p.Cancel, p.Confirm);
            if (choice < 0) return;
            replace = choice == 1;
        }
        StartImport(new PendingImport(dlg.FileName, replace, false));
    }

    void StartImport(PendingImport job)
    {
        var err = Core.Send(Cmd.ImportBackup, ("path", job.Path), ("replaceScenes", job.ReplaceScenes), ("allowOtherDevice", job.AllowOtherDevice));
        if (err != null)
        {
            importSeq.Pending = null;
            Result(BackupResult, err, false);
            RenderImportButton();
            return;
        }
        importSeq.Pending = job;
        BackupResult.Inlines.Clear();
        BackupResult.Text = L.T("settings.device.windows.importing");
        BackupResult.Foreground = (Brush)FindResource("Sub");
        BackupResult.Visibility = Visibility.Visible;
        RenderImportButton();
    }

    void RenderImportButton()
    {
        ImportButton.IsEnabled = importSeq.Pending == null;
        ImportButton.Content = importSeq.Pending == null ? L.T("settings.device.backup.import") : L.T("settings.device.windows.importButtonBusy");
    }

    /// Neues Import-Ergebnis des Kerns. Nur für einen Auftrag aus diesem Fenster (die Einrichtung im Hauptfenster
    /// zeigt ihr eigenes Ergebnis).
    void RenderImport(Snapshot s)
    {
        if (!importSeq.Advance(s.ImportSeq)) return;
        var job = importSeq.Pending;
        if (job == null || s.ImportResult is not { } r) return;
        importSeq.Pending = null;
        RenderImportButton();
        // Alle Ausgänge (eingelesen, Anlage antwortet nicht, Fehler) liefert der Kern als fertigen Text.
        if (r.Ok) { Result(BackupResult, r.Text ?? "", r.Verified != false); return; }
        if (r.ErrorCode == "otherDevice" && !job.AllowOtherDevice && r.Prompt is { } prompt)
        {
            BackupResult.Visibility = Visibility.Collapsed;
            _ = AskOtherDevice(job, prompt);
            return;
        }
        Result(BackupResult, r.Text ?? r.Error ?? "", false);
    }

    /// Sicherung einer anderen Anlage → nachfragen (Text und Knöpfe vom Kern), dann mit allowOtherDevice erneut senden.
    /// Abbrechen steht vorn und ist damit Standard.
    async Task AskOtherDevice(PendingImport job, PromptInfo p)
    {
        var choice = p.Warning ? await Dialogs.AskWarn(this, p.Title, p.Message, p.Cancel, p.Confirm)
                               : await Dialogs.Ask(this, p.Title, p.Message, p.Cancel, p.Confirm);
        if (choice != 1) { Result(BackupResult, L.T("settings.device.windows.importDeclined"), true); return; }
        StartImport(job with { AllowOtherDevice = true });
    }

    /// Der Kern legt device.json beiseite (umbenannt in „device.entfernt-….json“). „Erst sichern …“ ist freiwillig
    /// und Standard bei Enter, danach wird erneut gefragt; ohne Sicherung trägt die Rückfrage das Warnsymbol.
    async void Forget_Click(object sender, RoutedEventArgs e)
    {
        // Gerade gesichert: Der Schnappschuss meldet CredentialsBackedUp erst nach der nächsten Abfrage.
        var exported = false;
        while (true)
        {
            var prompts = Core.Snap.Options.Prompts;
            var p = exported || !Core.Snap.ForgetNeedsBackup ? prompts.Forget : prompts.ForgetNeedsBackup;
            var choice = p.Warning
                ? await Dialogs.AskWarn(this, p.Title, p.Message, p.Backup, p.Confirm, p.Cancel)
                : await Dialogs.Ask(this, p.Title, p.Message, p.Backup, p.Confirm, p.Cancel);
            if (choice == 0)
            {
                // Gesichert: gleich wieder fragen, damit niemand den Weg zurück suchen muss.
                if (await ExportBackup()) { exported = true; continue; }
                return;
            }
            if (choice != 1) return;
            break;
        }
        var err = Core.Send(Cmd.ForgetDevice);
        if (err != null) { Warn(L.T("settings.device.windows.forgetFailedTitle"), err); return; }
        BackupResult.Visibility = Visibility.Collapsed;
        RelocateResult.Visibility = Visibility.Collapsed;
        importSeq.Pending = null;
        RenderImportButton();
        setAsideChecked = false;
    }

    /// Ohne Anlage: zeigt, ob eine beiseitegelegte Einrichtungsdatei (device.entfernt-….json) im Datenordner liegt.
    void RenderSetAside(Snapshot s)
    {
        if (s.Configured) { setAsideChecked = false; SetAsidePanel.Visibility = Visibility.Collapsed; return; }
        if (setAsideChecked) return;
        setAsideChecked = true;
        setAsideFile = null;
        try
        {
            setAsideFile = new DirectoryInfo(Native.SupportDir()).EnumerateFiles("device.entfernt-*.json")
                .OrderByDescending(f => f.LastWriteTimeUtc).FirstOrDefault()?.FullName;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        SetAsidePanel.Visibility = Show(setAsideFile != null);
        if (setAsideFile != null)
            SetAsideText.Text = L.F("settings.device.windows.setAsideNote", ("name", Path.GetFileName(setAsideFile)));
    }

    void SetAsideShow_Click(object sender, RoutedEventArgs e) => ShowInExplorer(setAsideFile ?? Native.SupportDir());

    /// „Adresse neu suchen“: Kern-Befehl `relocate` (asynchron). Während `Relocating` ist der Knopf aus
    /// („Suche …“); das Ergebnis kommt über RelocateSeq/RelocateOK, der Grund eines Misserfolgs steht in `Notice`.
    void Relocate_Click(object sender, RoutedEventArgs e)
    {
        if (relocateRequested || Core.Snap.Relocating) return;
        RelocateResult.Visibility = Visibility.Collapsed;
        var err = Core.Send(Cmd.Relocate);
        if (err != null) { Result(RelocateResult, err, false); return; }
        relocateRequested = true;
        RenderRelocate(Core.Snap);
    }

    void RenderRelocate(Snapshot s)
    {
        if (s.Relocating) relocateRequested = false; // der Kern hat übernommen
        if (relocateSeq.Advance(s.RelocateSeq))
        {
            relocateRequested = false;
            // Text aus dem Kern (wie am Mac), Rückmeldung am Ort der Aktion.
            Result(RelocateResult, s.RelocateMessage ?? "", s.RelocateOK);
        }
        var busy = s.Relocating || relocateRequested;
        RelocateButton.IsEnabled = !busy;
        RelocateButton.Content = busy ? L.T("main.relocate.searching") : L.T("settings.device.relocate.button");
    }
}
