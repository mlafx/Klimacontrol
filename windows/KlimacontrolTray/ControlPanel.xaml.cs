using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Steuerung im Hauptfenster und im Fenster am Infobereich: zeigt den Zustand des Kerns und schickt Befehle, ohne
/// eigene Logik. Szenen, Timer und Einrichtung sind eigene Bausteine, die sich selbst beim Kern anmelden.
public partial class ControlPanel : UserControl
{
    static Core Core => Core.Shared;

    readonly Dictionary<int, Button> modeTiles = new();
    readonly Dictionary<int, string> modeLabels = new();
    readonly Button swingTile, ecoTile, turboTile, silentTile;
    readonly Button ieco, purifier, freeze, clean, display, sound;
    readonly Dictionary<int, RadioButton> rateButtons = new();
    bool updating;
    DateTime lastTempDrag;

    // Symbole der weiteren Funktionen – nur hier gebraucht, darum nicht in Icons.cs.
    const string GaugeLow = "M2,12 A6,6 0 1 1 14,12 M8,11 L5.5,6.5 M8,11 V11.1";
    const string GaugeHigh = "M2,12 A6,6 0 1 1 14,12 M8,11 L10.5,6.5 M8,11 V11.1";
    const string Sparkles = "M7,2 L8.2,5.8 L12,7 L8.2,8.2 L7,12 L5.8,8.2 L2,7 L5.8,5.8 Z M12.5,10.5 L13,12 L14.5,12.5 L13,13 L12.5,14.5 L12,13 L10.5,12.5 L12,12 Z";
    const string SnowflakeCircle = "M8,1.5 A6.5,6.5 0 1 1 7.99,1.5 Z M8,4.5 V11.5 M5,6.25 L11,9.75 M11,6.25 L5,9.75";
    const string Bubbles = "M5.5,6 A3,3 0 1 1 5.49,6 Z M11.5,8.8 A2.2,2.2 0 1 1 11.49,8.8 Z M11,2.5 A1.5,1.5 0 1 1 10.99,2.5 Z";
    const string Speaker = "M2,6 H4.5 L8,3 V13 L4.5,10 H2 Z M10.5,5.5 Q12.5,8 10.5,10.5";
    const string DisplayDashed = "M2,4 H5 M7,4 H9 M11,4 H14 V6.5 M14,9.5 V12 H11 M9,12 H7 M5,12 H2 V9.5 M2,6.5 V4";

    /// Schließt das Fenster am Infobereich, wenn „Klimacontrol öffnen“ (Hinweis ohne Einrichtung) ins Hauptfenster führt.
    public event Action? NavigatedAway;

    /// Einrichtung hier zeigen (Hauptfenster) oder nur den Weg dorthin (Fenster am Infobereich).
    public bool InlineSetup { get; set; } = true;

    /// Raumtemperatur steht an der Skala unter dem Regler bzw. groß (Hauptfenster). Aus (Fenster am Infobereich, wie
    /// die Menüleiste am Mac): keine Skala, dafür „Raum“ in den Kennzahlen.
    public bool RoomShownElsewhere { get; set; } = true;

    /// Beschriftung im Ein/Aus-Knopf („Ein“/„Aus“).
    readonly TextBlock powerLabel = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };

    void OpenMain_Click(object sender, RoutedEventArgs e)
    {
        NavigatedAway?.Invoke();
        ((App)Application.Current).ShowMain();
    }

    public ControlPanel()
    {
        InitializeComponent();
        var powerIcon = Icons.Make(Icons.Power, 16, null, 2);
        powerIcon.Margin = new Thickness(0, 0, 6, 0);
        powerIcon.VerticalAlignment = VerticalAlignment.Center;
        PowerButton.Content = new StackPanel { Orientation = Orientation.Horizontal, Children = { powerIcon, powerLabel } };
        MinusButton.Content = Icons.Make(Icons.Minus, 16, null, 1.8);
        PlusButton.Content = Icons.Make(Icons.Plus, 16, null, 1.8);

        foreach (var (value, label, icon) in Codes.Modes)
        {
            var tile = Tile(label, icon, () => Core.Send(Cmd.Mode, ("value", value)));
            RoundInner(tile);
            modeTiles[value] = tile;
            modeLabels[value] = label;
            ModeGrid.Children.Add(tile);
        }
        // Kurzinfos und Gültigkeit je Modus kommen aus dem Kern (`Availability`), beim Zeichnen gesetzt.
        swingTile = Tile(L.T("main.comfort.swing"), Icons.Swing, () => Toggle(Cmd.Swing, s => s.Swing));
        ecoTile = Tile(L.T("main.comfort.eco"), Icons.Leaf, () => Toggle(Cmd.Eco, s => s.Eco));
        turboTile = Tile(L.T("options.fan.turbo"), Icons.Bolt, () => Toggle(Cmd.Turbo, s => s.Turbo));
        silentTile = Tile(L.T("options.fan.quietOutdoor"), Icons.Mute, () => Toggle(Cmd.OutdoorSilent, s => s.OutSilent == true));
        foreach (var t in new[] { swingTile, ecoTile, turboTile, silentTile }) ComfortGrid.Children.Add(t);

        ieco = Row(L.T("main.comfort.ieco"), GaugeLow, () => Toggle(Cmd.Ieco, s => s.Ieco == true));
        purifier = Row(L.T("main.comfort.ionizer"), Sparkles, () => Toggle(Cmd.Purifier, s => s.Purifier));
        freeze = Row(L.T("main.comfort.frostProtection"), SnowflakeCircle, () => Toggle(Cmd.FreezeProtection, s => s.FreezeProtection));
        clean = Row(L.T("main.comfort.selfClean"), Bubbles, () => _ = SelfClean());
        display = Row(L.T("main.comfort.display"), DisplayDashed, () => Core.Send(Cmd.Display));
        sound = Row(L.T("main.comfort.sound"), Speaker, () => Toggle(Cmd.Sound, s => s.Sound ?? Core.Snap.Beep));
        foreach (var r in new[] { ieco, purifier, freeze, clean, display, sound }) MoreGrid.Children.Add(r);
        RateIcon.Content = Icons.Make(GaugeHigh, 14, null, 1.4);

        BuildFan();
        TempSlider.PreviewMouseDown += (_, _) => lastTempDrag = DateTime.Now;
        // Die Skala folgt dem Knopf des Reglers: bei neuer Größe oder Vorlage neu anordnen.
        TempScale.Source = TempSlider;
        TempSlider.SizeChanged += (_, _) => TempScale.InvalidateArrange();
        TempSlider.Loaded += (_, _) => TempScale.InvalidateArrange();

        // Kennzahlen einmal anlegen; beim Zeichnen ändern sich nur Texte, Tooltips und welche zu sehen sind.
        roomValue = Reading(L.T("main.reading.room"), out roomItem, out _);
        outdoorValue = Reading(L.T("main.reading.outdoor"), out outdoorItem, out _);
        powerValue = Reading(L.T("main.reading.power"), out powerItem, out _);
        todayValue = Reading(L.T("cost.title"), out todayItem, out todayCaption);

        // Symbole der Meldungen einmal anlegen; beim Zeichnen wechselt nur, welches zu sehen ist, und die Farbe.
        warnIcon = Icons.Make(Icons.Warning, 14, null, 1.5);
        offIcon = Icons.Make(Icons.DeviceOff, 14, null, 1.4);
        MessageIcon.Content = new Grid { Children = { warnIcon, offIcon } };
        // Farbe über die Ressource, damit ein Wechsel hell/dunkel sie mitnimmt.
        NoticeIcon.SetResourceReference(ForegroundProperty, "Sub");
        NoticeIcon.Content = Icons.Make(Icons.Info, 14, null, 1.4);

        // Darstellung: Größe und Ziffernstil gleich anwenden – NaturalHeight kann vor Loaded kommen. Die große
        // Zahl setzt ihre Größe selbst (Dichte × Faktor), die übrigen Schriften skaliert SizeScale.
        SizeScale.Own(TargetText);
        SizeScale.Own(RoomBig);
        ApplyLook();

        // Timer nur solange geladen und sichtbar: ein laufender DispatcherTimer hielte ein geschlossenes Fenster im
        // Speicher fest.
        resync.Tick += (_, _) =>
        {
            resync.Stop();
            if (IsVisible) Refresh(); else stale = true;
        };
        reconcileLater.Tick += (_, _) =>
        {
            reconcileLater.Stop();
            // Nur, wenn seitdem niemand mehr am Regler war.
            if (!fanInteracting && pendingReconcile is { } p && lastFanDrag <= p.At) ReconcileZones(p.Value, p.OwnsQuiet);
            pendingReconcile = null;
        };
        tick.Tick += (_, _) => { if (IsVisible) RenderLive(); };
        // Erst abmelden: Loaded kann beim Umhängen zwischen Spalten ohne Unloaded dazwischen kommen.
        Loaded += (_, _) =>
        {
            Core.Changed -= Refresh;
            Core.Changed += Refresh;
            Theme.Changed -= ThemeChanged;
            Theme.Changed += ThemeChanged;
            Appearance.Changed -= AppearanceChanged;
            Appearance.Changed += AppearanceChanged;
            if (IsVisible) tick.Start();
            ApplyLook();
            Refresh();
        };
        Unloaded += (_, _) => Detach();
        // Ausgeblendet (z. B. das Fenster am Infobereich) nicht mitzeichnen – erst beim Einblenden nachholen.
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible) { tick.Stop(); return; }
            if (IsLoaded) tick.Start();
            if (stale) Refresh(); else RenderLive();
        };
    }

    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(5) };

    /// Knöpfe „Leistung begrenzen“ nach der Liste des Kerns einmal anlegen (erst, wenn der erste Schnappschuss da ist).
    /// RadioButton im Aussehen eines Umschaltknopfs: eine Gruppe, aus der genau eins gewählt ist. Checked schickt den
    /// Befehl – egal ob per Maus, Leertaste oder Sprachausgabe; beim Zeichnen sperrt `updating`.
    void EnsureRateButtons(RateOptions rate)
    {
        if (rateButtons.Count > 0 || rate.Choices.Count == 0) return;
        var toggleStyle = TryFindResource(typeof(ToggleButton)) as Style;
        foreach (var pct in rate.Choices)
        {
            var b = new RadioButton
            {
                Content = L.F("main.comfort.percentChoice", ("value", pct.ToString(System.Globalization.CultureInfo.InvariantCulture))), FontSize = 12, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(2, 0, 0, 0),
                GroupName = "Rate",
            };
            if (toggleStyle != null) b.Style = toggleStyle;
            ToolTipService.SetShowOnDisabled(b, true);
            AutomationProperties.SetName(b, L.F("main.windows.ratePercent", ("pct", pct.ToString(System.Globalization.CultureInfo.InvariantCulture))));
            b.Checked += (_, _) => { if (!updating && Core.Snap.State != null) Core.Send(Cmd.Rate, ("value", pct)); };
            rateButtons[pct] = b;
            RatePanel.Children.Add(b);
        }
    }

    /// Vom Kern abmelden und Timer anhalten, samt Bausteinen – beim Entladen und beim Schließen des Fensters.
    public void Detach()
    {
        Core.Changed -= Refresh;
        Theme.Changed -= ThemeChanged;
        Appearance.Changed -= AppearanceChanged;
        tick.Stop();
        resync.Stop();
        reconcileLater.Stop();
        pendingReconcile = null;
        LivelyLayer.Halt();
        WeatherLayer.Halt();
        Scenes.Detach();
        Timers.Detach();
        Setup.Detach();
    }

    /// Einmal nachzeichnen, wenn ein Regler wegen Ziehens nicht nachgeführt wurde: Changed kommt selten, ein von der
    /// Anlage abweichend zurückgemeldeter Wert bliebe sonst bis zur nächsten Abfrage falsch stehen.
    readonly DispatcherTimer resync = new() { Interval = TimeSpan.FromSeconds(1.6) };

    void ResyncSoon()
    {
        resync.Stop();
        resync.Start();
    }

    /// Hell/Dunkel oder Hoher Kontrast gewechselt: selbst gesetzte Farben neu – Spur und Marken zeichnen
    /// nur bei geändertem Schlüssel, darum den vergessen.
    void ThemeChanged()
    {
        trackKey = default;
        marksKey = default;
        Refresh();
    }

    void AppearanceChanged()
    {
        ApplyLook();
        trackKey = default;
        marksKey = default;
        Refresh();
    }

    /// Modusfarbe nach Darstellung (nach Modus, Systemfarbe oder eigene Farbe).
    internal static Color Tint(int mode) => Theme.Accent(Codes.Tint(mode));

    /// Umfang „Einfach“: „Mehr …“ aufgeklappt – gilt für alle Fenster, nur für diese Sitzung.
    static bool moreOpen;

    bool stale;

    /// Anfangsfokus fürs Fenster am Infobereich: Ein/Aus, ohne Anlage die Einrichtung bzw. ihr Hinweis.
    public void FocusFirst()
    {
        if (PowerButton.IsVisible) PowerButton.Focus();
        else MoveFocus(new System.Windows.Input.TraversalRequest(System.Windows.Input.FocusNavigationDirection.First));
    }

    /// Jemand tippt gerade (Szenenname, Uhrzeit, Einrichtung) – das Fenster am Infobereich bleibt dann offen.
    public bool IsTyping => Scenes.IsTyping || Timers.IsTyping || (Setup.IsVisible && Setup.IsKeyboardFocusWithin);

    /// Element in einer Karte mit dem inneren Radius (wie `klimaInner` am Mac). Das Fluent-Design holt den Radius der
    /// Knöpfe aus `Border.CornerRadius` bzw. der Ressource `ControlCornerRadius` – beides nur für diesen Knopf.
    internal static void RoundInner(Control c)
    {
        c.SetResourceReference(Border.CornerRadiusProperty, "InnerRadius");
        c.Resources["ControlCornerRadius"] = Theme.InnerCorner;
    }

    /// Kachel (Modus, Komfort): Symbol und Name; zu lange Namen werden kleiner statt abgeschnitten.
    static Button Tile(string label, string icon, Action click)
    {
        var text = new TextBlock { Text = label, FontSize = 12 };
        var fit = new Viewbox
        {
            Child = text, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly,
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0),
        };
        var b = new Button
        {
            Content = new StackPanel { Children = { Icons.Make(icon, 17), fit } },
            MinHeight = 54, Margin = new Thickness(3), Padding = new Thickness(4, 6, 4, 6),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        ToolTipService.SetShowOnDisabled(b, true);
        AutomationProperties.SetName(b, label);
        b.Click += (_, _) => click();
        return b;
    }

    /// Zeile der weiteren Funktionen: Symbol und Name; das Symbol nimmt die Schriftfarbe des Knopfs an.
    static Button Row(string label, string icon, Action click)
    {
        var symbol = Icons.Make(icon, 14, null, 1.3);
        symbol.Margin = new Thickness(0, 0, 7, 0);
        symbol.VerticalAlignment = VerticalAlignment.Center;
        var text = new TextBlock { Text = label, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var content = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(symbol, Dock.Left);
        content.Children.Add(symbol);
        content.Children.Add(text);
        var b = new Button
        {
            Content = content,
            Height = 34, Margin = new Thickness(3), Padding = new Thickness(10, 0, 10, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
        };
        ToolTipService.SetShowOnDisabled(b, true);
        AutomationProperties.SetName(b, label);
        b.Click += (_, _) => click();
        return b;
    }

    static void Toggle(string cmd, Func<AcState, bool> get)
    {
        var st = Core.Snap.State;
        if (st != null) Core.Send(cmd, ("on", !get(st)));
    }

    /// Selbstreinigung: Ausschalten sofort, Starten erst nach Rückfrage (über `Dialogs`, also erst nach kc_pump).
    async System.Threading.Tasks.Task SelfClean()
    {
        var st = Core.Snap.State;
        if (st == null) return;
        if (st.SelfClean == true) { Core.Send(Cmd.SelfClean, ("on", false)); return; }
        // Titel, Text und Knöpfe der Rückfrage kommen aus dem Kern.
        var p = Core.Snap.Options.Prompts.SelfClean;
        var owner = Window.GetWindow(this);
        var answer = p.Warning ? await Dialogs.AskWarn(owner, p.Title, p.Message, p.Confirm, p.Cancel)
                               : await Dialogs.Ask(owner, p.Title, p.Message, p.Confirm, p.Cancel);
        if (answer == 0 && Core.Snap.State != null) Core.Send(Cmd.SelfClean, ("on", true));
    }

    /// Aktiv = getönte Fläche mit weißer Schrift, so weit abgedunkelt, dass die Schrift mindestens 4,5:1 erreicht; bei
    /// Hohem Kontrast Systemfarben. Den Zustand bekommt auch die Sprachausgabe, nicht nur die Farbe.
    static void Paint(Control c, bool active, bool enabled, Color tint, string inactive = "")
    {
        c.IsEnabled = enabled;
        c.Opacity = enabled ? 1 : 0.45;
        AutomationProperties.SetItemStatus(c, active && enabled ? L.T("main.mode.activeValue") : inactive);
        if (active && enabled)
        {
            // Zwischengespeicherte Pinsel: unveränderte Farbe = gleicher Wert, dann zeichnet WPF nichts neu.
            var b = Theme.ActiveFillBrush(tint);
            c.Background = b;
            c.Foreground = Theme.ActiveText;
            // Neon: leuchtende Kante in der hellen Modusfarbe statt in der Flächenfarbe.
            c.BorderBrush = Neon ? Paints.Of(tint) : b;
        }
        else if (c.ReadLocalValue(BackgroundProperty) != DependencyProperty.UnsetValue)
        {
            c.ClearValue(BackgroundProperty);
            c.ClearValue(ForegroundProperty);
            c.ClearValue(BorderBrushProperty);
        }
    }

    /// Schieberegler in der Modusfarbe: das Fluent-Design holt Knopf und gefüllte Spur aus der Akzentfarbe,
    /// darum diese Schlüssel nur für diesen Regler überschreiben. Nur bei neuer Farbe – jedes Schreiben in die
    /// Ressourcen ließe den ganzen Regler seine Vorlage neu auflösen.
    static void TintSlider(Slider s, Brush tint)
    {
        if (ReferenceEquals(s.Foreground, tint)) return;
        foreach (var key in new[] { "AccentFillColorDefaultBrush", "AccentFillColorSecondaryBrush", "AccentFillColorTertiaryBrush",
                                    "SliderThumbBackground", "SliderThumbBackgroundPointerOver", "SliderThumbBackgroundPressed",
                                    "SliderTrackValueFill", "SliderTrackValueFillPointerOver", "SliderTrackValueFillPressed" })
            s.Resources[key] = tint;
        s.Foreground = tint;
    }

    /// Nur die mitlaufende Zeitangabe der Statuszeile („vor N min“); die Timer zählen selbst weiter.
    /// Ohne Zustand gehört die Statuszeile zur Startanzeige.
    void RenderLive()
    {
        var s = Core.Snap;
        if (s.State != null) RenderStatus(s);
        else if (s.Configured) Connecting.Render(s, KeysApply);
    }

    /// Kürzel nur nennen, wo sie gelten: Strg+P, Strg+R und ↑/↓ gibt es im Hauptfenster und im Fenster am Infobereich.
    bool KeysApply => Window.GetWindow(this) is MainWindow or FlyoutWindow;

    void Refresh()
    {
        if (!IsVisible) { stale = true; return; }
        stale = false;
        updating = true;
        try { Render(Core.Snap); }
        finally { updating = false; }
    }

    void Render(Snapshot s)
    {
        var st = s.State;
        var configured = s.Configured;
        SetupPanel.Visibility = configured ? Visibility.Collapsed : Visibility.Visible;
        Setup.Visibility = InlineSetup ? Visibility.Visible : Visibility.Collapsed;
        SetupHint.Visibility = InlineSetup ? Visibility.Collapsed : Visibility.Visible;
        var keys = KeysApply;
        // Startanzeige: eingerichtet, aber noch kein Zustand – auch nach einem Startfehler (Meldung steht darunter).
        var connecting = configured && st == null;
        Connecting.Visibility = connecting ? Visibility.Visible : Visibility.Collapsed;
        if (connecting) Connecting.Render(s, keys);
        var show = configured && st != null ? Visibility.Visible : Visibility.Collapsed;
        HeroBox.Visibility = ControlsCard.Visibility = GroupCard.Visibility = Timers.Visibility = show;
        // Umfang „Einfach“: Kennzahlen, Komfort, weitere Funktionen und Szenen nur nach „Mehr …“; in der Karte mit den
        // Szenen bleibt dann nur der Timer.
        var look = Appearance.Current;
        var simple = look.Scope == "simple";
        var extras = !simple || moreOpen;
        ArrangeScope(simple);
        MoreToggle.Visibility = simple && show == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        if (MoreToggle.IsChecked != moreOpen) MoreToggle.IsChecked = moreOpen;
        MoreBox.Visibility = simple && moreOpen ? show : Visibility.Collapsed;
        HeroReadingsHost.Visibility = simple ? Visibility.Collapsed : Visibility.Visible;
        ScenesHost.Visibility = GroupDivider.Visibility = simple ? Visibility.Collapsed : Visibility.Visible;
        Scenes.Visibility = extras ? show : Visibility.Collapsed;
        RenderMessages(s, keys);
        if (st == null)
        {
            FanPanel.Visibility = FanDivider.Visibility = ComfortPanel.Visibility = Visibility.Collapsed;
            LivelyLayer.Halt();
            WeatherLayer.Halt();
            return;
        }

        var tint = Tint(st.Mode);
        var tintBrush = Paints.Of(tint);
        var on = st.Power;
        // Alte Werte (Verbindung weg, Anlage aus): Kopf grau und blass mit „Stand HH:MM“,
        // damit „Heizt · noch 2°“ nicht live wirkt. Bedienbar bleibt alles (ein Befehl verbindet neu).
        var live = s.UiStaleSince == null;
        var headBrush = live ? tintBrush : DotGray;

        // Kopf
        NameText.Text = s.DisplayName;
        RenderStatus(s);
        // Bei Hohem Kontrast keine getönte Fläche, sondern die Systemfarbe.
        Hero.Background = on && live && !Theme.HighContrast ? Paints.Of(Color.FromArgb(0x40, tint.R, tint.G, tint.B)) : (Brush)FindResource("Tile");
        PowerButton.Background = on ? Theme.ActiveFillBrush(live ? tint : DotGray.Color) : (Brush)FindResource("Card");
        PowerButton.Foreground = on ? Theme.ActiveText : (Brush)FindResource("Fg");
        powerLabel.Text = L.T(on ? "main.power.stateOn" : "main.power.stateOff");
        var powerKey = on ? "main.power.turnOff" : "main.power.turnOn";
        PowerButton.ToolTip = L.Tip(powerKey, keys ? Hotkeys.Ctrl("P") : "");
        // Name = Aktion, Zustand extra (wie am Mac: Beschriftung „Ausschalten“, Wert „ein“).
        AutomationProperties.SetName(PowerButton, L.T(powerKey));
        AutomationProperties.SetItemStatus(PowerButton, L.T(on ? "main.state.on" : "main.state.off"));
        AutomationProperties.SetAcceleratorKey(PowerButton, keys ? Hotkeys.Ctrl("P") : "");
        MinusButton.ToolTip = L.Tip("main.step.cooler", keys ? "↓" : "");
        PlusButton.ToolTip = L.Tip("main.step.warmer", keys ? "↑" : "");
        AutomationProperties.SetAcceleratorKey(MinusButton, keys ? "↓" : "");
        AutomationProperties.SetAcceleratorKey(PlusButton, keys ? "↑" : "");
        OnPanel.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        OffPanel.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        // Große Zahl, Zeile darunter und Hinweis (Soll oder Raum je nach „Groß angezeigt“, Lüften, alte Werte) liefert der Kern.
        TargetText.Text = s.HeroValue;
        TargetText.Foreground = live ? Paints.Of(Theme.TextTint(tint, 3.5)) : headBrush;
        TargetText.Opacity = live ? 1 : 0.5;
        // Zeigt die große Zahl nicht das Soll, ist sie die Raumtemperatur (−/+ und Regler gelten weiter fürs Soll).
        if (s.HeroValue != Fmt.Target(st.Target)) AutomationProperties.SetName(TargetText, L.F("main.windows.roomHero", ("value", TargetText.Text)));
        else TargetText.ClearValue(AutomationProperties.NameProperty);
        RenderGlow(tint, on && live);
        RenderEffects(st, tint, on && live, look);
        GoalText.Text = s.HeroCaption;
        // Grenzen der Solltemperatur aus dem Kern.
        var range = s.Options.Temperature;
        if (range.Max > range.Min)
        {
            if (TempSlider.Minimum != range.Min) TempSlider.Minimum = range.Min;
            if (TempSlider.Maximum != range.Max) TempSlider.Maximum = range.Max;
        }
        // Lüften hat kein Temperaturziel: Raumtemperatur groß, kein −/+ und kein Regler (wie am Mac).
        var target = TargetAdjustable(s);
        MinusButton.Visibility = PlusButton.Visibility = TempRow.Visibility = target ? Visibility.Visible : Visibility.Collapsed;
        MinusButton.IsEnabled = st.Target > range.Min;
        PlusButton.IsEnabled = st.Target < range.Max;
        TintSlider(TempSlider, headBrush);
        RenderScale(s, target && on, live);
        if ((DateTime.Now - lastTempDrag).TotalSeconds > 1.5 && !TempSlider.IsMouseCaptureWithin) TempSlider.Value = Math.Round(st.Target);
        else ResyncSoon();
        RoomBig.Text = s.HeroValue;
        RoomBig.Opacity = live ? 1 : 0.5;
        OffCaption.Text = s.HeroCaption;
        OffHint.Text = s.HeroHint ?? "";
        OffHint.Visibility = string.IsNullOrEmpty(s.HeroHint) ? Visibility.Collapsed : Visibility.Visible;
        RenderReadings(s, st, live);

        // Modus
        foreach (var (mode, tile) in modeTiles)
        {
            var selected = on && st.Mode == mode;
            Paint(tile, selected, true, Tint(mode));
            var label = modeLabels[mode];
            tile.ToolTip = selected ? L.F("main.mode.active", ("mode", label)) : on ? L.F("main.mode.switchTo", ("mode", label)) : L.F("main.mode.turnOnWith", ("mode", label));
        }

        // Lüfter
        FanPanel.Visibility = FanDivider.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        ComfortPanel.Visibility = on && extras ? Visibility.Visible : Visibility.Collapsed;
        RenderFan(s, st, tint);

        // Komfort: ob ein Schalter im Modus gilt und seine Kurzinfo sagt der Kern.
        Feature(swingTile, s, "swing", st.Swing, tint);
        Feature(ecoTile, s, "eco", st.Eco, tint);
        Feature(turboTile, s, "turbo", st.Turbo, tint);
        Feature(silentTile, s, "outdoorSilent", st.OutSilent == true, tint);
        Feature(ieco, s, "ieco", st.Ieco == true, tint);
        Feature(purifier, s, "purifier", st.Purifier, tint);
        Feature(freeze, s, "freezeProtection", st.FreezeProtection, tint);
        Feature(clean, s, "selfClean", st.SelfClean == true, tint);
        Feature(display, s, "display", st.DisplayOn, tint);
        Feature(sound, s, "sound", st.Sound ?? s.Beep, tint);
        EnsureRateButtons(s.Options.Rate);
        // Gilt nur in bestimmten Modi (`availability["rate"]` des Kerns); gesperrt zeigt die Kurzinfo den Grund.
        var rateEnabled = s.IsEnabled("rate");
        var rateTip = rateEnabled ? s.Options.Rate.Help : s.Why("rate") ?? s.Options.Rate.Help;
        if (!Equals(RateRow.ToolTip, rateTip)) RateRow.ToolTip = rateTip;
        var shownRate = st.RatePercent ?? s.Options.Rate.Fallback;
        foreach (var (pct, b) in rateButtons)
        {
            b.IsChecked = shownRate == pct;
            Paint(b, b.IsChecked == true, rateEnabled, tint);
            var tip = rateEnabled ? null : rateTip;
            if (!Equals(b.ToolTip, tip)) b.ToolTip = tip;
            AutomationProperties.SetHelpText(b, tip ?? "");
        }
    }

    /// Soll verstellbar (an und nicht Lüften) nach `availability["target"]` des Kerns; ohne Eintrag nicht. Gilt für
    /// −/+, Regler und Strg+↑/↓.
    internal static bool TargetAdjustable(Snapshot s) => s.Availability.TryGetValue("target", out var a) && a.Enabled;

    /// Skala unter dem Regler nur im Hauptfenster (`RoomShownElsewhere`); bei alten Werten abgeblendet wie der Kopf.
    void RenderScale(Snapshot s, bool shown, bool live)
    {
        shown &= RoomShownElsewhere && s.Options.TemperatureScale.Labels.Count > 0;
        TempScale.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;
        TempScale.Update(s.Options.TemperatureScale, s.ScaleRoom, Theme.SizeFactor);
        TempScale.Opacity = live ? 1 : 0.5;
    }

    /// Umfang zuletzt angeordnet (null = noch nie).
    bool? arrangedSimple;

    /// Umfang „Einfach“: Kennzahlen, Komfort und Szenen unter „Mehr …“ umhängen; „Alles“: zurück in Kopf, Steuerung
    /// und Karte mit dem Timer. Nur bei Wechsel – Umhängen lädt die Bausteine neu.
    void ArrangeScope(bool simple)
    {
        if (arrangedSimple == simple) return;
        arrangedSimple = simple;
        MoveTo(Readings, simple ? MoreReadingsHost : HeroReadingsHost);
        MoveTo(ComfortPanel, simple ? MoreComfortHost : ComfortHost);
        MoveTo(Scenes, simple ? MoreScenesHost : ScenesHost);
        ApplyDensity();
    }

    static void MoveTo(FrameworkElement e, Panel host)
    {
        if (ReferenceEquals(e.Parent, host)) return;
        (e.Parent as Panel)?.Children.Remove(e);
        host.Children.Add(e);
    }

    /// Schalter nach Gültigkeit und Kurzinfo des Kerns zeichnen.
    static void Feature(Button b, Snapshot s, string feature, bool active, Color tint)
    {
        Paint(b, active, s.IsEnabled(feature), tint, L.T("main.state.off"));
        var why = s.Why(feature);
        if (!Equals(b.ToolTip, why)) b.ToolTip = why;
    }

    /// „Mehr …“ auf- oder zugeklappt (Maus, Leertaste, Sprachausgabe). Beim Zeichnen sperrt `updating`.
    void MoreToggle_Changed(object sender, RoutedEventArgs e)
    {
        if (updating) return;
        moreOpen = MoreToggle.IsChecked == true;
        Refresh();
    }

    // Ereignisse

    void Power_Click(object sender, RoutedEventArgs e)
    {
        var st = Core.Snap.State;
        if (st != null) Core.Send(Cmd.Power, ("on", !st.Power));
    }

    void Minus_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.NudgeTemp, ("delta", -1.0));
    void Plus_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.NudgeTemp, ("delta", 1.0));

    void TempSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (updating || Core.Snap.State == null || Math.Round(e.NewValue) == Math.Round(Core.Snap.State.Target)) return;
        lastTempDrag = DateTime.Now;
        Core.Send(Cmd.Temp, ("value", Math.Round(e.NewValue)));
    }

    /// „Erneut versuchen“: sofort neu abfragen; der Kern hebt dabei die Sperren der Wegwahl auf.
    void Retry_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.Refresh);
    void DismissMessage_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.DismissMessage);
    void DismissNotice_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.DismissNotice);
}
