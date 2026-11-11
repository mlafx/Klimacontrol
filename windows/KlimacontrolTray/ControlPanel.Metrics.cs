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

/// Kennzahlen unter der großen Zahl (Raum, Außen, Leistung, Kosten heute) als ruhige Zeile: Name klein über dem Wert,
/// ohne Symbole. „Raum“ nur, wenn die Raumtemperatur nicht schon an der Skala bzw. groß steht (`RoomShownElsewhere`).
public partial class ControlPanel
{
    readonly TextBlock roomValue, outdoorValue, powerValue, todayValue, todayCaption;
    readonly FrameworkElement roomItem, outdoorItem, powerItem, todayItem;
    /// Kennzahlen zuletzt grau gezeichnet (alte Werte) – nur bei Wechsel umfärben.
    bool readingsStale;

    /// Eine Kennzahl (Titel, Wert) anlegen; zurück kommt der Wert-Text zum späteren Aktualisieren.
    TextBlock Reading(string title, out FrameworkElement item, out TextBlock caption)
    {
        // Farbe über die Ressource, damit ein Wechsel hell/dunkel sie mitnimmt.
        caption = new TextBlock { Text = title, FontSize = 11 };
        caption.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        // Schmale Spalte: Titel und Wert verkleinern statt abschneiden („Kosten seit 08:15“, „1,23 € · unsicher“).
        var fit = new Viewbox { Child = caption, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left };
        var value = new TextBlock { FontSize = 14, FontWeight = FontWeights.SemiBold, Typography = { NumeralAlignment = FontNumeralAlignment.Tabular } };
        var valueFit = new Viewbox
        {
            Child = value, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly,
            HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 2, 0, 0),
        };
        var panel = new StackPanel { Background = Brushes.Transparent, Margin = new Thickness(0, 0, 8, 0) };
        panel.Children.Add(fit);
        panel.Children.Add(valueFit);
        Readings.Children.Add(panel);
        item = panel;
        return value;
    }

    /// Nur Texte und Sichtbarkeit setzen; gleiche Werte lösen in WPF kein Neuzeichnen aus.
    /// `live` = false: alte Werte grau, und die Leistung fällt weg – eine alte Wattzahl liest sich wie jetzt.
    void RenderReadings(Snapshot s, AcState st, bool live)
    {
        if (readingsStale == live)
        {
            readingsStale = !live;
            foreach (var v in new[] { roomValue, outdoorValue, todayValue })
            {
                if (live) v.ClearValue(TextBlock.ForegroundProperty);
                else v.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
            }
        }
        roomItem.Visibility = RoomShownElsewhere ? Visibility.Collapsed : Visibility.Visible;
        roomValue.Text = Fmt.Temp(st.Indoor);
        // Ausgeblendet zählt im UniformGrid nicht mit; „Außen“ fehlt bei ausgeschalteter Anlage.
        outdoorItem.Visibility = st.Power ? Visibility.Visible : Visibility.Collapsed;
        outdoorValue.Text = Fmt.Temp(st.Outdoor);
        powerItem.Visibility = live ? Visibility.Visible : Visibility.Collapsed;
        powerValue.Text = Fmt.Watts(st.PowerWatts);
        powerItem.ToolTip = s.PowerCostHelp;
        // Titel, Wert und Kurzinfo der Kosten kommen fertig aus dem Kern.
        todayCaption.Text = s.CostLine.Title;
        todayValue.Text = s.CostLine.Value;
        if (!Equals(todayItem.ToolTip, s.CostLine.Help)) todayItem.ToolTip = s.CostLine.Help;
    }
}
