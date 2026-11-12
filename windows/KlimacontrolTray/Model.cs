using System;
using System.Collections.Generic;

namespace KlimacontrolTray;

// Spiegel der JSON-Strukturen aus Bridge.swift. VertragTests prüft sie gegen Vertrag/bridge-muster.json:
// Wer ein Feld ändert, ändert die Musterdatei mit.

public sealed class Snapshot
{
    /// Version der C-Schnittstelle (wie kc_api_version).
    public int ApiVersion { get; set; }
    public bool Configured { get; set; }
    string? displayName;
    /// Name der Anlage; fehlt er im JSON, gilt der Standardname aus dem Katalog (beim Lesen, nicht beim Anlegen:
    /// Der Katalog ist beim ersten Schnappschuss noch nicht geladen).
    public string DisplayName { get => displayName ?? L.T("message.defaultName"); set => displayName = value; }
    public string? DeviceName { get; set; }
    public string? Ip { get; set; }
    public int? Port { get; set; }
    /// Anlagen-ID als Text (64 bit).
    public string? DeviceId { get; set; }
    public string? DeviceIdentifier { get; set; }
    /// Nicht im Schnappschuss-JSON: setzt Core aus kc_live_json.
    public bool Busy { get; set; }
    public string? Message { get; set; }
    /// Letzte Abfrage/letzter Befehl scheiterte an der Verbindung – nur dann „Keine Verbindung“ (Punkt orange).
    public bool LastRefreshFailed { get; set; }
    /// `Message` ist der ruhige Hinweis „Anlage ausgeschaltet oder ohne Strom“ (grau statt orange).
    public bool DeviceOffNotice { get; set; }
    /// Hinweis zu einem Befehl (nicht übernommen, Timer, Sicherung): eigene graue Zeile, der Kern löscht ihn nach 10 s.
    public string? Notice { get; set; }
    /// Zieltext („Heizt · noch 1,2° bis zum Ziel“) und Statuszeile („Kühlt · Raum 24,5° · über WLAN“) aus dem Kern.
    public string GoalLine { get; set; } = "";
    public string StatusLine { get; set; } = "";
    /// „Außengerät leise“ und Turbo am Lüfterregler (nur Kühlen/Heizen).
    public bool FanZonesAvailable { get; set; }
    public string? Path { get; set; }
    public double? LastUpdate { get; set; }
    /// Nicht im Schnappschuss-JSON: setzt Core aus kc_live_json (ändert sich allein, ohne `Changed`).
    public double? NextRefresh { get; set; }
    public string ConnectionMode { get; set; } = "auto";
    public List<List<string>> ConnectionModes { get; set; } = new();
    public string? CloudAccount { get; set; }
    public bool CloudLoginRunning { get; set; }
    public int LoginSeq { get; set; }
    public string? LoginError { get; set; }
    public AcState? State { get; set; }
    public string? Diagnostics { get; set; }
    public DiagInfo? Diag { get; set; }
    public List<SceneInfo> Scenes { get; set; } = new();
    public double? OffAt { get; set; }
    public double? OnAt { get; set; }
    public double? CostPerHour { get; set; }
    public double? TodayKWh { get; set; }
    public int RefreshSeconds { get; set; }
    public double Price { get; set; }
    /// Gespeicherte Sprachwahl: "system", "de" oder "en" (wirkt nach Neustart).
    public string Language { get; set; } = "system";
    /// Währung des Strompreises (1–3 Zeichen).
    public string Currency { get; set; } = "€";
    public bool Beep { get; set; }
    /// Ausführliches Protokoll gilt nur für diese Sitzung; der Kern speichert es nie.
    public bool DebugLog { get; set; }
    /// Dezenter Hinweis, solange das ausführliche Protokoll an ist (null = keiner).
    public string? DebugLogNotice { get; set; }
    public bool HistoryCSV { get; set; }
    /// Zählt neue Verlaufspunkte (HistoryStore.revision) – Graphen laden daran neu.
    public int HistoryRevision { get; set; }
    /// Die Verlaufsdatenbank ließ sich nicht öffnen: statt „zu wenig Daten“ L.T("charts.unavailable") zeigen.
    public bool HistoryUnavailable { get; set; }
    public SetupInfo Setup { get; set; } = new();

    /// Verbindungsschritt beim Verbinden: "searching" | "handshake" | "reading" | null (verbunden bzw. keine Verbindung).
    public string? ConnectPhase { get; set; }
    /// Verbinden dauert länger als üblich (> 10 s) – „Dauert länger als üblich“ + „Erneut versuchen“.
    public bool ConnectSlow { get; set; }
    /// Werte sind nicht live (Unix-Sekunden des letzten guten Stands) – abgeblendet mit „Stand HH:MM“.
    public double? StaleSince { get; set; }
    /// Zuletzt bekannte Werte (aus dem Verlauf) für die Startanzeige; null = Skelett zeigen.
    public LastKnownInfo? LastKnown { get; set; }
    /// „Adresse neu suchen“ läuft; Ergebnis über RelocateSeq/RelocateOK, Text in `RelocateMessage`.
    public bool Relocating { get; set; }
    public int RelocateSeq { get; set; }
    public bool RelocateOK { get; set; }
    /// Ergebnis eines App-Timers (ausgeführt/verpasst/Fehler) – einmal anzeigen.
    public TimerResultInfo? TimerResult { get; set; }
    /// "notConfigured" | "connecting" | "live" | "deviceOff" | "noConnection".
    public string ConnectionState { get; set; } = "notConfigured";
    /// `Message` zerlegt: Was ist passiert. Was tun. (Code).
    public MessageInfo? MessageDetail { get; set; }
    /// Zugangsdaten wurden gesichert (bzw. stammen aus einer Sicherung).
    public bool CredentialsBackedUp { get; set; }
    /// „Sicherung einlesen“ läuft asynchron: Ergebnis über ImportSeq/ImportResult.
    public int ImportSeq { get; set; }
    public ImportResultInfo? ImportResult { get; set; }
    /// „Verlauf exportieren“ läuft im Hintergrund (exportHistoryStart): Ergebnis über ExportSeq/ExportError.
    public int ExportSeq { get; set; }
    public string? ExportError { get; set; }
    /// Rückmeldung des letzten „Adresse neu suchen“ (Text aus dem Kern, am Ort der Aktion zeigen).
    public string? RelocateMessage { get; set; }
    /// Anlage arbeitet sichtbar (ein, aktuelle Werte, nicht 0 W) – nur dann laufen die Effekte.
    public bool Working { get; set; }
    /// Große Zahl und Zeile darunter im Mini-Fenster (gleich wie am Mac, inkl. „Stand HH:MM“ bei alten Werten).
    public string MiniValue { get; set; } = "–";
    public string MiniCaption { get; set; } = "";
    /// Verbrauch heute mit Herkunft („seit 08:15“), null = unbekannt.
    public TodayEnergyInfo? TodayEnergy { get; set; }
    /// Fertige Texte der Timer („Ein heute 22:00“, „Aus in 1 h 30 min“) und Voraussetzung („Die App muss laufen …“).
    public string? OnTimerLabel { get; set; }
    public string? OffTimerLabel { get; set; }
    public string TimerRequirement { get; set; } = "";
    /// Darstellung; null bei älterem Kern. Oberflächen lesen sie über `Appearance.Current`, nicht direkt.
    public AppearanceInfo? Appearance { get; set; }
    /// Appcast für WinSparkle und Suchintervall in Sekunden; beides gibt der Kern vor (leer/0 bei älterem Kern).
    public string UpdateFeedURL { get; set; } = "";
    public int UpdateCheckInterval { get; set; }
    /// Updates automatisch installieren (Standard an); aus = erst nach „Jetzt installieren“.
    public bool UpdateAutoInstall { get; set; } = true;
    /// Suchintervall: "daily" | "weekly".
    public string UpdateInterval { get; set; } = "daily";

    // Anzeigetexte, Listen und Grenzen aus dem Kern (BridgeDisplay.swift): die Oberfläche zeigt sie nur an.
    /// Statische Auswahllisten, Grenzen, Standardwerte und feste Rückfragen.
    public OptionsInfo Options { get; set; } = new();
    /// Gültigkeit der Schalter im aktuellen Modus je Schalter (swing, eco, turbo, outdoorSilent, ieco, purifier,
    /// freezeProtection, selfClean, sleep, display); fehlt ein Schlüssel, gilt der Schalter.
    public Dictionary<string, AvailabilityInfo> Availability { get; set; } = new();
    /// Kurzinfo der Verbindungszeile (die Zeile selbst steht zeitabhängig in kc_live_json).
    public string ConnectionTooltip { get; set; } = "";
    /// Verbindungszustand für die Anzeige ("Anlage aus"/"Keine Verbindung" bleiben während eines neuen Versuchs stehen)
    /// und Zeitpunkt (Unix-Sekunden), seit dem die Werte nicht live sind.
    public string UiConnectionState { get; set; } = "notConfigured";
    public double? UiStaleSince { get; set; }
    /// „Stand 14:32 · nicht aktuell“, solange die Werte nicht live sind.
    public string? StaleText { get; set; }
    /// Große Zahl, Zeile darunter und Hinweis bei ausgeschalteter Anlage.
    public string HeroValue { get; set; } = "–";
    public string HeroCaption { get; set; } = "";
    public string? HeroHint { get; set; }
    public CostLineInfo CostLine { get; set; } = new();
    public string PowerCostHelp { get; set; } = "";
    /// Text neben dem Symbol im Infobereich (null = nur Symbol).
    public string? MenuTitle { get; set; }
    /// Zeile „Status“ im Reiter Verbindung.
    public ConnectionStatusInfo ConnectionStatus { get; set; } = new();
    public string ConnectStepsLine { get; set; } = "";
    /// Zuletzt bekannte Werte der Startanzeige; null = Skelett zeigen.
    public StartupValuesInfo? StartupValues { get; set; }
    /// `Notice` in Teilen (Text, Rat, Code).
    public MessageInfo? NoticeDetail { get; set; }
    /// Die Darstellung entspricht dem Standard dieser Plattform („Auf Standard zurücksetzen“ ausgegraut).
    public bool AppearanceIsStandard { get; set; } = true;
    /// Ein Aussehens-Wert weicht vom gewählten Thema ab (Größe, Umfang, Fenster-Optionen zählen nicht).
    public bool AppearanceCustomized { get; set; }
    public string? OnTimerChip { get; set; }
    /// Rückfrage beim Beenden, solange ein App-Timer gestellt ist (null = ohne Rückfrage beenden).
    public PromptInfo? QuitPrompt { get; set; }
    /// „Neu einrichten“ fragt mit `Options.Prompts.ForgetNeedsBackup` (WLAN-Zugangsdaten noch nicht gesichert).
    public bool ForgetNeedsBackup { get; set; }
    public string FanCaption { get; set; } = "";
    /// Raum-Marke an der Skala unter dem Regler (Lage schon an den Rand geklemmt); fehlt ohne Raumtemperatur.
    public ScaleMark? ScaleRoom { get; set; }
    public List<string> MaintenanceHints { get; set; } = new();
    public string ErrorCodeValue { get; set; } = "";
    public string FilterValue { get; set; } = "";
    public string AccountFooter { get; set; } = "";
    /// Erfolgstext des letzten Verlauf-Exports (null bei Fehler).
    public string? ExportText { get; set; }
    /// „Neu in dieser Version“ nach einem Update (null = nichts zu zeigen); Bestätigen mit `Cmd.DismissWhatsNew`.
    public WhatsNewInfo? WhatsNew { get; set; }

    /// Nicht im Schnappschuss-JSON: setzt Core aus kc_live_json (zeitabhängige Texte, ändern sich allein).
    public string ConnectionLine { get; set; } = "";
    public string? OffTimerChip { get; set; }
    public string NextRefreshLine { get; set; } = "";

    /// Gültigkeit eines Schalters im aktuellen Modus; ohne Eintrag gilt er.
    public bool IsEnabled(string feature) => !Availability.TryGetValue(feature, out var a) || a.Enabled;
    /// Kurzinfo bzw. Grund zu einem Schalter (null = die Beschriftung genügt).
    public string? Why(string feature) => Availability.TryGetValue(feature, out var a) ? a.Why : null;
}

/// AvailabilityDTO.
public sealed class AvailabilityInfo
{
    public bool Enabled { get; set; }
    public string? Why { get; set; }
}

public sealed class CostLineInfo
{
    public string Title { get; set; } = "";
    public string Value { get; set; } = "";
    public string Help { get; set; } = "";
}

public sealed class ConnectionStatusInfo
{
    public string Text { get; set; } = "";
    public bool Connected { get; set; }
}

/// StartupValuesDTO: zuletzt bekannte Werte vor der ersten Abfrage.
public sealed class StartupValuesInfo
{
    public string Main { get; set; } = "";
    public string Caption { get; set; } = "";
    public List<string> Extras { get; set; } = new();
    public string Accessibility { get; set; } = "";
}

/// WhatsNewDTO: Titel, OK-Knopf und die Abschnitte je Version (neueste zuerst).
public sealed class WhatsNewInfo
{
    public string Title { get; set; } = "";
    public string Ok { get; set; } = "";
    public List<WhatsNewVersion> Versions { get; set; } = new();
}

public sealed class WhatsNewVersion
{
    public string Version { get; set; } = "";
    public string Heading { get; set; } = "";
    public List<WhatsNewSection> Sections { get; set; } = new();
}

/// `Title` ist bei Absätzen ohne Überschrift leer.
public sealed class WhatsNewSection
{
    public string Title { get; set; } = "";
    public List<string> Items { get; set; } = new();
}

/// PromptDTO: fertige Rückfrage des Kerns (Titel, Text, Knöpfe). `Warning` = mit Warnsymbol.
public sealed class PromptInfo
{
    public string Title { get; set; } = "";
    public string Message { get; set; } = "";
    public string Cancel { get; set; } = "";
    public string Confirm { get; set; } = "";
    public bool Warning { get; set; }
}

/// ForgetPromptDTO: „Anlage neu einrichten?“ mit drei Knöpfen; `Backup` („Erst sichern …“) ist Standard bei Enter.
public sealed class ForgetPromptInfo
{
    public string Title { get; set; } = "";
    public string Message { get; set; } = "";
    public string Backup { get; set; } = "";
    public string Confirm { get; set; } = "";
    public string Cancel { get; set; } = "";
    public bool Warning { get; set; }
}

/// NoticeDTO: Hinweis mit Titel und Text.
public sealed class HintInfo
{
    public string Title { get; set; } = "";
    public string Message { get; set; } = "";
}

/// SetupDonePromptDTO: Fenster nach gelungener Einrichtung.
public sealed class SetupDonePromptInfo
{
    public string Title { get; set; } = "";
    public List<string> Paragraphs { get; set; } = new();
    /// Beschriftung des Häkchens „Nur WLAN“ (null = nicht anbieten).
    public string? LanOnlyChoice { get; set; }
    public string Primary { get; set; } = "";
    public string? Secondary { get; set; }
}

/// OptionsDTO: Auswahllisten, Grenzen, Standardwerte und feste Texte (ändert sich zur Laufzeit nicht).
public sealed class OptionsInfo
{
    public RangeInfo Temperature { get; set; } = new();
    public RefreshOptions Refresh { get; set; } = new();
    public RateOptions Rate { get; set; } = new();
    public PriceOptions Price { get; set; } = new();
    public List<OffTimerChoice> OffTimerChoices { get; set; } = new();
    public FanOptions Fan { get; set; } = new();
    public CredentialOptions Credentials { get; set; } = new();
    /// Skala unter dem Regler der Solltemperatur.
    public TemperatureScaleOptions TemperatureScale { get; set; } = new();
    public ChartOptions Chart { get; set; } = new();
    public WindowOptions Window { get; set; } = new();
    public EnergyOptions Energy { get; set; } = new();
    public List<ModeOption> ConnectionModes { get; set; } = new();
    public List<StepInfo> ConnectSteps { get; set; } = new();
    public CloudFolderOptions CloudFolder { get; set; } = new();
    public PromptOptions Prompts { get; set; } = new();
    public TextOptions Texts { get; set; } = new();
    public UpdateOptions Updates { get; set; } = new();
}

/// UpdatesDTO: Texte und Erinnerungsabstand für „Updates automatisch installieren“ und das Suchintervall.
public sealed class UpdateOptions
{
    public string AutoInstallTitle { get; set; } = "";
    public string AutoInstallHelp { get; set; } = "";
    public string IntervalTitle { get; set; } = "";
    public List<UpdateIntervalOption> Intervals { get; set; } = new();
    public string HeldBackTitle { get; set; } = "";
    /// Mit Platzhalter {version}.
    public string HeldBackMessageTemplate { get; set; } = "";
    public string HeldBackStatusTemplate { get; set; } = "";
    public string InstallNow { get; set; } = "";
    public string Later { get; set; } = "";
    /// Abstand der Erinnerung nach „Später“ in Sekunden.
    public double ReminderSeconds { get; set; }
}

public sealed class UpdateIntervalOption
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Help { get; set; } = "";
}

public sealed class RangeInfo
{
    public double Min { get; set; }
    public double Max { get; set; }
}

public sealed class ChoiceInfo
{
    public string Label { get; set; } = "";
    public double Seconds { get; set; }
}

/// Skala unter dem Regler der Solltemperatur (OptionsDTO.TemperatureScale).
public sealed class TemperatureScaleOptions
{
    public double Min { get; set; }
    public double Max { get; set; }
    public List<ScaleMark> Labels { get; set; } = new();
    /// Hervorgehobene Striche ohne Beschriftung.
    public List<ScaleTick> Emphasized { get; set; } = new();
}

/// Strich auf der Spur: `Fraction` 0…1 zwischen den Knopfmitten (Einzug = halbe Knopfbreite).
public class ScaleTick
{
    public double Value { get; set; }
    public double Fraction { get; set; }
}

/// Beschriftete Marke („16°“, „Raum 23,0°“).
public sealed class ScaleMark : ScaleTick
{
    public string? Text { get; set; }
}

public sealed class RefreshOptions
{
    public List<ChoiceInfo> Choices { get; set; } = new();
    public int Min { get; set; }
    public int Max { get; set; }
    public int WarnBelow { get; set; }
    public string CustomLabel { get; set; } = "";
    public string CustomHelp { get; set; } = "";
    public string Warning { get; set; } = "";
}

public sealed class RateOptions
{
    public List<int> Choices { get; set; } = new();
    public int Fallback { get; set; }
    public string Help { get; set; } = "";
}

public sealed class PriceOptions
{
    public double Min { get; set; }
    public double Max { get; set; }
    public int FractionDigitsMin { get; set; }
    public int FractionDigitsMax { get; set; }
}

public sealed class OffTimerChoice
{
    public int Minutes { get; set; }
    public string Label { get; set; } = "";
}

public sealed class FanMark
{
    public string Label { get; set; } = "";
    public int Value { get; set; }
}

public sealed class FanOptions
{
    public List<FanMark> Marks { get; set; } = new();
    public int AutoKnob { get; set; }
    public string LockedText { get; set; } = "";
    public string AutoHelp { get; set; } = "";
}

public sealed class CredentialOptions
{
    public int TokenLength { get; set; }
    public int KeyLength { get; set; }
    public int DefaultPort { get; set; }
    public string AddressPlaceholder { get; set; } = "";
    public string AddressExample { get; set; } = "";
    public string AddressOrHostPrompt { get; set; } = "";
    public string TokenPrompt { get; set; } = "";
    public string KeyPrompt { get; set; } = "";
}

public sealed class EnergyOptions
{
    public List<EnergyKindOption> Kinds { get; set; } = new();
    public string DefaultKind { get; set; } = "";
    public string Title { get; set; } = "";
    public string Help { get; set; } = "";
    public string Legend { get; set; } = "";
    public string NoData { get; set; } = "";
}

public sealed class EnergyKindOption
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public int Count { get; set; }
}

/// Antwort von kc_energy_json: Verbrauch je Zeitraum samt fertigen Texten (EnergyDTO); bei Fehler nur `Error`.
public sealed class EnergyResult
{
    public string Kind { get; set; } = "";
    public List<EnergyPeriod> Periods { get; set; } = new();
    public string Summary { get; set; } = "";
    /// Durchschnitt der abgeschlossenen Zeiträume (gestrichelte Linie) und Text für die Legende; fehlt ohne solche.
    public double? Average { get; set; }
    public string? AverageText { get; set; }
    public string? Error { get; set; }
}

public sealed class EnergyPeriod
{
    /// Unix-Sekunden; `End` des laufenden Zeitraums liegt in der Zukunft.
    public double Start { get; set; }
    public double End { get; set; }
    /// Fehlt = unbekannt. `KWh` ist der Zählerverbrauch, `MeasuredKWh` die Schätzung aus der Leistung.
    public double? KWh { get; set; }
    public double? MeasuredKWh { get; set; }
    public bool Complete { get; set; }
    public bool Current { get; set; }
    public string Label { get; set; } = "";
    public string Name { get; set; } = "";
    public string Tooltip { get; set; } = "";
    public string CostText { get; set; } = "";
    /// Wert über dem Balken („4,2“); fehlt ohne Wert oder bei zu vielen Balken.
    public string? ValueText { get; set; }
    public double? Shown => KWh ?? MeasuredKWh;
}

public sealed class ChartOptions
{
    public List<ChartRangeInfo> Ranges { get; set; } = new();
    public double DefaultRange { get; set; }
    public int WindowCount { get; set; }
    /// Lücke = max(GapMinSeconds, GapFactor × Punktabstand), Punktabstand = Zeitraum / WindowCount.
    public double GapFactor { get; set; }
    public double GapMinSeconds { get; set; }
    public RangeInfo TemperatureAxis { get; set; } = new();
    public RangeInfo OutdoorAxis { get; set; } = new();
}

/// Zeitraum des Verlaufs mit der Teilung seiner Zeitachse (ab 1440 min Datum statt Uhrzeit).
public sealed class ChartRangeInfo
{
    public string Label { get; set; } = "";
    public double Seconds { get; set; }
    public int TickMinutes { get; set; }
    /// Halbe Breite einer Achsenbeschriftung (Randprüfung der Marken).
    public double TickLabelHalfWidth { get; set; }
}

/// Regeln des Hauptfensters (MainWindowLayout im Kern); Breiten der Seitenspalten schließen ihre Trennlinie ein.
public sealed class WindowOptions
{
    public double ControlWidth { get; set; }
    public double HistoryMin { get; set; }
    /// Bis hierher bekommt der Verlauf zuerst allen zusätzlichen Platz, danach die Diagnose.
    public double HistoryBalanced { get; set; }
    /// Ab dieser Verlaufsbreite stehen die Graphen als 2 × 2 nebeneinander.
    public double HistoryGridFrom { get; set; }
    public double DiagnosticsMin { get; set; }
    public double DiagnosticsMax { get; set; }
    /// Ohne Verlauf und Diagnose ist das Fenster höchstens so breit.
    public double ControlsOnlyMaxWidth { get; set; }
    /// Mindesthöhe je Darstellungsgröße.
    public SizeHeights MinimumHeight { get; set; } = new();
    public double HistoryBaseHeight { get; set; }
    public double SingleOverhead { get; set; }
    public double GridOverhead { get; set; }
    public double GridRowMax { get; set; }
    public double ChartStep { get; set; }
    public double EnergyBarMaxWidth { get; set; }
    /// Graphenhöhen einspaltig ohne zusätzlichen Platz bzw. ganz ausgereizt, und kleinste Höhen im 2 × 2-Raster.
    public ChartHeightsInfo ChartMin { get; set; } = new();
    public ChartHeightsInfo ChartMax { get; set; } = new();
    public ChartHeightsInfo GridChartMin { get; set; } = new();
    /// Anteile an zusätzlicher Höhe; der Verbrauch bekommt nur den Rest.
    public ChartWeightsInfo ChartWeights { get; set; } = new();
}

public sealed class ChartWeightsInfo
{
    public double Power { get; set; }
    public double Temperature { get; set; }
    public double Outdoor { get; set; }
}

public sealed class SizeHeights
{
    public double Compact { get; set; }
    public double Normal { get; set; }
    public double Large { get; set; }
}

public sealed class ChartHeightsInfo
{
    public double Power { get; set; }
    public double Temperature { get; set; }
    public double Outdoor { get; set; }
    public double Energy { get; set; }
}

public sealed class ModeOption
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Help { get; set; } = "";
}

public sealed class StepInfo
{
    public string Phase { get; set; } = "";
    public string Name { get; set; } = "";
}

public sealed class CloudFolderOptions
{
    /// Pfadteile (nach Umwandlung von `\` in `/`), die einen Cloud-Ordner verraten.
    public List<string> Markers { get; set; } = new();
    public string Title { get; set; } = "";
    /// Text mit dem Platzhalter {folder}.
    public string MessageTemplate { get; set; } = "";
    public string Cancel { get; set; } = "";
    public string Confirm { get; set; } = "";
}

public sealed class PromptOptions
{
    public PromptInfo ReplaceScenes { get; set; } = new();
    public PromptInfo SelfClean { get; set; } = new();
    public PromptInfo AccountRemove { get; set; } = new();
    public ForgetPromptInfo Forget { get; set; } = new();
    public ForgetPromptInfo ForgetNeedsBackup { get; set; } = new();
    public HintInfo CloudNeedsAccount { get; set; } = new();
}

public sealed class TextOptions
{
    public string OffCaption { get; set; } = "";
    public string OffHint { get; set; } = "";
    public string FanModeCaption { get; set; } = "";
    public string ConnectSlow { get; set; } = "";
    public string Retry { get; set; } = "";
    public string AccountSignedIn { get; set; } = "";
    public string AccountRemoved { get; set; } = "";
    public string SetupLANOnlyChoice { get; set; } = "";
    public string ImportPanelTitle { get; set; } = "";
    public string ImportPanelMessage { get; set; } = "";
    public string ExportBackupPanelTitle { get; set; } = "";
    public string ExportBackupPanelMessage { get; set; } = "";
    public string ExportBackupFileName { get; set; } = "";
    public string ExportHistoryPanelTitle { get; set; } = "";
    public string ExportHistoryFileName { get; set; } = "";
    public string UpdatesHelp { get; set; } = "";
    public string UpdatesChecking { get; set; } = "";
    public string UpdatesCurrent { get; set; } = "";
    /// Enthält den Platzhalter {version}.
    public string UpdatesInstallingTemplate { get; set; } = "";
    public string UpdatesFailed { get; set; } = "";
    public string UpdatesCheckButton { get; set; } = "";
}

/// AppearanceDTO aus dem Kern (Namen und Wertebereiche wie dort; Umrechnung für die Oberfläche in Appearance.cs).
public sealed class AppearanceInfo
{
    public string Theme { get; set; } = "standard";
    public string Scheme { get; set; } = "system";
    public string Accent { get; set; } = "byMode";
    public string CustomColor { get; set; } = "orange";
    public string Background { get; set; } = "glass";
    public double Transparency { get; set; } = 0.4;
    public double Blur { get; set; } = 20;
    public double Glow { get; set; }
    public string Size { get; set; } = "normal";
    public string Digits { get; set; } = "normal";
    public string Hero { get; set; } = "target";
    public string Scope { get; set; } = "all";
    public bool Lively { get; set; }
    public bool Weather { get; set; }
    public bool ReduceMotion { get; set; }
    public bool AlwaysOnTop { get; set; }
    public string MenuBarText { get; set; } = "iconTarget";
    public bool MenuBarColored { get; set; }
    public bool MenuBarAnimated { get; set; }
    /// Außentemperatur im Temperaturgraphen statt eigenem Graphen (Standard aus).
    public bool TemperatureCombined { get; set; }
}

/// LastKnownDTO: letzter Verlaufspunkt (Unix-Sekunden).
public sealed class LastKnownInfo
{
    public double T { get; set; }
    public double? Power { get; set; }
    public double? Indoor { get; set; }
    public double? Outdoor { get; set; }
    public double? Target { get; set; }
    public bool On { get; set; }
}

/// TimerResultDTO: kind "executed" | "missed" | "failed".
public sealed class TimerResultInfo
{
    public string Kind { get; set; } = "";
    public string Title { get; set; } = "";
    public string Message { get; set; } = "";
    public bool Succeeded { get; set; }
    public bool PowerOn { get; set; }
    public double Due { get; set; }
}

/// MessageDTO: „Was ist passiert.“ / „Was tun.“ / Code (klein am Ende).
public sealed class MessageInfo
{
    public string What { get; set; } = "";
    public string Todo { get; set; } = "";
    public string? Code { get; set; }
}

/// ImportResultDTO; errorCode "otherDevice" (→ nachfragen, mit allowOtherDevice erneut) | "rejected" | "file" | "other".
public sealed class ImportResultInfo
{
    public bool Ok { get; set; }
    public bool? Verified { get; set; }
    public int ScenesImported { get; set; }
    public int ScenesSkipped { get; set; }
    public string? Error { get; set; }
    public string? ErrorCode { get; set; }
    /// Fertiger Text für die Rückmeldung (Erfolg, „Anlage antwortet nicht“ oder Fehler) wie am Mac.
    public string? Text { get; set; }
    /// Rückfrage „Andere Anlage einrichten?“ bei ErrorCode "otherDevice".
    public PromptInfo? Prompt { get; set; }
}

public sealed class TodayEnergyInfo
{
    public double KWh { get; set; }
    public double? Since { get; set; }
    public bool FromMidnight { get; set; }
    public bool? Plausible { get; set; }
    public string? SinceLabel { get; set; }
}

/// CompletionDTO: Abschluss der Einrichtung (Vorschläge „Nur WLAN“, „Zugangsdaten sichern“).
public sealed class CompletionInfo
{
    public string Path { get; set; } = "";
    public bool SuggestLANOnly { get; set; }
    public bool OfferBackup { get; set; }
    public string Note { get; set; } = "";
    /// Fertiger Inhalt des Abschlussfensters; null, wenn nichts anzubieten ist.
    public SetupDonePromptInfo? Prompt { get; set; }
}

/// Kleiner Zusatz-Zustand aus kc_live_json (LiveDTO in Bridge.swift).
public sealed class LiveInfo
{
    public bool Busy { get; set; }
    public double? NextRefresh { get; set; }
    /// Zeitabhängige Texte des Kerns („vor 2 min aktualisiert“, Restzeit des Timers, Countdown).
    public string ConnectionLine { get; set; } = "";
    public string? OffTimerChip { get; set; }
    public string NextRefreshLine { get; set; } = "";
}

public sealed class AcState
{
    public bool Power { get; set; }
    public bool Swing { get; set; }
    public bool Eco { get; set; }
    public bool Turbo { get; set; }
    public bool Purifier { get; set; }
    public bool Sleep { get; set; }
    public bool DisplayOn { get; set; }
    public bool FilterAlert { get; set; }
    public int Mode { get; set; }
    public string ModeLabel { get; set; } = "";
    public int Fan { get; set; }
    public string FanLabel { get; set; } = "";
    public double Target { get; set; }
    public double? Indoor { get; set; }
    public double? Outdoor { get; set; }
    public double? PowerWatts { get; set; }
    public double? TotalKWh { get; set; }
    public int? RatePercent { get; set; }
    public bool? OutSilent { get; set; }
    public bool? SelfClean { get; set; }
    public bool? Ieco { get; set; }
    public bool? Sound { get; set; }
    public bool FreezeProtection { get; set; }
    public int ErrorCode { get; set; }
}

public sealed class DiagInfo
{
    public int? CompressorPowerW { get; set; }
    public int? CompressorHz { get; set; }
    public int? CompressorTargetHz { get; set; }
    public int? CurrentA { get; set; }
    public int? VoltageV { get; set; }
    public int? OutdoorFanRpm { get; set; }
    public int? TpDischarge { get; set; }
    public int? EevOpening { get; set; }
    public int? IndoorFanRpm { get; set; }
    public int? IndoorFanTargetRpm { get; set; }
    public double? T1IndoorAir { get; set; }
    public double? IndoorTemp2 { get; set; }
    public double? T2IndoorCoil { get; set; }
    public double? T3OutdoorCoil { get; set; }
    public double? T4OutdoorAir { get; set; }
    public bool? Defrost { get; set; }
    public bool? CondensatePump { get; set; }
}

public sealed class SceneInfo
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Summary { get; set; } = "";
    public bool Active { get; set; }
    /// Modus der Szene (2 Kühlen, 4 Heizen …) – Symbol und Farbe der Kachel.
    public int Mode { get; set; }
}

public sealed class SetupInfo
{
    public bool Scanning { get; set; }
    public bool CloudScanning { get; set; }
    public bool Busy { get; set; }
    /// „Netz durchsuchen“ läuft; Fortschritt gesendet/gesamt (null außerhalb eines Laufs).
    public bool SubnetScanning { get; set; }
    public int? SubnetSent { get; set; }
    public int? SubnetTotal { get; set; }
    public string? Error { get; set; }
    public List<FoundDevice> Discovered { get; set; } = new();
    public string? Selected { get; set; }
    public int Seq { get; set; }
    public bool Ok { get; set; }
    /// Gewählter Weg: "account", "manual", "backup" oder null (Startseite „Wie möchtest du verbinden?“).
    public string? Path { get; set; }
    /// Weg „Zugangsdaten“: Eingaben und ihre Prüfung (ManualDTO in Bridge.swift).
    public ManualInfo Manual { get; set; } = new();
    /// Ergebnis von „Prüfen“: null = nicht geprüft bzw. seitdem geändert.
    public bool? ManualCheckOK { get; set; }
    /// Art des letzten Problems: nothingFound | notAirConditioner | invalidInput | rejected | busy | unreachable |
    /// accountLogin | cloud | network | other | null.
    public string? Issue { get; set; }
    /// Hilfe zu Firewall/privatem Netz/Gast-WLAN zeigen (nichts gefunden).
    public bool ShowsNetworkHelp { get; set; }
    /// Einrichtung abgeschlossen – Vorschläge anzeigen, danach `dismissCompletion`.
    public CompletionInfo? Completion { get; set; }
}

/// Eingaben des Wegs „Zugangsdaten“ wie ManualCredentials im Kern. Token/Schlüssel nie protokollieren.
public sealed class ManualInfo
{
    public string Ip { get; set; } = "";
    public string Port { get; set; } = "6444";
    public string DeviceId { get; set; } = "";
    public string Token { get; set; } = "";
    public string Key { get; set; } = "";
    public string Name { get; set; } = "";
    /// Hex-Zeichen ohne Leerzeichen/Zeilenumbrüche.
    public int TokenCount { get; set; }
    public int KeyCount { get; set; }
    /// Was fehlt bzw. falsch ist, je Feld ("ip", "port", "deviceId", "token", "key") ein kurzer Satz.
    public Dictionary<string, string> Problems { get; set; } = new();
    /// Alles gültig – „Prüfen“ und „Verbinden“ sind möglich.
    public bool Complete { get; set; }
}

public sealed class FoundDevice
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Ip { get; set; } = "";
    public string Sn { get; set; } = "";
    /// Nur aus der Cloud bekannt (antwortet nicht im WLAN); CloudOnline = laut Cloud verbunden.
    public bool CloudOnly { get; set; }
    public bool? CloudOnline { get; set; }
    /// Protokollversion (2/3) bei WLAN-Funden, 0 bei Cloud-Funden.
    public int Version { get; set; }

    /// Zweite Zeile: „über Midea-Konto · online“ bzw. „192.168.1.40 · Protokoll V3 · SN …12345678“ (Texte aus dem
    /// Katalog; bei WLAN-Funden immer die volle Zeile wie am Mac, auch ohne Seriennummer).
    public string Detail => CloudOnly
        ? L.T(CloudOnline == false ? "setup.view.found.cloudOff" : "setup.view.found.cloudOnline")
        : L.F("setup.view.found.lan", ("ip", Ip), ("version", Version.ToString(System.Globalization.CultureInfo.InvariantCulture)),
              ("serial", Sn.Length > 8 ? Sn[^8..] : Sn));

    public override string ToString() => $"{Name}  ({Detail})";
}

/// Eintrag aus kc_third_party_json (ThirdPartyNotice im Kern).
public sealed class NoticeInfo
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
    public string License { get; set; } = "";
    public List<string> Copyright { get; set; } = new();
    public string Usage { get; set; } = "";
    public string Platforms { get; set; } = "";
    public string LicenseText { get; set; } = "";
}

public sealed class Sample
{
    public double T { get; set; }
    public double? Power { get; set; }
    public double? Indoor { get; set; }
    public double? Outdoor { get; set; }
    public double? Target { get; set; }
    public bool On { get; set; }
    /// Betriebsart (1 Auto, 2 Kühlen, 3 Trocknen, 4 Heizen, 5 Lüften), nur solange die Anlage lief; fehlt bei älterem Kern.
    public int? Mode { get; set; }
    /// Geglättete Außentemperatur für die Linie (der Hover zeigt `Outdoor`); fehlt ohne Außenwert.
    public double? OutdoorSmooth { get; set; }
}

/// Kennzahlen eines Zeitraums (StatsDTO in Bridge.swift).
public sealed class HistoryStats
{
    public double? AvgWatts { get; set; }
    public double? PeakWatts { get; set; }
    public double? KWh { get; set; }
    /// Kennzahlenzeile unter dem Leistungsgraphen (Mittel · Spitze · kWh · Kosten), fertig aus dem Kern.
    public List<ChartStat> Line { get; set; } = new();
}

public sealed class ChartStat
{
    public string Text { get; set; } = "";
    public string Help { get; set; } = "";
}

/// Betriebsarten und Lüfterstufen wie in MideaKit (Commands.swift), Reihenfolge und Farben wie die Mac-App.
static class Codes
{
    public const int FanAuto = 102;

    /// Kein `static readonly`: Die Beschriftungen kommen beim Aufruf aus dem Katalog.
    public static (int Value, string Label, string Icon)[] Modes => new[]
    {
        (2, L.T("mode.cool"), Icons.Snowflake), (4, L.T("mode.heat"), Icons.Flame), (3, L.T("mode.dry"), Icons.Drop),
        (5, L.T("mode.fan"), Icons.Fan), (1, L.T("mode.auto"), Icons.Auto),
    };

    /// Farbe je Modus (wie OperationalMode.tint in der Mac-App).
    public static System.Windows.Media.Color Tint(int mode) => mode switch
    {
        2 => System.Windows.Media.Color.FromRgb(0x33, 0x8C, 0xF2),
        4 => System.Windows.Media.Color.FromRgb(0xF5, 0x73, 0x2E),
        3 => System.Windows.Media.Color.FromRgb(0x26, 0xAD, 0x9E),
        5 => System.Windows.Media.Color.FromRgb(0x73, 0x85, 0x99),
        _ => System.Windows.Media.Color.FromRgb(0x8C, 0x6B, 0xE6),
    };

    public static string Verb(int mode) => L.T(mode switch
    {
        2 => "mode.verb.cool", 4 => "mode.verb.heat", 3 => "mode.verb.dry", 5 => "mode.verb.fan", _ => "mode.verb.auto",
    });

    public static DateTime Local(double epoch) => DateTimeOffset.FromUnixTimeMilliseconds((long)(epoch * 1000)).LocalDateTime;
    public static double Epoch(DateTime local) => new DateTimeOffset(local).ToUnixTimeMilliseconds() / 1000.0;
}
