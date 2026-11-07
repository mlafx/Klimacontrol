using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// Reiter „Allgemein“: Name, Strompreis, Abfrage-Abstand, Verlauf, Autostart, Updates, Tastenkürzel.
public partial class SettingsWindow
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunValue = "Klimacontrol";
    bool customRefresh;
    // „Verlauf exportieren“ läuft im Hintergrund; der Auftrag ist der Dateiname.
    readonly SeqWatch<string> exportSeq;

    void Name_Click(object sender, RoutedEventArgs e) => WarnIfFailed(Core.Send(Cmd.DisplayName, ("value", NameBox.Text)));

    void Name_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Name_Click(sender, e);
    }

    /// Strompreis mit so vielen Nachkommastellen, wie der Kern vorgibt (mindestens/höchstens).
    static string PriceText(Snapshot s)
    {
        var p = s.Options.Price;
        var format = p.FractionDigitsMax > 0
            ? "0." + new string('0', p.FractionDigitsMin) + new string('#', Math.Max(0, p.FractionDigitsMax - p.FractionDigitsMin))
            : "0.##";
        return s.Price.ToString(format, De);
    }

    /// Auswahl des Abfrage-Abstands nach der Liste des Kerns, einmal angelegt (Tag 0 = „Eigener Wert“). Dazu die festen
    /// Texte der Zeilen „Eigener Wert“ und der Warnung.
    void EnsureRefreshItems(RefreshOptions r)
    {
        if (RefreshBox.Items.Count > 0 || r.Choices.Count == 0) return;
        foreach (var c in r.Choices) RefreshBox.Items.Add(new ComboBoxItem { Content = c.Label, Tag = (int)c.Seconds });
        RefreshBox.Items.Add(new ComboBoxItem { Content = r.CustomLabel, Tag = 0 });
        CustomRefreshTitle.Text = r.CustomLabel.Replace(" …", "", StringComparison.Ordinal);
        CustomRefreshHelp.Text = r.CustomHelp;
        RefreshWarnText.Text = r.Warning;
    }

    void Price_Click(object sender, RoutedEventArgs e)
    {
        // Grenzen und Meldung kommen aus dem Kern (`price`); hier nur die Zahl lesen.
        var text = PriceBox.Text.Trim().Replace(',', '.');
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var p))
        {
            Warn("Strompreis nicht übernommen", "Der Wert ist keine Zahl. Bitte einen Preis wie 0,30 eingeben. (price)");
            return;
        }
        var err = Core.Send(Cmd.Price, ("value", p));
        if (err != null) Warn("Strompreis nicht übernommen", err);
    }

    void Price_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Price_Click(sender, e);
    }

    void Refresh_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (updating || RefreshBox.SelectedItem is not ComboBoxItem i) return;
        customRefresh = (int)i.Tag == 0;
        if (customRefresh)
        {
            CustomRefreshPanel.Visibility = Visibility.Visible;
            CustomRefreshBox.Focus();
            CustomRefreshBox.SelectAll();
            return;
        }
        Core.Send(Cmd.RefreshSeconds, ("value", (int)i.Tag));
    }

    void CustomRefresh_Click(object sender, RoutedEventArgs e)
    {
        var limits = Core.Snap.Options.Refresh;
        if (!int.TryParse(CustomRefreshBox.Text.Trim(), out var secs) || secs < limits.Min || secs > limits.Max)
        {
            Warn("Abfrage-Abstand nicht übernommen",
                 $"Der Wert liegt außerhalb des erlaubten Bereichs. Bitte eine ganze Zahl von {limits.Min} bis {limits.Max} Sekunden eingeben.");
            return;
        }
        Core.Send(Cmd.RefreshSeconds, ("value", secs));
    }

    void CustomRefresh_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) CustomRefresh_Click(sender, e);
    }

    void HistoryCsv_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.HistoryCsv, ("on", HistoryCsvBox.IsChecked == true));

    void HistoryShow_Click(object sender, RoutedEventArgs e) => ShowInExplorer(Path.Combine(Native.SupportDir(), "verlauf.sqlite"));

    /// Der Verlauf ist nicht geheim: nur lokaler Startordner, keine Warnung bei OneDrive.
    async void HistoryExport_Click(object sender, RoutedEventArgs e)
    {
        await Dialogs.AfterPump();
        var dlg = new SaveFileDialog
        {
            Title = Core.Snap.Options.Texts.ExportHistoryPanelTitle,
            FileName = Core.Snap.Options.Texts.ExportHistoryFileName,
            Filter = "CSV (*.csv)|*.csv",
            InitialDirectory = Dialogs.SaveFolder(),
        };
        if (dlg.ShowDialog(this) != true) return;
        // Im Hintergrund und lesbar (deutsche Spalten, Ortszeit, Dezimalkomma) – wie am Mac.
        var err = Core.Send(Cmd.ExportHistoryStart, ("path", dlg.FileName), ("readable", true));
        if (err != null) { Result(HistoryResult, err, false); return; }
        exportSeq.Pending = Path.GetFileName(dlg.FileName);
        Result(HistoryResult, "Exportiere …", true);
    }

    void RenderExport(Snapshot s)
    {
        if (!exportSeq.Advance(s.ExportSeq)) return;
        if (exportSeq.Pending is not { } name) return;
        exportSeq.Pending = null;
        Result(HistoryResult, s.ExportError ?? s.ExportText ?? $"Verlauf gespeichert als „{name}“.", s.ExportError == null);
    }

    // Der Run-Wert startet diese exe mit --tray. Der Haken ist nur an, wenn er auf genau diese exe zeigt; sonst
    // steht darunter ein Hinweis, und Anhaken trägt diese exe ein.

    static string? SelfPath => Environment.ProcessPath;

    static string AutostartCommand => $"\"{SelfPath}\" --tray";

    static string? ReadRunValue()
    {
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            return run?.GetValue(RunValue) as string;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return null; }
    }

    /// Programmpfad aus einem Run-Wert: in Anführungszeichen oder bis „.exe“.
    static string? RunTarget(string? value)
    {
        var v = value?.Trim();
        if (string.IsNullOrEmpty(v)) return null;
        if (v[0] == '"')
        {
            var end = v.IndexOf('"', 1);
            return end > 1 ? v[1..end] : null;
        }
        var exe = v.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        return exe > 0 ? v[..(exe + 4)] : v.Split(' ')[0];
    }

    static bool SamePath(string a, string b)
    {
        try { return string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return false; }
    }

    void RenderAutostart()
    {
        var value = ReadRunValue();
        var target = RunTarget(value);
        var mine = target != null && SelfPath != null && SamePath(target, SelfPath);
        // Älterer Eintrag dieser exe ohne --tray: still nachtragen, sonst geht beim Anmelden das Hauptfenster auf.
        if (mine && value != AutostartCommand) WriteAutostart(true);
        AutostartBox.IsChecked = mine;
        if (value != null && !mine)
        {
            var where = target ?? value;
            var gone = target != null && !File.Exists(target);
            AutostartHint.Text = gone
                ? $"Der Autostart zeigt auf eine Datei, die es nicht mehr gibt ({where}). Darum startet Klimacontrol beim Anmelden nicht. Haken setzen, um diese Klimacontrol-Datei einzutragen."
                : $"Der Autostart zeigt auf eine andere Klimacontrol-Datei ({where}). Haken setzen, um stattdessen diese hier einzutragen.";
            AutostartHint.Visibility = Visibility.Visible;
        }
        else
        {
            AutostartHint.Visibility = Visibility.Collapsed;
        }
    }

    /// Schreibt bzw. entfernt den Run-Wert; Fehlertext oder null.
    static string? WriteAutostart(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) key.SetValue(RunValue, AutostartCommand);
            else key.DeleteValue(RunValue, false);
            App.Trace($"Mit Windows starten: {(on ? "an" : "aus")}");
            return null;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            App.Trace($"Autostart nicht geändert: {e.Message}");
            return on
                ? "Klimacontrol ließ sich nicht in den Autostart eintragen. Windows hat den Zugriff verweigert. In den Windows-Einstellungen unter Apps → Autostart prüfen."
                : "Klimacontrol ließ sich nicht aus dem Autostart austragen. Windows hat den Zugriff verweigert. In den Windows-Einstellungen unter Apps → Autostart ausschalten.";
        }
    }

    void RenderUpdates()
    {
        var on = Updates.Running;
        UpdateVersionText.Text = $"Version {App.Version}";
        var texts = Core.Snap.Options.Texts;
        UpdateHelpText.Text = texts.UpdatesHelp;
        UpdateHelpText.Visibility = texts.UpdatesHelp.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (texts.UpdatesCheckButton.Length > 0) UpdateCheckButton.Content = texts.UpdatesCheckButton;
        UpdateCheckButton.IsEnabled = on;
        UpdateSetupHint.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
    }

    void UpdateCheck_Click(object sender, RoutedEventArgs e) => Updates.CheckNow();

    void Autostart_Click(object sender, RoutedEventArgs e)
    {
        if (SelfPath == null) { RenderAutostart(); return; }
        Warn("Autostart nicht geändert", WriteAutostart(AutostartBox.IsChecked == true));
        RenderAutostart();
    }

    // Globales Kürzel, gespeichert als „Ctrl+Alt+K“ (Modifikatoren Ctrl, Alt, Shift, Win in dieser Reihenfolge, Taste
    // als WPF-`Key`-Name); leer = aus, fehlt der Wert = Standard.

    public const string DefaultHotkey = "Ctrl+Alt+K";
    const string HotkeyCustomTag = "*";
    static readonly string[] HotkeyPresets = { DefaultHotkey, "Ctrl+Alt+P", "Ctrl+Shift+K" };
    bool recordingHotkey;

    static string CurrentHotkey => Prefs.Get("FlyoutHotkey", DefaultHotkey) ?? DefaultHotkey;

    /// „Ctrl+Alt+K“ → Modifikatoren und Taste; false bei leerem oder ungültigem Text.
    public static bool TryParseHotkey(string? text, out ModifierKeys mods, out Key key)
    {
        mods = ModifierKeys.None;
        key = Key.None;
        if (string.IsNullOrWhiteSpace(text)) return false;
        var parts = text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return false;
        foreach (var p in parts[..^1])
        {
            switch (p.ToLowerInvariant())
            {
                case "ctrl": case "control": case "strg": mods |= ModifierKeys.Control; break;
                case "alt": mods |= ModifierKeys.Alt; break;
                case "shift": case "umschalt": mods |= ModifierKeys.Shift; break;
                case "win": case "windows": mods |= ModifierKeys.Windows; break;
                default: return false;
            }
        }
        var last = parts[^1];
        if (last.Length == 1 && char.IsDigit(last[0])) last = "D" + last;
        return Enum.TryParse(last, ignoreCase: true, out key) && IsUsableHotkey(mods, key);
    }

    /// Mit Strg, Alt oder Win (nur Umschalt würde Tippen blockieren); keine reine Modifikatortaste; F12 reserviert Windows.
    static bool IsUsableHotkey(ModifierKeys mods, Key key) =>
        (mods & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != 0
        && key is not (Key.None or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift
            or Key.RightShift or Key.LWin or Key.RWin or Key.System or Key.ImeProcessed or Key.DeadCharProcessed or Key.F12
            or Key.Escape or Key.Tab or Key.CapsLock or Key.NumLock or Key.Scroll);

    static string FormatHotkey(ModifierKeys mods, Key key)
    {
        var parts = new List<string>();
        if (mods.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (mods.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (mods.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (mods.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(key.ToString());
        return string.Join("+", parts);
    }

    /// Anzeige in deutscher Schreibweise: „Strg+Alt+K“, „Strg+Umschalt+1“.
    static string DisplayHotkey(string stored) =>
        TryParseHotkey(stored, out var mods, out var key) ? DisplayMods(mods) + DisplayKey(key) : stored;

    /// „Strg+Alt+“ usw. (mit abschließendem Plus), leer ohne Modifikatoren.
    static string DisplayMods(ModifierKeys mods)
    {
        var text = "";
        if (mods.HasFlag(ModifierKeys.Control)) text += "Strg+";
        if (mods.HasFlag(ModifierKeys.Alt)) text += "Alt+";
        if (mods.HasFlag(ModifierKeys.Shift)) text += "Umschalt+";
        if (mods.HasFlag(ModifierKeys.Windows)) text += "Win+";
        return text;
    }

    static string DisplayKey(Key key) => key switch
    {
        >= Key.D0 and <= Key.D9 => ((char)('0' + (key - Key.D0))).ToString(),
        >= Key.NumPad0 and <= Key.NumPad9 => $"Ziffernblock {key - Key.NumPad0}",
        Key.Space => "Leertaste",
        Key.Enter => "Eingabe",
        Key.Back => "Rücktaste",
        Key.Delete => "Entf",
        Key.Insert => "Einfg",
        Key.Home => "Pos1",
        Key.End => "Ende",
        Key.PageUp => "Bild↑",
        Key.PageDown => "Bild↓",
        Key.Up => "↑",
        Key.Down => "↓",
        Key.Left => "←",
        Key.Right => "→",
        Key.OemComma => ",",
        Key.OemPeriod => ".",
        Key.OemMinus => "-",
        Key.OemPlus => "+",
        _ => key.ToString(),
    };

    /// Auswahlliste: Vorschläge, ggf. das gespeicherte eigene Kürzel, „Eigene Kombination …“, „Aus“.
    void RenderHotkey()
    {
        var current = CurrentHotkey;
        var known = current.Length == 0 || TryParseHotkey(current, out _, out _);
        var items = HotkeyPresets
            .Select(h => new ComboBoxItem { Content = h == DefaultHotkey ? $"{DisplayHotkey(h)} (Standard)" : DisplayHotkey(h), Tag = h })
            .ToList();
        if (current.Length > 0 && known && !HotkeyPresets.Contains(current, StringComparer.OrdinalIgnoreCase))
            items.Add(new ComboBoxItem { Content = DisplayHotkey(current), Tag = current });
        items.Add(new ComboBoxItem { Content = "Eigene Kombination …", Tag = HotkeyCustomTag });
        items.Add(new ComboBoxItem { Content = "Aus", Tag = "" });
        var was = updating;
        updating = true;
        try
        {
            HotkeyBox.ItemsSource = items;
            HotkeyBox.SelectedItem = items.FirstOrDefault(i => string.Equals((string)i.Tag, current, StringComparison.OrdinalIgnoreCase))
                                     ?? items.First(i => (string)i.Tag == HotkeyCustomTag);
        }
        finally { updating = was; }
    }

    void SaveHotkey(string value)
    {
        Prefs.Set("FlyoutHotkey", value);
        ((App)Application.Current).ApplyHotkey();
        Result(HotkeyResult, value.Length == 0
            ? "✓ Kein Tastenkürzel. Das Fenster öffnet sich mit einem Klick auf das Symbol im Infobereich."
            : $"✓ {DisplayHotkey(value)} öffnet das Fenster am Infobereich – in jedem Programm.", true);
        RenderHotkey();
    }

    void Hotkey_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (updating || HotkeyBox.SelectedItem is not ComboBoxItem i) return;
        var tag = (string)i.Tag;
        if (tag == HotkeyCustomTag)
        {
            StartRecording();
            return;
        }
        StopRecording();
        if (!string.Equals(tag, CurrentHotkey, StringComparison.OrdinalIgnoreCase)) SaveHotkey(tag);
    }

    void StartRecording()
    {
        recordingHotkey = true;
        HotkeyRecordPanel.Visibility = Visibility.Visible;
        HotkeyRecordBox.Text = "Tasten drücken …";
        HotkeyResult.Visibility = Visibility.Collapsed;
        HotkeyRecordBox.Focus();
    }

    void StopRecording()
    {
        recordingHotkey = false;
        HotkeyRecordPanel.Visibility = Visibility.Collapsed;
    }

    void HotkeyRecordCancel_Click(object sender, RoutedEventArgs e)
    {
        StopRecording();
        RenderHotkey();
    }

    /// Nimmt eine Tastenkombination auf: Modifikatoren allein zeigen den Zwischenstand, Esc bricht ab.
    void HotkeyRecord_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!recordingHotkey) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = Keyboard.Modifiers;
        if (key == Key.Escape && mods == ModifierKeys.None)
        {
            StopRecording();
            RenderHotkey();
            return;
        }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
            or Key.LWin or Key.RWin)
        {
            HotkeyRecordBox.Text = mods == ModifierKeys.None ? "Tasten drücken …" : DisplayMods(mods) + "…";
            return;
        }
        if (!IsUsableHotkey(mods, key))
        {
            HotkeyRecordBox.Text = "Tasten drücken …";
            Result(HotkeyResult, key == Key.F12
                ? "F12 ist unter Windows reserviert. Bitte eine andere Taste wählen."
                : "Diese Kombination geht nicht. Bitte mit Strg, Alt oder Win zusammen drücken, z. B. Strg+Alt+K.", false);
            return;
        }
        var value = FormatHotkey(mods, key);
        HotkeyRecordBox.Text = DisplayHotkey(value);
        StopRecording();
        SaveHotkey(value);
    }
}
