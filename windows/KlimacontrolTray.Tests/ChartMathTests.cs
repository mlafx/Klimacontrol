using System;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Rechnung der Graphen gegen die gemeinsamen Tabellen mit dem Kern (`ChartAxisTests`, `SharedTableTests` in Swift).
public class ChartMathTests
{
    static string SourceDir([CallerFilePath] string here = "") => Path.GetDirectoryName(here)!;

    static JsonDocument Table() => Shared("chart-axis-table.json");

    static void Check(JsonElement row, ChartMath.Axis? axis)
    {
        var expected = row.GetProperty("axis");
        var values = string.Join(", ", row.GetProperty("values").EnumerateArray().Select(v => v.GetDouble()));
        if (expected.ValueKind == JsonValueKind.Null)
        {
            Assert.Null(axis);
            return;
        }
        Assert.True(axis != null, values);
        foreach (var (name, actual) in new[] { ("min", axis!.Min), ("max", axis.Max), ("first", axis.First), ("step", axis.Step) })
            Assert.True(Math.Abs(expected.GetProperty(name).GetDouble() - actual) < 1e-9, $"{name} bei [{values}]: {actual}");
    }

    [Fact]
    public void LeistungsachseWieImKern()
    {
        using var doc = Table();
        var rows = doc.RootElement.GetProperty("power").EnumerateArray().ToList();
        Assert.NotEmpty(rows);
        foreach (var r in rows)
            Check(r, ChartMath.PowerAxis(r.GetProperty("values").EnumerateArray().Select(v => v.GetDouble()).ToList()));
    }

    [Fact]
    public void TemperaturachseWieImKern()
    {
        using var doc = Table();
        var rows = doc.RootElement.GetProperty("temperature").EnumerateArray().ToList();
        Assert.NotEmpty(rows);
        foreach (var r in rows)
            Check(r, ChartMath.TempAxis(r.GetProperty("values").EnumerateArray().Select(v => v.GetDouble()).ToList()));
    }

    /// Die Tabelle rechnet mit den am Mac gemessenen Werten (6,0 je Zeichen, Abstand 10); geteilt wird die Regel.
    [Fact]
    public void BeschriftungWieImKern()
    {
        using var doc = Table();
        var rows = doc.RootElement.GetProperty("labels").EnumerateArray().ToList();
        Assert.NotEmpty(rows);
        foreach (var r in rows)
        {
            var count = r.GetProperty("count").GetInt32();
            var step = ChartMath.LabelStep(count, r.GetProperty("plotWidth").GetDouble(), r.GetProperty("labelLength").GetInt32(), 6.0, 10);
            var note = r.GetProperty("note").GetString();
            Assert.True(r.GetProperty("step").GetInt32() == step, $"{note}: Schritt {step}");
            var shown = Enumerable.Range(0, count).Where(i => ChartMath.ShowsLabel(i, count, step));
            Assert.Equal(r.GetProperty("shown").EnumerateArray().Select(v => v.GetInt32()), shown);
        }
    }

    [Fact]
    public void NichtEndlicheWerteZaehlenNicht()
    {
        Assert.Null(ChartMath.PowerAxis(new[] { double.NaN, double.PositiveInfinity }));
        Assert.Null(ChartMath.TempAxis(new[] { double.NegativeInfinity, double.NaN }));
        Assert.Equal(ChartMath.PowerAxis(new[] { 450.0 }), ChartMath.PowerAxis(new[] { 450.0, double.PositiveInfinity, double.NaN }));
        Assert.Equal(ChartMath.TempAxis(new[] { 21.0 }), ChartMath.TempAxis(new[] { double.NaN, 21.0, double.NegativeInfinity }));
    }

    /// Mit den für Segoe UI 11 gemessenen Werten: Die breitesten Tagesbeschriftungen (gemessen 44,0 bzw. 53,1 px)
    /// passen in den Platz von `step` Balken, deutsch wie englisch; die letzte Beschriftung bleibt immer stehen.
    [Theory]
    [InlineData("Mi 30.12.", 44.04, 14, 346)]
    [InlineData("Wed 12/30", 53.10, 14, 346)]
    [InlineData("Mo 2.11.", 41.89, 14, 420)]
    [InlineData("Mon 11/2", 47.64, 14, 420)]
    [InlineData("Wed 12/30", 53.10, 14, 766)]
    [InlineData("KW 45", 31.74, 8, 346)]
    [InlineData("Sept. 2026", 50.91, 12, 346)]
    [InlineData("Nov 2026", 46.68, 12, 346)]
    public void BeschriftungenDeutschUndEnglischPassen(string label, double measured, int count, double width)
    {
        var step = ChartMath.LabelStep(count, width, label.Length, EnergyCard.LabelCharWidth, EnergyCard.LabelGap);
        Assert.True(step * width / count >= measured, $"{label}: Schritt {step}");
        Assert.True(ChartMath.ShowsLabel(count - 1, count, step));
    }

    static JsonDocument Shared(string name)
    {
        var file = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "Tests", "Shared", name));
        Assert.True(File.Exists(file), file);
        return JsonDocument.Parse(File.ReadAllText(file));
    }

    /// Schnappschuss-Muster des Vertrags: die Zahlen, die der Kern in `options` liefert.
    static JsonElement MusterOptions(JsonDocument doc) => doc.RootElement.GetProperty("snapshot").GetProperty("options");

    static JsonDocument Muster()
    {
        var file = Path.Combine(SourceDir(), "Vertrag", "bridge-muster.json");
        Assert.True(File.Exists(file), file);
        return JsonDocument.Parse(File.ReadAllText(file));
    }

    static readonly JsonSerializerOptions Camel = new() { PropertyNameCaseInsensitive = true };

    [Fact]
    public void ModusBandVerlaengertNachUnten()
    {
        var a = new ChartMath.Axis(0, 600, 0, 200);
        var shown = a.ExtendedBelow(0.1);
        Assert.Equal(-600.0 / 9, shown.Min, 9);
        Assert.Equal(0.1, (0 - shown.Min) / (shown.Max - shown.Min), 9);
        Assert.Equal(a with { Min = shown.Min }, shown);
        Assert.Equal(a, a.ExtendedBelow(0));
        Assert.Equal(a, a.ExtendedBelow(1));
        Assert.Equal(new[] { 0.0, 200, 400, 600 }, shown.Ticks());
    }

    [Fact]
    public void PlatzNachObenWieImKern()
    {
        var a = new ChartMath.Axis(0, 600, 0, 200);
        Assert.Equal(750, a.WithHeadroom(600, 0.2).Max, 9);
        Assert.Equal(a, a.WithHeadroom(100, 0.2));
        Assert.Equal(a, a.WithHeadroom(double.NaN, 0.2));
    }

    [Fact]
    public void ZeitmarkenWieImKern()
    {
        using var doc = Shared("time-ticks-table.json");
        var zone = TimeZoneInfo.FindSystemTimeZoneById(doc.RootElement.GetProperty("windowsTimeZone").GetString()!);
        var cases = doc.RootElement.GetProperty("cases").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var ticks = ChartMath.TimeTicks(c.GetProperty("start").GetDouble(), c.GetProperty("end").GetDouble(),
                c.GetProperty("stepMinutes").GetInt32(), c.GetProperty("plotWidth").GetDouble(),
                c.GetProperty("labelHalfWidth").GetDouble(), zone);
            var expected = c.GetProperty("ticks").EnumerateArray().Select(v => v.GetDouble()).ToList();
            Assert.True(expected.SequenceEqual(ticks), $"{c.GetProperty("note").GetString()}: {string.Join(", ", ticks)}");
        }
    }

    /// Die Schrittweiten kommen in der App aus `options.chart.ranges`; das Muster muss zur Tabelle passen.
    [Fact]
    public void ZeitraeumeImMusterPassenZurTabelle()
    {
        using var table = Shared("time-ticks-table.json");
        using var muster = Muster();
        var steps = table.RootElement.GetProperty("steps").EnumerateArray()
            .ToDictionary(s => s.GetProperty("range").GetDouble(), s => (s.GetProperty("stepMinutes").GetInt32(), s.GetProperty("labelHalfWidth").GetDouble()));
        var ranges = MusterOptions(muster).GetProperty("chart").GetProperty("ranges").EnumerateArray().ToList();
        Assert.NotEmpty(ranges);
        foreach (var r in ranges)
        {
            var seconds = r.GetProperty("seconds").GetDouble();
            Assert.True(steps.TryGetValue(seconds, out var s), $"Zeitraum {seconds} fehlt in der Tabelle");
            Assert.Equal(s.Item1, r.GetProperty("tickMinutes").GetInt32());
            Assert.Equal(s.Item2, r.GetProperty("tickLabelHalfWidth").GetDouble());
        }
    }

    [Fact]
    public void GraphenhoehenWieImKern()
    {
        using var muster = Muster();
        var window = MusterOptions(muster).GetProperty("window").Deserialize<WindowOptions>(Camel)!;
        Assert.True(window.ChartStep > 0 && window.ChartWeights.Power > 0);
        using var doc = Shared("chart-heights-table.json");
        var cases = doc.RootElement.GetProperty("cases").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var overhead = c.GetProperty("overhead");
            var h = ChartMath.ChartHeights(window, c.GetProperty("columnHeight").GetDouble(), c.GetProperty("grid").GetBoolean(),
                overhead.ValueKind == JsonValueKind.Null ? null : overhead.GetDouble(), c.GetProperty("separateOutdoor").GetBoolean());
            var e = c.GetProperty("heights");
            var expected = new ChartMath.Heights(e.GetProperty("power").GetDouble(), e.GetProperty("temperature").GetDouble(),
                e.GetProperty("outdoor").GetDouble(), e.GetProperty("energy").GetDouble());
            Assert.True(expected == h, $"{c.GetProperty("note").GetString()}: {h}");
        }
    }

    [Fact]
    public void ModusLaeufeWieImKern()
    {
        using var doc = Shared("mode-runs-table.json");
        var cases = doc.RootElement.GetProperty("cases").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var points = c.GetProperty("samples").EnumerateArray()
                .Select(s => (s.GetProperty("t").GetDouble(), s.GetProperty("mode").ValueKind == JsonValueKind.Null ? (int?)null : s.GetProperty("mode").GetInt32()))
                .ToList();
            var runs = ChartMath.ModeRuns(points, c.GetProperty("gapLimit").GetDouble());
            var expected = c.GetProperty("runs").EnumerateArray()
                .Select(r => new ChartMath.ModeRun(r.GetProperty("mode").GetInt32(), r.GetProperty("start").GetDouble(), r.GetProperty("end").GetDouble()))
                .ToList();
            Assert.True(expected.SequenceEqual(runs), $"{c.GetProperty("note").GetString()}: {string.Join(", ", runs)}");
        }
    }
}
