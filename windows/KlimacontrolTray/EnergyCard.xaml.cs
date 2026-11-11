using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Verbrauch je Tag, Woche oder Monat unter den Graphen (kc_energy_json), aufgebaut wie `EnergyBars` am Mac: Wert über
/// den Balken, gestrichelter Durchschnitt, Achse rechts. Arten, Anzahlen und alle Texte kommen aus `Options.Energy` und
/// der Antwort des Kerns. Gelesen wird beim Sichtbarwerden, bei anderer Art und sonst höchstens alle 10 Minuten, nie je
/// Schnappschuss.
public partial class EnergyCard : UserControl
{
    const string KindPref = "EnergyKind";
    static readonly TimeSpan MaxAge = TimeSpan.FromMinutes(10);
    const double LabelFontSize = 11, ValueFontSize = 10;
    /// Abstände in der Zeichenfläche: Beschriftung unter den Balken, Achsentext rechts, Wert über dem Balken, kleinster
    /// Abstand zweier Beschriftungen.
    const double LabelTop = 4, AxisGap = 6, ValueGap = 2, MinLabelSpace = 4;
    /// Segoe UI 11 misst 4,9–6,0 je Zeichen bei Tagen und Monaten („Mi 30.12.“, „Wed 12/30“, „Sept. 2026“), 6,1–6,4
    /// bei den kurzen Wochen („KW 45“); der Abstand fängt den Rest und den Rand der Spalten auf. Bei „Groß“ mal
    /// `Theme.SizeFactor`.
    internal const double LabelCharWidth = 6.0, LabelGap = 10;
    /// Neutrales Grau der Balken (Farbe steht nur für den Modus), wie die Außentemperatur im Verlauf.
    static readonly Color BarBase = Color.FromRgb(0x80, 0x85, 0x8F);

    readonly DispatcherTimer timer = new() { Interval = MaxAge };
    EnergyResult? result;
    string kind = "";
    DateTime loadedAt = DateTime.MinValue;
    bool kindsBuilt, updatingKind;

    static EnergyOptions Options => Core.Shared.Snap.Options.Energy;

    public EnergyCard()
    {
        InitializeComponent();
        TitleIcon.SetResourceReference(ForegroundProperty, "Sub");
        TitleIcon.Content = Icons.Make(Icons.Chart, 13);
        timer.Tick += (_, _) => { if (IsVisible) Load(); };
        IsVisibleChanged += (_, _) => { if (IsVisible) Refresh(); else timer.Stop(); };
        Loaded += (_, _) =>
        {
            Core.Shared.Changed -= CoreChanged;
            Core.Shared.Changed += CoreChanged;
            Theme.Changed -= Redraw;
            Theme.Changed += Redraw;
            if (IsVisible) Refresh();
        };
        Unloaded += (_, _) => Detach();
        Plot.SizeChanged += (_, _) => Draw();
    }

    public void Detach()
    {
        timer.Stop();
        Core.Shared.Changed -= CoreChanged;
        Theme.Changed -= Redraw;
    }

    /// Höhe der Zeichenfläche (Balken samt Beschriftungen); die Graphen-Spalte darf sie nach ihren Regeln setzen.
    public double PlotHeight
    {
        get => Plot.Height;
        set { if (value > 0 && value != Plot.Height) Plot.Height = value; }
    }

    /// Erst wenn der Kern die Arten kennt (erster Schnappschuss); danach nicht mehr je Änderung.
    void CoreChanged()
    {
        if (!kindsBuilt && IsVisible) Refresh();
    }

    void Refresh()
    {
        if (!EnsureKinds()) return;
        if (result == null || DateTime.UtcNow - loadedAt >= MaxAge) Load(); else timer.Start();
    }

    bool EnsureKinds()
    {
        if (kindsBuilt) return true;
        var o = Options;
        if (o.Kinds.Count == 0) return false;
        TitleText.Text = o.Title;
        TitleHost.ToolTip = o.Help;
        AutomationProperties.SetName(KindPanel, o.Title);
        var saved = Prefs.Get(KindPref);
        kind = o.Kinds.Any(k => k.Id == saved) ? saved! : o.DefaultKind;
        var look = TryFindResource(typeof(ToggleButton)) as Style;
        foreach (var k in o.Kinds)
        {
            var id = k.Id;
            var b = new RadioButton { Content = k.Label, Tag = id, FontSize = 12, Padding = new Thickness(7, 3, 7, 3), Margin = new Thickness(2, 0, 0, 0) };
            if (look != null) b.Style = look;
            AutomationProperties.SetName(b, o.Title + " " + k.Label);
            b.Checked += (_, _) =>
            {
                if (updatingKind || kind == id) return;
                kind = id;
                Prefs.Set(KindPref, id);
                Load();
            };
            KindPanel.Children.Add(b);
        }
        kindsBuilt = true;
        ShowKind();
        return true;
    }

    void ShowKind()
    {
        updatingKind = true;
        try { foreach (RadioButton b in KindPanel.Children) b.IsChecked = (string)b.Tag == kind; }
        finally { updatingKind = false; }
    }

    void Load()
    {
        if (!kindsBuilt) return;
        var count = Options.Kinds.FirstOrDefault(k => k.Id == kind)?.Count ?? 0;
        ShowKind();
        result = count > 0 ? Core.Shared.Energy(kind, count) : null;
        loadedAt = DateTime.UtcNow;
        timer.Stop();
        timer.Start();
        Redraw();
    }

    List<EnergyPeriod> Periods => result is { Error: null } r ? r.Periods : new();

    void Redraw()
    {
        var any = Periods.Any(p => p.Shown.HasValue);
        Plot.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        NoDataText.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        NoDataText.Text = Options.NoData;
        Footer.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        SummaryText.Text = any ? result!.Summary : "";
        var average = any ? result!.AverageText : null;
        AverageText.Text = average ?? "";
        AverageLegend.Visibility = string.IsNullOrEmpty(average) ? Visibility.Collapsed : Visibility.Visible;
        LegendText.Text = any ? Options.Legend : "";
        LegendText.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        var f = Theme.SizeFactor;
        foreach (var part in new DependencyObject[] { TitleHost, KindPanel, NoDataText, Footer, LegendText })
            SizeScale.Apply(part, f);
        Draw();
    }

    /// Zeichnet die Balken neu (nach neuen Daten, Thema oder Größe). Höchstens 60 Balken, darum jedes Mal frisch.
    void Draw()
    {
        Plot.Children.Clear();
        var periods = Periods;
        double w = Plot.ActualWidth, h = Plot.ActualHeight;
        if (!periods.Any(p => p.Shown.HasValue) || w < 60 || h < 60) return;

        var f = Theme.SizeFactor;
        double labelFont = Math.Round(LabelFontSize * f * 2) / 2, valueFont = Math.Round(ValueFontSize * f * 2) / 2;
        var n = periods.Count;
        var withValues = periods.Any(p => p.ValueText != null);
        var withMarker = periods.Any(p => p.Current || p.KWh == null || !p.Complete);

        // Unten die Beschriftungen, rechts die Achse, oben Zeichen und Wert: Höhen gemessen, damit „Groß“ mitwächst.
        var plotHeight = h - Measure(Text("Ag", labelFont, "Sub")).Height - LabelTop;
        var lines = (withValues ? 1 : 0) + (withMarker ? 1 : 0);
        var textHeight = lines == 0 ? 0 : lines * Measure(Text("0", valueFont, "Sub")).Height + ValueGap;
        var fraction = EnergyMath.HeadroomFraction(withValues, textHeight, plotHeight);
        var average = result?.Average;
        if (plotHeight < 30 || EnergyMath.BarAxis(periods.Select(p => p.Shown ?? 0), average, fraction) is not { } axis) return;

        var ticks = EnergyMath.Ticks(axis);
        var tickLabels = ticks.Select((v, i) => Text(Fmt.Num(v, 0) + (i == ticks.Count - 1 ? " kWh" : ""), labelFont, "Sub")).ToList();
        var axisWidth = tickLabels.Count == 0 ? 0 : tickLabels.Max(t => Measure(t).Width) + AxisGap;
        var plotWidth = w - axisWidth;
        if (plotWidth < 40) return;
        double Y(double v) => EnergyMath.Y(v, axis, 0, plotHeight);

        var grid = new StreamGeometry();
        using (var ctx = grid.Open())
            for (var i = 0; i < ticks.Count; i++)
            {
                var y = Math.Round(Y(ticks[i])) + 0.5;
                ctx.BeginFigure(new Point(0, y), false, false);
                ctx.LineTo(new Point(plotWidth, y), true, false);
                var size = Measure(tickLabels[i]);
                Place(tickLabels[i], plotWidth + AxisGap, Math.Clamp(y - size.Height / 2, 0, Math.Max(0, plotHeight - size.Height)));
            }
        grid.Freeze();
        var gridPath = new Path { Data = grid, StrokeThickness = 1, IsHitTestVisible = false };
        gridPath.SetResourceReference(Shape.StrokeProperty, "Line");
        Plot.Children.Insert(0, gridPath);

        var color = Paints.Of(Theme.Series(BarBase));
        var barWidth = EnergyMath.BarWidth(plotWidth, n, Core.Shared.Snap.Options.Window.EnergyBarMaxWidth);
        var corner = Math.Min(3, barWidth / 4);
        var baseY = Y(axis.Min);
        for (var i = 0; i < n; i++)
        {
            var p = periods[i];
            var cx = EnergyMath.BarCenter(i, n, plotWidth);
            var value = p.Shown ?? 0;
            var top = value > 0 ? Math.Min(Y(value), baseY - 2) : baseY;
            if (value > 0)
                Place(new Border
                {
                    Background = color, Opacity = BarOpacity(p), Width = barWidth, Height = baseY - top,
                    CornerRadius = new CornerRadius(corner, corner, 0, 0), IsHitTestVisible = false,
                }, cx - barWidth / 2, top);
            if (Above(p, valueFont) is { } above)
            {
                var size = Measure(above);
                Place(above, EnergyMath.LabelLeft(cx, size.Width, plotWidth), Math.Max(0, top - size.Height - ValueGap));
            }
        }

        if (average is { } avg && double.IsFinite(avg))
        {
            var y = Math.Round(Y(avg)) + 0.5;
            var line = new Line
            {
                X1 = 0, X2 = plotWidth, Y1 = y, Y2 = y, StrokeThickness = 1, Opacity = 0.6, IsHitTestVisible = false,
                StrokeDashArray = new DoubleCollection { 4, 3 },
            };
            line.SetResourceReference(Shape.StrokeProperty, "Fg");
            Plot.Children.Add(line);
        }

        DrawLabels(periods, plotWidth, plotHeight, labelFont, f);

        // Je Balken eine unsichtbare Fläche über die ganze Höhe: Kurzinfo und Name für die Sprachausgabe (Zeitraum und Wert).
        var slot = plotWidth / n;
        for (var i = 0; i < n; i++)
        {
            var hit = new TextBlock { Width = slot, Height = h, Background = Brushes.Transparent, ToolTip = periods[i].Tooltip };
            AutomationProperties.SetName(hit, periods[i].Tooltip);
            Place(hit, i * slot, 0);
        }
    }

    /// Beschriftungen unter den Balken nach `ChartMath.LabelStep`; die letzte bleibt stehen. Am Rand werden sie in die
    /// Fläche geschoben statt abgeschnitten; überdeckte eine dann die rechts daneben, entfällt sie.
    void DrawLabels(List<EnergyPeriod> periods, double plotWidth, double plotHeight, double labelFont, double f)
    {
        var n = periods.Count;
        var length = periods.Max(p => p.Label.Length);
        var step = ChartMath.LabelStep(n, plotWidth, length, LabelCharWidth * f, LabelGap * f);
        var nextLeft = double.PositiveInfinity;
        for (var i = n - 1; i >= 0; i--)
        {
            if (!ChartMath.ShowsLabel(i, n, step) || periods[i].Label.Length == 0) continue;
            var t = Text(periods[i].Label, labelFont, "Sub");
            var size = Measure(t);
            var left = EnergyMath.LabelLeft(EnergyMath.BarCenter(i, n, plotWidth), size.Width, plotWidth);
            if (left + size.Width > nextLeft - MinLabelSpace) continue;
            Place(t, left, plotHeight + LabelTop);
            nextLeft = left;
        }
    }

    /// Zeichen (läuft noch, ca., Lücke) und Wert über dem Balken; null, wenn es nichts zu zeigen gibt.
    static StackPanel? Above(EnergyPeriod p, double size)
    {
        var stack = new StackPanel { IsHitTestVisible = false };
        if (Marker(p, size) is { } marker)
        {
            marker.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(marker);
        }
        if (p.ValueText is { Length: > 0 } v)
        {
            var t = Text(v, size, "Fg");
            t.Opacity = 0.75;
            t.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(t);
        }
        return stack.Children.Count == 0 ? null : stack;
    }

    /// Schon in der Schriftgröße nach „Größe“ angelegt; `SizeScale.Own`, damit nichts doppelt vergrößert.
    static TextBlock Text(string text, double size, string brush)
    {
        var t = new TextBlock { Text = text, FontSize = size, IsHitTestVisible = false };
        t.SetResourceReference(TextBlock.ForegroundProperty, brush);
        SizeScale.Own(t);
        return t;
    }

    static Size Measure(UIElement e)
    {
        e.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return e.DesiredSize;
    }

    void Place(UIElement e, double left, double top)
    {
        Canvas.SetLeft(e, left);
        Canvas.SetTop(e, top);
        Plot.Children.Add(e);
    }

    /// Nicht nur über die Farbe erkennbar: zusätzlich ein Zeichen über dem Balken (`Marker`).
    static double BarOpacity(EnergyPeriod p) => p.Current ? 0.4 : p.KWh == null ? 0.5 : p.Complete ? 1 : 0.7;

    static FrameworkElement? Marker(EnergyPeriod p, double size)
    {
        if (p.Current)
        {
            var glyph = Icons.Glyph(((char)0xE121).ToString(), size);
            glyph.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
            SizeScale.Own(glyph);
            return glyph;
        }
        if (p.KWh == null) return Text(L.T("charts.approxMarker"), size, "Sub");
        if (!p.Complete) return Text("…", size, "Sub");
        return null;
    }
}
