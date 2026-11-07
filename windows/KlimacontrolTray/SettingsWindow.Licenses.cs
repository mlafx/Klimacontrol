using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace KlimacontrolTray;

/// Reiter „Lizenzen“.
public partial class SettingsWindow
{
    bool noticesLoaded;

    /// Karten einmal beim ersten Öffnen des Reiters bauen.
    void LoadNotices()
    {
        if (noticesLoaded) return;
        noticesLoaded = true;
        foreach (var n in Core.Notices()) NoticesList.Children.Add(NoticeCard(n));
    }

    UIElement NoticeCard(NoticeInfo n)
    {
        var sub = (Brush)FindResource("Sub");
        var card = new StackPanel();

        // Kopfzeile: Name als Link, rechts Lizenz als Kapsel und Plattform.
        var head = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 8, 0) };
        if (Uri.TryCreate(n.Url, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp))
        {
            var link = new Hyperlink(new Run(n.Name)) { NavigateUri = uri, ToolTip = n.Url };
            link.RequestNavigate += (_, e) =>
            {
                try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); }
                catch (Exception ex) { App.Trace($"Link nicht geöffnet: {ex.Message}"); }
                e.Handled = true;
            };
            name.Inlines.Add(link);
        }
        else
        {
            name.Text = n.Name;
        }
        head.Children.Add(name);
        var license = new Border
        {
            CornerRadius = new CornerRadius(9),
            Background = (Brush)FindResource("Tile"),
            Padding = new Thickness(7, 1, 7, 2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = n.License, FontSize = 11, FontWeight = FontWeights.Medium },
        };
        Grid.SetColumn(license, 1);
        head.Children.Add(license);
        var platforms = new TextBlock { Text = n.Platforms, FontSize = 11, Foreground = sub, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        Grid.SetColumn(platforms, 2);
        head.Children.Add(platforms);
        card.Children.Add(head);

        foreach (var c in n.Copyright)
            card.Children.Add(new TextBlock { Text = c, FontFamily = new FontFamily("Consolas"), FontSize = 11, TextWrapping = TextWrapping.Wrap });
        card.Children.Add(new TextBlock { Text = n.Usage, FontSize = 12.5, Foreground = sub, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 2) });

        // Lizenztext aufklappbar und markierbar; Text erst beim Aufklappen setzen (die Apache-Lizenz ist lang).
        var text = new TextBox
        {
            IsReadOnly = true,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 10,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = (Brush)FindResource("Tile"),
            Padding = new Thickness(8),
            Margin = new Thickness(0, 4, 0, 0),
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        text.SetValue(AutomationProperties.NameProperty, $"Lizenztext {n.Name}");
        // Das Mausrad gehört der Seite, nicht dem Textfeld (es scrollt selbst nicht).
        text.PreviewMouseWheel += (_, e) =>
        {
            e.Handled = true;
            NoticesScroll.ScrollToVerticalOffset(NoticesScroll.VerticalOffset - e.Delta / 3.0);
        };
        var expander = new Expander { Header = "Lizenztext", FontSize = 12, Margin = new Thickness(0, 4, 0, 0), Content = text };
        expander.Expanded += (_, _) => { if (text.Text.Length == 0) text.Text = n.LicenseText; };
        card.Children.Add(expander);

        return new Border
        {
            Background = (Brush)FindResource("Card"),
            BorderBrush = (Brush)FindResource("Line"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 0, 0, 12),
            Child = card,
        };
    }
}
