import Foundation
import KlimacontrolCore
import Observation

/// Ein langlaufender Auftrag (Anmeldung, Einrichtung, Adresse neu suchen, Sicherung, Verlauf-Export): Zähler je
/// beendetem Lauf und letztes Ergebnis. Die Oberfläche wartet, bis `seq` steigt, und liest dann `result`.
/// Beobachtbar, damit `track()` die Werte wie die Kern-Eigenschaften erfasst.
@MainActor @Observable final class BridgeJob<Value> {
    private(set) var seq = 0
    private(set) var result: Value

    init(_ initial: Value) { result = initial }

    /// Ergebnis ohne neuen Zähler zurücksetzen (z. B. alte Fehlermeldung beim Start einer neuen Anmeldung).
    func reset(to value: Value) { result = value }

    func finish(_ value: Value) {
        result = value
        seq += 1
    }

    /// Startet `work` auf dem MainActor; das Ergebnis zählt erst, wenn `work` fertig ist.
    func run(_ work: @escaping @MainActor () async -> Value) {
        Task { finish(await work()) }
    }
}

/// Ergebnisse der Bridge-Befehle, die nicht im Kern stehen. `setup` teilen sich `setupConnect` und `manualConnect`.
@MainActor @Observable final class BridgeResults {
    let login = BridgeJob<String?>(nil)
    let setup = BridgeJob(false)
    /// true = Anlage gefunden und erreichbar; der Grund bei Misserfolg steht in `notice`.
    let relocate = BridgeJob(false)
    let importBackup = BridgeJob<ImportResultDTO?>(nil)
    /// Fehlertext oder nil.
    let exportHistory = BridgeJob<String?>(nil)
    /// Erfolgstext des letzten Exports (nil nach Fehler oder beim Start eines neuen).
    var exportHistoryText: String?
}

/// Ergebnis von `importBackup`. `error`/`errorCode` nur bei Misserfolg (errorCode: "otherDevice", "rejected", "file").
struct ImportResultDTO: Encodable, Equatable {
    var ok: Bool
    /// true = an der Anlage geprüft, false = Anlage nicht erreichbar (ungeprüft übernommen), nil = ohne WLAN-Zugang.
    var verified: Bool?
    var scenesImported, scenesSkipped: Int
    var error, errorCode: String?
    /// Fertiger Text für die Rückmeldung (Erfolg, „Anlage antwortet nicht“ oder Fehler), wie ihn der Mac zeigt.
    var text: String? = nil
    /// Rückfrage „Andere Anlage einrichten?“ bei `errorCode == "otherDevice"`.
    var prompt: PromptDTO? = nil
}
