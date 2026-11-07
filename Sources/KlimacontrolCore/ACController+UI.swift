import Foundation
import MideaKit

// Gemeinsame Oberflächen-Logik (Zieltext, Statuszeile, Lüfter-Zonen) – die Oberflächen zeigen nur an und rufen hier auf.

extension ACController {
    // MARK: Texte

    /// Ziel im Verhältnis zum Raum – das, was man eigentlich wissen will („Heizt · noch 1,2° bis zum Ziel“).
    /// Ohne Zustand leer.
    public var goalLine: String {
        guard let s = state else { return "" }
        if s.selfClean == true { return L.Goal.selfClean }
        if diagnostics?.defrost == true { return L.Goal.defrost }
        guard let room = s.indoorTemperature else { return s.mode.verb }
        let diff = s.targetTemperature - room
        switch s.mode {
        case .heat where diff > 0.4: return L.Goal.heatRemaining(diff: Fmt.num(diff, 1))
        case .cool where diff < -0.4: return L.Goal.coolRemaining(diff: Fmt.num(-diff, 1))
        case .heat, .cool: return L.Goal.reached(verb: s.mode.verb)
        // Lüften, Trocknen, Auto: Die Anlage regelt selbst bzw. hat kein Temperaturziel – „Ziel erreicht“ wäre falsch.
        case .fan, .dry, .auto: return L.Goal.room(verb: s.mode.verb, temp: Fmt.temp(room))
        }
    }

    /// Statuszeile fürs Menüleisten-Fenster: „Kühlt · Raum 24,5° · über WLAN“ bzw. „Aus · Raum 24,5°“. Ohne Zustand leer.
    public var statusLine: String {
        guard let s = state else { return "" }
        let room = L.Status.room(temp: Fmt.temp(s.indoorTemperature))
        let path = connectionPath.map { " · " + L.Status.viaPath(path: $0.title) } ?? ""
        return (s.power ? "\(s.mode.verb) · \(room)" : "\(L.Common.off) · \(room)") + path
    }

    // MARK: Anzeige-Zustand (beide Oberflächen)

    /// Verbindungszustand für die Anzeige. Ein neuer Versuch nach einem Fehler meldet `connectionState` als
    /// `.connecting`; die Anzeige bleibt dann beim letzten Ergebnis („Anlage aus“ bzw. „Keine Verbindung“), sonst
    /// wechselten Punkt, Text und Symbol bei jeder Abfrage hin und her.
    public var uiConnectionState: ConnectionState {
        let s = connectionState
        guard s == .connecting else { return s }
        if deviceOffNotice { return .deviceOff }
        if lastRefreshFailed { return .noConnection }
        return s
    }

    /// „Anlage aus laut Cloud“ – grau statt Fehler.
    public var uiDeviceOff: Bool { uiConnectionState == .deviceOff }

    /// Seit wann die gezeigten Werte nicht mehr live sind (nil = live).
    public var uiStaleSince: Date? {
        guard state != nil, lastRefreshFailed || deviceOffNotice else { return nil }
        return staleSince ?? now()
    }

    /// Die Anlage arbeitet gerade sichtbar: ein, aktuelle Werte und keine gemeldete Leistung von 0 W (dann steht sie
    /// am Ziel). Nur dann laufen lebendiger Hintergrund und Wetter-Effekte.
    public var isWorking: Bool {
        guard let s = state, s.power, uiStaleSince == nil else { return false }
        if let w = s.powerWatts, w <= 0 { return false }
        return true
    }

    /// Große Zahl im Mini-Fenster: Soll, außer ausgeschaltet, beim Lüften oder bei „Groß angezeigt: Raum“.
    public var miniValue: String {
        guard let s = state else { return "–" }
        if !s.power || s.mode == .fan || appearance.hero == .room { return Fmt.temp(s.indoorTemperature) }
        return Fmt.target(s.targetTemperature)
    }

    /// Zeile darunter: „Kühlen · Raum 24,5°“, „Lüften · Raum“, „Aus · Raum“ oder „Stand 14:32“ bei alten Werten.
    public var miniCaption: String {
        guard config != nil else { return L.Status.notConfigured }
        guard let s = state else { return L.Status.connecting }
        if let stale = uiStaleSince { return Fmt.stand(stale) }
        guard s.power else { return L.Status.miniOff }
        if s.mode == .fan || appearance.hero == .room { return L.Status.miniRoomOnly(mode: s.mode.title) }
        return L.Status.miniRoom(mode: s.mode.title, temp: Fmt.temp(s.indoorTemperature))
    }

    // MARK: Lüfter-Zonen

    /// „Außengerät leise“ und Turbo wirken nur beim Kühlen und Heizen.
    public var fanZonesAvailable: Bool {
        guard let m = state?.mode else { return false }
        return UIOptions.isAvailable(.outdoorSilent, in: m)
    }

    nonisolated static func inQuietZone(_ s: ACState) -> Bool { s.fanSpeed == 1 && s.outSilent == true }
    nonisolated static func inTurboZone(_ s: ACState) -> Bool { s.fanSpeed == 100 && s.turbo }

    /// Ziel des Lüfterreglers: Zone ganz links, Zone ganz rechts oder eine Stufe (1–100 %, Auto).
    public enum FanTarget: Equatable, Sendable {
        case quiet, turbo, speed(Int)
    }

    /// Was ein Ziel an der Anlage bedeutet, gemessen am Stand vor der Bedienung (`origin`).
    struct FanPlan: Equatable, Sendable {
        var fanSpeed: Int
        var turbo: Bool
        var ecoOff = false
        /// nil = „Außengerät leise“ nicht anfassen.
        var outSilent: Bool?

        /// Für die Anzeige: alles, auch „Außengerät leise“.
        func apply(to s: inout ACState) {
            applyFan(to: &s)
            if let outSilent { s.outSilent = outSilent }
        }

        /// Für den Lüfterbefehl an die Anlage: nur Stufe, Turbo, Eco („Außengerät leise“ ist eine eigene Eigenschaft).
        func applyFan(to s: inout ACState) {
            s.fanSpeed = fanSpeed
            s.turbo = turbo
            if ecoOff { s.eco = false }
        }

        /// Ändert den Lüfter-Befehl selbst etwas (Stufe, Turbo, Eco)?
        func changesState(_ o: ACState) -> Bool { fanSpeed != o.fanSpeed || turbo != o.turbo || (ecoOff && o.eco) }
        func changesSilent(_ o: ACState) -> Bool { outSilent.map { $0 != (o.outSilent == true) } ?? false }
        /// Wechselt eine Zone (Turbo oder „Außengerät leise“)? Dann gilt der Mindestabstand `zoneGap`.
        func changesZone(_ o: ACState) -> Bool { turbo != o.turbo || changesSilent(o) }
    }

    /// Plan für ein Ziel. Wer eine Zone verlässt, schaltet ihre Funktion ab – im selben Lüfterbefehl (Turbo) bzw.
    /// einmal („Außengerät leise“). Eine per Kachel gesetzte Funktion bleibt, solange der Lüfter nicht in ihrer Zone war.
    nonisolated static func fanPlan(_ target: FanTarget, origin o: ACState, zones: Bool) -> FanPlan? {
        switch target {
        case .quiet:
            guard zones else { return nil }
            return FanPlan(fanSpeed: 1, turbo: false, outSilent: true)
        case .turbo:
            guard zones else { return nil }
            return FanPlan(fanSpeed: 100, turbo: true, ecoOff: true, outSilent: o.outSilent == true ? false : nil)
        case .speed(let v):
            let leftTurbo = zones && inTurboZone(o)
            let leftQuiet = zones && inQuietZone(o)
            return FanPlan(fanSpeed: v, turbo: leftTurbo ? false : o.turbo, outSilent: leftQuiet ? false : nil)
        }
    }

    /// Ganz links: 1 % und „Außengerät leise“ an (Turbo dabei aus). `now`: sofort, sonst beim Ziehen sammeln.
    public func setFanQuiet(now: Bool = true) { setFanTarget(.quiet, now: now) }

    /// Ganz rechts: 100 % und Turbo an (Eco und „Außengerät leise“ aus).
    public func setFanTurbo(now: Bool = true) { setFanTarget(.turbo, now: now) }

    /// Lüfterstufe 1–100 % oder Auto. `now`: sofort senden, sonst Folgewerte sammeln.
    public func setFan(_ speed: Int, now: Bool) {
        guard (1...100).contains(speed) || speed == FanSpeed.auto.rawValue else { return }
        setFanTarget(.speed(speed), now: now)
    }

    /// Ein Weg für alle Lüfter-Bedienungen beider Oberflächen: Der neue Wert erscheint sofort; gesendet wird nur
    /// der letzte (nach `debounceDelay` Ruhe bzw. sofort), gemessen am Stand vor dem ersten noch nicht gesendeten Wert.
    /// Zonen-Wechsel halten `zoneGap` Abstand zum vorigen – sie werden verschoben, nie verschluckt.
    public func setFanTarget(_ target: FanTarget, now: Bool) {
        guard device != nil, let current = state else { return }
        let pending = debounce[.fan] != nil
        let origin = pending ? (debounceOrigin[.fan] ?? current) : current
        guard let plan = Self.fanPlan(target, origin: origin, zones: fanZonesAvailable) else { return }
        if !pending, !plan.changesState(origin), !plan.changesSilent(origin) { return }
        generation += 1
        debounceOrigin[.fan] = origin
        var shown = current
        plan.apply(to: &shown)
        if shown != current { state = shown }
        debounce[.fan]?.cancel()
        debounce[.fan] = Task { [weak self, delay = debounceDelay] in
            if !now { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            if plan.changesZone(origin) {
                let wait = zoneGap - self.now().timeIntervalSince(zoneSentAt)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                zoneSentAt = self.now()
            }
            debounce[.fan] = nil
            debounceOrigin[.fan] = nil
            await sendFanPlan(plan, origin: origin)
        }
    }

    /// Plan an die Anlage: „Außengerät leise“ aus vor dem Lüfterbefehl, an danach. Scheitert ein Teil an der
    /// Verbindung, unterbleibt der Rest; lehnt die Anlage nur „Außengerät leise“ ab, geht der Lüfterbefehl trotzdem.
    func sendFanPlan(_ plan: FanPlan, origin: ACState) async {
        let silentFirst = plan.outSilent == false && plan.changesSilent(origin)
        if silentFirst {
            guard await sendStep({ await self.sendOutdoorSilent(false) }) else { return }
            if var s = state { plan.apply(to: &s); state = s }
        }
        if plan.changesState(origin) {
            let p = plan
            guard await send({ p.applyFan(to: &$0) }, origin: origin) else { return }
        }
        if !silentFirst, plan.changesSilent(origin), let on = plan.outSilent {
            await sendOutdoorSilent(on)
        }
    }

    /// Einen Teilschritt senden; false nur, wenn die Verbindung fehlt (dann lohnt der nächste Schritt nicht).
    private func sendStep(_ step: () async -> Bool) async -> Bool {
        if await step() { return true }
        return !lastRefreshFailed
    }

    // MARK: Bedienregeln

    public func setPower(_ on: Bool) {
        update { $0.power = on }
    }

    /// Modus wählen: schaltet ein; Eco gibt es nur beim Kühlen, Turbo und „Außengerät leise“ nur beim Kühlen
    /// und Heizen – was im neuen Modus nicht geht, geht aus.
    public func setMode(_ mode: OperationalMode) {
        guard device != nil, let origin = state else { return }
        let coolOrHeat = UIOptions.isAvailable(.turbo, in: mode)
        let change: @Sendable (inout ACState) -> Void = { s in
            s.power = true
            s.mode = mode
            if !UIOptions.isAvailable(.eco, in: mode) { s.eco = false }
            if !coolOrHeat { s.turbo = false }
        }
        let dropSilent = !coolOrHeat && origin.outSilent == true
        generation += 1
        var shown = origin
        change(&shown)
        if dropSilent { shown.outSilent = false }
        state = shown
        // Nacheinander, nicht gleichzeitig: zwei Befehle direkt hintereinander übernimmt die Anlage nicht zuverlässig.
        Task {
            if dropSilent {
                guard await sendStep({ await self.sendOutdoorSilent(false) }) else { return }
                if var s = state { change(&s); state = s }
            }
            await send(change, origin: origin)
        }
    }

    /// Eco (nur beim Kühlen); schaltet Turbo ab.
    public func setEco(_ on: Bool) {
        if on, let m = state?.mode, !UIOptions.isAvailable(.eco, in: m) { return }
        if on, state == nil { return }
        update { s in
            s.eco = on
            if on { s.turbo = false }
        }
    }

    /// Turbo (nur beim Kühlen und Heizen); schaltet Eco ab.
    public func setTurbo(_ on: Bool) {
        if on, !fanZonesAvailable { return }
        update { s in
            s.turbo = on
            if on { s.eco = false }
        }
    }

    /// Solltemperatur in ganzen Grad (16–30 °C); schnelle Folgewerte werden gesammelt.
    public func setTemperature(_ celsius: Double) {
        guard celsius.isFinite else { return }
        let target = min(UIOptions.temperatureMax, max(UIOptions.temperatureMin, celsius.rounded()))
        debounced(.temperature) { $0.targetTemperature = target }
    }
}
