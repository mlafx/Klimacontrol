using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Axis = KlimacontrolTray.ChartMath.Axis;

namespace KlimacontrolTray;

/// Verlauf aus dem HistoryStore des Kerns (kc_history_json) wie am Mac (Charts.swift): eine Karte mit Leistung (Linie,
/// darunter das Modus-Band), Temperatur (Raum, Soll in der Modusfarbe) und Außen (geglättet, gepunktet) untereinander
/// mit gemeinsamer Zeitachse, Beschriftung nur am untersten Graphen; ab `historyGridFrom` als 2 × 2 Karten. Mit
/// „Außentemperatur im Temperaturgraphen“ steht Außen im Temperaturgraphen. Höhen nach `ChartMath.ChartHeights`.
///
/// Sparsam fürs Software-Zeichnen: neu geladen nur bei anderem Zeitraum, neuem Zeitfenster des Kerns oder (1 h/6 h)
/// neuer `HistoryRevision`; neu gezeichnet nur bei neuen Daten, anderer Größe, anderem Thema oder anderer Modusfarbe,
/// beim Ziehen an der Fenstergröße höchstens alle 120 ms. Je Reihe wenige Pfade mit eingefrorener Geometrie.
public partial class ChartsPanel : UserControl
{
    /// Neutrales Grau der Außentemperatur (wie `ChartStyle.outdoorBase` am Mac); auch für den Verbrauch.
    internal static readonly Color OutdoorBase = Color.FromRgb(0x80, 0x85, 0x8F);
    static Color LineColor => Theme.Foreground;
    static Color OutdoorColor => Theme.Series(OutdoorBase);
    static Color ModeColor(int mode) => Theme.Accent(Codes.Tint(mode));
    /// Soll in der Farbe des aktuellen Modus.
    static Color TargetColor() => Core.Shared.Snap.State is { } st ? ModeColor(st.Mode) : Color.FromRgb(0x00, 0x5F, 0xB8);

    /// Gewählter Zeitraum (Sekunden); gemerkt unter Prefs "ChartRange". Die Zeiträume, den Standard (bei unbekanntem
    /// gemerkten Wert), die Teilung der Zeitachse, die Zahl der Zeitfenster und die Lückenregel gibt der Kern vor
    /// (`Options.Chart`); 0 = noch nicht bekannt.
    static double range;

    static ChartOptions Chart => Core.Shared.Snap.Options.Chart;
    static WindowOptions WindowRules => Core.Shared.Snap.Options.Window;

    // Strichmuster in Vielfachen der Strichstärke: Soll gestrichelt (5/3), Außen gepunktet (runde Punkte im Abstand 4).
    const double LineWidth = 1.75, OutdoorWidth = 2;
    static readonly DoubleCollection GridDash = Frozen(new DoubleCollection { 2, 3 });
    static readonly DoubleCollection TargetDash = Frozen(new DoubleCollection { 5 / LineWidth, 3 / LineWidth });
    static readonly DoubleCollection OutdoorDash = Frozen(new DoubleCollection { 0.01, 4 / OutdoorWidth });

    /// Deckkraft einer Lücke (Linie und Fläche).
    const double GapOpacity = 0.22;
    /// Fläche unter der Leistung (höchstens 8 %).
    const byte AreaAlpha = 0x12;

    /// Rechts die Y-Beschriftung in fester Breite (gleiche Zeichenfläche in allen Graphen); oben Platz für die oberste
    /// Beschriftung, unten für die Zeitbeschriftung bzw. ohne sie nur ein schmaler Rand.
    const double AxisLabelWidth = 46, AxisGap = 6, AxisWidth = AxisLabelWidth + AxisGap, Pad = 8, TimeLabels = 20, NoTimeLabels = 4;
    /// Modus-Band unter der Leistung: Höhe und Abstand zur Nulllinie.
    const double BandHeight = 4, BandGap = 5;

    List<Sample> samples = new();
    List<ChartMath.ModeRun> modeRuns = new();
    double? hoverX;
    Canvas? hoverCanvas;
    /// Einmaliger Timer auf den nächsten Wechsel des Zeitfensters; nur aktiv, solange der Verlauf sichtbar ist.
    readonly DispatcherTimer reload = new();
    /// Beim Ziehen an der Fenstergröße: sofort zeichnen, danach höchstens alle 120 ms und einmal am Ende.
    readonly DispatcherTimer sizeThrottle = new() { Interval = TimeSpan.FromMilliseconds(120) };
    bool sizePending;

    // Stand des letzten Ladens: Zeitraum, Zeitfenster, Verlaufsrevision des Kerns; dataVersion zählt jedes Laden.
    double loadedRange;
    long loadedBucket = long.MinValue;
    int loadedRevision = int.MinValue;
    int dataVersion, themeVersion;
    readonly Dictionary<Canvas, (double W, double H, int Data, int Theme, Color Tint, bool Labels, bool Combined)> drawKeys = new();
    Color targetTint;

    /// Gemeinsame Zeitachse aller Graphen (Unix-Sekunden): erster Punkt bis jetzt.
    double from, to = 1;
    /// Y-Skalen, beim Laden aus den Daten berechnet.
    Axis? powerAxis, insideAxis, combinedAxis, outsideAxis;
    bool anyOutdoor;

    // Anordnung: Raster, Außen im Temperaturgraphen, eigener Außengraph, Graphen vorhanden.
    bool grid, combined, separateOutdoor, hasCharts, placed;
    /// Höhe der Spalte ohne die Graphen, je Anordnung gemessen (Raster ja/nein, Außen im Temperaturgraphen ja/nein).
    readonly Dictionary<int, double> overhead = new();
    double applied;
    int layoutKey, measureRounds;

    /// Gezeichnete Skala und unterer Rand je Graph – nur diese Graphen bekommen eine Wertanzeige.
    readonly Dictionary<Canvas, (Axis Shown, double Bottom)> drawn = new();
    readonly Dictionary<Canvas, List<TextBlock>> labelPool = new();
    readonly Dictionary<Canvas, Line> hoverLines = new();
    readonly Border hoverLabel;
    readonly Ellipse hoverDot;
    readonly TextBlock hoverValue, hoverWhen, hoverExtra;

    /// Zeitraum-Knöpfe werden gerade vom Code gesetzt (kein Laden, kein Merken).
    bool updatingRange;

    public event Action? CloseRequested;

    public ChartsPanel()
    {
        InitializeComponent();
        CloseButton.Content = Icons.Make(Icons.Close, 11, null, 1.6);
        CloseButton.ToolTip = L.Tip("charts.hide", Hotkeys.Ctrl("G"));
        AutomationProperties.SetAcceleratorKey(CloseButton, Hotkeys.Ctrl("G"));
        foreach (var (cc, icon, size) in new[] { (TitleIcon, Icons.Chart, 15.0), (PowerIcon, Icons.Bolt, 13.0), (TempIcon, Icons.Thermometer, 13.0), (OutdoorIcon, Icons.Sun, 13.0) })
        {
            cc.SetResourceReference(ForegroundProperty, "Sub");
            cc.Content = Icons.Make(icon, size);
        }
        ModeLegend.ToolTip = L.T("charts.modeBandHelp");
        AutomationProperties.SetHelpText(ModeLegend, L.T("charts.modeBandHelp"));
        EnsureRanges();

        // Wertanzeige (Linie je Graph; Punkt und Kasten im Graphen unter der Maus) einmal anlegen; ZIndex hält sie
        // über den Graphen, auch wenn diese neu gezeichnet werden.
        foreach (var c in Canvases)
        {
            labelPool[c] = new List<TextBlock>();
            var l = new Line { StrokeThickness = 1, Opacity = 0.6, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
            l.SetResourceReference(Shape.StrokeProperty, "Sub");
            Panel.SetZIndex(l, 1);
            hoverLines[c] = l;
            c.Children.Add(l);
            c.SizeChanged += (_, _) => CanvasSized();
        }
        hoverDot = new Ellipse { Width = 9, Height = 9, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
        Panel.SetZIndex(hoverDot, 2);
        hoverValue = new TextBlock { FontSize = 16, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center };
        hoverWhen = new TextBlock { FontSize = 11, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
        hoverExtra = new TextBlock { FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center };
        hoverExtra.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        hoverLabel = new Border
        {
            Child = new StackPanel { Children = { hoverValue, hoverWhen, hoverExtra } },
            BorderThickness = new Thickness(1), CornerRadius = Theme.InnerCorner, Padding = new Thickness(8, 4, 8, 4),
            Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        };
        hoverLabel.SetResourceReference(Border.BackgroundProperty, "Card");
        hoverLabel.SetResourceReference(Border.BorderBrushProperty, "Line");
        Panel.SetZIndex(hoverLabel, 3);

        sizeThrottle.Tick += (_, _) =>
        {
            sizeThrottle.Stop();
            if (!sizePending) return;
            sizePending = false;
            Draw();
            sizeThrottle.Start();
        };
        SizeChanged += (_, _) => Relayout();
        PowerFooter.SizeChanged += (_, e) => { if (e.WidthChanged) ArrangeFooter(); };
        reload.Tick += (_, _) =>
        {
            reload.Stop();
            if (!IsVisible) return;
            if (NeedsReload()) Load(); else Arm();
        };
        // Beim Umordnen der Spalten kommt kein MouseLeave – die Wertanzeige bliebe sonst stehen.
        IsVisibleChanged += (_, _) =>
        {
            hoverX = null;
            if (IsVisible)
            {
                // Erst nach dem Layout: dann sind auch die Graphen sichtbar und haben ihre Größe. Draw zeichnet nur, was
                // sich geändert hat (z. B. Design gewechselt, solange ausgeblendet).
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (!IsVisible) return;
                    if (NeedsReload()) Load(); else { Relayout(); Draw(); Arm(); }
                }), DispatcherPriority.Loaded);
            }
            else
            {
                reload.Stop();
                sizeThrottle.Stop();
            }
        };
        // Ein laufender Timer hielte ein geschlossenes Fenster im Speicher fest.
        Loaded += (_, _) =>
        {
            Core.Shared.Changed -= CoreChanged;
            Core.Shared.Changed += CoreChanged;
            Theme.Changed -= ThemeChanged;
            Theme.Changed += ThemeChanged;
            Appearance.Changed -= AppearanceChanged;
            Appearance.Changed += AppearanceChanged;
            BuildTempLegend();
            if (IsVisible) Arm();
        };
        Unloaded += (_, _) => Detach();
    }

    Canvas[] Canvases => new Canvas[] { PowerCanvas, TempCanvas, OutdoorCanvas };

    /// Zeitraum-Knöpfe nach der Liste des Kerns einmal anlegen (erst, wenn der erste Schnappschuss da ist). false = noch
    /// keine Zeiträume bekannt – dann gibt es nichts zu laden.
    bool EnsureRanges()
    {
        if (RangePanel.Children.Count > 0) return true;
        var chart = Chart;
        if (chart.Ranges.Count == 0) return false;
        var saved = Prefs.GetInt("ChartRange", (int)chart.DefaultRange);
        if (range <= 0 || chart.Ranges.All(r => r.Seconds != range))
            range = chart.Ranges.Any(r => r.Seconds == saved) ? saved : chart.DefaultRange;
        // Optionsfelder im Knopf-Stil: Maus, Leertaste und Sprachausgabe wählen alle über `Checked`.
        var look = TryFindResource(typeof(ToggleButton)) as Style;
        foreach (var r in chart.Ranges)
        {
            var secs = r.Seconds;
            var b = new RadioButton { Content = r.Label, Tag = secs, FontSize = 12, Padding = new Thickness(7, 3, 7, 3), Margin = new Thickness(2, 0, 0, 0) };
            if (look != null) b.Style = look;
            AutomationProperties.SetName(b, L.F("charts.windows.rangeName", ("label", r.Label)));
            b.Checked += (_, _) =>
            {
                if (updatingRange || range == secs) return;
                range = secs;
                Prefs.SetInt("ChartRange", (int)secs);
                Load();
            };
            RangePanel.Children.Add(b);
        }
        ShowRange();
        return true;
    }

    /// Beim Schließen des Fensters: Timer anhalten, falls Unloaded ausbleibt.
    public void Detach()
    {
        hoverX = null;
        reload.Stop();
        sizeThrottle.Stop();
        Energy.Detach();
        Core.Shared.Changed -= CoreChanged;
        Theme.Changed -= ThemeChanged;
        Appearance.Changed -= AppearanceChanged;
    }

    /// Hell/Dunkel, Thema oder Hoher Kontrast gewechselt: der Rest folgt über Ressourcenverweise, die Graphen (eigene
    /// Pinsel, eingefrorene Geometrie) und Legenden einmal neu.
    void ThemeChanged()
    {
        themeVersion++;
        BuildTempLegend();
        BuildModeLegend();
        if (IsVisible) Draw();
    }

    /// „Außentemperatur im Temperaturgraphen“ umgeschaltet: Anordnung und Temperaturgraph neu.
    void AppearanceChanged()
    {
        if (Appearance.Current.TemperatureCombined == combined) return;
        BuildTempLegend();
        if (IsVisible) { Relayout(); Draw(); }
    }

    /// Neuer Zustand vom Kern: neu laden nur bei neuem Verlaufspunkt (1 h/6 h), sonst höchstens eine neue Modusfarbe
    /// übernehmen (das Soll ist in der Modusfarbe).
    void CoreChanged()
    {
        if (!IsVisible) return;
        if (NeedsReload()) Load();
        else if (TargetColor() != targetTint)
        {
            BuildTempLegend();
            DrawTemp();
            DrawHover();
        }
    }

    static DoubleCollection Frozen(DoubleCollection d) { d.Freeze(); return d; }

    void Close_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();

    /// Länge eines Zeitfensters des Kerns (der Verlauf liefert höchstens `WindowCount` Punkte je Zeitraum).
    static double BucketSeconds => range / Math.Max(1, Chart.WindowCount);

    /// Ab diesem Abstand zweier Punkte gilt die Strecke als Lücke: ein Vielfaches des Mittelungsfensters, mindestens
    /// eine Mindestdauer (beides vom Kern).
    static double GapThreshold => Math.Max(Chart.GapMinSeconds, Chart.GapFactor * Math.Max(1, BucketSeconds));

    static long Bucket() => (long)Math.Floor(Codes.Epoch(DateTime.Now) / BucketSeconds);

    /// Revision zählt nur bei kurzen Zeiträumen; bei 24 h/7 T genügt der Wechsel des Zeitfensters.
    static int Revision() => range <= 6 * 3600 ? Core.Shared.Snap.HistoryRevision : 0;

    /// Lohnt sich neues Laden? Ja bei anderem Zeitraum, neuem Zeitfenster oder (1 h/6 h) neuem Verlaufspunkt.
    bool NeedsReload() => EnsureRanges() && (loadedRange != range || Bucket() != loadedBucket || Revision() != loadedRevision);

    /// Timer auf den nächsten Wechsel des Zeitfensters stellen (knapp danach, damit der Kern ihn schon kennt).
    void Arm()
    {
        reload.Stop();
        if (!IsVisible || !EnsureRanges()) return;
        var len = BucketSeconds;
        var now = Codes.Epoch(DateTime.Now);
        var wait = (Math.Floor(now / len) + 1) * len - now + 0.05;
        reload.Interval = TimeSpan.FromSeconds(Math.Clamp(wait, 0.2, len + 0.05));
        reload.Start();
    }

    /// Knöpfe auf den gewählten Zeitraum stellen, ohne erneut zu laden.
    void ShowRange()
    {
        updatingRange = true;
        try { foreach (RadioButton b in RangePanel.Children) b.IsChecked = (double)b.Tag == range; }
        finally { updatingRange = false; }
    }

    void Load()
    {
        if (!EnsureRanges()) return;
        ShowRange();
        loadedRange = range;
        loadedBucket = Bucket();
        loadedRevision = Revision();
        samples = Core.Shared.History(TimeSpan.FromSeconds(range));
        dataVersion++;
        var now = Codes.Epoch(DateTime.Now);
        // Die Zeitachse endet bei „jetzt“, nicht beim letzten Punkt: eine Lücke am Ende bleibt sichtbar.
        from = samples.Count > 0 ? samples[0].T : now - range;
        to = Math.Max(samples.Count > 0 ? samples[^1].T : now, now);
        if (!(to > from)) to = from + 1;
        var inside = samples.Select(s => s.Indoor).Concat(samples.Select(TargetOf)).OfType<double>().ToList();
        var outside = samples.Select(s => s.Outdoor).OfType<double>().ToList();
        anyOutdoor = outside.Count > 0;
        powerAxis = ChartMath.PowerAxis(samples.Select(s => s.Power).OfType<double>());
        insideAxis = ChartMath.TempAxis(inside);
        combinedAxis = ChartMath.TempAxis(inside.Concat(outside));
        outsideAxis = ChartMath.TempAxis(outside);
        modeRuns = ChartMath.ModeRuns(samples.Select(s => (s.T, s.Mode)), GapThreshold);
        hasCharts = samples.Count >= 2;
        RenderStats();
        BuildModeLegend();
        EmptyText.Visibility = hasCharts ? Visibility.Collapsed : Visibility.Visible;
        ShowAvailability();
        Summaries();
        Relayout();
        Draw();
        Arm();
    }

    /// Ließ sich die Verlaufsdatenbank nicht öffnen, sagt der Hinweis das statt „zu wenig Daten“, und der Verbrauch
    /// (liest dieselbe Datenbank) entfällt.
    void ShowAvailability()
    {
        var unavailable = Core.Shared.Snap.HistoryUnavailable;
        EmptyText.Text = L.T(unavailable ? "charts.unavailable" : "charts.windows.tooFew");
        Energy.Visibility = unavailable ? Visibility.Collapsed : Visibility.Visible;
    }

    /// Uhrzeit, über einen Tag Zeitraum mit Wochentag davor.
    static string When(double t)
    {
        var local = Codes.Local(t);
        return range > 86400 ? Fmt.WeekdayShort(local) + " " + Fmt.Clock(local) : Fmt.Clock(local);
    }

    /// Soll nur bei eingeschalteter Anlage (ausgeschaltet gibt es kein Ziel).
    static double? TargetOf(Sample s) => s.On ? s.Target : null;

    // Kennzahlen, Legenden, Namen für die Sprachausgabe

    /// Kennzahlenzeile aus dem Kern (alle gespeicherten Punkte, `HistoryStore.stats`), jeder Teil mit Kurzinfo.
    void RenderStats()
    {
        StatsLine.Children.Clear();
        var line = Core.Shared.Stats(TimeSpan.FromSeconds(range)).Line;
        for (var i = 0; i < line.Count; i++)
        {
            var s = line[i];
            var tb = new TextBlock { Text = (i > 0 ? " · " : "") + s.Text, FontSize = 12, ToolTip = s.Help };
            tb.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
            AutomationProperties.SetName(tb, s.Text);
            AutomationProperties.SetHelpText(tb, s.Help);
            StatsLine.Children.Add(tb);
        }
        ArrangeFooter();
    }

    /// Legende des Modus-Bands: Farbstreifen und Name je Betriebsart, die im Zeitraum vorkam (Zustand nie nur über Farbe).
    void BuildModeLegend()
    {
        ModeLegend.Children.Clear();
        var names = new List<string>();
        foreach (var m in modeRuns.Select(r => r.Mode).Distinct())
        {
            var name = ModeName(m);
            names.Add(name);
            var text = new TextBlock { Text = name, FontSize = 12, Margin = new Thickness(5, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            text.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
            ModeLegend.Children.Add(new Rectangle { Width = 14, Height = BandHeight, RadiusX = 1, RadiusY = 1, Fill = Paints.Of(ModeColor(m)), VerticalAlignment = VerticalAlignment.Center });
            ModeLegend.Children.Add(text);
        }
        AutomationProperties.SetName(ModeLegend, string.Join(", ", names));
        ArrangeFooter();
    }

    static string ModeName(int mode)
    {
        foreach (var (value, label, _) in Codes.Modes)
            if (value == mode) return label;
        return L.F("mode.unknown", ("value", mode.ToString(System.Globalization.CultureInfo.InvariantCulture)));
    }

    /// Legende nebeneinander mit den Kennzahlen rechts, wenn beide in eine Zeile passen; sonst Kennzahlen oben.
    void ArrangeFooter()
    {
        var width = PowerFooter.ActualWidth;
        if (width <= 0) return;
        var infinite = new Size(double.PositiveInfinity, double.PositiveInfinity);
        ModeLegend.Measure(infinite);
        StatsLine.Measure(infinite);
        var legend = ModeLegend.Children.Count > 0;
        var oneRow = !legend || ModeLegend.DesiredSize.Width + 12 + StatsLine.DesiredSize.Width <= width;
        Grid.SetRow(StatsLine, 0);
        Grid.SetColumn(StatsLine, oneRow ? 1 : 0);
        Grid.SetColumnSpan(StatsLine, oneRow ? 1 : 2);
        StatsLine.HorizontalAlignment = oneRow ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        Grid.SetRow(ModeLegend, oneRow ? 0 : 1);
        Grid.SetColumnSpan(ModeLegend, oneRow ? 1 : 2);
        ModeLegend.Margin = new Thickness(0, oneRow ? 0 : 4, 0, 0);
        ModeLegend.Visibility = legend ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Linienmuster der Temperaturreihen (durchgezogen, gestrichelt, gepunktet) mit Namen.
    void BuildTempLegend()
    {
        TempLegend.Children.Clear();
        targetTint = TargetColor();
        LegendItem(L.T("charts.series.room"), LineColor, null, LineWidth);
        LegendItem(L.T("charts.series.target"), targetTint, TargetDash, LineWidth);
        if (Appearance.Current.TemperatureCombined && anyOutdoor) LegendItem(L.T("charts.series.outdoor"), OutdoorColor, OutdoorDash, OutdoorWidth);
    }

    void LegendItem(string title, Color color, DoubleCollection? dash, double width)
    {
        var line = new Line { X1 = 0, X2 = 16, Y1 = 2, Y2 = 2, Width = 16, Height = 4, Stroke = Paints.Of(color), StrokeThickness = width, VerticalAlignment = VerticalAlignment.Center };
        if (dash != null)
        {
            line.StrokeDashArray = dash;
            line.StrokeDashCap = PenLineCap.Round;
        }
        var text = new TextBlock { Text = title, FontSize = 12, Margin = new Thickness(5, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        text.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        TempLegend.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { line, text } });
    }

    /// Ein Element je Graph für die Sprachausgabe statt hunderter Punkte: „zuletzt 412 W, niedrigster 0 W, höchster 980 W“.
    void Summaries()
    {
        AutomationProperties.SetHelpText(PowerCanvas, Summary(samples.Select(s => s.Power), Fmt.Watts));
        var temp = L.T("charts.series.room") + ": " + Summary(samples.Select(s => s.Indoor), v => Fmt.Temp(v));
        if (Appearance.Current.TemperatureCombined && anyOutdoor)
            temp += "; " + L.T("charts.series.outdoor") + ": " + Summary(samples.Select(s => s.Outdoor), v => Fmt.Temp(v));
        AutomationProperties.SetHelpText(TempCanvas, temp);
        AutomationProperties.SetHelpText(OutdoorCanvas, Summary(samples.Select(s => s.Outdoor), v => Fmt.Temp(v)));
    }

    static string Summary(IEnumerable<double?> values, Func<double?, string> format)
    {
        var list = values.OfType<double>().ToList();
        if (list.Count == 0) return L.T("charts.summaryNone");
        return L.F("charts.summary", ("last", format(list[^1])), ("low", format(list.Min())), ("high", format(list.Max())));
    }

    // Anordnung und Höhen

    /// Breite und sichtbare Höhe der Spalte (ScrollViewer des Hauptfensters), dazu der Rand der Spalte um dieses Element.
    (double Width, double Height, double Margins) Column()
    {
        DependencyObject? d = this;
        while (d != null && d is not ScrollViewer) d = VisualTreeHelper.GetParent(d);
        var margins = Margin.Top + Margin.Bottom + (Parent is FrameworkElement p ? p.Margin.Top + p.Margin.Bottom : 0);
        if (d is ScrollViewer sv) return (sv.ActualWidth, sv.ViewportHeight > 0 ? sv.ViewportHeight : sv.ActualHeight, margins);
        return (ActualWidth, 0, margins);
    }

    /// Raster oder einspaltig, eigener Außengraph oder nicht, Höhen der Graphen nach `ChartMath.ChartHeights`.
    void Relayout()
    {
        var rules = WindowRules;
        var (columnWidth, columnHeight, _) = Column();
        var gridNow = rules.HistoryGridFrom > 0 && columnWidth >= rules.HistoryGridFrom;
        combined = Appearance.Current.TemperatureCombined;
        separateOutdoor = hasCharts && !combined && anyOutdoor;
        var showsEnergy = Energy.Visibility == Visibility.Visible;
        Place(gridNow);

        var key = (gridNow ? 1 : 0) + (combined ? 2 : 0);
        if (key != layoutKey) { layoutKey = key; measureRounds = 0; }
        // Ohne Regeln vom Kern (vor dem ersten Schnappschuss) bleiben die Höhen aus dem XAML.
        if (rules.ChartMin.Power <= 0) return;
        var h = ChartMath.ChartHeights(rules, columnHeight, gridNow, overhead.TryGetValue(key, out var o) ? o : null, !combined);
        if (gridNow)
        {
            var top = Math.Max(h.Power, h.Temperature);
            var bottom = separateOutdoor ? Math.Max(h.Outdoor, h.Energy) : h.Energy;
            PowerCanvas.Height = TempCanvas.Height = top;
            OutdoorCanvas.Height = bottom;
            Energy.PlotHeight = bottom;
            applied = (hasCharts ? top : 0) + (separateOutdoor || showsEnergy ? bottom : 0);
        }
        else
        {
            PowerCanvas.Height = h.Power;
            TempCanvas.Height = h.Temperature;
            OutdoorCanvas.Height = Math.Max(1, h.Outdoor);
            Energy.PlotHeight = h.Energy;
            applied = (hasCharts ? h.Power + h.Temperature : 0) + (separateOutdoor ? h.Outdoor : 0) + (showsEnergy ? h.Energy : 0);
        }
        if (hasCharts && measureRounds < 4) Dispatcher.BeginInvoke(new Action(MeasureOverhead), DispatcherPriority.Loaded);
    }

    /// Höhe der Spalte ohne die Graphen messen (Kopf, Überschriften, Kennzahlenzeile, Abstände); weicht sie ab, die Höhen
    /// damit neu rechnen. Höchstens wenige Runden je Anordnung, damit sich nichts aufschaukelt.
    void MeasureOverhead()
    {
        if (!IsVisible || !hasCharts || Root.ActualHeight <= 0) return;
        var value = Math.Max(0, Math.Ceiling(Root.ActualHeight + Column().Margins - applied));
        if (overhead.TryGetValue(layoutKey, out var old) && Math.Abs(old - value) < 1) return;
        overhead[layoutKey] = value;
        measureRounds++;
        Relayout();
    }

    /// Abschnitte in die eine Karte (einspaltig) oder in die Karten des Rasters hängen und ein- oder ausblenden.
    void Place(bool gridNow)
    {
        if (!placed || gridNow != grid)
        {
            placed = true;
            grid = gridNow;
            hoverX = null;
            foreach (var section in new FrameworkElement[] { PowerSection, TempSection, OutdoorSection })
                switch (section.Parent)
                {
                    case Panel panel: panel.Children.Remove(section); break;
                    case Border border: border.Child = null; break;
                }
            if (Energy.Parent is Panel energyParent) energyParent.Children.Remove(Energy);
            if (gridNow)
            {
                PowerCard.Child = PowerSection;
                TempCard.Child = TempSection;
                OutdoorCard.Child = OutdoorSection;
                Grid.SetRow(Energy, 2);
                Energy.Margin = new Thickness(0);
                ChartGrid.Children.Add(Energy);
            }
            else
            {
                MainStack.Children.Clear();
                MainStack.Children.Add(PowerSection);
                MainStack.Children.Add(Divider1);
                MainStack.Children.Add(TempSection);
                MainStack.Children.Add(Divider2);
                MainStack.Children.Add(OutdoorSection);
                Grid.SetRow(Energy, 4);
                Grid.SetColumn(Energy, 0);
                Grid.SetColumnSpan(Energy, 1);
                Energy.Margin = new Thickness(0, 16, 0, 0);
                Root.Children.Add(Energy);
            }
        }
        var charts = hasCharts ? Visibility.Visible : Visibility.Collapsed;
        var outdoor = separateOutdoor ? Visibility.Visible : Visibility.Collapsed;
        MainCard.Visibility = !gridNow && hasCharts ? Visibility.Visible : Visibility.Collapsed;
        ChartGrid.Visibility = gridNow ? Visibility.Visible : Visibility.Collapsed;
        PowerCard.Visibility = TempCard.Visibility = charts;
        ChartGrid.RowDefinitions[1].Height = new GridLength(hasCharts ? 16 : 0);
        OutdoorCard.Visibility = OutdoorSection.Visibility = Divider2.Visibility = outdoor;
        if (gridNow)
        {
            // Ohne eigenen Außengraphen nimmt der Verbrauch die ganze untere Zeile.
            Grid.SetColumn(Energy, separateOutdoor ? 2 : 0);
            Grid.SetColumnSpan(Energy, separateOutdoor ? 1 : 3);
        }
    }

    // Zeichnen

    void CanvasSized()
    {
        if (sizeThrottle.IsEnabled) { sizePending = true; return; }
        Draw();
        sizeThrottle.Start();
    }

    void Draw()
    {
        DrawPower();
        DrawTemp();
        DrawOutdoor();
        DrawHover();
    }

    /// Zeitbeschriftung nur am untersten Graphen einer Karte; im Raster hat jede Karte ihre eigene.
    bool TimeLabelsOn(Canvas c) => grid || c == OutdoorCanvas || (c == TempCanvas && !separateOutdoor);

    /// Zeichnen nur, wenn sich Größe, Daten, Thema, Farbe, Beschriftung oder Anordnung geändert haben.
    bool Changed(Canvas c, Color tint)
    {
        // Ausgeblendet wird nicht gezeichnet und nichts gemerkt: beim Einblenden zeichnet die neue Größe.
        if (!c.IsVisible)
        {
            drawKeys.Remove(c);
            return false;
        }
        var key = (c.ActualWidth, c.ActualHeight, dataVersion, themeVersion, tint, TimeLabelsOn(c), combined);
        if (drawKeys.TryGetValue(c, out var old) && old == key) return false;
        drawKeys[c] = key;
        return true;
    }

    void DrawPower()
    {
        if (!Changed(PowerCanvas, default)) return;
        var labels = TimeLabelsOn(PowerCanvas);
        var axis = powerAxis;
        // Unter der Nulllinie liegt das Modus-Band; der Bereich wird dafür nach unten verlängert.
        var plot = PowerCanvas.ActualHeight - Pad - (labels ? TimeLabels : NoTimeLabels);
        var shown = axis?.ExtendedBelow((BandHeight + BandGap) / Math.Max(40, plot));
        DrawChart(PowerCanvas, axis, shown, new[] { new Series(LineColor, s => s.Power, Area: true) }, "W", labels, DrawBand);
    }

    void DrawTemp()
    {
        targetTint = TargetColor();
        if (!Changed(TempCanvas, targetTint)) return;
        var outdoor = combined && anyOutdoor;
        var axis = (outdoor ? combinedAxis : insideAxis) ?? Fixed(Chart.TemperatureAxis);
        var series = new List<Series>();
        if (outdoor) series.Add(new Series(OutdoorColor, s => s.OutdoorSmooth, Dash: OutdoorDash, Width: OutdoorWidth));
        series.Add(new Series(targetTint, TargetOf, Step: true, Dash: TargetDash));
        series.Add(new Series(LineColor, s => s.Indoor));
        DrawChart(TempCanvas, axis, axis, series.ToArray(), "°C", TimeLabelsOn(TempCanvas), null);
    }

    void DrawOutdoor()
    {
        if (!Changed(OutdoorCanvas, default)) return;
        var axis = separateOutdoor ? outsideAxis ?? Fixed(Chart.OutdoorAxis) : null;
        DrawChart(OutdoorCanvas, axis, axis, new[] { new Series(OutdoorColor, s => s.OutdoorSmooth, Dash: OutdoorDash, Width: OutdoorWidth) },
            "°C", TimeLabelsOn(OutdoorCanvas), null);
    }

    static Axis? Fixed(RangeInfo r) => r.Max > r.Min ? ChartMath.Fixed(r.Min, r.Max) : null;

    /// Eine Reihe: Farbe, Wert je Punkt, Stufen (Soll), Strichmuster und – mit `Area` – blasse Fläche bis zur Nulllinie.
    record Series(Color Color, Func<Sample, double?> Get, bool Step = false, DoubleCollection? Dash = null, double Width = LineWidth, bool Area = false);

    const double Left = 0;
    double X(double t, double w) => Left + (t - from) / (to - from) * (w - Left - AxisWidth);
    double TimeAt(double x, double w) => from + (x - Left) / (w - Left - AxisWidth) * (to - from);
    static double Y(double v, Axis a, double h, double bottom) => Pad + (1 - (v - a.Min) / (a.Max - a.Min)) * (h - Pad - bottom);

    /// Modus-Band: je Betriebsart ein Pfad mit Rechtecken vom Beginn bis zum Ende jedes Laufs, ganz unten im Graphen.
    void DrawBand(Canvas c, double w, double h, double bottom)
    {
        var y = h - bottom - BandHeight;
        foreach (var group in modeRuns.GroupBy(r => r.Mode))
        {
            var g = new StreamGeometry();
            using (var ctx = g.Open())
                foreach (var r in group)
                {
                    double x0 = X(Math.Max(r.Start, from), w), x1 = X(Math.Min(r.End, to), w);
                    if (x1 - x0 < 0.5) x1 = x0 + 0.5;
                    ctx.BeginFigure(new Point(x0, y), true, true);
                    ctx.PolyLineTo(new[] { new Point(x1, y), new Point(x1, y + BandHeight), new Point(x0, y + BandHeight) }, false, false);
                }
            g.Freeze();
            c.Children.Add(new Path { Data = g, Fill = Paints.Of(ModeColor(group.Key)), IsHitTestVisible = false });
        }
    }

    TextBlock Label(Canvas c, ref int used, string text, double x, double y)
    {
        var labels = labelPool[c];
        if (used == labels.Count)
        {
            var tb = new TextBlock { FontSize = 11, IsHitTestVisible = false };
            tb.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
            labels.Add(tb);
        }
        var t = labels[used++];
        t.Text = text;
        Canvas.SetLeft(t, x);
        Canvas.SetTop(t, y);
        return t;
    }

    /// Gitter nach der Achse des Kerns (Zahlen rechts in fester Breite, Einheit an der obersten Linie), Zeitmarken auf
    /// runden Ortszeiten, dann die Reihen. `shown` ist der gezeichnete Bereich, falls er unter die Gitterlinien reicht.
    void DrawChart(Canvas c, Axis? axis, Axis? shown, Series[] series, string unit, bool timeLabels, Action<Canvas, double, double, double>? extra)
    {
        if (hoverCanvas is { IsMouseOver: false }) hoverX = null;
        drawn.Remove(c);
        // Alles außer der Wertanzeige entfernen; die bleibt liegen und wird nur verschoben.
        for (var i = c.Children.Count - 1; i >= 0; i--)
        {
            var ch = c.Children[i];
            if (ch != hoverLines[c] && ch != hoverLabel && ch != hoverDot) c.Children.RemoveAt(i);
        }
        double w = c.ActualWidth, h = c.ActualHeight;
        if (!hasCharts || axis is not { } a || shown is not { } s || !c.IsVisible || w < AxisWidth + 40 || h < 30) return;
        var bottom = timeLabels ? TimeLabels : NoTimeLabels;
        drawn[c] = (s, bottom);
        var used = 0;
        var plotRight = w - AxisWidth;

        var horizontal = new StreamGeometry();
        var ticks = a.Ticks();
        using (var ctx = horizontal.Open())
            foreach (var v in ticks)
            {
                var y = Y(v, s, h, bottom);
                ctx.BeginFigure(new Point(Left, y), false, false);
                ctx.LineTo(new Point(plotRight, y), true, false);
                var text = v == ticks[^1] ? Fmt.Num(v, 0) + " " + unit : Fmt.Num(v, 0);
                c.Children.Add(Label(c, ref used, text, plotRight + AxisGap, y - 8));
            }
        horizontal.Freeze();
        c.Children.Add(GridPath(horizontal, null));

        var info = Chart.Ranges.FirstOrDefault(r => r.Seconds == range);
        var vertical = new StreamGeometry();
        if (info is { TickMinutes: > 0 })
            using (var ctx = vertical.Open())
                foreach (var t in ChartMath.TimeTicks(from, to, info.TickMinutes, plotRight - Left, info.TickLabelHalfWidth, TimeZoneInfo.Local))
                {
                    var x = X(t, w);
                    ctx.BeginFigure(new Point(x, Pad), false, false);
                    ctx.LineTo(new Point(x, h - bottom), true, false);
                    if (!timeLabels) continue;
                    var tick = Label(c, ref used, info.TickMinutes >= 1440 ? Fmt.DayMonth(t) : Fmt.Clock(t), x, h - bottom + 3);
                    tick.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                    Canvas.SetLeft(tick, Math.Clamp(x - tick.DesiredSize.Width / 2, 0, Math.Max(0, w - tick.DesiredSize.Width)));
                    c.Children.Add(tick);
                }
        vertical.Freeze();
        c.Children.Add(GridPath(vertical, GridDash));

        extra?.Invoke(c, w, h, bottom);

        var baseY = Y(Math.Max(a.Min, Math.Min(0, a.Max)), s, h, bottom);
        foreach (var se in series)
        {
            var area = se.Area ? new StreamGeometry() : null;
            var gapArea = se.Area ? new StreamGeometry() : null;
            var line = new StreamGeometry();
            var gapLine = new StreamGeometry();
            var gaps = 0;
            using (var lc = line.Open())
            using (var gc = gapLine.Open())
            using (var ac = area?.Open())
            using (var gac = gapArea?.Open())
            {
                Point? previous = null;
                foreach (var run in Runs(se.Get))
                {
                    var first = new Point(X(run[0].T, w), Y(run[0].V, s, h, bottom));
                    // Brücke über die Lücke: gerade von letztem zu erstem Punkt, blass (eigene Pfade mit Deckkraft).
                    if (previous is { } p)
                    {
                        gaps++;
                        gc.BeginFigure(p, false, false);
                        gc.LineTo(first, true, false);
                        if (gac != null)
                        {
                            gac.BeginFigure(p, true, true);
                            gac.PolyLineTo(new[] { first, new Point(first.X, baseY), new Point(p.X, baseY) }, false, false);
                        }
                    }
                    var pts = Thin(run.Select(q => new Point(X(q.T, w), Y(q.V, s, h, bottom))).ToList(), w);
                    previous = pts[^1];
                    if (se.Step)
                    {
                        var stepped = new List<Point>(pts.Count * 2);
                        for (var i = 0; i < pts.Count; i++)
                        {
                            if (i > 0) stepped.Add(new Point(pts[i].X, stepped[^1].Y));
                            stepped.Add(pts[i]);
                        }
                        pts = stepped;
                    }
                    if (pts.Count < 2) continue;
                    var rest = pts.GetRange(1, pts.Count - 1);
                    if (ac != null)
                    {
                        // Fläche unter der Linie bis zur Nulllinie, eine Figur je Lauf.
                        ac.BeginFigure(pts[0], true, true);
                        ac.PolyLineTo(rest, false, false);
                        ac.LineTo(new Point(pts[^1].X, baseY), false, false);
                        ac.LineTo(new Point(pts[0].X, baseY), false, false);
                    }
                    lc.BeginFigure(pts[0], false, false);
                    lc.PolyLineTo(rest, true, false);
                }
            }
            if (area != null)
            {
                area.Freeze();
                c.Children.Add(new Path { Data = area, Fill = AreaFill(se.Color), IsHitTestVisible = false });
            }
            if (gapArea != null && gaps > 0)
            {
                gapArea.Freeze();
                c.Children.Add(new Path { Data = gapArea, Fill = AreaFill(se.Color), Opacity = GapOpacity, IsHitTestVisible = false });
            }
            line.Freeze();
            c.Children.Add(SeriesPath(line, se, 1));
            if (gaps > 0)
            {
                gapLine.Freeze();
                c.Children.Add(SeriesPath(gapLine, se, GapOpacity));
            }
        }
    }

    static Path GridPath(Geometry g, DoubleCollection? dash)
    {
        var p = new Path { Data = g, StrokeThickness = 1, IsHitTestVisible = false };
        if (dash != null) p.StrokeDashArray = dash;
        p.SetResourceReference(Shape.StrokeProperty, "Line");
        return p;
    }

    static Path SeriesPath(Geometry g, Series se, double opacity)
    {
        var p = new Path
        {
            Data = g, Stroke = Paints.Of(se.Color), StrokeThickness = se.Width, StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, IsHitTestVisible = false,
        };
        if (se.Dash != null)
        {
            p.StrokeDashArray = se.Dash;
            p.StrokeDashCap = PenLineCap.Round;
        }
        if (opacity < 1) p.Opacity = opacity;
        return p;
    }

    /// Gleichmäßig blasse Fläche in der Linienfarbe, eingefroren und je Farbe nur einmal.
    static Brush AreaFill(Color c) => Paints.Of(Color.FromArgb(AreaAlpha, c.R, c.G, c.B));

    /// Mehr Punkte als Bildpunkte (7 Tage): je Bildpunktspalte nur erster, tiefster, höchster und letzter Punkt in
    /// ihrer Reihenfolge – sieht gleich aus, zeichnet aber nur einen Bruchteil.
    static List<Point> Thin(List<Point> pts, double width)
    {
        if (pts.Count <= 2 * width) return pts;
        var result = new List<Point>((int)(4 * width));
        var i = 0;
        while (i < pts.Count)
        {
            var col = Math.Floor(pts[i].X);
            int first = i, low = i, high = i;
            while (i < pts.Count && Math.Floor(pts[i].X) == col)
            {
                if (pts[i].Y < pts[high].Y) high = i;   // Bildschirm-Y: klein = oben
                if (pts[i].Y > pts[low].Y) low = i;
                i++;
            }
            var last = i - 1;
            foreach (var k in new[] { first, low, high, last }.Distinct().OrderBy(k => k)) result.Add(pts[k]);
        }
        return result;
    }

    /// Zusammenhängende Läufe einer Reihe; ein Abstand über `GapThreshold` trennt (dazwischen liegt eine Lücke).
    IEnumerable<List<(double T, double V)>> Runs(Func<Sample, double?> get)
    {
        var limit = GapThreshold;
        var run = new List<(double, double)>();
        double? last = null;
        foreach (var s in samples)
        {
            if (get(s) is not { } v) continue;
            if (last.HasValue && s.T - last.Value > limit && run.Count > 0) { yield return run; run = new(); }
            run.Add((s.T, v));
            last = s.T;
        }
        if (run.Count > 0) yield return run;
    }

    // Wertanzeige unter der Maus

    void Canvas_MouseMove(object sender, MouseEventArgs e)
    {
        hoverCanvas = (Canvas)sender;
        hoverX = e.GetPosition(hoverCanvas).X;
        DrawHover();
    }

    void Canvas_MouseLeave(object sender, MouseEventArgs e)
    {
        hoverX = null;
        DrawHover();
    }

    void HideHover()
    {
        foreach (var l in hoverLines.Values) l.Visibility = Visibility.Collapsed;
        hoverLabel.Visibility = hoverDot.Visibility = Visibility.Collapsed;
    }

    /// Senkrechte Linie zur selben Zeit in allen Graphen, Punkt und großer Wert mit Uhrzeit im Graphen unter der Maus
    /// (nächster Punkt). Die Elemente gibt es nur einmal; hier werden sie nur verschoben, beschriftet und ein- oder
    /// ausgeblendet. Außen zeigt den gemessenen Wert, der Punkt sitzt auf der geglätteten Linie.
    void DrawHover()
    {
        if (hoverX is not { } x || hoverCanvas is not { } hc || !drawn.TryGetValue(hc, out var d)) { HideHover(); return; }
        Func<Sample, double?> get = hc == PowerCanvas ? s => s.Power : hc == TempCanvas ? s => s.Indoor : s => s.OutdoorSmooth;
        var t = TimeAt(x, hc.ActualWidth);
        Sample? best = null;
        var bestDist = double.MaxValue;
        foreach (var p in samples)
            if (get(p).HasValue && Math.Abs(p.T - t) < bestDist) { best = p; bestDist = Math.Abs(p.T - t); }
        if (best is not { } s || get(s) is not { } v) { HideHover(); return; }

        foreach (var (c, l) in hoverLines)
        {
            if (!drawn.TryGetValue(c, out var dc)) { l.Visibility = Visibility.Collapsed; continue; }
            l.X1 = l.X2 = X(s.T, c.ActualWidth);
            l.Y1 = Pad;
            l.Y2 = c.ActualHeight - dc.Bottom;
            l.Visibility = Visibility.Visible;
        }
        var px = X(s.T, hc.ActualWidth);
        string value;
        Color color;
        var extra = new List<string>();
        if (hc == PowerCanvas) { value = Fmt.Watts(v); color = LineColor; }
        else if (hc == TempCanvas)
        {
            // Großer Wert mit Einheit („21,5 °C“); darunter „Soll 22°“ und mit Außen im Graphen „Außen 8,5°“.
            value = Fmt.Temp(v).Replace("°", " °C");
            color = LineColor;
            if (TargetOf(s) is { } target) extra.Add(L.F("charts.hoverTarget", ("target", Fmt.Target(target))));
            if (combined && s.Outdoor is { } o) extra.Add(L.F("charts.hoverOutdoor", ("outdoor", Fmt.Temp(o))));
        }
        else
        {
            value = Fmt.Temp(s.Outdoor ?? v).Replace("°", " °C");
            color = OutdoorColor;
        }
        hoverValue.Text = value;
        hoverWhen.Text = When(s.T);
        hoverExtra.Text = string.Join("\n", extra);
        hoverExtra.Visibility = extra.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (FrameworkElement el in new FrameworkElement[] { hoverLabel, hoverDot })
            if (el.Parent != hc)
            {
                (el.Parent as Panel)?.Children.Remove(el);
                hc.Children.Add(el);
            }
        hoverDot.Fill = Paints.Of(color);
        Canvas.SetLeft(hoverDot, px - hoverDot.Width / 2);
        Canvas.SetTop(hoverDot, Y(v, d.Shown, hc.ActualHeight, d.Bottom) - hoverDot.Height / 2);
        hoverDot.Visibility = Visibility.Visible;
        hoverLabel.Visibility = Visibility.Visible;
        hoverLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(hoverLabel, Math.Clamp(px - hoverLabel.DesiredSize.Width / 2, 0, Math.Max(0, hc.ActualWidth - hoverLabel.DesiredSize.Width)));
        Canvas.SetTop(hoverLabel, 2);
    }
}

/// Zeichenfläche eines Graphen: für die Sprachausgabe ein einziges Bild mit Namen und Zusammenfassung (HelpText) statt
/// hunderter Beschriftungen und Pfade.
public sealed class ChartCanvas : Canvas
{
    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    sealed class Peer(ChartCanvas owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;
        protected override string GetClassNameCore() => nameof(ChartCanvas);
        protected override List<AutomationPeer>? GetChildrenCore() => null;
    }
}
