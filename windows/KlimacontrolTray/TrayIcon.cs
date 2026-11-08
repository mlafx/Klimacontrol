using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using ImageSource = System.Windows.Media.ImageSource;
using Media = System.Windows.Media;

namespace KlimacontrolTray;

/// Symbol im Infobereich: Kachel in der Modusfarbe mit Solltemperatur bzw. Zustandszeichen, wahlweise einfarbig
/// ohne Kachel oder als drehender Lüfter. Gezeichnet in der Größe, die der Infobereich wirklich zeigt – nicht in
/// 32 px und dann von Windows verkleinert.
static class TrayIcon
{
    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    enum Symbol { None, Warning, DeviceOff, PowerOff, Connecting, Mode, Fan }

    /// Alles, was das Bild bestimmt – gleicher Wert = gleiches Bild. Bei `Mono` ist `Color` die Farbe von Zahl und Zeichen.
    readonly record struct Look(Color Color, string Text, Symbol Symbol, int Size, bool Mono = false, bool Outline = false,
                                string? Glyph = null, int Frame = 0, bool Running = false);

    /// Einzelbilder je Drittel-Umdrehung (der Lüfter hat drei Flügel) und Abstand zwischen zwei Bildern.
    public const int SpinFrames = 8;
    public static readonly TimeSpan SpinInterval = TimeSpan.FromMilliseconds(150);

    static Look? madeKey;
    static Icon? made;
    static Look? framesKey;
    static Icon[]? frames;

    public static bool Spins(Snapshot s)
    {
        var a = Appearance.Current;
        return a.TrayAnimated && !Appearance.ReduceMotion && LookOf(s, 16, a, false).Running;
    }

    /// Symbol zum Zustand in `size` Pixeln; gleiche Darstellung → dasselbe Icon-Objekt. `frame` ≥ 0: Einzelbild des
    /// drehenden Lüfters.
    public static Icon Make(Snapshot s, int size, bool taskbarLight = false, int frame = -1)
    {
        var look = LookOf(s, size, Appearance.Current, taskbarLight);
        if (frame >= 0 && look.Running)
            return Frame(look with { Symbol = Symbol.Fan, Text = "", Glyph = null, Outline = false }, frame % SpinFrames);
        if (made != null && madeKey == look) return made;
        var old = made;
        made = Draw(look);
        madeKey = look;
        // Der Infobereich hält eine eigene Kopie, und der Aufrufer setzt das neue sofort.
        old?.Dispose();
        return made;
    }

    /// Lüfterbilder auf einmal zeichnen und wiederverwenden, solange Farbe/Größe gleich bleiben.
    static Icon Frame(Look fan, int frame)
    {
        if (frames == null || framesKey != fan)
        {
            var old = frames;
            var next = new Icon[SpinFrames];
            for (var i = 0; i < SpinFrames; i++) next[i] = Draw(fan with { Frame = i });
            frames = next;
            framesKey = fan;
            if (old != null) foreach (var o in old) o.Dispose();
        }
        return frames[frame];
    }

    /// Lüfterbilder freigeben – erst aufrufen, nachdem der Infobereich wieder ein festes Symbol (`Make` ohne `frame`)
    /// bekommen hat.
    public static void ReleaseFrames()
    {
        if (frames == null) return;
        foreach (var f in frames) f.Dispose();
        frames = null;
        framesKey = null;
    }

    static readonly Color Grey = Color.FromArgb(120, 120, 120), OffGrey = Color.FromArgb(110, 110, 110),
        Red = Color.FromArgb(196, 43, 28), Orange = Color.FromArgb(202, 80, 16);

    static Color Fill(Media.Color tint)
    {
        var c = Theme.ActiveFill(tint);
        return Color.FromArgb(c.R, c.G, c.B);
    }

    /// Modusfarbe, abgedunkelt für weiße Schrift (mind. 4,5:1).
    static Color ModeFill(int mode) => Fill(Theme.Accent(Codes.Tint(mode)));

    static string ModeGlyph(int mode)
    {
        foreach (var m in Codes.Modes) if (m.Value == mode) return m.Icon;
        return Icons.Auto;
    }

    static Look LookOf(Snapshot s, int size, AppearanceSettings a, bool taskbarLight)
    {
        size = Math.Clamp(size, 16, 64);
        var mono = !a.TrayColored;
        var ink = taskbarLight ? Color.Black : Color.White;
        Look Mk(Color tile, string text, Symbol symbol, bool outline = false, string? glyph = null, bool running = false) =>
            mono ? new Look(ink, text, symbol, size, true, outline, glyph, 0, running)
                 : new Look(tile, text, symbol, size, false, false, glyph, 0, running);

        if (!s.Configured) return Mk(Grey, "–", Symbol.None);
        // Ohne bekannten Verbindungszustand nach den Merkern.
        switch (s.ConnectionState)
        {
            case "deviceOff": return Mk(OffGrey, "", Symbol.DeviceOff);
            case "noConnection": return Mk(Orange, "", Symbol.Warning);
            case "connecting": return Mk(Grey, "", Symbol.Connecting);
            case "live": break;
            default:
                if (s.DeviceOffNotice) return Mk(OffGrey, "", Symbol.DeviceOff);
                if (s.LastRefreshFailed) return Mk(Orange, "", Symbol.Warning);
                break;
        }
        var st = s.State;
        if (st == null) return Mk(Grey, "–", Symbol.None);
        var target = Math.Round(st.Target).ToString("0");
        if (s.Message != null) return st.Power ? Mk(Red, target, Symbol.None, outline: true) : Mk(Red, "", Symbol.PowerOff);
        if (!st.Power) return Mk(OffGrey, "", Symbol.PowerOff);
        var fill = ModeFill(st.Mode);
        return a.TrayTooltip switch
        {
            "iconOnly" => Mk(fill, "", Symbol.Mode, glyph: ModeGlyph(st.Mode), running: true),
            "iconRoom" => Mk(fill, st.Indoor is { } room ? Math.Round(room).ToString("0") : "–", Symbol.None, running: true),
            _ => Mk(fill, target, Symbol.None, running: true),
        };
    }

    /// Gezeichnet im 32er-Raster und auf `Size` skaliert; Striche bei kleinen Größen etwas kräftiger.
    static Icon Draw(Look look)
    {
        if (look.Symbol is Symbol.Mode or Symbol.Fan) return DrawGeometry(look);
        var size = look.Size;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            g.ScaleTransform(size / 32f, size / 32f);
            if (!look.Mono)
            {
                using var path = Rounded(new RectangleF(0, 0, 32, 32), 7);
                using var fill = new SolidBrush(look.Color);
                g.FillPath(fill, path);
            }
            var ink = look.Mono ? look.Color : Color.White;
            var stroke = Math.Max(2.2f, 1.5f * 32f / size);
            if (look.Symbol == Symbol.None)
            {
                var text = look.Text;
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                if (look.Mono)
                {
                    // Ohne Kachel ist mehr Platz: Ziffern etwas größer, als Pfad (ausgefüllt bzw. Kontur).
                    var em = text.Length switch { <= 1 => 25f, 2 => 22f, _ => 15f };
                    using var family = new FontFamily("Segoe UI");
                    using var glyphs = new GraphicsPath();
                    glyphs.AddString(text, family, (int)System.Drawing.FontStyle.Bold, em, new RectangleF(-4, 1, 40, 32), fmt);
                    if (look.Outline)
                    {
                        using var pen = new Pen(ink, Math.Max(1.6f, 1.1f * 32f / size)) { LineJoin = LineJoin.Round };
                        g.DrawPath(pen, glyphs);
                    }
                    else
                    {
                        using var brush = new SolidBrush(ink);
                        g.FillPath(brush, glyphs);
                    }
                }
                else
                {
                    // Groß genug für 16 px: zwei Ziffern füllen die Kachel fast ganz aus.
                    var em = text.Length switch { <= 1 => 21f, 2 => 19f, _ => 13f };
                    using var font = new Font("Segoe UI", em, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel);
                    g.DrawString(text, font, Brushes.White, new RectangleF(-4, 1, 40, 32), fmt);
                }
            }
            else DrawSymbol(g, look, stroke, ink);
        }
        return ToIcon(bmp);
    }

    /// GetHicon gehört uns: nach dem Klonen (eigene Kopie) gleich freigeben.
    static Icon ToIcon(Bitmap bmp)
    {
        var handle = bmp.GetHicon();
        try
        {
            using var temp = Icon.FromHandle(handle);
            return (Icon)temp.Clone();
        }
        finally { DestroyIcon(handle); }
    }

    /// Linien-Symbol aus Icons.cs (16er-Raster) auf die Kachel bzw. frei: Raster 16 → 20 Einheiten, mittig.
    static void DrawSymbol(Graphics g, Look look, float stroke, Color ink)
    {
        const float scale = 1.25f, offset = 6f;
        PointF P(float x, float y) => new(offset + x * scale, offset + y * scale);
        using var pen = new Pen(ink, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        switch (look.Symbol)
        {
            case Symbol.Warning:
                g.DrawPolygon(pen, new[] { P(8, 1.8f), P(14.8f, 13.8f), P(1.2f, 13.8f) });
                g.DrawLine(pen, P(8, 6), P(8, 9.4f));
                using (var dot = new SolidBrush(ink))
                {
                    var c = P(8, 11.7f);
                    var r = stroke * 0.65f;
                    g.FillEllipse(dot, c.X - r, c.Y - r, 2 * r, 2 * r);
                }
                break;
            case Symbol.DeviceOff:
                g.DrawRectangle(pen, offset + 1.5f * scale, offset + 4 * scale, 13 * scale, 5.5f * scale);
                g.DrawLine(pen, P(3.5f, 7.5f), P(12.5f, 7.5f));
                foreach (var x in new[] { 4f, 8f, 12f }) g.DrawLine(pen, P(x, 12), P(x, 13.5f));
                // Erst eine Lücke um den Strich (Kachelfarbe bzw. einfarbig: durchsichtig), dann der Strich selbst.
                using (var gap = new Pen(look.Mono ? Color.Transparent : look.Color, stroke * 2.3f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                {
                    if (look.Mono) g.CompositingMode = CompositingMode.SourceCopy;
                    g.DrawLine(gap, P(1.5f, 1.5f), P(14.5f, 14.5f));
                    g.CompositingMode = CompositingMode.SourceOver;
                }
                g.DrawLine(pen, P(1.5f, 1.5f), P(14.5f, 14.5f));
                break;
            case Symbol.Connecting:
                using (var dot = new SolidBrush(ink))
                {
                    var r = Math.Max(2.6f, stroke * 1.15f);
                    foreach (var x in new[] { 7f, 16f, 25f }) g.FillEllipse(dot, x - r, 16 - r, 2 * r, 2 * r);
                }
                break;
            case Symbol.PowerOff:
                g.DrawArc(pen, new RectangleF(7.5f, 8.5f, 17, 17), 305, 290);
                g.DrawLine(pen, new PointF(16, 5.5f), new PointF(16, 15.5f));
                break;
        }
    }

    // Modus-Zeichen und Lüfter: Pfade aus Icons.cs (mit Bögen), darum mit WPF gezeichnet und in ein Icon umgewandelt.

    static readonly Dictionary<string, Media.Geometry> geometries = new();
    static Media.Geometry? fanGeometry;

    static Media.Geometry Parsed(string data)
    {
        if (!geometries.TryGetValue(data, out var g))
        {
            g = Media.Geometry.Parse(data);
            g.Freeze();
            geometries[data] = g;
        }
        return g;
    }

    /// Lüfter mit drei um je 120° gedrehten Flügeln und Nabe, im 16er-Raster.
    static Media.Geometry FanGeometry()
    {
        if (fanGeometry != null) return fanGeometry;
        var blade = Media.Geometry.Parse("M8,8 C7,4 8.5,1.5 10.5,2 C12.5,2.5 11.5,6 8,8 Z");
        var group = new Media.GeometryGroup { FillRule = Media.FillRule.Nonzero };
        for (var i = 0; i < 3; i++)
        {
            var b = blade.Clone();
            b.Transform = new Media.RotateTransform(i * 120, 8, 8);
            group.Children.Add(b);
        }
        group.Children.Add(new Media.EllipseGeometry(new System.Windows.Point(8, 8), 1.6, 1.6));
        group.Freeze();
        return fanGeometry = group;
    }

    static Icon DrawGeometry(Look look)
    {
        var size = look.Size;
        Media.Color W(Color c) => Media.Color.FromArgb(c.A, c.R, c.G, c.B);
        var ink = new Media.SolidColorBrush(look.Mono ? W(look.Color) : Media.Colors.White);
        ink.Freeze();
        var visual = new Media.DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new Media.ScaleTransform(size / 32.0, size / 32.0));
            if (!look.Mono)
            {
                var tile = new Media.SolidColorBrush(W(look.Color));
                tile.Freeze();
                dc.DrawRoundedRectangle(tile, null, new System.Windows.Rect(0, 0, 32, 32), 7, 7);
            }
            // Ohne Kachel darf das Zeichen größer sein. Raster 16 → `scale`, mittig auf (16, 16).
            var scale = look.Mono ? 1.75 : 1.3;
            if (look.Symbol == Symbol.Fan)
            {
                scale = look.Mono ? 1.95 : 1.6;
                dc.PushTransform(new Media.RotateTransform(look.Frame * 120.0 / SpinFrames, 16, 16));
            }
            dc.PushTransform(new Media.TranslateTransform(16 - 8 * scale, 16 - 8 * scale));
            dc.PushTransform(new Media.ScaleTransform(scale, scale));
            if (look.Symbol == Symbol.Fan) dc.DrawGeometry(ink, null, FanGeometry());
            else if (look.Glyph != null)
            {
                var stroke = Math.Max(2.2, 1.5 * 32.0 / size) / scale;
                var pen = new Media.Pen(ink, stroke)
                {
                    StartLineCap = Media.PenLineCap.Round, EndLineCap = Media.PenLineCap.Round, LineJoin = Media.PenLineJoin.Round,
                };
                pen.Freeze();
                dc.DrawGeometry(null, pen, Parsed(look.Glyph));
            }
        }
        var rtb = new RenderTargetBitmap(size, size, 96, 96, Media.PixelFormats.Pbgra32);
        rtb.Render(visual);
        // Icons brauchen nicht vormultiplizierte Farben (Bgra32), Bitmap erwartet dieselbe Byte-Folge (BGRA).
        var converted = new FormatConvertedBitmap(rtb, Media.PixelFormats.Bgra32, null, 0);
        var pixels = new byte[size * size * 4];
        converted.CopyPixels(pixels, size * 4, 0);
        using var bmp = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(new Rectangle(0, 0, size, size), System.Drawing.Imaging.ImageLockMode.WriteOnly,
                                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            for (var y = 0; y < size; y++) Marshal.Copy(pixels, y * size * 4, data.Scan0 + y * data.Stride, size * 4);
        }
        finally { bmp.UnlockBits(data); }
        return ToIcon(bmp);
    }

    static ImageSource? windowIcon;

    /// Fenstersymbol = App-Symbol (Klimacontrol.ico, dasselbe wie in der exe und am Mac); alle Größen, damit Windows
    /// für Titelleiste und Taskleiste die passende nimmt.
    public static ImageSource WindowIcon() =>
        windowIcon ??= BitmapFrame.Create(new Uri("pack://application:,,,/Klimacontrol.ico", UriKind.Absolute));

    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        var d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
