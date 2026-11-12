using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace KlimacontrolTray;

/// Reiter „Darstellung“.
public partial class SettingsWindow
{
    // Darstellung: jede Wahl geht sofort an `Appearance`; angezeigt wird nur, was `Appearance.Current` danach sagt.
    // `lookUpdating` sperrt die Handler, solange die Anzeige gesetzt wird; Regler erst nach 150 ms Ruhe speichern.

    bool lookUpdating;
    readonly System.Windows.Threading.DispatcherTimer sliderTimer = new() { Interval = TimeSpan.FromMilliseconds(150) };
    RadioButton[] themeChoices = Array.Empty<RadioButton>();
    RadioButton[] swatches = Array.Empty<RadioButton>();

    void AttachAppearance()
    {
        themeChoices = new[] { ThemeStandard, ThemeNight, ThemeNeon, ThemeMinimal, ThemeContrast };
        swatches = new[] { SwatchOrange, SwatchBlue, SwatchGreen, SwatchPurple, SwatchGrey };
        sliderTimer.Tick += (_, _) => FlushSliders();
        // „Animationseffekte“ in Windows kann sich bei offenem Fenster ändern (ReduceMotion folgt dem).
        System.ComponentModel.PropertyChangedEventHandler onSystem = (_, e) =>
        {
            if (e.PropertyName is nameof(SystemParameters.ClientAreaAnimation) or nameof(SystemParameters.HighContrast))
                Dispatcher.BeginInvoke(new Action(RenderAppearance));
        };
        Appearance.Changed += RenderAppearance;
        Theme.Changed += RenderAppearance;
        SystemParameters.StaticPropertyChanged += onSystem;
        Closed += (_, _) =>
        {
            // Noch nicht übernommenen Reglerwert nicht verlieren.
            FlushSliders();
            Appearance.Changed -= RenderAppearance;
            Theme.Changed -= RenderAppearance;
            SystemParameters.StaticPropertyChanged -= onSystem;
        };
        RenderAppearance();
    }

    static void SelectTag(ComboBox box, string value) =>
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag as string == value);

    void RenderAppearance()
    {
        var a = Appearance.Current;
        lookUpdating = true;
        try
        {
            RenderThemeTiles(Core.Snap.AppearanceCustomized);

            SelectTag(LookModeBox, a.Mode);
            SelectTag(LookColorsBox, a.Colors);
            foreach (var s in swatches) s.IsChecked = s.Tag as string == a.CustomColor;
            // Wie am Mac nur sichtbar, wenn Farben „Eigene“ gewählt ist.
            LookSwatchRow.Visibility = Show(a.Colors == "custom");
            LookHighContrastHint.Visibility = Show(Theme.HighContrast);

            SelectTag(LookBackgroundBox, a.Background);
            // Während ein Reglerwert noch aussteht, nicht unter dem Finger zurückspringen.
            if (!sliderTimer.IsEnabled)
            {
                LookTransparency.Value = Math.Clamp(a.Transparency, 0, 95);
                LookBlur.Value = Math.Clamp(a.Blur, 0, 40);
                LookGlow.Value = Math.Clamp(a.Glow, 0, 100);
            }
            RenderSliderTexts();

            SelectTag(LookSizeBox, a.Size);
            SelectTag(LookDigitsBox, a.Digits);
            var (family, weight) = Theme.DigitFont;
            LookDigitPreview.FontFamily = family;
            LookDigitPreview.FontWeight = weight;
            SelectTag(LookBigBox, a.BigValue);
            SelectTag(LookScopeBox, a.Scope);
            LookTemperatureCombinedBox.IsChecked = a.TemperatureCombined;

            LookLivingBox.IsChecked = a.LivingBackground;
            LookWeatherBox.IsChecked = a.WeatherEffects;
            LookReduceBox.IsChecked = a.ReduceAnimations;
            // Animationen aus (Option oder Windows): die beiden Effekte ausgegraut, ihr gespeicherter Wert bleibt.
            LookLivingRow.IsEnabled = LookWeatherRow.IsEnabled = !Appearance.ReduceMotion;
            LookSystemMotionHint.Visibility = Show(!SystemParameters.ClientAreaAnimation);

            LookOnTopBox.IsChecked = a.AlwaysOnTop;
            LookMiniBox.IsChecked = a.MiniWindow;

            SelectTag(LookTooltipBox, a.TrayTooltip);
            LookTrayColoredBox.IsChecked = a.TrayColored;
            LookTrayAnimatedBox.IsChecked = a.TrayAnimated;
            LookPreview.Render();
        }
        finally { lookUpdating = false; }
    }

    /// Fünf Kacheln mit Mini-Vorschau aus der Palette und dem Ziffernstil des Themas; die gewählte trägt bei Abweichung
    /// „angepasst“. Der Zustand „ausgewählt“ steht auch für die Sprachausgabe (UIA-Auswahl und Status) bereit.
    void RenderThemeTiles(bool customized)
    {
        var selected = Appearance.Current.Theme;
        var wasUpdating = lookUpdating;
        lookUpdating = true;
        try
        {
            foreach (var r in themeChoices)
            {
                if (r.Tag is not string tag) continue;
                var on = tag == selected;
                r.IsChecked = on;
                var name = L.T("appearance.theme." + tag);
                var dark = tag is "night" or "neon" || Theme.SystemDark;
                var p = Theme.PaletteFor(tag, dark);
                var (family, weight) = Theme.DigitFontFor(tag switch
                {
                    "night" or "minimal" => "thin",
                    "neon" or "contrast" => "bold",
                    _ => "normal",
                });
                var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
                panel.Children.Add(new TextBlock
                {
                    Text = "24°", FontFamily = family, FontWeight = weight, FontSize = 26,
                    Foreground = new SolidColorBrush(p.Accent), HorizontalAlignment = HorizontalAlignment.Center,
                });
                panel.Children.Add(new TextBlock
                {
                    Text = name, FontSize = 12, FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal,
                    Foreground = new SolidColorBrush(p.Fg), HorizontalAlignment = HorizontalAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
                var status = "";
                if (on)
                {
                    var selectedText = L.T("settings.appearance.theme.selected");
                    var customText = L.T("settings.appearance.theme.customized");
                    status = customized ? selectedText + ", " + customText : selectedText;
                    if (customized)
                        panel.Children.Add(new TextBlock
                        {
                            Text = customText, FontSize = 10, Foreground = new SolidColorBrush(p.Sub),
                            HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
                        });
                }
                r.Background = new SolidColorBrush(p.Bg);
                r.Content = panel;
                System.Windows.Automation.AutomationProperties.SetName(r, name);
                System.Windows.Automation.AutomationProperties.SetItemStatus(r, status);
            }
            LookRestoreRow.Visibility = Show(customized);
        }
        finally { lookUpdating = wasUpdating; }
    }

    void RenderSliderTexts()
    {
        // ValueChanged kann schon während InitializeComponent kommen, bevor die Textfelder stehen.
        if (LookTransparencyText == null || LookBlurText == null || LookGlowText == null) return;
        // Regler stehen in Prozent (0–95 bzw. 0–100), Fmt.Percent erwartet wie der Mac den Anteil 0–1.
        LookTransparencyText.Text = Fmt.Percent(LookTransparency.Value / 100);
        LookBlurText.Text = Fmt.Points(LookBlur.Value);
        LookGlowText.Text = Fmt.Percent(LookGlow.Value / 100);
    }

    /// Jede Änderung aus diesem Reiter: erst einen ausstehenden Reglerwert übernehmen, dann die neue Wahl.
    void Look(Func<AppearanceSettings, AppearanceSettings> change)
    {
        FlushSliders();
        Appearance.Update(change);
    }

    void FlushSliders()
    {
        if (!sliderTimer.IsEnabled) return;
        sliderTimer.Stop();
        var t = (int)Math.Round(LookTransparency.Value);
        var b = (int)Math.Round(LookBlur.Value);
        var g = (int)Math.Round(LookGlow.Value);
        Appearance.Update(a => a with { Transparency = t, Blur = b, Glow = g });
    }

    void LookSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        RenderSliderTexts();
        if (lookUpdating) return;
        sliderTimer.Stop();
        sliderTimer.Start();
    }

    void LookTheme_Checked(object sender, RoutedEventArgs e)
    {
        if (lookUpdating || sender is not RadioButton { Tag: string theme }) return;
        FlushSliders();
        Appearance.ApplyTheme(theme);
    }

    void LookSwatch_Checked(object sender, RoutedEventArgs e)
    {
        if (lookUpdating || sender is not RadioButton { Tag: string color }) return;
        Look(a => a with { CustomColor = color });
    }

    void Look_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (lookUpdating || sender is not ComboBox { SelectedItem: ComboBoxItem { Tag: string v } } box) return;
        if (box == LookModeBox) Look(a => a with { Mode = v });
        else if (box == LookColorsBox) Look(a => a with { Colors = v });
        else if (box == LookBackgroundBox) Look(a => a with { Background = v });
        else if (box == LookSizeBox) Look(a => a with { Size = v });
        else if (box == LookDigitsBox) Look(a => a with { Digits = v });
        else if (box == LookBigBox) Look(a => a with { BigValue = v });
        else if (box == LookScopeBox) Look(a => a with { Scope = v });
        else if (box == LookTooltipBox) Look(a => a with { TrayTooltip = v });
    }

    void LookToggle_Click(object sender, RoutedEventArgs e)
    {
        if (lookUpdating || sender is not CheckBox box) return;
        var on = box.IsChecked == true;
        if (box == LookLivingBox) Look(a => a with { LivingBackground = on });
        else if (box == LookWeatherBox) Look(a => a with { WeatherEffects = on });
        else if (box == LookReduceBox) Look(a => a with { ReduceAnimations = on });
        else if (box == LookTemperatureCombinedBox) Look(a => a with { TemperatureCombined = on });
        else if (box == LookOnTopBox) Look(a => a with { AlwaysOnTop = on });
        else if (box == LookMiniBox) Look(a => a with { MiniWindow = on });
        else if (box == LookTrayColoredBox) Look(a => a with { TrayColored = on });
        else if (box == LookTrayAnimatedBox) Look(a => a with { TrayAnimated = on });
    }

    void LookRestore_Click(object sender, RoutedEventArgs e)
    {
        FlushSliders();
        Appearance.ApplyTheme(Appearance.Current.Theme);
    }

    async void LookReset_Click(object sender, RoutedEventArgs e)
    {
        FlushSliders();
        if (await Confirm(L.T("settings.appearance.reset.title"),
                L.T("settings.appearance.reset.message"),
                L.T("settings.appearance.reset.confirm")))
            Appearance.Reset();
    }
}
