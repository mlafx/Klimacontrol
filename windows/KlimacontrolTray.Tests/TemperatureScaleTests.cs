using System;
using System.Collections.Generic;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Umrechnung der Skala unter dem Regler der Solltemperatur in Pixel (`ScaleMath`); Lagen und Texte liefert der Kern.
public class TemperatureScaleTests
{
    static void Near(double expected, double actual) => Assert.True(Math.Abs(expected - actual) < 1e-9, $"{expected} ≠ {actual}");

    [Fact]
    public void InsetsAreHalfTheThumbPlusTrackOffset()
    {
        var (l, r) = ScaleMath.Insets(sliderWidth: 300, trackLeft: 0, trackWidth: 300, thumbWidth: 20);
        Near(10, l);
        Near(10, r);
        (l, r) = ScaleMath.Insets(sliderWidth: 300, trackLeft: 4, trackWidth: 290, thumbWidth: 18);
        Near(13, l);
        Near(15, r);
    }

    [Fact]
    public void FractionRunsBetweenThumbCenters()
    {
        Near(10, ScaleMath.X(0, 300, 10, 10));
        Near(290, ScaleMath.X(1, 300, 10, 10));
        Near(150, ScaleMath.X(0.5, 300, 10, 10));
        // Werte außerhalb 0…1 bleiben am Rand (der Kern klemmt schon, das hier ist nur die Sicherung).
        Near(10, ScaleMath.X(-0.2, 300, 10, 10));
        Near(290, ScaleMath.X(1.4, 300, 10, 10));
        Near(10, ScaleMath.X(double.NaN, 300, 10, 10));
        // Zu schmal für den Einzug: keine negative Spur.
        Near(10, ScaleMath.X(1, 15, 10, 10));
    }

    [Fact]
    public void LabelStaysInsideTheWidth()
    {
        Near(140, ScaleMath.LabelLeft(150, 20, 300));
        Near(0, ScaleMath.LabelLeft(10, 30, 300));
        Near(270, ScaleMath.LabelLeft(290, 30, 300));
        Near(0, ScaleMath.LabelLeft(150, 400, 300));
    }

    [Fact]
    public void RoomLabelHidesTouchingValueLabels()
    {
        // Einzug 10 auf 300 px: 16° bei 10, 25° bei ~189,3, 30° bei 290.
        var labels = new List<(double, double)> { (0, 20), (0.6428571428571429, 20), (1, 20) };
        var (placed, roomLeft) = ScaleMath.Place(300, 10, 10, labels, (0.6785714285714286, 60));
        Assert.NotNull(roomLeft);
        Assert.True(placed[0].Visible);
        Assert.False(placed[1].Visible);
        Assert.True(placed[2].Visible);
        Near(0, placed[0].Left);
        Near(280, placed[2].Left);

        // Raum am linken Rand (unter 16°): die Beschriftung bleibt drin, 16° weicht.
        (placed, roomLeft) = ScaleMath.Place(300, 10, 10, labels, (0, 60));
        Near(0, roomLeft!.Value);
        Assert.False(placed[0].Visible);
        Assert.True(placed[1].Visible);
        Assert.True(placed[2].Visible);

        // Ohne Raumtemperatur alle Beschriftungen.
        (placed, roomLeft) = ScaleMath.Place(300, 10, 10, labels, null);
        Assert.Null(roomLeft);
        Assert.All(placed, p => Assert.True(p.Visible));
    }

    [Fact]
    public void TouchingCountsAsOverlap()
    {
        Assert.True(ScaleMath.Touches(0, 10, 16, 10, 6));
        Assert.False(ScaleMath.Touches(0, 10, 16.5, 10, 6));
        Assert.True(ScaleMath.Touches(50, 10, 40, 30, 0));
    }
}
