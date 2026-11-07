using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace KlimacontrolTray;

/// Reiter „Verbindung“: Zustand, Verbindungsweg, Midea-Konto.
public partial class SettingsWindow
{
    // Gepunkteter Kreis für „Verbinde …“.
    static readonly Geometry Circle = Geometry.Parse("M8,1.5 A6.5,6.5 0 1 1 7.99,1.5 Z");
    // Ergebnis der Anmeldung (LoginSeq): jedes neue wird gezeigt, ohne eigenen Auftrag.
    readonly SeqWatch loginSeq;

    /// Grün nur, wenn die Werte aktuell sind (`ConnectionStatus.Connected`); Text und Zustand liefert der Kern, darunter
    /// seine Meldung.
    void RenderStatus(Snapshot s)
    {
        var state = s.ConnectionState;
        var text = s.ConnectionStatus.Text;
        Geometry icon;
        if (s.ConnectionStatus.Connected) icon = Geometry.Parse(Icons.Check);
        else if (state == "deviceOff") icon = Geometry.Parse(Icons.DeviceOff);
        else if (state == "noConnection") icon = Geometry.Parse(Icons.Warning);
        else icon = Circle;
        var brush = (Brush)FindResource(s.ConnectionStatus.Connected ? "Ok" : "Sub");
        ConnStatus.Text = text;
        ConnStatus.Foreground = brush;
        ConnIcon.Data = icon;
        ConnIcon.Stroke = brush;
        ConnIcon.StrokeDashArray = icon == Circle ? new DoubleCollection { 1.2, 1.4 } : new DoubleCollection();
        var detail = s.MessageDetail is { What.Length: > 0 } m && state is "noConnection" or "deviceOff" ? m : null;
        if (detail != null) SetMessage(ConnDetail, detail.What, detail.Todo, detail.Code);
        ConnDetail.Visibility = Show(detail != null);
    }

    void Mode_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (updating || ModeBox.SelectedItem is not ComboBoxItem i) return;
        var mode = (string)i.Tag;
        if (mode == "cloud" && Core.Snap.CloudAccount == null)
        {
            var n = Core.Snap.Options.Prompts.CloudNeedsAccount;
            Warn(n.Title, n.Message);
            Render();
            return;
        }
        Core.Send(Cmd.ConnectionMode, ("value", mode));
    }

    void UpdateLoginButton()
    {
        var running = Core.Snap.CloudLoginRunning;
        CloudLoginButton.IsEnabled = !running && CloudUser.Text.Trim().Length > 0 && CloudPass.Password.Length > 0;
        CloudLoginButton.Content = running ? "Melde an …" : "Anmelden und speichern";
    }

    void CloudInput_Changed(object sender, RoutedEventArgs e) => UpdateLoginButton();

    void CloudPass_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && CloudLoginButton.IsEnabled) CloudLogin_Click(sender, e);
    }

    void CloudLogin_Click(object sender, RoutedEventArgs e)
    {
        if (Core.Snap.CloudLoginRunning || CloudUser.Text.Trim().Length == 0 || CloudPass.Password.Length == 0) return;
        CloudResult.Visibility = Visibility.Collapsed;
        var err = Core.Send(Cmd.CloudLogin, ("account", CloudUser.Text.Trim()), ("password", CloudPass.Password));
        if (err != null)
        {
            CloudPass.Clear();
            Result(CloudResult, err, false);
        }
    }

    async void CloudLogout_Click(object sender, RoutedEventArgs e)
    {
        // Rückfrage und Erfolgstext vom Kern.
        if (!await Confirm(Core.Snap.Options.Prompts.AccountRemove)) return;
        var err = Core.Send(Cmd.CloudLogout);
        Result(CloudResult, err ?? Core.Snap.Options.Texts.AccountRemoved, err == null);
    }
}
