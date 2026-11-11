using System;
using System.Collections.Generic;

namespace KlimacontrolTray;

/// Seitenspalten des Hauptfensters (Namen wie `MainWindowLayout.Column` im Kern).
enum SideColumn { History, Diagnostics }

/// Welche Seitenspalten gezeigt werden bzw. gewünscht sind.
readonly record struct SideColumns(bool History, bool Diagnostics)
{
    public bool Contains(SideColumn c) => c == SideColumn.History ? History : Diagnostics;
    public bool Any => History || Diagnostics;
}

/// Breiten der Spalten; die Seitenspalten schließen ihre Trennlinie ein, `Margin` ist der ungenutzte Rest.
readonly record struct ColumnWidths(double History, double Control, double Diagnostics, double Margin)
{
    public double Total => History + Control + Diagnostics + Margin;
}

/// Ergebnis der „passt nicht“-Regel: was gezeigt wird und welche gewünschten Spalten dafür wegfallen.
sealed record ColumnResolution(SideColumns Shown, IReadOnlyList<SideColumn> Hidden);

/// Rechteck in WPF-Einheiten, y nach unten (`Y` = obere Kante).
readonly record struct DipRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

enum FrameSide { Left, Right }

/// C#-Nachbau von `MainWindowLayout` und `MainWindowFrame` aus dem Kern; die Zahlen kommen aus `options.window`.
/// Geprüft gegen `Tests/Shared/main-window-layout-table.json`.
static class WindowLayoutMath
{
    /// Regeln vom Kern sind da (vor dem ersten Schnappschuss fehlen sie).
    public static bool Valid(WindowOptions r) => r.ControlWidth > 0 && r.MinimumHeight.Normal > 0;

    public static double MinimumWidth(WindowOptions r, SideColumns v) =>
        r.ControlWidth + (v.History ? r.HistoryMin : 0) + (v.Diagnostics ? r.DiagnosticsMin : 0);

    /// Erst die Mindestbreiten, der Überschuss zuerst an den Verlauf bis `historyBalanced`, dann an die Diagnose bis
    /// `diagnosticsMax`, danach wieder an den Verlauf; ohne Verlauf bleibt er Rand. Unter der Mindestbreite wird nicht
    /// gequetscht.
    public static ColumnWidths Widths(WindowOptions r, double total, SideColumns v)
    {
        var history = v.History ? r.HistoryMin : 0;
        var diagnostics = v.Diagnostics ? r.DiagnosticsMin : 0;
        var margin = 0.0;
        var rest = Math.Max(0, total - MinimumWidth(r, v));
        if (v.History)
        {
            var a = Math.Min(rest, r.HistoryBalanced - r.HistoryMin);
            history += a;
            rest -= a;
        }
        if (v.Diagnostics)
        {
            var b = Math.Min(rest, r.DiagnosticsMax - r.DiagnosticsMin);
            diagnostics += b;
            rest -= b;
        }
        if (v.History) history += rest;
        else margin = rest;
        return new ColumnWidths(history, r.ControlWidth, diagnostics, margin);
    }

    public static bool HistoryUsesGrid(WindowOptions r, double width) => width >= r.HistoryGridFrom;

    /// Reicht die Breite nicht, bleibt nur die zuletzt geöffnete Spalte (ohne Angabe der Verlauf); passt auch die
    /// nicht, nur die Steuerung.
    public static ColumnResolution Resolve(WindowOptions r, SideColumns wanted, double available, SideColumn? lastOpened)
    {
        if (MinimumWidth(r, wanted) <= available) return new ColumnResolution(wanted, Array.Empty<SideColumn>());
        var shown = wanted;
        var hidden = new List<SideColumn>();
        if (wanted.History && wanted.Diagnostics)
        {
            var keep = lastOpened ?? SideColumn.History;
            var drop = keep == SideColumn.History ? SideColumn.Diagnostics : SideColumn.History;
            shown = drop == SideColumn.History ? shown with { History = false } : shown with { Diagnostics = false };
            hidden.Add(drop);
            if (MinimumWidth(r, shown) <= available) return new ColumnResolution(shown, hidden);
        }
        if (shown.History) hidden.Add(SideColumn.History);
        if (shown.Diagnostics) hidden.Add(SideColumn.Diagnostics);
        return new ColumnResolution(default, hidden);
    }

    /// Mindesthöhe des Inhalts je Darstellungsgröße ("compact" | "normal" | "large").
    public static double MinimumHeight(WindowOptions r, string size) => size switch
    {
        "compact" => r.MinimumHeight.Compact,
        "large" => r.MinimumHeight.Large,
        _ => r.MinimumHeight.Normal,
    };

    /// Gespeicherter Name wie am Mac (`history`, `diagnostics`); Unbekanntes = keine Angabe.
    public static SideColumn? ParseColumn(string? s) => s switch
    {
        "history" => SideColumn.History,
        "diagnostics" => SideColumn.Diagnostics,
        _ => null,
    };

    public static string ColumnName(SideColumn c) => c == SideColumn.History ? "history" : "diagnostics";

    // Rahmen

    /// Wächst nur um den Fehlbetrag bis `minimum` (links oder rechts) und passt das Ergebnis auf den Bildschirm ein.
    /// null, wenn die Mindestbreite breiter ist als der Bildschirm.
    public static (DipRect Frame, double Added)? Grow(DipRect frame, double minimum, FrameSide side, DipRect screen)
    {
        if (minimum > screen.Width) return null;
        var deficit = Math.Max(0, minimum - frame.Width);
        var f = frame with { Width = frame.Width + deficit, X = side == FrameSide.Left ? frame.X - deficit : frame.X };
        return (Fit(f, screen), deficit);
    }

    /// Nimmt höchstens `amount` Breite zurück, aber nie unter `minimumWidth`.
    public static DipRect Shrink(DipRect frame, double amount, FrameSide side, double minimumWidth)
    {
        var take = Math.Max(0, Math.Min(amount, frame.Width - minimumWidth));
        return frame with { Width = frame.Width - take, X = side == FrameSide.Left ? frame.X + take : frame.X };
    }

    /// Kürzt auf `maximum`; `keeping` ist die Seite, die stehen bleibt.
    public static DipRect LimitWidth(DipRect frame, double maximum, FrameSide keeping)
    {
        var cut = frame.Width - maximum;
        if (cut <= 0) return frame;
        return frame with { Width = frame.Width - cut, X = keeping == FrameSide.Right ? frame.X + cut : frame.X };
    }

    /// Wächst nach unten (obere Kante bleibt) bis zur Mindesthöhe, soweit der Bildschirm reicht.
    public static DipRect GrowHeight(DipRect frame, double minimum, DipRect screen)
    {
        var target = Math.Min(minimum, screen.Height);
        if (frame.Height >= target) return frame;
        return Fit(frame with { Height = target }, screen);
    }

    /// Rückt das Fenster gerade so weit herein, dass es ganz auf dem Bildschirm liegt (kleiner nur, wenn es größer ist).
    public static DipRect Fit(DipRect frame, DipRect screen)
    {
        var (x, y, w, h) = (frame.X, frame.Y, Math.Min(frame.Width, screen.Width), Math.Min(frame.Height, screen.Height));
        if (x + w > screen.Right) x = screen.Right - w;
        if (x < screen.X) x = screen.X;
        if (y + h > screen.Bottom) y = screen.Bottom - h;
        if (y < screen.Y) y = screen.Y;
        return new DipRect(x, y, w, h);
    }

    /// Maximierte oder angedockte Fenster: bildschirmhoch und an einem seitlichen Rand; sie werden nicht verändert.
    public static bool IsConstrained(DipRect frame, DipRect screen)
    {
        var tall = frame.Height >= screen.Height - 2;
        var atEdge = frame.X <= screen.X + 2 || frame.Right >= screen.Right - 2;
        return tall && atEdge;
    }
}
