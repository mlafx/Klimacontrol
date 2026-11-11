import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Menüleiste: Tastenkürzel nachschlagbar

/// Menüs „Anlage“ und „Darstellung“ mit den Tastenkürzeln. Verlauf/Diagnose schalten denselben gespeicherten Wert
/// wie die Fußzeile (`@AppStorage`); die Menütitel folgen dem Zustand.
struct AppCommands: Commands {
    let model: ACController
    @AppStorage(SettingsKey.showChartsPanel) private var showCharts = false
    @FocusedValue(\.klimacontrolFullScreen) private var fullScreen
    @AppStorage(SettingsKey.showDiagnosticsPanel) private var showDiagnostics = false
    /// Nur im Hauptfenster bzw. Menüleisten-Fenster gesetzt: ⌘↑/⌘↓/⌘P schicken sonst (z. B. in den Textfeldern der
    /// Einstellungen) Befehle an die Anlage.
    @FocusedValue(\.klimacontrolControls) private var controls
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L.Commands.checkUpdates) { AppUpdater.shared.checkForUpdates() }
                .disabled(!AppUpdater.shared.canCheck)
        }
        CommandMenu(L.Commands.deviceMenu) {
            Button(model.state?.power == true ? L.Commands.powerOff : L.Commands.powerOn) {
                guard let on = model.state?.power else { return }
                model.setPower(!on)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model.state == nil || controls != true)
            Divider()
            Button(L.Commands.warmer) { model.nudgeTemperature(by: 1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!UIText.targetAdjustable(model.state) || controls != true)
            Button(L.Commands.cooler) { model.nudgeTemperature(by: -1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!UIText.targetAdjustable(model.state) || controls != true)
            Divider()
            Button(L.Commands.refreshNow) { Task { await model.refreshNow() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.config == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(showCharts ? L.Commands.hideHistory : L.Commands.showHistory) { SideColumns.toggle(.history) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.config == nil)
            Button(showDiagnostics ? L.Commands.hideDiagnostics : L.Commands.showDiagnostics) { SideColumns.toggle(.diagnostics) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.state == nil)
            Divider()
            Button(L.Commands.miniWindow) { openWindow(id: "mini") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle(L.Commands.alwaysOnTop, isOn: Binding(get: { model.appearance.alwaysOnTop }, set: { on in
                var a = model.appearance
                a.alwaysOnTop = on
                model.setAppearance(a)
            }))
            .disabled(fullScreen == true)
            Divider()
        }
    }
}
