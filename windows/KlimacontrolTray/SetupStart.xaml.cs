using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// Startseite der Einrichtung: „Mit Midea-Konto“, „Zugangsdaten eingeben“ oder „Sicherung einlesen“ (direkt von hier,
/// asynchron an der Anlage geprüft).
public partial class SetupStart : UserControl
{
    static Core Core => Core.Shared;

    public SetupStart()
    {
        InitializeComponent();
        HeadIcon.Content = Accent(Icons.Make(Icons.AirConditioner, 30, null, 1.3));
        AccountIcon.Content = Accent(Icons.Make(SetupIcons.Person, 22));
        ManualIcon.Content = Accent(Icons.Make(SetupIcons.Key, 22));
        BackupIcon.Content = Accent(Icons.Make(SetupIcons.Document, 22));
        AccountChevron.Content = Chevron();
        ManualChevron.Content = Chevron();
        BackupChevron.Content = Chevron();
        SettingsLinkText.ToolTip = L.Tip("setup.view.windows.settingsHelp", Hotkeys.Ctrl(","));
    }

    static Path Accent(Path p)
    {
        p.SetResourceReference(Shape.StrokeProperty, "Accent");
        return p;
    }

    static Path Chevron()
    {
        var p = Icons.Make(SetupIcons.ChevronRight, 12, null, 1.5);
        p.SetResourceReference(Shape.StrokeProperty, "Sub");
        p.Opacity = 0.7;
        return p;
    }

    /// Nach „‹ Zurück“, damit Tastatur und Esc im Ablauf bleiben.
    public void FocusFirst() => AccountCard.Focus();

    /// Beim Verlassen der Startseite alte Meldungen wegräumen (der Hinweis „wird eingelesen …“ bleibt, solange es läuft).
    public void Reset()
    {
        if (!importing) ImportResult.Visibility = Visibility.Collapsed;
    }

    void Account_Click(object sender, RoutedEventArgs e) => Choose("account");

    void Manual_Click(object sender, RoutedEventArgs e) => Choose("manual");

    void Choose(string path)
    {
        Reset();
        var err = Core.Send(Cmd.SetupPath, ("value", path));
        if (err != null) Show(err);
    }

    /// Meldung unter den Karten: Fehler orange (Code klein am Ende), sonst grau.
    void Show(string text, bool error = true)
    {
        SetupUi.SetMessage(ImportResult, text);
        ImportResult.SetResourceReference(TextBlock.ForegroundProperty, error ? "Warn" : "Sub");
        ImportResult.Visibility = Visibility.Visible;
    }

    Window? Owner() => Window.GetWindow(this) is { IsVisible: true } w ? w : null;

    // MARK: Sicherung einlesen

    /// Ergebnis kommt über `Snap.ImportSeq`/`ImportResult`; Datei und Antworten bleiben für den zweiten Versuch
    /// („Anlage wechseln?“) stehen.
    bool importing;
    int importSeq;
    string importPath = "";
    bool importReplace, importOther;

    /// Der Dialog öffnet erst nach kc_pump (Dialogs.AfterPump).
    async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (importing) return;
        Reset();
        await Dialogs.AfterPump();
        var dlg = new OpenFileDialog { Title = Core.Snap.Options.Texts.ImportPanelTitle, Filter = L.T("settings.device.windows.importFilter") };
        var owner = Owner();
        if ((owner != null ? dlg.ShowDialog(owner) : dlg.ShowDialog()) != true || importing) return;
        var replace = false;
        if (Core.Snap.Scenes.Count > 0)
        {
            // Rückfrage vom Kern: Cancel = behalten, Confirm = ersetzen.
            var p = Core.Snap.Options.Prompts.ReplaceScenes;
            replace = await Dialogs.Ask(Owner(), p.Title, p.Message, p.Cancel, p.Confirm) == 1;
        }
        BeginImport(dlg.FileName, replace, false);
    }

    void BeginImport(string path, bool replace, bool other)
    {
        if (importing) return;
        importSeq = Core.Snap.ImportSeq;
        var err = Core.Send(Cmd.ImportBackup, ("path", path), ("replaceScenes", replace), ("allowOtherDevice", other));
        if (err != null)
        {
            Show(err);
            return;
        }
        (importing, importPath, importReplace, importOther) = (true, path, replace, other);
        BackupCard.IsEnabled = false;
        Show(L.T("settings.device.windows.importing"), false);
        // Selbst anmelden: Das Ergebnis soll auch ankommen, wenn die Einrichtung inzwischen verschwunden ist.
        Core.Changed -= ImportChanged;
        Core.Changed += ImportChanged;
    }

    void ImportChanged()
    {
        var snap = Core.Snap;
        if (!importing || snap.ImportSeq == importSeq) return;
        importing = false;
        Core.Changed -= ImportChanged;
        BackupCard.IsEnabled = true;
        ImportResult.Visibility = Visibility.Collapsed;
        _ = Finish(snap.ImportResult);
    }

    async Task Finish(ImportResultInfo? r)
    {
        try
        {
            if (r == null) return;
            if (!r.Ok && r.ErrorCode == "otherDevice" && !importOther && r.Prompt is { } p)
            {
                // Text und Knöpfe vom Kern; Abbrechen steht vorn und ist damit Standard.
                var a = p.Warning ? await Dialogs.AskWarn(Owner(), p.Title, p.Message, p.Cancel, p.Confirm)
                                  : await Dialogs.Ask(Owner(), p.Title, p.Message, p.Cancel, p.Confirm);
                if (a == 1) BeginImport(importPath, importReplace, true);
                return;
            }
            if (!r.Ok)
            {
                var text = r.Text ?? r.Error ?? "";
                // Noch auf der Startseite: Meldung unter den Karten, sonst als Hinweisfenster.
                if (IsVisible) Show(text);
                else await Dialogs.Warn(Owner(), L.T("setup.view.windows.importFailedTitle"), text);
                return;
            }
            // Eingelesen, aber an der Anlage nicht geprüft: Die Einrichtung ist dann schon weg – Hinweisfenster.
            if (r.Verified == false)
            {
                await Dialogs.Warn(Owner(), L.T("file.importAlertTitle"), r.Text ?? "");
            }
        }
        catch (Exception ex) { App.Trace("Sicherung einlesen: " + ex.GetType().Name); }
    }

    void Settings_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).ShowSettings(SettingsTab.General);
}
