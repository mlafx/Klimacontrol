using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// Reiter der Einstellungen in der Reihenfolge im TabControl (wie am Mac).
public enum SettingsTab { General, Appearance, Connection, Device, Log, Licenses }

/// Einstellungen; je Reiter eine eigene Datei (SettingsWindow.General.cs usw.). Die Einrichtung macht das
/// Hauptfenster. Rückfragen, Hinweise und Datei-Dialoge nur über `Dialogs` (nie innerhalb von kc_pump).
public partial class SettingsWindow : Window
{
    static Core Core => Core.Shared;
    static readonly CultureInfo De = CultureInfo.GetCultureInfo("de-DE");
    bool updating;

    /// Zähler eines langlaufenden Kern-Befehls (`LoginSeq`, `RelocateSeq`, `ExportSeq`, `ImportSeq`): merkt den
    /// zuletzt gesehenen Stand, damit jedes Ergebnis genau einmal erscheint und keins von vor dem Öffnen des Fensters.
    class SeqWatch
    {
        int seen;
        public SeqWatch(int current) => seen = current;

        /// true, wenn der Kern seit dem letzten Aufruf ein neues Ergebnis gemeldet hat.
        public bool Advance(int seq)
        {
            if (seq == seen) return false;
            seen = seq;
            return true;
        }
    }

    /// Dazu der laufende Auftrag aus diesem Fenster (null = keiner); nur dessen Ergebnis zeigt dieses Fenster.
    sealed class SeqWatch<TJob> : SeqWatch where TJob : class
    {
        public SeqWatch(int current) : base(current) { }
        public TJob? Pending { get; set; }
    }

    SettingsTab CurrentTab => (SettingsTab)Tabs.SelectedIndex;

    public SettingsWindow()
    {
        // Ergebnisse von vor dem Öffnen nicht noch einmal zeigen.
        loginSeq = new SeqWatch(Core.Snap.LoginSeq);
        relocateSeq = new SeqWatch(Core.Snap.RelocateSeq);
        importSeq = new SeqWatch<PendingImport>(Core.Snap.ImportSeq);
        exportSeq = new SeqWatch<string>(Core.Snap.ExportSeq);
        InitializeComponent();
        Theme.AttachWindow(this);
        Icon = TrayIcon.WindowIcon();
        VersionText.Text = $"Klimacontrol {App.Version} für Windows · Daten in {Native.SupportDir()}";
        RenderUpdates();
        NameBox.Text = Core.Snap.DisplayName;
        PriceBox.Text = PriceText(Core.Snap);
        RefreshWarnIcon.Data = Geometry.Parse(Icons.Warning);
        RenderAutostart();
        RenderHotkey();
        // „Nur Ereignisse“ merkt sich die Anzeige; Standard an.
        eventsOnly = Prefs.GetBool("LogEventsOnly", true);
        EventsOnlyBox.IsChecked = eventsOnly;
        Tabs.SelectionChanged += (_, e) =>
        {
            if (e.Source != Tabs) return;
            if (CurrentTab == SettingsTab.Log) LoadLog(force: true);
            if (CurrentTab == SettingsTab.Licenses) LoadNotices();
        };
        // Protokoll-Reiter: alle 3 s den Dateistempel prüfen, neu lesen nur bei geänderter Datei.
        var tick = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        tick.Tick += (_, _) => { if (IsVisible && CurrentTab == SettingsTab.Log) LoadLog(force: false); };
        tick.Start();
        Closed += (_, _) => { Core.Changed -= Render; tick.Stop(); };
        Core.Changed += Render;
        App.TrackVisibility(this, "settings");
        Render();
        AttachAppearance();
    }

    public void SelectTab(SettingsTab tab)
    {
        Tabs.SelectedIndex = (int)tab;
        if (tab == SettingsTab.Log) LoadLog(force: true);
        if (tab == SettingsTab.Licenses) LoadNotices();
    }

    void Render()
    {
        updating = true;
        try { RenderInner(Core.Snap); }
        finally { updating = false; }
    }

    /// WLAN-Zugang vorhanden. Über die Cloud eingerichtet: Adresse leer, Port 0.
    static bool HasLan(Snapshot s) => s.Configured && s.Port is > 0 && !string.IsNullOrEmpty(s.Ip);

    /// Anlagen-ID gesetzt (über die Cloud nötig); die Bridge schickt „0“, wenn keine bekannt ist.
    static bool HasDeviceId(Snapshot s) => !string.IsNullOrEmpty(s.DeviceId) && s.DeviceId != "0";

    static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    void RenderInner(Snapshot s)
    {
        // Allgemein
        EnsureRefreshItems(s.Options.Refresh);
        var preset = !customRefresh && s.Options.Refresh.Choices.Any(c => (int)c.Seconds == s.RefreshSeconds);
        RefreshBox.SelectedItem = RefreshBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (int)i.Tag == (preset ? s.RefreshSeconds : 0));
        CustomRefreshPanel.Visibility = Show(!preset);
        if (!CustomRefreshBox.IsKeyboardFocusWithin) CustomRefreshBox.Text = s.RefreshSeconds.ToString(CultureInfo.InvariantCulture);
        RefreshWarn.Visibility = Show(s.RefreshSeconds < s.Options.Refresh.WarnBelow);
        HistoryCsvBox.IsChecked = s.HistoryCSV;

        // Darstellung: „Auf Standard zurücksetzen“ nur, wenn etwas vom Standard abweicht (sagt der Kern).
        LookResetButton.IsEnabled = !s.AppearanceIsStandard;

        // Verbindung
        var lan = HasLan(s);
        ConnNoDevice.Visibility = Show(!s.Configured);
        ConnPanel.Visibility = Show(s.Configured);
        RenderStatus(s);
        // Nur bei geänderter Auswahl neu füllen – sonst klappt eine offene Liste bei jedem neuen Zustand zu.
        if (!ModeBox.Items.Cast<ComboBoxItem>().Select(i => $"{i.Tag}\u001e{i.Content}")
                .SequenceEqual(s.ConnectionModes.Select(m => $"{m[0]}\u001e{m[1]}")))
            ModeBox.ItemsSource = s.ConnectionModes.Select(m => new ComboBoxItem { Content = m[1], Tag = m[0] }).ToList();
        ModeBox.SelectedItem = ModeBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == s.ConnectionMode);
        ModeRow.IsEnabled = lan || s.CloudAccount != null;
        ModeHint.Text = s.Options.ConnectionModes.FirstOrDefault(m => m.Id == s.ConnectionMode)?.Help ?? "";
        var account = s.CloudAccount != null;
        CloudOn.Visibility = Show(account);
        CloudNoId.Visibility = Show(!account && !HasDeviceId(s));
        CloudOff.Visibility = Show(!account && HasDeviceId(s));
        CloudAccountText.Text = s.CloudAccount ?? "";
        UpdateLoginButton();
        CloudFoot.Text = s.AccountFooter;
        if (loginSeq.Advance(s.LoginSeq))
        {
            CloudPass.Clear(); // auch nach einem Fehler nicht im Speicher lassen
            Result(CloudResult, s.LoginError ?? s.Options.Texts.AccountSignedIn, s.LoginError == null);
        }

        // Anlage
        DeviceNoDevice.Visibility = Show(!s.Configured);
        DevicePanel.Visibility = Show(s.Configured);
        RenderSetAside(s);
        DeviceNameText.Text = s.DeviceName ?? "–";
        AddressText.Text = lan ? s.Ip : "über Midea-Konto";
        // Nur mit Anlagen-ID: die Suche findet die Anlage über ihre ID.
        RelocateRow.Visibility = Show(HasDeviceId(s));
        RenderRelocate(s);
        // Signalton: Wert der Anlage, sonst die gemerkte Einstellung; ohne Zustand nicht schaltbar.
        BeepBox.IsChecked = s.State?.Sound ?? s.Beep;
        SoundRow.IsEnabled = s.State != null;
        PortLabel.Visibility = PortText.Visibility = Show(lan);
        DeviceIdLabel.Visibility = DeviceIdText.Visibility = Show(HasDeviceId(s));
        PortText.Text = s.Port?.ToString(CultureInfo.InvariantCulture) ?? "";
        DeviceIdText.Text = s.DeviceId ?? "";
        IdentifierText.Text = string.IsNullOrEmpty(s.DeviceIdentifier) ? "–" : s.DeviceIdentifier;
        CredentialsText.Text = lan ? "gespeichert, nur für dich lesbar" : "keine – Steuerung über das Midea-Konto";
        RenderBackupState(s, lan);
        RenderImport(s);
        RenderExport(s);

        // Ohne Debug gibt es nichts auszublenden – „Nur Ereignisse“ dann aus.
        var debugChanged = DebugBox.IsChecked != s.DebugLog;
        DebugBox.IsChecked = s.DebugLog;
        EventsOnlyBox.IsEnabled = s.DebugLog;
        DebugHint.Text = s.DebugLog
            ? "An: zusätzlich jede Nachricht an die Anlage und an Midea – groß, die Datei wird alle paar Stunden neu begonnen."
            : "Aus (Standard): Start, Verbindungsweg, Befehle, Fehler und Timer stehen trotzdem im Protokoll.";
        if (debugChanged && logRaw != null && IsVisible && CurrentTab == SettingsTab.Log) LoadLog(force: true);
    }

    /// Meldung „Was ist passiert. Was tun.“ mit dem Code klein am Ende (wie die Meldungen des Kerns).
    void SetMessage(TextBlock target, string what, string? todo, string? code)
    {
        var text = string.IsNullOrWhiteSpace(todo) ? what : what.TrimEnd() + " " + todo!.Trim();
        target.Inlines.Clear();
        target.Inlines.Add(new Run(text));
        if (!string.IsNullOrWhiteSpace(code))
            target.Inlines.Add(new Run($" ({code})") { FontSize = Math.Max(9, target.FontSize - 2), Foreground = (Brush)FindResource("Sub") });
    }

    /// Ergebniszeile; ein Code am Ende des Kerntexts („… (file-4)“) erscheint klein und grau.
    void Result(TextBlock target, string text, bool ok)
    {
        var (main, code) = SplitCode(text);
        target.Foreground = (Brush)FindResource(ok ? "Ok" : "Warn");
        SetMessage(target, main, null, code);
        target.Visibility = Visibility.Visible;
    }

    /// „Text. (code)“ → („Text.“, „code“); ohne Code am Ende (kurz, ohne Leerzeichen) bleibt der Text ganz.
    internal static (string Text, string? Code) SplitCode(string text)
    {
        var t = text.TrimEnd();
        if (t.Length < 3 || t[^1] != ')') return (text, null);
        var open = t.LastIndexOf('(');
        if (open <= 0) return (text, null);
        var code = t[(open + 1)..^1];
        if (code.Length == 0 || code.Length > 40 || code.Any(char.IsWhiteSpace)) return (text, null);
        return (t[..open].TrimEnd(), code);
    }

    /// Hinweis mit „OK“ (über Dialogs, also nach kc_pump).
    void Warn(string title, string? text)
    {
        if (text != null) _ = Dialogs.Warn(this, title, text);
    }

    /// Fehlerrückgabe eines Kern-Befehls anzeigen (der Kern liefert den Text, nil = in Ordnung).
    void WarnIfFailed(string? error) => Warn("Nicht übernommen", error);

    /// Rückfrage des Kerns (Titel, Text, Knöpfe); true nur beim Bestätigen (Esc/Abbrechen = false).
    async Task<bool> Confirm(PromptInfo p) =>
        (p.Warning ? await Dialogs.AskWarn(this, p.Title, p.Message, p.Confirm, p.Cancel)
                   : await Dialogs.Ask(this, p.Title, p.Message, p.Confirm, p.Cancel)) == 0;

    /// Rückfrage mit benanntem Knopf; true nur bei diesem Knopf (Esc/Abbrechen = false).
    async Task<bool> Confirm(string title, string text, string action) =>
        await Dialogs.Ask(this, title, text, action, "Abbrechen") == 0;

    /// Datei im Explorer markieren; fehlt sie, den Ordner öffnen (App.ShowInExplorer findet auch umgeleitete Pfade).
    static void ShowInExplorer(string path) => App.ShowInExplorer(path);

    void OpenMain_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).ShowMain();
}
