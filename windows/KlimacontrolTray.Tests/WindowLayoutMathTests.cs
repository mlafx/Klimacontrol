using System;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Spalten und Rahmen des Hauptfensters gegen die gemeinsame Tabelle mit dem Kern (`MainWindowLayout`,
/// `MainWindowFrame`); die Zahlen kommen wie in der App aus `options.window` (Vertragsmuster).
public class WindowLayoutMathTests
{
    static string SourceDir([CallerFilePath] string here = "") => Path.GetDirectoryName(here)!;

    static readonly JsonSerializerOptions Camel = new() { PropertyNameCaseInsensitive = true };

    static JsonDocument Table()
    {
        var file = Path.GetFullPath(Path.Combine(SourceDir(), "..", "..", "Tests", "Shared", "main-window-layout-table.json"));
        Assert.True(File.Exists(file), file);
        return JsonDocument.Parse(File.ReadAllText(file));
    }

    static WindowOptions Rules()
    {
        var file = Path.Combine(SourceDir(), "Vertrag", "bridge-muster.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        var w = doc.RootElement.GetProperty("snapshot").GetProperty("options").GetProperty("window").Deserialize<WindowOptions>(Camel)!;
        Assert.True(WindowLayoutMath.Valid(w));
        return w;
    }

    static string Note(JsonElement c) => c.GetProperty("note").GetString() ?? "";

    static SideColumns Visible(JsonElement e) => new(e.GetProperty("history").GetBoolean(), e.GetProperty("diagnostics").GetBoolean());

    static SideColumn Column(string? s) => WindowLayoutMath.ParseColumn(s) ?? throw new InvalidDataException(s);

    static FrameSide Side(JsonElement e) => e.GetString() == "left" ? FrameSide.Left : FrameSide.Right;

    // Die Tabelle rechnet wie AppKit (y nach oben, y = untere Kante). Gespiegelt an y = 0 wird daraus die WPF-Lage
    // (y nach unten, y = obere Kante); x und Breite bleiben.
    static DipRect Flip(DipRect r) => r with { Y = -(r.Y + r.Height) };

    static DipRect Rect(JsonElement e) => Flip(new DipRect(e.GetProperty("x").GetDouble(), e.GetProperty("y").GetDouble(),
                                                           e.GetProperty("width").GetDouble(), e.GetProperty("height").GetDouble()));

    static void Same(DipRect expected, DipRect actual, string note) =>
        Assert.True(Math.Abs(expected.X - actual.X) < 1e-9 && Math.Abs(expected.Y - actual.Y) < 1e-9
                    && Math.Abs(expected.Width - actual.Width) < 1e-9 && Math.Abs(expected.Height - actual.Height) < 1e-9,
                    $"{note}: erwartet {expected}, bekommen {actual}");

    [Fact]
    public void BreitenWieImKern()
    {
        var r = Rules();
        using var doc = Table();
        var cases = doc.RootElement.GetProperty("widths").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var v = Visible(c);
            Assert.True(c.GetProperty("minimum").GetDouble() == WindowLayoutMath.MinimumWidth(r, v), Note(c));
            var w = WindowLayoutMath.Widths(r, c.GetProperty("total").GetDouble(), v);
            var e = c.GetProperty("expected");
            var expected = new ColumnWidths(e.GetProperty("history").GetDouble(), e.GetProperty("control").GetDouble(),
                                            e.GetProperty("diagnostics").GetDouble(), e.GetProperty("margin").GetDouble());
            Assert.True(expected == w, $"{Note(c)}: {w}");
            Assert.True(c.GetProperty("historyGrid").GetBoolean() == WindowLayoutMath.HistoryUsesGrid(r, w.History), Note(c));
        }
    }

    [Fact]
    public void PasstNichtWieImKern()
    {
        var r = Rules();
        using var doc = Table();
        var cases = doc.RootElement.GetProperty("resolve").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var last = c.GetProperty("lastOpened");
            var res = WindowLayoutMath.Resolve(r, Visible(c), c.GetProperty("available").GetDouble(),
                                               last.ValueKind == JsonValueKind.Null ? null : Column(last.GetString()));
            Assert.True(Visible(c.GetProperty("shown")) == res.Shown, $"{Note(c)}: {res.Shown}");
            var hidden = c.GetProperty("hidden").EnumerateArray().Select(h => Column(h.GetString())).ToList();
            Assert.True(hidden.SequenceEqual(res.Hidden), $"{Note(c)}: {string.Join(", ", res.Hidden)}");
        }
    }

    [Fact]
    public void AnbauenWieImKern()
    {
        using var doc = Table();
        var cases = doc.RootElement.GetProperty("grow").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var g = WindowLayoutMath.Grow(Rect(c.GetProperty("frame")), c.GetProperty("minimum").GetDouble(),
                                          Side(c.GetProperty("side")), Rect(c.GetProperty("screen")));
            var e = c.GetProperty("expected");
            if (e.ValueKind == JsonValueKind.Null)
            {
                Assert.True(g == null, Note(c));
                continue;
            }
            Assert.True(g != null, Note(c));
            Same(Rect(e.GetProperty("frame")), g!.Value.Frame, Note(c));
            Assert.True(e.GetProperty("added").GetDouble() == g.Value.Added, Note(c));
        }
    }

    [Fact]
    public void ZuruecknehmenWieImKern()
    {
        using var doc = Table();
        var cases = doc.RootElement.GetProperty("shrink").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
            Same(Rect(c.GetProperty("expected")),
                 WindowLayoutMath.Shrink(Rect(c.GetProperty("frame")), c.GetProperty("amount").GetDouble(),
                                         Side(c.GetProperty("side")), c.GetProperty("minimumWidth").GetDouble()), Note(c));
    }

    [Fact]
    public void KuerzenWieImKern()
    {
        using var doc = Table();
        var cases = doc.RootElement.GetProperty("limitWidth").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
            Same(Rect(c.GetProperty("expected")),
                 WindowLayoutMath.LimitWidth(Rect(c.GetProperty("frame")), c.GetProperty("maximum").GetDouble(),
                                             Side(c.GetProperty("keeping"))), Note(c));
    }

    [Fact]
    public void HoeherWerdenWieImKernObereKanteBleibt()
    {
        using var doc = Table();
        var cases = doc.RootElement.GetProperty("growHeight").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var frame = Rect(c.GetProperty("frame"));
            var screen = Rect(c.GetProperty("screen"));
            var f = WindowLayoutMath.GrowHeight(frame, c.GetProperty("minimum").GetDouble(), screen);
            Same(Rect(c.GetProperty("expected")), f, Note(c));
            // Unter WPF heißt „obere Kante bleibt“: Top unverändert, solange unten Platz ist.
            if (frame.Y + f.Height <= screen.Bottom) Assert.True(f.Y == frame.Y, Note(c));
        }
    }

    [Fact]
    public void AngedocktWieImKern()
    {
        using var doc = Table();
        var cases = doc.RootElement.GetProperty("isConstrained").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
            Assert.True(c.GetProperty("expected").GetBoolean()
                        == WindowLayoutMath.IsConstrained(Rect(c.GetProperty("frame")), Rect(c.GetProperty("screen"))), Note(c));
    }

    [Fact]
    public void MindesthoeheJeGroesse()
    {
        var r = Rules();
        Assert.Equal(r.MinimumHeight.Compact, WindowLayoutMath.MinimumHeight(r, "compact"));
        Assert.Equal(r.MinimumHeight.Normal, WindowLayoutMath.MinimumHeight(r, "normal"));
        Assert.Equal(r.MinimumHeight.Large, WindowLayoutMath.MinimumHeight(r, "large"));
        // Unbekannte Größe aus einer kaputten Einstellung: wie „normal“.
        Assert.Equal(r.MinimumHeight.Normal, WindowLayoutMath.MinimumHeight(r, "riesig"));
    }

    [Fact]
    public void ZuletztGeoeffneteSpalteWieAmMacGespeichert()
    {
        Assert.Equal(SideColumn.History, WindowLayoutMath.ParseColumn("history"));
        Assert.Equal(SideColumn.Diagnostics, WindowLayoutMath.ParseColumn("diagnostics"));
        Assert.Null(WindowLayoutMath.ParseColumn(null));
        Assert.Null(WindowLayoutMath.ParseColumn("Charts"));
        foreach (var c in new[] { SideColumn.History, SideColumn.Diagnostics })
            Assert.Equal(c, WindowLayoutMath.ParseColumn(WindowLayoutMath.ColumnName(c)));
    }

    [Fact]
    public void OhneRegelnVomKernKeineRechnung() => Assert.False(WindowLayoutMath.Valid(new WindowOptions()));
}
