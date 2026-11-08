using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Reiter „Darstellung“: gleiche Texte, Reihenfolgen und Reglerschritte wie am Mac. Die Mac-Texte stehen im Katalog des
/// Kerns; `Appearance.<Enum>.label` in Sources/KlimacontrolCore/Appearance.swift nennt nur den Schlüssel
/// (`L.Appearance.Scheme.system` → `appearance.scheme.system`). Unter Windows bleiben die Kernnamen nur Werte (`Tag`) und
/// erscheinen nie als Anzeige. Übergang bis zum Umbau der Einstellungen: statt `{l:T schlüssel}` darf noch der deutsche
/// Katalogtext als Literal stehen.
[Collection("Global")]
public class AppearanceTextTests
{
    static readonly XNamespace X = "http://schemas.microsoft.com/winfx/2006/xaml";

    /// Auswahllisten des Reiters → Swift-Enum mit denselben Werten.
    static readonly (string Box, string Enum)[] Boxes =
    {
        ("LookModeBox", "Scheme"),
        ("LookColorsBox", "Accent"),
        ("LookBackgroundBox", "Background"),
        ("LookSizeBox", "SizeClass"),
        ("LookDigitsBox", "DigitStyle"),
        ("LookBigBox", "HeroValue"),
        ("LookScopeBox", "Scope"),
        ("LookTooltipBox", "MenuBarText"),
    };

    static string SourceDir([CallerFilePath] string here = "") => Path.GetDirectoryName(here)!;

    static string Repo(params string[] parts) =>
        Path.GetFullPath(Path.Combine(new[] { SourceDir(), "..", ".." }.Concat(parts).ToArray()));

    static string ReadLf(string path) => File.ReadAllText(path).Replace("\r\n", "\n");

    static string LowerFirst(string s) => char.ToLowerInvariant(s[0]) + s[1..];

    /// Swift-Enums der Darstellung: Name → Fälle in Reihenfolge von `allCases` mit dem Schlüssel ihres `label`.
    static Dictionary<string, List<(string Value, string Key)>> MacEnums()
    {
        var swift = ReadLf(Repo("Sources", "KlimacontrolCore", "Appearance.swift"));
        var result = new Dictionary<string, List<(string Value, string Key)>>();
        var enumRx = new Regex(@"public enum (?<name>\w+): String[^{]*\{(?<body>.*?)\n    \}", RegexOptions.Singleline);
        foreach (Match e in enumRx.Matches(swift))
        {
            var body = e.Groups["body"].Value;
            var labels = Regex.Matches(body, @"case \.(\w+): L\.Appearance\.(\w+)\.(\w+)")
                .ToDictionary(m => m.Groups[1].Value, m => "appearance." + LowerFirst(m.Groups[2].Value) + "." + m.Groups[3].Value);
            if (labels.Count == 0) continue;
            var decl = Regex.Match(body, @"\n\s*case (?<cases>\w+(?:, *\w+)*)\n");
            Assert.True(decl.Success, $"Fälle von Appearance.{e.Groups["name"].Value} nicht gefunden");
            var cases = decl.Groups["cases"].Value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            result[e.Groups["name"].Value] = cases.Select(c => (c, labels[c])).ToList();
        }
        Assert.NotEmpty(result);
        return result;
    }

    static XElement AppearanceTab()
    {
        var doc = XDocument.Load(Repo("windows", "KlimacontrolTray", "SettingsWindow.xaml"));
        return doc.Descendants().Single(e => e.Name.LocalName == "TabItem"
            && (string?)e.Attribute("Header") is "Darstellung" or "{l:T settings.tabs.appearance}");
    }

    /// Anzeige passt zum Schlüssel: `{l:T schlüssel}` oder (Übergang) der deutsche Katalogtext.
    static void AssertShows(string key, string? shown, string where)
    {
        Assert.NotNull(shown);
        if (shown!.Trim() == "{l:T " + key + "}") return;
        if (Catalog.Available) Assert.True(shown == Catalog.Text(key, "de"), $"{where}: „{shown}“ statt {{l:T {key}}}");
    }

    static XElement Named(XElement root, string name) =>
        root.Descendants().Single(e => (string?)e.Attribute(X + "Name") == name);

    [Fact]
    public void AuswahllistenHabenTexteUndReihenfolgeWieAmMac()
    {
        var mac = MacEnums();
        var tab = AppearanceTab();
        foreach (var (box, enumName) in Boxes)
        {
            var items = Named(tab, box).Elements().Where(e => e.Name.LocalName == "ComboBoxItem").ToList();
            Assert.True(mac.ContainsKey(enumName), $"Appearance.{enumName} fehlt im Kern");
            Assert.Equal(mac[enumName].Select(c => c.Value), items.Select(i => (string)i.Attribute("Tag")!));
            for (var n = 0; n < items.Count; n++)
                AssertShows(mac[enumName][n].Key, (string?)items[n].Attribute("Content"), box + " " + mac[enumName][n].Value);
        }
    }

    [Fact]
    public void ThemenUndFarbtupferWieAmMac()
    {
        var mac = MacEnums();
        var tab = AppearanceTab();
        var radios = tab.Descendants().Where(e => e.Name.LocalName == "RadioButton").ToList();

        var themes = radios.Where(r => ((string?)r.Attribute("Style"))?.Contains("ThemeTile") == true).ToList();
        Assert.Equal(mac["Theme"].Select(c => c.Value), themes.Select(r => (string)r.Attribute("Tag")!));
        for (var n = 0; n < themes.Count; n++)
            // Der Name der Kachel entsteht in SettingsWindow.Appearance.cs aus "appearance.theme." + Tag.
            Assert.Equal("appearance.theme." + mac["Theme"][n].Value, mac["Theme"][n].Key);

        var swatches = radios.Where(r => ((string?)r.Attribute("Style"))?.Contains("Swatch") == true).ToList();
        Assert.Equal(mac["CustomColor"].Select(c => c.Value), swatches.Select(r => (string)r.Attribute("Tag")!));
        for (var n = 0; n < swatches.Count; n++)
            AssertShows(mac["CustomColor"][n].Key, (string?)swatches[n].Attribute("ToolTip"), "Farbe " + mac["CustomColor"][n].Value);
    }

    [Fact]
    public void KeinKernnameAlsAnzeige()
    {
        var raw = new HashSet<string>(MacEnums().Values.SelectMany(l => l.Select(c => c.Value)), StringComparer.Ordinal);
        string[] shown = { "Content", "Text", "ToolTip", "Header", "AutomationProperties.Name", "AutomationProperties.HelpText" };
        var offenders = AppearanceTab().DescendantsAndSelf()
            .SelectMany(e => e.Attributes())
            .Where(a => shown.Contains(a.Name.LocalName) && raw.Contains(a.Value.Trim()))
            .Select(a => $"{a.Parent!.Name.LocalName} {a.Name.LocalName}=\"{a.Value}\"")
            .ToList();
        Assert.Empty(offenders);
    }

    [Fact]
    public void ProzentReglerInSchrittenWieAmMac()
    {
        var swift = ReadLf(Repo("Sources", "KlimacontrolCore", "Appearance.swift"));
        double Upper(string range)
        {
            var m = Regex.Match(swift, range + @": ClosedRange<Double> = \d+(?:\.\d+)?\.\.\.(\d+(?:\.\d+)?)");
            Assert.True(m.Success, range + " nicht gefunden");
            return double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
        }
        var panel = ReadLf(Repo("Sources", "KlimacontrolApp", "PanelsAppearance.swift"));
        var stepMatch = Regex.Match(panel, @"Slider\(value: \$value, in: range, step: (\d+(?:\.\d+)?)\)");
        Assert.True(stepMatch.Success, "Schritt des Prozent-Reglers am Mac nicht gefunden");
        var macStep = double.Parse(stepMatch.Groups[1].Value, CultureInfo.InvariantCulture);

        var tab = AppearanceTab();
        var doc = tab.Document!;
        var style = doc.Descendants().Single(e => e.Name.LocalName == "Style" && (string?)e.Attribute(X + "Key") == "LookPercentSlider");
        string Setter(string property) =>
            (string)style.Elements().Single(s => s.Name.LocalName == "Setter" && (string?)s.Attribute("Property") == property).Attribute("Value")!;
        Assert.Equal(macStep * 100, double.Parse(Setter("TickFrequency"), CultureInfo.InvariantCulture), 6);
        Assert.Equal(macStep * 100, double.Parse(Setter("SmallChange"), CultureInfo.InvariantCulture), 6);

        foreach (var (slider, range) in new[] { ("LookTransparency", "transparencyRange"), ("LookGlow", "glowRange") })
        {
            var s = Named(tab, slider);
            Assert.Contains("LookPercentSlider", (string)s.Attribute("Style")!);
            Assert.Equal(Upper(range) * 100, double.Parse((string)s.Attribute("Maximum")!, CultureInfo.InvariantCulture), 6);
        }
    }

    [Theory]
    [InlineData(0.0, "0 %")]
    [InlineData(0.4, "40 %")]
    [InlineData(0.55, "55 %")]
    [InlineData(0.95, "95 %")]
    [InlineData(1.0, "100 %")]
    [InlineData(0.125, "13 %")]   // wie Swift `rounded()`: ,5 weg von null
    public void ProzentWieAmMac(double fraction, string expected) => Assert.Equal(expected, Fmt.Percent(fraction));

    [Theory]
    [InlineData(0.0, "0 pt")]
    [InlineData(20.0, "20 pt")]
    [InlineData(40.0, "40 pt")]
    public void UnschaerfeInPunkt(double blur, string expected) => Assert.Equal(expected, Fmt.Points(blur));
}
