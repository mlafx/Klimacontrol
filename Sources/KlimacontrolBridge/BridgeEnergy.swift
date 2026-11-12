import Foundation
import KlimacontrolCore

// Verbrauch je Tag, Woche oder Monat (kc_energy_json); Texte und Zahlen kommen fertig aus dem Kern.

struct EnergyPeriodDTO: Encodable {
    /// Unix-Sekunden (Ortszeit-Grenzen); `end` des laufenden Zeitraums liegt in der Zukunft.
    var start, end: Double
    var kWh, measuredKWh: Double?
    var complete, current: Bool
    var label, name, tooltip, costText: String
    /// Wert über dem Balken („4,2“); fehlt ohne Wert oder bei mehr als `UIOptions.energyValuesMaxBars` Zeiträumen.
    var valueText: String?
}

struct EnergyDTO: Encodable {
    var kind: String
    var periods: [EnergyPeriodDTO]
    var summary: String
    /// Durchschnitt der abgeschlossenen Zeiträume (gestrichelte Linie) und sein Text für die Legende.
    var average: Double?
    var averageText: String?
}

struct EnergyErrorDTO: Encodable {
    var error: String
}

/// Notfalltext, falls das Kodieren selbst scheitert (sprachunabhängig, nie angezeigt).
private let errorFallback = #"{"error":"error"}"#

/// Anzahl der Zeiträume, die ein Aufruf höchstens liefert.
let energyMaxCount = 60

@MainActor func energyJSON(_ c: ACController, kind: String?, count: Int) -> String {
    guard let kind = kind.flatMap(EnergyPeriodKind.init(rawValue:)) else {
        let names = EnergyPeriodKind.allCases.map(\.rawValue).joined(separator: ", ")
        return encode(EnergyErrorDTO(error: L.Bridge.energyKindUnknown(kinds: names)), fallback: errorFallback)
    }
    guard (1...energyMaxCount).contains(count) else {
        return encode(EnergyErrorDTO(error: L.Bridge.energyCountInvalid(max: "\(energyMaxCount)")), fallback: errorFallback)
    }
    let price = c.pricePerKWh, currency = c.currency
    let periods = c.history.energyPeriods(kind, count: count)
    let dto = EnergyDTO(
        kind: kind.rawValue,
        periods: periods.map {
            EnergyPeriodDTO(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970, kWh: $0.kWh,
                            measuredKWh: $0.measuredKWh, complete: $0.complete, current: $0.current,
                            label: UIText.energyPeriodLabel($0, kind: kind), name: UIText.energyPeriodName($0, kind: kind),
                            tooltip: UIText.energyTooltip($0, kind: kind, price: price, currency: currency),
                            costText: UIText.energyCost($0, price: price, currency: currency),
                            valueText: UIText.energyBarValue($0, barCount: periods.count))
        },
        summary: UIText.energySummary(periods, price: price, currency: currency),
        average: UIText.energyAverage(periods),
        averageText: UIText.energyAverageText(periods))
    return encode(dto, fallback: errorFallback)
}
