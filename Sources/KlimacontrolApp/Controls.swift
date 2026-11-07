import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Modus

struct ModePicker: View, Equatable {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    /// Nur Ein/Aus und Modus: neue Messwerte rechnen die fünf Glasknöpfe nicht neu.
    let power: Bool
    let mode: OperationalMode

    init(state: ACState) {
        power = state.power
        mode = state.mode
    }

    nonisolated static func == (a: ModePicker, b: ModePicker) -> Bool { a.power == b.power && a.mode == b.mode }
    private let modes: [OperationalMode] = [.cool, .heat, .dry, .fan, .auto]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(modes, id: \.self) { m in
                let selected = power && mode == m
                Button {
                    model.setMode(m)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: m.symbol).font(.system(size: 16, weight: .medium))
                        Text(m.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(selected ? theme.label(on: theme.tint(for: m)) : .primary)
                    .klimaCard(tint: selected ? theme.tint(for: m) : nil, radius: 12, interactive: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(selected ? L.Main.Mode.active(mode: m.title)
                      : (power ? L.Main.Mode.switchTo(mode: m.title) : L.Main.Mode.turnOnWith(mode: m.title)))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(selected ? L.Main.Mode.activeValue : "")
                .accessibilityHint(selected ? ""
                                   : (power ? L.Main.Mode.switchToHint(mode: m.title) : L.Main.Mode.turnOnWithHint(mode: m.title)))
            }
        }
    }
}

// MARK: - Lüfter: Regler 1–100 %, Stufen als Sprungmarken, Auto als eigener Schalter.
// Beim Kühlen und Heizen liegt links von 1 % eine gestrichelte Zone bis „Außengerät leise“ (1 % + Außengerät leise),
// rechts von 100 % gleich lang bis „Turbo“ (100 % + Turbo). Dazwischen springt der Knopf zur näheren Seite.
// Begriff überall „Außengerät leise“, nicht „Leise außen“ (neben der Lüfterstufe „Leise“ missverständlich).

struct FanControl: View, Equatable {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    /// Nur die Werte, die der Lüfter zeigt: neue Messwerte (Raumtemperatur, Leistung …) rechnen ihn nicht neu.
    let state: FanInput

    init(state: ACState) { self.state = FanInput(state) }

    nonisolated static func == (a: FanControl, b: FanControl) -> Bool { a.state == b.state }
    @State private var dragValue: Double?
    /// Ende des letzten Ziehens – so lange zeigt der Knopf noch den gezogenen Wert, bis die Anlage geantwortet hat.
    @State private var dragEnded = Date.distantPast

    /// Zonen schmal (je ~6 % der Spur): so bleibt die Mitte breit, und die Zonen-Symbole passen in die
    /// Zeile der Sprungmarken.
    private static let quietEnd = -6.0, turboEnd = 107.0
    private var locked: Bool { state.mode == .dry }
    private var isAuto: Bool { state.fanSpeed == FanSpeed.auto.rawValue }
    /// „Außengerät leise“ und Turbo wirken nur beim Kühlen und Heizen.
    private var zones: Bool { state.mode == .cool || state.mode == .heat }
    private var lo: Double { zones ? Self.quietEnd : 1 }
    private var hi: Double { zones ? Self.turboEnd : 100 }
    private var quiet: Bool { zones && !isAuto && state.fanSpeed == 1 && state.outSilent == true }
    private var turbo: Bool { zones && !isAuto && state.fanSpeed == 100 && state.turbo }
    /// Das Zonen-Symbol leuchtet, sobald die Funktion an ist – wie die
    /// Kachel im Komfort. Die Zone selbst (1 % bzw. 100 % plus Funktion) bestimmt nur die Lage des Knopfs.
    private var quietOn: Bool { zones && state.outSilent == true }
    private var turboOn: Bool { zones && state.turbo }

    private var value: Double {
        if let dragValue { return dragValue }
        if isAuto { return Double(UIOptions.fanAutoKnob) }
        if quiet { return lo }
        if turbo { return hi }
        return Double(min(100, max(1, state.fanSpeed)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: L.Main.Section.fan, trailing: current)
                Toggle(L.Fan.auto, isOn: Binding(
                    get: { isAuto },
                    set: { on in
                        model.setFan(on ? FanSpeed.auto.rawValue : Int(value.rounded()), now: true)
                    }))
                    .toggleStyle(.button).controlSize(.small)
                    .tint(theme.tint(for: state.mode))
                    .help(UIOptions.fanAutoHelp)
            }
            GeometryReader { geo in
                track(width: geo.size.width)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in drag(to: valueAt(g.location.x, width: geo.size.width)) }
                        .onEnded { _ in endDrag() })
            }
            .frame(height: 22)
            .opacity(isAuto ? 0.45 : 1)
            .accessibilityElement()
            .accessibilityLabel(L.Main.Fan.percentLabel)
            .accessibilityValue(current.replacingOccurrences(of: "%", with: L.Main.Fan.percentWord))
            .accessibilityAdjustableAction { dir in
                let v = Int(value.rounded())
                model.setFan(min(100, max(1, dir == .increment ? v + 10 : v - 10)), now: true)
            }
            // Eine Zeile: Sprungmarken an ihrer Position, die Zonen als Symbole ganz außen (unter den gestrichelten
            // Enden). Der Name der Zone steht im Kopf („Außengerät leise · 1 %“) und im Tooltip.
            GeometryReader { geo in
                let w = geo.size.width
                ForEach(UIOptions.fanMarks, id: \.value) { mark in
                    let on = !isAuto && !quiet && !turbo && state.fanSpeed == mark.value
                    let button = markButton(mark.label, on: on) { model.setFan(mark.value, now: true) }
                    switch mark.value {
                    case 1:
                        button.frame(height: 14).offset(x: x(1, width: w) - 3)
                    case 100:
                        button.frame(height: 14).frame(width: w, alignment: .trailing).offset(x: -(w - x(100, width: w)) + 3)
                    default:
                        button.position(x: x(Double(mark.value), width: w), y: 7)
                    }
                }
                if zones {
                    zoneButton("speaker.slash", L.Options.Fan.quietOutdoor, on: quietOn) { model.setFanQuiet() }
                        .help(UIOptions.fanQuietZoneHelp(on: quietOn))
                        .position(x: 12, y: 7)
                    zoneButton("bolt", L.Options.Fan.turbo, on: turboOn) { model.setFanTurbo() }
                        .help(UIOptions.fanTurboZoneHelp(on: turboOn))
                        .position(x: geo.size.width - 12, y: 7)
                }
            }
            .frame(height: 14)
        }
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
    }

    // MARK: Zeichnen

    /// Knopfradius 10 pt an beiden Enden.
    private func x(_ v: Double, width: CGFloat) -> CGFloat {
        10 + (width - 20) * CGFloat((v - lo) / (hi - lo))
    }

    private func valueAt(_ px: CGFloat, width: CGFloat) -> Double {
        let f = Double((px - 10) / max(1, width - 20))
        return min(hi, max(lo, lo + f * (hi - lo)))
    }

    /// Spur selbst gezeichnet: fest von 1 bis 100 %, gestrichelt in den Zonen; der Teil bis zum Knopf in der Modusfarbe.
    private func track(width: CGFloat) -> some View {
        let tint = theme.tint(for: state.mode)
        let rest = Color.secondary.opacity(0.3)
        let y: CGFloat = 11
        let start = x(1, width: width), end = x(100, width: width)
        let knob = x(value, width: width)
        let inQuiet = value < 1, inTurbo = value > 100
        return ZStack(alignment: .topLeading) {
            line(from: start, to: end, y: y).stroke(rest, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            line(from: start, to: min(max(knob, start), end), y: y)
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if zones {
                line(from: 10, to: start - 5, y: y)
                    .stroke(inQuiet ? tint : rest, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3, 4]))
                line(from: end + 5, to: width - 10, y: y)
                    .stroke(inTurbo ? tint : rest, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3, 4]))
            }
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .frame(width: 20, height: 20)
                .position(x: knob, y: y)
        }
    }

    private func line(from a: CGFloat, to b: CGFloat, y: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: a, y: y)); p.addLine(to: CGPoint(x: max(a, b), y: y)) }
    }

    /// Sprungmarke: Text 13 pt hoch, Trefferfläche aber 22 pt (reicht in den Leerraum darüber und darunter).
    private func markButton(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? theme.tint(for: state.mode) : .secondary)
                .fixedSize()
                .padding(.horizontal, 3)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Zone („Außengerät leise“/„Turbo“) als Symbol am Ende der Markenzeile: aktiv in der Modusfarbe, sonst
    /// `.secondary`. Trefferfläche 22 pt; der Name steht im Tooltip und für VoiceOver.
    private func zoneButton(_ symbol: String, _ name: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AnyShapeStyle(theme.tint(for: state.mode)) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? L.Main.State.on : L.Main.State.off)
    }

    // MARK: Bedienen

    private func drag(to raw: Double) {
        var v = raw
        // Tote Zonen: der Knopf bleibt nie in einer gestrichelten Strecke stehen.
        if zones, v > lo, v < 1 { v = v < (lo + 1) / 2 ? lo : 1 }
        if zones, v > 100, v < hi { v = v > (100 + hi) / 2 ? hi : 100 }
        guard v != dragValue else { return }
        dragValue = v
        // Sammeln, Zonen-Abstand und „Zone verlassen“ regelt der Kern (gleich wie unter Windows).
        if v <= lo, zones { model.setFanQuiet(now: false) }
        else if v >= hi, zones { model.setFanTurbo(now: false) }
        else { model.setFan(Int(v.rounded()), now: false) }
    }

    private func endDrag() {
        dragEnded = Date()
        let ended = dragEnded
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if dragEnded == ended { dragValue = nil }
        }
    }

    private var current: String { UIOptions.fanCaption(state.acState) }
}

/// Eingaben des Lüfterreglers (Teil von `ACState`).
struct FanInput: Equatable, Sendable {
    let mode: OperationalMode
    let fanSpeed: Int
    let outSilent: Bool?
    let turbo: Bool

    init(_ s: ACState) {
        mode = s.mode; fanSpeed = s.fanSpeed; outSilent = s.outSilent; turbo = s.turbo
    }

    /// Zustand mit den Feldern, aus denen der Kern die Kopfzeile bildet.
    var acState: ACState {
        var s = ACState()
        s.mode = mode; s.fanSpeed = fanSpeed; s.outSilent = outSilent; s.turbo = turbo
        return s
    }
}
