import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: Verbindung: Weg, Midea-Konto

struct ConnectionSettings: View {
    @Environment(ACController.self) var model
    @State private var needsAccount = false

    var body: some View {
        Form {
            if let cfg = model.config {
                Section {
                    let status = model.connectionStatus
                    LabeledContent(L.Settings.Connection.status) {
                        Label {
                            Text(status.text)
                        } icon: {
                            Image(systemName: status.connected ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(status.connected ? Color.green : Color.secondary)
                        }
                    }
                    SettingRow(title: L.Settings.Connection.wayTitle, help: UIText.wayHelp(model.connectionMode)) {
                        Picker(L.Settings.Connection.wayTitle, selection: modeChoice) {
                            ForEach(ConnectionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .disabled(!cfg.hasLAN && !model.cloudConfigured)
                }
                CloudSettings(config: cfg)
            } else {
                Text(L.Settings.Connection.noDevice).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(UIText.cloudNeedsAccount.title, isPresented: $needsAccount) {
            Button(L.Common.ok, role: .cancel) {}
        } message: {
            Text(UIText.cloudNeedsAccount.message)
        }
    }

    /// „Nur Cloud“ ohne Midea-Konto wird nicht übernommen, sondern erklärt (wie unter Windows).
    private var modeChoice: Binding<ConnectionMode> {
        Binding(get: { model.connectionMode }, set: { mode in
            if mode == .cloud, !model.cloudConfigured { needsAccount = true } else { model.connectionMode = mode }
        })
    }
}

/// Verbindung → Midea-Konto: einmal anmelden, dann ist die Anlage auch unterwegs erreichbar.
struct CloudSettings: View {
    @Environment(ACController.self) var model
    let config: DeviceConfig
    @State private var account = ""
    @State private var password = ""
    @State private var result: ActionFeedback?
    @State private var confirmLogout = false
    private let removePrompt = UIText.accountRemovePrompt()

    var body: some View {
        Section {
            if let acc = model.cloudAccount {
                LabeledContent(L.Settings.Connection.accountTitle, value: acc)
                Button(L.Settings.Connection.accountRemove, role: .destructive) { confirmLogout = true }
                    .confirmationDialog(removePrompt.title, isPresented: $confirmLogout) {
                        Button(removePrompt.confirm, role: .destructive) {
                            model.cloudLogout()
                            result = .ok(UIText.accountRemoved)
                        }
                        Button(removePrompt.cancel, role: .cancel) {}
                    } message: {
                        Text(removePrompt.message)
                    }
            } else if config.deviceId == 0 {
                Text(L.Settings.Connection.needsDevice)
                    .foregroundStyle(.secondary)
            } else {
                TextField(L.Settings.Connection.emailPlaceholder, text: $account).textContentType(.username)
                SecureField(L.Settings.Connection.passwordPlaceholder, text: $password).textContentType(.password).onSubmit(login)
                HStack {
                    Button(model.cloudLoginRunning ? L.Settings.Connection.signingIn : L.Settings.Connection.signIn, action: login)
                        .disabled(model.cloudLoginRunning || account.isEmpty || password.isEmpty)
                    if model.cloudLoginRunning { ProgressView().controlSize(.small) }
                }
            }
            if let result { FeedbackLine(feedback: result) }
        } header: {
            Text(L.Settings.Connection.accountHeader)
        } footer: {
            Text(UIText.accountFooter(signedIn: model.cloudAccount != nil))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func login() {
        guard !model.cloudLoginRunning, !account.isEmpty, !password.isEmpty else { return }
        result = nil
        Task {
            let err = await model.cloudLogin(account: account, password: password)
            password = "" // auch nach einem Fehler nicht im Speicher lassen
            if let err {
                result = .failed(err)
            } else {
                result = .ok(UIText.accountSignedIn)
            }
        }
    }
}
