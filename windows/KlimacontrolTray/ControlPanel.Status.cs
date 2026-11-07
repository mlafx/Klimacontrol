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

/// Verbindungszeile im Kopf und Meldungen (Fehler, „Anlage aus“, Hinweise).
public partial class ControlPanel
{
    readonly Path warnIcon, offIcon;

    /// Fehler orange mit Warndreieck (mit „Erneut versuchen“, wenn die Verbindung scheiterte), „Anlage ausgeschaltet
    /// oder ohne Strom“ ruhig in Grau; darunter der Hinweis zu einem Befehl.
    void RenderMessages(Snapshot s, bool keys)
    {
        MessageBanner.Visibility = s.Message != null ? Visibility.Visible : Visibility.Collapsed;
        var key = MessageKey(s);
        if (s.Message != null)
        {
            var quiet = s.DeviceOffNotice || s.UiConnectionState == "deviceOff";
            var fg = quiet ? (Brush)FindResource("Sub") : WarnText;
            if (key != shownMessage) { shownMessage = key; FillMessage(s); }
            MessageText.Foreground = fg;
            MessageBanner.Background = Theme.HighContrast ? (Brush)FindResource("Tile")
                                     : quiet ? (Brush)FindResource("Tile") : Paints.Of(Color.FromArgb(0x38, 0xF5, 0x9E, 0x0B));
            warnIcon.Visibility = quiet ? Visibility.Collapsed : Visibility.Visible;
            offIcon.Visibility = quiet ? Visibility.Visible : Visibility.Collapsed;
            warnIcon.Stroke = offIcon.Stroke = fg;
            RetryButton.Visibility = s.LastRefreshFailed ? Visibility.Visible : Visibility.Collapsed;
            var retry = s.Options.Texts.Retry;
            if (retry.Length > 0 && !Equals(RetryButton.Content, retry)) RetryButton.Content = retry;
            var retryTip = keys ? "Sofort neu abfragen (Strg+R)" : "Sofort neu abfragen";
            if (!Equals(RetryButton.ToolTip, retryTip)) RetryButton.ToolTip = retryTip;
            AutomationProperties.SetAcceleratorKey(RetryButton, keys ? "Strg+R" : "");
            // Fehler sofort ansagen, „Anlage ausgeschaltet“ nur höflich.
            AutomationProperties.SetLiveSetting(MessageText, quiet ? AutomationLiveSetting.Polite : AutomationLiveSetting.Assertive);
        }
        else shownMessage = null;
        NoticeBanner.Visibility = s.Notice != null ? Visibility.Visible : Visibility.Collapsed;
        FillNotice(s);
        if (key != lastMessage) { lastMessage = key; if (key != null) Announce(MessageText); }
        if (s.Notice != lastNotice) { lastNotice = s.Notice; if (s.Notice != null) Announce(NoticeText); }
    }

    /// Hinweis zu einem Befehl; hat der Kern einen Code dazu, steht er klein und abgesetzt am Ende (wie bei Fehlermeldungen).
    void FillNotice(Snapshot s)
    {
        var key = s.Notice == null ? null : $"{s.Notice}\u001F{s.NoticeDetail?.Code}";
        if (key == shownNotice) return;
        shownNotice = key;
        if (s.NoticeDetail is not { } d || string.IsNullOrWhiteSpace(d.Code) || string.IsNullOrWhiteSpace(d.What))
        {
            NoticeText.Text = s.Notice ?? "";
            return;
        }
        NoticeText.Inlines.Clear();
        NoticeText.Inlines.Add(new Run(string.IsNullOrWhiteSpace(d.Todo) ? d.What.Trim() : d.What.Trim() + " " + d.Todo.Trim()));
        NoticeText.Inlines.Add(CodeRun(d.Code));
    }

    /// Code einer Meldung, klein und grau: reine Zahl als „(Code 3123)“, sonst der Code selbst („(no-device)“).
    static Run CodeRun(string code)
    {
        code = code.Trim();
        var run = new Run("  (" + (code.All(char.IsDigit) ? "Code " + code : code) + ")") { FontSize = 10.5 };
        run.SetResourceReference(TextElement.ForegroundProperty, "Sub");
        return run;
    }

    /// Zuletzt angesagte Meldung bzw. zuletzt angesagter Hinweis – nur ein Wechsel wird angesagt.
    string? lastMessage, lastNotice;
    /// Zuletzt in MessageText gesetzte Meldung – die Zeilen nur bei neuer Meldung neu aufbauen.
    string? shownMessage;
    /// Zuletzt in NoticeText gesetzter Hinweis samt Code.
    string? shownNotice;

    /// Vergleichswert einer Meldung: Text samt Zerlegung (null = keine Meldung).
    static string? MessageKey(Snapshot s) =>
        s.Message == null ? null
        : s.MessageDetail is { } d ? $"{s.Message}\u001F{d.What}\u001F{d.Todo}\u001F{d.Code}" : s.Message;

    /// Muster „Was ist passiert. Was tun.“: erste Zeile fett, zweite normal, der Code klein und grau am Ende.
    /// Ohne Zerlegung der ganze Satz.
    void FillMessage(Snapshot s)
    {
        if (s.MessageDetail is not { } d || string.IsNullOrWhiteSpace(d.What))
        {
            MessageText.Text = s.Message ?? "";
            return;
        }
        MessageText.Inlines.Clear();
        MessageText.Inlines.Add(new Run(d.What.Trim()) { FontWeight = FontWeights.SemiBold });
        if (!string.IsNullOrWhiteSpace(d.Todo))
        {
            MessageText.Inlines.Add(new LineBreak());
            MessageText.Inlines.Add(new Run(d.Todo.Trim()));
        }
        if (!string.IsNullOrWhiteSpace(d.Code)) MessageText.Inlines.Add(CodeRun(d.Code));
    }

    /// Live-Bereich geändert: die Sprachausgabe liest den neuen Text vor (LiveSetting am Element bestimmt, wie dringend).
    internal static void Announce(UIElement e)
    {
        var peer = UIElementAutomationPeer.FromElement(e) ?? UIElementAutomationPeer.CreatePeerForElement(e);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    /// Orange der Fehlermeldung, lesbar auf hellem und dunklem Grund; bei Hohem Kontrast die Systemschrift. Bei jedem
    /// Zeichnen frisch, damit ein Wechsel hell/dunkel mitgeht.
    static Brush WarnText => Theme.HighContrast ? SystemColors.WindowTextBrush
                           : Paints.Of(Theme.Dark ? Color.FromRgb(0xFF, 0xB0, 0x4D) : Color.FromRgb(0xB4, 0x5A, 0x00));
    static readonly SolidColorBrush DotGreen = Paints.Of(Color.FromRgb(0x3C, 0xC1, 0x5A));
    static readonly SolidColorBrush DotOrange = Paints.Of(Color.FromRgb(0xF5, 0x9E, 0x0B));
    static readonly SolidColorBrush DotGray = Paints.Of(Color.FromRgb(0x8E, 0x8E, 0x93));

    /// Verbindungszeile im Kopf (mit Zustand); ohne Zustand zeichnet die Startanzeige dieselbe Zeile.
    void RenderStatus(Snapshot s)
    {
        var (text, dot) = Status(s);
        StatusDot.Fill = dot;
        StatusText.Text = text;
        var tip = StatusTip(s);
        if (!Equals(StatusRow.ToolTip, tip)) StatusRow.ToolTip = tip;
    }

    /// Text und Punkt der Verbindungszeile: grün = live, orange = Verbindungsfehler, grau = Anlage aus/stromlos bzw.
    /// verbindet noch. Den Text (`ConnectionLine`, zeitabhängig) und den Zustand liefert der Kern; Hinweise zu Befehlen
    /// (`Notice`) ändern die Zeile nicht.
    internal static (string Text, SolidColorBrush Dot) Status(Snapshot s)
    {
        var ui = s.UiConnectionState;
        var dot = ui == "live" ? DotGreen : ui == "noConnection" ? DotOrange : DotGray;
        return (s.ConnectionLine, dot);
    }

    /// Kurzinfo der Verbindungszeile aus dem Kern (leer ohne Einrichtung).
    internal static string? StatusTip(Snapshot s) => s.Configured && s.ConnectionTooltip.Length > 0 ? s.ConnectionTooltip : null;
}
