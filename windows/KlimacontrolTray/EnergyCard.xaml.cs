using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Verbrauch je Tag, Woche oder Monat unter den Graphen (kc_energy_json). Arten, Anzahlen und alle Texte kommen aus
/// `Options.Energy` und der Antwort des Kerns. Gelesen wird beim Sichtbarwerden, bei anderer Art und sonst höchstens
/// alle 10 Minuten, nie je Schnappschuss.
public partial class EnergyCard : UserControl
{
    const string KindPref = "EnergyKind";
    static readonly TimeSpan MaxAge = TimeSpan.FromMinutes(10);

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
    }

    public void Detach()
    {
        timer.Stop();
        Core.Shared.Changed -= CoreChanged;
        Theme.Changed -= Redraw;
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

    void Redraw()
    {
        Bars.Children.Clear();
        Bars.ColumnDefinitions.Clear();
        var periods = result is { Error: null } r ? r.Periods : new();
        var max = periods.Max(p => p.Shown) ?? 0;
        var any = periods.Any(p => p.Shown.HasValue);
        Bars.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        NoDataText.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        NoDataText.Text = Options.NoData;
        SummaryText.Text = any ? result!.Summary : "";
        SummaryText.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        LegendText.Text = any ? Options.Legend : "";
        LegendText.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        if (!any) return;

        var color = Paints.Of(Theme.Series(ChartsPanel.OutdoorBase));
        // Bei vielen Balken nur jede zweite Beschriftung (die letzte bleibt).
        var step = periods.Count > 8 ? 2 : 1;
        for (var i = 0; i < periods.Count; i++)
        {
            var p = periods[i];
            Bars.ColumnDefinitions.Add(new ColumnDefinition());
            var value = p.Shown ?? 0;
            var col = new Grid { Margin = new Thickness(2, 0, 2, 0), Background = Brushes.Transparent, ToolTip = p.Tooltip };
            AutomationProperties.SetName(col, p.Tooltip);
            // Oben Platz für die Kennzeichnung, darunter der Balken im Verhältnis zum größten Wert.
            col.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Math.Max(max * 1.2 - value, 0.0001), GridUnitType.Star) });
            col.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Math.Max(value, 0), GridUnitType.Star) });
            col.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var bar = new Border { Background = color, CornerRadius = new CornerRadius(2, 2, 0, 0), Opacity = BarOpacity(p), MinHeight = value > 0 ? 2 : 0 };
            Grid.SetRow(bar, 1);
            col.Children.Add(bar);
            if (Marker(p) is { } marker)
            {
                marker.VerticalAlignment = VerticalAlignment.Bottom;
                marker.HorizontalAlignment = HorizontalAlignment.Center;
                col.Children.Add(marker);
            }
            var label = new TextBlock
            {
                Text = (i + periods.Count - 1) % step == 0 ? p.Label : "", FontSize = 11, TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0),
            };
            label.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
            Grid.SetRow(label, 2);
            col.Children.Add(label);
            Grid.SetColumn(col, i);
            Bars.Children.Add(col);
        }
    }

    /// Nicht nur über die Farbe erkennbar: zusätzlich ein Zeichen über dem Balken (`Marker`).
    static double BarOpacity(EnergyPeriod p) => p.Current ? 0.4 : p.KWh == null ? 0.5 : p.Complete ? 1 : 0.7;

    static FrameworkElement? Marker(EnergyPeriod p)
    {
        FrameworkElement? m = null;
        if (p.Current) m = Icons.Glyph(((char)0xE121).ToString(), 11);
        else if (p.KWh == null) m = new TextBlock { Text = "ca.", FontSize = 11 };
        else if (!p.Complete) m = new TextBlock { Text = "…", FontSize = 11 };
        if (m is TextBlock t) t.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        return m;
    }
}
