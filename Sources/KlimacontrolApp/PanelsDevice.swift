import MideaKit
import KlimacontrolCore
import SwiftUI

struct DeviceSettings: View {
    @Environment(ACController.self) var model
    @State private var confirmForget = false
    @State private var details = false
    @State private var relocating = false
    @State private var relocateResult: ActionFeedback?
    @State private var backupResult: ActionFeedback?

    var body: some View {
        Form {
            if let cfg = model.config {
                Section(L.Settings.Device.section) {
                    // „Name der Anlage“, nicht „Name“: den gibt es unter „Allgemein“ schon (Anzeigename).
                    LabeledContent {
                        Text(cfg.name)
                    } label: {
                        Text(L.Settings.Device.Name.title)
                        Text(L.Settings.Device.Name.help)
                    }
                    // Über das Konto eingerichtet (ip leer, Anlagen-ID gesetzt): Adresse gibt es keine, die ID schon.
                    LabeledContent(L.Setup.Found.address, value: cfg.hasLAN ? cfg.ip : L.Settings.Device.viaAccount)
                    if cfg.deviceId != 0 { relocateRow }
                    SoundSettingRow()
                    DisclosureGroup(L.Settings.Device.Details.title, isExpanded: $details) {
                        if cfg.hasLAN { LabeledContent(L.Setup.Found.port, value: "\(cfg.port)") }
                        if cfg.deviceId != 0 { LabeledContent(L.Setup.Found.applianceId, value: "\(cfg.deviceId)") }
                        LabeledContent(L.Settings.Device.Identifier.title, value: model.deviceIdentifier ?? "–")
                            .help(L.Settings.Device.Identifier.help)
                        LabeledContent(L.Settings.Device.Credentials.title,
                                       value: cfg.hasLAN ? L.Settings.Device.Credentials.stored : L.Settings.Device.Credentials.none)
                    }
                }
                Section {
                    Button(L.Settings.Device.Backup.export) { backupResult = model.exportBackup() }
                    Button(L.Settings.Device.Backup.import) { importBackup() }
                    if let backupResult { FeedbackLine(feedback: backupResult) }
                } header: {
                    Text(L.Settings.Device.Backup.header)
                } footer: {
                    Text(L.Settings.Device.Backup.footer)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(L.Settings.Device.Forget.button, role: .destructive) { confirmForget = true }
                } footer: {
                    Text(L.Settings.Device.Forget.footer)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(L.Settings.Device.noDevice).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(forgetPrompt.title, isPresented: $confirmForget) {
            Button(forgetPrompt.backup) {
                backupResult = model.exportBackup()
                // Gesichert: gleich wieder fragen (erst nach dem Schließen dieses Dialogs, sonst erscheint er nicht erneut).
                if backupResult?.ok == true { Task { @MainActor in confirmForget = true } }
            }
            Button(forgetPrompt.confirm, role: .destructive) { model.forgetDevice() }
            Button(forgetPrompt.cancel, role: .cancel) {}
        } message: {
            Text(forgetPrompt.message)
        }
    }

    private var forgetPrompt: ForgetPrompt { model.forgetPrompt() }

    /// Router-Wechsel, neue IP: Anlage über ihre Anlagen-ID neu suchen, Zugangsdaten bleiben.
    private var relocateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(relocating ? L.Setup.View.searching : L.Settings.Device.Relocate.button) { relocate() }
                    .disabled(relocating)
                if relocating { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(L.Settings.Device.Relocate.help)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let relocateResult { FeedbackLine(feedback: relocateResult) }
        }
    }

    private func relocate() {
        relocating = true
        relocateResult = nil
        Task {
            let ok = await model.relocate()
            relocating = false
            let text = model.relocateMessage ?? ""
            relocateResult = ok ? .ok(text) : .failed(text)
        }
    }

    private func importBackup() {
        backupResult = nil
        Task { backupResult = await model.chooseAndImportBackup() }
    }
}
