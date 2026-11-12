using System;
using System.Collections.Generic;
using System.Linq;

namespace KlimacontrolTray;

/// Reine Rechnung der Verbrauchsbalken ohne WPF, gleich wie `EnergyBars` am Mac (`ChartAxis.withHeadroom`,
/// Balkenbreite aus `MainWindowLayout.energyBarMaxWidth`).
internal static class EnergyMath
{
    /// Anteil der Höhe über dem höchsten Balken: mit Werten darüber mehr Platz (wie am Mac).
    internal const double HeadroomWithValues = 0.24, HeadroomPlain = 0.12;
    /// Mehr als dieser Anteil geht nie an die Werte über den Balken.
    internal const double HeadroomMax = 0.6;

    /// Anteil für den Platz oben: wie am Mac, aber mindestens so viel, dass Zeichen und Wert (`textHeight` Pixel, mit
    /// größerer Schrift höher) über den höchsten Balken passen.
    internal static double HeadroomFraction(bool withValues, double textHeight, double plotHeight)
    {
        var fraction = withValues ? HeadroomWithValues : HeadroomPlain;
        if (plotHeight > 0 && textHeight > 0) fraction = Math.Max(fraction, textHeight / plotHeight);
        return Math.Min(fraction, HeadroomMax);
    }

    /// Y-Achse der Balken samt Durchschnitt und Platz oben; null ohne einen einzigen Wert.
    internal static ChartMath.Axis? BarAxis(IEnumerable<double> values, double? average, double fraction)
    {
        var all = values.Where(double.IsFinite).ToList();
        if (all.Count == 0) return null;
        if (average is { } avg && double.IsFinite(avg)) all.Add(avg);
        var axis = ChartMath.PowerAxis(all);
        return axis?.WithHeadroom(all.Max(), fraction);
    }

    /// Werte der Gitterlinien innerhalb des Bereichs (Toleranz ein Tausendstel Schritt wie im Kern).
    internal static List<double> Ticks(ChartMath.Axis a)
    {
        var ticks = new List<double>();
        if (a.Step <= 0 || a.First > a.Max + a.Step / 1000) return ticks;
        var n = (int)Math.Floor((a.Max - a.First) / a.Step + 0.001);
        for (var i = 0; i <= n; i++) ticks.Add(a.First + i * a.Step);
        return ticks;
    }

    /// Breite eines Balkens: 70 % seines Platzes, mindestens 4, höchstens `maxWidth` (gerundet wie am Mac).
    internal static double BarWidth(double plotWidth, int count, double maxWidth)
    {
        var width = Math.Max(4, plotWidth / Math.Max(1, count) * 0.7);
        if (maxWidth > 0) width = Math.Min(maxWidth, width);
        return Math.Round(width, MidpointRounding.AwayFromZero);
    }

    /// Mitte des Balkens `index` von `count` auf der Zeichenfläche.
    internal static double BarCenter(int index, int count, double plotWidth) =>
        plotWidth / Math.Max(1, count) * (index + 0.5);

    /// Höhe eines Werts auf der Zeichenfläche (`top` oben, `height` hoch, Achsenminimum unten).
    internal static double Y(double value, ChartMath.Axis a, double top, double height) =>
        a.Max > a.Min ? top + (1 - (value - a.Min) / (a.Max - a.Min)) * height : top + height;

    /// Linker Rand einer mittig unter bzw. über `center` gesetzten Beschriftung der Breite `width`, so verschoben, dass
    /// sie nicht über die Zeichenfläche `0…plotWidth` hinausragt (erste und letzte Beschriftung).
    internal static double LabelLeft(double center, double width, double plotWidth)
    {
        var left = center - width / 2;
        if (left + width > plotWidth) left = plotWidth - width;
        return Math.Max(0, left);
    }
}
