import Foundation
import MideaKit

/// Schlüssel gesammelter Befehle (`ACController.debounced`): je Art wird nur der letzte Wert gesendet.
public enum DebounceKey: Hashable, Sendable {
    case temperature
    case fan
}

/// Ergebnis eines Gerätebefehls (`ACController.perform`).
enum CommandOutcome {
    /// Übernommen bzw. Abfrage gelungen.
    case applied
    /// Die Anlage hat den Befehl nicht übernommen; `actual` ist ihr echter Stand.
    case notApplied(actual: ACState)
    /// Der Befehl ging hinaus, dann brach die Verbindung ab: ob er ankam, ist offen.
    case unclear(any Error)
    /// Gescheitert (Verbindung, Anmeldung, unlesbare Antwort …).
    case failed(any Error)
    /// Ergebnis verworfen (Gerät gewechselt, neuerer Befehl, gesammelter Befehl steht aus) – kein Erfolg, aber auch
    /// kein Fehler, der angezeigt wird.
    case superseded

    init(failure: any Error) {
        switch failure {
        case MideaError.commandNotApplied(let actual): self = .notApplied(actual: actual)
        case MideaError.outcomeUnknown: self = .unclear(failure)
        default: self = .failed(failure)
        }
    }

    var succeeded: Bool { if case .applied = self { return true } else { return false } }

    /// Der Fehler für Meldungen; nil bei Erfolg oder verworfenem Ergebnis.
    var error: (any Error)? {
        switch self {
        case .applied, .superseded: return nil
        case .notApplied(let actual): return MideaError.commandNotApplied(actual)
        case .unclear(let e), .failed(let e): return e
        }
    }
}

/// Stellbefehle: sofort anzeigen, an die Anlage schicken, Ergebnis übernehmen oder zurücksetzen.
extension ACController {
    /// Ein Stellbefehl läuft (Abfragen zählen nicht mit – sonst wechselte `busy` bei jeder Abfrage).
    public var busy: Bool { commandsInFlight > 0 }

    /// Führt einen Gerätebefehl aus und übernimmt den Zustand. Verbindungsfehler landen in `message`
    /// (+ `lastRefreshFailed`), alle anderen als Hinweis in `notice`; beides im Protokoll.
    /// `staleAware` (Abfrage): Ergebnis verwerfen, wenn inzwischen ein Stellbefehl kam oder ein gesammelter Befehl
    /// aussteht – sonst flackerte der gerade angezeigte neue Wert kurz auf den alten zurück. Ein Stellbefehl
    /// (nicht `staleAware`) räumt den vorigen Hinweis weg; sein Zustand gilt nur, solange kein neuerer Befehl kam.
    @discardableResult
    func perform(staleAware: Bool = false, _ op: @escaping () async throws -> ACState) async -> CommandOutcome {
        let startGeneration = generation
        let startConfig = configGeneration
        let startDevice = device
        if !staleAware { clearNotice() }
        if staleAware, state == nil || lastRefreshFailed { beginConnectPhase() }
        inFlight += 1
        if !staleAware { commandsInFlight += 1 }
        defer {
            inFlight -= 1
            if !staleAware { commandsInFlight -= 1 }
            if inFlight == 0 { runPendingRefresh() }
        }
        do {
            let result = try await op()
            // Gerät inzwischen gewechselt oder vergessen: nichts übernehmen, keine Verlaufszeile der alten Anlage.
            guard configGeneration == startConfig, device === startDevice else { return .superseded }
            if staleAware, generation != startGeneration || !debounce.isEmpty { return .superseded }
            endConnectPhase()
            if lastRefreshFailed { AppLog.write(L.Log.Commands.restored) }
            clearConnectionError()
            lastUpdate = now()
            lastKnown = nil
            let path = device?.connectionPath
            if connectionPath != path { connectionPath = path }
            noteLANResult()
            // Ein älterer Befehl überschreibt die Anzeige eines neueren nicht (die nächste Abfrage zeigt den Stand).
            guard staleAware || generation == startGeneration else { return .applied }
            if state != result { state = result }
            // Diagnose der letzten Runde mitschreiben, wenn sie frisch ist (sie wird höchstens alle 30 s gelesen).
            history.add(result, diagnostics: now().timeIntervalSince(lastDiagnostics) < 45 ? diagnostics : nil)
            return .applied
        } catch {
            guard configGeneration == startConfig, device === startDevice else { return .superseded }
            endConnectPhase()
            let outcome = CommandOutcome(failure: error)
            // Nicht übernommen: Die Anlage meldet ihren echten Stand mit – den zeigen statt des vorab gezeigten Werts.
            if !staleAware, generation == startGeneration, case .notApplied(let actual) = outcome, state != actual {
                state = actual
            }
            let text = error.localizedDescription
            if Self.isConnectionError(error) {
                if !lastRefreshFailed || messageDetail?.detail != text { AppLog.error(text) }
                showConnectionError(UserMessage.from(error), deviceOff: UserMessage.isDeviceOff(error))
                noteLANResult(failed: true)
            } else {
                AppLog.error(text)
                showNotice(UserMessage.from(error))
            }
            return outcome
        }
    }

    /// Eine verschobene Abfrage nachholen, sobald kein Befehl und keine Prüfverbindung mehr läuft.
    func runPendingRefresh() {
        guard refreshPending, inFlight == 0, probing == 0, !stopped else { return }
        refreshPending = false
        Task { await refreshOnce() }
    }

    /// Ändert den Zustand: sofort anzeigen, dann an die Anlage schicken.
    public func update(_ change: @escaping @Sendable (inout ACState) -> Void) {
        Task { await send(change) }
    }

    /// Wie `update`, wartet aber auf die Anlage. Klappt es nicht, zurück auf den Ausgangsstand und frisch lesen –
    /// eine andere App kann die Anlage inzwischen umgestellt haben. Erfolg → true.
    /// `origin`: Ausgangsstand eines gesammelten Befehls (die Änderung steht dann schon im Zustand).
    /// `byTimer`: der Befehl kommt vom App-Timer (zählt nicht als Schalten von Hand).
    @discardableResult
    func send(_ change: @escaping @Sendable (inout ACState) -> Void, origin: ACState? = nil,
              byTimer: Bool = false) async -> Bool {
        guard let device else { return false }
        generation += 1
        let myGeneration = generation
        let old = origin ?? state
        if var s = state {
            if origin == nil { change(&s) }
            if let old {
                let diff = Fmt.change(from: old, to: s)
                if !diff.isEmpty { AppLog.write(L.Log.Commands.change(change: diff)) }
                if !byTimer, old.power != s.power { timerRuntime.userPowerAt = now() }
            }
            state = s
        }
        let outcome = await perform { try await device.update(change) }
        switch outcome {
        case .applied: return true
        case .superseded: return false
        case .notApplied: AppLog.error(L.Log.Commands.notApplied)
        case .unclear, .failed: break
        }
        // Inzwischen kam ein neuerer Befehl: dessen Anzeige nicht auf den alten Stand zurücksetzen.
        guard generation == myGeneration else { return false }
        // „Nicht übernommen“ bringt den echten Stand schon mit (`perform`); sonst zurück auf den Ausgangsstand.
        if case .notApplied = outcome {} else if let old { state = old }
        // Die Abfrage danach klappte: der Fehler ist ein Hinweis zum Befehl, kein Verbindungszustand.
        if await refreshOnce(), !lastRefreshFailed, let error = outcome.error { showNotice(UserMessage.from(error)) }
        return false
    }

    /// Schnelle Folgeklicks (Temperatur, Lüfterregler) sammeln und nur den letzten Wert senden.
    public func debounced(_ key: DebounceKey, _ change: @escaping @Sendable (inout ACState) -> Void) {
        generation += 1
        if debounce[key] == nil, let s = state { debounceOrigin[key] = s }
        if var s = state { change(&s); state = s }
        debounce[key]?.cancel()
        debounce[key] = Task { [weak self, delay = debounceDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            debounce[key] = nil
            let origin = debounceOrigin.removeValue(forKey: key)
            await send(change, origin: origin)
        }
    }

    func cancelAllDebounce() {
        debounce.values.forEach { $0.cancel() }
        debounce = [:]
        debounceOrigin = [:]
    }

    /// Solltemperatur in ganzen Grad verstellen (16–30 °C).
    public func nudgeTemperature(by delta: Double) {
        guard let current = state?.targetTemperature else { return }
        setTemperature(current + delta)
    }

    public func setOutdoorSilent(_ on: Bool) {
        guard device != nil else { return }
        generation += 1
        Task { await sendOutdoorSilent(on) }
    }

    /// „Außengerät leise“ senden und abwarten; true = übernommen. Ob die Anlage es übernommen hat, sagt ihre Antwort
    /// (`commandNotApplied`), nicht der angezeigte Zustand – den kann ein neuerer Befehl schon überholt haben.
    @discardableResult
    func sendOutdoorSilent(_ on: Bool) async -> Bool {
        guard let device else { return false }
        generation += 1
        let outcome = await perform { try await device.setOutdoorSilent(on) }
        if case .notApplied = outcome {
            showNotice(L.Message.OutdoorSilent.notApplied)
        }
        return outcome.succeeded
    }

    public func setSelfClean(_ on: Bool) { command { try await $0.setSelfClean(on) } }
    public func setIECO(_ on: Bool) { command { try await $0.setIECO(on) } }
    public func toggleDisplay() { command { try await $0.toggleDisplay() } }

    /// Leistung begrenzen (die PortaSplit kennt 100, 75 und 50 %).
    public func setRate(_ percent: Int) {
        guard device != nil else { return }
        let percent = PortaSplitDevice.nearestRate(percent)
        AppLog.write(L.Log.Commands.rate(percent: String(percent)))
        let before = state?.ratePercent
        if var s = state { s.ratePercent = percent; state = s }
        command(revert: { $0.ratePercent = before }) { try await $0.setRate(percent) }
    }

    /// Signalton der Anlage; die Einstellung gilt erst, wenn die Anlage den Befehl angenommen hat. Scheitert er,
    /// bekommt auch das Gerät wieder den bisherigen Wert (es setzt das Piep-Bit schon vor dem Senden).
    public func setSound(_ on: Bool) {
        guard let device else { return }
        generation += 1
        Task {
            guard await perform({ try await device.setSound(on) }).succeeded else {
                if self.device === device { device.beep = storedBeep }
                return
            }
            storedBeep = on
            settings.set(on, forKey: SettingsKey.beep)
        }
    }

    /// Gerätebefehl ohne Verifikation im Kern. `revert`: nimmt einen vorab angezeigten Wert zurück, wenn der Befehl
    /// scheitert (bei „nicht übernommen“ zeigt `perform` ohnehin den echten Stand).
    func command(revert: (@Sendable (inout ACState) -> Void)? = nil, _ op: @escaping (any ACDevice) async throws -> ACState) {
        guard let device else { return }
        generation += 1
        let myGeneration = generation
        Task {
            let outcome = await perform { try await op(device) }
            guard let revert, generation == myGeneration else { return }
            switch outcome {
            case .unclear, .failed: if var s = state { revert(&s); state = s }
            case .applied, .notApplied, .superseded: return
            }
        }
    }
}
