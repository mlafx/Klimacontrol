using System;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Rechnung der Verbrauchsbalken wie `EnergyBars` am Mac (`ChartAxis.withHeadroom`, Balkenbreite, Beschriftungen).
public class EnergyMathTests
{
    static string SourceDir([CallerFilePath] string here = "") => Path.GetDirectoryName(here)!;

    static JsonDocument Table()
    {
        var file = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "Tests", "Shared", "chart-axis-table.json"));
        Assert.True(File.Exists(file), file);
        return JsonDocument.Parse(File.ReadAllText(file));
    }

    /// Für jede Zeile der Leistungstabelle: Über dem höchsten Wert bleibt genau der Anteil frei (oder mehr, wenn die
    /// runde Achse schon höher reicht); Untergrenze, Gitter und Schritt bleiben wie in der Tabelle.
    [Fact]
    public void PlatzObenUeberDemHoechstenWert()
    {
        using var doc = Table();
        foreach (var row in doc.RootElement.GetProperty("power").EnumerateArray())
        {
            var values = row.GetProperty("values").EnumerateArray().Select(v => v.GetDouble()).ToList();
            var expected = row.GetProperty("axis");
            if (expected.ValueKind == JsonValueKind.Null || values.Count == 0) continue;
            foreach (var fraction in new[] { EnergyMath.HeadroomPlain, EnergyMath.HeadroomWithValues })
            {
                var a = EnergyMath.BarAxis(values, null, fraction)!;
                var highest = values.Max();
                Assert.Equal(expected.GetProperty("min").GetDouble(), a.Min, 9);
                Assert.Equal(expected.GetProperty("first").GetDouble(), a.First, 9);
                Assert.Equal(expected.GetProperty("step").GetDouble(), a.Step, 9);
                Assert.True(a.Max >= expected.GetProperty("max").GetDouble() - 1e-9);
                Assert.True((a.Max - highest) / (a.Max - a.Min) >= fraction - 1e-9, $"[{string.Join(", ", values)}] {fraction}");
            }
        }
    }

    [Fact]
    public void PlatzObenWieAmMac()
    {
        var axis = new ChartMath.Axis(0, 3, 0, 1);
        // 2,5 / (1 − 0,24) = 3,289…; die runde Achse (3) reicht nicht mehr.
        Assert.Equal(2.5 / 0.76, axis.WithHeadroom(2.5, 0.24).Max, 9);
        // Reicht die Achse schon, bleibt sie.
        Assert.Equal(3, axis.WithHeadroom(1, 0.24).Max, 9);
        // Ungültige Anteile oder Werte ändern nichts.
        Assert.Equal(axis, axis.WithHeadroom(double.NaN, 0.24));
        Assert.Equal(axis, axis.WithHeadroom(2.5, 0));
        Assert.Equal(axis, axis.WithHeadroom(2.5, 1));
    }

    [Fact]
    public void DurchschnittZaehltZurAchse()
    {
        var a = EnergyMath.BarAxis(new[] { 1.0, 0.5 }, 4.0, 0.12)!;
        Assert.True(a.Max >= 4.0 / 0.88 - 1e-9);
        Assert.Null(EnergyMath.BarAxis(Array.Empty<double>(), 2.0, 0.12));
        Assert.Null(EnergyMath.BarAxis(new[] { double.NaN }, null, 0.12));
    }

    [Fact]
    public void AnteilObenWaechstMitDerSchrift()
    {
        Assert.Equal(EnergyMath.HeadroomWithValues, EnergyMath.HeadroomFraction(true, 20, 130), 9);
        Assert.Equal(EnergyMath.HeadroomPlain, EnergyMath.HeadroomFraction(false, 0, 130), 9);
        // „Groß“: zwei Zeilen à 15,5 px passen nicht in 24 % von 130 px.
        Assert.Equal(33.0 / 130, EnergyMath.HeadroomFraction(true, 33, 130), 9);
        Assert.Equal(EnergyMath.HeadroomMax, EnergyMath.HeadroomFraction(true, 500, 130), 9);
    }

    [Theory]
    [InlineData(346, 14, 56, 17)]
    [InlineData(766, 14, 56, 38)]
    [InlineData(766, 8, 56, 56)]
    [InlineData(346, 60, 56, 4)]
    [InlineData(100, 1, 56, 56)]
    public void BalkenbreiteHoechstensDieGrenze(double plotWidth, int count, double max, double expected)
    {
        Assert.Equal(expected, EnergyMath.BarWidth(plotWidth, count, max));
    }

    [Fact]
    public void GitterInnerhalbDesBereichs()
    {
        Assert.Equal(new[] { 0.0, 1, 2, 3 }, EnergyMath.Ticks(new ChartMath.Axis(0, 3.29, 0, 1)));
        Assert.Equal(new[] { 0.0, 200, 400, 600 }, EnergyMath.Ticks(new ChartMath.Axis(0, 600, 0, 200)));
        Assert.Empty(EnergyMath.Ticks(new ChartMath.Axis(0, 1, 0, 0)));
    }

    [Fact]
    public void HoeheEinesWerts()
    {
        var a = new ChartMath.Axis(0, 4, 0, 1);
        Assert.Equal(100, EnergyMath.Y(0, a, 0, 100), 9);
        Assert.Equal(0, EnergyMath.Y(4, a, 0, 100), 9);
        Assert.Equal(25, EnergyMath.Y(3, a, 0, 100), 9);
    }

    /// Erste und letzte Beschriftung ragen nicht über die Zeichenfläche, die übrigen stehen mittig.
    [Theory]
    [InlineData(12.35, 53, 346, 0)]
    [InlineData(333.65, 53, 346, 293)]
    [InlineData(173, 40, 346, 153)]
    [InlineData(10, 400, 346, 0)]
    public void BeschriftungBleibtInDerFlaeche(double center, double width, double plotWidth, double expected)
    {
        Assert.Equal(expected, EnergyMath.LabelLeft(center, width, plotWidth), 9);
    }

    [Fact]
    public void BalkenmitteJeZeitraum()
    {
        Assert.Equal(12.5, EnergyMath.BarCenter(0, 4, 100), 9);
        Assert.Equal(87.5, EnergyMath.BarCenter(3, 4, 100), 9);
    }
}
