using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Windows.Threading;
using Xunit;

namespace KlimacontrolTray.Tests;

/// Nachgebildete Brücke: liefert vorgegebene Werte und zählt, was Core liest.
sealed class FakeBridge : ICoreBridge
{
    public long Rev;
    public string State = "{\"configured\":true}";
    public string Live = "{\"busy\":false}";
    public string? CommandResult;
    public int? Api = Native.ExpectedApi;
    public int RevReads, StateReads, LiveReads, Inits, Pumps, Stops, MaxDepth;
    public Exception? StopThrows;
    /// Läuft innerhalb von Pump (Tiefe 1, 2 …) – so lässt sich ein Dialog in kc_pump nachbilden.
    public Action<int>? OnPump;
    int depth;
    public readonly List<string> Commands = new();
    public readonly List<string> Traces = new();

    public int? ApiVersion() => Api;
    public void Init(string version) => Inits++;
    public void Pump()
    {
        Pumps++;
        depth++;
        MaxDepth = Math.Max(MaxDepth, depth);
        try { OnPump?.Invoke(depth); }
        finally { depth--; }
    }
    public void Stop() { Stops++; if (StopThrows != null) throw StopThrows; }
    public long StateRev() { RevReads++; return Rev; }
    public string StateJson() { StateReads++; return State; }
    public string LiveJson() { LiveReads++; return Live; }
    public string? Command(string json) { Commands.Add(json); return CommandResult; }
    public void Trace(string line) => Traces.Add(line);
}

public class CoreTests
{
    readonly FakeBridge bridge = new();
    readonly Core core;
    int changed;

    public CoreTests()
    {
        core = new Core(bridge);
        core.Changed += () => changed++;
    }

    [Fact]
    public void ZeitabhaengigeTexteKommenAusDemLiveTeil()
    {
        bridge.Live = "{\"busy\":false,\"connectionLine\":\"Verbunden über WLAN · gerade aktualisiert\",\"offTimerChip\":\"Aus in 5 min\",\"nextRefreshLine\":\"Live 1\"}";
        core.Poll();
        Assert.Equal("Verbunden über WLAN · gerade aktualisiert", core.Snap.ConnectionLine);
        Assert.Equal("Aus in 5 min", core.Snap.OffTimerChip);
        Assert.Equal("Live 1", core.Snap.NextRefreshLine);
        // Die Texte laufen allein weiter: ohne neuen Zähler wird der Zustand nicht noch einmal gelesen.
        bridge.Live = "{\"busy\":false,\"connectionLine\":\"Verbunden über WLAN · vor 1 min aktualisiert\",\"nextRefreshLine\":\"Live 2\"}";
        core.Poll();
        Assert.Equal("Verbunden über WLAN · vor 1 min aktualisiert", core.Snap.ConnectionLine);
        Assert.Null(core.Snap.OffTimerChip);
        Assert.Equal("Live 2", core.Snap.NextRefreshLine);
        Assert.Equal(1, bridge.StateReads);
        // Ein neuer Schnappschuss übernimmt gleich die zuletzt gelesenen Texte.
        bridge.Rev = 1;
        bridge.State = "{\"configured\":false}";
        core.Poll();
        Assert.Equal("Verbunden über WLAN · vor 1 min aktualisiert", core.Snap.ConnectionLine);
        Assert.Equal("Live 2", core.Snap.NextRefreshLine);
    }

    [Fact]
    public void ErsteAbfrageLiestZustandUndMeldetAenderung()
    {
        core.Poll();
        Assert.Equal(1, bridge.StateReads);
        Assert.Equal(1, changed);
        Assert.True(core.Snap.Configured);
    }

    [Fact]
    public void GleicherZaehlerLiestZustandNichtNochEinmal()
    {
        core.Poll();
        bridge.State = "{\"configured\":false}"; // ohne neuen Zähler darf das nicht gelesen werden
        core.Poll();
        core.Poll();
        Assert.Equal(1, bridge.StateReads);
        Assert.Equal(3, bridge.RevReads);
        Assert.Equal(1, changed);
        Assert.True(core.Snap.Configured);
    }

    [Fact]
    public void NeuerZaehlerMitGleichemTextMeldetKeineAenderung()
    {
        core.Poll();
        var snap = core.Snap;
        bridge.Rev = 1;
        core.Poll();
        Assert.Equal(2, bridge.StateReads);
        Assert.Equal(1, changed);
        Assert.Same(snap, core.Snap);
    }

    [Fact]
    public void NeuerZaehlerMitNeuemTextErsetztSchnappschuss()
    {
        core.Poll();
        var snap = core.Snap;
        bridge.Rev = 1;
        bridge.State = "{\"configured\":true,\"state\":{\"power\":true,\"target\":22}}";
        core.Poll();
        Assert.Equal(2, changed);
        Assert.NotSame(snap, core.Snap);
        Assert.True(core.Snap.State?.Power);
        Assert.Equal(22, core.Snap.State?.Target);
    }

    [Fact]
    public void KleinererZaehlerZaehltAuchAlsAenderung()
    {
        bridge.Rev = 5;
        core.Poll();
        bridge.Rev = 0; // Kern neu gestartet
        bridge.State = "{\"configured\":false}";
        core.Poll();
        Assert.Equal(2, changed);
        Assert.False(core.Snap.Configured);
    }

    [Fact]
    public void BusyAendertSnapMitChangedBeiSichtbaremFenster()
    {
        core.Poll();
        var snap = core.Snap;
        bridge.Live = "{\"busy\":true}";
        core.Poll();
        Assert.True(core.Snap.Busy);
        Assert.Same(snap, core.Snap);
        Assert.Equal(1, bridge.StateReads);
        Assert.Equal(2, changed);
        core.Poll(); // unverändert busy → nichts Neues
        Assert.Equal(2, changed);
        bridge.Live = "{\"busy\":false}";
        core.Poll();
        Assert.False(core.Snap.Busy);
        Assert.Equal(3, changed);
    }

    [Fact]
    public void BusyOhneSichtbaresFensterOhneChanged()
    {
        core.WindowVisible = false;
        core.Poll();
        Assert.Equal(1, changed);
        bridge.Live = "{\"busy\":true}";
        core.Poll();
        Assert.True(core.Snap.Busy);
        Assert.Equal(1, changed);
    }

    [Fact]
    public void NaechsteAbfrageAendertSnapOhneChanged()
    {
        core.Poll();
        bridge.Live = "{\"busy\":false,\"nextRefresh\":1700000000.5}";
        core.Poll();
        Assert.Equal(1700000000.5, core.Snap.NextRefresh);
        bridge.Live = "{\"busy\":false,\"nextRefresh\":1700000010}";
        core.Poll();
        Assert.Equal(1700000010, core.Snap.NextRefresh);
        Assert.Equal(1, changed);
    }

    [Fact]
    public void NeuerSchnappschussBehaeltLiveWerte()
    {
        bridge.Live = "{\"busy\":true,\"nextRefresh\":42}";
        core.Poll();
        bridge.Rev = 1;
        bridge.State = "{\"configured\":false}";
        core.Poll();
        Assert.True(core.Snap.Busy);
        Assert.Equal(42, core.Snap.NextRefresh);
    }

    [Fact]
    public void ZustandNullErgibtLeerenSchnappschuss()
    {
        bridge.State = "null";
        bridge.Live = "{}";
        core.Poll();
        Assert.False(core.Snap.Configured);
        Assert.Null(core.Snap.State);
        Assert.Equal(1, changed);
    }

    [Fact]
    public void WerfenderAbonnentHaengtUebrigeNichtAb()
    {
        var after = 0;
        var c = new Core(bridge);
        c.Changed += () => throw new InvalidOperationException("kaputt");
        c.Changed += () => after++;
        c.Poll();
        Assert.Equal(1, after);
        Assert.Single(bridge.Traces);
        Assert.Contains("kaputt", bridge.Traces[0]);
    }

    [Fact]
    public void SendBautBefehlAlsJson()
    {
        Assert.Null(core.Send("nudgeTemp", ("delta", -1.0)));
        Assert.Null(core.Send("refresh"));
        Assert.Null(core.Send("power", ("on", true)));
        Assert.Equal(3, bridge.Commands.Count);
        using (var d = JsonDocument.Parse(bridge.Commands[0]))
        {
            Assert.Equal("nudgeTemp", d.RootElement.GetProperty("cmd").GetString());
            Assert.Equal(-1.0, d.RootElement.GetProperty("delta").GetDouble());
        }
        Assert.Equal("{\"cmd\":\"refresh\"}", bridge.Commands[1]);
        using (var d = JsonDocument.Parse(bridge.Commands[2]))
            Assert.True(d.RootElement.GetProperty("on").GetBoolean());
    }

    [Fact]
    public void SendGibtFehlerDesKernsZurueck()
    {
        bridge.CommandResult = "unbekannter Befehl";
        Assert.Equal("unbekannter Befehl", core.Send("gibtsnicht"));
    }

    /// Führt alle eingereihten Aufträge (Priorität Background und höher) auf dem Dispatcher dieses Threads aus.
    static void Drain()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.InvokeAsync(() => frame.Continue = false, DispatcherPriority.ContextIdle);
        Dispatcher.PushFrame(frame);
    }

    // --- Fehler zentral protokollieren, ohne Argumente ---

    [Fact]
    public void FehlerEinesBefehlsStehtImProtokollOhneArgumente()
    {
        bridge.CommandResult = "Anmeldung fehlgeschlagen.";
        core.Send("cloudLogin", ("account", "a@b.de"), ("password", "geheim123"));
        var line = Assert.Single(bridge.Traces);
        Assert.Equal("FEHLER Befehl cloudLogin: Anmeldung fehlgeschlagen.", line);
        Assert.DoesNotContain("geheim123", line);
        Assert.DoesNotContain("a@b.de", line);
    }

    [Fact]
    public void AngenommenerBefehlSchreibtNichtsInsProtokoll()
    {
        core.Send("refresh");
        Assert.Empty(bridge.Traces);
    }

    // --- Start, Einreihung, Stop, SetUIVisible ---

    [Fact]
    public void StartPrueftVersionStartetKernUndLiest()
    {
        core.Start("1.2.3", background: false);
        Assert.Equal(1, bridge.Inits);
        Assert.Equal(1, bridge.StateReads);
        Assert.Equal(1, changed);
        core.Start("1.2.3", background: false); // zweimal harmlos
        Assert.Equal(1, bridge.Inits);
        core.Stop();
    }

    [Fact]
    public void FalscheSchnittstellenVersionVerhindertStart()
    {
        bridge.Api = Native.ExpectedApi + 1;
        var ex = Assert.Throws<BridgeVersionException>(() => core.Start("x", background: false));
        Assert.IsAssignableFrom<EntryPointNotFoundException>(ex); // fängt der Start-Fehlerweg der App schon
        Assert.Contains("ganzen Ordner", ex.Message);
        Assert.Equal(0, bridge.Inits);
        core.Stop(); // ohne gelungenen Start: DLL nicht mehr anfassen
        Assert.Equal(0, bridge.Stops);
    }

    [Fact]
    public void AlteDllOhneVersionVerhindertStart()
    {
        bridge.Api = null;
        var ex = Assert.Throws<BridgeVersionException>(() => core.Start("x", background: false));
        Assert.Null(ex.Found);
        Assert.Contains("Schnittstelle fehlt, erwartet 2", ex.Message);
        Assert.Equal(0, bridge.Inits);
        Assert.Contains(bridge.Traces, t => t.StartsWith("FEHLER Kern-Schnittstelle fehlt"));
    }

    [Fact]
    public void MehrereBefehleReihenEinPumpenEin()
    {
        core.Start("x", background: false);
        var reads = bridge.StateReads;
        core.Send("temp", ("value", 22.0));
        core.Send("temp", ("value", 23.0));
        core.Send("temp", ("value", 24.0));
        Assert.Equal(0, bridge.Pumps); // nie synchron (WPF-Layout)
        Drain();
        Assert.Equal(1, bridge.Pumps);
        Assert.Equal(reads, bridge.StateReads); // gleicher Zähler: nicht neu gelesen
        Assert.True(bridge.LiveReads >= 2);
        core.Send("refresh");
        Drain();
        Assert.Equal(2, bridge.Pumps);
        core.Stop();
    }

    [Fact]
    public void StopIstMehrfachAufrufbarUndBeendetBefehle()
    {
        core.Start("x", background: false);
        core.Stop();
        core.Stop();
        Assert.Equal(1, bridge.Stops);
        var n = bridge.Commands.Count;
        Assert.Equal(Core.StoppedText, core.Send("power", ("on", true)));
        Assert.Equal(n, bridge.Commands.Count);
        var reads = bridge.LiveReads;
        core.Poll();
        Assert.Equal(reads, bridge.LiveReads);
        Drain();
        Assert.Equal(0, bridge.Pumps);
    }

    [Fact]
    public void StopVorDemStartFasstDenKernNichtAn()
    {
        core.Stop();
        Assert.Equal(0, bridge.Stops);
        Assert.Equal(Core.StoppedText, core.Send("refresh"));
        Assert.Empty(bridge.Commands);
    }

    [Fact]
    public void FehlerBeimBeendenWirdProtokolliert()
    {
        core.Start("x", background: false);
        bridge.StopThrows = new InvalidOperationException("weg");
        core.Stop();
        Assert.Contains(bridge.Traces, t => t.Contains("Kern beenden") && t.Contains("weg"));
    }

    [Fact]
    public void SichtbarkeitWirdVorDemStartGemerktUndNurGeaendertGesendet()
    {
        core.SetUIVisible("main", true);
        core.SetUIVisible("flyout", false);
        Assert.Empty(bridge.Commands);
        core.Start("x", background: false);
        Assert.Equal(2, bridge.Commands.Count);
        Assert.Contains(bridge.Commands, c => c.Contains("\"main\"") && c.Contains("\"visible\":true"));
        Assert.Contains(bridge.Commands, c => c.Contains("\"flyout\"") && c.Contains("\"visible\":false"));
        core.SetUIVisible("main", true); // unverändert
        Assert.Equal(2, bridge.Commands.Count);
        core.SetUIVisible("main", false); // unsichtbar: melden, aber nicht einreihen
        Assert.Equal(3, bridge.Commands.Count);
        Drain();
        Assert.Equal(1, bridge.Pumps); // nur der Auftrag vom sichtbaren „main“
        core.Stop();
        core.SetUIVisible("main", true); // nach Stop nichts mehr
        Assert.Equal(3, bridge.Commands.Count);
    }

    [Fact]
    public void AbgelehnteSichtbarkeitWirdErneutVersucht()
    {
        core.Start("x", background: false);
        bridge.CommandResult = "Oberfläche fehlt";
        core.SetUIVisible("settings", false);
        Assert.Contains(bridge.Traces, t => t.StartsWith("FEHLER Befehl uiVisible settings=False"));
        bridge.CommandResult = null;
        core.SetUIVisible("settings", false);
        Assert.Equal(2, bridge.Commands.Count);
        core.Stop();
    }

    // --- unlesbare Daten ---

    [Fact]
    public void UnlesbarerZustandBehaeltLetztenStandUndProtokolliertEinmal()
    {
        core.Poll();
        var good = core.Snap;
        for (var i = 1; i <= 5; i++)
        {
            bridge.Rev = i;
            bridge.State = "{\"configured\":tru" + i; // kaputt
            core.Poll();
        }
        Assert.Same(good, core.Snap);
        Assert.Equal(1, changed);
        Assert.Single(bridge.Traces, t => t.Contains("Kern-Zustand nicht lesbar"));
        bridge.Rev = 9;
        bridge.State = "{\"configured\":false}";
        core.Poll();
        Assert.False(core.Snap.Configured);
        Assert.Equal(2, changed);
    }

    [Fact]
    public void UnlesbareLiveWerteBehaltenLetztenStand()
    {
        bridge.Live = "{\"busy\":true,\"nextRefresh\":42}";
        core.Poll();
        bridge.Live = "<kaputt>";
        core.Poll();
        core.Poll();
        Assert.True(core.Snap.Busy);
        Assert.Equal(42, core.Snap.NextRefresh);
        Assert.Single(bridge.Traces, t => t.Contains("busy/nextRefresh"));
    }

    [Fact]
    public void KodierfehlerDesKernsBehaeltLetztenStand()
    {
        core.Start("x", background: false);
        bridge.Rev = 1;
        bridge.State = "{\"jsonError\":true}";
        core.Poll();
        bridge.Rev = 2;
        core.Poll();
        Assert.True(core.Snap.Configured);
        Assert.Equal(1, changed);
        Assert.Single(bridge.Traces, t => t.Contains("jsonError"));
        core.Stop();
    }

    [Fact]
    public void NullNachDemStartGiltNichtAlsNichtEingerichtet()
    {
        core.Start("x", background: false);
        Assert.True(core.Snap.Configured);
        bridge.Rev = 1;
        bridge.State = "null";
        core.Poll();
        Assert.True(core.Snap.Configured);
        Assert.Single(bridge.Traces, t => t.Contains("keinen Zustand"));
        core.Stop();
    }

    // --- Dialog innerhalb von kc_pump ---

    [Fact]
    public void KurzeUeberschneidungWirdStillUebersprungen()
    {
        core.Start("x", background: false);
        bridge.OnPump = depth => { if (depth == 1) core.PumpTick(); };
        core.PumpTick();
        Assert.Equal(1, bridge.Pumps);
        Assert.Equal(1, bridge.MaxDepth);
        Assert.DoesNotContain(bridge.Traces, t => t.Contains("Kern-Takt"));
        core.Stop();
    }

    [Fact]
    public void HaengendesPumpenWirdVerschachteltWeitergefuehrt()
    {
        core.Start("x", background: false);
        core.StuckAfter = TimeSpan.Zero; // jede Überschneidung gilt als „hängt in einem Dialog“
        // Dialog-Schleife in kc_pump: liefert drei Takte aus; die verschachtelte Ebene liefert selbst noch einen.
        bridge.OnPump = depth =>
        {
            if (depth == 1) { core.PumpTick(); core.PumpTick(); core.PumpTick(); }
            else core.PumpTick();
        };
        core.PumpTick();
        Assert.Equal(4, bridge.Pumps); // außen + 3 verschachtelt
        Assert.Equal(2, bridge.MaxDepth); // nie tiefer als eine Ebene
        Assert.Single(bridge.Traces, t => t.Contains("hängt"));
        var end = Assert.Single(bridge.Traces, t => t.Contains("wieder normal"));
        Assert.Contains("3× verschachtelt", end);
        Assert.Contains("3× übersprungen", end);
        // Nächster normaler Takt: keine neuen Zeilen.
        bridge.OnPump = null;
        core.PumpTick();
        Assert.Equal(2, bridge.Traces.Count);
        core.Stop();
    }

    [Fact]
    public void BefehlWaehrendHaengendemPumpenKommtDurch()
    {
        core.Start("x", background: false);
        core.StuckAfter = TimeSpan.Zero;
        // Klick im Dialog innerhalb von kc_pump: Send reiht ein, die Dialog-Schleife arbeitet den Auftrag ab.
        bridge.OnPump = depth => { if (depth == 1) { core.Send("power", ("on", true)); Drain(); } };
        core.PumpTick();
        Assert.Equal(2, bridge.Pumps);
        core.Stop();
    }
}
