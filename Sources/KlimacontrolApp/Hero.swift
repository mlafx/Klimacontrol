import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Große Zahl

/// Schrift der großen Temperatur aus dem Aussehen (Größe, Ziffernstil). Standard: 68 pt, leicht, abgerundet.
struct HeroLook: Equatable {
    var scale: CGFloat = 1
    var weight: Font.Weight = .light
    var design: Font.Design = .rounded

    init() {}

    init(_ theme: ThemeStyle) {
        scale = theme.scale
        weight = theme.fontWeight
        design = theme.fontDesign
    }

    func font(_ base: CGFloat, monospaced: Bool = true) -> Font {
        let f = Font.system(size: (base * scale).rounded(), weight: weight, design: design)
        return monospaced ? f.monospacedDigit() : f
    }
}

extension View {
    /// Leuchten um die große Zahl, nur wenn die Anlage live arbeitet (Stärke aus dem Thema, Standard 0 = nichts).
    @ViewBuilder
    func heroGlow(_ color: Color, active: Bool) -> some View {
        if active { klimaGlow(color) } else { self }
    }
}

// MARK: - Kopf: Was macht die Anlage gerade?

struct HeroView: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    let state: ACState
    /// Kennzahlenzeile im Kopf; beim Umfang „Einfach“ steht sie unter „Mehr …“.
    var showReadings = true

    /// Werte nicht live (Verbindungsfehler, Anlage aus laut Cloud): seit wann – sonst nil.
    private var staleSince: Date? { model.uiStaleSince }
    private var live: Bool { state.power && staleSince == nil }
    private var tint: Color { live ? theme.tint(for: state.mode) : .secondary }
    /// Zieltext – bei alten Werten stattdessen „Stand 14:32 · nicht aktuell“ (sonst wirkt „Heizt · noch 2°“ live).
    private var goal: String { model.staleText ?? model.goalLine }
    private var look: HeroLook { HeroLook(theme) }
    /// „Groß angezeigt: Raumtemperatur“ – nur, wenn die Anlage sie gemeldet hat.
    private var roomBig: Bool { model.appearance.hero == .room && state.indoorTemperature != nil }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.title3.weight(.semibold))
                    ConnectionLine()
                }
                Spacer()
                MiniWindowButton()
                PowerButton(on: state.power, tint: staleSince == nil ? theme.tint(for: state.mode) : .gray) {
                    model.setPower(!state.power)
                }
            }

            if state.power, state.mode == .fan {
                // Lüften hat kein Temperaturziel: Raumtemperatur groß, kein ± und kein Regler.
                FanModeSummary(tint: tint, look: look, glow: live)
                    .opacity(staleSince == nil ? 1 : 0.5)
            } else if state.power {
                TemperatureStepper(target: state.targetTemperature, spacing: 0) {
                    VStack(spacing: 0) {
                        let big = roomBig ? (state.indoorTemperature ?? 0) : state.targetTemperature
                        Text(model.heroValue)
                            .font(look.font(68))
                            .foregroundStyle(tint)
                            .contentTransition(.numericText(value: big))
                            .heroGlow(tint, active: live)
                            .opacity(staleSince == nil ? 1 : 0.5)
                        Text(model.heroCaption)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    // VoiceOver: „Solltemperatur 26°, Heizt · noch 2,0° bis zum Ziel“ statt einer nackten Zahl.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(roomBig
                        ? "Raumtemperatur \(Fmt.temp(state.indoorTemperature)), Solltemperatur \(Fmt.target(state.targetTemperature)), \(goal)"
                        : "Solltemperatur \(Fmt.target(state.targetTemperature)), \(goal)")
                }

                Slider(value: Binding(
                    get: { state.targetTemperature },
                    set: { v in
                        let t = v.rounded()
                        model.debounced(.temperature) { $0.targetTemperature = t }
                    }), in: UIOptions.temperatureMin...UIOptions.temperatureMax, step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text(Fmt.target(UIOptions.temperatureMin)).font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text(Fmt.target(UIOptions.temperatureMax)).font(.caption2).foregroundStyle(.secondary)
                }
                .tint(tint)
                .accessibilityLabel("Solltemperatur")
                .accessibilityValue(Fmt.num(state.targetTemperature, 0) + " Grad")
            } else {
                OffSummary(staleSince: staleSince, look: look)
            }

            if showReadings { ReadingsStrip(state: state) }
        }
        .padding(16)
        .klimaCard(tint: live ? tint.opacity(0.28) : nil, radius: 20)
    }

    // Der Zieltext („Heizt · noch 1,2° bis zum Ziel“) kommt aus dem Kern (`ACController.goalLine`) – gleiche Logik
    // wie unter Windows.
}

struct ConnectionLine: View {
    @Environment(ACController.self) var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(model.connectionLine).font(.caption).foregroundStyle(.secondary)
            }
            .help(model.connectionTooltip)
            .accessibilityElement(children: .combine)
        }
    }

    /// Grün = letzte Abfrage gelungen, grau = Anlage ausgeschaltet/stromlos (kein Fehler), orange = Verbindungsfehler.
    /// Hinweise zu Befehlen (`notice`) ändern die Zeile nicht – die Anlage antwortet ja.
    private var dot: Color {
        // Ein Zustand aus dem Kern statt Textvergleich: kein Flackern zwischen orange und grau.
        switch model.uiConnectionState {
        case .live: return .green
        case .noConnection: return .orange
        case .deviceOff, .connecting, .notConfigured: return .secondary
        }
    }
}

/// Aus-Zustand: kein toter Regler, sondern Raumlage und ein klarer Weg zum Einschalten.
struct OffSummary: View {
    @Environment(ACController.self) var model
    var staleSince: Date? = nil
    var look = HeroLook()

    var body: some View {
        VStack(spacing: 4) {
            Text(model.heroValue)
                .font(look.font(56))
                .opacity(staleSince == nil ? 1 : 0.5)
            Text(model.heroCaption)
                .font(.callout).foregroundStyle(.secondary)
            Text(model.heroHint ?? "")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Kennzahlen als ruhige Zeile im Kopf statt als eigene Karte.
struct ReadingsStrip: View {
    @Environment(ACController.self) var model
    let state: ACState

    var body: some View {
        // Alte Werte: abgeblendet, und die Leistung fällt weg – eine alte Wattzahl liest sich wie jetzt.
        let stale = model.uiStaleSince != nil
        HStack(spacing: 0) {
            item("thermometer.medium", "Raum", Fmt.temp(state.indoorTemperature), stale: stale)
            if state.power { item("sun.max", "Außen", Fmt.temp(state.outdoorTemperature), stale: stale) }
            if !stale {
                item("bolt", "Leistung", Fmt.watts(state.powerWatts), stale: false)
                    .help(model.powerCostHelp)
            }
            let cost = model.costLine
            item("calendar", cost.title, cost.value, stale: stale)
                .help(cost.help)
        }
    }

    private func item(_ icon: String, _ title: String, _ value: String, stale: Bool) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            Text(value).font(.system(.callout, design: .rounded).weight(.medium).monospacedDigit())
                .foregroundStyle(stale ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct PowerButton: View {
    @Environment(\.klimaTheme) private var theme
    let on: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? theme.label(on: tint) : .primary)
                .frame(width: 44, height: 44)
                .klimaCard(tint: on ? tint : nil, radius: 22, interactive: true)
                // Ganzer Kreis klickbar, nicht nur das Symbol (bei .plain zählt sonst nur der gezeichnete Inhalt).
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // ⌘P liegt im Menü „Anlage“ (AppCommands) – nicht hier, der Knopf steht in Fenster und Menüleiste zugleich.
        .help(on ? "Ausschalten (⌘P)" : "Einschalten (⌘P)")
        .accessibilityLabel(on ? "Ausschalten" : "Einschalten")
    }
}

/// Öffnet das kleine schwebende Fenster (nur Temperatur, Modusfarbe, Ein/Aus).
struct MiniWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "mini") } label: {
            Image(systemName: "pip")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mini-Fenster öffnen")
        .accessibilityLabel("Mini-Fenster öffnen")
    }
}

/// −/+ links und rechts der Temperatur (Hauptfenster und Menüleiste); in der Mitte steht die jeweilige Anzeige.
struct TemperatureStepper<Center: View>: View {
    @Environment(ACController.self) private var model
    let target: Double
    var spacing: CGFloat? = nil
    @ViewBuilder let center: () -> Center

    var body: some View {
        HStack(spacing: spacing) {
            StepButton(symbol: "minus", enabled: target > UIOptions.temperatureMin) { model.nudgeTemperature(by: -1) }
            center()
            StepButton(symbol: "plus", enabled: target < UIOptions.temperatureMax) { model.nudgeTemperature(by: 1) }
        }
    }
}

struct StepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 42)
                .klimaCard(tint: nil, radius: 21, interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        // Kein nacktes ↑/↓ (nimmt ScrollView, Regler und Tastaturnavigation die Pfeile weg und schickt bei
        // jedem Druck einen Befehl): Das Kürzel ⌘↑/⌘↓ liegt im Menü „Anlage“.
        .help(symbol == "plus" ? "Wärmer (⌘↑)" : "Kälter (⌘↓)")
        .accessibilityLabel(symbol == "plus" ? "Wärmer" : "Kälter")
    }
}

// MARK: - Lüften: kein Ziel

struct FanModeSummary: View {
    @Environment(ACController.self) private var model
    let tint: Color
    var look = HeroLook()
    var glow = false

    var body: some View {
        VStack(spacing: 2) {
            Text(model.heroValue)
                .font(look.font(68))
                .foregroundStyle(tint)
                .heroGlow(tint, active: glow)
            Text(model.heroCaption)
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
