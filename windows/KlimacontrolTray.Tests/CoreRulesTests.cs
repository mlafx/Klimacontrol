using System;
using System.IO;
using System.Text.Json;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Regeln, die die Oberfläche vom Kern übernimmt: Zahl im Infobereich aus `menuTitle`, Lüftersperre aus `availability`,
/// Soll verstellbar aus `availability["target"]`, Schlafmodus aus `state.sleep` und `availability["sleep"]`.
public class CoreRulesTests
{
    [Theory]
    [InlineData("24°", ",", "24")]
    [InlineData("25,5°", ",", "26")]
    [InlineData("22,5°", ",", "23")]
    [InlineData("21,4°", ",", "21")]
    [InlineData("25.5°", ".", "26")]
    [InlineData("25,5° → 24°", ",", "24")]
    [InlineData("-0,4°", ",", "0")]
    [InlineData("-2,5°", ",", "-3")]
    [InlineData(null, ",", null)]
    [InlineData("", ",", null)]
    [InlineData("–", ",", null)]
    public void ZahlImSymbolKommtAusDemTextDesKerns(string? title, string separator, string? expected) =>
        Assert.Equal(expected, TrayIcon.IconNumber(title, separator));

    [Fact]
    public void TooltipFolgtDemTextDesKerns()
    {
        var st = new AcState { Power = true, Mode = 2 };
        Assert.Null(App.TipDetail(st, "24°", "iconTarget"));
        // Ohne Text vom Kern nur der Zustand, wie bei „nur Symbol“; mit Text der Zustand samt Text.
        var status = App.TipDetail(st, "24°", "iconOnly");
        Assert.Equal(status, App.TipDetail(st, null, "roomTarget"));
        Assert.Equal(status, App.TipDetail(st, "", "iconRoom"));
        Assert.Equal(L.F("tray.tip.statusRoom", ("status", status!), ("room", "25,5° → 24°")), App.TipDetail(st, "25,5° → 24°", "roomTarget"));
        Assert.Equal(L.F("tray.tip.statusRoom", ("status", status!), ("room", "25,5°")), App.TipDetail(st, "25,5°", "iconRoom"));
    }

    static Snapshot Muster()
    {
        var file = Path.Combine(AppContext.BaseDirectory, "Vertrag", "bridge-muster.json");
        Assert.True(File.Exists(file), file);
        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        return JsonSerializer.Deserialize(doc.RootElement.GetProperty("snapshot").GetRawText(), BridgeJson.Default.Snapshot)!;
    }

    [Fact]
    public void LuefterSperreAusDerAvailabilityDesKerns()
    {
        var s = Muster();
        Assert.False(s.Availability["fan"].Enabled);
        Assert.True(ControlPanel.FanLocked(s));
        s.Availability["fan"] = new AvailabilityInfo { Enabled = true };
        Assert.False(ControlPanel.FanLocked(s));
    }

    [Fact]
    public void SollVerstellbarAusDerAvailabilityDesKerns()
    {
        var s = Muster();
        Assert.True(s.Availability["target"].Enabled);
        Assert.True(ControlPanel.TargetAdjustable(s));
        s.Availability["target"] = new AvailabilityInfo { Enabled = false };
        Assert.False(ControlPanel.TargetAdjustable(s));
        s.Availability.Remove("target");
        Assert.False(ControlPanel.TargetAdjustable(s));
    }

    [Fact]
    public void SchlafmodusAusZustandUndAvailabilityDesKerns()
    {
        var s = Muster();
        Assert.False(s.State!.Sleep);
        Assert.True(s.IsEnabled("sleep"));
        Assert.False(string.IsNullOrEmpty(s.Why("sleep")));
        s.Availability["sleep"] = new AvailabilityInfo { Enabled = false, Why = "x" };
        Assert.False(s.IsEnabled("sleep"));
        Assert.Equal("x", s.Why("sleep"));
    }
}
