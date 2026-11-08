import Foundation
import MideaKit

/// Ergebnis eines App-Timers – für den Timer-Chip, den Hinweis und die Mitteilung der Oberfläche.
public enum TimerOutcome: Equatable, Sendable {
    /// Befehl angenommen (`at` = Zeitpunkt der Ausführung).
    case executed(powerOn: Bool, due: Date, at: Date)
    /// Nie versucht: die App war geschlossen oder der Rechner schlief, als der Timer fällig war.
    case missed(powerOn: Bool, due: Date)
    /// Versucht, aber nicht angenommen (Anlage nicht erreichbar bzw. keine Anlage eingerichtet).
    case failed(powerOn: Bool, due: Date, reason: TimerFailure)

    public var powerOn: Bool {
        switch self {
        case let .executed(on, _, _), let .missed(on, _), let .failed(on, _, _): return on
        }
    }

    public var due: Date {
        switch self {
        case let .executed(_, d, _), let .missed(_, d), let .failed(_, d, _): return d
        }
    }

    public var succeeded: Bool { if case .executed = self { return true } else { return false } }

    /// Kurzer Titel für eine Mitteilung.
    public var title: String {
        switch self {
        case .executed: return powerOn ? L.Timer.Title.on : L.Timer.Title.off
        case .missed: return L.Timer.Title.missed
        case .failed: return L.Timer.Title.failed
        }
    }

    /// Meldung nach dem Muster „Was ist passiert. Was tun.“
    public var message: String {
        let name = powerOn ? L.Timer.nameOn : L.Timer.nameOff
        let time = ACController.clock(due)
        switch self {
        case let .executed(_, _, at):
            let done = ACController.clock(at)
            return powerOn ? L.Timer.executedOn(name: name, time: done) : L.Timer.executedOff(name: name, time: done)
        case .missed:
            return L.Timer.missed(name: name, time: time)
        case .failed(_, _, .noDevice):
            return L.Timer.failedNoDevice(name: name, time: time)
        case .failed(_, _, .unreachable):
            return L.Timer.failedUnreachable(name: name, time: time)
        }
    }
}

extension TimerOutcome {
    /// Text fürs Protokoll in der Sprache der Oberfläche, mit 24-Stunden-Uhrzeit.
    var logMessage: String {
        let name = Localizer.text(powerOn ? "timer.nameOn" : "timer.nameOff")
        let time = Fmt.clock(due, profile: .germany)
        switch self {
        case let .executed(_, _, at):
            return Localizer.text(powerOn ? "timer.executedOn" : "timer.executedOff",
                                  ["name": name, "time": Fmt.clock(at, profile: .germany)])
        case .missed:
            return Localizer.text("timer.missed", ["name": name, "time": time])
        case .failed(_, _, .noDevice):
            return Localizer.text("timer.failedNoDevice", ["name": name, "time": time])
        case .failed(_, _, .unreachable):
            return Localizer.text("timer.failedUnreachable", ["name": name, "time": time])
        }
    }
}

public enum TimerFailure: Equatable, Sendable {
    case noDevice
    case unreachable
}

/// Laufzeitdaten der Timer-Schleife (gespeichert in `ACController.timerRuntime`).
struct TimerRuntime {
    /// Timer (Schlüssel: Einschalt-Timer?), für die schon ein Befehl versucht wurde – unterscheidet „verpasst“
    /// (nie versucht) von „nicht erreichbar“ (versucht, nicht angenommen).
    var tried: Set<Bool> = []
    /// Ein Durchlauf schickt gerade Befehle.
    var firing = false
    /// Hook für die Oberfläche (Mitteilung). Wird auf dem MainActor nach jedem Ergebnis gerufen.
    var onResult: (@MainActor (TimerOutcome) -> Void)?
    /// Ergebnisse, die kamen, bevor die Oberfläche `onResult` gesetzt hat (verpasst beim Start).
    var undelivered: [TimerOutcome] = []
    /// Zuletzt hat der Nutzer (nicht der Timer) die Anlage ein- oder ausgeschaltet.
    var userPowerAt: Date?
}

/// App-Timer „aus in … Minuten“ und „ein um …“. Die PortaSplit nimmt Gerätetimer per LAN nicht an,
/// deshalb schaltet die App selbst. Ein Timer bleibt stehen, bis die Anlage den Befehl angenommen hat.
extension ACController {
    /// Länger als so überfällige Timer gelten als veraltet (App war geschlossen) und lösen nicht mehr aus.
    static let timerGrace: TimeInterval = 5 * 60

    /// Voraussetzung, die jede Oberfläche beim Timer nennt.
    public static var timerRequirement: String { L.Timer.requirement }

    /// Mitteilung der Oberfläche nach jedem Timer-Ergebnis (ausgeführt, verpasst, fehlgeschlagen).
    public var onTimerResult: (@MainActor (TimerOutcome) -> Void)? {
        get { timerRuntime.onResult }
        set {
            timerRuntime.onResult = newValue
            guard let newValue else { return }
            let pending = timerRuntime.undelivered
            timerRuntime.undelivered = []
            pending.forEach { newValue($0) }
        }
    }

    /// Ausschalt-Timer in `minutes` Minuten (1 min bis 24 h); nil löscht ihn. `now`: Zeitpunkt (Standard: Uhr des Kerns).
    public func setOffTimer(in minutes: Int?, now: Date? = nil) {
        let now = now ?? self.now()
        AppLog.write(minutes.map { L.Log.Timer.offIn(minutes: String($0)) } ?? L.Log.Timer.offDeleted)
        cancelTimerFire()
        offAt = minutes.map { now.addingTimeInterval(TimeInterval(min(24 * 60, max(1, $0)) * 60)) }
        timerRuntime.tried.remove(false)
        persistTimers()
    }

    /// Nur die Uhrzeit zählt: der Timer gilt für das nächste Vorkommen nach `now` (heute oder morgen). Ein Datum
    /// innerhalb der nächsten 24 h bleibt unverändert; ältere oder weiter entfernte Daten (z. B. aus einem Picker,
    /// der Tage alt ist) werden auf das nächste Vorkommen der Uhrzeit gelegt.
    public func setOnTimer(at date: Date?, now: Date? = nil) {
        let now = now ?? self.now()
        cancelTimerFire()
        onAt = date.map { Self.nextOccurrence(of: $0, after: now) }
        AppLog.write(onAt.map { L.Log.Timer.onAt(time: Self.logLabel($0, now: now)) } ?? L.Log.Timer.onDeleted)
        timerRuntime.tried.remove(true)
        persistTimers()
    }

    /// Einschalt-Timer für Stunde und Minute (nächstes Vorkommen).
    public func setOnTimer(hour: Int, minute: Int, now: Date? = nil) {
        let now = now ?? self.now()
        var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        c.hour = min(23, max(0, hour))
        c.minute = min(59, max(0, minute))
        c.second = 0
        setOnTimer(at: Calendar.current.date(from: c) ?? now, now: now)
    }

    /// Nächstes Vorkommen der Uhrzeit (Stunde:Minute) von `date` nach `now`.
    static func nextOccurrence(of date: Date, after now: Date) -> Date {
        if date > now, date.timeIntervalSince(now) <= 86400 { return date }
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: date)
        return cal.nextDate(after: now, matching: DateComponents(hour: c.hour, minute: c.minute, second: 0),
                            matchingPolicy: .nextTime, direction: .forward)
            ?? now.addingTimeInterval(86400)
    }

    /// „heute 07:00“, „morgen 07:00“ bzw. „Mi 07:00“ – der Tag ist immer sichtbar.
    public static func timerLabel(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDate(date, inSameDayAs: now) {
            day = DateWords.today
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            day = DateWords.tomorrow
        } else {
            day = DateWords.weekdayShort(cal.component(.weekday, from: date))
        }
        return day + " " + clock(date)
    }

    /// Wie `timerLabel`, aber mit 24-Stunden-Uhrzeit fürs Protokoll.
    static func logLabel(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDate(date, inSameDayAs: now) {
            day = Localizer.text("date.today")
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            day = Localizer.text("date.tomorrow")
        } else {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            day = Localizer.text("date.weekdayShort." + names[cal.component(.weekday, from: date) - 1])
        }
        return day + " " + Fmt.clock(date, profile: .germany)
    }

    /// Anzeigetexte der gesetzten Timer („heute 07:00“); nil = kein Timer.
    public var onTimerLabel: String? { onAt.map { Self.timerLabel($0, now: now()) } }
    public var offTimerLabel: String? { offAt.map { Self.timerLabel($0, now: now()) } }

    nonisolated static func clock(_ date: Date) -> String { Fmt.clock(date) }

    /// Zahl mit führenden Nullen (ohne C-Format, das unter Windows anders breit sein kann).
    nonisolated static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// Gespeicherte Timer laden; veraltete (App war geschlossen) nicht mehr schalten, aber als „verpasst“ melden.
    func loadTimers(now: Date? = nil) {
        let now = now ?? self.now()
        func load(_ key: String, powerOn: Bool) -> Date? {
            guard let raw = settings.object(forKey: key) as? Double, raw.isFinite else { return nil }
            let t = Date(timeIntervalSince1970: raw)
            guard now.timeIntervalSince(t) <= Self.timerGrace else {
                AppLog.write(L.Log.Timer.missed(name: powerOn ? L.Log.Timer.nameOn : L.Log.Timer.nameOff, time: Self.logLabel(t, now: now)))
                settings.removeObject(forKey: key)
                report(.missed(powerOn: powerOn, due: t))
                return nil
            }
            return t
        }
        offAt = load(SettingsKey.timerOffAt, powerOn: false)
        onAt = load(SettingsKey.timerOnAt, powerOn: true)
        platform.keepAwake(offAt != nil || onAt != nil)
    }

    func persistTimers() {
        for (key, date) in [(SettingsKey.timerOffAt, offAt), (SettingsKey.timerOnAt, onAt)] {
            if let date { settings.set(date.timeIntervalSince1970, forKey: key) } else { settings.removeObject(forKey: key) }
        }
        // Solange ein Timer läuft, darf der Rechner nicht von selbst einschlafen (sonst käme der Befehl zu spät).
        platform.keepAwake(offAt != nil || onAt != nil)
        scheduleTimerLoop()
    }

    /// Abstand der Wiederholungen, solange ein fälliger Timer noch nicht angenommen wurde.
    static let timerRetry: TimeInterval = 10
    /// Längster Schlaf bis zur nächsten Prüfung (falls die Uhr verstellt wird, stimmt die Fälligkeit trotzdem).
    static let timerMaxSleep: TimeInterval = 300

    /// Schaltet die Timer-Schleife ein (nur die laufende App; Tests prüfen `checkTimers` direkt).
    func startTimerLoop() {
        timerLoopEnabled = true
        scheduleTimerLoop()
    }

    /// Plant die Timer-Schleife neu: ohne gesetzten Timer läuft keine; sonst schläft sie bis zur Fälligkeit
    /// (höchstens `timerMaxSleep`) und wiederholt einen fälligen, noch nicht angenommenen Timer alle `timerRetry`.
    func scheduleTimerLoop() {
        timerTask?.cancel()
        timerTask = nil
        guard timerLoopEnabled, offAt != nil || onAt != nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                // Den Controller nur für die Prüfung festhalten, nicht über den Schlaf: so kann er freigegeben werden.
                guard let wait = self?.timerLoopStep() else { return }
                try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(min(2, wait * 0.1)))
            }
        }
    }

    /// Eine Runde der Timer-Schleife: fällige Timer ausführen; liefert die Sekunden bis zur nächsten Prüfung.
    func timerLoopStep() -> TimeInterval? {
        checkTimers()
        return nextTimerWait()
    }

    /// Sekunden bis zur nächsten Prüfung; `nil`, wenn kein Timer gesetzt ist.
    func nextTimerWait(now: Date? = nil) -> TimeInterval? {
        let now = now ?? self.now()
        guard let next = [offAt, onAt].compactMap({ $0 }).min() else { return nil }
        let d = next.timeIntervalSince(now)
        return d <= 0 ? Self.timerRetry : min(d, Self.timerMaxSleep)
    }

    /// Fällige Timer ausführen – jeden für sich, in der Reihenfolge ihrer Fälligkeit (ein scheiternder Aus-Timer hält
    /// den Ein-Timer nicht auf). Scheitert ein Befehl, bleibt der Timer stehen und wird alle `timerRetry` erneut
    /// versucht (ohne vorab angezeigten Zustand, damit die Anzeige nicht flackert), bis er länger als `timerGrace`
    /// überfällig ist. Nie versucht und schon zu alt = „verpasst“; versucht und zu alt = „nicht erreichbar“.
    func checkTimers(now: Date? = nil) {
        let now = now ?? self.now()
        guard !timerRuntime.firing else { return }
        let due = [(false, offAt), (true, onAt)]
            .compactMap { on, at in at.flatMap { $0 <= now ? (on, $0) : nil } }
            .sorted { $0.1 < $1.1 }
        var run: [(powerOn: Bool, at: Date)] = []
        for (powerOn, at) in due {
            let overdue = now.timeIntervalSince(at) > Self.timerGrace
            if config == nil {
                finish(.failed(powerOn: powerOn, due: at, reason: .noDevice))
            } else if overdue {
                finish(timerRuntime.tried.contains(powerOn)
                       ? .failed(powerOn: powerOn, due: at, reason: .unreachable) : .missed(powerOn: powerOn, due: at))
            } else if device == nil {
                // Eingerichtet, aber gerade nicht nutzbar: weiter versuchen, bis die Frist abläuft.
                timerRuntime.tried.insert(powerOn)
            } else {
                run.append((powerOn, at))
            }
        }
        guard !run.isEmpty else { return }
        timerRuntime.firing = true
        timerFireTask = Task { [weak self] in await self?.fire(run) }
    }

    /// Befehle der fälligen Timer nacheinander schicken. Abgebrochen (Timer neu gesetzt oder gelöscht, `stop()`) geht
    /// kein weiterer Befehl mehr hinaus; ein noch fälliger Timer kommt dann gleich in der nächsten Runde dran.
    private func fire(_ run: [(powerOn: Bool, at: Date)]) async {
        defer {
            timerRuntime.firing = false
            timerFireTask = nil
            if Task.isCancelled { scheduleTimerLoop() }
        }
        for (powerOn, at) in run {
            guard !Task.isCancelled else { return }
            guard let device else { timerRuntime.tried.insert(powerOn); continue }
            let first = !timerRuntime.tried.contains(powerOn)
            if !first {
                // Nach dem ersten Versuch von Hand geschaltet: der Nutzer hat entschieden, nicht zurückschalten.
                if let user = timerRuntime.userPowerAt, user >= at {
                    drop(powerOn: powerOn, because: L.Log.Timer.switchedByHand)
                    continue
                }
                // Der erste Versuch kam an, nur die Antwort fehlte: nicht noch einmal senden.
                if state?.power == powerOn, let updated = lastUpdate, updated >= at {
                    finish(.executed(powerOn: powerOn, due: at, at: updated))
                    continue
                }
            }
            timerRuntime.tried.insert(powerOn)
            AppLog.write(L.Log.Timer.firing(action: powerOn ? L.Log.Timer.actionOn : L.Log.Timer.actionOff, suffix: first ? "" : L.Log.Timer.repeat))
            // Eigene Aufgabe, damit ein Abbruch den Befehl nicht mitten im Senden trifft (ob er ankam, wäre sonst offen).
            let ok = await Task {
                if first { return await send({ $0.power = powerOn }, byTimer: true) }
                return await perform(staleAware: true, { try await device.update { $0.power = powerOn } }).succeeded
            }.value
            // Inzwischen vom Nutzer geändert oder gelöscht? Dann nicht mehr melden.
            guard (powerOn ? onAt : offAt) == at else { continue }
            if ok { finish(.executed(powerOn: powerOn, due: at, at: now())) }
        }
    }

    /// Laufende Timer-Befehle abbrechen (vor dem Neusetzen oder Löschen eines Timers).
    func cancelTimerFire() {
        timerFireTask?.cancel()
    }

    /// Timer ohne Ergebnis-Meldung beenden (der Nutzer hat inzwischen selbst geschaltet).
    private func drop(powerOn: Bool, because reason: String) {
        if powerOn { onAt = nil } else { offAt = nil }
        timerRuntime.tried.remove(powerOn)
        persistTimers()
        AppLog.write(L.Log.Timer.ended(name: powerOn ? L.Log.Timer.nameOn : L.Log.Timer.nameOff, reason: reason))
    }

    /// Timer abschließen: löschen, Ergebnis merken, Hinweis und Mitteilung.
    private func finish(_ outcome: TimerOutcome) {
        if outcome.powerOn { onAt = nil } else { offAt = nil }
        timerRuntime.tried.remove(outcome.powerOn)
        persistTimers()
        if outcome.succeeded { AppLog.write(outcome.logMessage) } else { AppLog.error(outcome.logMessage) }
        report(outcome)
    }

    private func report(_ outcome: TimerOutcome) {
        lastTimerResult = outcome
        showNotice(outcome.message)
        if let hook = timerRuntime.onResult { hook(outcome) } else { timerRuntime.undelivered.append(outcome) }
    }
}
