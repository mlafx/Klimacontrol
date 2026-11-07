using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;

namespace KlimacontrolTray;

/// Kleine Linien-Symbole (16×16) als Pfade – unabhängig davon, welche Symbolschriften Windows mitbringt.
static class Icons
{
    public const string Snowflake = "M8,1 V15 M2,8 H14 M3.5,3.5 L12.5,12.5 M12.5,3.5 L3.5,12.5 M6,1.8 L8,3.5 L10,1.8 M6,14.2 L8,12.5 L10,14.2";
    public const string Flame = "M8,1 C9,4 13,6 13,10.5 A5,4.5 0 0 1 3,10.5 C3,8 4.5,6.5 5.5,5 C6,7 7,7.5 7.5,7.5 C7,5 7.5,3 8,1 Z";
    public const string Drop = "M8,1.5 C8,1.5 3.2,7 3.2,10.2 A4.8,4.8 0 0 0 12.8,10.2 C12.8,7 8,1.5 8,1.5 Z";
    public const string Fan = "M8,8 C7,4 8.5,1.5 10.5,2 C12.5,2.5 11.5,6 8,8 Z M8,8 C11.5,9.5 13,12 11.5,13.5 C10,15 7.5,12 8,8 Z M8,8 C5,10.5 2,10.5 1.8,8.5 C1.6,6.5 5,6 8,8 Z";
    public const string Auto = "M8,1.5 A6.5,6.5 0 1 1 7.99,1.5 Z M5.2,11.5 L8,4.5 L10.8,11.5 M6.2,9 H9.8";
    public const string Power = "M8,1.5 V7.5 M4.6,3.6 A5.6,5.6 0 1 0 11.4,3.6";
    public const string Swing = "M8,1.5 V14.5 M5,4.5 L8,1.5 L11,4.5 M5,11.5 L8,14.5 L11,11.5";
    public const string Leaf = "M2.5,13.5 C2.5,6.5 7.5,2.5 13.5,2.5 C13.5,9.5 8.5,13.5 2.5,13.5 Z M2.5,13.5 L9,7";
    public const string Bolt = "M9.5,1 L3.5,9 H8 L6.5,15 L12.5,7 H8 Z";
    public const string Mute = "M1.5,6 H4.5 L8.5,2.5 V13.5 L4.5,10 H1.5 Z M10.5,5.5 L14.5,10.5 M14.5,5.5 L10.5,10.5";
    public const string Thermometer = "M6.5,2.5 A1.5,1.5 0 0 1 9.5,2.5 V9.5 A3,3 0 1 1 6.5,9.5 Z";
    public const string Sun = "M8,5 A3,3 0 1 1 7.99,5 Z M8,1 V2.5 M8,13.5 V15 M1,8 H2.5 M13.5,8 H15 M3,3 L4,4 M12,12 L13,13 M13,3 L12,4 M4,12 L3,13";
    public const string Calendar = "M2,3.5 H14 V14 H2 Z M2,6.5 H14 M5,1.5 V4.5 M11,1.5 V4.5";
    public const string Timer = "M8,4 A5.5,5.5 0 1 1 7.99,4 Z M8,6.5 V9.5 H10.5 M6,1.5 H10";
    public const string Chart = "M1.5,14.5 H14.5 M1.5,1.5 V14.5 M3.5,11 L6.5,7 L9,9.5 L13.5,4";
    public const string Pulse = "M1,8 H4 L5.5,4 L8,12 L10,6 L11.5,8 H15";
    public const string Close = "M3.5,3.5 L12.5,12.5 M12.5,3.5 L3.5,12.5";
    public const string Check = "M2.5,8.5 L6.5,12 L13.5,4";
    public const string Plus = "M8,2.5 V13.5 M2.5,8 H13.5";
    public const string Minus = "M2.5,8 H13.5";
    /// Info (Hinweiszeile `notice`), Warndreieck (Verbindungsfehler), Anlage aus (durchgestrichenes Gerät).
    public const string Info = "M8,1.5 A6.5,6.5 0 1 1 7.99,1.5 Z M8,7 V11.5 M8,4.6 V4.8";
    public const string Warning = "M8,1.8 L14.8,13.8 H1.2 Z M8,6 V9.6 M8,11.6 V11.8";
    public const string AirConditioner = "M1.5,4 H14.5 V9.5 H1.5 Z M3.5,7.5 H12.5 M4,12 V13.5 M8,12 V13.5 M12,12 V13.5";
    public const string DeviceOff = "M1.5,4 H14.5 V9.5 H1.5 Z M3.5,7.5 H12.5 M4,12 V13.5 M8,12 V13.5 M12,12 V13.5 M1.5,1.5 L14.5,14.5";
    /// Einrichtung: Suche im WLAN (Funkwellen), Netz durchsuchen (Knoten), Cloud.
    public const string Radio = "M8,8.5 V8.6 M5.5,6 A3.5,3.5 0 0 0 5.5,11 M10.5,6 A3.5,3.5 0 0 1 10.5,11 M3.2,3.8 A6.5,6.5 0 0 0 3.2,13.2 M12.8,3.8 A6.5,6.5 0 0 1 12.8,13.2";
    public const string Network = "M6,1.5 H10 V5 H6 Z M1.5,11 H5.5 V14.5 H1.5 Z M10.5,11 H14.5 V14.5 H10.5 Z M8,5 V8 M3.5,11 V8 H12.5 V11";
    public const string Cloud = "M4.5,13 A3,3 0 0 1 4,7 A4,4 0 0 1 11.6,5.6 A3.7,3.7 0 0 1 12,13 Z";

    /// Windows-Systemsymbol aus Segoe Fluent Icons (Windows 11, Rückfall Segoe MDL2 Assets), z. B. E713 Einstellungen.
    public static System.Windows.Controls.TextBlock Glyph(string code, double size = 14) => new()
    {
        Text = code,
        FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
        FontSize = size,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static readonly string GlyphSettings = ((char)0xE713).ToString(), GlyphRefresh = ((char)0xE72C).ToString();

    static readonly Dictionary<string, Geometry> geometries = new();

    /// Pfad einmal einlesen und eingefroren wiederverwenden – alle Symbole gleicher Form teilen sich die Geometrie.
    static Geometry Parsed(string data)
    {
        if (!geometries.TryGetValue(data, out var g))
        {
            g = Geometry.Parse(data);
            g.Freeze();
            geometries[data] = g;
        }
        return g;
    }

    /// Symbol in der gewünschten Größe; Farbe über Foreground des umgebenden Elements (Stroke-Bindung).
    public static Path Make(string data, double size = 16, Brush? brush = null, double thickness = 1.4)
    {
        var p = new Path
        {
            Data = Parsed(data),
            Width = size,
            Height = size,
            Stretch = Stretch.Uniform,
            StrokeThickness = thickness,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            SnapsToDevicePixels = true,
        };
        if (brush != null) p.Stroke = brush;
        else p.SetBinding(Shape.StrokeProperty, new System.Windows.Data.Binding("Foreground")
        {
            RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.FindAncestor, typeof(System.Windows.Controls.Control), 1),
        });
        return p;
    }
}

/// Eingefrorene Pinsel je Farbe: einmal angelegt, dann wiederverwendet. Gleicher Pinsel = gleicher Wert, darum
/// zeichnet WPF nichts neu, wenn sich die Farbe nicht geändert hat (ein neuer Pinsel gälte immer als Änderung).
static class Paints
{
    static readonly Dictionary<Color, SolidColorBrush> brushes = new();

    public static SolidColorBrush Of(Color c)
    {
        if (!brushes.TryGetValue(c, out var b))
        {
            b = new SolidColorBrush(c);
            b.Freeze();
            brushes[c] = b;
        }
        return b;
    }
}
