using System;
using System.IO;
using System.Linq;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Zurückgehaltene Updates: Kopie, Prüfsumme, Erinnerung, Beiseitelegen statt Löschen.
/// Jeder Test hat einen eigenen Ordner unter %TEMP%\KlimacontrolTests (bleibt liegen, wird nicht gelöscht).
public sealed class UpdateHoldTests
{
    readonly string root = Path.Combine(Path.GetTempPath(), "KlimacontrolTests", "hold-" + Guid.NewGuid().ToString("N"));
    string Download => Path.Combine(root, "download");
    string Dir => Path.Combine(root, "update");

    public UpdateHoldTests() => Directory.CreateDirectory(Download);

    string Setup(string version, string content)
    {
        var path = Path.Combine(Download, $"Klimacontrol-Windows-{version}-Setup.exe");
        File.WriteAllText(path, content);
        return path;
    }

    [Theory]
    [InlineData(@"C:\Temp\x\Klimacontrol-Windows-1.3.0.0-Setup.exe", "1.3.0.0")]
    [InlineData("klimacontrol-windows-2.0.1.4-setup.EXE", "2.0.1.4")]
    [InlineData("Klimacontrol-Windows-Setup.exe", null)]
    [InlineData("Klimacontrol-Windows-1.3.0.0b1-Setup.exe", null)]
    [InlineData("Klimacontrol-Windows-1.3.0.0-Setup.exe.tmp", null)]
    [InlineData("anderes.exe", null)]
    public void VersionAusDemDateinamen(string path, string? version) => Assert.Equal(version, UpdateHold.VersionFromFileName(path));

    [Theory]
    [InlineData("1.3.0.0", "1.2.0.0", true)]
    [InlineData("1.2.0.1", "1.2.0.0", true)]
    [InlineData("1.2.0.0", "1.2.0.0", false)]
    [InlineData("1.1.0.0", "1.2.0.0", false)]
    [InlineData("?", "1.2.0.0", false)]
    [InlineData("1.3.0.0", "?", false)]
    public void NeuerAlsDieseFassung(string held, string current, bool newer) => Assert.Equal(newer, UpdateHold.IsNewer(held, current));

    [Fact]
    public void ErinnerungFaelligAbDemZeitpunkt()
    {
        Assert.True(UpdateHold.ReminderDue(100, 100));
        Assert.True(UpdateHold.ReminderDue(101, 100));
        Assert.False(UpdateHold.ReminderDue(99.5, 100));
    }

    [Fact]
    public void ZurueckhaltenKopiertUndMerkt()
    {
        var src = Setup("1.3.0.0", "setup-a");
        var held = UpdateHold.Hold(Dir, src, "1.3.0.0", 1000);
        Assert.Equal("1.3.0.0", held.Version);
        Assert.Equal(1000, held.RemindAt);
        Assert.Equal(UpdateHold.Sha256(src), held.Sha256);
        Assert.Equal(64, held.Sha256.Length);
        Assert.True(File.Exists(Path.Combine(Dir, held.File)));
        Assert.Equal(held, UpdateHold.Load(Dir));
        // Die Quelle (WinSparkles Ordner) bleibt unberührt.
        Assert.True(File.Exists(src));
    }

    [Fact]
    public void ErinnerungUeberlebtNeustart()
    {
        var held = UpdateHold.Hold(Dir, Setup("1.3.0.0", "a"), "1.3.0.0", 1000);
        UpdateHold.Save(Dir, held with { RemindAt = 1000 + 86400 });
        var loaded = UpdateHold.Load(Dir)!;
        Assert.Equal(87400, loaded.RemindAt);
        Assert.False(UpdateHold.ReminderDue(2000, loaded.RemindAt));
    }

    [Fact]
    public void NeuesUpdateLegtAltesBeiseite()
    {
        UpdateHold.Hold(Dir, Setup("1.3.0.0", "alt"), "1.3.0.0", 1000);
        var neu = UpdateHold.Hold(Dir, Setup("1.3.0.1", "neu"), "1.3.0.1", 2000);
        Assert.Equal(neu, UpdateHold.Load(Dir));
        var files = Directory.GetFiles(Dir).Select(Path.GetFileName).ToList();
        Assert.Contains("Klimacontrol-Windows-1.3.0.0-Setup.exe.entfernt-2000", files);
        Assert.Contains("held.json.entfernt-2000", files);
        Assert.Contains("Klimacontrol-Windows-1.3.0.1-Setup.exe", files);
    }

    [Fact]
    public void GleichesUpdateNochmalZurueckhalten()
    {
        UpdateHold.Hold(Dir, Setup("1.3.0.0", "a"), "1.3.0.0", 1000);
        var again = UpdateHold.Hold(Dir, Setup("1.3.0.0", "a"), "1.3.0.0", 1000);
        Assert.Equal(again, UpdateHold.Load(Dir));
        Assert.Contains(Directory.GetFiles(Dir), f => f.EndsWith(".entfernt-1000-2", StringComparison.Ordinal)
                                                     || f.EndsWith(".entfernt-1000", StringComparison.Ordinal));
    }

    [Fact]
    public void PruefsummeStimmtVorDemStart()
    {
        var held = UpdateHold.Hold(Dir, Setup("1.3.0.0", "echt"), "1.3.0.0", 1000);
        using (var s = UpdateHold.OpenVerified(Dir, held))
        {
            Assert.NotNull(s);
            // Solange geprüft und gestartet wird, ist die Datei gegen Schreiben gesperrt.
            Assert.Throws<IOException>(() => File.WriteAllText(Path.Combine(Dir, held.File), "getauscht"));
        }
        File.WriteAllText(Path.Combine(Dir, held.File), "getauscht");
        Assert.Null(UpdateHold.OpenVerified(Dir, held));
    }

    [Fact]
    public void VerwerfenBenenntUm()
    {
        var held = UpdateHold.Hold(Dir, Setup("1.3.0.0", "a"), "1.3.0.0", 1000);
        UpdateHold.Discard(Dir, held, 5000);
        Assert.Null(UpdateHold.Load(Dir));
        var files = Directory.GetFiles(Dir).Select(Path.GetFileName).ToList();
        Assert.Equal(2, files.Count);
        Assert.All(files, f => Assert.EndsWith(".entfernt-5000", f));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("kaputt")]
    [InlineData("{\"version\":\"1.3.0.0\",\"sha256\":\"ab\",\"file\":\"Klimacontrol-Windows-1.3.0.0-Setup.exe\",\"remindAt\":1}")]
    [InlineData("{\"version\":\"1.3.0.0\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"file\":\"..\\\\x.exe\",\"remindAt\":1}")]
    public void UnbrauchbarerMerkerGiltAlsKeiner(string json)
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(Path.Combine(Dir, "Klimacontrol-Windows-1.3.0.0-Setup.exe"), "a");
        File.WriteAllText(Path.Combine(Dir, UpdateHold.StateFile), json);
        Assert.Null(UpdateHold.Load(Dir));
    }

    [Fact]
    public void OhneOrdnerKeinMerker() => Assert.Null(UpdateHold.Load(Dir));
}
