import Foundation
import MideaKit
import Observation
import KlimacontrolCore

// C-Schnittstelle für die Windows-Oberfläche (C#/WPF, windows/KlimacontrolTray). Nur Oberfläche drüben – die Logik
// steckt in ACController/SetupFlow/HistoryStore. Regeln für den Aufrufer:
// - Alle kc_*-Funktionen auf dem Hauptthread aufrufen (WPF-UI-Thread = Hauptthread des Prozesses).
// - kc_pump() regelmäßig aufrufen (alle ~30 ms): leert die Main-Queue, auf der der MainActor läuft.
// - Zurückgegebene Zeichenketten (UTF-8) mit kc_free freigeben.
// - Befehle als JSON {"cmd": "...", ...}. Passwörter darin werden nie protokolliert.
// - Beim Start kc_api_version() mit der eigenen Erwartung vergleichen (Stand von exe und DLL gleich?).
// - Fehlt ein Pflichtparameter oder ist er falsch, liefert kc_command eine Fehlermeldung statt eines Standardwerts.
// - kc_set_locale(json) vor kc_init: Sprache und Formate des Systems. kc_strings_json() liefert die Texte der aktiven Sprache.

/// Version der C-Schnittstelle. Erhöhen bei jeder Änderung an Funktionen, Befehlen oder Feldern des Schnappschusses,
/// auf die sich die Oberfläche verlässt. 1 = ohne kc_api_version, 2 = Pflichtparameter,
/// `apiVersion`/`jsonError` im Schnappschuss, `manual` nur im Weg „Zugangsdaten“ gefüllt, 3 = die Oberfläche ruft
/// `kc_set_locale` und `kc_strings_json` (Sprache und Texte aus dem Katalog); `language`/`currency` im Schnappschuss.
let bridgeAPIVersion: Int32 = 3

@MainActor var controller: ACController?

#if os(Windows)
/// `UserDefaults` von swift-corelibs-foundation schreibt nur bei `synchronize()` auf die Platte; ohne den Aufruf
/// gingen unter Windows alle Einstellungen des Kerns beim Beenden verloren.
private final class SyncedDefaults: SettingsStore {
    private let defaults = UserDefaults.standard
    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        _ = defaults.synchronize()
    }
    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
        _ = defaults.synchronize()
    }
}
#endif
@MainActor let results = BridgeResults()
/// Revisionszähler des Schnappschusses (kc_state_rev): steigt, sobald sich eine darin gelesene Eigenschaft ändert.
@MainActor var stateRev: Int64 = 0
@MainActor var tracking = false
/// Letzter gelungener Schnappschuss (JSON): Scheitert das Kodieren einmal, sieht die Oberfläche weiter den letzten
/// Stand statt „nicht eingerichtet“; der Fehler steht einmal im Protokoll (nicht viermal je Sekunde).
@MainActor private var lastGoodState: String?
@MainActor var jsonErrorLogged = false

private func cString(_ s: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(s.utf8CString)
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    p.initialize(from: bytes, count: bytes.count)
    return p
}

/// Feste Schlüsselreihenfolge: Foundation unter Windows ordnet die Schlüssel sonst je Aufruf anders (Hash) – die
/// Oberfläche sähe dann bei jeder Abfrage einen „neuen“ Zustand und zeichnete ständig neu.
@MainActor private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    return e
}()

/// Kodiert `value`; scheitert das, einmal protokollieren und `fallback` liefern (nie stilles "null").
@MainActor func encode(_ value: some Encodable, fallback: String) -> String {
    do {
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        jsonErrorLogged = false
        return text
    } catch {
        if !jsonErrorLogged {
            AppLog.error(L.Log.Bridge.encodeFailed(type: "\(type(of: value))", error: "\(error)"))
            jsonErrorLogged = true
        }
        return fallback
    }
}

/// Führt `body` auf dem MainActor aus (Aufrufer ist laut Vertrag der Hauptthread) und gibt das Ergebnis als
/// C-Zeichenkette zurück. Der Zeiger entsteht erst nach dem Isolationswechsel: über die Grenze geht nur der
/// (Sendable) `String`, nie ein `UnsafeMutablePointer` (Swift 6).
private func mainCString(_ body: @MainActor () -> String) -> UnsafeMutablePointer<CChar> {
    cString(MainActor.assumeIsolated(body))
}

@_cdecl("kc_free")
public func kc_free(_ p: UnsafeMutablePointer<CChar>?) {
    p?.deallocate()
}

/// Version der C-Schnittstelle (siehe `bridgeAPIVersion`). Die Oberfläche prüft sie beim Start; passt sie nicht,
/// stammen exe und DLL aus verschiedenen Ständen.
@_cdecl("kc_api_version")
public func kc_api_version() -> Int32 {
    bridgeAPIVersion
}

/// Startet den Kern (lädt die Einrichtung, beginnt die Abfrage). Mehrfacher Aufruf ist harmlos.
@_cdecl("kc_init")
public func kc_init(_ version: UnsafePointer<CChar>?) {
    let appVersion = version.map { String(cString: $0) } ?? "?"
    MainActor.assumeIsolated {
        guard controller == nil else { return }
        #if os(Windows)
        WindowsSettingsCheck.runOnce()
        applyWindowsTimeZone()
        let created = ACController(appVersion: appVersion, settings: SyncedDefaults())
        controller = created
        WindowsSettingsCheck.report(to: created)
        #else
        controller = ACController(appVersion: appVersion)
        #endif
        stateRev += 1
        track()
    }
}

/// Leert die Main-Queue einmal (Abfrage, Timer und Befehle laufen dort).
@_cdecl("kc_pump")
public func kc_pump() {
    _ = RunLoop.main.run(mode: .default, before: Date())
}

/// Beendet Abfrage, Timer und Verbindung (beim Schließen der App).
@_cdecl("kc_stop")
public func kc_stop() {
    MainActor.assumeIsolated {
        controller?.stop()
        controller = nil
        // Ein späteres kc_init beobachtet neu (die alte Registrierung meldet sich evtl. nie mehr).
        tracking = false
        stateRev += 1
    }
}

// MARK: Zustand

/// Revisionszähler des Schnappschusses: Die Oberfläche liest kc_state_json nur, wenn er sich geändert hat.
@_cdecl("kc_state_rev")
public func kc_state_rev() -> Int64 {
    MainActor.assumeIsolated { stateRev }
}

struct LiveDTO: Encodable {
    var busy: Bool
    var nextRefresh: Double?
    /// Zeitabhängige Texte („vor 2 min aktualisiert“, Restzeit des Timers, Countdown): ändern sich ohne Zustandsänderung.
    var connectionLine: String
    var offTimerChip: String?
    var nextRefreshLine: String
}

/// Werte, die sich bei jeder Abfrage ändern (nicht im Schnappschuss, damit der Zähler nicht je Abfrage springt).
@_cdecl("kc_live_json")
public func kc_live_json() -> UnsafeMutablePointer<CChar> {
    mainCString {
        guard let c = controller else { return "{}" }
        return encode(LiveDTO(busy: c.busy, nextRefresh: c.nextRefresh?.timeIntervalSince1970,
                              connectionLine: c.connectionLine, offTimerChip: c.offTimerChip,
                              nextRefreshLine: c.nextRefreshLine), fallback: "{}")
    }
}

/// Aktueller Zustand als JSON (siehe `Snapshot`), "null" vor kc_init. Scheitert das Kodieren, kommt der letzte gute
/// Stand (bzw. `{"jsonError":true}`, falls es noch keinen gab) – nie "null" mitten im Betrieb.
@_cdecl("kc_state_json")
public func kc_state_json() -> UnsafeMutablePointer<CChar> {
    mainCString {
        guard let c = controller else { return "null" }
        let text = encode(snapshot(c), fallback: lastGoodState ?? #"{"jsonError":true}"#)
        if !jsonErrorLogged { lastGoodState = text }
        return text
    }
}

/// Zeitraum der Verlaufsabfragen an der C-Grenze prüfen: NaN, ∞, ≤ 0 → nil; sonst höchstens 400 Tage.
func historySeconds(_ seconds: Double) -> TimeInterval? {
    guard seconds.isFinite, seconds > 0 else { return nil }
    return min(seconds, 400 * 86_400)
}

struct SampleDTO: Encodable {
    var t: Double
    var power, indoor, outdoor, target: Double?
    var on: Bool
    /// Betriebsart (Zahl wie bei den Szenen), nur solange die Anlage lief; bei gemittelten Punkten die überwiegende.
    var mode: Int?
    /// Geglättete Außentemperatur für die Linie im Graphen (`HistorySample.smoothedOutdoor(_:range:)`); nur an
    /// Punkten mit Außenwert.
    var outdoorSmooth: Double?
}

/// Verlaufspunkte eines Zeitraums mit der geglätteten Außentemperatur desselben Zeitraums.
func historyDTOs(_ samples: [HistorySample], range: TimeInterval) -> [SampleDTO] {
    let smooth = Dictionary(HistorySample.smoothedOutdoor(samples, range: range).map { ($0.time, $0.outdoor) },
                            uniquingKeysWith: { first, _ in first })
    return samples.map {
        SampleDTO(t: $0.time.timeIntervalSince1970, power: $0.power, indoor: $0.indoor, outdoor: $0.outdoor,
                  target: $0.target, on: $0.on, mode: $0.mode?.rawValue,
                  outdoorSmooth: smooth[$0.time] ?? nil)
    }
}

/// Verlauf der letzten `seconds` Sekunden als JSON-Liste.
@_cdecl("kc_history_json")
public func kc_history_json(_ seconds: Double) -> UnsafeMutablePointer<CChar> {
    mainCString {
        guard let c = controller, let seconds = historySeconds(seconds) else { return "[]" }
        return encode(historyDTOs(c.history.window(seconds), range: seconds), fallback: "[]")
    }
}

struct ChartStatDTO: Encodable {
    var text, help: String
}

struct StatsDTO: Encodable {
    var avgWatts, peakWatts, kWh: Double?
    /// Kennzahlenzeile unter dem Leistungsgraphen (Mittel · Spitze · kWh · Kosten) mit Kurzinfos, aus dem Kern.
    var line: [ChartStatDTO]

    init(_ s: HistoryStats, price: Double, currency: String) {
        avgWatts = s.avgWatts
        peakWatts = s.peakWatts
        kWh = s.kWh
        line = UIText.chartStats(s, price: price, currency: currency).map { ChartStatDTO(text: $0.text, help: $0.help) }
    }
}

/// Kennzahlen des Verlaufs (Ø/Spitze/kWh) aus allen gespeicherten Punkten – genauer als aus den gemittelten
/// Graphenpunkten von `kc_history_json` (dort wäre der Verbrauch über 7 Tage fast 0).
@_cdecl("kc_history_stats_json")
public func kc_history_stats_json(_ seconds: Double) -> UnsafeMutablePointer<CChar> {
    mainCString {
        guard let c = controller, let seconds = historySeconds(seconds) else { return "{}" }
        return encode(StatsDTO(c.history.stats(seconds), price: c.pricePerKWh, currency: c.currency), fallback: "{}")
    }
}

/// Verbrauch der letzten `count` Zeiträume (`kind` = "day", "week", "month"; `count` 1 bis 60) als JSON-Objekt
/// `{kind, periods, summary}`, ältester Zeitraum zuerst, der letzte ist der laufende. Bei unbekannter Art oder
/// ungültiger Anzahl `{"error": "…"}`. Kosten mit dem eingestellten Strompreis.
@_cdecl("kc_energy_json")
public func kc_energy_json(_ kind: UnsafePointer<CChar>?, _ count: Int32) -> UnsafeMutablePointer<CChar> {
    let name = kind.map { String(cString: $0) }
    return mainCString {
        guard let c = controller else { return encode(EnergyErrorDTO(error: L.Bridge.notStarted), fallback: #"{"error":"error"}"#) }
        return energyJSON(c, kind: name, count: Int(count))
    }
}

/// Letzte Zeilen des Protokolls (enthält keine Geheimnisse). `lines` ≤ 0 → leer, höchstens 20 000.
@_cdecl("kc_log_tail")
public func kc_log_tail(_ lines: Int32) -> UnsafeMutablePointer<CChar> {
    guard lines > 0 else { return cString("") }
    return cString(AppLog.tail(min(Int(lines), 20_000)))
}

/// Hinweise zu Drittanbietern (Lizenzen der Quellen) als JSON-Liste – für den Reiter „Lizenzen“.
/// Felder: id, name, url, license, copyright (Liste), usage, platforms, licenseText.
@_cdecl("kc_third_party_json")
public func kc_third_party_json() -> UnsafeMutablePointer<CChar> {
    mainCString { encode(ThirdPartyNotices.all, fallback: "[]") }
}

/// Ordner mit device.json, Szenen, Verlauf und Protokoll.
@_cdecl("kc_support_dir")
public func kc_support_dir() -> UnsafeMutablePointer<CChar> {
    cString(DeviceConfig.supportDirectory.path)
}
// MARK: Befehle

/// Führt einen Befehl aus (Tabelle in BridgeCommands.swift). Rückgabe: nil = angenommen, sonst Fehlermeldung (mit
/// kc_free freigeben). Das Ergebnis an der Anlage erscheint mit der nächsten Abfrage von kc_state_json.
@_cdecl("kc_command")
public func kc_command(_ text: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    // Text vor dem Isolationswechsel kopieren; heraus kommt nur die Meldung als String (nil = angenommen).
    let command = text.map { String(cString: $0) }
    let message: String? = MainActor.assumeIsolated { handleCommand(command, on: controller) }
    return message.map(cString)
}

// MARK: Sprache und Formate

private struct LocaleDTO: Decodable {
    let uiLanguage: String
    let format: JSONValue?
}

/// Setzt Sprache und Format aus dem JSON von `kc_set_locale`. nil = übernommen, sonst Meldung. Die Sprache legt nur
/// der erste Aufruf fest, das Format gilt bei jedem Aufruf neu.
@MainActor func applyLocale(_ text: String?, settings: any SettingsStore) -> String? {
    guard let text, let dto = try? JSONDecoder().decode(LocaleDTO.self, from: Data(text.utf8)) else {
        return L.Bridge.localeUnreadable
    }
    let choice = LanguageChoice(stored: settings.object(forKey: SettingsKey.language) as? String)
    Localizer.configure(choice.resolve(preferred: [dto.uiLanguage]))
    guard let format = dto.format, let data = try? JSONEncoder().encode(format),
          let profile = FormatProfile.decode(data) else {
        return L.Bridge.formatInvalid
    }
    FormatProfile.setCurrent(profile)
    return nil
}

private struct StringsDTO: Encodable {
    var language: String
    var pseudo: Bool
    var strings: [String: LocalizedValue]
}

@MainActor func stringsJSON() -> String {
    encode(StringsDTO(language: Localizer.language.rawValue, pseudo: Localizer.isPseudo, strings: Localizer.table()),
           fallback: "{}")
}

/// Sprache und Formate setzen – vor `kc_init` aufrufen. JSON: `{"uiLanguage": "de-DE", "format": {"localeIdentifier":
/// "de_DE", "decimalSeparator": ",", "groupingSeparator": ".", "uses24HourClock": true, "amSymbol": "AM",
/// "pmSymbol": "PM", "dayMonthPattern": "dd.MM."}}`. Rückgabe nil = übernommen, sonst Meldung (mit `kc_free` freigeben).
@_cdecl("kc_set_locale")
public func kc_set_locale(_ json: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let text = json.map { String(cString: $0) }
    let message: String? = MainActor.assumeIsolated {
        #if os(Windows)
        WindowsSettingsCheck.runOnce()
        #endif
        return applyLocale(text, settings: UserDefaults.standard)
    }
    return message.map(cString)
}

/// Alle Texte der aktiven Sprache: `{"language", "pseudo", "strings": {Schlüssel: Text | {"one", "other", …}}}`.
@_cdecl("kc_strings_json")
public func kc_strings_json() -> UnsafeMutablePointer<CChar> {
    cString(MainActor.assumeIsolated { stringsJSON() })
}
