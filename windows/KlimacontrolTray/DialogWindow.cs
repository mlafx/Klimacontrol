using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Shapes;

namespace KlimacontrolTray;

/// Rückfrage/Hinweis im Fluent-Design. Erster Knopf = Standard (Enter), Esc bzw. Schließen = -1. Nur über `Dialogs`
/// benutzen.
sealed class DialogWindow : Window
{
    public enum Kind { Question, Info, Warning }

    /// Fragezeichen im Kreis (16×16).
    const string QuestionIcon = "M8,1.5 A6.5,6.5 0 1 1 7.99,1.5 Z M6.1,6.2 A1.95,1.95 0 1 1 8.7,8 C8.2,8.25 8,8.6 8,9.3 M8,11.4 V11.6";

    public int Result { get; private set; } = -1;
    /// Stand des optionalen Häkchens beim Schließen (false ohne Häkchen).
    public bool OptionChecked => option?.IsChecked == true;

    readonly CheckBox? option;

    readonly string title, text;

    public DialogWindow(Window? owner, Kind kind, string title, string text, string[] buttons, string? optionText = null)
    {
        this.title = title;
        this.text = text;
        if (buttons.Length == 0) buttons = new[] { L.T("common.ok") };

        Title = "Klimacontrol";
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        MinWidth = 360;
        MaxWidth = 520;
        UseLayoutRounding = true;
        SetResourceReference(BackgroundProperty, "Bg");
        SetResourceReference(TextElement.ForegroundProperty, "Fg");
        Theme.AttachWindow(this);
        AutomationProperties.SetName(this, title);
        AutomationProperties.SetHelpText(this, text);
        AutomationProperties.SetIsDialog(this, true);

        if (owner != null)
        {
            Owner = owner;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ShowInTaskbar = false;
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Topmost = true;
            ShowInTaskbar = true;
        }

        var icon = Icons.Make(kind switch { Kind.Info => Icons.Info, Kind.Warning => Icons.Warning, _ => QuestionIcon }, 32, null, 2);
        icon.SetResourceReference(Shape.StrokeProperty, kind == Kind.Warning ? "Warn" : "Accent");
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 16, 0);

        var head = new TextBlock
        {
            Text = title,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 400,
        };
        head.SetResourceReference(TextBlock.FontSizeProperty, "FontSizeTitle");
        AutomationProperties.SetHeadingLevel(head, AutomationHeadingLevel.Level1);
        var body = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 400,
            Margin = new Thickness(0, 8, 0, 0),
            Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible,
        };
        body.SetResourceReference(TextBlock.FontSizeProperty, "FontSizeNormal");
        var words = new StackPanel();
        words.Children.Add(head);
        words.Children.Add(body);
        if (!string.IsNullOrEmpty(optionText))
        {
            option = new ClickCheckBox { Content = optionText, IsChecked = true, Margin = new Thickness(0, 12, 0, 0) };
            AutomationProperties.SetName(option, optionText);
            words.Children.Add(option);
        }

        var content = new Grid { Margin = new Thickness(24, 24, 24, 24) };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.Children.Add(icon);
        Grid.SetColumn(words, 1);
        content.Children.Add(words);

        var row = new UniformGrid { Rows = 1, HorizontalAlignment = buttons.Length == 1 ? HorizontalAlignment.Right : HorizontalAlignment.Stretch };
        for (var i = 0; i < buttons.Length; i++)
        {
            var index = i;
            var b = new Button
            {
                Content = buttons[i],
                MinWidth = 120,
                MinHeight = 32,
                Padding = new Thickness(12, 5, 12, 6),
                Margin = new Thickness(i == 0 ? 0 : 4, 0, i == buttons.Length - 1 ? 0 : 4, 0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                IsDefault = i == 0,
            };
            if (i == 0 && TryFindResource("Primary") is Style primary) b.Style = primary;
            AutomationProperties.SetName(b, buttons[i].Replace("_", ""));
            b.Click += (_, _) => Finish(index);
            row.Children.Add(b);
        }
        var bar = new Border
        {
            Padding = new Thickness(24, 20, 24, 20),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = row,
        };
        bar.SetResourceReference(Border.BackgroundProperty, "Tile");
        bar.SetResourceReference(Border.BorderBrushProperty, "Line");

        var root = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(bar, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(content);
        Content = root;

        PreviewKeyDown += OnKey;
        Loaded += (_, _) =>
        {
            if (row.Children.OfType<Button>().FirstOrDefault() is { } first) first.Focus();
            Activate();
        };
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Finish(-1);
        }
        else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control)
        {
            // Strg+C kopiert Titel und Text wie bei Windows-Meldungen.
            e.Handled = true;
            try { Clipboard.SetText(string.IsNullOrEmpty(text) ? title : title + Environment.NewLine + Environment.NewLine + text); }
            catch { }
        }
        else if (e.Key is Key.Left or Key.Right && Keyboard.FocusedElement is Button)
        {
            e.Handled = true;
            ((UIElement)Keyboard.FocusedElement).MoveFocus(new TraversalRequest(e.Key == Key.Left ? FocusNavigationDirection.Previous : FocusNavigationDirection.Next));
        }
    }

    void Finish(int index)
    {
        Result = index;
        Close();
    }
}
