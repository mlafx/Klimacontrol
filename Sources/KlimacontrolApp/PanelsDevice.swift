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
                Section("Anlage") {
                    // „Name der Anlage“, nicht „Name“: den gibt es unter „Allgemein“ schon (Anzeigename).
                    LabeledContent {
                        Text(cfg.name)
                    } label: {
                        Text("Name der Anlage")
                        Text("Von Midea vergeben. Der Anzeigename steht unter „Allgemein“.")
                    }
                    // Über das Konto eingerichtet (ip leer, Anlagen-ID gesetzt): Adresse gibt es keine, die ID schon.
                    LabeledContent("Adresse", value: cfg.hasLAN ? cfg.ip : "über Midea-Konto")
                    if cfg.deviceId != 0 { relocateRow }
                    SoundSettingRow()
                    DisclosureGroup("Technische Angaben", isExpanded: $details) {
                        if cfg.hasLAN { LabeledContent("Port", value: "\(cfg.port)") }
                        if cfg.deviceId != 0 { LabeledContent("Anlagen-ID", value: "\(cfg.deviceId)") }
                        LabeledContent("Kennung der Anlage", value: model.deviceIdentifier ?? "–")
                            .help("Eigenschaft 0x00AB der Anlage")
                        LabeledContent("WLAN-Zugangsdaten",
                                       value: cfg.hasLAN ? "gespeichert, nur für dich lesbar" : "keine – Steuerung über das Midea-Konto")
                    }
                }
                Section {
                    Button("Zugangsdaten sichern …") { backupResult = model.exportBackup() }
                    Button("Sicherung einlesen …") { importBackup() }
                    if let backupResult { FeedbackLine(feedback: backupResult) }
                } header: {
                    Text("Sichern und übertragen")
                } footer: {
                    Text("Die Sicherung enthält Token, Schlüssel, Adresse und Szenen – damit lässt sich die Anlage auf einem anderen Rechner ohne Midea-Konto einrichten. Nicht in Cloud-Ordnern (iCloud, OneDrive, Dropbox) ablegen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Anlage neu einrichten …", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("Nur für eine andere Anlage. Nach einem Router-Wechsel oder bei neuer Adresse reicht „Adresse neu suchen“.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Noch keine Anlage eingerichtet – das geht im Hauptfenster.").foregroundStyle(.secondary)
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
                Button(relocating ? "Suche …" : "Adresse neu suchen") { relocate() }
                    .disabled(relocating)
                if relocating { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Nach einem Router-Wechsel oder wenn die Anlage eine neue Adresse hat. Token und Schlüssel bleiben erhalten.")
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
