using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;

namespace KlimacontrolTray;

/// „Neu in dieser Version“ nach einem Update: Text des Kerns, darunter OK. Schließen ohne OK lässt den Kern den Hinweis beim
/// nächsten Start wieder liefern.
sealed class WhatsNewWindow : Window
{
    /// OK gedrückt (nur dann den Befehl `dismissWhatsNew` schicken).
    public bool Confirmed { get; private set; }

    public WhatsNewWindow(WhatsNewInfo info)
    {
        Title = "Klimacontrol";
        ResizeMode = ResizeMode.NoResize;
        Width = 780;
        MaxHeight = Math.Max(320, SystemParameters.WorkArea.Height * 0.9);
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        UseLayoutRounding = true;
        SetResourceReference(BackgroundProperty, "Bg");
        SetResourceReference(TextElement.ForegroundProperty, "Fg");
        Theme.AttachWindow(this);
        AutomationProperties.SetName(this, info.Title);

        var head = new TextBlock { Text = info.Title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        head.SetResourceReference(TextBlock.FontSizeProperty, "FontSizeTitle");
        AutomationProperties.SetHeadingLevel(head, AutomationHeadingLevel.Level1);

        var list = new StackPanel { Margin = new Thickness(0, 12, 12, 0) };
        foreach (var v in info.Versions)
        {
            var h = new TextBlock { Text = v.Heading, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, list.Children.Count == 0 ? 0 : 16, 0, 4) };
            h.SetResourceReference(TextBlock.FontSizeProperty, "FontSizeNormal");
            AutomationProperties.SetHeadingLevel(h, AutomationHeadingLevel.Level2);
            list.Children.Add(h);
            foreach (var s in v.Sections)
            {
                if (s.Title.Length > 0)
                {
                    var t = new TextBlock { Text = s.Title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 2) };
                    t.SetResourceReference(TextBlock.FontSizeProperty, "FontSizeNormal");
                    list.Children.Add(t);
                }
                foreach (var item in s.Items) list.Children.Add(Bullet(item));
            }
        }
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = list, Focusable = false };

        var content = new DockPanel { Margin = new Thickness(24) };
        DockPanel.SetDock(head, Dock.Top);
        content.Children.Add(head);
        content.Children.Add(scroll);

        var ok = new Button { Content = info.Ok, MinWidth = 120, MinHeight = 32, Padding = new Thickness(12, 5, 12, 6), IsDefault = true, HorizontalAlignment = HorizontalAlignment.Right };
        if (TryFindResource("Primary") is Style primary) ok.Style = primary;
        AutomationProperties.SetName(ok, info.Ok.Replace("_", ""));
        ok.Click += (_, _) => { Confirmed = true; Close(); };
        var bar = new Border { Padding = new Thickness(24, 20, 24, 20), BorderThickness = new Thickness(0, 1, 0, 0), Child = ok };
        bar.SetResourceReference(Border.BackgroundProperty, "Tile");
        bar.SetResourceReference(Border.BorderBrushProperty, "Line");

        var root = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(bar, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(content);
        Content = root;

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            Close();
        };
        Loaded += (_, _) => { ok.Focus(); Activate(); };
    }

    /// „• “ mit hängendem Einzug; Zeilenumbrüche im Text bleiben erhalten.
    static UIElement Bullet(string text)
    {
        var grid = new Grid { Margin = new Thickness(8, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var dot = new TextBlock { Text = "•" };
        var body = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
        dot.SetResourceReference(TextBlock.FontSizeProperty, "FontSizeNormal");
        body.SetResourceReference(TextBlock.FontSizeProperty, "FontSizeNormal");
        Grid.SetColumn(body, 1);
        grid.Children.Add(dot);
        grid.Children.Add(body);
        return grid;
    }
}
