using System;
using System.Collections.Generic;
using System.Linq;

namespace KlimacontrolTray;

/// Bereiche des Hauptfensters.
enum Pane { Controls, Charts, Diag }

/// Breite einer Spalte samt Innenabstand: kleinste, bevorzugte, größte.
readonly record struct Span(double Min, double Pref, double Max);

/// Eine Spalte des Hauptfensters: welche Bereiche, und ob sie als Reiter (statt untereinander) erscheinen.
sealed record LayoutColumn(List<Pane> Panes, bool Tabbed);

/// Rechenregeln ohne WPF für die Spalten des Hauptfensters, die Lage des Fensters am Infobereich und die gemerkte
/// Lage des Hauptfensters. MainWindow misst und baut, hier wird nur entschieden.
static class Layout
{
    public static readonly Span ControlsSpan = new(360, 490, 600);
    public static readonly Span ChartsSpan = new(320, 470, double.PositiveInfinity);
    public static readonly Span DiagSpan = new(300, 360, 460);

    /// Breiter als das wird die Steuerung selbst nie, auch nicht in einer einzelnen breiten Spalte.
    public const double ControlsMaxContent = 560;
    /// Innenabstand oben/unten: normal bzw. kompakt.
    public const double PadNormal = 20, PadCompact = 12;

    public static Span SpanOf(Pane p) => p switch { Pane.Controls => ControlsSpan, Pane.Charts => ChartsSpan, _ => DiagSpan };

    /// Wunschbreite des Inhalts mit den gewünschten Bereichen nebeneinander.
    public static double NaturalWidth(bool charts, bool diag) =>
        ControlsSpan.Pref + (charts ? ChartsSpan.Pref : 0) + (diag ? DiagSpan.Pref : 0);

    /// Spalten für die Breite w nach den Mindestbreiten: alle nebeneinander, sonst Steuerung | Verlauf+Diagnose
    /// (untereinander, wenn `stackFits`, sonst als Reiter), sonst eine Spalte mit Reitern.
    public static List<LayoutColumn> Arrange(double w, bool charts, bool diag, Func<double, bool> stackFits)
    {
        double c = ControlsSpan.Min, ch = ChartsSpan.Min, d = DiagSpan.Min;
        if (charts && diag && w >= c + ch + d)
            return new() { new(new() { Pane.Charts }, false), new(new() { Pane.Controls }, false), new(new() { Pane.Diag }, false) };
        if (charts && diag && w >= c + Math.Max(ch, d))
            return new() { new(new() { Pane.Controls }, false), new(new() { Pane.Charts, Pane.Diag }, !stackFits(w - c)) };
        if (charts && !diag && w >= c + ch)
            return new() { new(new() { Pane.Charts }, false), new(new() { Pane.Controls }, false) };
        if (diag && !charts && w >= c + d)
            return new() { new(new() { Pane.Controls }, false), new(new() { Pane.Diag }, false) };
        var one = new List<Pane> { Pane.Controls };
        if (charts) one.Add(Pane.Charts);
        if (diag) one.Add(Pane.Diag);
        return new() { new(one, one.Count > 1) };
    }

    /// Luft über den kleinsten Graphen, damit der Verlauf untereinander nicht gequetscht wirkt.
    public const double StackSlack = 80;
    /// Trennlinie zwischen Verlauf und Diagnose samt Abstand (20 + 1 + 20).
    public const double StackSeparator = 41;
    /// Diagnose ohne Daten ist kurz – mit der üblichen Höhe rechnen, damit nichts hin- und herspringt.
    public const double DiagTypicalHeight = 520;

    /// Passen Verlauf und Diagnose untereinander in die Höhe? `chartsHeight`/`diagHeight` sind gemessene Wunschhöhen.
    public static bool StackFits(double chartsHeight, double diagHeight, double available) =>
        chartsHeight + StackSlack + StackSeparator + Math.Max(diagHeight, DiagTypicalHeight) + 2 * PadNormal <= available;

    /// Schlüssel der Anordnung: gleicher Schlüssel = Spalten nicht neu bauen, nur Breiten anpassen.
    public static string Key(IEnumerable<LayoutColumn> cols) =>
        string.Join("|", cols.Select(c => string.Join(",", c.Panes) + (c.Tabbed ? "/Reiter" : "")));

    /// Mehrere Bereiche in einer Spalte: jeweils die größte Mindest-, Wunsch- und Höchstbreite.
    public static Span ColumnSpan(IReadOnlyList<Pane> panes) =>
        new(panes.Max(p => SpanOf(p).Min), panes.Max(p => SpanOf(p).Pref), panes.Max(p => SpanOf(p).Max));

    /// Breite verteilen: erst auf Wunschbreite, dann begrenzte Spalten bis zur Höchstbreite, den Rest an unbegrenzte.
    public static double[] Distribute(IReadOnlyList<Span> spans, double total)
    {
        var w = spans.Select(s => s.Min).ToArray();
        var extra = total - w.Sum();
        void Grow(Func<Span, double> target)
        {
            if (extra <= 0) return;
            var room = spans.Select((s, i) => Math.Max(0, Math.Min(target(s), 1e6) - w[i])).ToArray();
            var sum = room.Sum();
            if (sum <= 0) return;
            var take = Math.Min(extra, sum);
            for (var i = 0; i < w.Length; i++) w[i] += take * room[i] / sum;
            extra -= take;
        }
        Grow(s => s.Pref);
        Grow(s => double.IsInfinity(s.Max) ? s.Pref : s.Max);
        Grow(s => s.Max);
        if (extra < 0) w[^1] += extra; // schmaler als alle Mindestbreiten: letzte Spalte gibt nach
        return w.Select(x => Math.Max(0, Math.Floor(x))).ToArray();
    }

    /// Seitlicher Innenabstand einer Spalte.
    public static double PadX(double columnWidth) => columnWidth < 420 ? 16 : 20;

    /// Breite, die die Steuerung in ihrer Spalte bekommt.
    public static double ControlsWidth(double columnWidth) => Math.Min(ControlsMaxContent, columnWidth - 2 * PadX(columnWidth));

    /// Kompakt, sobald die Steuerung in normaler Dichte (`naturalHeight`) samt Innenabstand nicht in die Höhe passt.
    /// In einer Reiter-Spalte ist der Abstand oben kleiner (die Reiterleiste steht darüber).
    public static bool NeedsCompact(double naturalHeight, bool tabbed, double available) =>
        naturalHeight + (tabbed ? 8 : PadNormal) + PadNormal > available;

    /// Neue Innenbreite, wenn Verlauf/Diagnose ein- oder ausgeblendet werden: wächst bzw. schrumpft nach rechts um die
    /// Spalte, begrenzt durch die Wunschbreite und `maxClient` (Platz bis zum rechten Rand). null = Größe bleibt.
    public static double? ResizeClient(double client, bool oldCharts, bool oldDiag, bool charts, bool diag, double maxClient)
    {
        var natural = NaturalWidth(charts, diag);
        var added = (charts && !oldCharts ? ChartsSpan.Pref : 0) + (diag && !oldDiag ? DiagSpan.Pref : 0);
        var removed = (oldCharts && !charts ? ChartsSpan.Pref : 0) + (oldDiag && !diag ? DiagSpan.Pref : 0);
        double target;
        if (added > 0) target = Math.Max(client, Math.Min(natural, client + added));
        else if (removed > 0) target = Math.Min(client, Math.Max(natural, client - removed));
        else return null;
        return Math.Min(target, maxClient);
    }

    // Fenster am Infobereich und gemerkte Lage des Hauptfensters. Alles in Bildschirm-Pixeln.

    /// Abstand des Fensters am Infobereich zum Rand des Arbeitsbereichs (in WPF-Einheiten; mal Skalierung = Pixel).
    public const double FlyoutGap = 12;

    /// Seite der Taskleiste: die Seite, um die der Arbeitsbereich am stärksten schrumpft. Bei automatisch
    /// ausgeblendeter Taskleiste schrumpft er nicht – dann die Kante nächst `anchor`, sonst `appBar`, sonst unten.
    public static TaskbarEdge EdgeOf(PxRect monitor, PxRect work, PxRect? anchor, TaskbarEdge? appBar)
    {
        var insets = new (TaskbarEdge Edge, double Inset)[]
        {
            (TaskbarEdge.Bottom, monitor.Bottom - work.Bottom), (TaskbarEdge.Top, work.Top - monitor.Top),
            (TaskbarEdge.Left, work.Left - monitor.Left), (TaskbarEdge.Right, monitor.Right - work.Right),
        };
        var widest = insets.MaxBy(i => i.Inset);
        if (widest.Inset > 0) return widest.Edge;
        if (anchor is { } a)
        {
            var dist = new (TaskbarEdge Edge, double Dist)[]
            {
                (TaskbarEdge.Bottom, monitor.Bottom - a.CenterY), (TaskbarEdge.Top, a.CenterY - monitor.Top),
                (TaskbarEdge.Left, a.CenterX - monitor.Left), (TaskbarEdge.Right, monitor.Right - a.CenterX),
            };
            return dist.MinBy(d => d.Dist).Edge;
        }
        return appBar ?? TaskbarEdge.Bottom;
    }

    /// Linke obere Ecke des Fensters am Infobereich: neben der Taskleiste, mittig zum Symbol (ohne `anchor` in der
    /// Ecke am Infobereich), nie über den Arbeitsbereich hinaus; ist es höher, bleibt es oben bündig.
    public static (double X, double Y) FlyoutPosition(PxRect work, TaskbarEdge edge, PxRect? anchor, double w, double h, double gap)
    {
        double x, y;
        switch (edge)
        {
            case TaskbarEdge.Top:
                y = work.Top + gap;
                x = anchor is { } t ? t.CenterX - w / 2 : work.Right - w - gap;
                break;
            case TaskbarEdge.Left:
                x = work.Left + gap;
                y = anchor is { } l ? l.CenterY - h / 2 : work.Bottom - h - gap;
                break;
            case TaskbarEdge.Right:
                x = work.Right - w - gap;
                y = anchor is { } r ? r.CenterY - h / 2 : work.Bottom - h - gap;
                break;
            default:
                y = work.Bottom - h - gap;
                x = anchor is { } b ? b.CenterX - w / 2 : work.Right - w - gap;
                break;
        }
        return (Fit(x, work.Left + gap, work.Right - w - gap), Fit(y, work.Top + gap, work.Bottom - h - gap));
    }

    /// Wie Math.Clamp, aber passt der Bereich nicht (hi < lo), gilt lo (links/oben bündig).
    static double Fit(double v, double lo, double hi) => hi < lo ? lo : Math.Min(Math.Max(v, lo), hi);

    /// Mindestens so viel der Titelleiste muss auf einem Bildschirm liegen, damit eine gemerkte Lage gilt.
    public const double TitleVisibleWidth = 120, TitleVisibleHeight = 20, TitleStrip = 40;

    /// Gemerkte Lage, auf den Arbeitsbereich begrenzt, solange ihre Titelleiste noch auf einem Bildschirm sichtbar ist;
    /// null = Standardlage.
    public static PxRect? FitSaved(PxRect saved, IReadOnlyList<PxRect> workAreas)
    {
        if (!(saved.Width > 0 && saved.Height > 0) || double.IsInfinity(saved.Width) || double.IsInfinity(saved.Height))
            return null;
        PxRect? best = null;
        var bestOverlap = 0.0;
        foreach (var work in workAreas)
        {
            var titleW = Math.Min(saved.Right, work.Right) - Math.Max(saved.Left, work.Left);
            var titleH = Math.Min(saved.Top + TitleStrip, work.Bottom) - Math.Max(saved.Top, work.Top);
            if (titleW < Math.Min(TitleVisibleWidth, saved.Width) || titleH < TitleVisibleHeight) continue;
            var overlap = titleW * Math.Max(0, Math.Min(saved.Bottom, work.Bottom) - Math.Max(saved.Top, work.Top));
            if (best == null || overlap > bestOverlap) (best, bestOverlap) = (work, overlap);
        }
        if (best is not { } wa) return null;
        var w = Math.Min(saved.Width, wa.Width);
        var h = Math.Min(saved.Height, wa.Height);
        var left = Fit(saved.Left, wa.Left, wa.Right - w);
        var top = Fit(saved.Top, wa.Top, wa.Bottom - h);
        return new PxRect(left, top, left + w, top + h);
    }

    /// "x;y;w;h" (ganze Pixel) ↔ PxRect, für Prefs "MainWindowBounds".
    public static string FormatBounds(PxRect r) => FormattableString.Invariant(
        $"{Math.Round(r.Left):0};{Math.Round(r.Top):0};{Math.Round(r.Width):0};{Math.Round(r.Height):0}");

    public static PxRect? ParseBounds(string? s)
    {
        var parts = s?.Split(';');
        if (parts is not { Length: 4 }) return null;
        var v = new double[4];
        for (var i = 0; i < 4; i++)
            if (!double.TryParse(parts[i], System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out v[i]))
                return null;
        return v[2] > 0 && v[3] > 0 ? new PxRect(v[0], v[1], v[0] + v[2], v[1] + v[3]) : null;
    }
}

/// Seite der Taskleiste.
enum TaskbarEdge { Bottom, Top, Left, Right }

/// Rechteck in Bildschirm-Pixeln (wie Win32 RECT), ohne WPF.
readonly record struct PxRect(double Left, double Top, double Right, double Bottom)
{
    public double Width => Right - Left;
    public double Height => Bottom - Top;
    public double CenterX => (Left + Right) / 2;
    public double CenterY => (Top + Bottom) / 2;
}
