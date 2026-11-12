using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Die Werte aus Vertrag/bridge-muster.json kommen mit dem Leser der App (BridgeJson.Default) im Modell an.
public class ModelFelderTests
{
    static JsonElement Sample(string part)
    {
        var file = Path.Combine(AppContext.BaseDirectory, "Vertrag", "bridge-muster.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        return doc.RootElement.GetProperty(part).Clone();
    }

    static Snapshot Snap() => JsonSerializer.Deserialize(Sample("snapshot").GetRawText(), BridgeJson.Default.Snapshot)!;

    static void AssertTick(JsonElement expected, ScaleTick actual)
    {
        Assert.Equal(expected.GetProperty("value").GetDouble(), actual.Value);
        Assert.Equal(expected.GetProperty("fraction").GetDouble(), actual.Fraction);
        Assert.False(expected.TryGetProperty("text", out _));
    }

    static void AssertMark(JsonElement expected, ScaleMark actual)
    {
        Assert.Equal(expected.GetProperty("value").GetDouble(), actual.Value);
        Assert.Equal(expected.GetProperty("fraction").GetDouble(), actual.Fraction);
        Assert.Equal(expected.GetProperty("text").GetString(), actual.Text);
    }

    [Fact]
    public void VerlaufBringtGeglaetteteAussentemperatur()
    {
        var json = Sample("history");
        var samples = JsonSerializer.Deserialize(json.GetRawText(), BridgeJson.Default.ListSample)!;
        Assert.Equal(json.GetArrayLength(), samples.Count);
        Assert.Equal(json[0].GetProperty("outdoorSmooth").GetDouble(), samples[0].OutdoorSmooth);
        Assert.Equal(28.75, samples[0].OutdoorSmooth);
    }

    [Fact]
    public void KennzahlenzeileKommtAn()
    {
        var json = Sample("stats");
        var stats = JsonSerializer.Deserialize(json.GetRawText(), BridgeJson.Default.HistoryStats)!;
        var line = json.GetProperty("line");
        Assert.Equal(4, line.GetArrayLength());
        Assert.Equal(line.GetArrayLength(), stats.Line.Count);
        for (var i = 0; i < stats.Line.Count; i++)
        {
            Assert.Equal(line[i].GetProperty("text").GetString(), stats.Line[i].Text);
            Assert.Equal(line[i].GetProperty("help").GetString(), stats.Line[i].Help);
        }
    }

    [Fact]
    public void TemperaturskalaKommtAn()
    {
        var json = Sample("snapshot").GetProperty("options").GetProperty("temperatureScale");
        var scale = Snap().Options.TemperatureScale;
        Assert.Equal(json.GetProperty("min").GetDouble(), scale.Min);
        Assert.Equal(json.GetProperty("max").GetDouble(), scale.Max);
        var labels = json.GetProperty("labels").EnumerateArray().ToList();
        Assert.Equal(labels.Count, scale.Labels.Count);
        for (var i = 0; i < labels.Count; i++) AssertMark(labels[i], scale.Labels[i]);
        var emphasized = json.GetProperty("emphasized").EnumerateArray().ToList();
        Assert.Equal(emphasized.Count, scale.Emphasized.Count);
        for (var i = 0; i < emphasized.Count; i++) AssertTick(emphasized[i], scale.Emphasized[i]);
    }

    [Fact]
    public void RaumMarkeKommtAn()
    {
        var json = Sample("snapshot").GetProperty("scaleRoom");
        var room = Snap().ScaleRoom;
        Assert.NotNull(room);
        AssertMark(json, room!);
        Assert.Equal("Raum 25,5°", room!.Text);
    }

    [Fact]
    public void ZeitraeumeTragenTeilungDerAchse()
    {
        var json = Sample("snapshot").GetProperty("options").GetProperty("chart").GetProperty("ranges").EnumerateArray().ToList();
        var ranges = Snap().Options.Chart.Ranges;
        Assert.Equal(json.Count, ranges.Count);
        for (var i = 0; i < json.Count; i++)
        {
            Assert.Equal(json[i].GetProperty("label").GetString(), ranges[i].Label);
            Assert.Equal(json[i].GetProperty("seconds").GetDouble(), ranges[i].Seconds);
            Assert.Equal(json[i].GetProperty("tickMinutes").GetInt32(), ranges[i].TickMinutes);
            Assert.Equal(json[i].GetProperty("tickLabelHalfWidth").GetDouble(), ranges[i].TickLabelHalfWidth);
        }
        Assert.Equal(1440, ranges[^1].TickMinutes);
        Assert.Equal(20, ranges[^1].TickLabelHalfWidth);
    }

    /// Jede Zahl unter options.window (auch in Unterobjekten) steht mit demselben Wert im Modell.
    [Fact]
    public void FensterRegelnStimmenMitDemMusterUeberein()
    {
        var json = Sample("snapshot").GetProperty("options").GetProperty("window");
        var window = Snap().Options.Window;
        var compared = CompareNumbers(json, window, "window");
        Assert.True(compared >= 25, $"nur {compared} Zahlen verglichen");
        Assert.Equal(3, window.ChartWeights.Power);
        Assert.Equal(3, window.ChartWeights.Temperature);
        Assert.Equal(2, window.ChartWeights.Outdoor);
    }

    static int CompareNumbers(JsonElement json, object model, string path)
    {
        var count = 0;
        foreach (var p in json.EnumerateObject())
        {
            var prop = model.GetType().GetProperty(p.Name,
                BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase);
            Assert.True(prop != null, $"{path}.{p.Name} fehlt im Modell");
            var value = prop!.GetValue(model);
            switch (p.Value.ValueKind)
            {
                case JsonValueKind.Number:
                    Assert.True(Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture) == p.Value.GetDouble(),
                        $"{path}.{p.Name}: Muster {p.Value.GetDouble()}, Modell {value}");
                    count++;
                    break;
                case JsonValueKind.Object:
                    Assert.NotNull(value);
                    count += CompareNumbers(p.Value, value!, path + "." + p.Name);
                    break;
                default:
                    Assert.Fail($"{path}.{p.Name}: unerwartete Art {p.Value.ValueKind}");
                    break;
            }
        }
        return count;
    }

    [Fact]
    public void FehlendeNeueFelderSindKeinFehler()
    {
        var snap = JsonSerializer.Deserialize("{\"configured\":true,\"options\":{\"chart\":{\"ranges\":[{\"label\":\"1 h\",\"seconds\":3600}]},\"window\":{}}}",
            BridgeJson.Default.Snapshot)!;
        Assert.Null(snap.ScaleRoom);
        Assert.Empty(snap.Options.TemperatureScale.Labels);
        Assert.Empty(snap.Options.TemperatureScale.Emphasized);
        Assert.Equal(0, snap.Options.Chart.Ranges[0].TickMinutes);
        Assert.Equal(0, snap.Options.Window.ChartWeights.Power);

        var samples = JsonSerializer.Deserialize("[{\"t\":1,\"on\":false,\"outdoor\":null}]", BridgeJson.Default.ListSample)!;
        Assert.Null(samples[0].OutdoorSmooth);

        var stats = JsonSerializer.Deserialize("{\"avgWatts\":null}", BridgeJson.Default.HistoryStats)!;
        Assert.Empty(stats.Line);
    }
}
