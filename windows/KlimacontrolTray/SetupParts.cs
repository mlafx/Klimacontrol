using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;

namespace KlimacontrolTray;

/// Symbole nur der Einrichtung (16×16, Strich).
static class SetupIcons
{
    public const string Person = "M8,1.5 A6.5,6.5 0 1 1 7.99,1.5 Z M8,4.3 A2.3,2.3 0 1 1 7.99,4.3 Z M3.7,12.8 C4.7,10.8 6.2,9.9 8,9.9 C9.8,9.9 11.3,10.8 12.3,12.8";
    public const string Key = "M5,8 A3,3 0 1 1 4.99,8 Z M7.2,8.8 L14,2 M11.4,4.6 L13.4,6.6 M9.6,6.4 L11.1,7.9";
    public const string Document = "M3,1.5 H9.5 L13,5 V14.5 H3 Z M9.5,1.5 V5 H13 M8,12.5 V7.5 M5.8,9.7 L8,7.5 L10.2,9.7";
    public const string Clipboard = "M4,2.5 H12 V14.5 H4 Z M6,1.5 H10 V3.8 H6 Z M6.2,7.5 H9.8 M6.2,10.5 H9.8";
    public const string ChevronRight = "M6,3 L11,8 L6,13";
    /// Kreis für „unvollständig“ (gestrichelt gezeichnet).
    public const string Circle = "M8,2 A6,6 0 1 1 7.99,2 Z";
}

/// Gemeinsame Bausteine der Einrichtung (SetupAccount, SetupManual).
static class SetupUi
{
    /// Knopfinhalt „Symbol + Text“; der Text bleibt änderbar (Suche …, 37 von 254).
    public static StackPanel Labeled(string icon, out TextBlock label, string? text = null)
    {
        label = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Text = text ?? "" };
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        var i = Icons.Make(icon, 14);
        i.Margin = new Thickness(0, 0, 6, 0);
        p.Children.Add(i);
        p.Children.Add(label);
        return p;
    }

    /// Suchknöpfe „Im WLAN suchen“ und „Netz durchsuchen“ einrichten.
    public static void SetupSearch(Button scan, out TextBlock scanLabel, Button subnet, out TextBlock subnetLabel)
    {
        scan.Content = Labeled(Icons.Radio, out scanLabel);
        subnet.Content = Labeled(Icons.Network, out subnetLabel);
        // Fortschritt „37 von 254“ im Knopf: gleich breite Ziffern, damit der Knopf beim Zählen nicht zappelt.
        System.Windows.Documents.Typography.SetNumeralAlignment(subnetLabel, FontNumeralAlignment.Tabular);
    }

    public static void RenderSearch(SetupInfo s, Button scan, TextBlock scanLabel, Button subnet, TextBlock subnetLabel)
    {
        scan.IsEnabled = !s.Scanning;
        scanLabel.Text = L.T(s.Scanning ? "setup.view.searching" : "setup.view.search.wifi");
        subnet.IsEnabled = !s.SubnetScanning;
        subnetLabel.Text = !s.SubnetScanning ? L.T("setup.view.search.subnet")
            : s.SubnetSent is int sent && s.SubnetTotal is int total
                ? L.F("setup.view.search.subnetProgress", ("done", Fmt.Num(sent, 0)), ("total", Fmt.Num(total, 0)))
                : L.T("setup.view.search.subnetBusy");
    }

    /// Code am Ende einer Kernmeldung („Was ist passiert. Was tun. (code)“): ein Wort ohne Leerzeichen in Klammern.
    static readonly Regex CodeTail = new(@"\s*\(([A-Za-z0-9][A-Za-z0-9._:\-]*)\)\s*$", RegexOptions.CultureInvariant);

    /// Meldung im Muster des Kerns setzen: Text in der Farbe des Blocks, der Code klein und grau am Ende.
    public static void SetMessage(TextBlock text, string message)
    {
        var m = CodeTail.Match(message);
        if (!m.Success)
        {
            text.Text = message;
            return;
        }
        text.Inlines.Clear();
        text.Inlines.Add(new Run(message[..m.Index]));
        var code = new Run(" (" + m.Groups[1].Value + ")") { FontSize = Math.Max(9, text.FontSize - 1.5) };
        code.SetResourceReference(TextElement.ForegroundProperty, "Sub");
        text.Inlines.Add(code);
    }

    /// Meldung unter einem Schritt zeigen: orange mit Warndreieck bzw. grün mit Häkchen.
    public static void ShowMessage(Border box, TextBlock text, ContentControl icon, string message, bool ok)
    {
        var key = ok ? "Ok" : "Warn";
        SetMessage(text, message);
        text.SetResourceReference(TextBlock.ForegroundProperty, key);
        // Symbol nur bei Wechsel Fehler/Erfolg neu anlegen.
        if (icon.Tag as string != key)
        {
            var path = Icons.Make(ok ? Icons.Check : Icons.Warning, 14, null, 1.5);
            path.SetResourceReference(Shape.StrokeProperty, key);
            icon.Content = path;
            icon.Tag = key;
        }
        box.Visibility = Visibility.Visible;
    }

    public static void SetName(DependencyObject o, string name) =>
        System.Windows.Automation.AutomationProperties.SetName(o, name);

    /// Hilfe unter einer Meldung zeigen, wenn der Kern sie vorsieht (nichts gefunden bzw. Anlage antwortet nicht).
    public static void RenderHelp(NetworkHelp help, SetupInfo s, bool shown)
    {
        if (shown && s.Error != null && s.ShowsNetworkHelp) help.Show(s.Issue);
        else help.Visibility = Visibility.Collapsed;
    }
}

/// Häufige Windows-Gründe, warum die Suche keine Anlage findet, und ein Knopf zu den WLAN-Einstellungen.
public sealed class NetworkHelp : Border
{
    readonly TextBlock title;

    public NetworkHelp()
    {
        Margin = new Thickness(0, 6, 0, 0);
        Padding = new Thickness(10, 8, 10, 8);
        CornerRadius = new CornerRadius(6);
        BorderThickness = new Thickness(1);
        Visibility = Visibility.Collapsed;
        SetResourceReference(BorderBrushProperty, "Line");

        var panel = new StackPanel();
        title = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(title);
        foreach (var key in new[]
        {
            "setup.view.windows.helpPowerWifi",
            "setup.view.windows.helpPrivate",
            "setup.view.windows.helpFirewall",
            "setup.view.windows.helpGuest",
        })
            panel.Children.Add(Bullet(L.T(key)));

        var open = new Button
        {
            Content = L.T("setup.view.windows.openNetwork"),
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 8, 0, 0),
            Padding = new Thickness(9, 4, 9, 5),
            ToolTip = L.T("setup.view.windows.openNetworkHelp"),
        };
        open.Click += (_, _) => OpenSettings();
        panel.Children.Add(open);
        Child = panel;
    }

    static UIElement Bullet(string text)
    {
        var dot = new TextBlock { Text = "•", FontSize = 12, Margin = new Thickness(0, 0, 6, 0) };
        dot.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        var body = new TextBlock { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        body.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        var row = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
        DockPanel.SetDock(dot, Dock.Left);
        row.Children.Add(dot);
        row.Children.Add(body);
        return row;
    }

    /// Sichtbar machen; die Überschrift passt zur Art der Meldung (`Setup.Issue`).
    public void Show(string? issue)
    {
        title.Text = L.T(issue == "unreachable" ? "setup.view.windows.helpTitleUnreachable" : "setup.view.windows.helpTitleNotFound");
        Visibility = Visibility.Visible;
    }

    static void OpenSettings()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:network-wifi") { UseShellExecute = true });
        }
        catch (Exception ex) { App.Trace("Netzwerkeinstellungen nicht geöffnet: " + ex.GetType().Name); }
    }
}

/// Fundliste der Einrichtung: Karten nur bei geänderten Funden neu anlegen, Auswahl nur umfärben.
sealed class FoundCards
{
    readonly Panel panel;
    readonly bool lanOnly;
    readonly Action<string> pick;
    readonly List<(string Id, Button Card, Ellipse Ring, Path Check)> cards = new();
    string listKey = "\u0000";

    /// `lanOnly`: nur WLAN-Funde (Weg „Zugangsdaten“); `pick` bekommt die Anlagen-ID.
    public FoundCards(Panel panel, bool lanOnly, Action<string> pick)
    {
        this.panel = panel;
        this.lanOnly = lanOnly;
        this.pick = pick;
    }

    public void Render(SetupInfo s)
    {
        var shown = s.Discovered.Where(d => !lanOnly || !d.CloudOnly).ToList();
        var key = string.Join("\u001e", shown.Select(d => $"{d.Id}\u001f{d.Name}\u001f{d.Detail}"));
        if (key != listKey)
        {
            listKey = key;
            panel.Children.Clear();
            cards.Clear();
            foreach (var d in shown) cards.Add(Make(d));
        }
        foreach (var (id, card, ring, check) in cards)
        {
            var on = id == s.Selected;
            if (on)
            {
                ring.SetResourceReference(Shape.FillProperty, "Accent");
                ring.SetResourceReference(Shape.StrokeProperty, "Accent");
                card.SetResourceReference(Control.BorderBrushProperty, "Accent");
            }
            else
            {
                ring.Fill = Brushes.Transparent;
                ring.SetResourceReference(Shape.StrokeProperty, "Sub");
                card.SetResourceReference(Control.BorderBrushProperty, "Line");
            }
            check.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    /// Auswahlkarte: Kreis bzw. Häkchen, Name fett, darunter IP/SN oder „über Midea-Konto · online“.
    (string, Button, Ellipse, Path) Make(FoundDevice d)
    {
        var ring = new Ellipse { Width = 16, Height = 16, StrokeThickness = 1.4 };
        var check = Icons.Make(Icons.Check, 10, Brushes.White, 1.8);
        var mark = new Grid { Width = 18, Height = 18, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        mark.Children.Add(ring);
        mark.Children.Add(check);

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = d.Name, FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        var detail = new TextBlock { Text = d.Detail, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 1, 0, 0) };
        detail.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        text.Children.Add(detail);

        var row = new DockPanel();
        DockPanel.SetDock(mark, Dock.Left);
        row.Children.Add(mark);
        row.Children.Add(text);

        var card = new Button
        {
            Content = row,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(0, 6, 0, 0),
            BorderThickness = new Thickness(1),
            ToolTip = d.Name + " · " + d.Detail,
        };
        card.SetResourceReference(Control.BackgroundProperty, "Tile");
        SetupUi.SetName(card, d.Name);
        var id = d.Id;
        card.Click += (_, _) => pick(id);
        panel.Children.Add(card);
        return (id, card, ring, check);
    }
}
