using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Markup;

namespace KlimacontrolTray;

/// Texte der Oberfläche aus dem Katalog des Kerns (kc_strings_json), einmal beim Start geladen.
static class L
{
    /// "de" oder "en" – Sprache der App (nicht die Systemsprache).
    public static string Language { get; private set; } = "de";
    public static bool Pseudo { get; private set; }

    static readonly object Gate = new();
    static Dictionary<string, string> plain = new(StringComparer.Ordinal);
    static Dictionary<string, (string? One, string Other)> plural = new(StringComparer.Ordinal);
    static readonly HashSet<string> missingLogged = new(StringComparer.Ordinal);

    /// Wohin „Text fehlt“ geht (App: Oberflächenprotokoll; Tests setzen eine eigene Senke).
    internal static Action<string> Log { get; set; } = App.Trace;

    static readonly Regex Placeholder = new(@"\{(\w+)\}", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// Liest {"language","pseudo","strings":{Schlüssel: "Text" | {"one":…,"other":…}}}; unlesbar → leer (Trace).
    public static void Load(string json)
    {
        var newPlain = new Dictionary<string, string>(StringComparer.Ordinal);
        var newPlural = new Dictionary<string, (string? One, string Other)>(StringComparer.Ordinal);
        var language = "de";
        var pseudo = false;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("language", out var l) && l.ValueKind == JsonValueKind.String)
                    language = l.GetString() is { Length: > 0 } s ? s : "de";
                if (root.TryGetProperty("pseudo", out var p) && p.ValueKind is JsonValueKind.True or JsonValueKind.False)
                    pseudo = p.GetBoolean();
                if (root.TryGetProperty("strings", out var strings) && strings.ValueKind == JsonValueKind.Object)
                {
                    foreach (var entry in strings.EnumerateObject())
                    {
                        if (entry.Value.ValueKind == JsonValueKind.String)
                            newPlain[entry.Name] = entry.Value.GetString() ?? "";
                        else if (entry.Value.ValueKind == JsonValueKind.Object
                                 && entry.Value.TryGetProperty("other", out var other) && other.ValueKind == JsonValueKind.String)
                        {
                            string? one = entry.Value.TryGetProperty("one", out var o) && o.ValueKind == JsonValueKind.String
                                ? o.GetString() : null;
                            newPlural[entry.Name] = (one, other.GetString() ?? "");
                        }
                    }
                }
            }
        }
        catch (JsonException ex)
        {
            Log("FEHLER Texte nicht lesbar: " + ex.Message);
            newPlain.Clear();
            newPlural.Clear();
        }
        lock (Gate)
        {
            plain = newPlain;
            plural = newPlural;
            missingLogged.Clear();
        }
        Language = language;
        Pseudo = pseudo;
    }

    /// Zustand vor dem Laden (Tests).
    internal static void Reset() => Load("{}");

    /// Text zu `key`; Mehrzahl-Eintrag → "other"; fehlt → der Schlüssel selbst (einmal Trace „Text fehlt“).
    public static string T(string key)
    {
        lock (Gate)
        {
            if (plain.TryGetValue(key, out var text)) return text;
            if (plural.TryGetValue(key, out var forms)) return forms.Other;
            if (missingLogged.Add(key)) Log("Text fehlt: " + key);
        }
        return key;
    }

    /// Mit Platzhaltern {name}: `L.F("settings.general.pricePerKWh", ("currency", "€"))`. Unbekannte Platzhalter bleiben stehen.
    public static string F(string key, params (string Name, string Value)[] args) => Fill(T(key), args);

    /// Mehrzahl: count == 1 → "one", sonst "other" (fehlt "one": "other"); {count} = Fmt.Num(count, 0).
    public static string P(string key, int count, params (string Name, string Value)[] args)
    {
        string text;
        lock (Gate)
        {
            if (plural.TryGetValue(key, out var forms)) text = count == 1 && forms.One != null ? forms.One : forms.Other;
            else if (plain.TryGetValue(key, out var single)) text = single;
            else
            {
                if (missingLogged.Add(key)) Log("Text fehlt: " + key);
                text = key;
            }
        }
        var all = new (string Name, string Value)[args.Length + 1];
        all[0] = ("count", Fmt.Num(count, 0));
        Array.Copy(args, 0, all, 1, args.Length);
        return Fill(text, all);
    }

    /// Text mit Kürzel in Klammern: „Einschalten (Strg+P)“. `shortcut` leer → nur der Text.
    public static string Tip(string key, string shortcut) =>
        shortcut.Length == 0 ? T(key) : F("keys.windows.withShortcut", ("text", T(key)), ("shortcut", shortcut));

    /// Gibt es den Schlüssel im geladenen Katalog (Tests, Rückfälle)?
    internal static bool Has(string key)
    {
        lock (Gate) return plain.ContainsKey(key) || plural.ContainsKey(key);
    }

    static string Fill(string text, (string Name, string Value)[] args)
    {
        if (args.Length == 0 || text.IndexOf('{') < 0) return text;
        // Ein Durchgang: ein eingesetzter Wert wird nicht noch einmal als Platzhalter gelesen.
        return Placeholder.Replace(text, m =>
        {
            foreach (var (name, value) in args)
                if (string.Equals(name, m.Groups[1].Value, StringComparison.Ordinal)) return value;
            return m.Value;
        });
    }
}

/// XAML: Text="{l:T settings.tabs.general}" mit xmlns:l="clr-namespace:KlimacontrolTray".
[MarkupExtensionReturnType(typeof(string))]
public sealed class TExtension : MarkupExtension
{
    public TExtension() { }
    public TExtension(string key) => Key = key;

    [ConstructorArgument("key")]
    public string Key { get; set; } = "";

    public override object ProvideValue(IServiceProvider serviceProvider) => L.T(Key);
}
