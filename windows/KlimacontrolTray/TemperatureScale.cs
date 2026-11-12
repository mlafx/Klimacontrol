using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;

namespace KlimacontrolTray;

/// Umrechnung der Skala in Pixel. Lage (`fraction` 0…1 zwischen den Knopfmitten) und Texte kommen fertig aus dem Kern
/// (`options.temperatureScale`, `scaleRoom`); hier nur Einzug und Platz der Beschriftungen (wie `ScaleLayout` am Mac).
static class ScaleMath
{
    /// Mindestabstand zwischen der Raum-Beschriftung und einer Wertbeschriftung.
    public const double LabelGap = 6;

    /// Einzug links und rechts: Die Knopfmitte läuft von Spuranfang + halbe Knopfbreite bis Spurende − halbe Knopfbreite.
    public static (double Left, double Right) Insets(double sliderWidth, double trackLeft, double trackWidth, double thumbWidth)
    {
        var half = Math.Max(0, thumbWidth) / 2;
        var left = Math.Max(0, trackLeft) + half;
        var right = Math.Max(0, sliderWidth - trackLeft - trackWidth) + half;
        return (left, right);
    }

    /// Lage eines Werts auf der Breite (geklemmt auf 0…1).
    public static double X(double fraction, double width, double left, double right) =>
        left + Math.Max(0, width - left - right) * Math.Clamp(double.IsFinite(fraction) ? fraction : 0, 0, 1);

    /// Linke Kante einer Beschriftung: mittig an ihrem Wert, aber nie über den Rand hinaus.
    public static double LabelLeft(double x, double labelWidth, double width) =>
        Math.Max(0, Math.Min(x - labelWidth / 2, width - labelWidth));

    /// Zwei Beschriftungen kommen sich näher als `gap` (Berühren zählt mit).
    public static bool Touches(double aLeft, double aWidth, double bLeft, double bWidth, double gap) =>
        aLeft <= bLeft + bWidth + gap && bLeft <= aLeft + aWidth + gap;

    /// Linke Kanten der Wertbeschriftungen und der Raum-Beschriftung; eine Wertbeschriftung, die die Raum-Beschriftung
    /// berühren würde, entfällt (`Visible` = false, der Raum hat Vorrang).
    public static (List<(double Left, bool Visible)> Labels, double? RoomLeft) Place(
        double width, double left, double right,
        IReadOnlyList<(double Fraction, double Width)> labels, (double Fraction, double Width)? room)
    {
        double? roomLeft = room is { } r ? LabelLeft(X(r.Fraction, width, left, right), r.Width, width) : null;
        var placed = new List<(double, bool)>(labels.Count);
        foreach (var (fraction, w) in labels)
        {
            var l = LabelLeft(X(fraction, width, left, right), w, width);
            var hidden = roomLeft is { } rl && room is { } rr && Touches(l, w, rl, rr.Width, LabelGap);
            placed.Add((l, !hidden));
        }
        return (placed, roomLeft);
    }
}

/// Skala unter dem Regler der Solltemperatur: betonte Striche, Wertbeschriftungen und die Marke der Raumtemperatur.
/// Die Lagen folgen der Knopfmitte des Reglers `Source`.
public sealed class TemperatureScale : Panel
{
    const double MarkRow = 8;
    const double DotSize = 7;

    /// Regler, unter dem die Skala steht (gleiche Breite und linke Kante).
    public Slider? Source { get; set; }

    readonly List<(ScaleTick Tick, Rectangle Shape)> ticks = new();
    readonly List<(ScaleMark Mark, TextBlock Text)> labels = new();
    readonly Ellipse roomDot = new() { Width = DotSize, Height = DotSize, IsHitTestVisible = false };
    readonly TextBlock roomText = new() { FontWeight = FontWeights.SemiBold };
    ScaleMark? room;
    string key = "";
    double fontSize = 11;
    /// Wertbeschriftungen, die beim letzten Anordnen der Raum-Beschriftung weichen mussten.
    readonly HashSet<TextBlock> hidden = new();

    public TemperatureScale()
    {
        SnapsToDevicePixels = true;
        ClipToBounds = true;
        roomDot.SetResourceReference(Shape.FillProperty, "Fg");
        roomText.SetResourceReference(TextBlock.ForegroundProperty, "Fg");
        // Die Schriftgröße setzt die Skala selbst (× „Größe“), SizeScale lässt sie aus.
        SizeScale.Own(roomText);
        AutomationProperties.SetName(this, L.T("main.hero.targetTemperature"));
    }

    /// Striche, Beschriftungen und Raum-Marke nach dem Kern; baut nur bei geänderten Werten um.
    public void Update(TemperatureScaleOptions options, ScaleMark? roomMark, double factor)
    {
        var size = Math.Round(11 * factor * 2) / 2;
        var k = string.Join("\u001f", options.Emphasized.Select(t => $"{t.Value}:{t.Fraction}"))
              + "\u001e" + string.Join("\u001f", options.Labels.Select(t => $"{t.Value}:{t.Fraction}:{t.Text}"))
              + "\u001e" + (roomMark == null ? "" : $"{roomMark.Fraction}:{roomMark.Text}") + "\u001e" + size;
        if (k == key) return;
        key = k;
        fontSize = size;
        Children.Clear();
        ticks.Clear();
        labels.Clear();
        hidden.Clear();
        foreach (var t in options.Emphasized)
        {
            var r = new Rectangle { Width = 1.5, Height = 6, RadiusX = 0.75, RadiusY = 0.75, IsHitTestVisible = false };
            r.SetResourceReference(Shape.FillProperty, "Sub");
            ticks.Add((t, r));
            Children.Add(r);
        }
        foreach (var m in options.Labels)
        {
            var tb = new TextBlock { Text = m.Text ?? "", FontSize = size };
            tb.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
            SizeScale.Own(tb);
            labels.Add((m, tb));
            Children.Add(tb);
        }
        room = roomMark;
        if (roomMark != null)
        {
            roomText.Text = roomMark.Text ?? "";
            roomText.FontSize = size;
            Children.Add(roomDot);
            Children.Add(roomText);
        }
        InvalidateMeasure();
    }

    /// Einzug aus dem Regler: Lage der Spur und Breite des Knopfs; ohne Vorlage ein üblicher Wert.
    (double Left, double Right) Insets()
    {
        if (Source is { ActualWidth: > 0 } s && s.Template?.FindName("PART_Track", s) is Track { ActualWidth: > 0 } t
            && t.Thumb is { ActualWidth: > 0 } thumb && t.IsDescendantOf(s))
        {
            var p = t.TranslatePoint(new Point(0, 0), s);
            return ScaleMath.Insets(s.ActualWidth, p.X, t.ActualWidth, thumb.ActualWidth);
        }
        return (10, 10);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var height = 0.0;
        foreach (UIElement c in InternalChildren)
        {
            c.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            if (c is TextBlock) height = Math.Max(height, c.DesiredSize.Height);
        }
        if (height == 0) height = Math.Ceiling(fontSize * 1.33);
        return new Size(double.IsFinite(availableSize.Width) ? availableSize.Width : 0, MarkRow + 2 + height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var w = finalSize.Width;
        var (left, right) = Insets();
        foreach (var (tick, shape) in ticks)
        {
            var x = ScaleMath.X(tick.Fraction, w, left, right);
            shape.Arrange(new Rect(x - shape.DesiredSize.Width / 2, 0, shape.DesiredSize.Width, shape.DesiredSize.Height));
        }
        var (placed, roomLeft) = ScaleMath.Place(w, left, right,
            labels.Select(l => (l.Mark.Fraction, l.Text.DesiredSize.Width)).ToList(),
            room != null ? (room.Fraction, roomText.DesiredSize.Width) : null);
        const double top = MarkRow + 2;
        hidden.Clear();
        for (var i = 0; i < labels.Count; i++)
        {
            var tb = labels[i].Text;
            var (l, visible) = placed[i];
            // Verdeckte Beschriftungen außerhalb ablegen; der Zuschnitt blendet sie aus (Sichtbarkeit hier zu setzen
            // löste eine neue Messung aus).
            tb.Arrange(new Rect(visible ? l : -10_000, top, tb.DesiredSize.Width, tb.DesiredSize.Height));
            if (!visible) hidden.Add(tb);
        }
        if (room != null && roomLeft is { } rl)
        {
            var x = ScaleMath.X(room.Fraction, w, left, right);
            roomDot.Arrange(new Rect(x - DotSize / 2, (MarkRow - DotSize) / 2, DotSize, DotSize));
            roomText.Arrange(new Rect(rl, top, roomText.DesiredSize.Width, roomText.DesiredSize.Height));
        }
        return finalSize;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new ScalePeer(this);

    /// Für die Sprachausgabe eine Gruppe mit den sichtbaren Beschriftungen und der Raum-Beschriftung.
    sealed class ScalePeer(TemperatureScale owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
        protected override string GetClassNameCore() => nameof(TemperatureScale);

        protected override List<AutomationPeer>? GetChildrenCore()
        {
            var list = new List<AutomationPeer>();
            foreach (var (_, tb) in owner.labels)
                if (!owner.hidden.Contains(tb) && UIElementAutomationPeer.CreatePeerForElement(tb) is { } p) list.Add(p);
            if (owner.room != null && UIElementAutomationPeer.CreatePeerForElement(owner.roomText) is { } r) list.Add(r);
            return list;
        }
    }
}
