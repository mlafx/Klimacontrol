using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Lüfter: Regler mit Zonen „Außengerät leise“ und Turbo, Marken, Auto.
public partial class ControlPanel
{
    /// Zonen schmal (je ~6 % der Spur): links von 1 % gestrichelt bis „Außengerät leise“, rechts von 100 % bis „Turbo“.
    const double QuietMin = -6, TurboMax = 107;

    readonly List<Button> fanMarkLabels = new();
    readonly Button quietZone = new(), turboZone = new();
    readonly Path quietIcon = Icons.Make(Icons.Mute, 12, null, 1.3), turboIcon = Icons.Make(Icons.Bolt, 12, null, 1.3);
    /// Spur aus fünf Linien, einmal angelegt: fest (Rest), fest (bis zum Knopf), zwei gestrichelte Zonen.
    readonly Line trackRest = TrackLine(4), trackFill = TrackLine(4), trackQuiet = TrackLine(2.5, dashed: true), trackTurbo = TrackLine(2.5, dashed: true);

    /// Zustand des Reglers, wie ihn der letzte Render gesetzt hat.
    bool zones, fanQuiet, fanTurboOn, fanAuto;
    int fanSpeed;
    Color fanTint = Codes.Tint(2);

    /// Zieh-Zustand. `ownsQuiet`: die Bedienung begann in „Außengerät leise“ oder war dort – nur dann schaltet sie es
    /// beim Verlassen ab (sonst bliebe ein per Kachel gesetztes „Außengerät leise“ bei 40 % stehen).
    bool fanInteracting, snapping, keyStep;
    bool? ownsQuiet;
    DateTime lastFanDrag;

    /// Abgleich nach dem Loslassen noch einmal nach Ablauf der 2-s-Sperre des Kerns (die kann den ersten verschlucken).
    readonly DispatcherTimer reconcileLater = new() { Interval = TimeSpan.FromSeconds(2.2) };
    (double Value, bool OwnsQuiet, DateTime At)? pendingReconcile;

    static Line TrackLine(double thickness, bool dashed = false)
    {
        var l = new Line { StrokeThickness = thickness, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
        if (dashed)
        {
            // Strich 3, Lücke 4 px: WPF misst StrokeDashArray in Vielfachen der Strichstärke.
            l.StrokeDashArray = new DoubleCollection { 3 / thickness, 4 / thickness };
            l.StrokeDashCap = PenLineCap.Round;
        }
        return l;
    }

    void BuildFan()
    {
        foreach (var l in new[] { trackRest, trackFill, trackQuiet, trackTurbo }) FanTrack.Children.Add(l);

        // Flache Knöpfe in der Reihenfolge von links nach rechts, damit Tab ihnen so folgt:
        // „Außengerät leise“, 1 % … Max, Turbo. Die Sprungmarken dazwischen legt `EnsureFanMarks` nach der Liste des Kerns an.
        var flat = (Style)FindResource("FlatMark");
        Zone(quietZone, quietIcon, flat, "Außengerät leise", "Außengerät leise: 1 % und leises Außengerät – nur beim Kühlen und Heizen", Cmd.FanQuiet);
        Zone(turboZone, turboIcon, flat, "Turbo", "Turbo: 100 % und Turbo – nur beim Kühlen und Heizen", Cmd.FanTurbo);

        FanMarks.SizeChanged += (_, _) => PlaceFanMarks();
        // Bedienung mit der Maus beginnt/endet; Ziehen am Knopf meldet DragCompleted, Klick auf die Spur nur MouseUp.
        FanSlider.PreviewMouseLeftButtonDown += (_, _) => BeginFanDrag();
        FanSlider.PreviewMouseLeftButtonUp += (_, _) => EndFanDrag();
        FanSlider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => EndFanDrag()));
        FanSlider.LostMouseCapture += (_, _) => { if (Mouse.LeftButton != MouseButtonState.Pressed) EndFanDrag(); };
        // Tastenschritt: der Regler verarbeitet die Taste gleich danach im selben Ereignis; danach zurücksetzen.
        FanSlider.PreviewKeyDown += (_, _) =>
        {
            keyStep = true;
            Dispatcher.BeginInvoke(() => keyStep = false, DispatcherPriority.Input);
        };
    }

    /// Sprungmarken (Beschriftung und Wert) nach der Liste des Kerns einmal anlegen, zwischen den beiden Zonen-Symbolen.
    void EnsureFanMarks(FanOptions fan)
    {
        if (fanMarkLabels.Count > 0 || fan.Marks.Count == 0) return;
        var flat = (Style)FindResource("FlatMark");
        var at = 1;
        foreach (var mark in fan.Marks)
        {
            var value = mark.Value;
            var t = new Button { Content = mark.Label, Tag = value, Style = flat };
            t.Click += (_, _) =>
            {
                if (!FanPanel.IsEnabled) return;
                CancelReconcile();
                Core.Send(Cmd.Fan, ("value", value), ("now", true));
            };
            AutomationProperties.SetName(t, "Lüfter " + mark.Label);
            fanMarkLabels.Add(t);
            FanMarks.Children.Insert(at++, t);
        }
        marksKey = default;
    }

    /// Zonen-Symbol ganz außen in der Markenzeile: aktiv in der Modusfarbe, sonst grau; der Name im Tooltip.
    void Zone(Button b, Path icon, Style flat, string name, string help, string cmd)
    {
        b.Style = flat;
        b.Width = 22;
        b.Padding = new Thickness(0);
        b.ToolTip = help;
        b.Content = icon;
        ToolTipService.SetShowOnDisabled(b, true);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(b, name);
        b.Click += (_, _) =>
        {
            if (!FanPanel.IsEnabled || !zones) return;
            CancelReconcile();
            Core.Send(cmd);
        };
        FanMarks.Children.Add(b);
    }

    void RenderFan(Snapshot s, AcState st, Color tint)
    {
        var tintBrush = Paints.Of(tint);
        EnsureFanMarks(s.Options.Fan);
        var locked = st.Mode == 3;
        zones = s.FanZonesAvailable;
        fanAuto = st.Fan == Codes.FanAuto;
        fanSpeed = st.Fan;
        fanQuiet = zones && !fanAuto && st.Fan == 1 && st.OutSilent == true;
        fanTurboOn = zones && !fanAuto && st.Fan == 100 && st.Turbo;
        fanTint = tint;

        FanPanel.IsEnabled = !locked;
        FanPanel.Opacity = locked ? 0.4 : 1;
        // Kopfzeile rechts („Mittel · 60 %“, „Turbo · 100 %“, beim Trocknen der feste Text) kommt fertig aus dem Kern.
        FanValue.Text = s.FanCaption;
        if (s.Options.Fan.AutoHelp.Length > 0 && !Equals(FanAuto.ToolTip, s.Options.Fan.AutoHelp)) FanAuto.ToolTip = s.Options.Fan.AutoHelp;
        FanAuto.IsChecked = fanAuto;
        Paint(FanAuto, fanAuto, !locked, tint);
        FanSlider.Foreground = tintBrush;
        FanSlider.Minimum = zones ? QuietMin : 1;
        FanSlider.Maximum = zones ? TurboMax : 100;
        FanSlider.Opacity = fanAuto ? 0.45 : 1;
        // Nach dem Ziehen zeigt der Knopf noch 1,5 s den gezogenen Wert, bis die Anlage geantwortet hat.
        if (!fanInteracting && (DateTime.Now - lastFanDrag).TotalSeconds > 1.5 && !FanSlider.IsMouseCaptureWithin)
            FanSlider.Value = fanAuto ? s.Options.Fan.AutoKnob : fanQuiet ? QuietMin : fanTurboOn ? TurboMax : Math.Clamp(st.Fan, 1, 100);
        else ResyncSoon();
        AutomationProperties.SetItemStatus(FanSlider, fanAuto ? "automatisch" : fanQuiet ? "Außengerät leise, 1 Prozent"
                                                      : fanTurboOn ? "Turbo, 100 Prozent" : $"{st.Fan} Prozent");

        // Erst die Schriftstärke der Marken, dann platzieren – die gewählte Marke ist breiter.
        var sub = (Brush)FindResource("Sub");
        // Schrift und Symbole in Modusfarbe im Hellen abgedunkelt, sonst ist z. B. „Max“ in Orange kaum lesbar.
        var textBrush = Paints.Of(Theme.TextTint(tint, 4.5));
        var iconBrush = Paints.Of(Theme.TextTint(tint, 3.0));
        foreach (var t in fanMarkLabels)
        {
            var sel = !fanAuto && !fanQuiet && !fanTurboOn && st.Fan == (int)t.Tag;
            t.Foreground = sel ? textBrush : sub;
            t.FontWeight = sel ? FontWeights.SemiBold : FontWeights.Normal;
            AutomationProperties.SetItemStatus(t, sel ? "aktiv" : "");
        }
        foreach (var (zone, icon, active) in new[] { (quietZone, quietIcon, fanQuiet), (turboZone, turboIcon, fanTurboOn) })
        {
            zone.Visibility = zones ? Visibility.Visible : Visibility.Collapsed;
            icon.Stroke = active ? iconBrush : sub;
            icon.StrokeThickness = active ? 1.8 : 1.3;
            AutomationProperties.SetItemStatus(zone, active ? "aktiv" : "");
        }
        DrawFanTrack();
        PlaceFanMarks();
    }

    double FanLo => zones ? QuietMin : 1;
    double FanHi => zones ? TurboMax : 100;

    /// Lage eines Reglerwerts in Pixeln (Knopfradius 10 px an beiden Enden, wie der Track rechnet).
    double FanX(double value, double width) => 10 + (width - 20) * (value - FanLo) / (FanHi - FanLo);

    /// Lage der Marken und der Spur zuletzt – nur bei Änderung neu setzen.
    (double, bool, int) marksKey;
    (double, double, bool, double, Color) trackKey;

    void PlaceFanMarks()
    {
        var width = FanMarks.ActualWidth;
        if (width <= 0) return;
        // Die gewählte Marke ist halbfett und damit breiter – darum zählt sie mit.
        var key = (width, zones, fanMarkLabels.FindIndex(t => t.FontWeight == FontWeights.SemiBold));
        if (key == marksKey) return;
        marksKey = key;
        foreach (var t in fanMarkLabels)
        {
            t.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var w = t.DesiredSize.Width;
            var pad = t.Padding.Left;
            var v = (int)t.Tag;
            // „1 %“ linksbündig am Anfang, „Max“ rechtsbündig am Ende der festen Spur, die übrigen mittig.
            var left = v == 1 ? FanX(1, width) - pad
                     : v == 100 ? FanX(100, width) + pad - w
                     : Math.Clamp(FanX(v, width) - w / 2, 0, Math.Max(0, width - w));
            Canvas.SetLeft(t, left);
            Canvas.SetTop(t, 0);
        }
        // Zonen-Symbole ganz außen, unter den gestrichelten Enden (Mitte 12 px vom Rand), 22 × 22 px.
        Canvas.SetLeft(quietZone, 12 - quietZone.Width / 2);
        Canvas.SetLeft(turboZone, width - 12 - turboZone.Width / 2);
        Canvas.SetTop(quietZone, 0);
        Canvas.SetTop(turboZone, 0);
    }

    /// Spur: fest von 1 bis 100 % in Linienfarbe, bis zum Knopf in der Modusfarbe; die Zonen gestrichelt
    /// und dünner, in der Modusfarbe, wenn der Knopf dort steht.
    void DrawFanTrack()
    {
        var w = FanSlider.ActualWidth;
        var h = FanSlider.ActualHeight;
        var key = (w, h, zones, FanSlider.Value, fanTint);
        if (key == trackKey) return;
        trackKey = key;
        if (w <= 0 || h <= 0) return;
        var y = h / 2;
        var tint = Paints.Of(fanTint);
        var rest = (Brush)FindResource("Line");
        var start = FanX(1, w);
        var end = FanX(100, w);
        var knob = FanX(FanSlider.Value, w);
        static void Set(Line l, double x1, double x2, double y, Brush b)
        {
            l.Visibility = x2 > x1 ? Visibility.Visible : Visibility.Collapsed;
            l.X1 = x1;
            l.X2 = Math.Max(x1, x2);
            l.Y1 = l.Y2 = y;
            l.Stroke = b;
        }
        Set(trackRest, start, end, y, rest);
        Set(trackFill, start, Math.Clamp(knob, start, end), y, tint);
        trackFill.Visibility = knob > start ? Visibility.Visible : Visibility.Collapsed;
        if (zones)
        {
            Set(trackQuiet, 10, start - 5, y, FanSlider.Value < 1 ? tint : rest);
            Set(trackTurbo, end + 5, w - 10, y, FanSlider.Value > 100 ? tint : rest);
        }
        else trackQuiet.Visibility = trackTurbo.Visibility = Visibility.Collapsed;
    }

    void FanSlider_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        DrawFanTrack();
        PlaceFanMarks();
    }

    void BeginFanDrag()
    {
        if (fanInteracting) return;
        fanInteracting = true;
        ownsQuiet = fanQuiet;
        lastFanDrag = DateTime.Now;
        reconcileLater.Stop();
        pendingReconcile = null;
    }

    void FanSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (snapping) return;
        var v = e.NewValue;
        if (zones)
        {
            var lo = QuietMin;
            var hi = TurboMax;
            // Tote Zonen: der Knopf bleibt nie in einer gestrichelten Strecke stehen. Mit der Maus zur näheren Seite,
            // mit der Tastatur über die Strecke hinweg (sonst käme ein Pfeilschritt von 1 % nie nach „Außengerät leise“).
            if (v > lo && v < 1)
                v = keyStep ? (e.OldValue <= lo ? 1 : lo) : (v < (lo + 1) / 2 ? lo : 1);
            else if (v > 100 && v < hi)
                v = keyStep ? (e.OldValue >= hi ? 100 : hi) : (v > (100 + hi) / 2 ? hi : 100);
            if (v != e.NewValue)
            {
                snapping = true;
                FanSlider.Value = v;
                snapping = false;
            }
        }
        DrawFanTrack();
        if (updating || Core.Snap.State == null) return;

        // Ein Klick auf die Spur setzt den Wert, bevor PreviewMouseDown hier ankommt – Bedienung dann hier beginnen.
        if (!fanInteracting && !keyStep && Mouse.LeftButton == MouseButtonState.Pressed) BeginFanDrag();
        var owns = fanInteracting ? ownsQuiet ?? fanQuiet : fanQuiet;
        lastFanDrag = DateTime.Now;

        if (zones && v <= QuietMin)
        {
            if (fanInteracting) ownsQuiet = true;
            Core.Send(Cmd.FanQuiet);
        }
        else if (zones && v >= TurboMax) Core.Send(Cmd.FanTurbo);
        else
        {
            var speed = (int)Math.Clamp(Math.Round(v), 1, 100);
            // Der Kern schaltet Zonen beim Verlassen selbst ab (Turbo im selben Befehl).
            if (speed != fanSpeed || fanAuto || fanQuiet || fanTurboOn) Core.Send(Cmd.Fan, ("value", speed));
        }
        // Ein Tastenschritt ist Drücken und Loslassen zugleich: gleich abgleichen.
        if (!fanInteracting) FinishFan(v, owns);
    }

    void EndFanDrag()
    {
        if (!fanInteracting) return;
        fanInteracting = false;
        var owns = ownsQuiet == true;
        ownsQuiet = null;
        lastFanDrag = DateTime.Now;
        FinishFan(FanSlider.Value, owns);
        // Gezogenen Wert noch kurz stehen lassen, dann auf den Stand der Anlage nachführen.
        ResyncSoon();
    }

    /// Nach dem Loslassen abgleichen – sofort und noch einmal nach Ablauf der 2-s-Sperre des Kerns.
    /// Das zweite Mal nur an den Zonen-Enden: nur dort kann die Sperre etwas verschluckt haben.
    void FinishFan(double value, bool owns)
    {
        ReconcileZones(value, owns);
        CancelReconcile();
        if (zones && (value <= QuietMin || value >= TurboMax))
        {
            pendingReconcile = (value, owns, lastFanDrag);
            reconcileLater.Start();
        }
    }

    /// Eine andere Lüfter-Bedienung (Marke, Zonen-Symbol, Auto) ersetzt den ausstehenden Abgleich.
    void CancelReconcile()
    {
        reconcileLater.Stop();
        pendingReconcile = null;
    }

    /// Hat die 2-s-Sperre des Kerns ein Umschalten verschluckt, jetzt nachholen (doppelt senden schadet nicht).
    /// „Außengerät leise“ beim Verlassen direkt über `outdoorSilent` abschalten – `fan` tut das nur von genau 1 % aus.
    void ReconcileZones(double value, bool owns)
    {
        var s = Core.Snap;
        if (!s.FanZonesAvailable || s.State is not { } st) return;
        if (value <= QuietMin)
        {
            if (st.Fan != 1 || st.Turbo || st.OutSilent != true) Core.Send(Cmd.FanQuiet);
        }
        else if (value >= TurboMax)
        {
            if (st.Fan != 100 || !st.Turbo) Core.Send(Cmd.FanTurbo);
            else if (st.OutSilent == true) Core.Send(Cmd.OutdoorSilent, ("on", false));
        }
        else if (owns && st.OutSilent == true)
        {
            Core.Send(Cmd.OutdoorSilent, ("on", false));
        }
    }

    /// Auto an/aus – per Maus, Leertaste oder Sprachausgabe (Umschalten). Beim Zeichnen sperrt `updating`.
    void FanAuto_Changed(object sender, RoutedEventArgs e)
    {
        if (updating) return;
        var st = Core.Snap.State;
        if (st == null) return;
        var toAuto = FanAuto.IsChecked == true;
        if (toAuto == (st.Fan == Codes.FanAuto)) return;
        CancelReconcile();
        Core.Send(Cmd.Fan, ("value", toAuto ? Codes.FanAuto : (int)Math.Clamp(Math.Round(FanSlider.Value), 1, 100)), ("now", true));
    }
}
