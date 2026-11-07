using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace KlimacontrolTray;

/// Diagnose. Solange sie sichtbar ist, liest der Kern die Diagnose bei jeder Abfrage.
public partial class DiagnosticsPanel : UserControl
{
    static Core Core => Core.Shared;
    public event Action? CloseRequested;

    public DiagnosticsPanel()
    {
        InitializeComponent();
        // Farben als Ressourcenverweis: folgen einem Wechsel hell/dunkel zur Laufzeit von selbst.
        var pulse = Icons.Make(Icons.Pulse, 16);
        pulse.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, "Fg");
        TitleIcon.Content = pulse;
        CloseButton.Content = Icons.Make(Icons.Close, 11, null, 1.6);
        // Timer nur solange geladen und sichtbar, sonst hielte er ein geschlossenes Fenster im Speicher fest.
        tick.Tick += (_, _) => RenderLive();
        IsVisibleChanged += (_, _) =>
        {
            Core.Send(Cmd.DiagnosticsVisible, ("on", IsVisible));
            if (IsVisible) { tick.Start(); Render(); } else tick.Stop();
        };
        // Erst abmelden: Loaded kann beim Umhängen zwischen Spalten ohne Unloaded dazwischen kommen.
        Loaded += (_, _) => { Core.Changed -= Render; Core.Changed += Render; };
        Unloaded += (_, _) => { Core.Changed -= Render; tick.Stop(); };
    }

    readonly System.Windows.Threading.DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(1) };

    /// Beim Schließen des Fensters: abmelden, Timer anhalten und dem Kern sagen, dass die Diagnose nicht mehr
    /// gebraucht wird (sonst liest er sie bei jeder Abfrage weiter).
    public void Detach()
    {
        Core.Changed -= Render;
        tick.Stop();
        Core.Send(Cmd.DiagnosticsVisible, ("on", false));
    }

    void Close_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();
    void Folder_Click(object sender, RoutedEventArgs e) => App.ShowInExplorer(System.IO.Path.Combine(Native.SupportDir(), "verlauf.sqlite"));

    void RenderLive()
    {
        // Zeile mit Countdown („… nächste Abfrage in 12 s“) kommt zeitabhängig aus dem Kern (kc_live_json).
        LiveText.Text = Core.Snap.NextRefreshLine;
    }

    // Zeilen werden einmal angelegt; danach ändern sich nur Texte (gleiche Texte lösen kein Neuzeichnen aus).
    TextBlock? loading;
    readonly List<FrameworkElement> content = new();
    readonly List<(Grid Row, TextBlock Label, TextBlock Value)> rows = new();

    void Render()
    {
        if (!IsVisible) return;
        RenderLive();
        var s = Core.Snap;
        var d = s.Diag;
        var st = s.State;
        if (d == null || st == null)
        {
            if (loading == null)
            {
                loading = new TextBlock { Text = "Diagnosedaten werden geladen …", FontSize = 12, Margin = new Thickness(0, 12, 0, 0) };
                loading.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
                Sections.Children.Insert(0, loading);
            }
            loading.Visibility = Visibility.Visible;
            foreach (var e in content) e.Visibility = Visibility.Collapsed;
            Footer.Visibility = Visibility.Collapsed;
            HintsText.Visibility = Visibility.Collapsed;
            return;
        }
        if (loading != null) loading.Visibility = Visibility.Collapsed;
        foreach (var e in content) e.Visibility = Visibility.Visible;
        Footer.Visibility = Visibility.Visible;
        // Hinweise zu Filter und Fehlercode aus dem Kern (leer = nichts zu tun).
        HintsText.Text = string.Join("\n", s.MaintenanceHints);
        HintsText.Visibility = s.MaintenanceHints.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var heating = st.Mode == 4;
        // Technische Herkunft (Eigenschaftscodes) nur im Tooltip, nicht im Text.
        (string Label, string Value, string? Help)[][] sections =
        {
            new (string, string, string?)[]
            {
                ("Leistungsaufnahme", N(d.CompressorPowerW, "W"), null),
                ("Frequenz", $"{N(d.CompressorHz, "Hz")}  (Soll {N(d.CompressorTargetHz, "Hz")})", null),
                ("Strom · Spannung", $"{N(d.CurrentA, "A")} · {N(d.VoltageV, "V")}", "Die Anlage meldet den Strom nur in ganzen Ampere."),
                ("Lüfter außen", N(d.OutdoorFanRpm, "U/min"), null),
                ("Abtauen", Flag(d.Defrost, "läuft", "nein"), null),
            },
            new (string, string, string?)[]
            {
                ("T1 · Innenluft", T(d.T1IndoorAir), null),
                ("Innenfühler 2", T(d.IndoorTemp2), "Zweiter Innenfühler (Eigenschaft 0x00E0)"),
                ($"T2 · Innenregister ({(heating ? "Verflüssiger" : "Verdampfer")})", T(d.T2IndoorCoil), null),
                ($"T3 · Außenregister ({(heating ? "Verdampfer" : "Verflüssiger")})", T(d.T3OutdoorCoil), null),
                ("T4 · Außenluft", T(d.T4OutdoorAir), null),
                ("TP · Heißgasleitung", N(d.TpDischarge, "°C"), null),
                ("EEV-Öffnung", N(d.EevOpening, "Schritte"), "Öffnung des elektronischen Expansionsventils"),
            },
            new (string, string, string?)[]
            {
                ("Lüfter innen", $"{N(d.IndoorFanRpm, "U/min")}  (Soll {N(d.IndoorFanTargetRpm, "U/min")})", null),
                ("Kondensatpumpe", Flag(d.CondensatePump, "läuft", "aus"), null),
                ("Filter", s.FilterValue, null),
                ("Fehlercode", s.ErrorCodeValue, null),
                ("Zählerstand", Fmt.Kwh(st.TotalKWh), null),
            },
        };
        if (rows.Count == 0)
        {
            string[] titles = { "VERDICHTER · AUSSENGERÄT", "KÄLTEKREIS", "INNENGERÄT" };
            for (var i = 0; i < sections.Length; i++) Section(titles[i], sections[i].Length);
        }
        var n = 0;
        foreach (var (label, value, help) in sections.SelectMany(x => x))
        {
            var (row, l, v) = rows[n++];
            l.Text = label;
            v.Text = value;
            // Die Bezeichnung kann gekürzt sein: im Tooltip ganz, mit Erklärung, wo es eine gibt.
            row.ToolTip = help == null ? label : $"{label}\n{help}";
        }
    }

    /// Überschrift und leere Zeilen eines Abschnitts anlegen.
    void Section(string title, int count)
    {
        var head = new TextBlock { Text = title, FontSize = 11, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 14, 0, 4) };
        head.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        Sections.Children.Add(head);
        content.Add(head);
        for (var i = 0; i < count; i++)
        {
            // Zwei Spalten: bei schmaler Spalte wird die Bezeichnung gekürzt (ganz im Tooltip), der Wert nie.
            // Durchsichtiger Hintergrund: der Tooltip erscheint über der ganzen Zeile, nicht nur über dem Text.
            var g = new Grid { Margin = new Thickness(0, 2, 0, 2), Background = Brushes.Transparent };
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var l = new TextBlock { FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis };
            g.Children.Add(l);
            var v = new TextBlock { FontSize = 13, Margin = new Thickness(8, 0, 0, 0) };
            v.SetResourceReference(TextBlock.ForegroundProperty, "Fg");
            Grid.SetColumn(v, 1);
            g.Children.Add(v);
            Sections.Children.Add(g);
            content.Add(g);
            rows.Add((g, l, v));
        }
    }

    static string N(int? v, string unit) => v.HasValue ? (unit.Length == 0 ? v.Value.ToString() : $"{v} {unit}") : "–";
    static string T(double? v) => v.HasValue ? Fmt.Num(v.Value, 1) + " °C" : "–";
    static string Flag(bool? v, string yes, string no) => v.HasValue ? (v.Value ? yes : no) : "–";
}
