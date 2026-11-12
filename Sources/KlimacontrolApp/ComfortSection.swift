import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Komfort: vier häufige Funktionen als Kacheln, darunter immer sichtbar die weiteren Funktionen

struct ComfortSection: View, Equatable {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    /// Nur die Schalter dieses Abschnitts – Messwerte lassen Kacheln und Glas unangetastet.
    let state: ComfortInput

    init(state: ACState) { self.state = ComfortInput(state) }

    nonisolated static func == (a: ComfortSection, b: ComfortSection) -> Bool { a.state == b.state }
    @State private var confirmSelfClean = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: L.Main.Section.comfort)
            HStack(spacing: 6) {
                tile(L.Main.Comfort.swing, "arrow.up.and.down", state.swing == .vertical, .swing) { on in
                    model.update { $0.swing = on ? .vertical : .off }
                }
                tile(L.Main.Comfort.eco, "leaf", state.eco, .eco) { on in
                    model.setEco(on)
                }
                // Gleiche Bedeutung wie das Symbol am Lüfter: die Funktion selbst, Lüfterstufe bleibt.
                tile(L.Options.Fan.turbo, "bolt", state.turbo, .turbo) { on in
                    model.setTurbo(on)
                }
                tile(L.Options.Fan.quietOutdoor, "speaker.slash", state.outSilent, .outdoorSilent) { on in model.setOutdoorSilent(on) }
            }

            SectionTitle(text: L.Main.Section.moreFeatures).padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    row(L.Main.Comfort.ieco, "gauge.with.dots.needle.33percent", state.ieco, .ieco) { on in model.setIECO(on) }
                    row(L.Main.Comfort.ionizer, "sparkles", state.purifier, .purifier) { on in model.update { $0.purifier = on } }
                    row(L.Main.Comfort.frostProtection, "snowflake.circle", state.freezeProtection, .freezeProtection) { on in
                        model.update { $0.freezeProtection = on }
                    }
                    // Nicht drop.triangle – sieht wie ein Warndreieck aus.
                    row(L.Main.Comfort.selfClean, "bubbles.and.sparkles", state.selfClean, .selfClean) { on in
                        if on { confirmSelfClean = true } else { model.setSelfClean(false) }
                    }
                    row(L.Main.Comfort.display, "rectangle.dashed", state.displayOn, .display) { _ in model.toggleDisplay() }
                    row(L.Main.Comfort.sound, "speaker.wave.2", state.sound ?? model.beep, .sound) { on in model.setSound(on) }
                }
                HStack {
                    Label(L.Main.Comfort.limitPower, systemImage: "gauge.with.dots.needle.67percent").font(.callout)
                    Spacer()
                    Picker(L.Main.Comfort.limitPower, selection: Binding(
                        get: { UIOptions.rateShown(state.ratePercent) },
                        set: { model.setRate($0) })) {
                        ForEach(UIOptions.rateChoices, id: \.self) { Text(L.Main.Comfort.percentChoice(value: "\($0)")).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .padding(.top, 4)
                .help(UIOptions.rateHelp)
            }
        }
        .confirmationDialog(UIText.selfCleanPrompt.title, isPresented: $confirmSelfClean) {
            Button(UIText.selfCleanPrompt.confirm) { model.setSelfClean(true) }
            Button(UIText.selfCleanPrompt.cancel, role: .cancel) {}
        } message: {
            Text(UIText.selfCleanPrompt.message)
        }
    }

    /// Große Kachel (Symbol über Text).
    private func tile(_ title: String, _ icon: String, _ on: Bool?, _ feature: UIOptions.ComfortFeature,
                      _ action: @escaping (Bool) -> Void) -> some View {
        let a = UIOptions.availability(feature, mode: state.mode, capabilities: state.capabilities)
        return switchButton(title, on, enabled: a.enabled, why: a.why, radius: 12, action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
    }

    /// Flache Zeile (Symbol neben Text).
    private func row(_ title: String, _ icon: String, _ on: Bool?, _ feature: UIOptions.ComfortFeature,
                     _ action: @escaping (Bool) -> Void) -> some View {
        let a = UIOptions.availability(feature, mode: state.mode, capabilities: state.capabilities)
        return switchButton(title, on, enabled: a.enabled, why: a.why, radius: 10, action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 16)
                Text(title).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(height: 34)
        }
    }

    /// Gemeinsamer Schalter für Kachel und Zeile: aktiv = in der Modusfarbe getönt.
    /// `on == nil`: Die Anlage hat den Zustand nicht gemeldet – blass, Tooltip/VoiceOver „unbekannt“, ein Klick schaltet ein.
    private func switchButton<Content: View>(_ title: String, _ on: Bool?, enabled: Bool, why: String?, radius: CGFloat,
                                             _ action: @escaping (Bool) -> Void,
                                             @ViewBuilder label: () -> Content) -> some View {
        let active = on == true && enabled
        return Button { action(on != true) } label: {
            label()
                .foregroundStyle(active ? theme.label(on: theme.tint(for: state.mode)) : .primary)
                .klimaCard(tint: active ? theme.tint(for: state.mode) : nil, radius: radius, interactive: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SwitchLook(title: title, on: on, enabled: enabled, why: why))
    }
}

/// Gemeinsames Verhalten der Komfort-Schalter: gesperrt blass, unbekannt halb blass; VoiceOver sagt „ein/aus/unbekannt“
/// und liest den Grund für gesperrte Schalter vor statt ihn nur im Tooltip zu zeigen.
private struct SwitchLook: ViewModifier {
    let title: String
    let on: Bool?
    let enabled: Bool
    let why: String?

    func body(content: Content) -> some View {
        content
            .disabled(!enabled)
            .opacity(!enabled ? 0.38 : on == nil ? 0.6 : 1)
            .help(on == nil && enabled ? L.Main.Comfort.unknownSuffix(text: why ?? title) : (why ?? title))
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on == nil ? L.Common.unknown : on == true ? L.Main.State.on : L.Main.State.off)
            .accessibilityHint(enabled ? "" : (why ?? ""))
    }
}

/// Eingaben des Komfort-Abschnitts (Teil von `ACState`).
struct ComfortInput: Equatable, Sendable {
    let mode: OperationalMode
    let swing: SwingMode
    let eco: Bool
    let turbo: Bool
    let outSilent: Bool?
    let ieco: Bool?
    let purifier: Bool
    let freezeProtection: Bool
    let selfClean: Bool?
    let displayOn: Bool
    let sound: Bool?
    let ratePercent: Int?
    let capabilities: ACCapabilities?

    init(_ s: ACState) {
        mode = s.mode; swing = s.swing; eco = s.eco; turbo = s.turbo; outSilent = s.outSilent; ieco = s.ieco
        purifier = s.purifier; freezeProtection = s.freezeProtection; selfClean = s.selfClean
        displayOn = s.displayOn; sound = s.sound; ratePercent = s.ratePercent; capabilities = s.capabilities
    }
}
