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
        CloseButton.ToolTip = L.Tip("diagnostics.panel.hide", Hotkeys.Ctrl("D"));
        System.Windows.Automation.AutomationProperties.SetAcceleratorKey(CloseButton, Hotkeys.Ctrl("D"));
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
                loading = new TextBlock { Text = L.T("diagnostics.panel.loading"), FontSize = 12, Margin = new Thickness(0, 12, 0, 0) };
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
        var rpm = L.T("diagnostics.panel.unitRpm");
        // Technische Herkunft (Eigenschaftscodes) nur im Tooltip, nicht im Text.
        (string Label, string Value, string? Help)[][] sections =
        {
            new (string, string, string?)[]
            {
                (L.T("diagnostics.panel.power"), N(d.CompressorPowerW, "W"), null),
                (L.T("diagnostics.panel.frequency"), L.F("diagnostics.panel.withTarget", ("value", N(d.CompressorHz, "Hz")), ("target", N(d.CompressorTargetHz, "Hz"))), null),
                (L.T("diagnostics.panel.currentVoltage"), $"{N(d.CurrentA, "A")} · {N(d.VoltageV, "V")}", L.T("diagnostics.panel.currentHelp")),
                (L.T("diagnostics.panel.outdoorFan"), N(d.OutdoorFanRpm, L.T("diagnostics.panel.unitRpm")), null),
                (L.T("diagnostics.panel.defrost"), Flag(d.Defrost, L.T("diagnostics.panel.running"), L.T("diagnostics.panel.no")), null),
            },
            new (string, string, string?)[]
            {
                (L.T("diagnostics.panel.t1"), T(d.T1IndoorAir), null),
                (L.T("diagnostics.panel.indoorSensor2"), T(d.IndoorTemp2), L.T("diagnostics.panel.indoorSensor2Help")),
                (L.F("diagnostics.panel.t2", ("role", L.T(heating ? "diagnostics.panel.condenser" : "diagnostics.panel.evaporator"))), T(d.T2IndoorCoil), null),
                (L.F("diagnostics.panel.t3", ("role", L.T(heating ? "diagnostics.panel.evaporator" : "diagnostics.panel.condenser"))), T(d.T3OutdoorCoil), null),
                (L.T("diagnostics.panel.t4"), T(d.T4OutdoorAir), null),
                (L.T("diagnostics.panel.tp"), N(d.TpDischarge, "°C"), null),
                (L.T("diagnostics.panel.eev"), N(d.EevOpening, L.T("diagnostics.panel.unitSteps")), L.T("diagnostics.panel.eevHelp")),
            },
            new (string, string, string?)[]
            {
                (L.T("diagnostics.panel.indoorFan"), L.F("diagnostics.panel.withTarget", ("value", N(d.IndoorFanRpm, rpm)), ("target", N(d.IndoorFanTargetRpm, rpm))), null),
                (L.T("diagnostics.panel.condensatePump"), Flag(d.CondensatePump, L.T("diagnostics.panel.running"), L.T("main.state.off")), null),
                (L.T("diagnostics.panel.filter"), s.FilterValue, null),
                (L.T("diagnostics.panel.errorCode"), s.ErrorCodeValue, null),
                (L.T("diagnostics.panel.meter"), Fmt.Kwh(st.TotalKWh), null),
            },
        };
        if (rows.Count == 0)
        {
            var upper = System.Globalization.CultureInfo.GetCultureInfo(L.Language);
            string[] titles =
            {
                L.T("diagnostics.panel.sectionCompressor").ToUpper(upper),
                L.T("diagnostics.panel.sectionCircuit").ToUpper(upper),
                L.T("diagnostics.panel.sectionIndoor").ToUpper(upper),
            };
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
