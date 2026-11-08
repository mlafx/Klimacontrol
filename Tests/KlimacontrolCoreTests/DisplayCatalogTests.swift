import Foundation
import MideaKit
@testable import KlimacontrolCore
import XCTest

/// Auswahllisten, Regeln und Anzeigetexte des Kerns – wörtlich so, wie die Mac-Oberfläche sie vor dem Umzug in den
/// Kern gezeigt hat. Ändert sich ein Text hier, ändert sich die Anzeige auf beiden Plattformen.
@MainActor
final class DisplayCatalogTests: CoreTestCase {
    /// Fester Zeitpunkt in Ortszeit (unabhängig von der Zeitzone des Rechners): 6. 11. 2026, 14:32.
    private func local(_ day: Int = 6, _ hour: Int = 14, _ minute: Int = 32, second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    private func controller(now: Date, configured: Bool = true) throws -> ACController {
        let c = makeController()
        if configured { try c.adopt(Self.config) }
        c.stop()
        c.now = { now }
        return c
    }

    private func change(_ c: ACController, _ edit: (inout Appearance) -> Void) {
        var a = c.appearance
        edit(&a)
        c.setAppearance(a)
    }

    private func cooling(_ c: ACController, indoor: Double? = 25.5, target: Double = 24) {
        var s = ACState()
        s.power = true
        s.mode = .cool
        s.targetTemperature = target
        s.indoorTemperature = indoor
        c.state = s
    }

    // MARK: Optionen und Grenzen

    func testWindowColumnTexts() {
        XCTAssertEqual(UIText.columnControls, "Steuerung")
        XCTAssertEqual(UIText.columnName(.history), "Verlauf")
        XCTAssertEqual(UIText.columnName(.diagnostics), "Diagnose")
        XCTAssertEqual(UIText.columnHidden(.history), "Verlauf ausgeblendet, weil der Bildschirm zu schmal ist.")
        XCTAssertEqual(UIText.columnHidden(.diagnostics), "Diagnose ausgeblendet, weil der Bildschirm zu schmal ist.")
    }

    func testOptionLists() {
        XCTAssertEqual(UIOptions.temperatureMin, 16)
        XCTAssertEqual(UIOptions.temperatureMax, 30)
        XCTAssertEqual(UIOptions.refreshChoices.map(\.seconds), [5, 10, 30, 60, 300])
        XCTAssertEqual(UIOptions.refreshChoices.map(\.label), ["5 Sekunden", "10 Sekunden", "30 Sekunden", "1 Minute", "5 Minuten"])
        XCTAssertEqual(UIOptions.refreshMin, 1)
        XCTAssertEqual(UIOptions.refreshMax, 600)
        XCTAssertEqual(UIOptions.refreshCustomHelp, "1 bis 600 Sekunden.")
        XCTAssertEqual(UIOptions.refreshCustomLabel, "Eigener Wert …")
        XCTAssertEqual(UIOptions.rateChoices, [100, 75, 50])
        XCTAssertEqual(UIOptions.rateShown(nil), 100)
        XCTAssertEqual(UIOptions.rateShown(50), 50)
        XCTAssertEqual(UIOptions.offTimerChoices.map(\.minutes), [30, 60, 120, 180, 240, 360, 480])
        XCTAssertEqual(UIOptions.offTimerChoices.map(\.label),
                       ["30 Minuten", "1 Stunde", "2 Stunden", "3 Stunden", "4 Stunden", "6 Stunden", "8 Stunden"])
        XCTAssertEqual(UIOptions.tokenLength, 128)
        XCTAssertEqual(UIOptions.keyLength, 64)
        XCTAssertEqual(UIOptions.defaultPort, 6444)
        XCTAssertEqual(UIOptions.addressExample, "z. B. 192.168.1.20")
        XCTAssertEqual(UIOptions.addressOrHostPrompt, "oder Adresse, z. B. 192.168.1.20")
        XCTAssertEqual(UIOptions.tokenPrompt, "128 Zeichen (0–9, a–f)")
        XCTAssertEqual(UIOptions.keyPrompt, "64 Zeichen (0–9, a–f)")
        XCTAssertEqual(UIOptions.fanMarks.map(\.label), ["1 %", "Leise", "Niedrig", "Mittel", "Hoch", "Max"])
        XCTAssertEqual(UIOptions.fanMarks.map(\.value), [1, 20, 40, 60, 80, 100])
        XCTAssertEqual(UIOptions.fanAutoKnob, 60)
    }

    func testRefreshWarning() {
        XCTAssertEqual(UIOptions.refreshWarning(forSeconds: 7),
                       "Unter 8 s bleibt die Verbindung dauerhaft offen – andere Apps (z. B. die Midea-App) kommen dann nicht an die Anlage.")
        XCTAssertNil(UIOptions.refreshWarning(forSeconds: 8))
        XCTAssertTrue(UIOptions.isRefreshPreset(30))
        XCTAssertFalse(UIOptions.isRefreshPreset(45))
    }

    func testChartRangesAndGapThreshold() {
        XCTAssertEqual(UIOptions.chartRanges.map(\.label), ["1 h", "6 h", "24 h", "7 Tage"])
        XCTAssertEqual(UIOptions.chartRanges.map(\.seconds), [3600, 21600, 86400, 604_800])
        XCTAssertEqual(UIOptions.chartRangeDefault, 21600)
        XCTAssertEqual(UIOptions.chartWindowCount, 600)
        XCTAssertEqual(UIOptions.chartGapThreshold(range: 3600), 180, "1 h: 3 · 6 s = 18 s, mindestens 3 min")
        XCTAssertEqual(UIOptions.chartGapThreshold(range: 21600), 180, "6 h: 3 · 36 s = 108 s")
        XCTAssertEqual(UIOptions.chartGapThreshold(range: 86400), 432, "24 h: 3 · 144 s")
        XCTAssertEqual(UIOptions.chartGapThreshold(range: 604_800), 3024, "7 Tage: 3 · 1008 s")
        XCTAssertEqual(UIOptions.chartBucketSeconds(range: 3600), 6)
        XCTAssertEqual(UIOptions.chartBucketSeconds(range: 10), 1, "mindestens eine Sekunde")
        XCTAssertEqual(UIOptions.chartTemperatureAxis, 16.0...30.0)
        XCTAssertEqual(UIOptions.chartOutdoorAxis, 0.0...10.0)
    }

    // MARK: Gültigkeit je Modus

    func testAvailabilityPerMode() {
        func enabled(_ f: UIOptions.ComfortFeature, _ m: OperationalMode) -> Bool { UIOptions.availability(f, mode: m).enabled }
        for m in [OperationalMode.cool, .heat, .dry, .fan, .auto] {
            XCTAssertEqual(enabled(.eco, m), m == .cool, "Eco nur Kühlen")
            XCTAssertEqual(enabled(.turbo, m), m == .cool || m == .heat, "Turbo nur Kühlen/Heizen")
            XCTAssertEqual(enabled(.outdoorSilent, m), m == .cool || m == .heat, "Außengerät leise nur Kühlen/Heizen")
            XCTAssertEqual(enabled(.freezeProtection, m), m == .heat, "Frostschutz nur Heizen")
            for f in [UIOptions.ComfortFeature.swing, .ieco, .purifier, .selfClean, .display, .sound] { XCTAssertTrue(enabled(f, m)) }
        }
    }

    func testAvailabilityTexts() {
        let cool = UIOptions.availability
        XCTAssertEqual(cool(.swing, .cool).why, "Lamellen schwenken auf und ab")
        XCTAssertEqual(cool(.eco, .cool).why, "Eco gibt es nur beim Kühlen")
        XCTAssertEqual(cool(.turbo, .cool).why,
                       "Turbo an/aus – die Lüfterstufe bleibt. Ganz rechts am Lüfter: Turbo und 100 % zusammen")
        XCTAssertEqual(cool(.turbo, .dry).why, "Turbo gibt es nur beim Kühlen und Heizen")
        XCTAssertEqual(cool(.outdoorSilent, .heat).why,
                       "Verdichter und Lüfter draußen gedrosselt – die Lüfterstufe bleibt. Ganz links am Lüfter: zusätzlich 1 %")
        XCTAssertEqual(cool(.outdoorSilent, .fan).why, "Außengerät leise wirkt nur beim Kühlen und Heizen")
        XCTAssertEqual(cool(.ieco, .auto).why,
                       "iECO = Sparprogramm der Anlage, begrenzt die Leistungsaufnahme in jedem Modus (Eco oben gilt nur beim Kühlen)")
        XCTAssertNil(cool(.purifier, .auto).why)
        XCTAssertEqual(cool(.freezeProtection, .heat).why, "Hält 8 °C – nur im Heizbetrieb")
        XCTAssertEqual(cool(.selfClean, .cool).why, "Selbstreinigung: trocknet und reinigt das Innengerät (ca. 15 Min.)")
        XCTAssertEqual(cool(.display, .cool).why, "Temperaturanzeige an der Anlage")
    }

    func testControllerUsesTheSameRules() async throws {
        let c = try await makeConnected()
        var s = c.state!
        s.mode = .heat
        c.state = s
        XCTAssertTrue(c.fanZonesAvailable)
        XCTAssertTrue(c.availability(.turbo).enabled)
        XCTAssertFalse(c.availability(.eco).enabled)
        s.mode = .dry
        c.state = s
        XCTAssertFalse(c.fanZonesAvailable)
        XCTAssertFalse(c.availability(.turbo).enabled)
    }

    // MARK: Lüfter

    func testFanCaption() {
        var s = ACState()
        s.mode = .cool
        s.fanSpeed = 60
        XCTAssertEqual(UIOptions.fanCaption(s), "Mittel · 60 %")
        s.fanSpeed = 37
        XCTAssertEqual(UIOptions.fanCaption(s), "37 %")
        s.fanSpeed = 1
        XCTAssertEqual(UIOptions.fanCaption(s), "1 %")
        s.outSilent = true
        XCTAssertEqual(UIOptions.fanCaption(s), "Außengerät leise · 1 %")
        s.outSilent = false
        s.fanSpeed = 100
        s.turbo = true
        XCTAssertEqual(UIOptions.fanCaption(s), "Turbo · 100 %")
        s.fanSpeed = 40
        s.outSilent = true
        XCTAssertEqual(UIOptions.fanCaption(s), "Niedrig · 40 % · Turbo · Außengerät leise", "Funktion an, Lüfter nicht in der Zone")
        s.fanSpeed = FanSpeed.auto.rawValue
        s.turbo = false
        s.outSilent = false
        XCTAssertEqual(UIOptions.fanCaption(s), "automatisch")
        s.mode = .heat
        s.fanSpeed = 100
        XCTAssertEqual(UIOptions.fanCaption(s), "Max · 100 %")
        s.mode = .dry
        XCTAssertEqual(UIOptions.fanCaption(s), "regelt die Anlage beim Trocknen")
        s.mode = .fan
        s.turbo = true
        s.fanSpeed = 100
        XCTAssertEqual(UIOptions.fanCaption(s), "Max · 100 %", "ohne Zonen kein Turbo-Zusatz")
    }

    func testFanZoneHelp() {
        XCTAssertEqual(UIOptions.fanQuietZoneHelp(on: true), "Außengerät leise ist an – Klick: zusätzlich Lüfter auf 1 %")
        XCTAssertEqual(UIOptions.fanQuietZoneHelp(on: false),
                       "Außengerät leise: 1 % und leises Außengerät – nur beim Kühlen und Heizen")
        XCTAssertEqual(UIOptions.fanTurboZoneHelp(on: true), "Turbo ist an – Klick: zusätzlich Lüfter auf 100 %")
        XCTAssertEqual(UIOptions.fanTurboZoneHelp(on: false), "Turbo: 100 % und Turbo – nur beim Kühlen und Heizen")
    }

    // MARK: Verbindungszeile

    func testConnectionLineBeforeFirstAnswer() throws {
        let c = try controller(now: local())
        XCTAssertEqual(c.connectionLine, "Verbinde …", "eingerichtet, noch kein Zustand")
    }

    func testConnectionLineWithPath() throws {
        let t0 = local()
        let c = try controller(now: t0)
        cooling(c)
        c.connectionPath = .lan
        c.lastUpdate = t0.addingTimeInterval(-5)
        XCTAssertEqual(c.connectionLine(now: t0), "Verbunden über WLAN · gerade aktualisiert")
        XCTAssertEqual(c.connectionLine(now: t0.addingTimeInterval(120)), "Verbunden über WLAN · vor 2 min aktualisiert")
        c.connectionPath = .cloud
        XCTAssertEqual(c.connectionLine(now: t0), "Verbunden über Cloud · gerade aktualisiert")
        c.connectionPath = nil
        XCTAssertEqual(c.connectionLine(now: t0), "Verbunden · gerade aktualisiert")
        c.lastUpdate = nil
        XCTAssertEqual(c.connectionLine(now: t0), "Verbinde …")
    }

    func testConnectionLineFailures() throws {
        let t0 = local()
        let c = try controller(now: t0)
        c.lastUpdate = nil
        c.showConnectionError(UserMessage(what: "x", todo: ""))
        XCTAssertEqual(c.connectionLine(now: t0), "Nicht erreichbar", "noch nie geantwortet")
        cooling(c)
        c.lastUpdate = t0.addingTimeInterval(-10)
        XCTAssertEqual(c.connectionLine(now: t0), "Keine Verbindung · zuletzt vor weniger als 1 min")
        XCTAssertEqual(c.connectionLine(now: t0.addingTimeInterval(300)), "Keine Verbindung · zuletzt vor 5 min")
        c.showConnectionError(UserMessage(what: "x", todo: ""), deviceOff: true)
        XCTAssertEqual(c.connectionLine(now: t0), "Anlage ausgeschaltet oder ohne Strom · zuletzt vor weniger als 1 min")
        XCTAssertEqual(c.connectionStatus, ConnectionStatus(text: "Anlage ausgeschaltet oder ohne Strom", connected: false))
    }

    func testConnectionLineWithoutSetupAndTooltip() throws {
        let c = try controller(now: local(), configured: false)
        XCTAssertEqual(c.connectionLine, "")
        XCTAssertEqual(c.connectionTooltip, "")
        try c.adopt(Self.config)
        XCTAssertEqual(c.connectionTooltip, "Test · 192.168.1.40:6444 · lokal")
        XCTAssertEqual(c.connectionStatus, ConnectionStatus(text: "Verbinde …", connected: false))
        c.connectionPath = .lan
        XCTAssertEqual(c.connectionStatus, ConnectionStatus(text: "Verbunden über WLAN", connected: true))
        c.showConnectionError(UserMessage(what: "x", todo: ""))
        XCTAssertEqual(c.connectionStatus, ConnectionStatus(text: "Keine Verbindung", connected: false))
    }

    // MARK: Alte Werte, große Zahl

    func testStaleTextAndHero() throws {
        let t0 = local()
        let c = try controller(now: t0)
        XCTAssertEqual(c.heroValue, "–")
        XCTAssertEqual(c.heroCaption, "")
        cooling(c)
        c.lastUpdate = t0.addingTimeInterval(-3600)
        XCTAssertNil(c.staleText)
        XCTAssertEqual(c.heroValue, "24°")
        XCTAssertEqual(c.heroCaption, "Kühlt · noch 1,5° bis zum Ziel")
        XCTAssertNil(c.heroHint)
        c.showConnectionError(UserMessage(what: "x", todo: ""))
        XCTAssertEqual(c.staleText, "Stand 13:32 · nicht aktuell")
        XCTAssertEqual(c.heroCaption, "Stand 13:32 · nicht aktuell")
    }

    func testStaleTextOfAnotherDay() throws {
        let t0 = local()
        let c = try controller(now: t0)
        cooling(c)
        c.lastUpdate = local(3, 9, 5)
        c.showConnectionError(UserMessage(what: "x", todo: ""))
        XCTAssertEqual(c.staleText, "Stand 03.11., 09:05 · nicht aktuell")
    }

    func testHeroOffFanAndRoom() throws {
        let c = try controller(now: local())
        var s = ACState()
        s.power = false
        s.indoorTemperature = 22.4
        c.state = s
        XCTAssertEqual(c.heroValue, "22,4°")
        XCTAssertEqual(c.heroCaption, "Raumtemperatur · Anlage aus")
        XCTAssertEqual(c.heroHint, "Einschalten mit dem Knopf oben oder direkt einen Modus bzw. eine Szene wählen.")
        s.power = true
        s.mode = .fan
        c.state = s
        XCTAssertEqual(c.heroValue, "22,4°")
        XCTAssertEqual(c.heroCaption, "Raumtemperatur · Lüften ohne Zieltemperatur")
        XCTAssertNil(c.heroHint)
        cooling(c)
        change(c) { $0.hero = .room }
        XCTAssertEqual(c.heroValue, "25,5°")
        XCTAssertEqual(c.heroCaption, "Soll 24° · Kühlt · noch 1,5° bis zum Ziel")
        cooling(c, indoor: nil)
        XCTAssertEqual(c.heroValue, "24°", "ohne Raumtemperatur bleibt das Soll groß")
        XCTAssertEqual(c.heroCaption, "Kühlt")
    }

    // MARK: Kosten

    /// Tagesbeginn wie ihn der Kern speichert (Anlage 42 = `Self.config`).
    private func setDayStart(kWh: Double, midnight: Bool, since: Date, now: Date) {
        settings.values[SettingsKey.energyDayStart] =
            "\(ACController.dayString(now));\(kWh);42;\(Int(since.timeIntervalSince1970));\(midnight ? 1 : 0)"
    }

    func testCostLineWithoutCounter() async throws {
        let c = try await makeConnected()
        var s = c.state!
        s.totalEnergyKWh = nil
        c.state = s
        XCTAssertEqual(c.costLine, CostLine(title: "Kosten heute", value: "unbekannt",
                                            help: "Tagesverbrauch unbekannt – der Zähler der Anlage hat noch keinen Wert geliefert."))
    }

    func testCostLineFromMidnight() async throws {
        let c = try await makeConnected()
        let now = local()
        c.now = { now }
        c.pricePerKWh = 0.5
        var s = c.state!
        s.totalEnergyKWh = 100
        s.powerWatts = 400
        c.state = s
        setDayStart(kWh: 99, midnight: true, since: now, now: now)
        XCTAssertEqual(c.costLine.title, "Kosten heute")
        XCTAssertEqual(c.costLine.value, "0,50 €")
        XCTAssertEqual(c.costLine.help, "1,00 kWh laut Zähler der Anlage seit Mitternacht · Zähler gesamt 100,00 kWh")
        XCTAssertEqual(c.powerCostHelp, "Kosten bei dieser Leistung: 0,20 € pro Stunde")
    }

    func testCostLineSinceTimeAndUncertain() async throws {
        let c = try await makeConnected()
        let now = local()
        c.now = { now }
        c.pricePerKWh = 0.5
        var s = c.state!
        s.totalEnergyKWh = 100
        c.state = s
        setDayStart(kWh: 99, midnight: false, since: now.addingTimeInterval(-6 * 3600), now: now)
        XCTAssertEqual(c.costLine.title, "Kosten seit 08:32")
        XCTAssertEqual(c.costLine.help, "1,00 kWh laut Zähler der Anlage seit 08:32 · Zähler gesamt 100,00 kWh")
        // Zähler unter dem Tagesbeginn: passt nicht zur Leistung.
        setDayStart(kWh: 105, midnight: true, since: now, now: now)
        XCTAssertEqual(c.costLine.value, "0,00 € · unsicher")
        XCTAssertEqual(c.costLine.help,
                       "0,00 kWh laut Zähler der Anlage seit Mitternacht · Zähler gesamt 100,00 kWh\nUnsicher: Der Zähler passt nicht zur gemessenen Leistung.")
    }

    // MARK: Menüleiste

    func testMenuTitle() throws {
        let c = try controller(now: local())
        XCTAssertNil(c.menuTitle, "ohne Zustand")
        cooling(c)
        XCTAssertEqual(c.menuTitle, "24°", "Standard: Symbol und Soll")
        change(c) { $0.menuBarText = .iconRoom }
        XCTAssertEqual(c.menuTitle, "25,5°")
        change(c) { $0.menuBarText = .roomTarget }
        XCTAssertEqual(c.menuTitle, "25,5° → 24°")
        change(c) { $0.menuBarText = .iconOnly }
        XCTAssertNil(c.menuTitle)
        change(c) { $0.menuBarText = .iconTarget }
        var s = c.state!
        s.mode = .fan
        c.state = s
        XCTAssertNil(c.menuTitle, "beim Lüften kein Soll")
        s.power = false
        s.mode = .cool
        c.state = s
        XCTAssertNil(c.menuTitle, "ausgeschaltet kein Soll")
        change(c) { $0.menuBarText = .roomTarget }
        XCTAssertEqual(c.menuTitle, "25,5°")
        s.indoorTemperature = nil
        s.power = true
        c.state = s
        XCTAssertEqual(c.menuTitle, "24°")
    }

    // MARK: Timer und Beenden

    func testTimerChipsAndQuitPrompt() throws {
        let t0 = local()
        let c = try controller(now: t0)
        XCTAssertNil(c.offTimerChip)
        XCTAssertNil(c.onTimerChip)
        XCTAssertNil(c.quitPrompt())
        c.offAt = t0.addingTimeInterval(90 * 60)
        XCTAssertEqual(c.offTimerChip, "Aus in 1 h 30 min")
        XCTAssertEqual(c.offTimerChip(now: t0.addingTimeInterval(30 * 60)), "Aus in 1 h")
        XCTAssertEqual(c.offTimerChip(now: t0.addingTimeInterval(89 * 60 + 40)), "Aus in 0 min")
        XCTAssertEqual(c.offTimerChip(now: t0.addingTimeInterval(61 * 60)), "Aus in 29 min")
        c.onAt = local(7, 7, 0)
        XCTAssertEqual(c.onTimerChip, "Ein morgen 07:00")
        let prompt = try XCTUnwrap(c.quitPrompt())
        XCTAssertEqual(prompt.title, "Klimacontrol beenden?")
        XCTAssertEqual(prompt.message,
                       "Timer „Aus“ heute um 16:02 und „Ein“ morgen um 07:00 ist gestellt. Er schaltet nur, solange Klimacontrol geöffnet ist.")
        XCTAssertEqual(prompt.cancel, "Geöffnet lassen")
        XCTAssertEqual(prompt.confirm, "Trotzdem beenden")
    }

    func testQuitPromptNamesFarDaysLikeTheMac() throws {
        let t0 = local()
        let c = try controller(now: t0)
        c.onAt = local(9, 7, 5)
        XCTAssertEqual(try XCTUnwrap(c.quitPrompt()).message,
                       "Timer „Ein“ am Mo. 9.11. um 07:05 ist gestellt. Er schaltet nur, solange Klimacontrol geöffnet ist.")
    }

    // MARK: Startanzeige

    func testStartupValues() throws {
        let t0 = local()
        let c = try controller(now: t0)
        let on = HistorySample(time: t0.addingTimeInterval(-3600), power: 300, indoor: 25.5, outdoor: 29, target: 24, on: true)
        let v = try XCTUnwrap(c.startupValues(from: on, now: t0))
        XCTAssertEqual(v.main, "24°")
        XCTAssertEqual(v.caption, "Stand 13:32 · Solltemperatur")
        XCTAssertEqual(v.extras, ["Raum 25,5°", "Außen 29,0°"])
        XCTAssertEqual(v.accessibility, "Zuletzt bekannte Werte, Stand 13:32: 24°")
        let off = HistorySample(time: t0.addingTimeInterval(-3600), power: 0, indoor: 22, outdoor: nil, target: nil, on: false)
        let w = try XCTUnwrap(c.startupValues(from: off, now: t0))
        XCTAssertEqual(w.main, "22,0°")
        XCTAssertEqual(w.caption, "Stand 13:32 · Raumtemperatur · aus")
        XCTAssertEqual(w.extras, ["Außen –"])
        let old = HistorySample(time: t0.addingTimeInterval(-8 * 86400), power: 0, indoor: 22, outdoor: nil, target: nil, on: false)
        XCTAssertNil(c.startupValues(from: old, now: t0), "älter als 7 Tage")
        XCTAssertNil(c.startupValues(from: nil, now: t0))
        XCTAssertNil(c.startupValues, "kein Verlauf beim Start")
    }

    func testConnectSteps() {
        XCTAssertEqual(UIText.connectStepsLine(nil), "Anlage suchen … · Anmelden · Werte lesen")
        XCTAssertEqual(UIText.connectStepsLine(.searching), "Anlage suchen … · Anmelden · Werte lesen")
        XCTAssertEqual(UIText.connectStepsLine(.handshake), "Anlage suchen ✓ · Anmelden … · Werte lesen")
        XCTAssertEqual(UIText.connectStepsLine(.reading), "Anlage suchen ✓ · Anmelden ✓ · Werte lesen …")
        XCTAssertEqual(UIText.connectSlowText, "Dauert länger als üblich.")
        XCTAssertEqual(UIText.retryButton, "Erneut versuchen")
    }

    // MARK: Diagnose

    func testDiagnosticsTexts() {
        XCTAssertEqual(UIText.errorCodeValue(0), "keiner")
        XCTAssertEqual(UIText.errorCodeValue(7), "Code 7 – siehe Bedienungsanleitung")
        XCTAssertEqual(UIText.filterValue(alert: true), "reinigen")
        XCTAssertEqual(UIText.filterValue(alert: false), "in Ordnung")
        XCTAssertEqual(UIText.maintenanceHints(filterAlert: false, errorCode: 0), [])
        XCTAssertEqual(UIText.maintenanceHints(filterAlert: true, errorCode: 5), [
            "Die Anlage meldet eine Störung. Bedeutung und Abhilfe stehen in der Bedienungsanleitung (Code 5).",
            "Filter reinigen: Die Anlage bittet um eine Filterreinigung (siehe Bedienungsanleitung).",
        ])
    }

    func testNextRefreshLine() throws {
        let t0 = local()
        let c = try controller(now: t0)
        XCTAssertEqual(c.nextRefreshLine(now: t0), "Live aus der Anlage · alle 30 s · nächste Abfrage in …")
        c.nextRefresh = t0.addingTimeInterval(11.2)
        XCTAssertEqual(c.nextRefreshLine(now: t0), "Live aus der Anlage · alle 30 s · nächste Abfrage in 12 s")
        XCTAssertEqual(c.nextRefreshLine(now: t0.addingTimeInterval(30)), "Live aus der Anlage · alle 30 s · nächste Abfrage in 0 s")
    }

    // MARK: Verbindungsweg

    func testWayHelp() {
        XCTAssertEqual(UIText.wayHelp(.auto), "Erst WLAN, dann über das Midea-Konto – empfohlen.")
        XCTAssertEqual(UIText.wayHelp(.lan), "Nur im selben WLAN. Nutzt nie die Midea-Server und braucht kein Internet.")
        XCTAssertEqual(UIText.wayHelp(.cloud), "Über die Midea-Server, auch unterwegs – langsamer.")
        XCTAssertEqual(UIText.modeAfterAccountLogin(.lan), .auto)
        XCTAssertEqual(UIText.modeAfterAccountLogin(.cloud), .cloud)
        XCTAssertEqual(UIText.modeAfterAccountLogin(.auto), .auto)
    }

    // MARK: Darstellung

    func testAppearanceIsStandard() throws {
        let c = try controller(now: local())
        XCTAssertTrue(c.appearanceIsStandard)
        change(c) { $0.glow = 0.5 }
        XCTAssertFalse(c.appearanceIsStandard)
        c.resetAppearance()
        XCTAssertTrue(c.appearanceIsStandard)
    }

    func testAppearanceTabTexts() {
        XCTAssertEqual(L.Settings.Appearance.Display.section, "Anzeige")
        XCTAssertEqual(L.Settings.Appearance.WindowMenu.section, "Fenster und Menüleiste")
        XCTAssertEqual(L.Settings.Appearance.WindowNotify.section, "Fenster und Infobereich")
        XCTAssertEqual(L.Settings.Appearance.Customize.title, "Anpassen")
        XCTAssertEqual(L.Settings.Appearance.Theme.customized, "angepasst")
        XCTAssertEqual(L.Settings.Appearance.Theme.restore, "Thema wiederherstellen")
        XCTAssertEqual(L.Settings.Appearance.Theme.selected, "ausgewählt")
    }

    func testAppearanceIsCustomized() throws {
        let c = try controller(now: local())
        XCTAssertFalse(c.appearanceIsCustomized)
        change(c) { $0.glow = 0.5 }
        XCTAssertTrue(c.appearanceIsCustomized)
        c.applyTheme(c.appearance.theme)
        XCTAssertFalse(c.appearanceIsCustomized)
    }

    // MARK: Meldungen und Rückfragen

    func testBackupImportedMessages() {
        XCTAssertEqual(UIText.backupImported(BackupImportResult(verified: true), ip: "192.168.1.40").text,
                       "Sicherung eingelesen, die Anlage nimmt die Zugangsdaten an.")
        XCTAssertEqual(UIText.backupImported(BackupImportResult(verified: nil), ip: "").text, "Sicherung eingelesen.")
        XCTAssertEqual(UIText.backupImported(BackupImportResult(verified: true, scenesImported: 3, scenesSkipped: 0), ip: "").text,
                       "Sicherung eingelesen, die Anlage nimmt die Zugangsdaten an. 3 Szenen übernommen.")
        XCTAssertEqual(UIText.backupImported(BackupImportResult(verified: nil, scenesImported: 0, scenesSkipped: 2), ip: "").text,
                       "Sicherung eingelesen. Die vorhandenen Szenen bleiben.")
        let down = UIText.backupImported(BackupImportResult(verified: false), ip: "192.168.1.40")
        XCTAssertFalse(down.ok)
        XCTAssertEqual(down.text, "Sicherung eingelesen, aber die Anlage antwortet nicht unter 192.168.1.40. "
            + "Ist sie eingeschaltet? Hat sie eine neue Adresse, hilft „Adresse neu suchen“ unter Einstellungen → Anlage.")
        XCTAssertEqual(UIText.backupImported(BackupImportResult(verified: false), ip: "").text,
                       "Sicherung eingelesen, aber die Anlage antwortet nicht. "
                       + "Ist sie eingeschaltet? Hat sie eine neue Adresse, hilft „Adresse neu suchen“ unter Einstellungen → Anlage.")
        XCTAssertTrue(UIText.backupImported(BackupImportResult(verified: true), ip: "").ok)
    }

    func testBackupImportFailedMessages() {
        let other = UIText.backupImportFailed(BackupImportError.otherDevice(backup: "A", current: "B"))
        XCTAssertFalse(other.ok)
        XCTAssertEqual(other.text, BackupImportError.otherDevice(backup: "A", current: "B").errorDescription)
        XCTAssertEqual(UIText.backupImportFailed(BackupImportError.rejected).text, BackupImportError.rejected.errorDescription)
        struct Boom: LocalizedError { var errorDescription: String? { "kaputt" } }
        XCTAssertEqual(UIText.backupImportFailed(Boom()).text,
                       "Die Sicherung ließ sich nicht einlesen. Ist es die richtige Datei? (kaputt)")
    }

    func testExportMessages() {
        struct Boom: LocalizedError { var errorDescription: String? { "kein Zugriff" } }
        XCTAssertEqual(UIText.backupExported(fileName: "s.json").text, "Gesichert als „s.json“.")
        XCTAssertEqual(UIText.backupExportFailed(Boom()).text,
                       "Die Sicherung ließ sich nicht speichern. Anderen Ort wählen? (kein Zugriff)")
        XCTAssertEqual(UIText.historyExported(fileName: "v.csv").text, "Verlauf gespeichert als „v.csv“.")
        XCTAssertEqual(UIText.historyExportFailed(Boom()).text,
                       "Der Verlauf ließ sich nicht speichern. Anderen Ort wählen? (kein Zugriff)")
        XCTAssertTrue(UIText.backupExported(fileName: "s.json").ok)
        XCTAssertFalse(UIText.historyExportFailed(Boom()).ok)
    }

    func testPrompts() {
        let other = UIText.otherDevicePrompt(backup: "Wohnzimmer", current: "Büro")
        XCTAssertEqual(other.title, "Andere Anlage einrichten?")
        XCTAssertEqual(other.message,
                       "Die Sicherung gehört zu „Wohnzimmer“, eingerichtet ist „Büro“. Beim Wechsel kommt die bisherige Einrichtung in den Papierkorb.")
        XCTAssertEqual([other.cancel, other.confirm], ["Abbrechen", "Anlage wechseln"])
        let cloud = UIText.cloudFolderPrompt(folder: "OneDrive")
        XCTAssertEqual(cloud.title, "In einem Cloud-Ordner sichern?")
        XCTAssertEqual(cloud.message, "„OneDrive“ wird mit einem Cloud-Dienst abgeglichen. Mit Token und Schlüssel lässt sich die Anlage steuern – besser lokal oder auf einem USB-Stick ablegen.")
        XCTAssertEqual([cloud.cancel, cloud.confirm], ["Anderen Ort wählen", "Trotzdem sichern"])
        XCTAssertEqual(UIText.replaceScenesPrompt.title, "Szenen ersetzen?")
        XCTAssertEqual(UIText.replaceScenesPrompt.message,
                       "Es gibt schon Szenen. Sollen sie durch die Szenen aus der Sicherung ersetzt werden?")
        XCTAssertEqual([UIText.replaceScenesPrompt.cancel, UIText.replaceScenesPrompt.confirm], ["Behalten", "Ersetzen"])
        XCTAssertEqual(UIText.selfCleanPrompt.title, "Selbstreinigung starten?")
        XCTAssertEqual(UIText.selfCleanPrompt.message,
                       "Dauert etwa 15 Minuten. Die Anlage macht dabei ungewöhnliche Geräusche, es kann Dampf austreten – das ist normal.")
        XCTAssertEqual([UIText.selfCleanPrompt.cancel, UIText.selfCleanPrompt.confirm], ["Abbrechen", "Starten"])
        XCTAssertEqual(UIText.accountRemovePrompt().title, "Midea-Konto entfernen?")
        XCTAssertEqual(UIText.accountSignedIn, "Angemeldet und gespeichert.")
        XCTAssertEqual(UIText.accountRemoved, "Midea-Konto und Passwort entfernt.")
    }

    func testAccountRemovePromptNamesTheHostStore() {
        XCTAssertEqual(UIText.accountRemovePrompt(host: .mac).message,
                       "Konto und Passwort werden aus dem Schlüsselbund gelöscht, unterwegs ist die Anlage dann nicht mehr erreichbar. "
                       + "Das Konto lässt sich jederzeit wieder anmelden.")
        XCTAssertEqual(UIText.accountRemovePrompt(host: .windows).message,
                       "Konto und Passwort werden aus der Anmeldeinformationsverwaltung gelöscht, unterwegs ist die Anlage dann nicht mehr erreichbar. "
                       + "Das Konto lässt sich jederzeit wieder anmelden.")
    }

    func testForgetPromptWordingPerHost() {
        let tail = " Die Sitzung beim Midea-Konto endet. Danach sucht Klimacontrol neu – im WLAN oder über das Midea-Konto."
        let hint = "\n\nDie Zugangsdaten sind noch nicht gesichert. Mit „Erst sichern …“ lässt sich die Anlage später "
            + "ohne neue Suche wieder einrichten."
        let mac = UIText.forgetPrompt(needsBackup: false, host: .mac)
        XCTAssertEqual(mac.title, "Anlage neu einrichten?")
        XCTAssertEqual([mac.backup, mac.confirm, mac.cancel], ["Erst sichern …", "Neu einrichten", "Abbrechen"])
        XCTAssertEqual(mac.message, "Die Einrichtungsdatei kommt unverändert in den Papierkorb – Token und Schlüssel liegen "
                       + "danach im Papierkorb (wer ihn leert, verliert sie)." + tail)
        XCTAssertFalse(mac.warning)
        let win = UIText.forgetPrompt(needsBackup: true, host: .windows)
        XCTAssertEqual(win.message, "Die Einrichtungsdatei wird nicht gelöscht, sondern unverändert im Datenordner "
                       + "beiseitegelegt. Token und Schlüssel bleiben in der Datei erhalten, bis du sie selbst löschst."
                       + tail + hint)
        XCTAssertTrue(win.warning, "ungesichert: Warnung")
    }

    func testCloudNeedsAccountNotice() {
        XCTAssertEqual(UIText.cloudNeedsAccount.title, "Midea-Konto fehlt")
        XCTAssertEqual(UIText.cloudNeedsAccount.message,
                       "Dieser Weg geht nur mit Midea-Konto. Bitte zuerst unten beim Midea-Konto anmelden.")
    }

    func testForgetNeedsBackupOnlyWithUnsavedLANCredentials() async throws {
        let c = try await makeConnected()
        XCTAssertTrue(c.forgetNeedsBackup, "WLAN-Zugangsdaten, noch nicht gesichert")
        XCTAssertTrue(c.forgetPrompt(host: .mac).warning)
        try c.exportBackup(to: dir.appendingPathComponent("sicherung.json"))
        XCTAssertFalse(c.forgetNeedsBackup, "gesichert")
        XCTAssertFalse(c.forgetPrompt(host: .mac).message.contains("noch nicht gesichert"))
    }

    func testCloudLoginSwitchesOnlyLANToAuto() async throws {
        let c = try await makeConnected()
        c.connectionMode = .lan
        var err = await c.cloudLogin(account: "a@example.com", password: "pw")
        XCTAssertNil(err)
        XCTAssertEqual(c.connectionMode, .auto, "Wer ein Konto anmeldet, will es nutzen")
        c.connectionMode = .cloud
        err = await c.cloudLogin(account: "a@example.com", password: "pw")
        XCTAssertNil(err)
        XCTAssertEqual(c.connectionMode, .cloud)
        c.stop()
    }

    func testCloudFolderDetection() {
        XCTAssertTrue(UIText.isCloudFolder(path: "/Users/x/Library/CloudStorage/OneDrive-Personal/a.json"))
        XCTAssertTrue(UIText.isCloudFolder(path: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/a.json"))
        XCTAssertTrue(UIText.isCloudFolder(path: "/Users/x/Dropbox/a.json"))
        XCTAssertTrue(UIText.isCloudFolder(path: "/Users/x/Google Drive/a.json"))
        XCTAssertTrue(UIText.isCloudFolder(path: "C:\\Users\\x\\OneDrive\\Dokumente\\a.json"), "Windows-Pfad mit Rückstrichen")
        XCTAssertFalse(UIText.isCloudFolder(path: "/Users/x/Documents/a.json"))
        XCTAssertFalse(UIText.isCloudFolder(path: "C:\\Users\\x\\Klimacontrol\\a.json"))
    }

    func testCloudFolderNoticeAfterExport() async throws {
        let c = try await makeConnected()
        let url = dir.appendingPathComponent("OneDrive").appendingPathComponent("s.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try c.exportBackup(to: url)
        XCTAssertEqual(c.notice, "Die Sicherung liegt in einem Cloud-Ordner und enthält Token und Schlüssel der Anlage. "
                       + "Lege sie besser in einen Ordner nur auf diesem Rechner.")
        XCTAssertEqual(c.noticeMessage, UIText.cloudFolderNotice)
    }

    func testSetupDonePrompt() {
        let backup = SetupCompletion(path: .manual, suggestLANOnly: true, offerBackup: true, note: "Eingerichtet.")
        let p = UIText.setupDonePrompt(backup, host: .mac)
        XCTAssertEqual(p?.title, "Zugangsdaten jetzt sichern?")
        XCTAssertEqual(p?.paragraphs, ["Eingerichtet.",
                                       "Ohne Midea-Konto liegen Token und Schlüssel nur auf diesem Mac. Eine Sicherung braucht es für einen anderen Rechner oder nach „Neu einrichten“."])
        XCTAssertEqual(p?.lanOnlyChoice, "Nur WLAN nutzen (nie über die Midea-Server)")
        XCTAssertEqual(p?.primary, "Sichern …")
        XCTAssertEqual(p?.secondary, "Später")
        XCTAssertTrue(UIText.setupDonePrompt(backup, host: .windows)?.paragraphs.last?.contains("diesem Rechner") ?? false)
        let lanOnly = SetupCompletion(path: .account, suggestLANOnly: true, offerBackup: false, note: "Hinweis.")
        let q = UIText.setupDonePrompt(lanOnly, host: .mac)
        XCTAssertEqual(q?.title, "Anlage eingerichtet")
        XCTAssertEqual(q?.paragraphs, ["Hinweis."])
        XCTAssertEqual(q?.primary, "OK")
        XCTAssertNil(q?.secondary)
        XCTAssertNil(UIText.setupDonePrompt(SetupCompletion(path: .account, suggestLANOnly: false, offerBackup: false, note: "x")))
    }

    func testAccountFooter() {
        XCTAssertEqual(UIText.accountFooter(signedIn: false, host: .mac),
                       "Optional. Das Passwort wird nur im macOS-Schlüsselbund gespeichert, damit sich Klimacontrol neu anmelden kann. Es verlässt den Mac nur zur Anmeldung bei Midea.")
        XCTAssertEqual(UIText.accountFooter(signedIn: true, host: .mac),
                       "Angemeldet. Bei „Automatisch“ springt das Midea-Konto ein, wenn WLAN nicht geht. Das Passwort wird nur im macOS-Schlüsselbund gespeichert, damit sich Klimacontrol neu anmelden kann. Es verlässt den Mac nur zur Anmeldung bei Midea.")
        XCTAssertTrue(UIText.accountFooter(signedIn: false, host: .windows).contains("Windows-Anmeldeinformationsverwaltung"))
    }

    func testKeychainMessagesNameTheStoreOfTheHost() {
        let unavailable = KeychainError.unavailable(-25293)
        XCTAssertEqual(UserMessage.from(unavailable, host: .mac).text,
                       "Der Schlüsselbund ist gesperrt oder hat den Zugriff abgelehnt. Mac entsperren bzw. den Zugriff erlauben und erneut versuchen. (Status -25293)")
        XCTAssertEqual(UserMessage.from(unavailable, host: .windows).text,
                       "Die Anmeldeinformationsverwaltung ist gesperrt oder hat den Zugriff abgelehnt. Windows entsperren bzw. den Zugriff erlauben und erneut versuchen. (Status -25293)")
        XCTAssertEqual(UserMessage.from(KeychainError.saveFailed(-1), host: .mac).what,
                       "Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden.")
        XCTAssertEqual(UserMessage.from(KeychainError.saveFailed(-1), host: .windows).what,
                       "Die Zugangsdaten konnten nicht in der Anmeldeinformationsverwaltung gespeichert werden.")
        XCTAssertEqual(keychainLockedText(host: .mac),
                       "Der Schlüsselbund ist gesperrt. Mac entsperren; Klimacontrol versucht es danach von selbst wieder.")
        XCTAssertEqual(keychainLockedText(host: .windows),
                       "Die Anmeldeinformationsverwaltung ist gesperrt. Windows entsperren; Klimacontrol versucht es danach von selbst wieder.")
        Localizer.withLanguage(.en) {
            XCTAssertEqual(UserMessage.from(unavailable, host: .windows).what, "Windows Credential Manager is locked or denied access.")
            XCTAssertEqual(keychainLockedText(host: .windows),
                           "Windows Credential Manager is locked. Unlock Windows; Klimacontrol will then try again on its own.")
        }
    }

    func testNoMacWordsInWindowsVariantsOfKeychainTexts() {
        let windowsTexts = [
            L.Message.Keychain.Windows.Unavailable.what, L.Message.Keychain.Windows.Unavailable.todo,
            L.Message.Keychain.Windows.SaveFailed.what, L.Message.Account.Windows.notSaved, L.Reason.Cloud.Windows.keychainLocked,
        ]
        for text in windowsTexts {
            XCTAssertFalse(text.contains("Schlüsselbund") || text.contains("Mac"), text)
        }
    }

    // MARK: Hinweise mit Code

    func testNoticeKeepsTextAndCodeApart() throws {
        let c = try controller(now: local())
        c.showNotice("Nur Text.")
        XCTAssertEqual(c.notice, "Nur Text.")
        XCTAssertEqual(c.noticeMessage, UserMessage(what: "Nur Text.", todo: ""))
        c.showNotice(UserMessage.from(MideaError.timeout))
        XCTAssertEqual(c.notice, UserMessage.from(MideaError.timeout).text)
        let m = UserMessage(what: "Anlage offline.", todo: "Später.", code: "3123")
        c.showNotice(m)
        XCTAssertEqual(c.noticeMessage?.code, "3123")
        XCTAssertEqual(c.notice, "Anlage offline. Später. (3123)")
        c.clearNotice()
        XCTAssertNil(c.noticeMessage)
        XCTAssertNil(c.notice)
    }

    // MARK: Updates

    func testUpdateTexts() {
        XCTAssertEqual(UIText.updatesHelp(host: .mac),
                       "Updates werden automatisch geladen. Danach fragt Klimacontrol, ob es gleich neu starten soll; sonst wird beim Beenden installiert.")
        XCTAssertEqual(UIText.updatesHelp(host: .windows),
                       "Klimacontrol sucht täglich nach Updates und fragt vor der Installation.")
        XCTAssertEqual(UIText.updatesChecking, "Suche nach Updates …")
        XCTAssertEqual(UIText.updatesCurrent, "Klimacontrol ist auf dem neuesten Stand.")
        XCTAssertEqual(UIText.updatesInstalling(version: "1.2.3.4"),
                       "Version 1.2.3.4 wird geladen und installiert. Klimacontrol startet danach neu.")
        XCTAssertEqual(UIText.updatesFailed, "Die Suche nach Updates hat nicht geklappt. Später erneut versuchen.")
        XCTAssertEqual(UIText.updatesCheckButton, "Jetzt suchen …")
        XCTAssertEqual(UIText.updatesManualCurrentTitle, "Klimacontrol ist aktuell.")
        XCTAssertEqual(UIText.updatesManualCurrentMessage(version: "1.2.3.4"), "Version 1.2.3.4 ist die neueste Version.")
        XCTAssertEqual(UIText.updatesManualFailedTitle, "Nach Updates suchen hat nicht geklappt.")
        XCTAssertEqual(UIText.updatesManualFailedMessage,
                       "Die Update-Information konnte nicht geladen oder geprüft werden. Später erneut versuchen.")
    }

    func testWhatsNewTexts() {
        XCTAssertEqual(UIText.whatsNewTitle(version: "1.0.1.2"), "Neu in Klimacontrol 1.0.1.2")
        XCTAssertEqual(UIText.whatsNewVersionHeading("1.0.1.1"), "Version 1.0.1.1")
        XCTAssertEqual(UIText.whatsNewOK, "OK")
    }
}
