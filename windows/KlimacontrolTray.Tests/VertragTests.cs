using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using System.Text.RegularExpressions;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Vertrag Swift ↔ C#: Model.cs ist von Hand aus Bridge.swift gespiegelt; ein umbenanntes Feld fiele sonst still auf
/// Standardwerte. Vertrag/bridge-muster.json enthält jedes DTO-Feld genau einmal und wird von Hand nachgezogen.
/// Geprüft wird in beide Richtungen: kein Musterfeld ist C# unbekannt, und jede beschreibbare C#-Eigenschaft steht im
/// Muster.
public class VertragTests
{
    /// Nicht aus dem Schnappschuss-JSON: setzt Core aus kc_live_json.
    static readonly HashSet<string> CoreOnly = new(StringComparer.OrdinalIgnoreCase)
    {
        "Snapshot.busy", "Snapshot.nextRefresh", "Snapshot.connectionLine", "Snapshot.offTimerChip", "Snapshot.nextRefreshLine",
    };

    static readonly BridgeJson Strict = new(new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    });

    static JsonElement Sample(string part)
    {
        var file = Path.Combine(AppContext.BaseDirectory, "Vertrag", "bridge-muster.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        return doc.RootElement.GetProperty(part).Clone();
    }

    /// Jede beschreibbare Eigenschaft von T (rekursiv in Unterobjekten und Listen) muss im Muster stehen.
    static void AllPropertiesPresent(JsonTypeInfo info, JsonElement sample, string path, List<string> missing)
    {
        if (sample.ValueKind == JsonValueKind.Array)
        {
            if (info.ElementType is { } element && sample.GetArrayLength() > 0)
                AllPropertiesPresent(Strict.GetTypeInfo(element)!, sample[0], path + "[]", missing);
            return;
        }
        if (sample.ValueKind != JsonValueKind.Object || info.Kind != JsonTypeInfoKind.Object) return;
        var keys = sample.EnumerateObject().ToDictionary(p => p.Name, p => p.Value, StringComparer.OrdinalIgnoreCase);
        foreach (var p in info.Properties)
        {
            if (p.Set == null) continue;
            if (CoreOnly.Contains(info.Type.Name + "." + p.Name)) continue;
            if (!keys.TryGetValue(p.Name, out var value)) { missing.Add(path + "." + p.Name); continue; }
            var inner = Nullable.GetUnderlyingType(p.PropertyType) ?? p.PropertyType;
            if (inner.IsPrimitive || inner == typeof(string) || inner == typeof(decimal)) continue;
            if (Strict.GetTypeInfo(inner) is { } t) AllPropertiesPresent(t, value, path + "." + p.Name, missing);
        }
    }

    static void Check<T>(string part, JsonTypeInfo<T> info)
    {
        var sample = Sample(part);
        // Unbekanntes Feld (neu oder umbenannt in Bridge.swift) → JsonException mit dem Feldnamen.
        var value = JsonSerializer.Deserialize(sample.GetRawText(), info);
        Assert.NotNull(value);
        var missing = new List<string>();
        AllPropertiesPresent(info, sample, part, missing);
        Assert.True(missing.Count == 0, "In C# vorhanden, im Muster (Bridge.swift) nicht: " + string.Join(", ", missing));
    }

    [Fact] public void SchnappschussPasstFeldFuerFeld() => Check("snapshot", Strict.Snapshot);
    [Fact] public void LiveWertePassen() => Check("live", Strict.LiveInfo);
    [Fact] public void VerlaufPasst() => Check("history", Strict.ListSample);
    [Fact] public void KennzahlenPassen() => Check("stats", Strict.HistoryStats);
    [Fact] public void LizenzhinweisePassen() => Check("notices", Strict.ListNoticeInfo);

    [Fact]
    public void SchnappschussWerteKommenAn()
    {
        var s = JsonSerializer.Deserialize(Sample("snapshot").GetRawText(), Strict.Snapshot)!;
        Assert.Equal(Native.ExpectedApi, s.ApiVersion);
        Assert.Equal("111122223333444", s.DeviceId);
        Assert.Equal(6444, s.Port);
        Assert.Equal(410.0, s.State?.PowerWatts);
        Assert.Equal(123.45, s.State?.TotalKWh);
        Assert.Equal(2.4, s.TodayKWh);
        Assert.False(s.HistoryCSV);
        Assert.Equal(7, s.HistoryRevision);
        Assert.Equal(254, s.Setup.SubnetTotal);
        Assert.Equal("Schlüssel fehlt.", s.Setup.Manual.Problems["key"]);
        Assert.Equal(3, s.Setup.Discovered[0].Version);
        Assert.Equal(620.0, JsonSerializer.Deserialize(Sample("stats").GetRawText(), Strict.HistoryStats)!.PeakWatts);
    }

    [Fact]
    public void AnzeigeKatalogKommtAn()
    {
        var s = JsonSerializer.Deserialize(Sample("snapshot").GetRawText(), Strict.Snapshot)!;
        var o = s.Options;
        Assert.Equal(16, o.Temperature.Min);
        Assert.Equal(30, o.Temperature.Max);
        Assert.Equal("5 Sekunden", o.Refresh.Choices[0].Label);
        Assert.Equal(5, o.Refresh.Choices[0].Seconds);
        Assert.Equal((1, 600, 8), (o.Refresh.Min, o.Refresh.Max, o.Refresh.WarnBelow));
        Assert.Equal(new[] { 100, 75, 50 }, o.Rate.Choices);
        Assert.Equal(100, o.Rate.Fallback);
        Assert.Equal((2, 4), (o.Price.FractionDigitsMin, o.Price.FractionDigitsMax));
        Assert.Equal(60, o.OffTimerChoices[1].Minutes);
        Assert.Equal("Leise", o.Fan.Marks[1].Label);
        Assert.Equal(60, o.Fan.AutoKnob);
        Assert.Equal((128, 64, 6444), (o.Credentials.TokenLength, o.Credentials.KeyLength, o.Credentials.DefaultPort));
        Assert.Equal(21600, o.Chart.DefaultRange);
        Assert.Equal((600, 3.0, 180.0), (o.Chart.WindowCount, o.Chart.GapFactor, o.Chart.GapMinSeconds));
        Assert.Equal("auto", o.ConnectionModes[0].Id);
        Assert.Equal("searching", o.ConnectSteps[0].Phase);
        Assert.Contains("iCloud", o.CloudFolder.Markers);
        Assert.Contains("{folder}", o.CloudFolder.MessageTemplate);
        Assert.True(o.Prompts.AccountRemove.Warning);
        Assert.False(o.Prompts.SelfClean.Warning);
        Assert.Equal("Erst sichern …", o.Prompts.Forget.Backup);
        Assert.False(o.Prompts.Forget.Warning);
        Assert.True(o.Prompts.ForgetNeedsBackup.Warning);
        Assert.Equal("Midea-Konto fehlt", o.Prompts.CloudNeedsAccount.Title);
        Assert.Equal(new[] { "day", "week" }, o.Energy.Kinds.Select(k => k.Id));
        Assert.Equal((14, 8), (o.Energy.Kinds[0].Count, o.Energy.Kinds[1].Count));
        Assert.Equal("day", o.Energy.DefaultKind);
        Assert.All(new[] { o.Energy.Title, o.Energy.Help, o.Energy.Legend, o.Energy.NoData }, t => Assert.NotEmpty(t));
        Assert.Equal("Angemeldet und gespeichert.", o.Texts.AccountSignedIn);
        Assert.Equal("Klimacontrol-Verlauf.csv", o.Texts.ExportHistoryFileName);
        Assert.All(new[]
        {
            o.Texts.UpdatesHelp, o.Texts.UpdatesChecking, o.Texts.UpdatesCurrent, o.Texts.UpdatesInstallingTemplate,
            o.Texts.UpdatesFailed, o.Texts.UpdatesCheckButton,
        }, t => Assert.NotEmpty(t));
        Assert.Contains("{version}", o.Texts.UpdatesInstallingTemplate);
    }

    /// Die Update-Suche ist nicht abschaltbar: kein Haken in den Einstellungen, in Updates.cs wird die automatische
    /// Suche nur mit der Konstanten 1 gesetzt und es gibt keinen Zugriff darauf von außen.
    [Fact]
    public void UpdateSucheIstNichtAbschaltbar()
    {
        var dir = TrayDir();
        if (!Directory.Exists(dir)) return;
        var updates = File.ReadAllText(Path.Combine(dir, "Updates.cs"));
        Assert.DoesNotContain("AutomaticCheck", updates);
        var calls = Regex.Matches(updates, @"win_sparkle_set_automatic_check_for_updates""\)\(([^)]*)\)");
        Assert.NotEmpty(calls);
        Assert.All(calls.Select(m => m.Groups[1].Value), v => Assert.Equal("1", v));
        Assert.Contains("SkipThisVersion", updates);
        Assert.Contains("win_sparkle_check_update_without_ui", updates);
        foreach (var file in Directory.EnumerateFiles(dir, "SettingsWindow*").Where(f => f.EndsWith(".cs") || f.EndsWith(".xaml")))
        {
            var text = File.ReadAllText(file);
            Assert.DoesNotContain("UpdateAutoBox", text);
            Assert.DoesNotContain("Updates.AutomaticCheck", text);
        }
    }

    [Fact]
    public void TexteUndRegelnAusDemKernKommenAn()
    {
        var s = JsonSerializer.Deserialize(Sample("snapshot").GetRawText(), Strict.Snapshot)!;
        // Gültigkeit je Modus samt Kurzinfo; ein unbekannter Schalter gilt, ohne Eintrag keine Kurzinfo.
        Assert.False(s.IsEnabled("freezeProtection"));
        Assert.True(s.IsEnabled("swing"));
        Assert.True(s.IsEnabled("gibtEsNicht"));
        Assert.Equal("Lamellen schwenken auf und ab", s.Why("swing"));
        Assert.Null(s.Why("purifier"));
        Assert.Null(s.Why("gibtEsNicht"));
        Assert.Equal("live", s.UiConnectionState);
        Assert.Equal("Stand 14:32 · nicht aktuell", s.StaleText);
        Assert.Equal("24°", s.HeroValue);
        Assert.Equal("0,84 €", s.CostLine.Value);
        Assert.Equal("Kosten heute", s.CostLine.Title);
        Assert.True(s.ConnectionStatus.Connected);
        Assert.Equal(new[] { "Raum 25,5°", "Außen 29,0°" }, s.StartupValues!.Extras);
        Assert.Null(s.NoticeDetail!.Code);
        Assert.False(s.AppearanceIsStandard);
        Assert.Equal("Trotzdem beenden", s.QuitPrompt!.Confirm);
        var news = s.WhatsNew!;
        Assert.Equal("Neu in Klimacontrol 1.0.1.2", news.Title);
        Assert.Equal("OK", news.Ok);
        Assert.Equal("Hinzugefügt", news.Versions[0].Sections[0].Title);
        Assert.Equal(2, news.Versions[0].Sections[0].Items.Count);
        Assert.Equal("Mittel · 60 %", s.FanCaption);
        Assert.Single(s.MaintenanceHints);
        Assert.Equal("Anlage wechseln", s.ImportResult!.Prompt!.Confirm);
        Assert.Equal("Die Sicherung gehört zu einer anderen Anlage.", s.ImportResult.Text);
        var prompt = s.Setup.Completion!.Prompt!;
        Assert.Equal("Sichern …", prompt.Primary);
        Assert.Equal("Später", prompt.Secondary);
        Assert.NotNull(prompt.LanOnlyChoice);
        Assert.StartsWith("Verlauf gespeichert", s.ExportText);
    }

    [Fact]
    public void ZeitabhaengigeTexteStehenImLiveTeil()
    {
        var live = JsonSerializer.Deserialize(Sample("live").GetRawText(), Strict.LiveInfo)!;
        Assert.Equal("Verbunden über WLAN · gerade aktualisiert", live.ConnectionLine);
        Assert.Equal("Aus in 1 h", live.OffTimerChip);
        Assert.StartsWith("Live aus der Anlage", live.NextRefreshLine);
    }

    static string TrayDir() => Path.GetFullPath(Path.Combine(SourceDir(), "..", "KlimacontrolTray"));

    /// Listen, Grenzen, Rückfragen und Texte, die der Kern liefert, dürfen in der Oberfläche nicht noch einmal stehen
    /// (Kommentare und Model.cs ausgenommen). Ein Treffer heißt: Text aus `Options`/Schnappschuss nehmen.
    [Fact]
    public void OberflaecheHatKeineEigenenListenGrenzenOderRueckfragen()
    {
        var dir = TrayDir();
        if (!Directory.Exists(dir)) return;
        string[] forbidden =
        {
            "\"5 Sekunden\"", "\"10 Sekunden\"", "\"5 Minuten\"", "1 bis 600", "Unter 8 s bleibt", "{ 100, 75, 50 }", "{ 30, 60, 120",
            "Begrenzt die Leistungsaufnahme", "Dauert etwa 15 Minuten", "Dauert länger als üblich", "Lüfter regelt die Anlage selbst",
            "Kosten bei dieser Leistung", "Konto und Passwort werden", "Es gibt schon Szenen", "Beim Wechsel kommt",
            "Suche Anlage im Netz", "Live aus der Anlage", "In OneDrive", "regelt die Anlage beim Trocknen",
            "Raumtemperatur · Anlage aus", "Einschalten mit dem Knopf oben", "Tagesverbrauch unbekannt", "Eigener Wert …", "\"day\"", "\"week\"", "\"month\"", "\"Tage\"", "\"Wochen\"", "\"Monate\"",
        };
        var offenders = new List<string>();
        foreach (var file in Directory.EnumerateFiles(dir, "*.*", SearchOption.AllDirectories)
                     .Where(f => (f.EndsWith(".cs") || f.EndsWith(".xaml")) && Path.GetFileName(f) != "Model.cs"
                                 && !f.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar)
                                 && !f.Contains(Path.DirectorySeparatorChar + "bin" + Path.DirectorySeparatorChar)))
        {
            var number = 0;
            foreach (var line in File.ReadLines(file))
            {
                number++;
                var t = line.TrimStart();
                if (t.StartsWith("//") || t.StartsWith("<!--")) continue;
                foreach (var f in forbidden)
                    if (line.Contains(f, StringComparison.Ordinal)) offenders.Add($"{Path.GetFileName(file)}:{number} „{f}“");
            }
        }
        Assert.True(offenders.Count == 0, "Eigene Kopien von Kern-Texten in der Oberfläche: " + string.Join(", ", offenders));
    }

    [Fact]
    public void VerbrauchAntwortLiestSich()
    {
        const string json = """
            {"kind":"day","summary":"Zusammen 1,2 kWh",
             "periods":[{"start":1000.0,"end":87400.0,"kWh":1.2,"complete":true,"current":false,"label":"Mo","name":"Montag","tooltip":"Montag: 1,2 kWh","costText":"0,36 €"},
                        {"start":87400.0,"end":173800.0,"measuredKWh":0.4,"complete":false,"current":true,"label":"Di","name":"Dienstag","tooltip":"Dienstag: ca. 0,4 kWh","costText":""}]}
            """;
        var r = JsonSerializer.Deserialize(json, Strict.EnergyResult)!;
        Assert.Null(r.Error);
        Assert.Equal(1.2, r.Periods[0].KWh);
        Assert.Null(r.Periods[0].MeasuredKWh);
        Assert.Equal(0.4, r.Periods[1].Shown);
        Assert.True(r.Periods[1].Current);
        Assert.Equal("Montag: 1,2 kWh", r.Periods[0].Tooltip);
        Assert.Equal("Fehler", JsonSerializer.Deserialize("{\"error\":\"Fehler\"}", Strict.EnergyResult)!.Error);
    }

    [Fact]
    public void UnbekanntesFeldFaelltAuf()
    {
        // Gegenprobe: Ohne Disallow würde ein umbenanntes Feld still ignoriert.
        var ex = Assert.Throws<JsonException>(() =>
            JsonSerializer.Deserialize("{\"configured\":true,\"connectPhaseNeu\":1}", Strict.Snapshot));
        Assert.Contains("connectPhaseNeu", ex.Message);
    }

    static string SourceDir([CallerFilePath] string here = "") => Path.GetDirectoryName(here)!;

    [Fact]
    public void SchnittstellenVersionWieInBridgeSwift()
    {
        // Liegen die Quellen nicht daneben (Tests anderswo gebaut), lässt sich das nicht prüfen.
        var bridge = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "Sources", "KlimacontrolBridge", "Bridge.swift"));
        if (!File.Exists(bridge)) return;
        var m = Regex.Match(File.ReadAllText(bridge), @"let\s+bridgeAPIVersion\s*:\s*Int32\s*=\s*(\d+)");
        Assert.True(m.Success, "bridgeAPIVersion nicht in Bridge.swift gefunden");
        Assert.Equal(Native.ExpectedApi, int.Parse(m.Groups[1].Value));
        Assert.Equal(Native.ExpectedApi, Sample("snapshot").GetProperty("apiVersion").GetInt32());
    }

    /// Jeder Befehlsname in `Cmd` ist eindeutig und steht in der Befehlstabelle der Bridge
    /// (Sources/KlimacontrolBridge/*.swift, Einträge `.device("befehl")` bzw. `.always("befehl")`; die Gegenrichtung
    /// prüft der Swift-Test `BridgeCommandTests`).
    [Fact]
    public void BefehlsnamenGibtEsInDerBridge()
    {
        var names = typeof(Cmd).GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
            .Where(f => f.IsLiteral && f.FieldType == typeof(string))
            .Select(f => (string)f.GetRawConstantValue()!)
            .ToList();
        Assert.NotEmpty(names);
        Assert.Equal(names.Count, names.Distinct(StringComparer.Ordinal).Count());
        var bridgeDir = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "Sources", "KlimacontrolBridge"));
        if (!Directory.Exists(bridgeDir)) return;
        var entry = new Regex(@"\.(?:device|always)\(""([A-Za-z]+)""");
        var known = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in Directory.GetFiles(bridgeDir, "*.swift"))
            foreach (Match m in entry.Matches(File.ReadAllText(file)))
                known.Add(m.Groups[1].Value);
        Assert.NotEmpty(known);
        // Leer = alle Namen gefunden; sonst stehen die unbekannten in der Meldung.
        var unknown = names.Where(n => !known.Contains(n)).ToList();
        Assert.Empty(unknown);
    }
}
