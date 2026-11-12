using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace KlimacontrolTray;

/// Vorschau oben im Reiter „Darstellung“ wie am Mac (`AppearancePreview`): große Zahl, Kopfkarte, Ein/Aus und Modus,
/// wahlweise als Kühlen oder Heizen. Nur Anzeige: die Wahl Kühlen/Heizen gilt nur hier, an die Anlage geht nichts.
/// Farben, Schrift und Größe kommen aus `Theme` und den Ressourcen; `Render()` nach jeder Änderung der Darstellung.
public sealed class AppearancePreview : UserControl
{
    const int Cool = 2, Heat = 4;

    int mode = Cool;
    readonly RadioButton coolButton, heatButton;
    readonly Border card, content, powerTile, modeTile;
    readonly Grid cardBox;
    readonly TextBlock title, hero, caption;
    readonly AmbientLayer lively = new() { Kind = AmbientLayer.Layer.Lively, CornerRadius = Theme.CardRadius };
    readonly AmbientLayer weather = new() { Kind = AmbientLayer.Layer.Weather, CornerRadius = Theme.CardRadius };
    readonly DropShadowEffect glow = new() { ShadowDepth = 0, RenderingBias = RenderingBias.Performance };

    public AppearancePreview()
    {
        title = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Text = L.T("settings.appearance.preview.title") };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        coolButton = Choice(Cool, "mode.cool");
        heatButton = Choice(Heat, "mode.heat");
        var picker = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        picker.Children.Add(coolButton);
        picker.Children.Add(heatButton);
        AutomationProperties.SetName(picker, L.T("settings.appearance.preview.modePicker"));
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10), LastChildFill = false };
        DockPanel.SetDock(picker, Dock.Right);
        head.Children.Add(picker);
        head.Children.Add(title);

        hero = new TextBlock { HorizontalAlignment = HorizontalAlignment.Center };
        caption = new TextBlock { HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        caption.SetResourceReference(TextBlock.ForegroundProperty, "Sub");
        var numbers = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        numbers.Children.Add(hero);
        numbers.Children.Add(caption);

        powerTile = new Border { Width = 40, Height = 40, CornerRadius = new CornerRadius(20), HorizontalAlignment = HorizontalAlignment.Center };
        modeTile = new Border { Width = 40, Height = 32, CornerRadius = Theme.InnerCorner, Margin = new Thickness(0, 8, 0, 0), BorderThickness = new Thickness(1) };
        modeTile.SetResourceReference(Border.BackgroundProperty, "Tile");
        modeTile.SetResourceReference(Border.BorderBrushProperty, "Edge");
        var buttons = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(14, 0, 0, 0) };
        buttons.Children.Add(powerTile);
        buttons.Children.Add(modeTile);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition());
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(buttons, 1);
        body.Children.Add(numbers);
        body.Children.Add(buttons);

        card = new Border { CornerRadius = Theme.CardCorner, BorderThickness = new Thickness(1) };
        content = new Border { Child = body };
        cardBox = new Grid();
        cardBox.Children.Add(card);
        cardBox.Children.Add(lively);
        cardBox.Children.Add(content);
        cardBox.Children.Add(weather);

        var stack = new StackPanel();
        stack.Children.Add(head);
        stack.Children.Add(cardBox);
        var outer = new Border { CornerRadius = Theme.CardCorner, Padding = new Thickness(12), Child = stack };
        outer.SetResourceReference(Border.BackgroundProperty, "Bg");
        Content = outer;
        Margin = new Thickness(0, 4, 0, 4);
        AutomationProperties.SetName(this, L.T("settings.appearance.preview.accessibility"));
        Unloaded += (_, _) => { lively.Halt(); weather.Halt(); };
    }

    RadioButton Choice(int value, string key)
    {
        var r = new RadioButton
        {
            Content = L.T(key), GroupName = "AppearancePreviewMode", IsChecked = value == mode,
            Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        r.Checked += (_, _) =>
        {
            if (mode == value) return;
            mode = value;
            Render();
        };
        return r;
    }

    /// Alles aus der aktuellen Darstellung und dem zuletzt bekannten Soll/Raum neu setzen.
    public void Render()
    {
        var look = Appearance.Current;
        var f = Theme.SizeFactor;
        var tint = ControlPanel.Tint(mode);
        var st = Core.Shared.Snap.State;
        var target = st?.Target ?? 24;
        var room = st?.Indoor;
        var heroIsRoom = look.BigValue == "room" && room != null;

        hero.Text = heroIsRoom ? Fmt.Temp(room) : Fmt.Target(target);
        var (family, weight) = Theme.DigitFont;
        hero.FontFamily = family;
        hero.FontWeight = weight;
        hero.FontSize = Math.Round(56 * f);
        hero.Foreground = Paints.Of(Theme.TextTint(tint, 3.5));
        caption.Text = heroIsRoom
            ? L.F("settings.appearance.preview.target", ("value", Fmt.Target(target)))
            : L.F("settings.appearance.preview.room", ("value", Fmt.Temp(room)));
        caption.FontSize = Math.Round(13 * f * 2) / 2;

        // Wie die Kopfkarte im Hauptfenster: getönte Fläche, bei Hohem Kontrast die Systemfläche; Neon mit leuchtender Kante.
        card.Background = Theme.HighContrast ? (Brush)FindResource("Tile") : Paints.Of(Color.FromArgb(0x40, tint.R, tint.G, tint.B));
        if (Theme.EdgeGlowBrush(tint) is { } edge) card.BorderBrush = edge;
        else card.SetResourceReference(Border.BorderBrushProperty, "Line");
        card.Effect = Theme.EdgeGlow(tint);
        content.Padding = new Thickness(Math.Round(14 * f));

        powerTile.Background = Theme.ActiveFillBrush(tint);
        powerTile.Child = Icons.Make(Icons.Power, 16, Theme.ActiveText, 1.8);
        var modeBrush = Paints.Of(Theme.TextTint(tint, 3));
        modeTile.Child = Icons.Make(mode == Heat ? Icons.Flame : Icons.Snowflake, 14, modeBrush);

        // Leuchten der großen Zahl nach derselben Regel wie im Hauptfenster.
        var g = Math.Clamp(look.Glow, 0, 100) / 100.0;
        if (g <= 0 || Theme.HighContrast) hero.Effect = null;
        else
        {
            glow.Color = tint;
            glow.BlurRadius = Math.Round(6 + 24 * g);
            glow.Opacity = g * (look.Theme == "night" ? 0.5 : 0.9);
            hero.Effect = glow;
        }

        // Die Ebenen prüfen selbst „Animationen reduzieren“ und ob das Fenster sichtbar ist.
        lively.Show(look.LivingBackground && !Theme.HighContrast, mode, tint);
        weather.Show(look.WeatherEffects && !Theme.HighContrast, mode, tint);
    }
}
