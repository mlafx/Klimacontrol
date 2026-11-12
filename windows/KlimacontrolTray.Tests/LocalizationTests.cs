using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Katalog des Kerns (l10n/Localizable.xcstrings) für Tests; null, wenn die Quellen nicht daneben liegen.
internal static class Catalog
{
    static string SourceDir([CallerFilePath] string here = "") => Path.GetDirectoryName(here)!;

    static readonly Lazy<Dictionary<string, JsonElement>?> Entries = new(() =>
    {
        var file = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "l10n", "Localizable.xcstrings"));
        if (!File.Exists(file)) return null;
        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        var all = doc.RootElement.GetProperty("strings").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
        // Katalog-Teile (l10n/parts/*.json) gelten wie der Hauptkatalog, bis sie zusammengeführt sind.
        var parts = Path.Combine(Path.GetDirectoryName(file)!, "parts");
        if (Directory.Exists(parts))
            foreach (var part in Directory.GetFiles(parts, "*.json").OrderBy(f => f, StringComparer.Ordinal))
            {
                using var d = JsonDocument.Parse(File.ReadAllText(part));
                if (!d.RootElement.TryGetProperty("strings", out var strings)) continue;
                foreach (var p in strings.EnumerateObject()) all[p.Name] = p.Value.Clone();
            }
        return all;
    });

    public static bool Available => Entries.Value != null;

    public static bool Has(string key) => Entries.Value!.ContainsKey(key);

    /// Text einer Sprache; bei Mehrzahl-Einträgen „other“. null, wenn es die Sprache nicht gibt.
    public static string? Text(string key, string language, bool other = true)
    {
        if (!Entries.Value!.TryGetValue(key, out var entry)) return null;
        if (!entry.TryGetProperty("localizations", out var loc) || !loc.TryGetProperty(language, out var l)) return null;
        if (l.TryGetProperty("stringUnit", out var unit)) return unit.GetProperty("value").GetString();
        if (l.TryGetProperty("variations", out var v) && v.GetProperty("plural").TryGetProperty(other ? "other" : "one", out var form))
            return form.GetProperty("stringUnit").GetProperty("value").GetString();
        return null;
    }

    public static bool IsPlural(string key) =>
        Entries.Value!.TryGetValue(key, out var e) && e.TryGetProperty("localizations", out var loc)
        && loc.EnumerateObject().Any(p => p.Value.TryGetProperty("variations", out _));
}

/// Verändert Texte und Format des Prozesses: nie gleichzeitig mit anderen Klassen.
[Collection("Global")]
public class LocalizationTests : IDisposable
{
    public LocalizationTests() => L.Log = _ => { };

    public void Dispose()
    {
        L.Reset();
        Fmt.Profile = FormatProfile.Germany;
        L.Log = App.Trace;
    }

    const string Table = """
        {"language":"en","pseudo":false,"strings":{
          "a.plain":"Hello",
          "a.named":"{name} has {n} items {name}",
          "a.count":{"one":"{count} day","other":"{count} days"},
          "a.onlyOther":{"other":"{count} things"},
          "keys.windows.withShortcut":"{text} ({shortcut})"
        }}
        """;

    // --- L ---

    [Fact]
    public void TextWirdGeladenUndGefunden()
    {
        L.Load(Table);
        Assert.Equal("en", L.Language);
        Assert.False(L.Pseudo);
        Assert.Equal("Hello", L.T("a.plain"));
        Assert.True(L.Has("a.plain"));
    }

    [Fact]
    public void FehlenderSchluesselZeigtDenSchluesselUndMeldetEinmal()
    {
        var lines = new List<string>();
        L.Log = lines.Add;
        L.Load(Table);
        Assert.Equal("gibt.es.nicht", L.T("gibt.es.nicht"));
        Assert.Equal("gibt.es.nicht", L.T("gibt.es.nicht"));
        Assert.Single(lines, l => l.Contains("gibt.es.nicht"));
    }

    [Fact]
    public void MehrzahlEintragGiltBeiTAlsOther()
    {
        L.Load(Table);
        Assert.Equal("{count} days", L.T("a.count"));
    }

    [Fact]
    public void PlatzhalterWerdenWoertlichErsetztUnbekannteBleiben()
    {
        L.Load(Table);
        Assert.Equal("Ann has {n} items Ann", L.F("a.named", ("name", "Ann")));
        // Ein eingesetzter Wert wird nicht noch einmal gelesen.
        Assert.Equal("{n} has 3 items {n}", L.F("a.named", ("name", "{n}"), ("n", "3")));
    }

    [Fact]
    public void MehrzahlWaehltNachZahlUndFuelltCountMitProfil()
    {
        L.Load(Table);
        Assert.Equal("1 day", L.P("a.count", 1));
        Assert.Equal("2 days", L.P("a.count", 2));
        Assert.Equal("0 days", L.P("a.count", 0));
        Assert.Equal("1 things", L.P("a.onlyOther", 1));
        Fmt.Profile = FormatProfile.UnitedStates;
        Assert.Equal("1,000 days", L.P("a.count", 1000));
        Fmt.Profile = FormatProfile.Germany;
        Assert.Equal("1.000 days", L.P("a.count", 1000));
    }

    [Fact]
    public void UnlesbareTabelleWirdLeer()
    {
        var lines = new List<string>();
        L.Log = lines.Add;
        L.Load(Table);
        L.Load("{kaputt");
        Assert.False(L.Has("a.plain"));
        Assert.Equal("de", L.Language);
        Assert.NotEmpty(lines);
    }

    [Fact]
    public void TipSetztDasKuerzelInKlammern()
    {
        L.Load(Table);
        Assert.Equal("Hello (Ctrl+P)", L.Tip("a.plain", "Ctrl+P"));
        Assert.Equal("Hello", L.Tip("a.plain", ""));
    }

    [Fact]
    public void MarkupErweiterungLiefertDenText()
    {
        L.Load(Table);
        Assert.Equal("Hello", new TExtension("a.plain").ProvideValue(null!));
        Assert.Equal("Hello", new TExtension { Key = "a.plain" }.ProvideValue(null!));
    }

    [Fact]
    public void MarkupErweiterungWirdImXamlAufgeloest()
    {
        L.Load("{\"language\":\"en\",\"strings\":{\"settings.tabs.general\":\"General\"}}");
        string? text = null;
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try
            {
                var block = (TextBlock)XamlReader.Parse(
                    "<TextBlock xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' "
                    + "xmlns:l='clr-namespace:KlimacontrolTray;assembly=Klimacontrol' Text='{l:T settings.tabs.general}'/>");
                text = block.Text;
            }
            catch (Exception ex) { error = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        Assert.Null(error);
        Assert.Equal("General", text);
    }

    // --- FormatProfile ---

    [Theory]
    [InlineData("dd.MM.yyyy", "dd.MM.")]
    [InlineData("d.M.yyyy", "dd.MM.")]
    [InlineData("M/d/yyyy", "MM/dd")]
    [InlineData("dd/MM/yyyy", "dd/MM")]
    [InlineData("yyyy-MM-dd", "MM-dd")]
    [InlineData("yyyy/MM/dd", "MM/dd")]
    [InlineData("d. M. yyyy", "dd. MM.")]
    [InlineData("dd-MM-yy", "dd-MM")]
    [InlineData("ddd, d MMM yyyy", "dd MM")]
    [InlineData("yyyy. MM. dd.", "MM. dd.")]
    public void TagUndMonatAusDemKurzenDatumsmuster(string pattern, string expected) =>
        Assert.Equal(expected, FormatProfile.DayMonthFrom(pattern));

    [Fact]
    public void MusterOhneTagUndMonatGibtNull()
    {
        Assert.Null(FormatProfile.DayMonthFrom("yyyy"));
        Assert.Null(FormatProfile.DayMonthFrom(""));
    }

    [Fact]
    public void ProfilAusDeDeEntsprichtDeutschland()
    {
        var p = FormatProfile.FromCulture(CultureInfo.GetCultureInfo("de-DE"));
        var g = FormatProfile.Germany;
        Assert.Equal((g.LocaleIdentifier, g.DecimalSeparator, g.GroupingSeparator, g.Uses24HourClock, g.DayMonthPattern),
                     (p.LocaleIdentifier, p.DecimalSeparator, p.GroupingSeparator, p.Uses24HourClock, p.DayMonthPattern));
    }

    [Fact]
    public void ProfilAusEnUsUndEnGb()
    {
        var us = FormatProfile.FromCulture(CultureInfo.GetCultureInfo("en-US"));
        Assert.Equal((".", ",", false, "MM/dd", "en_US"), (us.DecimalSeparator, us.GroupingSeparator, us.Uses24HourClock, us.DayMonthPattern, us.LocaleIdentifier));
        var gb = FormatProfile.FromCulture(CultureInfo.GetCultureInfo("en-GB"));
        Assert.Equal((".", ",", true, "dd/MM"), (gb.DecimalSeparator, gb.GroupingSeparator, gb.Uses24HourClock, gb.DayMonthPattern));
    }

    [Theory]
    [InlineData("fr-FR")]
    [InlineData("de-CH")]
    [InlineData("ja-JP")]
    public void ProfilAusAnderenKulturenIstGueltig(string name)
    {
        var p = FormatProfile.FromCulture(CultureInfo.GetCultureInfo(name));
        Assert.InRange(p.DecimalSeparator.Length, 1, 4);
        Assert.InRange(p.GroupingSeparator.Length, 0, 4);
        Assert.Contains("dd", p.DayMonthPattern);
        Assert.Contains("MM", p.DayMonthPattern);
    }

    [Fact]
    public void InvarianteKulturWirdEnUs()
    {
        Assert.Equal("en_US", FormatProfile.FromCulture(CultureInfo.InvariantCulture).LocaleIdentifier);
    }

    // --- Fmt (gleiche Fälle wie FormatProfileTests im Kern) ---

    [Theory]
    [InlineData(0.0, 1, "0,0", "0.0")]
    [InlineData(21.5, 1, "21,5", "21.5")]
    [InlineData(-0.25, 1, "-0,3", "-0.3")]
    [InlineData(1.005, 2, "1,00", "1.00")]
    [InlineData(999.995, 2, "1.000,00", "1,000.00")]
    [InlineData(1234.5, 1, "1.234,5", "1,234.5")]
    [InlineData(-1234.567, 2, "-1.234,57", "-1,234.57")]
    [InlineData(1000000.0, 0, "1.000.000", "1,000,000")]
    public void ZahlenNachProfil(double v, int digits, string german, string american)
    {
        Assert.Equal(german, Fmt.Num(v, digits, FormatProfile.Germany));
        Assert.Equal(american, Fmt.Num(v, digits, FormatProfile.UnitedStates));
    }

    [Fact]
    public void AndereTrennzeichen()
    {
        var p = FormatProfile.Germany with { GroupingSeparator = " " };
        Assert.Equal("1 234,5", Fmt.Num(1234.5, 1, p));
        p = p with { GroupingSeparator = "" };
        Assert.Equal("1234,5", Fmt.Num(1234.5, 1, p));
    }

    [Fact]
    public void EinheitenUndGeld()
    {
        Assert.Equal("21,5°", Fmt.Temp(21.5));
        Assert.Equal("22°", Fmt.Target(21.6));
        Assert.Equal("410 W", Fmt.Watts(410));
        Assert.Equal("1,23 kWh", Fmt.Kwh(1.234));
        Assert.Equal("0,30 CHF", Fmt.Money(0.3, "CHF"));
        Assert.Equal("–", Fmt.Money(null, "€"));
        Assert.Equal("–", Fmt.Temp(null));
        Fmt.Profile = FormatProfile.UnitedStates;
        Assert.Equal("12.50 $", Fmt.Money(12.5, "$"));
    }

    [Theory]
    [InlineData(14, 32, "14:32", "2:32 PM")]
    [InlineData(0, 5, "00:05", "12:05 AM")]
    [InlineData(12, 0, "12:00", "12:00 PM")]
    public void Uhrzeit(int h, int m, string german, string american)
    {
        var d = new DateTime(2026, 11, 3, h, m, 0);
        Assert.Equal(german, Fmt.Clock(d, FormatProfile.Germany));
        Assert.Equal(american, Fmt.Clock(d, FormatProfile.UnitedStates));
    }

    [Fact]
    public void UhrzeitMitLeeremZeichenNimmtAmPm()
    {
        var p = FormatProfile.UnitedStates with { AmSymbol = "", PmSymbol = "" };
        Assert.Equal("2:32 PM", Fmt.Clock(new DateTime(2026, 11, 3, 14, 32, 0), p));
        Assert.Equal("9:05 AM", Fmt.Clock(new DateTime(2026, 11, 3, 9, 5, 0), p));
    }

    [Theory]
    [InlineData("dd.MM.", "03.11.")]
    [InlineData("MM/dd", "11/03")]
    [InlineData("M/d", "11/3")]
    [InlineData("d. MMM", "3. 11")]
    [InlineData("'Tag' d", "Tag 3")]
    public void TagUndMonatNachMuster(string pattern, string expected) =>
        Assert.Equal(expected, Fmt.DayMonth(new DateTime(2026, 11, 3, 10, 0, 0), FormatProfile.Germany with { DayMonthPattern = pattern }));

    [Fact]
    public void ClockOfZeigtDieUhrzeitImProfil()
    {
        Assert.Equal("07:30", Fmt.ClockOf(7, 30));
        Fmt.Profile = FormatProfile.UnitedStates;
        Assert.Equal("7:30 AM", Fmt.ClockOf(7, 30));
    }

    [Fact]
    public void WochentagUndVorKurzemAusDemKatalog()
    {
        L.Load("{\"strings\":{\"date.weekdayShort.tue\":\"Tue\",\"common.ago.never\":\"not read yet\","
               + "\"common.ago.seconds\":\"{seconds} s ago\",\"common.ago.minutes\":\"{minutes} min ago\",\"common.atTime\":\"at {time}\"}}");
        Assert.Equal("Tue", Fmt.WeekdayShort(new DateTime(2026, 11, 3)));
        Assert.Equal("not read yet", Fmt.Ago(null));
        var now = Codes.Epoch(DateTime.Now);
        Assert.EndsWith(" s ago", Fmt.Ago(now - 5));
        Assert.EndsWith(" min ago", Fmt.Ago(now - 300));
        Assert.StartsWith("at ", Fmt.Ago(now - 7200));
    }

    // --- Eingaben ---

    [Theory]
    [InlineData("0,30", 0.30)]
    [InlineData("0.30", 0.30)]
    [InlineData("1.234,5", 1234.5)]
    [InlineData("1,234.5", 1234.5)]
    [InlineData("1 000", 1000.0)]
    [InlineData("1 000,5", 1000.5)]
    [InlineData("  12 ", 12.0)]
    [InlineData("1.234.567", 1234567.0)]
    public void ZahlenEingabe(string text, double expected)
    {
        foreach (var profile in new[] { FormatProfile.Germany, FormatProfile.UnitedStates })
        {
            Fmt.Profile = profile;
            Assert.True(Fmt.ParseNumber(text, out var v), text);
            Assert.Equal(expected, v, 9);
        }
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("")]
    [InlineData("NaN")]
    public void ZahlenEingabeAbgelehnt(string text) => Assert.False(Fmt.ParseNumber(text, out _));

    [Fact]
    public void ZahlenEingabeNimmtDasGruppenzeichenDesProfils()
    {
        Fmt.Profile = FormatProfile.Germany with { GroupingSeparator = "’" };
        Assert.True(Fmt.ParseNumber("1’234,5", out var v));
        Assert.Equal(1234.5, v);
    }

    [Theory]
    [InlineData("7:30", 7, 30)]
    [InlineData("07:30", 7, 30)]
    [InlineData("23:59", 23, 59)]
    [InlineData("0:00", 0, 0)]
    [InlineData("7:30 PM", 19, 30)]
    [InlineData("7:30pm", 19, 30)]
    [InlineData("12:15 AM", 0, 15)]
    [InlineData("12:15 pm", 12, 15)]
    [InlineData("11:00 am", 11, 0)]
    public void UhrzeitEingabe(string text, int hour, int minute)
    {
        Assert.True(Fmt.ParseTime(text, out var h, out var m), text);
        Assert.Equal((hour, minute), (h, m));
    }

    [Theory]
    [InlineData("24:00")]
    [InlineData("7:60")]
    [InlineData("13:00 PM")]
    [InlineData("0:30 AM")]
    [InlineData("7:30 xx")]
    [InlineData("730")]
    [InlineData("")]
    public void UhrzeitEingabeAbgelehnt(string text) => Assert.False(Fmt.ParseTime(text, out _, out _));

    [Fact]
    public void UhrzeitEingabeMitZeichenDesProfils()
    {
        Fmt.Profile = FormatProfile.Germany with { AmSymbol = "vorm.", PmSymbol = "nachm." };
        Assert.True(Fmt.ParseTime("7:30 nachm.", out var h, out var m));
        Assert.Equal((19, 30), (h, m));
    }

    [Fact]
    public void RundungstabelleStimmtMitDemKernUeberein()
    {
        var file = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "Tests", "Shared", "rounding-table.json"));
        Assert.True(File.Exists(file), file);
        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        var rows = doc.RootElement.GetProperty("rows").EnumerateArray().ToList();
        Assert.NotEmpty(rows);
        foreach (var r in rows)
        {
            var value = r.GetProperty("value").GetDouble();
            var digits = r.GetProperty("digits").GetInt32();
            Assert.Equal(r.GetProperty("de").GetString(), Fmt.Num(value, digits, FormatProfile.Germany));
            Assert.Equal(r.GetProperty("en").GetString(), Fmt.Num(value, digits, FormatProfile.UnitedStates));
        }
    }

    [Theory]
    [InlineData("h:mm tt", true)]
    [InlineData("hh:mm tt", true)]
    [InlineData("HH:mm", false)]
    [InlineData("H:mm", false)]
    [InlineData("HH'h'mm", false)]
    [InlineData("HH \"h\" mm", false)]
    [InlineData("HH \\h mm", false)]
    [InlineData("tt h:mm", true)]
    [InlineData("HH 'Uhr'", false)]
    public void ZwoelfStundenErkennung(string pattern, bool twelve) => Assert.Equal(twelve, FormatProfile.Uses12Hours(pattern));

    [Theory]
    [InlineData("7:30 p. m.", 19, 30)]
    [InlineData("7:30 P.M.", 19, 30)]
    [InlineData("12:05 a. m.", 0, 5)]
    [InlineData("7:30  p.  m.", 19, 30)]
    public void UhrzeitEingabeMitPunktenUndLeerzeichen(string text, int hour, int minute)
    {
        Assert.True(Fmt.ParseTime(text, out var h, out var m), text);
        Assert.Equal((hour, minute), (h, m));
    }

    [Fact]
    public void UhrzeitEingabeMitSpanischenZeichenDesProfils()
    {
        Fmt.Profile = FormatProfile.UnitedStates with { AmSymbol = "a. m.", PmSymbol = "p. m." };
        Assert.True(Fmt.ParseTime("7:30 p.m.", out var h, out var m));
        Assert.Equal((19, 30), (h, m));
        Assert.True(Fmt.ParseTime("7:30 a. m.", out h, out m));
        Assert.Equal((7, 30), (h, m));
    }

    [Fact]
    public void NeustartNachDreissigSekundenBeendetNichtAlsZweiterStart()
    {
        var restart = StartArgs.Parse(new[] { "--restart" });
        Assert.False(restart.IsSecondStart(ownsMutex: false, eventsCreated: true));
        Assert.False(restart.IsSecondStart(ownsMutex: true, eventsCreated: true));
        var normal = StartArgs.Parse(Array.Empty<string>());
        Assert.True(normal.IsSecondStart(ownsMutex: false, eventsCreated: true));
        Assert.True(normal.IsSecondStart(ownsMutex: true, eventsCreated: false));
        Assert.False(normal.IsSecondStart(ownsMutex: true, eventsCreated: true));
    }

    [Fact]
    public void GefundeneAnlageOhneSeriennummerZeigtDasProtokoll()
    {
        L.Load("""{"language":"de","pseudo":false,"strings":{"setup.view.found.lan":"{ip} · Protokoll V{version} · SN …{serial}","setup.view.found.cloudOnline":"über Midea-Konto · online"}}""");
        var lan = new FoundDevice { Ip = "192.168.1.40", Version = 3, Sn = "" };
        Assert.StartsWith("192.168.1.40 · Protokoll V3", lan.Detail);
        Assert.Equal("192.168.1.40 · Protokoll V3 · SN …12345678", new FoundDevice { Ip = "192.168.1.40", Version = 3, Sn = "000012345678" }.Detail);
        Assert.Equal("über Midea-Konto · online", new FoundDevice { CloudOnly = true, CloudOnline = true }.Detail);
    }

    // --- Start ---

    [Fact]
    public void StartArgumente()
    {
        Assert.Equal(new StartArgs(false, false), StartArgs.Parse(Array.Empty<string>()));
        Assert.Equal(new StartArgs(true, false), StartArgs.Parse(new[] { "--tray" }));
        Assert.Equal(new StartArgs(false, true), StartArgs.Parse(new[] { "--RESTART" }));
        Assert.Equal(new StartArgs(true, true), StartArgs.Parse(new[] { "--restart", "--tray", "x" }));
    }

    static string SourceDir([CallerFilePath] string here = "") => Path.GetDirectoryName(here)!;

    [Fact]
    public void LocaleJsonHatDieNamenAusDemKern()
    {
        var json = Formats.LocaleJson("en-US", FormatProfile.UnitedStates);
        using var mine = JsonDocument.Parse(json);
        Assert.Equal("en-US", mine.RootElement.GetProperty("uiLanguage").GetString());
        var format = mine.RootElement.GetProperty("format");
        Assert.Equal(".", format.GetProperty("decimalSeparator").GetString());
        Assert.False(format.GetProperty("uses24HourClock").GetBoolean());
        Assert.Equal("MM/dd", format.GetProperty("dayMonthPattern").GetString());

        // Beispiel im Kommentar über kc_set_locale in Bridge.swift: gleiche Namen, gleiche Reihenfolge der Ebenen.
        var bridge = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "Sources", "KlimacontrolBridge", "Bridge.swift"));
        Assert.True(File.Exists(bridge), bridge);
        var comment = string.Join(" ", File.ReadAllLines(bridge).Select(l => l.TrimStart()).Where(l => l.StartsWith("///")).Select(l => l[3..].Trim()));
        var m = Regex.Match(comment, @"JSON: `(\{.*?\})`");
        Assert.True(m.Success, "Beispiel für kc_set_locale nicht gefunden");
        using var swift = JsonDocument.Parse(m.Groups[1].Value);
        Assert.Equal(Names(swift.RootElement), Names(mine.RootElement));
        Assert.Equal(Names(swift.RootElement.GetProperty("format")), Names(format));
    }

    static List<string> Names(JsonElement e) => e.EnumerateObject().Select(p => p.Name).OrderBy(n => n, StringComparer.Ordinal).ToList();

    [Fact]
    public void TestKulturKommtAusDerUmgebungsvariable()
    {
        var old = Environment.GetEnvironmentVariable("KLIMACONTROL_CULTURE");
        try
        {
            Environment.SetEnvironmentVariable("KLIMACONTROL_CULTURE", null);
            Assert.Null(Formats.TestCulture());
            Environment.SetEnvironmentVariable("KLIMACONTROL_CULTURE", "en-US");
            Assert.Equal("en-US", Formats.TestCulture()!.Name);
            Environment.SetEnvironmentVariable("KLIMACONTROL_CULTURE", "xx-gibt-es-nicht-!!");
            Assert.Null(Formats.TestCulture());
        }
        finally { Environment.SetEnvironmentVariable("KLIMACONTROL_CULTURE", old); }
    }

    [Fact]
    public void StartTexteSindInBeidenSprachenDa()
    {
        var pairs = typeof(StartupText).GetFields(BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)
            .Where(f => f.FieldType == typeof(StartupText.Pair))
            .Select(f => (f.Name, Pair: (StartupText.Pair)f.GetValue(null)!))
            .ToList();
        Assert.True(pairs.Count >= 5, "Texte vor dem Katalog fehlen");
        foreach (var (name, pair) in pairs)
        {
            Assert.False(string.IsNullOrWhiteSpace(pair.De), name + " (de)");
            Assert.False(string.IsNullOrWhiteSpace(pair.En), name + " (en)");
            Assert.NotEqual(pair.De, pair.En);
            Assert.Equal(Placeholders(pair.De), Placeholders(pair.En));
        }
        Assert.Contains("res", StartupText.Pick(StartupText.FilesMissingText, CultureInfo.GetCultureInfo("de-DE")));
        Assert.Contains("extract", StartupText.Pick(StartupText.StartFailedText, CultureInfo.GetCultureInfo("en-GB")));
        Assert.Contains("manually", StartupText.Pick(StartupText.RestartFailedText, CultureInfo.GetCultureInfo("en-US")));
        Assert.Contains("von Hand", StartupText.Pick(StartupText.RestartFailedText, CultureInfo.GetCultureInfo("de-AT")));
    }

    static List<string> Placeholders(string text) =>
        Regex.Matches(text, @"\{\w+\}").Select(m => m.Value).OrderBy(x => x, StringComparer.Ordinal).ToList();

    // --- Tastennamen ---

    [Fact]
    public void TastennamenAusDemKatalog()
    {
        L.Load("{\"strings\":{\"keys.windows.ctrl\":\"Ctrl\",\"keys.windows.alt\":\"Alt\",\"keys.windows.shift\":\"Shift\","
               + "\"keys.windows.win\":\"Win\",\"keys.windows.space\":\"Space\",\"keys.windows.numpad\":\"Numpad {digit}\"}}");
        Assert.Equal("Ctrl+Alt+K", Hotkeys.Display(ModifierKeys.Control | ModifierKeys.Alt, Key.K));
        Assert.Equal("Ctrl+Shift+Win+1", Hotkeys.Display(ModifierKeys.Control | ModifierKeys.Shift | ModifierKeys.Windows, Key.D1));
        Assert.Equal("Alt+Space", Hotkeys.Display(ModifierKeys.Alt, Key.Space));
        Assert.Equal("Ctrl+Numpad 3", Hotkeys.Display(ModifierKeys.Control, Key.NumPad3));
        Assert.Equal("Ctrl+P", Hotkeys.Ctrl("P"));
        Assert.Equal("Ctrl+Alt+K", NotifyArea.HotkeyDisplay("Ctrl+Alt+K"));
        Assert.Equal("", NotifyArea.HotkeyDisplay(""));
        Assert.Equal("", NotifyArea.HotkeyDisplay("Quatsch"));
    }

    [Fact]
    public void KatalogKenntDieSchluesselDieDieInfrastrukturBraucht()
    {
        Assert.True(Catalog.Available, "Katalog l10n/Localizable.xcstrings fehlt");
        string[] keys =
        {
            "keys.windows.ctrl", "keys.windows.alt", "keys.windows.shift", "keys.windows.win", "keys.windows.withShortcut",
            "app.windows.quitting", "app.windows.uiError", "app.windows.restartFailed", "message.defaultName",
            "mode.cool", "mode.heat", "mode.dry", "mode.fan", "mode.auto", "common.ago.never", "common.ago.seconds",
            "common.ago.minutes", "common.atTime", "setup.view.found.cloudOff", "setup.view.found.cloudOnline",
            "setup.view.found.lan", "mode.verb.cool", "mode.verb.heat", "mode.verb.dry", "mode.verb.fan", "mode.verb.auto",
            "date.weekdayShort.mon", "date.weekdayShort.tue", "date.weekdayShort.wed", "date.weekdayShort.thu",
            "date.weekdayShort.fri", "date.weekdayShort.sat", "date.weekdayShort.sun",
            "keys.windows.numpad", "keys.windows.space", "keys.windows.enter", "keys.windows.backspace", "keys.windows.delete",
            "keys.windows.insert", "keys.windows.home", "keys.windows.end", "keys.windows.pageUp", "keys.windows.pageDown",
        };
        foreach (var key in keys)
        {
            Assert.True(Catalog.Has(key), key);
            Assert.False(string.IsNullOrEmpty(Catalog.Text(key, "de")), key + " (de)");
            Assert.False(string.IsNullOrEmpty(Catalog.Text(key, "en")), key + " (en)");
        }
    }
}
