using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Szenen: einklappbarer Abschnitt mit Raster, „Szene sichern“ und Rechtsklick „Szene löschen“. Zeigt nur den Zustand
/// des Kerns (Snapshot.Scenes) und schickt Befehle.
public partial class ScenesSection : UserControl
{
    static Core Core => Core.Shared;
    /// Auf-/zugeklappt gilt für alle Fenster und bleibt über einen Neustart erhalten (Prefs "ScenesOpen"); Standard: zu.
    static bool scenesOpen = Prefs.GetBool("ScenesOpen", false);

    /// Liste, aktive Szene und Modusfarbe beim letzten Aufbau der Knöpfe.
    string sceneKey = "";
    /// Zustand kam, während der Abschnitt ausgeblendet war – beim Einblenden nachzeichnen.
    bool stale = true;
    bool compact;

    public ScenesSection()
    {
        InitializeComponent();
        var plus = Icons.Make(Icons.Plus, 10, null, 1.8);
        plus.Margin = new Thickness(0, 0, 6, 0);
        plus.VerticalAlignment = VerticalAlignment.Center;
        SceneAdd.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children = { plus, new TextBlock { Text = "Szene sichern", VerticalAlignment = VerticalAlignment.Center } },
        };
        ScenesExpander.IsExpanded = scenesOpen;

        // Erst abmelden: Loaded kann beim Umhängen zwischen Spalten ohne Unloaded dazwischen kommen.
        Loaded += (_, _) =>
        {
            Core.Changed -= Refresh;
            Core.Changed += Refresh;
            Theme.Changed -= ThemeChanged;
            Theme.Changed += ThemeChanged;
            // Darstellung geändert: Knöpfe wie bei einem Themenwechsel neu bauen.
            Appearance.Changed -= ThemeChanged;
            Appearance.Changed += ThemeChanged;
            ScenesExpander.IsExpanded = scenesOpen;
            Refresh();
        };
        Unloaded += (_, _) => Detach();
        // Ausgeblendet nicht mitzeichnen – erst beim Einblenden nachholen. Dabei auch den Klappzustand übernehmen,
        // den ein anderes Fenster inzwischen geändert haben kann.
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible) return;
            ScenesExpander.IsExpanded = scenesOpen;
            if (stale) Refresh();
        };
    }

    /// Kompakte Dichte: nur der Abstand nach oben wird kleiner. Ihn setzt der Baustein selbst (Margin), damit er nicht
    /// doppelt zählt.
    public bool Compact
    {
        get => compact;
        set
        {
            if (compact == value) return;
            compact = value;
            ApplyDensity();
        }
    }

    /// Abstand nach oben nach Dichte und „Größe“ (`Theme.SizeFactor`).
    internal void ApplyDensity() => Margin = new Thickness(0, Math.Round((compact ? 8 : 12) * Theme.SizeFactor), 0, 0);

    /// Der Szenenname hat den Tastaturfokus (das Fenster am Infobereich soll dann z. B. nicht schließen).
    public bool IsTyping => SceneNameBox.IsKeyboardFocusWithin;

    /// Vom Kern abmelden – beim Entladen und beim Schließen des Fensters.
    public void Detach()
    {
        Core.Changed -= Refresh;
        Theme.Changed -= ThemeChanged;
        Appearance.Changed -= ThemeChanged;
    }

    /// Hell/Dunkel oder Hoher Kontrast gewechselt: Knöpfe mit den neuen Farben neu bauen.
    void ThemeChanged()
    {
        sceneKey = "";
        Refresh();
    }

    void Refresh()
    {
        if (!IsVisible) { stale = true; return; }
        stale = false;
        Render(Core.Snap);
    }

    void Render(Snapshot s)
    {
        var active = s.Scenes.FirstOrDefault(x => x.Active);
        // Eingeklappt zeigen, welche Szene gerade eingestellt ist (Name nicht in Großbuchstaben).
        HeaderText.Text = active != null ? $"SZENEN · {active.Name} aktiv" : "SZENEN";
        HeaderText.ToolTip = active != null ? $"{active.Name} ist eingestellt" : null;
        var empty = s.Scenes.Count == 0;
        ScenesHint.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        SceneGrid.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;

        // Knöpfe nur neu bauen, wenn sich Liste, aktive Szene oder die Modusfarbe geändert haben – neue Messwerte
        // allein bauen nichts um.
        var key = string.Join("\u001f", s.Scenes.Select(x => $"{x.Id}\u001e{x.Name}\u001e{x.Summary}\u001e{x.Active}\u001e{x.Mode}"));
        if (key == sceneKey) return;
        sceneKey = key;
        SceneGrid.Children.Clear();
        var sub = (Brush)FindResource("Sub");
        foreach (var scene in s.Scenes) SceneGrid.Children.Add(SceneButton(scene, sub));
        // Mit Grundgrößen gebaut, jetzt nach „Größe“ skalieren.
        SizeScale.Apply(SceneGrid, Theme.SizeFactor);
    }

    /// Ein Knopf im Raster: Modus-Symbol, Name, Zusammenfassung aus dem Kern („Kühlen · 18° · Max“), aktiv mit Häkchen.
    /// Farbe und Symbol aus dem Modus der Szene – fünf gleiche Kacheln wären nicht zu unterscheiden.
    /// Aktiv: abgedunkelte Modusfarbe, damit die weiße Schrift lesbar bleibt, bei Hohem Kontrast Systemfarben.
    static Button SceneButton(SceneInfo scene, Brush sub)
    {
        var color = ControlPanel.Tint(scene.Mode);
        var tint = Theme.HighContrast ? (Brush)SystemColors.WindowTextBrush : Paints.Of(color);
        var fill = Theme.ActiveFillBrush(color);
        var onFill = Theme.ActiveText;
        var modeIcon = Codes.Modes.FirstOrDefault(m => m.Value == scene.Mode).Icon;
        var title = new TextBlock { Text = scene.Name, FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        var summary = new TextBlock
        {
            Text = scene.Summary, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 1, 0, 0),
            Foreground = scene.Active ? onFill : sub, Opacity = scene.Active ? 0.85 : 1,
        };
        var content = new DockPanel { LastChildFill = true };
        if (scene.Active)
        {
            var check = Icons.Make(Icons.Check, 12, onFill, 2);
            check.Margin = new Thickness(8, 0, 0, 0);
            check.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(check, Dock.Right);
            content.Children.Add(check);
        }
        if (modeIcon != null)
        {
            var icon = Icons.Make(modeIcon, 15, scene.Active ? onFill : tint);
            icon.Margin = new Thickness(0, 0, 8, 0);
            icon.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(icon, Dock.Left);
            content.Children.Add(icon);
        }
        content.Children.Add(new StackPanel { Children = { title, summary } });
        var b = new Button
        {
            Content = content, Margin = new Thickness(3), Padding = new Thickness(10, 7, 10, 7),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            ToolTip = scene.Active ? $"{scene.Name} ist eingestellt" : $"{scene.Name} anwenden – Rechtsklick zum Löschen",
        };
        // Aktiv = getönte Fläche mit weißer Schrift; für die Sprachausgabe „aktiv“.
        AutomationProperties.SetName(b, scene.Name);
        AutomationProperties.SetHelpText(b, scene.Summary);
        if (scene.Active)
        {
            b.Background = fill;
            // Neon: leuchtende Kante in der hellen Modusfarbe (wie die Kacheln im ControlPanel).
            b.BorderBrush = Appearance.Current.Theme == "neon" && !Theme.HighContrast ? tint : fill;
            b.Foreground = onFill;
            AutomationProperties.SetItemStatus(b, "aktiv");
        }
        var id = scene.Id;
        b.Click += (_, _) => Core.Send(Cmd.ApplyScene, ("id", id));
        var name = scene.Name;
        var del = new MenuItem { Header = "Szene löschen …" };
        del.Click += async (_, _) =>
        {
            // Wie am Mac: erst nachfragen, eine gelöschte Szene lässt sich nicht wiederherstellen.
            var answer = await Dialogs.AskWarn(Window.GetWindow(b),$"Szene „{name}“ löschen?",
                "Die Szene lässt sich danach nicht wiederherstellen.", "Löschen", "Abbrechen");
            if (answer == 0) Core.Send(Cmd.DeleteScene, ("id", id));
        };
        b.ContextMenu = new ContextMenu { Items = { del } };
        return b;
    }

    // Ereignisse

    void Scenes_Changed(object sender, RoutedEventArgs e)
    {
        if (!ReferenceEquals(e.OriginalSource, ScenesExpander)) return;
        if (scenesOpen == ScenesExpander.IsExpanded) return;
        scenesOpen = ScenesExpander.IsExpanded;
        Prefs.SetBool("ScenesOpen", scenesOpen);
    }

    void SceneAdd_Click(object sender, RoutedEventArgs e)
    {
        SceneNameBox.Text = "";
        SceneNameRow.Visibility = Visibility.Visible;
        // Erst nach dem Layout fokussieren – gerade eingeblendet ist das Feld noch nicht bereit.
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () => { SceneNameBox.Focus(); Keyboard.Focus(SceneNameBox); });
    }

    void SceneName_TextChanged(object sender, TextChangedEventArgs e) =>
        SceneSaveButton.IsEnabled = SceneNameBox.Text.Trim().Length > 0;

    void SceneSave_Click(object sender, RoutedEventArgs e)
    {
        var name = SceneNameBox.Text.Trim();
        if (name.Length == 0) return;
        Core.Send(Cmd.SaveScene, ("name", name));
        CloseNameRow();
    }

    void SceneCancel_Click(object sender, RoutedEventArgs e) => CloseNameRow();

    void CloseNameRow()
    {
        SceneNameRow.Visibility = Visibility.Collapsed;
        SceneNameBox.Text = "";
    }

    void SceneName_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { SceneSave_Click(sender, e); e.Handled = true; }
        else if (e.Key == Key.Escape) { CloseNameRow(); e.Handled = true; }
    }
}
