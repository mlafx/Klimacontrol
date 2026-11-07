import Foundation
import MideaKit

/// Abfrage im eingestellten Takt: Zustand, Diagnose (bei sichtbarer Diagnose jedes Mal, sonst höchstens alle 30 s)
/// und unter 5 s der Schnellmodus.
extension ACController {
    /// Schnellmodus: 0 = Eigenschaften + Verbrauch, sonst Diagnosegruppe.
    static let fastCycle: [UInt8] = [0, 1, 2, 3, 5, 7]
    /// So alt darf die Diagnose für den Verlauf höchstens werden, ohne dass die Diagnose-Spalte offen ist.
    static let diagnosticsInterval: TimeInterval = 30

    func restartPolling() {
        pollTask?.cancel()
        guard device != nil, !stopped else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Den Controller nur für eine Runde festhalten, nicht über die Pause: so kann er freigegeben werden.
                guard let pause = await self?.pollRound() else { return }
                try? await Task.sleep(for: pause.duration, tolerance: pause.tolerance)
            }
        }
    }

    /// Eine Runde der Abfrageschleife; liefert die Pause bis zur nächsten.
    func pollRound() async -> (duration: Duration, tolerance: Duration?) {
        let clock = ContinuousClock()
        let started = clock.now
        await refresh()
        // Takt nach Startzeit: die Dauer des Abrufs zählt mit, damit „1 s“ wirklich jede Sekunde heißt.
        let secs = max(0.05, Double(effectiveRefreshSeconds) - started.duration(to: clock.now) / .seconds(1))
        nextRefresh = now().addingTimeInterval(secs)
        // Ab 5-s-Takt darf das System den Wecker etwas verschieben (bis 10 %, höchstens 2 s) und mit anderen
        // Weckvorgängen bündeln; schnelle Takte bleiben exakt.
        let tolerance: Duration? = effectiveRefreshSeconds >= 5 ? .seconds(min(2, secs * 0.1)) : nil
        return (.seconds(secs), tolerance)
    }

    /// „Jetzt aktualisieren“ (⌘R, „Erneut versuchen“, Windows-Befehl `refresh`): hebt die Sperren der Wegwahl auf und
    /// fragt sofort ab – läuft gerade ein Befehl, gleich danach. Die Abfrageschleife ruft `refresh()`.
    public func refreshNow() async {
        device?.resetBackoff()
        if connectSlow { connectSlow = false; scheduleConnectSlow() }
        await refresh()
    }

    public func refresh() async {
        await refreshOnce()
    }

    /// Eine Abfrage; true, wenn sie wirklich lief (nicht verschoben, nicht verworfen).
    @discardableResult
    func refreshOnce() async -> Bool {
        guard let device else { return false }
        guard inFlight == 0, probing == 0 else {
            refreshPending = true
            return false
        }
        if effectiveRefreshSeconds < 5 {
            return await refreshFast(device)
        }
        AppLog.debug("Abfrage gestartet")
        guard await perform(staleAware: true, { try await device.refresh() }).succeeded else { return false }
        if let s = state { AppLog.debug("Zustand: " + Fmt.stateLine(s)) }
        rememberDayStart()
        guard diagnosticsDue else { return true }
        // Zweiter Innenfühler (Zusatzabfrage) nur, wenn jemand die Diagnose sieht – der Verlauf braucht ihn nicht.
        if var d = try? await device.diagnostics(full: diagnosticsVisible), self.device === device {
            d.dropStandbyPlaceholders(power: state?.power ?? true)
            diagnostics = d
            lastDiagnostics = now() // erst nach dem Lesen: sonst galt eine alte Diagnose als frisch
            AppLog.debug("Diagnose: " + Fmt.diagnosticsLine(d))
        }
        return true
    }

    /// Diagnose lesen: bei sichtbarer Diagnose jedes Mal, sonst höchstens alle `diagnosticsInterval` (für den Verlauf).
    var diagnosticsDue: Bool {
        diagnosticsVisible || now().timeIntervalSince(lastDiagnostics) >= Self.diagnosticsInterval
    }

    /// Schnellmodus (< 5 s): je Runde Zustand + genau ein weiterer Block im Wechsel, damit eine Runde < 1 s bleibt.
    func refreshFast(_ device: any ACDevice) async -> Bool {
        let block = Self.fastCycle[fastStep % Self.fastCycle.count]
        fastStep += 1
        AppLog.debug("Schnellabruf (Block \(block == 0 ? "Eigenschaften+Verbrauch" : "Gruppe \(block)"))")
        guard await perform(staleAware: true, { try await device.refreshFast(extras: block == 0) }).succeeded else {
            return false
        }
        rememberDayStart()
        guard block != 0, diagnosticsDue,
              let raw = try? await device.rawGroups([block]), let f = raw[block], self.device === device else { return true }
        var d = diagnostics ?? Diagnostics()
        d.apply(group: block, payload: Array(f.dropFirst(10).dropLast(2)))
        d.dropStandbyPlaceholders(power: state?.power ?? true)
        diagnostics = d
        if block == 7 { lastDiagnostics = now() }
        return true
    }
}
