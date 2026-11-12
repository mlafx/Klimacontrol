using System;
using System.Collections.Generic;
using System.Linq;

namespace KlimacontrolTray;

/// Reine Rechnung der Graphen ohne WPF, gleich wie im Kern (`ChartAxis`, `MainWindowLayout.chartHeights`,
/// `HistorySample.modeRuns`); geprüft gegen die Tabellen in `Tests/Shared/` (ChartMathTests).
internal static class ChartMath
{
    /// Y-Skala: Bereich `Min…Max`, Gitterlinien ab `First` im Abstand `Step`.
    internal sealed record Axis(double Min, double Max, double First, double Step)
    {
        /// Bereich nach unten verlängert, sodass der neue Teil `fraction` der Höhe einnimmt (Platz für das Modus-Band
        /// unter der Nulllinie). Gitterlinien bleiben, wo sie waren.
        internal Axis ExtendedBelow(double fraction)
        {
            if (!(fraction > 0 && fraction < 1) || !(Max > Min)) return this;
            return this with { Min = Min - (Max - Min) * fraction / (1 - fraction) };
        }

        /// Bereich nach oben so weit verlängert, dass über `highest` noch `fraction` der Höhe frei bleibt.
        internal Axis WithHeadroom(double highest, double fraction)
        {
            if (!double.IsFinite(highest) || !(fraction > 0 && fraction < 1)) return this;
            return this with { Max = Math.Max(Max, Min + (highest - Min) / (1 - fraction)) };
        }

        /// Werte der Gitterlinien innerhalb des Bereichs (Toleranz ein Tausendstel Schritt).
        internal List<double> Ticks()
        {
            var ticks = new List<double>();
            if (!(Step > 0) || First > Max + Step / 1000) return ticks;
            var n = (int)Math.Floor((Max - First) / Step + 0.001);
            for (var i = 0; i <= n; i++) ticks.Add(First + i * Step);
            return ticks;
        }
    }

    /// Leistung: ab 0, nach oben auf einen runden Schritt aufgerundet (etwa drei Abschnitte). Nicht endliche Werte
    /// zählen bei beiden Achsen nicht (sonst fände die Schrittsuche kein Ende).
    internal static Axis? PowerAxis(IEnumerable<double> values)
    {
        double? hi = null;
        foreach (var v in values.Where(double.IsFinite)) hi = hi is { } h ? Math.Max(h, v) : v;
        if (hi is not { } max) return null;
        max = Math.Max(max, 1);
        var step = Math.Max(1, NiceStep(max / 3));
        return new Axis(0, Math.Ceiling(max / step) * step, 0, step);
    }

    /// Temperatur: Min−1…Max+1, mindestens 4° breit (bei einem einzigen Wert ±2°).
    internal static Axis? TempAxis(IEnumerable<double> values)
    {
        double? lo0 = null, hi0 = null;
        foreach (var v in values.Where(double.IsFinite))
        {
            lo0 = lo0 is { } a ? Math.Min(a, v) : v;
            hi0 = hi0 is { } b ? Math.Max(b, v) : v;
        }
        if (lo0 is not { } min || hi0 is not { } max) return null;
        double lo = min - 1, hi = max + 1;
        if (hi - lo < 4)
        {
            var mid = (lo + hi) / 2;
            (lo, hi) = (mid - 2, mid + 2);
        }
        return Gridded(lo, hi);
    }

    /// Achse ohne Daten: genau dieser Bereich, Gitter wie bei Messwerten.
    internal static Axis Fixed(double lo, double hi) => Gridded(lo, hi);

    /// Gitter auf runden Graden (1, 2, 5 mal Zehnerpotenz), höchstens fünf Abschnitte.
    static Axis Gridded(double lo, double hi)
    {
        var step = 1.0;
        for (var mag = 1.0; ; mag *= 10)
        {
            var found = false;
            foreach (var n in new[] { 1.0, 2.0, 5.0 })
                if ((hi - lo) / (n * mag) <= 5) { step = n * mag; found = true; break; }
            if (found) break;
        }
        return new Axis(lo, hi, Math.Ceiling(lo / step) * step, step);
    }

    /// Nächster runder Schritt (1, 2, 5 mal Zehnerpotenz) ab `raw`.
    internal static double NiceStep(double raw)
    {
        if (raw <= 0) return 1;
        var mag = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        var n = raw / mag;
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag;
    }

    /// Jede wievielte Beschriftung unter den Verbrauchsbalken Platz hat. `labelLength` ist die Zeichenzahl der
    /// längsten Beschriftung; Zeichenbreite und Abstand hängen von der Schrift der Oberfläche ab.
    internal static int LabelStep(int count, double plotWidth, int labelLength, double charWidth, double gap)
    {
        if (count <= 0 || plotWidth <= 0) return 1;
        var slot = plotWidth / count;
        var needed = labelLength * charWidth + gap;
        return Math.Max(1, (int)Math.Ceiling(needed / slot));
    }

    /// Ob der Balken `index` von `count` bei Schrittweite `step` beschriftet wird (von hinten gezählt, die letzte
    /// Beschriftung bleibt immer stehen).
    internal static bool ShowsLabel(int index, int count, int step) => (count - 1 - index) % Math.Max(1, step) == 0;

    // Zeitachse

    /// Die drei Graphen des Verlaufs, von oben nach unten.
    internal enum ChartKind { Power, Temperature, Outdoor }

    /// Unterster sichtbarer Graph der einspaltigen Karte: Außen, wenn er einen eigenen Graphen hat, sonst Temperatur.
    internal static ChartKind BottomChart(bool separateOutdoor) => separateOutdoor ? ChartKind.Outdoor : ChartKind.Temperature;

    /// Ob `chart` die Zeitbeschriftung trägt: im Raster jede Karte, einspaltig nur der unterste sichtbare Graph.
    internal static bool CarriesTimeLabels(ChartKind chart, bool grid, bool separateOutdoor) =>
        grid || chart == BottomChart(separateOutdoor);

    /// Zeitpunkte (Unix-Sekunden) der Beschriftungen auf runden Ortszeiten in `start…end`: Minute des Tages ein
    /// Vielfaches von `stepMinutes` (ab 1440 Mitternacht). Punkte, deren Beschriftung (halbe Breite `labelHalfWidth`)
    /// über den Rand der Zeichenfläche (`plotWidth`) ragte, entfallen; `plotWidth` 0 = ohne diese Prüfung. Gezählt wird
    /// in echter Zeit, darum kommt am Ende der Sommerzeit die doppelte Stunde zweimal.
    internal static List<double> TimeTicks(double start, double end, int stepMinutes, double plotWidth, double labelHalfWidth,
                                           TimeZoneInfo zone)
    {
        var result = new List<double>();
        var span = end - start;
        if (!(span > 0) || stepMinutes <= 0) return result;
        var daily = stepMinutes >= 1440;
        var t = MidnightUnix(ToLocal(start, zone).Date, zone);
        for (var guard = 0; t <= end && guard < 10_000; guard++)
        {
            var local = ToLocal(t, zone);
            var onGrid = daily || (local.Hour * 60 + local.Minute) % stepMinutes == 0;
            if (onGrid && t >= start)
            {
                var x = (t - start) / span * plotWidth;
                if (plotWidth <= 0 || (x >= labelHalfWidth && x <= plotWidth - labelHalfWidth)) result.Add(t);
            }
            var next = daily ? MidnightUnix(local.Date.AddDays(1), zone) : t + Math.Min(stepMinutes, 60) * 60.0;
            if (!(next > t)) break;
            t = next;
        }
        return result;
    }

    static DateTime ToLocal(double unix, TimeZoneInfo zone) =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.UnixEpoch.AddTicks((long)Math.Round(unix * TimeSpan.TicksPerSecond)), zone);

    /// Beginn des Tages `date` in `zone`; fällt Mitternacht in eine übersprungene Stunde, gilt die erste gültige Zeit.
    static double MidnightUnix(DateTime date, TimeZoneInfo zone)
    {
        var d = DateTime.SpecifyKind(date.Date, DateTimeKind.Unspecified);
        for (var i = 0; i < 24 * 4 && zone.IsInvalidTime(d); i++) d = d.AddMinutes(15);
        return (TimeZoneInfo.ConvertTimeToUtc(d, zone) - DateTime.UnixEpoch).Ticks / (double)TimeSpan.TicksPerSecond;
    }

    // Graphenhöhen

    /// Höhen der Graphen in der Verlaufsspalte.
    internal sealed record Heights(double Power, double Temperature, double Outdoor, double Energy);

    /// Wie `MainWindowLayout.chartHeights` im Kern, mit den Zahlen aus `options.window`: Einspaltig geht zusätzliche
    /// Höhe anteilig (`ChartWeights`) an Leistung, Temperatur und Außen bis zu ihrer Höchsthöhe, danach an den
    /// Verbrauch; jede Zugabe in Stufen von `ChartStep`, eine Zugabe bis 0,5 unter der vollen Höchsthöhe zählt als
    /// voll. Ohne eigenen Außengraphen teilen sich Leistung und Temperatur den Platz, `Outdoor` ist dann 0. Im Raster
    /// teilen sich beide Zeilen die Höhe unter dem Kopf. `overhead` ist die gemessene Höhe ohne die Graphen, sonst
    /// gilt die Schätzung des Kerns.
    internal static Heights ChartHeights(WindowOptions w, double columnHeight, bool grid, double? overhead, bool separateOutdoor)
    {
        var step = w.ChartStep > 0 ? w.ChartStep : 1;
        double Floor(double v) => Math.Floor((v + 0.001) / step) * step;
        if (grid)
        {
            var share = (columnHeight - (overhead ?? w.GridOverhead)) / 2;
            var top = Math.Min(w.GridRowMax, Math.Max(w.GridChartMin.Power, Floor(share)));
            var bottom = Math.Min(w.GridRowMax, Math.Max(w.GridChartMin.Energy, Floor(share)));
            return new Heights(top, top, separateOutdoor ? bottom : 0, bottom);
        }
        var b = w.ChartMin;
        var m = w.ChartMax;
        var weights = new[] { w.ChartWeights.Power, w.ChartWeights.Temperature, w.ChartWeights.Outdoor };
        var bases = new[] { b.Power, b.Temperature, separateOutdoor ? b.Outdoor : 0 };
        var maxes = new[] { m.Power, m.Temperature, separateOutdoor ? m.Outdoor : 0 };
        var baseSum = b.Power + b.Temperature + (separateOutdoor ? b.Outdoor : 0) + b.Energy;
        var extra = Math.Max(0, columnHeight - (overhead ?? w.SingleOverhead) - baseSum);
        var add = new double[3];
        var open = separateOutdoor ? new List<int> { 0, 1, 2 } : new List<int> { 0, 1 };
        while (extra > 0.5 && open.Count > 0)
        {
            var weight = open.Sum(i => weights[i]);
            if (!(weight > 0)) break;
            var used = 0.0;
            var next = new List<int>();
            foreach (var i in open)
            {
                var room = maxes[i] - bases[i] - add[i];
                var give = Math.Min(room, extra * weights[i] / weight);
                add[i] += give;
                used += give;
                if (room - give > 0.5) next.Add(i);
            }
            extra -= used;
            open = next;
            if (used < 0.5) break;
        }
        double Stepped(double v, double room) => v >= room - 0.5 ? room : Floor(v);
        var energyRoom = m.Energy - b.Energy;
        return new Heights(
            b.Power + Stepped(add[0], m.Power - b.Power),
            b.Temperature + Stepped(add[1], m.Temperature - b.Temperature),
            separateOutdoor ? b.Outdoor + Stepped(add[2], m.Outdoor - b.Outdoor) : 0,
            b.Energy + Stepped(Math.Min(Math.Max(0, extra), energyRoom), energyRoom));
    }

    // Modus-Band

    /// Zeit, in der die Anlage in einer Betriebsart lief (Unix-Sekunden).
    internal sealed record ModeRun(int Mode, double Start, double End);

    /// Läufe gleicher Betriebsart aus den zeitlich sortierten Punkten (`Mode` null = aus). Ein Lauf reicht bis zum
    /// nächsten Punkt mit anderem Zustand, außer dazwischen liegt eine Lücke länger als `gapLimit` (dann endet er beim
    /// letzten eigenen Punkt). Läufe ohne Dauer entfallen.
    internal static List<ModeRun> ModeRuns(IEnumerable<(double T, int? Mode)> points, double gapLimit)
    {
        var result = new List<ModeRun>();
        (int Mode, double Start, double Last)? current = null;
        void Close(double end)
        {
            if (current is { } c && end > c.Start) result.Add(new ModeRun(c.Mode, c.Start, end));
            current = null;
        }
        foreach (var (t, mode) in points)
        {
            if (current is { } c)
            {
                if (t - c.Last > gapLimit) Close(c.Last);
                else if (mode != c.Mode) Close(t);
                else
                {
                    current = c with { Last = t };
                    continue;
                }
            }
            if (mode is { } m) current = (m, t, t);
        }
        if (current is { } last) Close(last.Last);
        return result;
    }
}
