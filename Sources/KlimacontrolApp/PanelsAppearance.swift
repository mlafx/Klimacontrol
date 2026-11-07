import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Einstellungen → Darstellung

/// Reiter „Darstellung“: Thema, Farben, Hintergrund, große Zahl, Bewegung, Fenster, Menüleiste. Jede Änderung wirkt
/// sofort (Live-Vorschau oben und alle Fenster) und wird dauerhaft gespeichert (`ACController.setAppearance`).
struct AppearanceSettings: View {
    @Environment(ACController.self) var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var confirmReset = false

    var body: some View {
        let a = model.appearance
        Form {
            Section { AppearancePreview() }

            Section("Thema") {
                SettingRow(title: "Thema", help: "Setzt alle Werte darunter auf einmal; danach lässt sich jeder einzeln ändern.") {
                    Picker("Thema", selection: Binding(get: { a.theme }, set: { model.applyTheme($0) })) {
                        ForEach(Appearance.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            Section("Farben") {
                SettingRow(title: "Modus", help: "Hell, dunkel oder wie der Mac.") {
                    Picker("Modus", selection: bind(\.scheme)) {
                        ForEach(Appearance.Scheme.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingRow(title: "Farben", help: "Nach Modus: Blau beim Kühlen, Orange beim Heizen usw.") {
                    Picker("Farben", selection: bind(\.accent)) {
                        ForEach(Appearance.Accent.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if a.accent == .custom {
                    SettingRow(title: "Eigene Farbe", help: "Gilt für alle Modi.") { ColorSwatches(selection: bind(\.customColor)) }
                }
            }

            Section("Hintergrund") {
                SettingRow(title: "Hintergrund", help: "Glas lässt den Schreibtisch durchscheinen, Matt ist ruhig und deckend.") {
                    Picker("Hintergrund", selection: bind(\.background)) {
                        ForEach(Appearance.Background.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                PercentSlider(title: "Transparenz", help: "Wie stark Karten und Fenster durchscheinen.",
                              value: bind(\.transparency), range: Appearance.transparencyRange)
                SettingRow(title: "Unschärfe", help: "Wie weich der Hintergrund hinter den Karten verschwimmt.") {
                    HStack {
                        Slider(value: bind(\.blur), in: Appearance.blurRange, step: 1).frame(width: 160)
                            .accessibilityLabel("Unschärfe")
                            .accessibilityValue("\(Int(a.blur)) Punkt")
                        Text("\(Int(a.blur)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Große Temperatur") {
                PercentSlider(title: "Leuchten", help: "Schein in der Modusfarbe um die große Zahl.",
                              value: bind(\.glow), range: Appearance.glowRange)
                segmented("Größe", "Größe der großen Zahl und der Bedienelemente.", \.size, Appearance.SizeClass.allCases) { $0.label }
                segmented("Ziffernstil", "Form der großen Zahl.", \.digits, Appearance.DigitStyle.allCases) { $0.label }
                segmented("Groß angezeigt", "Welche Temperatur groß steht; die andere steht klein darunter.",
                          \.hero, Appearance.HeroValue.allCases) { $0.label }
                segmented("Umfang", "Einfach: nur Ein/Aus, Modus, Temperatur, Lüfter und Timer, der Rest unter „Mehr …“.",
                          \.scope, Appearance.Scope.allCases) { $0.label }
            }

            Section {
                toggle("Lebendiger Hintergrund", "Langsam fließende Farben, solange die Anlage arbeitet.", \.lively)
                    .disabled(!a.motionAllowed(systemReduceMotion: systemReduceMotion))
                toggle("Wetter-Effekte", "Schneeflocken beim Kühlen, aufsteigende Wärme beim Heizen – dezent.", \.weather)
                    .disabled(!a.motionAllowed(systemReduceMotion: systemReduceMotion))
                toggle("Animationen reduzieren", "Schaltet lebendigen Hintergrund und Wetter-Effekte immer ab.", \.reduceMotion)
            } header: {
                Text("Bewegung")
            } footer: {
                if systemReduceMotion {
                    Text("„Bewegung reduzieren“ ist in den Systemeinstellungen eingeschaltet – Effekte bleiben aus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Fenster") {
                toggle("Immer im Vordergrund", "Das Hauptfenster bleibt über anderen Fenstern.", \.alwaysOnTop)
                SettingRow(title: "Mini-Fenster", help: "Kleines schwebendes Fenster mit Temperatur und Ein/Aus (⇧⌘M).") {
                    Button("Öffnen") { openWindow(id: "mini") }
                }
            }

            Section("Menüleiste") {
                SettingRow(title: "Anzeige", help: "Was neben dem Symbol in der Menüleiste steht.") {
                    Picker("Anzeige in der Menüleiste", selection: bind(\.menuBarText)) {
                        ForEach(Appearance.MenuBarText.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                toggle("Symbol farbig", "Symbol in der Modusfarbe statt einfarbig.", \.menuBarColored)
                toggle("Symbol animiert", "Der Lüfter dreht sich, solange die Anlage läuft.", \.menuBarAnimated)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Auf Standard zurücksetzen …") { confirmReset = true }
                        .disabled(model.appearanceIsStandard)
                        .confirmationDialog("Darstellung zurücksetzen?", isPresented: $confirmReset) {
                            Button("Zurücksetzen", role: .destructive) { model.resetAppearance() }
                            Button("Abbrechen", role: .cancel) {}
                        } message: {
                            Text("Alle Werte dieses Reiters kommen auf das gewohnte Aussehen zurück.")
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
                    .accessibilityValue("\(Int((value * 100).rounded())) Prozent")
                Text("\(Int((value * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
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
                Text("Vorschau").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("Vorschau als", selection: $mode) {
                    Label("Kühlen", systemImage: OperationalMode.cool.symbol).tag(OperationalMode.cool)
                    Label("Heizen", systemImage: OperationalMode.heat.symbol).tag(OperationalMode.heat)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(heroIsRoom ? Fmt.temp(room) : Fmt.target(target))
                        .font(theme.heroFont(size: 56))
                        .foregroundStyle(tint)
                        .klimaGlow(tint)
                    Text(heroIsRoom ? "Soll \(Fmt.target(target))" : "Raum \(Fmt.temp(room))")
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
        .accessibilityLabel("Vorschau der Darstellung")
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
            .accessibilityLabel(on ? "Ausschalten" : "Einschalten")
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
                .accessibilityLabel("Mini-Fenster schließen")
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            openWindow(id: "main")
            NSApp.activate()
        }
        .contextMenu {
            Button("Klimacontrol öffnen") { openWindow(id: "main"); NSApp.activate() }
            Button("Mini-Fenster schließen") { dismissWindow(id: "mini") }
        }
        .accessibilityElement(children: .contain)
        .background(VisibilityProbe { model.setUIVisible("mini", $0) })
    }
}
