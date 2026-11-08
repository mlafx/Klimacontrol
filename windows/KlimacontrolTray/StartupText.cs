using System.Globalization;

namespace KlimacontrolTray;

/// Texte, die erscheinen können, bevor der Katalog geladen ist (fehlende oder unpassende DLL, Startfehler). Je Text ein
/// Paar Deutsch/Englisch; gewählt wird nach der Anzeigesprache von Windows.
static class StartupText
{
    internal readonly record struct Pair(string De, string En);

    internal static readonly Pair VersionMismatchText = new(
        "Klimacontrol.exe und der Kern im Ordner „res“ passen nicht zusammen – sie stammen aus verschiedenen Ständen. "
        + "Bitte den ganzen Ordner aus dem ZIP übernehmen. (Schnittstelle {found}, erwartet {expected})",
        "Klimacontrol.exe and the core in the “res” folder do not match. They come from different versions. "
        + "Please copy the entire folder from the ZIP. (Interface {found}, expected {expected})");

    internal static readonly Pair InterfaceMissing = new("fehlt", "missing");

    internal static readonly Pair FilesMissingText = new(
        "Klimacontrol kann nicht starten: Im Ordner „res“ neben Klimacontrol.exe fehlen Dateien oder sie sind unvollständig. "
        + "Bitte den ganzen Ordner aus dem ZIP neu entpacken.",
        "Klimacontrol cannot start. Files are missing or incomplete in the “res” folder next to Klimacontrol.exe. "
        + "Please extract the entire folder from the ZIP again.");

    internal static readonly Pair StartFailedText = new(
        "Klimacontrol konnte nicht starten. Bitte noch einmal starten; hilft das nicht, den Ordner aus dem ZIP neu entpacken.",
        "Klimacontrol could not start. Please start it again. If that does not help, extract the folder from the ZIP again.");

    internal static readonly Pair RestartFailedText = new(
        "Klimacontrol konnte sich nicht neu starten. Bitte von Hand starten.",
        "Klimacontrol could not restart itself. Please start it manually.");

    static bool German(CultureInfo? culture = null) => (culture ?? CultureInfo.CurrentUICulture).TwoLetterISOLanguageName == "de";

    internal static string Pick(Pair pair, CultureInfo? culture = null) => German(culture) ? pair.De : pair.En;

    public static string VersionMismatch(int? found, int expected, CultureInfo? culture = null) =>
        Pick(VersionMismatchText, culture)
            .Replace("{found}", found is { } f ? f.ToString(CultureInfo.InvariantCulture) : Pick(InterfaceMissing, culture))
            .Replace("{expected}", expected.ToString(CultureInfo.InvariantCulture));

    public static string FilesMissing => Pick(FilesMissingText);
    public static string StartFailed => Pick(StartFailedText);
    public static string RestartFailed => Pick(RestartFailedText);
}
