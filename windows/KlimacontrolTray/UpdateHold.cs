using System;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KlimacontrolTray;

/// Ein geladenes Update, das erst nach „Jetzt installieren“ installiert wird. `RemindAt` in Unix-Sekunden.
sealed record HeldUpdate(string Version, string Sha256, string File, double RemindAt);

/// Ablage für Updates, die nicht automatisch installiert werden: WinSparkle löscht seinen Download-Ordner beim nächsten
/// Start, darum liegt eine Kopie samt Prüfsumme und Erinnerungszeit in einem eigenen Ordner. Nichts wird gelöscht:
/// Ersetztes und Verworfenes wird mit Zeitstempel umbenannt.
static class UpdateHold
{
    public const string StateFile = "held.json";

    static readonly Regex SetupName = new(@"^Klimacontrol-Windows-([0-9]+(?:\.[0-9]+){1,3})-Setup\.exe\z",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    /// Version aus dem Namen des Setups (`Klimacontrol-Windows-1.3.0.0-Setup.exe`), sonst null.
    public static string? VersionFromFileName(string path)
    {
        var m = SetupName.Match(Path.GetFileName(path));
        return m.Success ? m.Groups[1].Value : null;
    }

    public static string Sha256(Stream stream)
    {
        stream.Position = 0;
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    public static string Sha256(string path)
    {
        using var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Sha256(s);
    }

    /// Ist `held` neuer als `current`? Nicht lesbare Versionen gelten als nicht neuer.
    public static bool IsNewer(string held, string current) =>
        Version.TryParse(held, out var h) && Version.TryParse(current, out var c) && h > c;

    public static bool ReminderDue(double now, double remindAt) => now >= remindAt;

    /// Kopiert das Setup in `dir`, prüft die Kopie gegen das Original und merkt Version und Prüfsumme. Vorhandene
    /// Dateien in `dir` werden vorher umbenannt. Die Erinnerung ist sofort fällig (`now`).
    public static HeldUpdate Hold(string dir, string source, string version, double now)
    {
        Directory.CreateDirectory(dir);
        var stamp = (long)now;
        foreach (var file in Directory.GetFiles(dir))
            if (!IsSetAside(file)) SetAside(file, stamp);
        var name = Path.GetFileName(source);
        var target = Path.Combine(dir, name);
        var expected = Sha256(source);
        System.IO.File.Copy(source, target, overwrite: false);
        var copied = Sha256(target);
        if (copied != expected)
        {
            SetAside(target, stamp);
            throw new IOException("Kopie des Updates weicht vom Download ab");
        }
        var held = new HeldUpdate(version, copied, name, now);
        Save(dir, held);
        return held;
    }

    public static void Save(string dir, HeldUpdate held)
    {
        using var buffer = new MemoryStream();
        using (var w = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            w.WriteStartObject();
            w.WriteString("version", held.Version);
            w.WriteString("sha256", held.Sha256);
            w.WriteString("file", held.File);
            w.WriteNumber("remindAt", held.RemindAt);
            w.WriteEndObject();
        }
        var file = Path.Combine(dir, StateFile);
        var temp = file + ".neu";
        System.IO.File.WriteAllBytes(temp, buffer.ToArray());
        System.IO.File.Move(temp, file, overwrite: true);
    }

    /// Gemerktes Update oder null (fehlt, unlesbar, Datei fehlt oder liegt außerhalb von `dir`).
    public static HeldUpdate? Load(string dir)
    {
        try
        {
            var file = Path.Combine(dir, StateFile);
            if (!System.IO.File.Exists(file)) return null;
            using var doc = JsonDocument.Parse(System.IO.File.ReadAllText(file, Encoding.UTF8));
            var r = doc.RootElement;
            var held = new HeldUpdate(r.GetProperty("version").GetString() ?? "", r.GetProperty("sha256").GetString() ?? "",
                                      r.GetProperty("file").GetString() ?? "", r.GetProperty("remindAt").GetDouble());
            if (held.File.Length == 0 || Path.GetFileName(held.File) != held.File || held.Sha256.Length != 64) return null;
            return System.IO.File.Exists(Path.Combine(dir, held.File)) ? held : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException
                                      or System.Collections.Generic.KeyNotFoundException or InvalidOperationException
                                      or FormatException)
        {
            return null;
        }
    }

    /// Öffnet das gemerkte Setup gegen Schreiben gesperrt, wenn die Prüfsumme stimmt; sonst null. Der Aufrufer hält den
    /// Strom offen, bis das Setup gestartet ist, damit die Datei zwischen Prüfung und Start nicht getauscht wird.
    public static FileStream? OpenVerified(string dir, HeldUpdate held)
    {
        FileStream? s = null;
        try
        {
            s = new FileStream(Path.Combine(dir, held.File), FileMode.Open, FileAccess.Read, FileShare.Read);
            if (string.Equals(Sha256(s), held.Sha256, StringComparison.OrdinalIgnoreCase)) return s;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        s?.Dispose();
        return null;
    }

    /// Legt Setup und Merker beiseite (umbenennen, nicht löschen).
    public static void Discard(string dir, HeldUpdate? held, double now)
    {
        var stamp = (long)now;
        if (held != null)
        {
            var setup = Path.Combine(dir, held.File);
            if (System.IO.File.Exists(setup)) SetAside(setup, stamp);
        }
        var state = Path.Combine(dir, StateFile);
        if (System.IO.File.Exists(state)) SetAside(state, stamp);
    }

    const string AsideMarker = ".entfernt-";

    static bool IsSetAside(string path) => Path.GetFileName(path).Contains(AsideMarker, StringComparison.Ordinal);

    /// `name.ext` → `name.ext.entfernt-<Unix>` (bei Gleichstand mit Zähler); so startet das Setup nicht versehentlich.
    static void SetAside(string path, long stamp)
    {
        var target = path + AsideMarker + stamp.ToString(CultureInfo.InvariantCulture);
        for (var n = 2; System.IO.File.Exists(target); n++)
            target = path + AsideMarker + stamp.ToString(CultureInfo.InvariantCulture) + "-" + n.ToString(CultureInfo.InvariantCulture);
        System.IO.File.Move(path, target);
    }
}
