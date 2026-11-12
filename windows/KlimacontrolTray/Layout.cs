using System;
using System.Collections.Generic;
using System.Linq;

namespace KlimacontrolTray;

/// Rechenregeln ohne WPF für Innenabstand und Dichte der Steuerspalte, die Lage des Fensters am Infobereich und die
/// gemerkte Lage des Hauptfensters. Spaltenbreiten und Fensterrahmen stehen in `WindowLayoutMath` (Regeln des Kerns).
static class Layout
{
    /// Innenabstand oben/unten: normal bzw. kompakt.
    public const double PadNormal = 20, PadCompact = 12;

    /// Seitlicher Innenabstand einer Spalte.
    public static double PadX(double columnWidth) => columnWidth < 420 ? 16 : 20;

    /// Breite, die die Steuerung in ihrer Spalte bekommt.
    public static double ControlsWidth(double columnWidth) => Math.Max(0, columnWidth - 2 * PadX(columnWidth));

    /// Kompakt, sobald die Steuerung in normaler Dichte (`naturalHeight`) samt Innenabstand nicht in die Höhe passt.
    public static bool NeedsCompact(double naturalHeight, double available) => naturalHeight + 2 * PadNormal > available;

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
