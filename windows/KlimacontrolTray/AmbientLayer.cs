using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Media;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Bewegte Ebene der Kopfkarte: `Lively` (hinter dem Inhalt) = „Lebendiger Hintergrund“, `Weather` (über dem Inhalt) =
/// „Wetter-Effekte“ (Schnee beim Kühlen, aufsteigende Wärme beim Heizen).
///
/// Sparsam, weil die App ohne Grafikkarte zeichnet (spart Speicher): ein DrawingVisual, eingefrorene Pinsel und ein gemeinsamer
/// Takt für alle Ebenen, damit die Karte nur einmal je Bild neu zeichnet. Der Takt läuft nur, solange eine Ebene zeichnet,
/// Bewegung erlaubt ist und das Fenster sichtbar ist.
public sealed class AmbientLayer : FrameworkElement
{
    public enum Layer { Lively, Weather }

    /// Welche Ebene (in XAML gesetzt).
    public Layer Kind { get; set; }

    /// Eckenradius der Karte – die Ebene zeichnet nur innerhalb.
    public double CornerRadius { get; set; } = 8;

    readonly DrawingVisual visual = new();
    bool active, running, dark;
    int mode;
    Color tint;
    Window? window;
    Geometry? clip;
    Brush[] blobs = Array.Empty<Brush>(), flakes = Array.Empty<Brush>();
    Brush? warm;
    (Color Tint, bool Dark)? brushKey;

    public AmbientLayer()
    {
        AddVisualChild(visual);
        IsHitTestVisible = false;
        Focusable = false;
        Loaded += (_, _) =>
        {
            if (window != null) window.StateChanged -= WindowStateChanged;
            window = Window.GetWindow(this);
            if (window != null) window.StateChanged += WindowStateChanged;
            UpdateRunning();
        };
        Unloaded += (_, _) =>
        {
            if (window != null) window.StateChanged -= WindowStateChanged;
            window = null;
            UpdateRunning();
        };
        IsVisibleChanged += (_, _) => UpdateRunning();
    }

    protected override int VisualChildrenCount => 1;
    protected override Visual GetVisualChild(int index) => visual;
    protected override AutomationPeer OnCreateAutomationPeer() => null!;

    /// `on` = Option an und die Anlage arbeitet; gleiche Werte ändern nichts.
    public void Show(bool on, int mode, Color tint)
    {
        active = on;
        this.mode = mode;
        this.tint = tint;
        if (on)
        {
            dark = Theme.Dark;
            if (brushKey != (tint, dark)) BuildBrushes();
        }
        UpdateRunning();
    }

    /// Anhalten; ein späteres `Show(true …)` startet wieder.
    public void Halt()
    {
        active = false;
        UpdateRunning();
    }

    void WindowStateChanged(object? sender, EventArgs e) => UpdateRunning();

    protected override void OnRenderSizeChanged(SizeChangedInfo info)
    {
        base.OnRenderSizeChanged(info);
        clip = null;
        UpdateRunning();
        if (running) Draw();
    }

    bool Wanted => active && IsLoaded && IsVisible && ActualWidth > 0 && ActualHeight > 0
                   && window?.WindowState != WindowState.Minimized && !Appearance.ReduceMotion
                   && (Kind == Layer.Lively || mode is 2 or 4);

    void UpdateRunning()
    {
        var run = Wanted;
        if (run == running) return;
        running = run;
        if (run)
        {
            Ticker.Add(this);
            Draw();
        }
        else
        {
            Ticker.Remove(this);
            // Leer zeichnen: keine stehengebliebenen Flocken, nichts mehr zu tun beim nächsten Neuzeichnen.
            using (visual.RenderOpen()) { }
        }
    }

    void Tick(long frame)
    {
        // Windows „Animationseffekte“ kann sich zur Laufzeit ändern, ohne dass Appearance.Changed kommt.
        if (!Wanted) { UpdateRunning(); return; }
        if (Kind == Layer.Lively && frame % 2 != 0) return;
        Draw();
    }

    void Draw()
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        if (clip == null)
        {
            var g = new RectangleGeometry(new Rect(0, 0, w, h), CornerRadius, CornerRadius);
            g.Freeze();
            clip = g;
        }
        var t = Ticker.Seconds;
        using var dc = visual.RenderOpen();
        dc.PushClip(clip);
        if (Kind == Layer.Lively) DrawLively(dc, w, h, t);
        else if (mode == 2) DrawSnow(dc, w, h, t);
        else DrawWarmth(dc, w, h, t);
        dc.Pop();
    }

    // ---- Zeichnen ----

    static readonly (double Fx, double Fy, double Phase, double Weight)[] Blobs =
        { (0.031, 0.023, 0, 1), (0.019, 0.037, 2.1, 0.7), (0.027, 0.017, 4.2, 0.5) };
    const int FlakeCount = 24, WarmCount = 12;

    void DrawLively(DrawingContext dc, double w, double h, double t)
    {
        var r = Math.Max(w, h) * 0.75 / 2;
        for (var i = 0; i < Blobs.Length; i++)
        {
            var (fx, fy, phase, _) = Blobs[i];
            var x = w * (0.5 + 0.4 * Math.Sin(t * fx * 2 * Math.PI / 1.2 + phase));
            var y = h * (0.5 + 0.4 * Math.Cos(t * fy * 2 * Math.PI / 1.2 + phase * 0.7));
            dc.DrawEllipse(blobs[i], null, new Point(x, y), r, r);
        }
    }

    void DrawSnow(DrawingContext dc, double w, double h, double t)
    {
        var span = h + 20;
        for (var i = 0; i < FlakeCount; i++)
        {
            var speed = 12 + Rnd(i, 1) * 18;   // px je Sekunde
            var y = (Rnd(i, 2) * span + t * speed) % span - 10;
            var x = w * Rnd(i, 3) + Math.Sin(t * 0.6 + i) * 8;
            var d = 2 + Rnd(i, 4) * 3;
            dc.DrawEllipse(flakes[i], null, new Point(x, y), d / 2, d / 2);
        }
    }

    void DrawWarmth(DrawingContext dc, double w, double h, double t)
    {
        for (var i = 0; i < WarmCount; i++)
        {
            var period = 6 + Rnd(i, 1) * 6;
            var p = (t / period + Rnd(i, 2)) % 1;   // 0 unten … 1 oben
            var y = h * (1 - p);
            // Leichtes Flimmern: seitliches Schwingen, schneller als das Aufsteigen.
            var x = w * Rnd(i, 3) + Math.Sin(t * 0.8 + i * 1.7) * 12 + Math.Sin(t * 3.1 + i) * 1.5;
            var d = 14 + Rnd(i, 4) * 22;
            dc.PushOpacity(Math.Sin(p * Math.PI));
            dc.DrawEllipse(warm, null, new Point(x, y), d / 2, d / 2);
            dc.Pop();
        }
    }

    /// Feste Pseudozufallswerte je Teilchen (ohne Zustand, gleich bei jedem Bild).
    static double Rnd(int i, int k)
    {
        var x = Math.Sin((i * 127 + k * 311) * 12.9898) * 43758.5453;
        return x - Math.Floor(x);
    }

    void BuildBrushes()
    {
        brushKey = (tint, dark);
        var strength = dark ? 0.32 : 0.22;
        blobs = new Brush[Blobs.Length];
        for (var i = 0; i < Blobs.Length; i++) blobs[i] = Radial(tint, strength * Blobs[i].Weight);
        var snow = dark ? Colors.White : Color.FromRgb(0x8C, 0x8C, 0x8C);
        flakes = new Brush[FlakeCount];
        for (var i = 0; i < FlakeCount; i++)
        {
            var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(255 * (0.25 + Rnd(i, 5) * 0.35)), snow.R, snow.G, snow.B));
            b.Freeze();
            flakes[i] = b;
        }
        warm = Radial(tint, 0.22);
    }

    static Brush Radial(Color c, double alpha)
    {
        var b = new RadialGradientBrush(Color.FromArgb((byte)Math.Round(255 * Math.Clamp(alpha, 0, 1)), c.R, c.G, c.B),
                                        Color.FromArgb(0, c.R, c.G, c.B));
        b.Freeze();
        return b;
    }

    /// Ein Zeitgeber für alle Ebenen aller Fenster: läuft nur, solange eine Ebene zeichnet.
    static class Ticker
    {
        static readonly HashSet<AmbientLayer> layers = new();
        static readonly Stopwatch clock = Stopwatch.StartNew();
        static DispatcherTimer? timer;
        static long frame;

        public static double Seconds => clock.Elapsed.TotalSeconds;

        public static void Add(AmbientLayer layer)
        {
            layers.Add(layer);
            if (timer == null)
            {
                // Hintergrund-Vorrang: Eingaben und Kern-Takt gehen immer vor, ein Bild darf ruhig ausfallen.
                timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(1000.0 / 15) };
                timer.Tick += (_, _) =>
                {
                    frame++;
                    // Kopie: Tick kann eine Ebene abmelden.
                    foreach (var l in new List<AmbientLayer>(layers)) l.Tick(frame);
                };
            }
            if (!timer.IsEnabled) timer.Start();
        }

        public static void Remove(AmbientLayer layer)
        {
            layers.Remove(layer);
            if (layers.Count == 0) timer?.Stop();
        }
    }
}
