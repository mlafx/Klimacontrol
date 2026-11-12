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

/// Dichte (Compact) und Größe (`Theme.SizeFactor`) der Steuerung.
public partial class ControlPanel
{
    /// Zuletzt angewandter Größenfaktor (NaN = noch nie).
    double appliedFactor = double.NaN;

    /// Größe (× `Theme.SizeFactor`, nur bei neuem Faktor) und Ziffernstil der großen Zahl.
    void ApplyLook()
    {
        var f = Theme.SizeFactor;
        if (f != appliedFactor)
        {
            appliedFactor = f;
            // Die Einrichtung baut ihre Seiten selbst um – sie bleibt außen vor.
            foreach (UIElement child in Root.Children)
                if (!ReferenceEquals(child, SetupPanel)) SizeScale.Apply(child, f);
            ApplyDensity();
        }
        var (family, weight) = Theme.DigitFont;
        foreach (var t in new[] { TargetText, RoomBig })
        {
            t.FontFamily = family;
            t.FontWeight = weight;
        }
        Connecting.ApplyLook();
    }

    bool compact;

    /// Kompakte Dichte für knappe Fensterhöhe: kleinere Abstände, flachere Kacheln, kleinere Solltemperatur.
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

    /// Höhe in normaler Dichte bei dieser Breite. Danach steht Compact auf false – der Aufrufer setzt es passend.
    /// Alle Elemente neu vermessen: Measure allein liefert nach geänderten Abständen sonst den alten Wert.
    public double NaturalHeight(double width)
    {
        Compact = false;
        static void Invalidate(DependencyObject d)
        {
            if (d is UIElement u) u.InvalidateMeasure();
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(d); i++) Invalidate(VisualTreeHelper.GetChild(d, i));
        }
        Invalidate(this);
        Measure(new Size(Math.Max(0, width), double.PositiveInfinity));
        return DesiredSize.Height;
    }

    /// Abstände nach Dichte (Compact) und „Größe“ (`Theme.SizeFactor`), beides zusammen.
    void ApplyDensity()
    {
        var f = Theme.SizeFactor;
        double D(double normal, double small) => Math.Round((compact ? small : normal) * f);
        HeroBody.Padding = new Thickness(D(16, 12));
        MoreToggle.Margin = new Thickness(0, D(12, 6), 0, 0);
        OnPanel.Margin = OffPanel.Margin = new Thickness(0, D(10, 2), 0, 0);
        TargetText.FontSize = D(64, 46);
        RoomBig.FontSize = D(54, 42);
        TempRow.Margin = new Thickness(0, D(8, 2), 0, 0);
        TempScale.Margin = new Thickness(0, D(2, 0), 0, 0);
        HeroDivider.Margin = new Thickness(0, D(14, 8), 0, 0);
        // Unter „Mehr …“ ohne Trennlinie davor.
        Readings.Margin = new Thickness(0, arrangedSimple == true ? 0 : D(12, 8), 0, 0);
        MoreReadingsHost.Margin = new Thickness(0, D(8, 4), 0, 0);
        // Karten: Abstand untereinander und Innenabstand (Theme.CardPadding, kompakt kleiner).
        var gap = new Thickness(0, D(14, 8), 0, 0);
        var inset = new Thickness(D(Theme.CardPadding, 12));
        ControlsCard.Margin = GroupCard.Margin = gap;
        ControlsCard.Padding = GroupCard.Padding = inset;
        FanDivider.Margin = new Thickness(0, D(14, 8), 0, 0);
        FanPanel.Margin = new Thickness(0, D(14, 8), 0, 0);
        GroupDivider.Margin = new Thickness(0, D(8, 6), 0, D(8, 6));
        Scenes.Margin = new Thickness(0, arrangedSimple == true ? D(12, 8) : 0, 0, 0);
        Timers.Margin = new Thickness(0);
        foreach (var t in modeTiles.Values.Concat(new[] { swingTile, ecoTile, turboTile, silentTile }))
        {
            t.MinHeight = D(54, 44);
            t.Padding = new Thickness(4, D(6, 3), 4, D(6, 3));
        }
        ComfortPanel.Margin = new Thickness(0, D(12, 6), 0, 0);
        MorePanel.Margin = new Thickness(0, D(14, 8), 0, 0);
        foreach (var r in new[] { ieco, sleep, purifier, freeze, clean, display, sound }) r.Height = D(34, 30);
        RateRow.Margin = new Thickness(0, D(10, 6), 0, 0);
        Scenes.Compact = compact;
        Timers.Compact = compact;
        Connecting.Compact = compact;
        // Die Bausteine rechnen den Faktor selbst ein; ein neuer Faktor bei gleicher Dichte braucht diesen Anstoß.
        Scenes.ApplyDensity();
        Timers.ApplyDensity();
        Connecting.ApplyDensity();
        MessageBanner.Margin = new Thickness(0, D(12, 8), 0, 0);
        NoticeBanner.Margin = new Thickness(0, D(8, 6), 0, 0);
    }
}
