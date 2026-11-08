using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Timer: zeigt Snapshot.OffAt/OnAt mit den fertigen Texten des Kerns und schickt `offTimer`/`onTimer`; ausgeführt
/// werden die Timer vom Kern.
public partial class TimerRow : UserControl
{
    static Core Core => Core.Shared;

    /// Rückfall, falls der Kern keine Voraussetzung liefert.
    static string FallbackRequirement => L.T("timer.requirement");
    /// Erklärtext unter dem Uhrzeitfeld mit der Voraussetzung aus dem Kern; beim Zeichnen nachgeführt.
    string hint = HintText("");

    static string Requirement(string fromCore) => string.IsNullOrWhiteSpace(fromCore) ? FallbackRequirement : fromCore.Trim();

    static string HintText(string requirement) =>
        L.F("main.timer.windows.onNote", ("requirement", Requirement(requirement)));

    readonly ContextMenu offMenu = new() { Placement = PlacementMode.Bottom };
    /// Weckt genau dann, wenn sich die angezeigte Restzeit um eine Minute ändert, und um Mitternacht („morgen“ → „heute“).
    readonly DispatcherTimer minute = new();
    readonly System.Windows.Shapes.Path offIcon, onIcon;
    bool compact;

    public TimerRow()
    {
        InitializeComponent();
        // Farbe über die Ressource, damit ein Wechsel hell/dunkel sie mitnimmt.
        TimerIcon.SetResourceReference(ForegroundProperty, "Sub");
        TimerIcon.Content = Icons.Make(Icons.Timer, 15);
        offIcon = Icons.Make(Icons.Power, 13, null, 1.6);
        onIcon = Icons.Make(Icons.Sun, 13, null, 1.4);
        OffChipIcon.Content = offIcon;
        OnChipIcon.Content = onIcon;
        OffClear.Content = Icons.Make(Icons.Close, 9, null, 1.8);
        OnClear.Content = Icons.Make(Icons.Close, 9, null, 1.8);
        OnTimerButton.Content = L.T("main.timer.onButton");
        OnTimeBox.Text = Fmt.ClockOf(7, 0);
        OnTimeBox.ToolTip = L.F("main.timer.windows.timeHelp", ("example", Fmt.ClockOf(7, 30)));
        // Pfeil wie bei Windows-Menüknöpfen: der Knopf öffnet eine Auswahl.
        var chevron = Icons.Glyph(((char)0xE70D).ToString(), 9);
        chevron.Margin = new Thickness(6, 1, 0, 0);
        OffTimerButton.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children = { new TextBlock { Text = L.T("main.timer.offMenu"), VerticalAlignment = VerticalAlignment.Center }, chevron },
        };
        TimerHint.Text = hint;

        minute.Tick += (_, _) =>
        {
            minute.Stop();
            // Die Restzeit „Aus in …“ liefert der Kern über kc_live_json: frisch lesen, bevor gezeichnet wird.
            Core.Poll();
            Refresh();
        };
        // Erst abmelden: Loaded kann beim Umhängen zwischen Spalten ohne Unloaded dazwischen kommen.
        Loaded += (_, _) =>
        {
            Core.Changed -= Refresh;
            Core.Changed += Refresh;
            Theme.Changed -= Refresh;
            Theme.Changed += Refresh;
            // Größe kommt über ControlPanel.ApplyDensity.
            Appearance.Changed -= Refresh;
            Appearance.Changed += Refresh;
            Refresh();
        };
        Unloaded += (_, _) => Detach();
        // Timer nur solange geladen und sichtbar: ein laufender DispatcherTimer hielte ein geschlossenes Fenster im
        // Speicher fest. Beim Einblenden stimmt die Restzeit evtl. nicht mehr – darum immer neu zeichnen.
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible) Refresh();
            else minute.Stop();
        };
    }

    /// Kompakte Dichte für knappe Fensterhöhe. Den Abstand nach oben setzt der Baustein selbst (Margin), damit er nicht
    /// doppelt zählt.
    public bool Compact
    {
        get => compact;
        set
        {
            if (compact == value) return;
            compact = value;
            ApplyDensity();
        }
    }

    /// Abstände nach Dichte und „Größe“ (`Theme.SizeFactor`).
    internal void ApplyDensity()
    {
        var f = Theme.SizeFactor;
        double D(double normal, double small) => Math.Round((compact ? small : normal) * f);
        Margin = new Thickness(0, D(14, 8), 0, 0);
        TimerCard.Padding = new Thickness(D(12, 12), D(8, 4), D(12, 12), D(8, 4));
    }

    /// Das Uhrzeitfeld hat den Tastaturfokus (das Fenster am Infobereich soll dann z. B. nicht schließen).
    public bool IsTyping => OnTimeBox.IsKeyboardFocusWithin;

    /// Vom Kern abmelden und Timer anhalten – beim Entladen und beim Schließen des Fensters.
    public void Detach()
    {
        Core.Changed -= Refresh;
        Theme.Changed -= Refresh;
        Appearance.Changed -= Refresh;
        minute.Stop();
    }

    void Refresh()
    {
        if (!IsVisible) { minute.Stop(); return; }
        Render(Core.Snap);
    }

    /// Auswahl „Ausschalten in …“ nach der Liste des Kerns, einmal angelegt.
    void EnsureOffMenu(List<OffTimerChoice> choices)
    {
        if (offMenu.Items.Count > 0 || choices.Count == 0) return;
        foreach (var c in choices)
        {
            var minutes = c.Minutes;
            var item = new MenuItem { Header = c.Label };
            item.Click += (_, _) => Core.Send(Cmd.OffTimer, ("minutes", minutes));
            offMenu.Items.Add(item);
        }
    }

    void Render(Snapshot s)
    {
        EnsureOffMenu(s.Options.OffTimerChoices);
        var tint = s.State != null ? Paints.Of(ControlPanel.Tint(s.State.Mode)) : (Brush)FindResource("Accent");
        var newHint = HintText(s.TimerRequirement);
        if (newHint != hint)
        {
            // Steht gerade der Erklärtext da (keine Fehlermeldung), gleich mitnehmen.
            if (TimerHint.Text == hint) TimerHint.Text = newHint;
            hint = newHint;
        }
        var offTip = L.F("main.timer.offHelp", ("requirement", Requirement(s.TimerRequirement)));
        if (!Equals(OffTimerButton.ToolTip, offTip)) OffTimerButton.ToolTip = offTip;

        var off = s.OffAt;
        // Ausgeschaltet gibt es nichts auszuschalten.
        OffTimerButton.Visibility = off.HasValue || s.State?.Power != true ? Visibility.Collapsed : Visibility.Visible;
        OffChip.Visibility = off.HasValue ? Visibility.Visible : Visibility.Collapsed;
        if (off.HasValue)
        {
            OffChipText.Text = s.OffTimerChip ?? "";
            OffChipText.Foreground = offIcon.Stroke = tint;
            OffChip.ToolTip = L.F("main.timer.windows.switchesOff", ("when", s.OffTimerLabel ?? L.F("common.atTime", ("time", Fmt.Clock(off.Value)))));
        }

        var on = s.OnAt;
        OnTimerButton.Visibility = on.HasValue ? Visibility.Collapsed : Visibility.Visible;
        OnChip.Visibility = on.HasValue ? Visibility.Visible : Visibility.Collapsed;
        if (on.HasValue)
        {
            // „Ein heute 22:00“ / „Ein morgen 07:00“ aus dem Kern.
            OnChipText.Text = s.OnTimerChip ?? "";
            OnChipText.Foreground = onIcon.Stroke = tint;
            OnChip.ToolTip = hint;
            // Gesetzt (auch von einem anderen Fenster aus): die Eingabe ist erledigt.
            if (OnTimePicker.Visibility == Visibility.Visible && !OnTimeBox.IsKeyboardFocusWithin) ClosePicker();
        }

        ScheduleMinute(off, on);
    }

    /// „heute“, „morgen“ oder Wochentag mit Datum („am Mi., 07.11.“).
    static string DayLabel(DateTime at, DateTime now)
    {
        if (at.Date == now.Date) return L.T("date.today");
        if (at.Date == now.Date.AddDays(1)) return L.T("date.tomorrow");
        return L.F("main.timer.windows.onWeekdayDate", ("weekday", Fmt.WeekdayShort(at)), ("date", Fmt.DayMonth(at)));
    }

    /// Nächster Zeitpunkt mit dieser Uhrzeit: heute, liegt sie schon zurück, morgen (so rechnet auch der Kern).
    static DateTime NextAt(TimeSpan time, DateTime now)
    {
        var at = now.Date + time;
        return at <= now ? at.AddDays(1) : at;
    }

    static double SecondsLeft(double epoch) => epoch - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    /// Nächster Zeitpunkt, an dem die gerundete Restzeit eine Minute weniger zeigt: angezeigt wird
    /// m = ⌊left/60 + 0,5⌋, auf m − 1 springt es bei left = (m − 0,5) · 60. Unter 30 s bleibt „0 min“ stehen, bis der
    /// Kern den Timer auslöst (dann kommt ohnehin ein neuer Zustand).
    void ScheduleMinute(double? offAt, double? onAt)
    {
        minute.Stop();
        if (!IsLoaded || !IsVisible) return;
        double? wait = null;
        if (offAt.HasValue)
        {
            var left = SecondsLeft(offAt.Value);
            if (left >= 30)
            {
                var m = Math.Floor(left / 60 + 0.5);
                wait = left - (m - 0.5) * 60 + 0.05;
            }
        }
        // Ein-Timer: kurz nach Mitternacht neu zeichnen, dann stimmt „heute“/„morgen“ wieder.
        if (onAt.HasValue)
        {
            var midnight = (DateTime.Today.AddDays(1) - DateTime.Now).TotalSeconds + 1;
            wait = wait is { } w ? Math.Min(w, midnight) : midnight;
        }
        if (wait is not { } next) return;
        minute.Interval = TimeSpan.FromSeconds(Math.Max(0.2, next));
        minute.Start();
    }

    // Ereignisse

    void OffTimer_Click(object sender, RoutedEventArgs e)
    {
        offMenu.PlacementTarget = OffTimerButton;
        offMenu.IsOpen = true;
    }

    void OffClear_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.OffTimer);
    void OnClear_Click(object sender, RoutedEventArgs e) => Core.Send(Cmd.OnTimer);

    /// Öffnet bzw. schließt die Uhrzeit-Eingabe. Startwert 07:00, danach bleibt die zuletzt eingegebene Zeit stehen.
    void OnTimer_Click(object sender, RoutedEventArgs e)
    {
        if (OnTimePicker.Visibility == Visibility.Visible) { ClosePicker(); return; }
        ShowHint(null);
        UpdateDay();
        OnTimePicker.Visibility = Visibility.Visible;
        // Erst nach dem Layout fokussieren – gerade eingeblendet ist das Feld noch nicht bereit.
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            OnTimeBox.Focus();
            Keyboard.Focus(OnTimeBox);
            OnTimeBox.SelectAll();
        });
    }

    void OnTimeSet_Click(object sender, RoutedEventArgs e)
    {
        if (!TryParseTime(OnTimeBox.Text, out var t))
        {
            ShowHint(L.F("main.timer.windows.invalidTime", ("example", Fmt.ClockOf(7, 30))));
            OnTimeBox.Focus();
            OnTimeBox.SelectAll();
            return;
        }
        OnTimeBox.Text = Fmt.ClockOf(t.Hours, t.Minutes);
        // Nur Stunde und Minute: das nächste Vorkommen (heute bzw. morgen) rechnet der Kern.
        Core.Send(Cmd.OnTimer, ("hour", t.Hours), ("minute", t.Minutes));
        ClosePicker();
    }

    void OnTimeCancel_Click(object sender, RoutedEventArgs e) => ClosePicker();

    void ClosePicker()
    {
        OnTimePicker.Visibility = Visibility.Collapsed;
        ShowHint(null);
    }

    /// Hinweis unter dem Uhrzeitfeld; mit Text als Fehlermeldung (rot, wird angesagt), ohne zurück zum Erklärtext.
    /// Farbe über die Ressource, damit ein Wechsel hell/dunkel sie mitnimmt.
    void ShowHint(string? error)
    {
        TimerHint.Text = error ?? hint;
        TimerHint.SetResourceReference(TextBlock.ForegroundProperty, error != null ? "Bad" : "Sub");
        if (error != null) Announce(TimerHint);
    }

    static void Announce(UIElement e)
    {
        var peer = UIElementAutomationPeer.FromElement(e) ?? UIElementAutomationPeer.CreatePeerForElement(e);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    /// „Schaltet heute um 07:30 ein“ unter dem Feld, beim Tippen nachgeführt; leer, solange die Eingabe keine Uhrzeit ist.
    void UpdateDay()
    {
        if (!TryParseTime(OnTimeBox.Text, out var t)) { OnDayText.Text = ""; OnDayText.Visibility = Visibility.Collapsed; return; }
        var now = DateTime.Now;
        var at = NextAt(t, now);
        var text = L.F("main.timer.switchesOn", ("day", DayLabel(at, now)), ("time", Fmt.Clock(at)));
        OnDayText.Visibility = Visibility.Visible;
        if (OnDayText.Text == text) return;
        OnDayText.Text = text;
        if (OnTimePicker.Visibility == Visibility.Visible) Announce(OnDayText);
    }

    void OnTime_TextChanged(object sender, TextChangedEventArgs e)
    {
        // Kommt schon beim Laden (Text="07:00"), bevor die Elemente darunter angelegt sind.
        if (OnDayText == null || TimerHint == null) return;
        UpdateDay();
        // Fehlermeldung verschwindet, sobald wieder eine Uhrzeit dasteht.
        if (OnDayText.Visibility == Visibility.Visible && TimerHint.Text != hint) ShowHint(null);
    }

    void OnTime_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { OnTimeSet_Click(sender, e); e.Handled = true; }
        else if (e.Key == Key.Escape) { ClosePicker(); e.Handled = true; }
    }

    static readonly System.Text.RegularExpressions.Regex DotBetweenDigits = new(@"(?<=\d)\.(?=\d)", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    /// Nimmt „7:30“, „07:30“, „7.30“, „730“, „0730“, „7“ (= 7:00) und mit AM/PM („7:30 PM“), wo das Format es kennt.
    static bool TryParseTime(string text, out TimeSpan time)
    {
        var x = DotBetweenDigits.Replace(text.Trim(), ":");
        if (x.Length > 0 && x.All(char.IsDigit))
            x = x.Length <= 2 ? x + ":00" : x.Length <= 4 ? x[..^2] + ":" + x[^2..] : x;
        time = default;
        if (!Fmt.ParseTime(x, out var hour, out var minute)) return false;
        time = new TimeSpan(hour, minute, 0);
        return true;
    }
}
