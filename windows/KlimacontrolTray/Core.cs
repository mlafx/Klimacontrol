using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;

namespace KlimacontrolTray;

/// Zur Übersetzungszeit erzeugte JSON-Leser für die Brückendaten (keine Reflexion: schnellerer Start, weniger Speicher).
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(Snapshot))]
[JsonSerializable(typeof(LiveInfo))]
[JsonSerializable(typeof(List<Sample>))]
[JsonSerializable(typeof(HistoryStats))]
[JsonSerializable(typeof(List<NoticeInfo>))]
[JsonSerializable(typeof(EnergyResult))]
partial class BridgeJson : JsonSerializerContext;

/// Naht zwischen `Core` und der Swift-Brücke; Tests setzen eine nachgebildete Brücke ein (ohne DLL).
interface ICoreBridge
{
    /// Version der C-Schnittstelle (kc_api_version); null = ältere DLL ohne diese Angabe.
    int? ApiVersion();
    /// Startet den Kern (kc_init).
    void Init(string version);
    /// Leert die Main-Queue des Kerns einmal (kc_pump).
    void Pump();
    /// Beendet Abfrage, Timer und Verbindung (kc_stop).
    void Stop();
    long StateRev();
    string StateJson();
    string LiveJson();
    /// null = angenommen, sonst Fehlermeldung.
    string? Command(string json);
    /// Protokollzeile (App: %TEMP%\klimacontrol-ui.log).
    void Trace(string line);
}

sealed class NativeBridge : ICoreBridge
{
    public static readonly NativeBridge Instance = new();
    public int? ApiVersion() => Native.ApiVersion();
    public void Init(string version) => Native.Init(version);
    public void Pump() => Native.kc_pump();
    public void Stop() => Native.kc_stop();
    public long StateRev() => Native.StateRev();
    public string StateJson() => Native.StateJson();
    public string LiveJson() => Native.LiveJson();
    public string? Command(string json) => Native.Command(json);
    public void Trace(string line) => App.Trace(line);
}

/// exe und res\KlimacontrolBridge.dll passen nicht zusammen (kc_api_version fehlt oder weicht ab).
/// Abgeleitet von EntryPointNotFoundException, damit der Start-Fehlerweg der App sie mit abfängt.
sealed class BridgeVersionException : EntryPointNotFoundException
{
    /// Version der DLL; null = DLL zu alt (ohne kc_api_version).
    public int? Found { get; }
    public int Expected { get; }

    public BridgeVersionException(int? found, int expected)
        : base("Klimacontrol.exe und der Kern im Ordner „res“ passen nicht zusammen – sie stammen aus verschiedenen Ständen. "
               + "Bitte den ganzen Ordner aus dem ZIP übernehmen. "
               + $"(Schnittstelle {(found is { } f ? f.ToString() : "fehlt")}, erwartet {expected})")
    {
        Found = found;
        Expected = expected;
    }
}

/// Verbindung zum Swift-Kern: bedient dessen Main-Queue und liest den Zustand. Fenster hängen sich an `Changed`.
sealed class Core
{
    public static readonly Core Shared = new();

    /// Rückgabe von `Send` nach `Stop()` (App wird beendet): Der Befehl kommt nicht mehr beim Kern an.
    public const string StoppedText = "Klimacontrol wird gerade beendet. Der Befehl wurde nicht mehr ausgeführt.";

    readonly ICoreBridge bridge;

    Core() : this(NativeBridge.Instance) { }

    /// Für Tests: Core mit nachgebildeter Brücke. Ohne Start() – Poll() und Send() gehen trotzdem (ohne Timer).
    internal Core(ICoreBridge bridge) => this.bridge = bridge;

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public Snapshot Snap { get; private set; } = new();
    public event Action? Changed;

    DispatcherTimer? pump, poll;
    Dispatcher? ui;
    /// Zuletzt übernommener (gültiger) Schnappschuss-Text.
    string last = "";
    /// Zuletzt gelesener Revisionszähler (kc_state_rev); -1 = noch nie gelesen.
    long lastRev = -1;
    /// Gewünschter und an den Kern gemeldeter Sichtbarkeitsstand je Oberfläche ("main", "flyout", "settings").
    readonly Dictionary<string, bool> uiWanted = new(), uiSent = new();
    /// pumpQueued: Pumpen+Lesen nach einem Befehl ist schon eingereiht. started: kc_init lief. stopped: nach Stop().
    /// powerEvents: an SystemEvents angemeldet.
    bool pumpQueued, started, stopped, powerEvents;
    /// Bis wann schnell gepumpt wird (nach einem Befehl, solange eine Abfrage läuft).
    DateTime fastUntil;

    // Die Main-Queue des Kerns leert sich unter Windows nicht von selbst (kein Run-Loop wie am Mac), darum kc_pump.
    // Nach Befehlen und während Abfragen schnell pumpen, sonst gemächlich; nur im Infobereich noch seltener.
    static readonly TimeSpan PumpFast = TimeSpan.FromMilliseconds(30), PumpIdle = TimeSpan.FromMilliseconds(250),
                             PumpHidden = TimeSpan.FromMilliseconds(500);
    // Zustand lesen: mit sichtbarem Fenster 4×/s, nur im Infobereich alle 2 s (Symbol und Tooltip).
    static readonly TimeSpan PollVisible = TimeSpan.FromMilliseconds(250), PollHidden = TimeSpan.FromSeconds(2);
    bool windowVisible = true;
    /// Ein Fenster ist sichtbar (setzt der Lesetakt aus den offenen Fenstern; Tests setzen es selbst).
    internal bool WindowVisible { get => windowVisible; set => windowVisible = value; }

    // kc_pump verarbeitet auch Fenster-Nachrichten: Öffnet ein Handler darin einen modalen Dialog, kehrt es erst nach
    // dessen Schließen zurück. Läuft der äußere Aufruf länger als `StuckAfter`, wird darum eine Ebene tief verschachtelt
    // gepumpt, damit der Kern weiterläuft; kürzere Überschneidungen werden übersprungen.
    const int MaxPumpDepth = 2;
    int pumpDepth;
    long pumpStarted;
    /// Takte, die in der laufenden Hänge-Phase übersprungen bzw. verschachtelt gepumpt wurden.
    int pumpSkipped, pumpNested;
    bool pumpStuck;
    /// Ab wann ein laufendes kc_pump als „hängt in einem Dialog“ gilt (Tests setzen 0).
    internal TimeSpan StuckAfter { get; set; } = TimeSpan.FromMilliseconds(500);
    /// kc_pump läuft gerade (auch verschachtelt).
    internal bool InPump => pumpDepth > 0;

    /// Fehler beim Lesen der Kern-Daten: höchstens eine Zeile je Art und Minute (nicht viermal je Sekunde).
    static readonly TimeSpan ErrorLogPause = TimeSpan.FromMinutes(1);
    readonly Dictionary<string, DateTime> errorLogged = new();

    void TraceOnce(string kind, string line)
    {
        var now = DateTime.UtcNow;
        if (errorLogged.TryGetValue(kind, out var at) && now - at < ErrorLogPause) return;
        errorLogged[kind] = now;
        bridge.Trace(line);
    }

    /// Startet den Kern, den Takt und die Abfrage. Wirft `BridgeVersionException`, wenn exe und DLL nicht
    /// zusammenpassen (auch: DLL ohne kc_api_version), und DllNotFound/BadImageFormat, wenn die DLL fehlt oder kaputt ist.
    public void Start(string version) => Start(version, background: true);

    /// background: Takt-Timer und Standby-Meldungen (Tests: false – dann laufen nur eingereihte Aufträge).
    internal void Start(string version, bool background)
    {
        if (started || stopped) return;
        var api = bridge.ApiVersion();
        if (api != Native.ExpectedApi)
        {
            bridge.Trace($"FEHLER Kern-Schnittstelle {(api is { } f ? f.ToString() : "fehlt")}, erwartet {Native.ExpectedApi}");
            throw new BridgeVersionException(api, Native.ExpectedApi);
        }
        bridge.Init(version);
        started = true;
        ui = Dispatcher.CurrentDispatcher;
        if (background)
        {
            pump = new DispatcherTimer(DispatcherPriority.Background) { Interval = PumpFast };
            pump.Tick += (_, _) => PumpTick();
            pump.Start();
            poll = new DispatcherTimer(DispatcherPriority.Background) { Interval = PollVisible };
            poll.Tick += (_, _) => { Poll(); AdjustPoll(); };
            poll.Start();
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            powerEvents = true;
        }
        foreach (var (id, visible) in uiWanted) SendUIVisible(id, visible);
        Hurry();
        Poll();
    }

    /// Meldet dem Kern, ob eine Oberfläche sichtbar ist (ohne sichtbare fragt er höchstens alle 30 s ab).
    /// Nur Änderungen gehen an den Kern; vor Start() gemerkt und beim Start nachgeholt.
    public void SetUIVisible(string id, bool visible)
    {
        uiWanted[id] = visible;
        if (ui == null || stopped) return;
        SendUIVisible(id, visible);
    }

    void SendUIVisible(string id, bool visible)
    {
        if (uiSent.TryGetValue(id, out var was) && was == visible) return;
        // Sichtbar wie ein Befehl (schnell pumpen), unsichtbar nur melden. Nie synchron pumpen: kann mitten im Layout
        // aus IsVisibleChanged kommen.
        string? r;
        if (visible) r = Send(Cmd.UiVisible, ("id", id), ("visible", visible));
        else
        {
            r = bridge.Command(BuildJson(Cmd.UiVisible, new (string Key, object? Value)[] { ("id", id), ("visible", visible) }));
            if (r != null) bridge.Trace($"FEHLER Befehl uiVisible {id}={visible}: {r}");
        }
        if (r == null) uiSent[id] = visible;
    }

    /// Beendet Takt und Kern. Mehrfach aufrufbar (Beenden-Menü, OnExit, Abmelden/Herunterfahren) und auch, wenn
    /// Start() nie gelungen ist – dann wird die DLL nicht mehr angefasst.
    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        if (powerEvents) SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        powerEvents = false;
        pump?.Stop();
        poll?.Stop();
        if (!started) return;
        try { bridge.Stop(); }
        catch (Exception ex) { bridge.Trace("FEHLER Kern beenden: " + ex.Message); }
    }

    /// Nach dem Aufwachen aus dem Standby sofort frisch lesen (die WLAN-Verbindung von vorher ist meist tot), beim
    /// Einschlafen den schnellen Takt beenden. SystemEvents meldet auf einem eigenen Thread.
    void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e) => ui?.InvokeAsync(() =>
    {
        if (stopped) return;
        if (e.Mode == PowerModes.Resume) Send(Cmd.Refresh);
        else if (e.Mode == PowerModes.Suspend) fastUntil = DateTime.MinValue;
    });

    /// Main-Queue des Kerns einmal leeren. Verschachtelt nur, wenn der äußere Aufruf in einem Dialog hängt (s. o.).
    void PumpOnce()
    {
        if (stopped) return;
        if (pumpDepth > 0)
        {
            var running = Stopwatch.GetElapsedTime(pumpStarted);
            if (running < StuckAfter || pumpDepth >= MaxPumpDepth)
            {
                pumpSkipped++;
                return;
            }
            if (!pumpStuck)
            {
                pumpStuck = true;
                bridge.Trace($"Kern-Takt: Pumpen hängt seit {running.TotalSeconds:0.0} s (Dialog offen: "
                             + $"{(ComponentDispatcher.IsThreadModal ? "ja" : "vermutlich")}) – pumpe verschachtelt weiter");
            }
            pumpNested++;
        }
        else
        {
            pumpStarted = Stopwatch.GetTimestamp();
            pumpSkipped = pumpNested = 0;
            pumpStuck = false;
        }
        pumpDepth++;
        try { bridge.Pump(); }
        finally
        {
            pumpDepth--;
            if (pumpDepth == 0 && pumpStuck)
            {
                var s = Stopwatch.GetElapsedTime(pumpStarted).TotalSeconds;
                bridge.Trace($"Kern-Takt: wieder normal nach {s:0.0} s ({pumpNested}× verschachtelt, {pumpSkipped}× übersprungen)");
                pumpStuck = false;
            }
        }
    }

    /// Takt des Pump-Timers: pumpen und den Takt an die Lage anpassen.
    internal void PumpTick()
    {
        PumpOnce();
        var fast = DateTime.UtcNow < fastUntil || Snap.Busy || Snap.CloudLoginRunning || Snap.Setup.Busy || Snap.Setup.Scanning;
        var want = fast ? PumpFast : windowVisible ? PumpIdle : PumpHidden;
        if (pump != null && pump.Interval != want) pump.Interval = want;
    }

    /// Ein Fenster ist offen und nicht minimiert (dann lohnt der schnelle Lesetakt).
    static bool AnyWindowVisible()
    {
        if (System.Windows.Application.Current is not { } app) return false;
        foreach (System.Windows.Window w in app.Windows)
            if (w.IsVisible && w.WindowState != System.Windows.WindowState.Minimized) return true;
        return false;
    }

    void AdjustPoll()
    {
        windowVisible = AnyWindowVisible();
        var want = windowVisible ? PollVisible : PollHidden;
        if (poll != null && poll.Interval != want) poll.Interval = want;
    }

    /// Schnell pumpen und lesen – nach Befehlen und wenn ein Fenster erscheint (App ruft das beim Zeigen).
    public void Hurry(double seconds = 3)
    {
        fastUntil = DateTime.UtcNow.AddSeconds(seconds);
        windowVisible = true;
        if (pump != null && pump.Interval != PumpFast) pump.Interval = PumpFast;
        if (poll != null && poll.Interval != PollVisible) poll.Interval = PollVisible;
    }

    public void Poll()
    {
        if (stopped) return;
        // busy/nextRefresh und die zeitabhängigen Texte kommen getrennt (kc_live_json), damit der Zähler nicht bei jeder Abfrage springt.
        // Unlesbar: letzte Werte behalten, einmal protokollieren.
        LiveInfo? live = null;
        try { live = JsonSerializer.Deserialize(bridge.LiveJson(), BridgeJson.Default.LiveInfo) ?? new LiveInfo(); }
        catch (JsonException ex) { TraceOnce("live", "FEHLER Kern-Daten (busy/nextRefresh) nicht lesbar, letzter Stand bleibt: " + ex.Message); }
        var changed = false;
        // Schnappschuss nur bei geändertem Zähler lesen; der Textvergleich bleibt als Sicherheitsnetz.
        var rev = bridge.StateRev();
        if (rev != lastRev)
        {
            // Gleicher Zähler liefert denselben Text: Ein unlesbarer Stand wird erst beim nächsten Zähler neu versucht.
            lastRev = rev;
            var j = bridge.StateJson();
            if (j != last && ReadSnapshot(j) is { } snap)
            {
                last = j;
                snap.Busy = Snap.Busy;
                snap.NextRefresh = Snap.NextRefresh;
                // Die eben gelesenen Live-Texte gleich mitnehmen, sonst zeigte die Verbindungszeile bis zum nächsten Takt den alten Stand.
                snap.ConnectionLine = live?.ConnectionLine ?? Snap.ConnectionLine;
                snap.OffTimerChip = live != null ? live.OffTimerChip : Snap.OffTimerChip;
                snap.NextRefreshLine = live?.NextRefreshLine ?? Snap.NextRefreshLine;
                Snap = snap;
                changed = true;
            }
        }
        if (live != null)
        {
            // Neuzeichnen wegen busy lohnt nur mit sichtbarem Fenster.
            if (Snap.Busy != live.Busy) { Snap.Busy = live.Busy; changed |= windowVisible; }
            // Countdown allein ist kein Grund zum Neuzeichnen – die Diagnose zählt selbst herunter.
            Snap.NextRefresh = live.NextRefresh;
            // Zeitabhängige Texte des Kerns: laufen allein weiter (kein Grund zum Neuzeichnen, die Bausteine lesen sie im Takt).
            Snap.ConnectionLine = live.ConnectionLine;
            Snap.OffTimerChip = live.OffTimerChip;
            Snap.NextRefreshLine = live.NextRefreshLine;
        }
        if (!changed || Changed == null) return;
        // Einzeln aufrufen: Ein werfender Abonnent soll die übrigen (z. B. das Infobereich-Symbol) nicht abhängen.
        foreach (var d in Changed.GetInvocationList())
        {
            try { ((Action)d)(); }
            catch (Exception ex) { bridge.Trace("FEHLER Oberfläche (Changed): " + ex); }
        }
    }

    /// Schnappschuss aus dem Kern-Text; null = nicht übernehmen (letzter guter Stand bleibt sichtbar).
    Snapshot? ReadSnapshot(string json)
    {
        Snapshot? snap;
        try { snap = JsonSerializer.Deserialize(json, BridgeJson.Default.Snapshot); }
        catch (JsonException ex)
        {
            TraceOnce("state", "FEHLER Kern-Zustand nicht lesbar, letzter Stand bleibt: " + ex.Message);
            return null;
        }
        if (snap != null)
        {
            // Kodierfehler im Kern ohne früheren Stand: {"jsonError":true} – kein echter Zustand (sonst „nicht eingerichtet“).
            if (json.Length < 64 && json.Contains("\"jsonError\":true", StringComparison.Ordinal))
            {
                TraceOnce("state", "FEHLER Kern konnte den Zustand nicht liefern (jsonError), letzter Stand bleibt");
                return null;
            }
            return snap;
        }
        // "null" = Kern nicht gestartet. Vor Start() ist das der leere Anfangsstand; danach kein Grund, die Oberfläche
        // auf „nicht eingerichtet“ springen zu lassen.
        if (!started) return new Snapshot();
        TraceOnce("null", "FEHLER Kern liefert keinen Zustand, letzter Stand bleibt");
        return null;
    }

    /// Baut einen Befehl als JSON. Feste Schlüssel statt anonymer Objekte, damit der Obfuscator die Serialisierung
    /// nicht bricht.
    static string BuildJson(string cmd, (string Key, object? Value)[] args)
    {
        var d = new Dictionary<string, object?>(args.Length + 1) { ["cmd"] = cmd };
        foreach (var (k, v) in args) d[k] = v;
        return JsonSerializer.Serialize(d, Json);
    }

    /// Befehl an den Kern, z. B. Send(Cmd.Power, ("on", true)). null = angenommen, sonst Fehlermeldung (steht auch im
    /// Protokoll – nur Befehlsname und Text, nie die Argumente, darin können Passwörter stehen). Nach Stop() kommt
    /// `StoppedText` zurück.
    public string? Send(string cmd, params (string Key, object? Value)[] args)
    {
        if (stopped) return StoppedText;
        var r = bridge.Command(BuildJson(cmd, args));
        if (r != null) bridge.Trace($"FEHLER Befehl {cmd}: {r}");
        // Nicht synchron pumpen: Send kann mitten im WPF-Layout kommen, dort wirft WPF „Dispatcherverarbeitung wurde
        // angehalten …“. Ein eingereihter Auftrag genügt für mehrere Befehle.
        Hurry();
        if (!pumpQueued && ui != null)
        {
            pumpQueued = true;
            ui.InvokeAsync(() => { pumpQueued = false; PumpOnce(); Poll(); }, DispatcherPriority.Background);
        }
        return r;
    }

    public List<Sample> History(TimeSpan span) => stopped ? new()
        : Read("history", () => JsonSerializer.Deserialize(Native.HistoryJson(span.TotalSeconds), BridgeJson.Default.ListSample)) ?? new();

    /// Ø/Spitze/kWh des Zeitraums aus allen gespeicherten Punkten (HistoryStore.stats im Kern).
    public HistoryStats Stats(TimeSpan span) => stopped ? new()
        : Read("stats", () => JsonSerializer.Deserialize(Native.HistoryStatsJson(span.TotalSeconds), BridgeJson.Default.HistoryStats)) ?? new();

    /// Verbrauch je Tag/Woche/Monat (kind: day, week, month) für den Verlauf; null = nicht lesbar.
    public EnergyResult? Energy(string kind, int count) => stopped ? null
        : Read("energy", () => JsonSerializer.Deserialize(Native.EnergyJson(kind, count), BridgeJson.Default.EnergyResult));

    /// Quellen und Lizenzen für den Reiter „Lizenzen“ (ThirdPartyNotices.all im Kern).
    public List<NoticeInfo> Notices() => stopped ? new()
        : Read("notices", () => JsonSerializer.Deserialize(Native.ThirdPartyJson(), BridgeJson.Default.ListNoticeInfo)) ?? new();

    /// Unlesbare Antwort des Kerns: leer statt Fehlerdialog (wie bei Poll), einmal im Protokoll.
    T? Read<T>(string what, Func<T?> read) where T : class
    {
        try { return read(); }
        catch (JsonException ex) { TraceOnce(what, $"FEHLER Kern-Daten ({what}) nicht lesbar: " + ex.Message); return null; }
    }
}

/// Deutsche Zahlen wie Fmt im Kern.
static class Fmt
{
    static readonly CultureInfo De = CultureInfo.GetCultureInfo("de-DE");
    public static string Num(double v, int digits) => v.ToString("N" + digits, De);
    // Wie Fmt.temp/Fmt.target im Kern (Mac): „21,5°“ bzw. „22°“.
    public static string Temp(double? v) => v.HasValue ? Num(v.Value, 1) + "°" : "–";
    public static string Target(double v) => Num(Math.Round(v), 0) + "°";
    public static string Watts(double? v) => v.HasValue ? Num(v.Value, 0) + " W" : "–";
    public static string Kwh(double? v) => v.HasValue ? Num(v.Value, 2) + " kWh" : "–";
    public static string Euro(double? v) => v.HasValue ? Num(v.Value, 2) + " €" : "–";
    // Wie die Regler am Mac (PanelsAppearance): Anteil 0–1 als ganze Prozent („40 %“), Unschärfe als „20 pt“; gerundet
    // wie Swift `rounded()` (ab ,5 weg von null).
    public static string Percent(double fraction) => Num(Math.Round(fraction * 100, MidpointRounding.AwayFromZero), 0) + " %";
    public static string Points(double v) => Num(Math.Round(v, MidpointRounding.AwayFromZero), 0) + " pt";
    public static string Clock(double epoch) => Codes.Local(epoch).ToString("HH:mm", De);

    public static string Ago(double? epoch)
    {
        if (!epoch.HasValue) return "noch nicht gelesen";
        var s = (DateTime.Now - Codes.Local(epoch.Value)).TotalSeconds;
        if (s < 60) return $"vor {Math.Max(0, (int)s)} s";
        if (s < 3600) return $"vor {(int)(s / 60)} min";
        return "um " + Clock(epoch.Value);
    }
}
