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
        Assert.True(s.HistoryUnavailable);
    }

    /// Die Update-Suche ist nicht abschaltbar: kein Haken in den Einstellungen, in Updates.cs wird die automatische
    /// Suche nur mit der Konstanten 1 gesetzt und es gibt keinen Zugriff darauf von außen.
    [Fact]
    public void UpdateSucheIstNichtAbschaltbar()
    {
        var dir = TrayDir();
        Assert.True(Directory.Exists(dir), dir);
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
    public void UpdateEinstellungenKommenAn()
    {
        var s = JsonSerializer.Deserialize(Sample("snapshot").GetRawText(), Strict.Snapshot)!;
        Assert.False(s.UpdateAutoInstall);
        Assert.Equal("weekly", s.UpdateInterval);
        Assert.Equal(604800, s.UpdateCheckInterval);
        Assert.Null(s.DebugLogNotice);
        var u = s.Options.Updates;
        Assert.Equal(new[] { "daily", "weekly" }, u.Intervals.Select(i => i.Id));
        Assert.All(new[] { u.AutoInstallTitle, u.AutoInstallHelp, u.IntervalTitle, u.HeldBackTitle, u.InstallNow, u.Later },
                   t => Assert.NotEmpty(t));
        Assert.Contains("{version}", u.HeldBackMessageTemplate);
        Assert.Contains("{version}", u.HeldBackStatusTemplate);
        Assert.Equal(86400, u.ReminderSeconds);
        // Ohne Feld im JSON (älterer Kern) gilt „automatisch installieren“ wie im Kern.
        Assert.True(JsonSerializer.Deserialize("{}", Strict.Snapshot)!.UpdateAutoInstall);
    }

    /// Ein zurückgehaltenes Setup startet mit denselben Schaltern, die der Appcast WinSparkle mitgibt.
    [Fact]
    public void SetupSchalterWieImAppcast()
    {
        var script = File.ReadAllText(Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "tools", "make_release.py")));
        var m = Regex.Match(script, @"^WINDOWS_INSTALLER_ARGS\s*=\s*""([^""]*)""", RegexOptions.Multiline);
        Assert.True(m.Success);
        Assert.Equal(Updates.InstallerArguments, m.Groups[1].Value);
    }

    /// Ohne automatische Installation übernimmt der Rückruf das Setup; die Suche bleibt dabei an.
    [Fact]
    public void RueckrufFuerZurueckgehalteneUpdates()
    {
        var updates = File.ReadAllText(Path.Combine(TrayDir(), "Updates.cs"));
        Assert.Contains("win_sparkle_set_user_run_installer_callback", updates);
        Assert.Contains("win_sparkle_set_update_check_interval", updates);
        Assert.Contains("skipShutdown", updates);
    }

    [Fact]
    public void WinSparkleSpracheKommtAusDerOberflaeche()
    {
        var dir = TrayDir();
        Assert.True(Directory.Exists(dir), dir);
        var updates = File.ReadAllText(Path.Combine(dir, "Updates.cs"));
        var calls = Regex.Matches(updates, @"win_sparkle_set_lang""\)\(([^;]*)\);");
        Assert.NotEmpty(calls);
        Assert.All(calls.Select(m => m.Groups[1].Value), v =>
        {
            Assert.Contains("L.Language", v);
            Assert.DoesNotMatch(@"^\s*""[a-z]*""\s*$", v);
        });
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
        Assert.True(Directory.Exists(dir), dir);
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
                // Namen von Platzhaltern in L.F/L.P („day“, „week“ …) sind keine eigenen Listen.
                var checkedLine = NamedArg.Replace(line, "(");
                foreach (var f in forbidden)
                    if (checkedLine.Contains(f, StringComparison.Ordinal)) offenders.Add($"{Path.GetFileName(file)}:{number} „{f}“");
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
        Assert.True(File.Exists(bridge), bridge);
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
        Assert.True(Directory.Exists(bridgeDir), bridgeDir);
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

    // --- Texte: Katalog, Markup-Erweiterung, Formate (Phase 5) ---

    /// Werte, die auch ohne Katalog stehen dürfen: Markennamen, Einheiten, feste Begriffe.
    static readonly HashSet<string> Allowed = new(StringComparer.Ordinal)
    {
        "Klimacontrol", "PortaSplit", "Midea", "MSmartHome", "Eco", "Turbo", "iECO", "OK", "IP", "Port", "Token", "kWh", "W", "pt",
    };

    static readonly string[] ShownAttributes =
    {
        "Text", "Content", "ToolTip", "Header", "Title", "AutomationProperties.Name", "AutomationProperties.HelpText",
        "AutomationProperties.ItemStatus", "InputGestureText",
    };

    static readonly string[] TextElements = { "TextBlock", "Run", "Hyperlink", "Label" };

    static IEnumerable<string> SourceFiles(params string[] extensions)
    {
        var dir = TrayDir();
        Assert.True(Directory.Exists(dir), dir);
        return Directory.EnumerateFiles(dir, "*.*", SearchOption.AllDirectories)
            .Where(f => extensions.Any(e => f.EndsWith(e, StringComparison.Ordinal))
                        && !f.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar)
                        && !f.Contains(Path.DirectorySeparatorChar + "bin" + Path.DirectorySeparatorChar))
            .OrderBy(f => f, StringComparer.Ordinal);
    }

    static bool HasLetters(string text) => text.Any(char.IsLetter);

    /// Feste Anzeigetexte in XAML: Attribute und Elementtext, die weder Markup noch erlaubt noch ohne Buchstaben sind.
    static List<string> XamlTextFindings()
    {
        var found = new List<string>();
        foreach (var file in SourceFiles(".xaml"))
        {
            var name = Path.GetFileName(file);
            var doc = System.Xml.Linq.XDocument.Load(file);
            foreach (var e in doc.Descendants())
            {
                foreach (var a in e.Attributes())
                {
                    var attribute = a.Name.LocalName;
                    if (!ShownAttributes.Contains(attribute)) continue;
                    var v = a.Value.Trim();
                    if (v.StartsWith('{') || !HasLetters(v) || Allowed.Contains(v)) continue;
                    found.Add($"{name} {e.Name.LocalName}.{attribute}=\"{v}\"");
                }
                if (TextElements.Contains(e.Name.LocalName) && !e.HasElements)
                {
                    var v = e.Value.Trim();
                    if (v.Length == 0 || v.StartsWith('{') || !HasLetters(v) || Allowed.Contains(v)) continue;
                    found.Add($"{name} <{e.Name.LocalName}>{v}");
                }
            }
        }
        return found;
    }

    static readonly Regex GermanWord = new(
        @"[äöüÄÖÜß„“]|\b(?:der|die|das|und|nicht|ist|mit|für|bei|von|zum|zur|Anlage|Einstellungen|Verlauf|Fenster|Abbrechen|Beenden|Schließen|Strg|Umschalt|heute|morgen|Uhr|Aus|Ein)\b",
        RegexOptions.CultureInvariant);

    static readonly Regex LogCall = new(@"\b(?:Trace|TraceOnce|Log)\(", RegexOptions.CultureInvariant);

    /// Inhalte der Zeichenkettenliterale einer Codezeile (ohne Kommentar); bei `$"…"` nur die Textteile.
    static List<string> Literals(string line)
    {
        var result = new List<string>();
        var i = 0;
        while (i < line.Length)
        {
            var c = line[i];
            if (c == '/' && i + 1 < line.Length && line[i + 1] == '/') break;
            if (c == '\'')
            {
                // Zeichenliteral: '"' darf keine Zeichenkette öffnen.
                i += i + 2 < line.Length && line[i + 1] == '\\' ? 4 : 3;
                continue;
            }
            var prefix = i;
            var interpolated = false;
            var verbatim = false;
            while (prefix < line.Length && (line[prefix] == '$' || line[prefix] == '@'))
            {
                interpolated |= line[prefix] == '$';
                verbatim |= line[prefix] == '@';
                prefix++;
            }
            if (prefix >= line.Length || line[prefix] != '"') { i = Math.Max(i + 1, prefix); continue; }
            var text = new System.Text.StringBuilder();
            var k = prefix + 1;
            var depth = 0;
            while (k < line.Length)
            {
                var ch = line[k];
                if (depth > 0)
                {
                    if (ch == '{') depth++;
                    else if (ch == '}') depth--;
                    else if (ch == '"')
                    {
                        // verschachtelte Zeichenkette im Ausdruck überspringen
                        var end = line.IndexOf('"', k + 1);
                        k = end < 0 ? line.Length : end;
                    }
                    k++;
                    continue;
                }
                if (ch == '"')
                {
                    if (verbatim && k + 1 < line.Length && line[k + 1] == '"') { text.Append('"'); k += 2; continue; }
                    break;
                }
                if (ch == '\\' && !verbatim) { k += 2; continue; }
                if (interpolated && ch == '{')
                {
                    if (k + 1 < line.Length && line[k + 1] == '{') { text.Append('{'); k += 2; continue; }
                    depth = 1;
                    text.Append(' ');
                    k++;
                    continue;
                }
                text.Append(ch);
                k++;
            }
            result.Add(text.ToString());
            i = k + 1;
        }
        return result;
    }

    /// Feste Anzeigetexte in C#: Literale mit Umlauten, „ “ oder typischen deutschen Wörtern; nicht in Kommentaren und
    /// Protokollaufrufen, nicht in StartupText.cs und BridgeCommands.cs, nicht in Zeilen mit `// kein Anzeigetext`.
    static List<string> CodeTextFindings()
    {
        var found = new List<string>();
        foreach (var file in SourceFiles(".cs"))
        {
            var name = Path.GetFileName(file);
            if (name is "StartupText.cs" or "BridgeCommands.cs") continue;
            var inBlock = false;
            var inLog = false;
            var number = 0;
            foreach (var raw in File.ReadLines(file))
            {
                number++;
                var line = raw;
                if (inBlock)
                {
                    var close = line.IndexOf("*/", StringComparison.Ordinal);
                    if (close < 0) continue;
                    line = line[(close + 2)..];
                    inBlock = false;
                }
                var t = line.TrimStart();
                if (t.StartsWith("//")) continue;
                if (t.StartsWith("/*") && !t.Contains("*/")) { inBlock = true; continue; }
                if (line.Contains("// kein Anzeigetext", StringComparison.Ordinal)) continue;
                if (inLog || LogCall.IsMatch(line))
                {
                    inLog = !line.TrimEnd().EndsWith(';');
                    continue;
                }
                foreach (var literal in Literals(line))
                    if (GermanWord.IsMatch(literal)) found.Add($"{name}:{number} „{literal.Trim()}“");
            }
        }
        return found;
    }

    /// Stand der Umstellung: Zahl der noch festen Texte. Jeder Teilauftrag senkt sie, am Ende steht 0.
    const int Erlaubt = 0;

    [Fact]
    public void OberflaecheOhneDeutscheTexte()
    {
        Assert.True(Directory.Exists(TrayDir()), TrayDir());
        var funde = XamlTextFindings().Concat(CodeTextFindings()).ToList();
        Assert.True(funde.Count <= Erlaubt,
            $"{funde.Count} feste Texte, erlaubt {Erlaubt}. Liegt die Zahl über dem Stand, sind Texte dazugekommen; erste Funde: "
            + string.Join(" | ", funde.Take(40)));
    }

    static readonly Regex XamlKey = new(@"\{l:T\s+([\w.]+)\s*\}", RegexOptions.CultureInvariant);
    static readonly Regex CodeKey = new(@"\bL\.(T|F|P|Tip)\(\s*""([\w.]+)""\s*[,)]", RegexOptions.CultureInvariant);
    static readonly Regex NamedArg = new(@"\(\s*""(\w+)""\s*,", RegexOptions.CultureInvariant);

    [Fact]
    public void TextschluesselStehenImKatalog()
    {
        Assert.True(Catalog.Available, "Katalog l10n/Localizable.xcstrings fehlt");
        var problems = new List<string>();
        void CheckKey(string where, string key)
        {
            if (!Catalog.Has(key)) { problems.Add($"{where}: {key} fehlt im Katalog"); return; }
            foreach (var language in new[] { "de", "en" })
                if (string.IsNullOrEmpty(Catalog.Text(key, language))) problems.Add($"{where}: {key} ohne {language}");
        }
        foreach (var file in SourceFiles(".xaml"))
            foreach (Match m in XamlKey.Matches(File.ReadAllText(file)))
                CheckKey(Path.GetFileName(file), m.Groups[1].Value);
        foreach (var file in SourceFiles(".cs"))
        {
            var name = Path.GetFileName(file);
            var text = string.Join("\n", File.ReadLines(file).Where(l => !l.TrimStart().StartsWith("//")));
            foreach (Match m in CodeKey.Matches(text))
            {
                var kind = m.Groups[1].Value;
                var key = m.Groups[2].Value;
                var where = $"{name} L.{kind}(\"{key}\")";
                CheckKey(where, key);
                if (!Catalog.Has(key)) continue;
                var plural = Catalog.IsPlural(key);
                var end = text.IndexOf(';', m.Index);
                var statement = text[m.Index..(end < 0 ? text.Length : end)];
                var placeholders = new[] { "de", "en" }
                    .SelectMany(l => Regex.Matches(Catalog.Text(key, l) ?? "", @"\{(\w+)\}").Select(x => x.Groups[1].Value))
                    .Distinct().ToList();
                var given = NamedArg.Matches(statement).Select(x => x.Groups[1].Value).ToHashSet();
                if (kind == "P" && !plural) problems.Add($"{where}: kein Mehrzahl-Eintrag");
                if (kind is "T" or "Tip" && plural) problems.Add($"{where}: Mehrzahl-Eintrag, bitte L.P");
                if (kind is "T" or "Tip" && placeholders.Count > 0) problems.Add($"{where}: hat Platzhalter, bitte L.F");
                if (kind is not ("T" or "Tip"))
                    foreach (var ph in placeholders)
                        if (!given.Contains(ph) && !(kind == "P" && ph == "count"))
                            problems.Add($"{where}: Platzhalter {{{ph}}} wird nicht gefüllt");
            }
        }
        Assert.True(problems.Count == 0, "Textschlüssel: " + string.Join(" | ", problems));
    }

    [Fact]
    public void MarkupErweiterungIstUeberallEingebunden()
    {
        var missing = SourceFiles(".xaml")
            .Where(f => File.ReadAllText(f).Contains("{l:T", StringComparison.Ordinal)
                        && !File.ReadAllText(f).Contains("xmlns:l=\"clr-namespace:KlimacontrolTray\"", StringComparison.Ordinal))
            .Select(Path.GetFileName)
            .ToList();
        Assert.True(missing.Count == 0, "Ohne xmlns:l: " + string.Join(", ", missing));
    }

    /// Stand der Umstellung auf `Formats.cs`: Zahl der Zeilen mit eigenem Format (`GetCultureInfo("de-DE")`, "HH:mm",
    /// `CurrentCulture`) außerhalb von Formats.cs und dem Protokoll-Reiter. Wird bis 5g auf 0 gesenkt.
    const int ErlaubteEigeneFormate = 0;

    static List<string> OwnFormatFindings()
    {
        var found = new List<string>();
        foreach (var file in SourceFiles(".cs"))
        {
            var name = Path.GetFileName(file);
            if (name is "Formats.cs" or "SettingsWindow.Log.cs") continue;
            var number = 0;
            foreach (var line in File.ReadLines(file))
            {
                number++;
                if (line.TrimStart().StartsWith("//") || line.Contains("// kein Anzeigetext", StringComparison.Ordinal)) continue;
                if (line.Contains("GetCultureInfo(\"de-DE\")", StringComparison.Ordinal)
                    || line.Contains("HH:mm", StringComparison.Ordinal)
                    || line.Contains("CurrentCulture", StringComparison.Ordinal))
                    found.Add($"{name}:{number} {line.Trim()}");
            }
        }
        return found;
    }

    [Fact]
    public void KeineEigenenFormate()
    {
        Assert.True(Directory.Exists(TrayDir()), TrayDir());
        var funde = OwnFormatFindings();
        Assert.True(funde.Count <= ErlaubteEigeneFormate,
            $"{funde.Count} Stellen mit eigenem Zahlen-/Zeitformat, erlaubt {ErlaubteEigeneFormate}: " + string.Join(" | ", funde));
    }

    [Fact]
    public void KeinBetaSchalterUnterWindows()
    {
        var offenders = SourceFiles(".cs", ".xaml")
            .Where(f => Path.GetFileName(f).StartsWith("SettingsWindow", StringComparison.Ordinal) || Path.GetFileName(f) == "BridgeCommands.cs")
            .Where(f => File.ReadAllText(f).Contains("Beta", StringComparison.Ordinal)
                        || File.ReadAllText(f).Contains("updateBetaChannel", StringComparison.Ordinal))
            .Select(Path.GetFileName)
            .ToList();
        Assert.True(offenders.Count == 0, "Beta-Schalter unter Windows: " + string.Join(", ", offenders));
    }
}
