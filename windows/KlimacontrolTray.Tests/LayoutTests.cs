using System;
using System.Collections.Generic;
using System.Linq;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Innenabstand und Dichte der Steuerspalte, Fenster am Infobereich, gemerkte Lage und Tastenkürzel. Spaltenbreiten
/// und Fensterrahmen prüft `WindowLayoutMathTests` gegen die gemeinsame Tabelle mit dem Kern.
public class LayoutTests
{
    [Theory]
    [InlineData(400, 16)]
    [InlineData(419.9, 16)]
    [InlineData(420, 20)]
    public void SeitenabstandJeSpaltenbreite(double width, double pad) => Assert.Equal(pad, Layout.PadX(width));

    [Fact]
    public void SteuerungFuelltIhreSpalteBisAufDenAbstand()
    {
        Assert.Equal(480 - 40, Layout.ControlsWidth(480));
        Assert.Equal(400 - 32, Layout.ControlsWidth(400));
        Assert.Equal(0, Layout.ControlsWidth(10));
    }

    [Theory]
    [InlineData(700, 740, false)] // 700 + 20 + 20 = 740 passt genau
    [InlineData(701, 740, true)]
    public void KompaktErstWennNormalNichtPasst(double natural, double avail, bool compact) =>
        Assert.Equal(compact, Layout.NeedsCompact(natural, avail));

    // Fenster am Infobereich. Bildschirm 1920×1080, Taskleiste 48 px.

    static readonly PxRect Mon = new(0, 0, 1920, 1080);

    [Theory]
    [InlineData(0, 0, 1920, 1032, "Bottom")]
    [InlineData(0, 48, 1920, 1080, "Top")]
    [InlineData(48, 0, 1920, 1080, "Left")]
    [InlineData(0, 0, 1872, 1080, "Right")]
    public void TaskleisteAusArbeitsbereich(double l, double t, double r, double b, string edge) =>
        Assert.Equal(Enum.Parse<TaskbarEdge>(edge), Layout.EdgeOf(Mon, new PxRect(l, t, r, b), null, null));

    [Fact]
    public void AutomatischAusblendenNimmtNaechsteKanteZumSymbol()
    {
        Assert.Equal(TaskbarEdge.Top, Layout.EdgeOf(Mon, Mon, new PxRect(1800, 5, 1820, 25), TaskbarEdge.Bottom));
        Assert.Equal(TaskbarEdge.Left, Layout.EdgeOf(Mon, Mon, new PxRect(5, 900, 25, 920), null));
        Assert.Equal(TaskbarEdge.Right, Layout.EdgeOf(Mon, Mon, null, TaskbarEdge.Right));
        Assert.Equal(TaskbarEdge.Bottom, Layout.EdgeOf(Mon, Mon, null, null));
    }

    [Fact]
    public void UntenMittigAmSymbolAberNieUeberDenRand()
    {
        var work = new PxRect(0, 0, 1920, 1032);
        Assert.Equal((1000.0 - 200, 1032.0 - 600 - 12), Layout.FlyoutPosition(work, TaskbarEdge.Bottom, new PxRect(990, 1040, 1010, 1060), 400, 600, 12));
        // Symbol ganz rechts: rechtsbündig mit Abstand.
        Assert.Equal((1920.0 - 400 - 12, 1032.0 - 600 - 12), Layout.FlyoutPosition(work, TaskbarEdge.Bottom, new PxRect(1880, 1040, 1900, 1060), 400, 600, 12));
        // Ohne Symbol: Ecke unten rechts.
        Assert.Equal((1920.0 - 400 - 12, 1032.0 - 600 - 12), Layout.FlyoutPosition(work, TaskbarEdge.Bottom, null, 400, 600, 12));
    }

    [Fact]
    public void TaskleisteObenLinksRechts()
    {
        var top = new PxRect(0, 48, 1920, 1080);
        Assert.Equal((1700.0 - 200, 48.0 + 12), Layout.FlyoutPosition(top, TaskbarEdge.Top, new PxRect(1690, 10, 1710, 30), 400, 600, 12));
        var left = new PxRect(48, 0, 1920, 1080);
        Assert.Equal((48.0 + 12, 1080.0 - 600 - 12), Layout.FlyoutPosition(left, TaskbarEdge.Left, new PxRect(10, 1000, 30, 1020), 400, 600, 12));
        Assert.Equal((48.0 + 12, 500.0 - 300), Layout.FlyoutPosition(left, TaskbarEdge.Left, new PxRect(10, 490, 30, 510), 400, 600, 12));
        var right = new PxRect(0, 0, 1872, 1080);
        Assert.Equal((1872.0 - 400 - 12, 1080.0 - 600 - 12), Layout.FlyoutPosition(right, TaskbarEdge.Right, null, 400, 600, 12));
    }

    [Fact]
    public void ZweiterBildschirmLinksMitNegativenKoordinaten()
    {
        // Bildschirm links vom Hauptbildschirm, 150 % (Pixelmaße schon skaliert): bleibt auf diesem Bildschirm.
        var work = new PxRect(-2560, 0, 0, 1380);
        var (x, y) = Layout.FlyoutPosition(work, TaskbarEdge.Bottom, new PxRect(-100, 1390, -70, 1420), 600, 900, 18);
        Assert.Equal(-600 - 18, x);
        Assert.Equal(1380 - 900 - 18, y);
    }

    [Fact]
    public void ZuHochBleibtObenBuendig() =>
        Assert.Equal(12, Layout.FlyoutPosition(new PxRect(0, 0, 1920, 700), TaskbarEdge.Bottom, null, 400, 900, 12).Y);

    // Gemerkte Lage des Hauptfensters.

    static readonly PxRect[] TwoScreens = { new(0, 0, 1920, 1032), new(1920, 0, 4480, 1392) };

    [Fact]
    public void GemerkteLageBleibtWennSichtbar() =>
        Assert.Equal(new PxRect(2000, 100, 3000, 1000), Layout.FitSaved(new PxRect(2000, 100, 3000, 1000), TwoScreens));

    [Fact]
    public void GemerkteLageAufAbgestecktemBildschirmVerworfen() =>
        Assert.Null(Layout.FitSaved(new PxRect(5000, 100, 6000, 1000), TwoScreens));

    [Fact]
    public void TitelleisteUeberDemBildschirmVerworfen() =>
        Assert.Null(Layout.FitSaved(new PxRect(100, -500, 900, 10), TwoScreens));

    [Fact]
    public void TeilweiseDraussenWirdHineingeschobenUndVerkleinert()
    {
        // Ragt rechts über den ersten Bildschirm hinaus, Titelleiste liegt überwiegend darauf.
        Assert.Equal(new PxRect(1920 - 800, 900 - 100, 1920, 1032), Layout.FitSaved(new PxRect(1500, 900, 2300, 1132), new[] { TwoScreens[0] }));
        // Größer als der Bildschirm → auf den Arbeitsbereich verkleinert.
        Assert.Equal(new PxRect(0, 0, 1920, 1032), Layout.FitSaved(new PxRect(10, 10, 3000, 2000), new[] { TwoScreens[0] }));
    }

    [Theory]
    [InlineData("10;20;800;600", 10, 20, 810, 620)]
    [InlineData("-1920;0;1000;900", -1920, 0, -920, 900)]
    public void BoundsText(string text, double l, double t, double r, double b)
    {
        Assert.Equal(new PxRect(l, t, r, b), Layout.ParseBounds(text));
        Assert.Equal(text, Layout.FormatBounds(new PxRect(l, t, r, b)));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("1;2;3")]
    [InlineData("a;b;c;d")]
    [InlineData("0;0;0;600")]
    public void BoundsTextUngueltig(string? text) => Assert.Null(Layout.ParseBounds(text));

    // Tastenkürzel: gleiche Entscheidung für Hauptfenster und Fenster am Infobereich.

    [Fact]
    public void Kuerzel()
    {
        const System.Windows.Input.ModifierKeys none = System.Windows.Input.ModifierKeys.None,
            ctrl = System.Windows.Input.ModifierKeys.Control;
        Assert.Equal(ShortcutCommand.Power, Shortcuts.Resolve(System.Windows.Input.Key.P, ctrl, false, true, false));
        Assert.Equal(ShortcutCommand.Warmer, Shortcuts.Resolve(System.Windows.Input.Key.Up, ctrl, true, false, false));
        Assert.Equal(ShortcutCommand.Colder, Shortcuts.Resolve(System.Windows.Input.Key.Down, ctrl, true, false, false));
        // Nackte Pfeile gehören Scrollbereichen, Reglern und der Tastaturnavigation – nie der Temperatur (wie am Mac).
        Assert.Equal(ShortcutCommand.None, Shortcuts.Resolve(System.Windows.Input.Key.Up, none, true, false, false));
        Assert.Equal(ShortcutCommand.None, Shortcuts.Resolve(System.Windows.Input.Key.Down, none, true, false, true));
        // Aus oder beim Tippen: auch Strg+Pfeil nicht.
        Assert.Equal(ShortcutCommand.None, Shortcuts.Resolve(System.Windows.Input.Key.Up, ctrl, false, false, false));
        Assert.Equal(ShortcutCommand.None, Shortcuts.Resolve(System.Windows.Input.Key.Up, ctrl, true, true, false));
        Assert.Equal(ShortcutCommand.Refresh, Shortcuts.Resolve(System.Windows.Input.Key.F5, none, false, false, false));
        Assert.Equal(ShortcutCommand.Refresh, Shortcuts.Resolve(System.Windows.Input.Key.R, ctrl, false, false, false));
        Assert.Equal(ShortcutCommand.Settings, Shortcuts.Resolve(System.Windows.Input.Key.OemComma, ctrl, false, false, false));
        // Strg+G/D nur im Hauptfenster mit Werten.
        Assert.Equal(ShortcutCommand.None, Shortcuts.Resolve(System.Windows.Input.Key.G, ctrl, true, false, false));
        Assert.Equal(ShortcutCommand.ToggleCharts, Shortcuts.Resolve(System.Windows.Input.Key.G, ctrl, true, false, true));
        Assert.Equal(ShortcutCommand.ToggleDiag, Shortcuts.Resolve(System.Windows.Input.Key.D, ctrl, true, false, true));
        // Andere Umschalttasten: nichts.
        Assert.Equal(ShortcutCommand.None, Shortcuts.Resolve(System.Windows.Input.Key.P, ctrl | System.Windows.Input.ModifierKeys.Shift, true, false, true));
    }
}
