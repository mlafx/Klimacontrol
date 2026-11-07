using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace KlimacontrolTray;

/// Verlauf aus dem HistoryStore des Kerns (kc_history_json): Leistung, Temperatur (Raum + Soll) und – nur mit
/// Außenwerten – Außentemperatur, mit gemeinsamer Zeitachse. Lücken werden als gerade, blasse Brücke gezeichnet.
///
/// Sparsam fürs Software-Zeichnen: neu geladen nur bei anderem Zeitraum, neuem Zeitfenster des Kerns oder (1 h/6 h)
/// neuer `HistoryRevision`; neu gezeichnet nur bei neuen Daten, anderer Größe oder anderer Modusfarbe. Je Reihe
/// höchstens vier Pfade mit eingefrorener Geometrie, bei langen Zeiträumen ausgedünnt.
public partial class ChartsPanel : UserControl
{
    // Neutrale Reihenfarben wie am Mac (Charts.swift, SeriesColors): Orange, Grün und Blau bezeichnen die Modi
    // Heizen, Trocknen und Kühlen. Raum = Vordergrund des Themas, Soll und Außen folgen dem Thema.
    static readonly Color TargetBase = Color.FromRgb(0xD9, 0x40, 0x8C);
    internal static readonly Color OutdoorBase = Color.FromRgb(0x80, 0x85, 0x8F);
    static Color IndoorColor => Theme.Foreground;
    static Color TargetColor => Theme.Series(TargetBase);
    static Color OutdoorColor => Theme.Series(OutdoorBase);
    /// Gewählter Zeitraum (Sekunden); gemerkt unter Prefs "ChartRange". Die Zeiträume, den Standard (bei unbekanntem
    /// gemerkten Wert), die Zahl der Zeitfenster und die Lückenregel gibt der Kern vor (`Options.Chart`); 0 = noch nicht bekannt.
    static double range;

    static ChartOptions Chart => Core.Shared.Snap.Options.Chart;
    static readonly DoubleCollection GridDash = Frozen(new DoubleCollection { 2, 3 }), StepDash = Frozen(new DoubleCollection { 3, 2 });
    static readonly CultureInfo De = CultureInfo.GetCultureInfo("de-DE");

    /// Deckkraft einer Lücke (Linie und Fläche).
    const double GapOpacity = 0.22;

    // Symbole, die Icons.cs nicht hat: Summenzeichen und Euro.
    const string SumIcon = "M12.5,2.5 H3.5 L8.5,8 L3.5,13.5 H12.5";
    const string EuroIcon = "M12.5,3.8 A5,5 0 1 0 12.5,12.2 M2,6.8 H9 M2,9.2 H9";

    const double Left = 8, Right = 44, Pad = 10, Bottom = 20;

    List<Sample> samples = new();
    double? hoverX;
    Canvas? hoverCanvas;
    /// Einmaliger Timer auf den nächsten Wechsel des Zeitfensters; nur aktiv, solange der Verlauf sichtbar ist.
    readonly System.Windows.Threading.DispatcherTimer reload = new();

    // Stand des letzten Ladens: Zeitraum, Zeitfenster, Verlaufsrevision des Kerns; dataVersion zählt jedes Laden.
    double loadedRange;
    long loadedBucket = long.MinValue;
    int loadedRevision = int.MinValue;
    int dataVersion;
    (double, double, int, Color) powerKey, tempKey, outdoorKey;
    Color powerTint;

    /// Gemeinsame Zeitachse aller Graphen (Unix-Sekunden), beim Laden festgehalten.
    double from, to = 1;
    /// Y-Skalen je Graph, beim Laden aus den Daten berechnet (`null` ohne Werte).
    Axis? powerAxis, tempAxis, outdoorAxis;
    /// Skala, mit der ein Graph zuletzt gezeichnet wurde – nur diese Graphen bekommen eine Wertanzeige.
    readonly Dictionary<Canvas, Axis> drawn = new();

    readonly TextBlock[] tileValues = new TextBlock[4];
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
        foreach (var (cc, icon, size) in new[] { (TitleIcon, Icons.Chart, 15.0), (PowerIcon, Icons.Bolt, 13.0), (TempIcon, Icons.Thermometer, 13.0), (OutdoorIcon, Icons.Sun, 13.0) })
        {
            cc.SetResourceReference(ForegroundProperty, "Sub");
            cc.Content = Icons.Make(icon, size);
        }
        EnsureRanges();
        // Kennzahlen einmal anlegen, danach nur die Werte setzen.
        tileValues[0] = Tile(Icons.Bolt, false, "Mittel");
        tileValues[1] = Tile(Icons.Bolt, true, "Spitze");
        tileValues[2] = Tile(SumIcon, false, "Verbrauch");
        tileValues[3] = Tile(EuroIcon, false, "Kosten");

        // Wertanzeige (Linie je Graph; Punkt und Kasten im Graphen unter der Maus) einmal anlegen; ZIndex hält sie
        // über den Graphen, auch wenn diese neu gezeichnet werden.
        foreach (var c in new[] { PowerCanvas, TempCanvas, OutdoorCanvas })
        {
            labelPool[c] = new List<TextBlock>();
            var l = new Line { StrokeThickness = 1, Opacity = 0.6, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
            l.SetResourceReference(Shape.StrokeProperty, "Sub");
            Panel.SetZIndex(l, 1);
            hoverLines[c] = l;
            c.Children.Add(l);
        }
        hoverDot = new Ellipse { Width = 9, Height = 9, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
        Panel.SetZIndex(hoverDot, 2);
        hoverValue = new TextBlock { FontSize = 16, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center };
        hoverWhen = new TextBlock { FontSize = 11, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
        hoverExtra = new TextBlock { FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center };
        hoverExtra.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        hoverLabel = new Border
        {
            Child = new StackPanel { Children = { hoverValue, hoverWhen, hoverExtra } },
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(8, 4, 8, 4),
            Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        };
        hoverLabel.SetResourceReference(Border.BackgroundProperty, "Card");
        hoverLabel.SetResourceReference(Border.BorderBrushProperty, "Line");
        Panel.SetZIndex(hoverLabel, 3);

        PowerCanvas.SizeChanged += (_, _) => { DrawPower(); DrawHover(); };
        TempCanvas.SizeChanged += (_, _) => { DrawTemp(); DrawHover(); };
        OutdoorCanvas.SizeChanged += (_, _) => { DrawOutdoor(); DrawHover(); };
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
                // Draw zeichnet nur, was sich geändert hat (z. B. Design gewechselt, solange ausgeblendet).
                if (NeedsReload()) Load(); else { Draw(); Arm(); }
            }
            else reload.Stop();
        };
        // Ein laufender Timer hielte ein geschlossenes Fenster im Speicher fest.
        Loaded += (_, _) =>
        {
            Core.Shared.Changed -= CoreChanged;
            Core.Shared.Changed += CoreChanged;
            Theme.Changed -= ThemeChanged;
            Theme.Changed += ThemeChanged;
            IndoorDot.Fill = Paints.Of(IndoorColor);
            TargetDot.Fill = Paints.Of(TargetColor);
            if (IsVisible) Arm();
        };
        Unloaded += (_, _) => Detach();
    }

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
            System.Windows.Automation.AutomationProperties.SetName(b, "Zeitraum " + r.Label);
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
        Energy.Detach();
        Core.Shared.Changed -= CoreChanged;
        Theme.Changed -= ThemeChanged;
    }

    /// Hell/Dunkel bzw. Hoher Kontrast gewechselt: der Rest folgt über Ressourcenverweise, die Graphen (eigene Pinsel,
    /// eingefrorene Geometrie) einmal neu zeichnen.
    void ThemeChanged()
    {
        powerKey = tempKey = outdoorKey = default;
        IndoorDot.Fill = Paints.Of(IndoorColor);
        TargetDot.Fill = Paints.Of(TargetColor);
        if (IsVisible) Draw();
    }

    /// Neuer Zustand vom Kern: neu laden nur bei neuem Verlaufspunkt (1 h/6 h), sonst höchstens eine neue Modusfarbe
    /// übernehmen (der Leistungsgraph ist in der Modusfarbe).
    void CoreChanged()
    {
        if (!IsVisible) return;
        if (NeedsReload()) Load();
        else if (samples.Count >= 2 && Tint() != powerTint) { DrawPower(); DrawHover(); }
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
        to = Codes.Epoch(DateTime.Now);
        from = to - range;
        powerAxis = PowerAxis(samples.Where(s => s.Power.HasValue).Select(s => s.Power!.Value));
        tempAxis = TempAxis(samples.SelectMany(s => new[] { s.Indoor, TargetOf(s) }).Where(v => v.HasValue).Select(v => v!.Value));
        outdoorAxis = TempAxis(samples.Where(s => s.Outdoor.HasValue).Select(s => s.Outdoor!.Value));
        RenderTiles();
        var enough = samples.Count >= 2;
        var outdoor = enough && outdoorAxis != null;
        EmptyText.Visibility = enough ? Visibility.Collapsed : Visibility.Visible;
        PowerCard.Visibility = TempCard.Visibility = enough ? Visibility.Visible : Visibility.Collapsed;
        OutdoorCard.Visibility = outdoor ? Visibility.Visible : Visibility.Collapsed;
        // Ohne Außenwerte nimmt die leere Zeile sonst ihren Anteil der freien Höhe weg.
        OutdoorRow.Height = outdoor ? new GridLength(2, GridUnitType.Star) : new GridLength(0);
        Draw();
        Arm();
    }

    /// Soll nur bei eingeschalteter Anlage (ausgeschaltet gibt es kein Ziel).
    static double? TargetOf(Sample s) => s.On ? s.Target : null;

    /// Kennzahlen aus dem Kern (alle gespeicherten Punkte, `HistoryStore.stats`). Die Graphenpunkte sind je Zeitfenster
    /// gemittelt – daraus berechnet wäre der Verbrauch über 7 Tage fast 0.
    void RenderTiles()
    {
        var s = Core.Shared.Stats(TimeSpan.FromSeconds(range));
        tileValues[0].Text = Fmt.Watts(s.AvgWatts);
        tileValues[1].Text = Fmt.Watts(s.PeakWatts);
        tileValues[2].Text = Fmt.Kwh(s.KWh);
        tileValues[3].Text = Fmt.Euro(s.KWh * Core.Shared.Snap.Price);
    }

    TextBlock Tile(string icon, bool filled, string title)
    {
        var path = Icons.Make(icon, 12, null, 1.3);
        if (filled) path.SetResourceReference(Shape.FillProperty, "Sub");
        var iconHost = new ContentControl { Content = path, HorizontalAlignment = HorizontalAlignment.Center, Focusable = false, IsTabStop = false };
        iconHost.SetResourceReference(ForegroundProperty, "Sub");
        var value = new TextBlock { FontSize = 14, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 3, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };
        var caption = new TextBlock { Text = title, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center };
        caption.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        var border = new Border { Child = new StackPanel { Children = { iconHost, value, caption } }, CornerRadius = new CornerRadius(8), Padding = new Thickness(4, 10, 4, 10), Margin = new Thickness(4, 0, 4, 0) };
        border.SetResourceReference(Border.BackgroundProperty, "Tile");
        Tiles.Children.Add(border);
        return value;
    }

    static Color Tint() => Core.Shared.Snap.State is { } st ? Theme.Accent(Codes.Tint(st.Mode)) : Color.FromRgb(0x00, 0x5F, 0xB8);

    void Draw()
    {
        DrawPower();
        DrawTemp();
        DrawOutdoor();
        DrawHover();
    }

    void DrawPower()
    {
        var tint = Tint();
        var key = (PowerCanvas.ActualWidth, PowerCanvas.ActualHeight, dataVersion, tint);
        if (key == powerKey) return;
        powerKey = key;
        powerTint = tint;
        DrawChart(PowerCanvas, powerAxis, new[] { new Series(tint, s => s.Power, false, 0x70, 0x0C) }, " W");
    }

    void DrawTemp()
    {
        var key = (TempCanvas.ActualWidth, TempCanvas.ActualHeight, dataVersion, default(Color));
        if (key == tempKey) return;
        tempKey = key;
        DrawChart(TempCanvas, tempAxis, new[]
        {
            new Series(TargetColor, TargetOf, true),
            new Series(IndoorColor, s => s.Indoor, false),
        }, "°");
    }

    void DrawOutdoor()
    {
        var key = (OutdoorCanvas.ActualWidth, OutdoorCanvas.ActualHeight, dataVersion, default(Color));
        if (key == outdoorKey) return;
        outdoorKey = key;
        DrawChart(OutdoorCanvas, outdoorAxis, new[] { new Series(OutdoorColor, s => s.Outdoor, false, 0x4D, 0x08) }, "°");
    }

    /// Eine Reihe: Farbe, Wert je Punkt, Stufen (Soll) und – mit `AreaTop` > 0 – Fläche mit Verlauf darunter
    /// (Deckkraft oben/unten als Alpha 0…255).
    record Series(Color Color, Func<Sample, double?> Get, bool Step, byte AreaTop = 0, byte AreaBottom = 0);

    /// Y-Skala: Bereich `Min…Max`, Gitterlinien ab `First` im Abstand `Step`.
    record Axis(double Min, double Max, double First, double Step);

    /// Leistung: ab 0, nach oben auf einen runden Schritt aufgerundet (etwa drei Abschnitte).
    static Axis? PowerAxis(IEnumerable<double> values)
    {
        double? hi = null;
        foreach (var v in values) hi = hi is { } h ? Math.Max(h, v) : v;
        if (hi is not { } max) return null;
        max = Math.Max(max, 1);
        var step = Math.Max(1, NiceStep(max / 3));
        return new Axis(0, Math.Ceiling(max / step) * step, 0, step);
    }

    /// Temperatur: Min−1…Max+1, mindestens 4° breit (bei einem einzigen Wert ±2°).
    /// Gitter auf ganzen Graden, höchstens fünf Abschnitte.
    static Axis? TempAxis(IEnumerable<double> values)
    {
        double? lo0 = null, hi0 = null;
        foreach (var v in values) { lo0 = lo0 is { } a ? Math.Min(a, v) : v; hi0 = hi0 is { } b ? Math.Max(b, v) : v; }
        if (lo0 is not { } min || hi0 is not { } max) return null;
        double lo = min - 1, hi = max + 1;
        if (hi - lo < 4)
        {
            var mid = (lo + hi) / 2;
            (lo, hi) = (mid - 2, mid + 2);
        }
        var step = 1.0;
        for (var mag = 1.0; ; mag *= 10)
        {
            var found = false;
            foreach (var n in new[] { 1.0, 2.0, 5.0 })
                if ((hi - lo) / (n * mag) <= 5) { step = n * mag; found = true; break; }
            if (found) break;
        }
        return new Axis(lo, hi, Math.Ceiling(lo / step) * step, step);
    }

    double X(double t, double w) => Left + (t - from) / (to - from) * (w - Left - Right);
    double TimeAt(double x, double w) => from + (x - Left) / (w - Left - Right) * (to - from);
    static double Y(double v, Axis a, double h) => Pad + (1 - (v - a.Min) / (a.Max - a.Min)) * (h - Pad - Bottom);

    void DrawChart(Canvas c, Axis? axis, Series[] series, string unit)
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
        if (samples.Count < 2 || axis is not { } a || w < 40 || h < 40) return;
        drawn[c] = a;

        // Gitter: waagerechte Linien durchgezogen, senkrechte gestrichelt – je ein Pfad.
        var labels = labelPool[c];
        var used = 0;
        TextBlock Label(string text, double x, double y)
        {
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
        var horizontal = new StreamGeometry();
        using (var ctx = horizontal.Open())
            for (var v = a.First; v <= a.Max + a.Step / 1000; v += a.Step)
            {
                var y = Y(v, a, h);
                ctx.BeginFigure(new Point(Left, y), false, false);
                ctx.LineTo(new Point(w - Right, y), true, false);
                // Leistung: Einheit nur an der obersten Linie; Temperatur: „22°“ an jeder.
                var text = Fmt.Num(v, 0) + (unit == "°" || v + a.Step > a.Max + a.Step / 1000 ? unit : "");
                c.Children.Add(Label(text, w - Right + 6, y - 8));
            }
        horizontal.Freeze();
        c.Children.Add(GridPath(horizontal, null));
        // Zeitachse: drei Marken mit Uhrzeit (bei mehr als 24 h mit Tag).
        var vertical = new StreamGeometry();
        using (var ctx = vertical.Open())
            for (var i = 1; i <= 3; i++)
            {
                var t = from + (to - from) * i / 4;
                var x = X(t, w);
                ctx.BeginFigure(new Point(x, Pad), false, false);
                ctx.LineTo(new Point(x, h - Bottom), true, false);
                c.Children.Add(Label(Codes.Local(t).ToString(range > 86400 ? "ddd HH:mm" : "HH:mm", De), x - 18, h - Bottom + 4));
            }
        vertical.Freeze();
        c.Children.Add(GridPath(vertical, GridDash));

        var baseY = Y(a.Min, a, h);
        foreach (var se in series)
        {
            var area = se.AreaTop > 0 ? new StreamGeometry() : null;
            var gapArea = se.AreaTop > 0 ? new StreamGeometry() : null;
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
                    var first = new Point(X(run[0].T, w), Y(run[0].V, a, h));
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
                    var pts = Thin(run.Select(q => new Point(X(q.T, w), Y(q.V, a, h))).ToList(), w);
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
                        // Fläche unter der Linie bis zur Grundlinie, eine Figur je Lauf.
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
                c.Children.Add(new Path { Data = area, Fill = AreaFill(se.Color, se.AreaTop, se.AreaBottom) });
            }
            if (gapArea != null && gaps > 0)
            {
                gapArea.Freeze();
                c.Children.Add(new Path { Data = gapArea, Fill = AreaFill(se.Color, se.AreaTop, se.AreaBottom), Opacity = GapOpacity });
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
        var p = new Path { Data = g, Stroke = Paints.Of(se.Color), StrokeThickness = 1.8, StrokeLineJoin = PenLineJoin.Round, IsHitTestVisible = false };
        if (se.Step) p.StrokeDashArray = StepDash;
        if (opacity < 1) p.Opacity = opacity;
        return p;
    }

    static readonly Dictionary<(Color, byte, byte), Brush> areaFills = new();

    /// Verlauf von kräftig (oben) nach fast durchsichtig (unten), eingefroren und je Farbe nur einmal.
    static Brush AreaFill(Color c, byte top, byte bottom)
    {
        if (!areaFills.TryGetValue((c, top, bottom), out var b))
        {
            b = new LinearGradientBrush(Color.FromArgb(top, c.R, c.G, c.B), Color.FromArgb(bottom, c.R, c.G, c.B), 90);
            b.Freeze();
            areaFills[(c, top, bottom)] = b;
        }
        return b;
    }

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

    static double NiceStep(double raw)
    {
        if (raw <= 0) return 1;
        var mag = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        var n = raw / mag;
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag;
    }

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

    /// Senkrechte Linie in allen Graphen, Punkt und großer Wert mit Uhrzeit im Graphen unter der Maus (nächster Punkt).
    /// Die Elemente gibt es nur einmal; hier werden sie nur verschoben, beschriftet und ein- oder ausgeblendet.
    void DrawHover()
    {
        if (hoverX is not { } x || hoverCanvas is not { } hc || !drawn.TryGetValue(hc, out var axis)) { HideHover(); return; }
        Func<Sample, double?> get = hc == PowerCanvas ? s => s.Power : hc == TempCanvas ? s => s.Indoor : s => s.Outdoor;
        var t = TimeAt(x, hc.ActualWidth);
        Sample? best = null;
        var bestDist = double.MaxValue;
        foreach (var p in samples)
            if (get(p).HasValue && Math.Abs(p.T - t) < bestDist) { best = p; bestDist = Math.Abs(p.T - t); }
        if (best is not { } s || get(s) is not { } v) { HideHover(); return; }

        foreach (var (c, l) in hoverLines)
        {
            if (!drawn.ContainsKey(c)) { l.Visibility = Visibility.Collapsed; continue; }
            l.X1 = l.X2 = X(s.T, c.ActualWidth);
            l.Y1 = Pad;
            l.Y2 = c.ActualHeight - Bottom;
            l.Visibility = Visibility.Visible;
        }
        var px = X(s.T, hc.ActualWidth);
        string value;
        Color color;
        string extra = "";
        if (hc == PowerCanvas) { value = Fmt.Watts(v); color = powerTint; }
        else
        {
            // Großer Wert mit Einheit („21,5 °C“); im Temperaturgraph darunter „Soll 22°“.
            value = Fmt.Temp(v).Replace("°", " °C");
            color = hc == TempCanvas ? IndoorColor : OutdoorColor;
            if (hc == TempCanvas && TargetOf(s) is { } target) extra = "Soll " + Fmt.Target(target);
        }
        hoverValue.Text = value;
        hoverWhen.Text = Codes.Local(s.T).ToString(range > 86400 ? "ddd HH:mm" : "HH:mm", De);
        hoverExtra.Text = extra;
        hoverExtra.Visibility = extra.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (FrameworkElement el in new FrameworkElement[] { hoverLabel, hoverDot })
            if (el.Parent != hc)
            {
                (el.Parent as Panel)?.Children.Remove(el);
                hc.Children.Add(el);
            }
        hoverDot.Fill = Paints.Of(color);
        Canvas.SetLeft(hoverDot, px - hoverDot.Width / 2);
        Canvas.SetTop(hoverDot, Y(v, axis, hc.ActualHeight) - hoverDot.Height / 2);
        hoverDot.Visibility = Visibility.Visible;
        hoverLabel.Visibility = Visibility.Visible;
        hoverLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(hoverLabel, Math.Clamp(px - hoverLabel.DesiredSize.Width / 2, 0, Math.Max(0, hc.ActualWidth - hoverLabel.DesiredSize.Width)));
        Canvas.SetTop(hoverLabel, 2);
    }
}
