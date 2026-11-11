import AppKit
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
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
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
            } else if UIText.targetAdjustable(state) {
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
                        ? L.Main.Hero.a11yRoomTarget(room: Fmt.temp(state.indoorTemperature),
                                                     target: Fmt.target(state.targetTemperature), goal: goal)
                        : L.Main.Hero.a11yTarget(target: Fmt.target(state.targetTemperature), goal: goal))
                }

                // Ohne Wertbeschriftungen am Regler: Die Skala darunter muss dieselbe Breite wie die Spur haben.
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { state.targetTemperature },
                        set: { v in
                            let t = v.rounded()
                            model.debounced(.temperature) { $0.targetTemperature = t }
                        }), in: UIOptions.temperatureMin...UIOptions.temperatureMax, step: 1)
                    .tint(tint)
                    .accessibilityLabel(L.Main.Hero.targetTemperature)
                    .accessibilityValue(L.Main.Hero.degrees(value: Fmt.num(state.targetTemperature, 0)))
                    TargetScale(room: state.indoorTemperature)
                        .opacity(staleSince == nil ? 1 : 0.5)
                }
            } else {
                OffSummary(staleSince: staleSince, look: look)
            }

            if showReadings {
                VStack(spacing: 12) {
                    CardDivider()
                    // „Raum“ steht an der Skala bzw. groß (aus, Lüften), darum hier nicht noch einmal.
                    ReadingsStrip(state: state, showRoom: false)
                }
            }
        }
        .padding(16)
        .klimaCard(tint: live ? tint.opacity(0.28) : nil, radius: ThemeStyle.cardRadius)
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

/// Kennzahlen als ruhige Zeile: Name klein über dem Wert, ohne Symbole.
struct ReadingsStrip: View {
    @Environment(ACController.self) var model
    let state: ACState
    /// Raumtemperatur mitzeigen (nicht im Kopf, dort steht sie an der Skala bzw. groß).
    var showRoom = true

    var body: some View {
        // Alte Werte: abgeblendet, und die Leistung fällt weg – eine alte Wattzahl liest sich wie jetzt.
        let stale = model.uiStaleSince != nil
        HStack(alignment: .top, spacing: 12) {
            if showRoom { item(L.Main.Reading.room, Fmt.temp(state.indoorTemperature), stale: stale) }
            if state.power { item(L.Main.Reading.outdoor, Fmt.temp(state.outdoorTemperature), stale: stale) }
            if !stale {
                item(L.Main.Reading.power, Fmt.watts(state.powerWatts), stale: false)
                    .help(model.powerCostHelp)
            }
            let cost = model.costLine
            item(cost.title, cost.value, stale: stale)
                .help(cost.help)
        }
    }

    private func item(_ title: String, _ value: String, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.system(.body, design: .rounded).weight(.medium).monospacedDigit())
                .foregroundStyle(stale ? .secondary : .primary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Beschriftet, damit der Zustand nicht nur an der Farbe hängt.
            HStack(spacing: 6) {
                Image(systemName: "power").font(.system(size: 15, weight: .semibold))
                Text(on ? L.Main.Power.stateOn : L.Main.Power.stateOff).font(.callout.weight(.semibold))
            }
            .foregroundStyle(on ? theme.label(on: tint) : .primary)
            .padding(.leading, 12).padding(.trailing, 16)
            .frame(minHeight: 44)
            .fixedSize()
            .klimaCard(tint: on ? tint : nil, radius: 22, interactive: true)
            // Ganze Kapsel klickbar, nicht nur Symbol und Text (bei .plain zählt sonst nur der gezeichnete Inhalt).
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // ⌘P liegt im Menü „Anlage“ (AppCommands) – nicht hier, der Knopf steht in Fenster und Menüleiste zugleich.
        .help(on ? L.Main.Power.turnOffHelp : L.Main.Power.turnOnHelp)
        .accessibilityLabel(on ? L.Main.Power.turnOff : L.Main.Power.turnOn)
        .accessibilityValue(on ? L.Main.State.on : L.Main.State.off)
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
        .help(L.Main.Mini.open)
        .accessibilityLabel(L.Main.Mini.open)
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
        .help(symbol == "plus" ? L.Main.Step.warmerHelp : L.Main.Step.coolerHelp)
        .accessibilityLabel(symbol == "plus" ? L.Main.Step.warmer : L.Main.Step.cooler)
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

// MARK: - Skala der Solltemperatur

/// Unter dem Regler der Solltemperatur: betonte Striche, Beschriftung der Enden und die Marke der Raumtemperatur.
/// Die Lagen folgen der Knopfmitte des Reglers (Einzug = halbe Knopfbreite, `SliderMetrics`).
struct TargetScale: View {
    @Environment(\.controlSize) private var controlSize
    let room: Double?

    var body: some View {
        ScaleLayout(inset: SliderMetrics.knobInset(controlSize)) {
            ForEach(UIText.temperatureScaleEmphasized, id: \.self) { v in
                Capsule().fill(.secondary).frame(width: 1.5, height: 6)
                    .layoutValue(key: ScaleSlot.self, value: ScaleSlot(value: v, kind: .tick))
            }
            ForEach(UIText.temperatureScaleLabels, id: \.self) { v in
                Text(Fmt.target(v)).font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .layoutValue(key: ScaleSlot.self, value: ScaleSlot(value: v, kind: .label))
            }
            if let room {
                Circle().fill(.primary).frame(width: 7, height: 7)
                    .layoutValue(key: ScaleSlot.self, value: ScaleSlot(value: room, kind: .roomDot))
                Text(UIText.temperatureScaleRoom(room)).font(.caption2.weight(.semibold)).fixedSize()
                    .layoutValue(key: ScaleSlot.self, value: ScaleSlot(value: room, kind: .roomLabel))
            }
        }
        // Verdeckte Beschriftungen legt das Layout außerhalb ab; der Zuschnitt blendet sie aus.
        .clipped()
        // Die Raumtemperatur steht für VoiceOver schon in der Ansage des Kopfs bzw. im Zieltext.
        .accessibilityHidden(true)
    }
}

struct ScaleSlot: LayoutValueKey, Equatable {
    enum Kind { case tick, label, roomDot, roomLabel }
    static let defaultValue = ScaleSlot(value: 0, kind: .tick)
    let value: Double
    let kind: Kind
}

/// Striche und Marke oben, Beschriftungen darunter. Beschriftungen bleiben innerhalb der Breite; eine Wertbeschriftung,
/// die die Raum-Beschriftung berühren würde, entfällt (der Raum hat Vorrang).
struct ScaleLayout: Layout {
    let inset: CGFloat
    private static let markRow: CGFloat = 8
    private static let gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let labels = subviews.filter { [.label, .roomLabel].contains($0[ScaleSlot.self].kind) }
        let height = labels.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 300, height: Self.markRow + 2 + height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func x(_ v: Double) -> CGFloat {
            bounds.minX + inset + (bounds.width - 2 * inset) * CGFloat(UIText.temperatureScaleFraction(v))
        }
        /// Mitte einer Beschriftung: an ihrem Wert, aber nie über den Rand hinaus.
        func center(_ v: Double, width: CGFloat) -> CGFloat {
            min(max(x(v), bounds.minX + width / 2), bounds.maxX - width / 2)
        }
        let labelTop = bounds.minY + Self.markRow + 2
        var roomSpan: ClosedRange<CGFloat>?
        for sv in subviews where sv[ScaleSlot.self].kind == .roomLabel {
            let size = sv.sizeThatFits(.unspecified)
            let c = center(sv[ScaleSlot.self].value, width: size.width)
            roomSpan = (c - size.width / 2 - Self.gap)...(c + size.width / 2 + Self.gap)
            sv.place(at: CGPoint(x: c, y: labelTop), anchor: .top, proposal: ProposedViewSize(size))
        }
        for sv in subviews {
            let slot = sv[ScaleSlot.self]
            let size = sv.sizeThatFits(.unspecified)
            switch slot.kind {
            case .tick:
                sv.place(at: CGPoint(x: x(slot.value), y: bounds.minY), anchor: .top, proposal: ProposedViewSize(size))
            case .roomDot:
                sv.place(at: CGPoint(x: x(slot.value), y: bounds.minY + Self.markRow / 2), anchor: .center,
                         proposal: ProposedViewSize(size))
            case .label:
                let c = center(slot.value, width: size.width)
                let span = (c - size.width / 2)...(c + size.width / 2)
                let hidden = roomSpan?.overlaps(span) ?? false
                sv.place(at: CGPoint(x: hidden ? bounds.minX - 10_000 : c, y: labelTop), anchor: .top,
                         proposal: ProposedViewSize(size))
            case .roomLabel:
                break
            }
        }
    }
}

/// Maße des Reglers: Die Knopfmitte läuft von halber Knopfbreite bis Breite minus halbe Knopfbreite (gemessen am
/// SwiftUI-Regler; die Knopfbreite je Größe liefert AppKit).
@MainActor
enum SliderMetrics {
    private static var cache: [NSControl.ControlSize: CGFloat] = [:]

    static func knobInset(_ size: ControlSize) -> CGFloat {
        let ns: NSControl.ControlSize
        switch size {
        case .mini: ns = .mini
        case .small: ns = .small
        case .regular: ns = .regular
        case .large, .extraLarge: ns = .large
        @unknown default: ns = .regular
        }
        if let hit = cache[ns] { return hit }
        let slider = NSSlider()
        slider.controlSize = ns
        // Wie der Regler der Solltemperatur: mit Strichen (der Knopf hat dann seine schmale Form).
        slider.numberOfTickMarks = Int(UIOptions.temperatureMax - UIOptions.temperatureMin) + 1
        let inset = slider.knobThickness / 2
        cache[ns] = inset
        return inset
    }
}
