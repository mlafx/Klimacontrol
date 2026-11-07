import Foundation
import MideaKit

/// Verbrauch heute laut Zähler der Anlage, mit Angabe, ab wann gezählt wird.
public struct TodayEnergy: Equatable, Sendable {
    /// Verbrauch seit `since` (bzw. seit Mitternacht) in kWh.
    public var kWh: Double
    /// Ab hier wird gezählt; nil = unbekannt (altes Speicherformat).
    public var since: Date?
    /// Der Zählerstand von Mitternacht ist bekannt (sonst fehlt der Verbrauch davor).
    public var fromMidnight: Bool
    /// Passt der Zähler grob (±50 %) zur Summe der gemessenen Leistung? nil = nicht prüfbar (zu wenig Messwerte).
    public var plausible: Bool?

    /// „seit 08:14“, wenn nicht ab Mitternacht gezählt wird; sonst nil.
    public var sinceLabel: String? {
        guard !fromMidnight else { return nil }
        return since.map { L.Cost.since(time: ACController.clock($0)) }
    }
}

/// Verbrauch und Kosten aus dem Gesamtzähler der Anlage.
extension ACController {
    /// Gespeicherter Tagesbeginn: „JJJJ-MM-TT;kWh;Anlagen-ID;Unix-Sekunden;1|0 (ab Mitternacht)“.
    /// Altes Format: nur „JJJJ-MM-TT;kWh“ (Anlage und Zeit unbekannt).
    struct DayStart: Equatable {
        var day: String
        var kWh: Double
        var device: UInt64?
        var since: Date?
        var fromMidnight: Bool
        /// Mit binärer Zählerlesart geschrieben (5 Felder); Einträge aus der BCD-Lesart passen nicht und werden ignoriert.
        var binary = true

        init(day: String, kWh: Double, device: UInt64?, since: Date?, fromMidnight: Bool) {
            self.day = day
            self.kWh = kWh
            self.device = device
            self.since = since
            self.fromMidnight = fromMidnight
        }

        init?(_ raw: String) {
            let p = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 2, let k = Double(p[1]), k.isFinite else { return nil }
            day = p[0]
            kWh = k
            device = p.count > 2 ? UInt64(p[2]) : nil
            since = p.count > 3 ? Double(p[3]).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } : nil
            fromMidnight = p.count > 4 && p[4] == "1"
            binary = p.count >= 5
        }

        var raw: String {
            [day, "\(kWh)", device.map(String.init) ?? "", since.map { String(Int($0.timeIntervalSince1970)) } ?? "",
             fromMidnight ? "1" : "0"].joined(separator: ";")
        }
    }

    /// Mehr kann die Anlage nicht aufnehmen (großzügig; die PortaSplit liegt bei gut 1 kW). Ein größerer Zuwachs
    /// des Zählers ist ein Lesefehler.
    nonisolated static let maxPlausibleKW = 2.5
    /// Kleine Rücksprünge (bis 2 Zählschritte à 0,01 kWh) sind Rundung, kein neuer Zähler.
    nonisolated static let counterJitterKWh = 0.02

    /// Gespeicherter Tagesbeginn, wenn er zu heute, zu dieser Anlage und zur binären Lesart gehört.
    private func currentDayStart(day: String) -> DayStart? {
        guard let s = storedDayStart(), s.binary, s.day == day, s.device == nil || s.device == config?.deviceId else {
            return nil
        }
        return s
    }

    /// Kosten pro Stunde bei aktueller Leistungsaufnahme.
    public var costPerHour: Double? {
        state?.powerWatts.map { $0 / 1000 * pricePerKWh }
    }

    /// Verbrauch heute laut Zähler; nil, wenn unbekannt oder unplausibel (dann sagt `todayEnergy` mehr).
    public var todayKWh: Double? {
        guard let e = todayEnergy, e.plausible != false else { return nil }
        return e.kWh
    }

    /// Verbrauch heute mit Herkunft („seit HH:MM“, Plausibilität). nil = kein Zählerstand.
    public var todayEnergy: TodayEnergy? { todayEnergy(now: now()) }

    func todayEnergy(now: Date) -> TodayEnergy? {
        guard let total = state?.totalEnergyKWh, total.isFinite else { return nil }
        let day = Self.dayString(now)
        let start = currentDayStart(day: day) ?? DayStart(day: day, kWh: total, device: nil, since: now, fromMidnight: false)
        let delta = total - start.kWh
        let from = start.fromMidnight ? Calendar.current.startOfDay(for: now) : start.since
        // Rücksprung über die Rundung hinaus: Zähler passt nicht zum Tagesbeginn (wird bei der nächsten Abfrage neu
        // gesetzt) – nicht still 0 zeigen, sondern als unplausibel melden.
        guard delta >= -Self.counterJitterKWh else {
            return TodayEnergy(kWh: 0, since: from, fromMidnight: start.fromMidnight, plausible: false)
        }
        let kWh = max(0, delta)
        var plausible = from.flatMap { plausibility(counterKWh: kWh, since: $0, now: now) }
        if let from, kWh > Self.maxPlausibleKW * max(0, now.timeIntervalSince(from)) / 3600 + 0.05 { plausible = false }
        return TodayEnergy(kWh: kWh, since: from, fromMidnight: start.fromMidnight, plausible: plausible)
    }

    /// Zähler gegen die Summe der gemessenen Leistung (Verlauf) halten. Der Zähler zählt auch, wenn die App nicht
    /// misst – darum darf er nur dann deutlich darüber liegen, wenn der Verlauf Lücken hat.
    func plausibility(counterKWh: Double, since: Date, now: Date) -> Bool? {
        let st = history.cachedStats(since: since, now: now)
        guard let measured = st.kWh, measured >= 0.1 || counterKWh >= 0.3 else { return nil }
        let span = now.timeIntervalSince(since)
        let covered = span > 0 ? min(1, (st.coveredSeconds ?? 0) / span) : 0
        if counterKWh < measured * 0.5 { return false }
        guard covered >= 0.9 else { return nil }
        guard measured > 0.02 else { return counterKWh < 0.3 }
        return counterKWh <= measured * 1.5
    }

    /// Zählerstand zum Tagesbeginn (wie gespeichert); nil = für diesen Tag noch keiner.
    func dayStart(for date: Date) -> Double? {
        let day = Self.dayString(date)
        if let s = storedDayStart(), s.day == day { return s.kWh }
        // Altes Format (ein Schlüssel je Tag „dayStart-JJJJ-MM-TT“). Entfernen ab 2027-01-01.
        return settings.object(forKey: "dayStart-" + day) as? Double
    }

    func storedDayStart() -> DayStart? {
        (settings.object(forKey: SettingsKey.energyDayStart) as? String).flatMap(DayStart.init)
    }

    /// Nach jeder Abfrage: Tagesbeginn festhalten. Neuer Tag oder andere Anlage → neuer Beginn, möglichst der
    /// Zählerstand um Mitternacht aus dem Verlauf, sonst der jetzige Stand („seit HH:MM“). Springt der Zähler
    /// zurück (Gerätetausch, Zählerüberlauf), beginnt die Zählung neu statt still 0 zu zeigen.
    func rememberDayStart(now: Date? = nil) {
        let now = now ?? self.now()
        guard let total = state?.totalEnergyKWh, total.isFinite else { return }
        let day = Self.dayString(now)
        let id = config?.deviceId
        let stored = storedDayStart()
        if let s = currentDayStart(day: day) {
            guard total + Self.counterJitterKWh < s.kWh else { return }
            AppLog.write("Zählerstand zurückgesprungen (\(s.kWh) → \(total) kWh) – Tagesverbrauch zählt ab jetzt neu")
            saveDayStart(DayStart(day: day, kWh: total, device: id, since: now, fromMidnight: false))
            return
        }
        // Verlauf nur nutzen, wenn er sicher zu dieser Anlage gehört (gleiche Anlage wie gestern oder erste Zählung).
        let sameDevice = stored == nil || stored?.device == nil || stored?.device == id
        let fromHistory = sameDevice ? history.counterAtDayStart(now: now, notAbove: total) : nil
        if let h = fromHistory {
            saveDayStart(DayStart(day: day, kWh: h.kWh, device: id, since: h.since, fromMidnight: h.fromMidnight))
        } else {
            saveDayStart(DayStart(day: day, kWh: total, device: id, since: now, fromMidnight: false))
        }
    }

    private func saveDayStart(_ s: DayStart) {
        settings.set(s.raw, forKey: SettingsKey.energyDayStart)
    }

    /// Tagesbeginn vergessen (beim Zurücksetzen der Einrichtung). Übrig bleibt nur ein Merker mit der Anlagen-ID der
    /// bisherigen Anlage: Der Verlauf kennt keine Anlagen-ID, also darf eine andere Anlage am selben Tag ihren
    /// Tagesbeginn nicht aus dem Verlauf der alten nehmen.
    public func forgetEnergyDayStart() {
        if let id = config?.deviceId, id != 0 {
            saveDayStart(DayStart(day: "", kWh: 0, device: id, since: nil, fromMidnight: false))
        } else {
            settings.removeObject(forKey: SettingsKey.energyDayStart)
        }
    }

    nonisolated static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return pad(c.year ?? 0, 4) + "-" + pad(c.month ?? 0, 2) + "-" + pad(c.day ?? 0, 2)
    }
}
