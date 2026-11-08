import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Einstellungen → Darstellung

/// Reiter „Darstellung“: Thema (Kacheln), Anzeige, Fenster und Menüleiste; Feinheiten unter „Anpassen“. Jede Änderung wirkt
/// sofort (Live-Vorschau oben und alle Fenster) und wird dauerhaft gespeichert (`ACController.setAppearance`).
struct AppearanceSettings: View {
    @Environment(ACController.self) var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var confirmReset = false
    @AppStorage("appearance.customizeOpen") private var customizeOpen = false

    var body: some View {
        let a = model.appearance
        let reduced = !a.motionAllowed(systemReduceMotion: systemReduceMotion)
        Form {
            Section { AppearancePreview() }

            Section {
                ThemeTiles(selected: a.theme, customized: model.appearanceIsCustomized) { model.applyTheme($0) }
                SettingRow(title: L.Settings.Appearance.Scheme.title, help: L.Settings.Appearance.Scheme.help(computer: HostWords.current.computer)) {
                    Picker(L.Settings.Appearance.Scheme.title, selection: bind(\.scheme)) {
                        ForEach(Appearance.Scheme.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if model.appearanceIsCustomized {
                    SettingRow(title: L.Settings.Appearance.Theme.restore, help: L.Settings.Appearance.Theme.restoreHelp) {
                        Button(L.Settings.Appearance.Theme.restore) { model.applyTheme(a.theme) }
                    }
                }
            } header: {
                Text(L.Settings.Appearance.Theme.title)
            } footer: {
                Text(L.Settings.Appearance.Theme.help).font(.caption).foregroundStyle(.secondary)
            }

            Section(L.Settings.Appearance.Display.section) {
                segmented(L.Settings.Appearance.Size.title, L.Settings.Appearance.Size.help, \.size, Appearance.SizeClass.allCases) { $0.label }
                segmented(L.Settings.Appearance.HeroValue.title, L.Settings.Appearance.HeroValue.help,
                          \.hero, Appearance.HeroValue.allCases) { $0.label }
                segmented(L.Settings.Appearance.Scope.title, L.Settings.Appearance.Scope.help,
                          \.scope, Appearance.Scope.allCases) { $0.label }
            }

            Section(L.Settings.Appearance.WindowMenu.section) {
                toggle(L.Settings.Appearance.AlwaysOnTop.title, L.Settings.Appearance.AlwaysOnTop.help, \.alwaysOnTop)
                SettingRow(title: L.Settings.Appearance.MenuBar.title, help: L.Settings.Appearance.MenuBar.help) {
                    Picker(L.Settings.Appearance.MenuBar.accessibility, selection: bind(\.menuBarText)) {
                        ForEach(Appearance.MenuBarText.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                toggle(L.Settings.Appearance.MenuBarColored.title, L.Settings.Appearance.MenuBarColored.help, \.menuBarColored)
                SettingRow(title: L.Settings.Appearance.Mini.title, help: L.Settings.Appearance.Mac.miniHelp) {
                    Button(L.Settings.Appearance.Mini.open) { openWindow(id: "mini") }
                }
            }

            Section {
                DisclosureGroup(isExpanded: $customizeOpen) {
                    SettingRow(title: L.Settings.Appearance.Colors.title, help: L.Settings.Appearance.Accent.help) {
                        Picker(L.Settings.Appearance.Colors.title, selection: bind(\.accent)) {
                            ForEach(Appearance.Accent.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    if a.accent == .custom {
                        SettingRow(title: L.Settings.Appearance.CustomColor.title, help: L.Settings.Appearance.CustomColor.help) { ColorSwatches(selection: bind(\.customColor)) }
                    }
                    SettingRow(title: L.Settings.Appearance.Background.title, help: L.Settings.Appearance.Background.help) {
                        Picker(L.Settings.Appearance.Background.title, selection: bind(\.background)) {
                            ForEach(Appearance.Background.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    PercentSlider(title: L.Settings.Appearance.Transparency.title, help: L.Settings.Appearance.Transparency.help,
                                  value: bind(\.transparency), range: Appearance.transparencyRange)
                    SettingRow(title: L.Settings.Appearance.Blur.title, help: L.Settings.Appearance.Blur.help) {
                        HStack {
                            Slider(value: bind(\.blur), in: Appearance.blurRange, step: 1).frame(width: 160)
                                .accessibilityLabel(L.Settings.Appearance.Blur.title)
                                .accessibilityValue(L.Settings.Appearance.Accessibility.points(count: Int(a.blur)))
                            Text(L.Settings.Appearance.Unit.points(value: Fmt.num(a.blur, 0))).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                    }
                    PercentSlider(title: L.Settings.Appearance.Glow.title, help: L.Settings.Appearance.Glow.help,
                                  value: bind(\.glow), range: Appearance.glowRange)
                    segmented(L.Settings.Appearance.Digits.title, L.Settings.Appearance.Digits.help, \.digits, Appearance.DigitStyle.allCases) { $0.label }
                    toggle(L.Settings.Appearance.Lively.title, L.Settings.Appearance.Lively.help, \.lively).disabled(reduced)
                    toggle(L.Settings.Appearance.Weather.title, L.Settings.Appearance.Weather.help, \.weather).disabled(reduced)
                    toggle(L.Settings.Appearance.MenuBarAnimated.title, L.Settings.Appearance.MenuBarAnimated.help, \.menuBarAnimated)
                    toggle(L.Settings.Appearance.ReduceMotion.title, L.Settings.Appearance.ReduceMotion.help, \.reduceMotion)
                    if systemReduceMotion {
                        Text(L.Settings.Appearance.Mac.reduceMotionSystem)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    SettingRow(title: L.Settings.Appearance.Customize.title, help: L.Settings.Appearance.Customize.help) { EmptyView() }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(L.Settings.Appearance.Reset.button) { confirmReset = true }
                        .disabled(model.appearanceIsStandard)
                        .confirmationDialog(L.Settings.Appearance.Reset.title, isPresented: $confirmReset) {
                            Button(L.Settings.Appearance.Reset.confirm, role: .destructive) { model.resetAppearance() }
                            Button(L.Common.cancel, role: .cancel) {}
                        } message: {
                            Text(L.Settings.Appearance.Reset.message)
                        }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Ein Feld der Darstellung lesen/ändern; jede Änderung geht über den Kern (prüft, speichert).
    private func bind<T>(_ kp: WritableKeyPath<Appearance, T>) -> Binding<T> {
        Binding(get: { model.appearance[keyPath: kp] }, set: { v in
            var a = model.appearance
            a[keyPath: kp] = v
            model.setAppearance(a)
        })
    }

    private func toggle(_ title: String, _ help: String, _ kp: WritableKeyPath<Appearance, Bool>) -> some View {
        SettingRow(title: title, help: help) {
            Toggle(title, isOn: bind(kp)).labelsHidden().toggleStyle(.switch)
        }
    }

    private func segmented<T: Hashable>(_ title: String, _ help: String, _ kp: WritableKeyPath<Appearance, T>,
                                        _ all: [T], label: @escaping (T) -> String) -> some View {
        SettingRow(title: title, help: help) {
            Picker(title, selection: bind(kp)) {
                ForEach(all, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

/// Fünf Themenkacheln mit Mini-Vorschau im eigenen Aussehen des Themas (ohne Animation und Diagramme).
private struct ThemeTiles: View {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selected: Appearance.Theme
    let customized: Bool
    let choose: (Appearance.Theme) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Appearance.Theme.allCases, id: \.self) { theme in
                tile(theme)
            }
        }
        .padding(.vertical, 2)
    }

    private func tile(_ theme: Appearance.Theme) -> some View {
        let preset = Appearance.preset(theme)
        let scheme: ColorScheme = switch preset.scheme {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
        let style = ThemeStyle(appearance: preset, mode: .cool, colorScheme: scheme, reduceMotion: reduceMotion)
        let on = theme == selected
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { choose(theme) } label: {
            VStack(spacing: 4) {
                Text(Fmt.target(24))
                    .font(style.heroFont(size: 26))
                    .foregroundStyle(style.tint)
                    .klimaGlow(style.tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(theme.label).font(.caption.weight(on ? .semibold : .regular)).foregroundStyle(.primary).lineLimit(1)
                if on && customized {
                    Text(L.Settings.Appearance.Theme.customized).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.horizontal, 4).padding(.vertical, 8)
            .background(shape.fill(style.windowBackground))
            .overlay(shape.strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: on ? 2.5 : 1))
            .contentShape(shape)
            .environment(\.colorScheme, scheme)
            .environment(\.klimaTheme, style)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.label)
        .accessibilityValue(on ? (customized ? "\(L.Settings.Appearance.Theme.selected), \(L.Settings.Appearance.Theme.customized)" : L.Settings.Appearance.Theme.selected) : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Regler 0–100 % mit Zahl daneben.
private struct PercentSlider: View {
    let title: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        SettingRow(title: title, help: help) {
            HStack {
                Slider(value: $value, in: range, step: 0.05).frame(width: 160)
                    .accessibilityLabel(title)
                    .accessibilityValue(L.Settings.Appearance.Accessibility.percent(value: Fmt.num(value * 100, 0)))
                Text(L.Settings.Appearance.Unit.percent(value: Fmt.num(value * 100, 0))).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Fünf Farbtupfer für „Eigene“ Farbe.
private struct ColorSwatches: View {
    @Binding var selection: Appearance.CustomColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Appearance.CustomColor.allCases, id: \.self) { c in
                Button { selection = c } label: {
                    Circle().fill(ThemeStyle.customColor(c)).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selection == c ? 0.8 : 0), lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.label)
                .accessibilityAddTraits(selection == c ? .isSelected : [])
            }
        }
    }
}

// MARK: - Live-Vorschau

/// Kachel oben im Reiter: große Zahl, Karten und Effekte genau wie im Hauptfenster, wahlweise als Kühlen oder Heizen.
/// Liest nur die Darstellung (und einmal die Solltemperatur), nicht jede Abfrage.
private struct AppearancePreview: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    @State private var mode: OperationalMode = .cool

    var body: some View {
        let tint = theme.tint(for: mode)
        let target = model.state?.targetTemperature ?? 24
        let room = model.state?.indoorTemperature
        let heroIsRoom = theme.appearance.hero == .room && room != nil
        VStack(spacing: 10) {
            HStack {
                Text(L.Settings.Appearance.Preview.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker(L.Settings.Appearance.Preview.modePicker, selection: $mode) {
                    Label(OperationalMode.cool.title, systemImage: OperationalMode.cool.symbol).tag(OperationalMode.cool)
                    Label(OperationalMode.heat.title, systemImage: OperationalMode.heat.symbol).tag(OperationalMode.heat)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(heroIsRoom ? Fmt.temp(room) : Fmt.target(target))
                        .font(theme.heroFont(size: 56))
                        .foregroundStyle(tint)
                        .klimaGlow(tint)
                    Text(heroIsRoom ? L.Settings.Appearance.Preview.target(value: Fmt.target(target)) : L.Settings.Appearance.Preview.room(value: Fmt.temp(room)))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    Image(systemName: "power").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.onTint(for: mode))
                        .frame(width: 40, height: 40)
                        .klimaCard(tint: tint, radius: 20, interactive: true)
                    Image(systemName: mode.symbol).font(.system(size: 14, weight: .medium))
                        .frame(width: 40, height: 32)
                        .klimaCard(radius: 10, interactive: true)
                }
            }
            .padding(14 * theme.scale)
            .klimaCard(tint: tint.opacity(0.28), radius: 20)
        }
        .padding(12)
        .background {
            ZStack {
                Rectangle().fill(theme.windowBackground)
                LivelyBackground(active: true, mode: mode)
                WeatherEffect(mode: mode, active: true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.Settings.Appearance.Preview.accessibility)
    }
}

// MARK: - Mini-Fenster

/// Kleines schwebendes Fenster (Szene `mini`): nur Temperatur, Modusfarbe und Ein/Aus. Ziehen am Hintergrund
/// verschiebt es, Doppelklick öffnet das Hauptfenster, ✕ oben links (beim Darüberfahren) schließt es.
struct MiniWindowView: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hover = false

    var body: some View {
        let s = model.state
        let stale = model.uiStaleSince != nil
        let on = s?.power == true
        let tint = on && !stale ? theme.tint(for: s?.mode) : .gray
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        VStack(spacing: 4) {
            Text(model.miniValue)
                .font(theme.heroFont(size: 40))
                .foregroundStyle(on && !stale ? tint : .secondary)
                .klimaGlow(on && !stale ? tint : .clear)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(model.miniCaption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button {
                guard let power = s?.power else { return }
                model.setPower(!power)
            } label: {
                Image(systemName: "power").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? theme.onTint(for: s?.mode) : .primary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .klimaCard(tint: on ? tint : nil, radius: 17, interactive: true)
            .disabled(s == nil)
            .accessibilityLabel(on ? L.Settings.Appearance.Mini.turnOff : L.Settings.Appearance.Mini.turnOn)
        }
        .padding(14)
        .frame(width: 150, height: 150)
        .background(shape.fill(theme.windowBackground))
        .overlay(shape.strokeBorder(tint.opacity(on ? 0.6 : 0.2), lineWidth: on ? 2 : 1))
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            if hover {
                Button { dismissWindow(id: "mini") } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).padding(10)
                .accessibilityLabel(L.Settings.Appearance.Mini.close)
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            openWindow(id: "main")
            NSApp.activate()
        }
        .contextMenu {
            Button(L.Settings.Appearance.Mini.openApp) { openWindow(id: "main"); NSApp.activate() }
            Button(L.Settings.Appearance.Mini.close) { dismissWindow(id: "mini") }
        }
        .accessibilityElement(children: .contain)
        .background(VisibilityProbe { model.setUIVisible("mini", $0) })
    }
}
