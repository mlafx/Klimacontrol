using System.Windows;
using System.Windows.Media;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Darstellung: reine Regeln von Theme und Backdrop ohne Fenster.
public class ThemeTests
{
    [Theory]
    [InlineData("glass", 0, "Mica")]
    [InlineData("glass", 1, "Acrylic")]
    [InlineData("glass", 40, "Acrylic")]
    [InlineData("glassStrong", 0, "Acrylic")]
    [InlineData("matte", 30, "Opaque")]
    public void BackdropFollowsBackgroundAndBlur(string background, int blur, string expected)
        => Assert.Equal(expected, Backdrop.Choose(background, blur, supported: true, highContrast: false).ToString());

    [Fact]
    public void BackdropIsOpaqueOnOldWindowsAndHighContrast()
    {
        Assert.Equal(Backdrop.Kind.Opaque, Backdrop.Choose("glassStrong", 20, supported: false, highContrast: false));
        Assert.Equal(Backdrop.Kind.Opaque, Backdrop.Choose("glass", 0, supported: true, highContrast: true));
    }

    [Fact]
    public void SurfaceAlphaFollowsTransparency()
    {
        Assert.Equal(255, Theme.SurfaceAlpha("glass", 0));
        Assert.Equal(255, Theme.SurfaceAlpha("matte", 80));
        Assert.Equal(128, Theme.SurfaceAlpha("glass", 50));
        Assert.Equal(13, Theme.SurfaceAlpha("glassStrong", 200)); // höchstens 95 %
    }

    [Fact]
    public void ModeAndSize()
    {
        Assert.False(Theme.EffectiveDark("light", systemDark: true));
        Assert.True(Theme.EffectiveDark("dark", systemDark: false));
        Assert.True(Theme.EffectiveDark("system", systemDark: true));
        Assert.Equal(ThemeMode.Dark, Theme.ThemeModeFor("dark", highContrast: false));
        Assert.Equal(ThemeMode.System, Theme.ThemeModeFor("dark", highContrast: true));
        Assert.Equal(0.9, Theme.SizeFactorFor("compact"));
        Assert.Equal(1.0, Theme.SizeFactorFor("normal"));
        Assert.Equal(1.15, Theme.SizeFactorFor("large"));
    }

    [Theory]
    [InlineData("standard")]
    [InlineData("night")]
    [InlineData("neon")]
    [InlineData("minimal")]
    [InlineData("contrast")]
    public void PaletteTextIsReadable(string theme)
    {
        foreach (var dark in new[] { false, true })
        {
            var p = Theme.PaletteFor(theme, dark);
            var need = theme == "contrast" ? 7 : 4.5;
            Assert.True(Theme.Contrast(p.Fg, p.Bg) >= need, $"{theme}/{dark}: Fg");
            Assert.True(Theme.Contrast(p.Fg, p.Card) >= need, $"{theme}/{dark}: Fg auf Card");
            Assert.True(Theme.Contrast(p.Sub, p.Bg) >= 4.5, $"{theme}/{dark}: Sub");
            Assert.True(Theme.Contrast(p.Accent, p.Bg) >= 4.5, $"{theme}/{dark}: Accent");
        }
    }

    [Fact]
    public void LightStandardTextIsReadableOnTintedHeroCard()
    {
        var p = Theme.PaletteFor("standard", false);
        foreach (var mode in new[] { 1, 2, 3, 4, 5 })
        {
            var tint = Codes.Tint(mode);
            var hero = Theme.Mix(p.Card, tint, 0x40 / 255.0);
            Assert.True(Theme.Contrast(p.Sub, hero) >= 4.5, $"Modus {mode}: Sub auf Karte");
            Assert.True(Theme.Contrast(p.Fg, hero) >= 4.5, $"Modus {mode}: Fg auf Karte");
            Assert.True(Theme.Contrast(Theme.Readable(tint, hero, 3.0), hero) >= 3.0, $"Modus {mode}: große Zahl");
            Assert.True(Theme.Contrast(Theme.Readable(tint, hero, 4.5), hero) >= 4.5, $"Modus {mode}: kleine Schrift");
        }
    }

    [Fact]
    public void LightStandardTintedTextReachesRatioOnLightestGrounds()
    {
        var p = Theme.PaletteFor("standard", false);
        var window = Color.FromRgb(0xF9, 0xF9, 0xF9);
        foreach (var mode in new[] { 1, 2, 3, 4, 5 })
        {
            var tint = Codes.Tint(mode);
            foreach (var ground in new[] { window, p.Bg, p.Card })
            {
                var hero = Theme.Mix(ground, tint, 0x40 / 255.0);
                var big = Theme.TextTintOn(tint, window, 3.5);
                var small = Theme.TextTintOn(tint, window, 4.5);
                Assert.True(Theme.Contrast(big, hero) >= 3.5, $"Modus {mode}: große Zahl auf {ground}");
                Assert.True(Theme.Contrast(small, hero) >= 4.5, $"Modus {mode}: Marke/Schrift auf {ground}");
                Assert.True(Theme.Contrast(small, window) >= 4.5, $"Modus {mode}: Marke auf Fenster");
                Assert.True(Theme.Contrast(p.Sub, hero) >= 4.5, $"Modus {mode}: Sub auf {ground}");
            }
            Assert.True(Theme.Contrast(p.Sub, window) >= 4.5, "Sub auf Fenster");
        }
    }

    [Fact]
    public void StandardPaletteIsTodaysLook()
    {
        Assert.Equal(Color.FromRgb(0xF9, 0xF9, 0xF9), Theme.PaletteFor("standard", false).Bg);
        Assert.Equal(Color.FromRgb(0x2C, 0x2C, 0x2C), Theme.PaletteFor("standard", true).Bg);
        Assert.Equal(Color.FromRgb(0x60, 0xCD, 0xFF), Theme.PaletteFor("standard", true).Accent);
    }

    [Fact]
    public void ReadableReachesRatio()
    {
        var bg = Color.FromRgb(0xF9, 0xF9, 0xF9);
        Assert.True(Theme.Contrast(Theme.Readable(Theme.CustomColor("orange", false), bg, 4.5), bg) >= 4.5);
        var dark = Color.FromRgb(0x2C, 0x2C, 0x2C);
        Assert.True(Theme.Contrast(Theme.Readable(Theme.CustomColor("purple", true), dark, 4.5), dark) >= 4.5);
    }

    [Fact]
    public void ThemeTintKeepsStandardAndDimsNight()
    {
        var c = Color.FromRgb(0xF5, 0x73, 0x2E);
        Assert.Equal(c, Theme.ThemeTint(c, "standard"));
        var night = Theme.ThemeTint(c, "night");
        Assert.True(night.R < c.R);
        Assert.Equal(Theme.CustomColor("grey", false), Theme.CustomColor("gray", false));
    }

    [Fact]
    public void DigitFonts()
    {
        Assert.Equal(FontWeights.Light, Theme.DigitFontFor("normal").Weight);
        Assert.Equal(FontWeights.SemiBold, Theme.DigitFontFor("bold").Weight);
        Assert.Contains("Segoe UI Variable Display", Theme.DigitFontFor("thin").Family.Source);
        Assert.Contains("Arial Rounded", Theme.DigitFontFor("rounded").Family.Source);
    }
}
