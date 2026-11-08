using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace KlimacontrolTray;

/// Startanzeige, solange eine Anlage eingerichtet ist, aber noch kein Zustand vorliegt (auch nach einem Startfehler):
/// zuletzt bekannte Werte bzw. Skelett und die Verbindungsschritte. Keine eigene Anmeldung beim Kern – ControlPanel
/// ruft `Render` beim Zeichnen und im 5-s-Takt auf.
public partial class ConnectingView : UserControl
{
    bool compact;
    string? lastSteps;
    bool lastSlow;

    public ConnectingView()
    {
        InitializeComponent();
        // Die große Zahl setzt ihre Größe selbst (Dichte × „Größe“), die übrigen Schriften skaliert das ControlPanel.
        SizeScale.Own(LastMain);
    }

    /// Kompakte Dichte wie im übrigen ControlPanel: weniger Rand, kleinere große Zahl.
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

    /// Abstände und große Zahl nach Dichte und „Größe“ (`Theme.SizeFactor`).
    internal void ApplyDensity()
    {
        var f = Theme.SizeFactor;
        double D(double normal, double small) => Math.Round((compact ? small : normal) * f);
        Card.Padding = new Thickness(D(16, 12));
        LastMain.FontSize = D(56, 40);
        SkelBig.Height = D(52, 40);
        LastPanel.Margin = Skeleton.Margin = new Thickness(0, D(12, 8), 0, 0);
        StepsPanel.Margin = new Thickness(0, D(14, 8), 0, 0);
    }

    /// Ziffernstil der großen Zahl (Darstellung); das ControlPanel ruft das bei jeder Änderung.
    internal void ApplyLook()
    {
        var (family, weight) = Theme.DigitFont;
        LastMain.FontFamily = family;
        LastMain.FontWeight = weight;
    }

    /// `keys`: das Fenster kennt die Kürzel (Strg+R) – dann stehen sie im Tooltip.
    public void Render(Snapshot s, bool keys)
    {
        NameText.Text = s.DisplayName;
        var (text, dot) = ControlPanel.Status(s);
        StatusText.Text = text;
        StatusDot.Fill = dot;
        var tip = ControlPanel.StatusTip(s);
        if (!Equals(StatusRow.ToolTip, tip)) StatusRow.ToolTip = tip;

        // Zuletzt bekannte Werte (Zahl, Zeile darunter, Zusatzwerte) fertig aus dem Kern; ohne Werte das Skelett.
        var last = s.StartupValues;
        LastPanel.Visibility = last != null ? Visibility.Visible : Visibility.Collapsed;
        Skeleton.Visibility = last == null ? Visibility.Visible : Visibility.Collapsed;
        if (last != null)
        {
            LastMain.Text = last.Main;
            LastCaption.Text = last.Caption;
            LastValues.Text = string.Join("   ", last.Extras);
            // Sprachausgabe: ein Satz statt drei loser Zahlen.
            AutomationProperties.SetName(LastMain, last.Accessibility);
        }

        // Nach einem Startfehler steht die Meldung (mit eigenem „Erneut versuchen“) darunter – dann keine Schritte.
        var showSteps = s.Message == null;
        StepsPanel.Visibility = showSteps ? Visibility.Visible : Visibility.Collapsed;
        if (!showSteps)
        {
            lastSteps = null;
            lastSlow = false;
            return;
        }
        var line = s.ConnectStepsLine;
        var spoken = SpokenSteps(line);
        StepsText.Text = line;
        AutomationProperties.SetName(StepsText, spoken);
        if (line != lastSteps)
        {
            // Erst ab dem zweiten Schritt ansagen – beim Einblenden selbst nicht.
            if (lastSteps != null) ControlPanel.Announce(StepsText);
            lastSteps = line;
        }
        // Der Kern setzt `ConnectSlow` nach 10 s und beim nächsten Versuch wieder zurück.
        SlowRow.Visibility = s.ConnectSlow ? Visibility.Visible : Visibility.Collapsed;
        var texts = s.Options.Texts;
        if (!Equals(SlowText.Text, texts.ConnectSlow)) SlowText.Text = texts.ConnectSlow;
        if (texts.Retry.Length > 0 && !Equals(RetryButton.Content, texts.Retry)) RetryButton.Content = texts.Retry;
        if (s.ConnectSlow && !lastSlow) ControlPanel.Announce(SlowText);
        lastSlow = s.ConnectSlow;
        var retryTip = L.Tip("main.windows.reconnectHelp", keys ? Hotkeys.Ctrl("R") : "");
        if (!Equals(RetryButton.ToolTip, retryTip)) RetryButton.ToolTip = retryTip;
        AutomationProperties.SetAcceleratorKey(RetryButton, keys ? Hotkeys.Ctrl("R") : "");
    }

    /// Gesprochene Form der Schrittzeile des Kerns („Anlage suchen ✓ · Anmelden … · Werte lesen“ → „Anlage suchen erledigt,
    /// Anmelden läuft, Werte lesen“).
    internal static string SpokenSteps(string line) =>
        line.Replace(" ✓", " " + L.T("main.windows.spokenDone"), StringComparison.Ordinal)
            .Replace(" …", " " + L.T("main.windows.spokenRunning"), StringComparison.Ordinal)
            .Replace(" · ", ", ", StringComparison.Ordinal);

    /// „Erneut versuchen“: sofort neu verbinden; der Kern hebt dabei die Sperren der Wegwahl auf.
    void Retry_Click(object sender, RoutedEventArgs e) => Core.Shared.Send(Cmd.Refresh);
}
