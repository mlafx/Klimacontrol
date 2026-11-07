using System;
using System.Collections.Generic;
using System.Linq;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Spaltenverteilung des Hauptfensters: Steuerung 360/490/600, Verlauf 320/470/beliebig,
/// Diagnose 300/360/460 (min/Wunsch/max).
public class LayoutTests
{
    static readonly Func<double, bool> Fits = _ => true, NoFit = _ => false;

    static string Describe(List<LayoutColumn> cols) => Layout.Key(cols);

    [Fact]
    public void SpaltenbreitenWieLeitlinie()
    {
        Assert.Equal(new Span(360, 490, 600), Layout.ControlsSpan);
        Assert.Equal(new Span(320, 470, double.PositiveInfinity), Layout.ChartsSpan);
        Assert.Equal(new Span(300, 360, 460), Layout.DiagSpan);
    }

    [Theory]
    [InlineData(2000, "Charts|Controls|Diag")]
    [InlineData(980, "Charts|Controls|Diag")]          // genau alle Mindestbreiten
    [InlineData(979, "Controls|Charts,Diag")]          // zwei Spalten, untereinander (Höhe reicht)
    [InlineData(680, "Controls|Charts,Diag")]          // Steuerung + breitere der beiden
    [InlineData(679, "Controls,Charts,Diag/Reiter")]   // eine Spalte mit Reitern
    [InlineData(420, "Controls,Charts,Diag/Reiter")]
    public void VerlaufUndDiagnose(double width, string expected) =>
        Assert.Equal(expected, Describe(Layout.Arrange(width, true, true, Fits)));

    [Fact]
    public void ZweiSpaltenAlsReiterWennHoeheNichtReicht() =>
        Assert.Equal("Controls|Charts,Diag/Reiter", Describe(Layout.Arrange(900, true, true, NoFit)));

    [Fact]
    public void StapelpruefungBekommtBreiteDerRechtenSpalte()
    {
        var asked = new List<double>();
        Layout.Arrange(900, true, true, w => { asked.Add(w); return true; });
        Assert.Equal(new[] { 900.0 - 360 }, asked);
        asked.Clear();
        Layout.Arrange(1200, true, true, w => { asked.Add(w); return true; }); // drei Spalten: keine Messung
        Assert.Empty(asked);
    }

    [Theory]
    [InlineData(1000, "Charts|Controls")]
    [InlineData(680, "Charts|Controls")]
    [InlineData(679, "Controls,Charts/Reiter")]
    public void NurVerlauf(double width, string expected) =>
        Assert.Equal(expected, Describe(Layout.Arrange(width, true, false, NoFit)));

    [Theory]
    [InlineData(1000, "Controls|Diag")]
    [InlineData(660, "Controls|Diag")]
    [InlineData(659, "Controls,Diag/Reiter")]
    public void NurDiagnose(double width, string expected) =>
        Assert.Equal(expected, Describe(Layout.Arrange(width, false, true, NoFit)));

    [Theory]
    [InlineData(300)]
    [InlineData(2000)]
    public void NurSteuerungOhneReiter(double width) =>
        Assert.Equal("Controls", Describe(Layout.Arrange(width, false, false, NoFit)));

    [Fact]
    public void GemeinsameSpalteNimmtGroessteBreiten()
    {
        var s = Layout.ColumnSpan(new[] { Pane.Charts, Pane.Diag });
        Assert.Equal(new Span(320, 470, double.PositiveInfinity), s);
        Assert.Equal(new Span(360, 490, double.PositiveInfinity), Layout.ColumnSpan(new[] { Pane.Controls, Pane.Charts, Pane.Diag }));
    }

    static double[] ThreeColumns(double total) =>
        Layout.Distribute(new[] { Layout.ChartsSpan, Layout.ControlsSpan, Layout.DiagSpan }, total);

    [Fact]
    public void DreiSpaltenAufWunschbreite() =>
        Assert.Equal(new double[] { 470, 490, 360 }, ThreeColumns(1320));

    [Fact]
    public void DreiSpaltenAufMindestbreite() =>
        Assert.Equal(new double[] { 320, 360, 300 }, ThreeColumns(980));

    [Fact]
    public void ZwischenMindestUndWunschAnteilig()
    {
        var w = ThreeColumns(1150); // 170 von 340 bis zur Wunschbreite: jede Spalte die Hälfte ihres Spielraums
        Assert.Equal(new double[] { 395, 425, 330 }, w);
    }

    [Fact]
    public void UeberWunschbreiteErstBegrenzteBisMax()
    {
        var w = ThreeColumns(1530); // 210 übrig = genau Steuerung +110 und Diagnose +100
        Assert.Equal(new double[] { 470, 600, 460 }, w);
    }

    [Fact]
    public void RestGehtAnDenVerlauf()
    {
        var w = ThreeColumns(2000);
        Assert.Equal(new double[] { 940, 600, 460 }, w);
        Assert.Equal(2000, w.Sum());
    }

    [Fact]
    public void OhneUnbegrenzteSpalteBleibtRestFrei()
    {
        var w = Layout.Distribute(new[] { Layout.ControlsSpan, Layout.DiagSpan }, 1500);
        Assert.Equal(new double[] { 600, 460 }, w); // übrige 440 verteilen sich links und rechts
    }

    [Fact]
    public void SchmalerAlsMindestbreiteGibtLetzteSpalteNach()
    {
        var w = Layout.Distribute(new[] { Layout.ControlsSpan }, 330);
        Assert.Equal(new double[] { 330 }, w);
        Assert.Equal(new double[] { 360, 0 }, Layout.Distribute(new[] { Layout.ControlsSpan, Layout.DiagSpan }, 300));
    }

    [Fact]
    public void BreitenWerdenAbgerundet()
    {
        foreach (var total in new[] { 981.0, 1001.7, 1234.5, 1777.3 })
            Assert.All(ThreeColumns(total), x => Assert.Equal(Math.Floor(x), x));
    }

    [Theory]
    [InlineData(false, false, 490)]
    [InlineData(true, false, 960)]
    [InlineData(false, true, 850)]
    [InlineData(true, true, 1320)]
    public void Wunschbreite(bool charts, bool diag, double expected) =>
        Assert.Equal(expected, Layout.NaturalWidth(charts, diag));

    [Theory]
    [InlineData(400, 16)]
    [InlineData(419.9, 16)]
    [InlineData(420, 20)]
    public void SeitenabstandJeSpaltenbreite(double width, double pad) => Assert.Equal(pad, Layout.PadX(width));

    [Fact]
    public void SteuerungNieBreiterAls560()
    {
        Assert.Equal(560, Layout.ControlsWidth(1200));
        Assert.Equal(490 - 40, Layout.ControlsWidth(490));
        Assert.Equal(400 - 32, Layout.ControlsWidth(400));
    }

    [Theory]
    [InlineData(700, false, 740, false)] // 700 + 20 + 20 = 740 passt genau
    [InlineData(701, false, 740, true)]
    [InlineData(712, true, 740, false)]  // Reiter: oben nur 8
    [InlineData(713, true, 740, true)]
    public void KompaktErstWennNormalNichtPasst(double natural, bool tabbed, double avail, bool compact) =>
        Assert.Equal(compact, Layout.NeedsCompact(natural, tabbed, avail));

    [Fact]
    public void StapelMitMindesthoehenAusDerMessung()
    {
        // Verlauf gemessen 400, + 80 Luft + 41 Trennlinie + Diagnose mind. 520 + 2 × 20 = 1081
        Assert.True(Layout.StackFits(400, 300, 1081));
        Assert.False(Layout.StackFits(400, 300, 1080));
        // Höhere Diagnose zählt voll; ein zusätzlicher Graph (z. B. Außentemperatur) über die Messung ebenso.
        Assert.False(Layout.StackFits(400, 600, 1081));
        Assert.False(Layout.StackFits(400 + 90, 300, 1081));
    }

    // Ein-/Ausblenden: linke Kante bleibt, rechts nie über den Rand.

    [Fact]
    public void EinblendenWaechstUmDieSpalte() =>
        Assert.Equal(490 + 470, Layout.ResizeClient(490, false, false, true, false, 5000));

    [Fact]
    public void EinblendenHoechstensBisZurWunschbreite() =>
        Assert.Equal(1320, Layout.ResizeClient(900, false, true, true, true, 5000)); // 900 + 470 > 1320

    [Fact]
    public void EinblendenSchrumpftNie() =>
        Assert.Equal(1500, Layout.ResizeClient(1500, false, false, true, false, 5000));

    [Fact]
    public void EinblendenNichtUeberDenRand() =>
        Assert.Equal(700, Layout.ResizeClient(490, false, false, true, false, 700));

    [Fact]
    public void AusblendenSchrumpftUmDieSpalte() =>
        Assert.Equal(850, Layout.ResizeClient(1320, true, true, false, true, 5000));

    [Fact]
    public void AusblendenNichtUnterWunschbreite() =>
        Assert.Equal(850, Layout.ResizeClient(1000, true, true, false, true, 5000)); // 1000 - 470 < 850

    [Fact]
    public void AusblendenWaechstNie() =>
        Assert.Equal(400, Layout.ResizeClient(400, true, false, false, false, 5000)); // schon schmaler als 490

    [Fact]
    public void OhneAenderungBleibtGroesse() =>
        Assert.Null(Layout.ResizeClient(800, true, false, true, false, 5000));

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
