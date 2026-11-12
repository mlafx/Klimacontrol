namespace KlimacontrolTray;

/// Namen der Befehle an `kc_command` (Vertrag in AGENTS.md 8.3). Ein Test im Swift-Kern liest diese Datei und vergleicht
/// die Namen mit der Bridge – darum genau eine Zeile `public const string Name = "befehl";` je Befehl.
public static class Cmd
{
    // Bedienung
    public const string Refresh = "refresh";
    public const string Power = "power";
    public const string Mode = "mode";
    public const string Temp = "temp";
    public const string NudgeTemp = "nudgeTemp";
    public const string Fan = "fan";
    public const string FanQuiet = "fanQuiet";
    public const string FanTurbo = "fanTurbo";

    // Schalter
    public const string Swing = "swing";
    public const string Eco = "eco";
    public const string Turbo = "turbo";
    public const string Purifier = "purifier";
    public const string FreezeProtection = "freezeProtection";
    public const string OutdoorSilent = "outdoorSilent";
    public const string SelfClean = "selfClean";
    public const string Ieco = "ieco";
    public const string Sleep = "sleep";
    public const string Display = "display";
    public const string Rate = "rate";
    public const string Sound = "sound";

    // Szenen
    public const string ApplyScene = "applyScene";
    public const string DeleteScene = "deleteScene";
    public const string SaveScene = "saveScene";

    // Timer
    public const string OffTimer = "offTimer";
    public const string OnTimer = "onTimer";

    // Einstellungen
    public const string ConnectionMode = "connectionMode";
    public const string DisplayName = "displayName";
    public const string RefreshSeconds = "refreshSeconds";
    public const string Price = "price";
    public const string Language = "language";
    public const string Currency = "currency";
    public const string DebugLog = "debugLog";
    public const string HistoryCsv = "historyCSV";
    public const string UpdateAutoInstall = "updateAutoInstall";
    public const string UpdateInterval = "updateInterval";
    public const string DiagnosticsVisible = "diagnosticsVisible";
    public const string UiVisible = "uiVisible";

    // Darstellung
    public const string Appearance = "appearance";
    public const string AppearanceTheme = "appearanceTheme";
    public const string AppearanceReset = "appearanceReset";

    // Daten
    public const string ExportHistory = "exportHistory";
    public const string ExportHistoryStart = "exportHistoryStart";
    public const string ClearLog = "clearLog";
    public const string ImportBackup = "importBackup";
    public const string ExportBackup = "exportBackup";

    // Midea-Konto
    public const string CloudLogin = "cloudLogin";
    public const string CloudLogout = "cloudLogout";

    // Einrichtung
    public const string SetupPath = "setupPath";
    public const string Scan = "scan";
    public const string ScanSubnet = "scanSubnet";
    public const string ScanCloud = "scanCloud";
    public const string Select = "select";
    public const string SetupConnect = "setupConnect";
    public const string ManualSet = "manualSet";
    public const string ManualUse = "manualUse";
    public const string ManualPaste = "manualPaste";
    public const string ManualCheck = "manualCheck";
    public const string ManualConnect = "manualConnect";
    public const string ApplySuggestedMode = "applySuggestedMode";
    public const string DismissCompletion = "dismissCompletion";

    // Anlage
    public const string ForgetDevice = "forgetDevice";
    public const string Relocate = "relocate";

    // Meldungen
    public const string DismissMessage = "dismissMessage";
    public const string DismissNotice = "dismissNotice";
    public const string DismissWhatsNew = "dismissWhatsNew";
}
