using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

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
            foreach (var r in themeChoices) r.IsChecked = r.Tag as string == a.Theme;

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
        }
        finally { lookUpdating = false; }
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
        else if (box == LookOnTopBox) Look(a => a with { AlwaysOnTop = on });
        else if (box == LookMiniBox) Look(a => a with { MiniWindow = on });
        else if (box == LookTrayColoredBox) Look(a => a with { TrayColored = on });
        else if (box == LookTrayAnimatedBox) Look(a => a with { TrayAnimated = on });
    }

    async void LookReset_Click(object sender, RoutedEventArgs e)
    {
        FlushSliders();
        if (await Confirm("Darstellung zurücksetzen?",
                "Alle Werte dieses Reiters kommen auf das gewohnte Aussehen zurück.",
                "Zurücksetzen"))
            Appearance.Reset();
    }
}
