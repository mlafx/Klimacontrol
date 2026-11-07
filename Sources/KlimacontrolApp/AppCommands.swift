import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Menüleiste: Tastenkürzel nachschlagbar

/// Menüs „Anlage“ und „Darstellung“ mit den Tastenkürzeln. Verlauf/Diagnose schalten denselben gespeicherten Wert
/// wie die Fußzeile (`@AppStorage`); die Menütitel folgen dem Zustand.
struct AppCommands: Commands {
    let model: ACController
    @AppStorage(SettingsKey.showChartsPanel) private var showCharts = false
    @AppStorage(SettingsKey.showDiagnosticsPanel) private var showDiagnostics = false
    /// Nur im Hauptfenster bzw. Menüleisten-Fenster gesetzt: ⌘↑/⌘↓/⌘P schicken sonst (z. B. in den Textfeldern der
    /// Einstellungen) Befehle an die Anlage.
    @FocusedValue(\.klimacontrolControls) private var controls
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { AppUpdater.shared.checkForUpdates() }
                .disabled(!AppUpdater.shared.canCheck)
        }
        CommandMenu("Anlage") {
            Button(model.state?.power == true ? "Ausschalten" : "Einschalten") {
                guard let on = model.state?.power else { return }
                model.setPower(!on)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model.state == nil || controls != true)
            Divider()
            Button("Wärmer") { model.nudgeTemperature(by: 1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.state?.power != true || controls != true)
            Button("Kälter") { model.nudgeTemperature(by: -1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.state?.power != true || controls != true)
            Divider()
            Button("Jetzt aktualisieren") { Task { await model.refreshNow() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.config == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(showCharts ? "Verlauf ausblenden" : "Verlauf einblenden") { showCharts.toggle() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.config == nil)
            Button(showDiagnostics ? "Diagnose ausblenden" : "Diagnose einblenden") { showDiagnostics.toggle() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.state == nil)
            Divider()
            Button("Mini-Fenster") { openWindow(id: "mini") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle("Immer im Vordergrund", isOn: Binding(get: { model.appearance.alwaysOnTop }, set: { on in
                var a = model.appearance
                a.alwaysOnTop = on
                model.setAppearance(a)
            }))
            Divider()
        }
    }
}
