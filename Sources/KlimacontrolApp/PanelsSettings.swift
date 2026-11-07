import MideaKit
import KlimacontrolCore
import ServiceManagement
import SwiftUI

// MARK: - Einstellungen

struct SettingsView: View {
    @Environment(ACController.self) var model

    var body: some View {
        // `.environment(model)` setzt schon die Szene (KlimacontrolApp) – hier nicht noch einmal.
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Darstellung", systemImage: "paintpalette") }
            ConnectionSettings().tabItem { Label("Verbindung", systemImage: "wifi") }
            DeviceSettings().tabItem { Label("Anlage", systemImage: "air.conditioner.horizontal") }
            LogSettings().tabItem { Label("Protokoll", systemImage: "list.bullet.rectangle") }
            NoticesSettings().tabItem { Label("Lizenzen", systemImage: "doc.text") }
        }
        // 600 hoch: Platz für „Adresse neu suchen“ und die Rückmeldezeile unter „Anlage“.
        .frame(width: 580, height: 600)
    }
}

/// Eine Einstellung mit kurzer Erklärung darunter – damit jede Zeile für sich verständlich ist.
struct SettingRow<Control: View>: View {
    let title: String
    let help: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        LabeledContent {
            control()
        } label: {
            Text(title)
            Text(help)
        }
    }
}

/// Rückmeldung einer Aktion direkt an ihrem Ort statt im Banner des Hauptfensters.
struct ActionFeedback: Equatable {
    let text: String
    let ok: Bool

    static func ok(_ text: String) -> ActionFeedback { ActionFeedback(text: text, ok: true) }
    static func failed(_ text: String) -> ActionFeedback { ActionFeedback(text: text, ok: false) }
}

struct FeedbackLine: View {
    let feedback: ActionFeedback

    var body: some View {
        // Farbe nur am Symbol, der Text bleibt gut lesbar (Kontrast).
        Label {
            Text(feedback.text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(feedback.ok ? Color.green : Color.orange)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Allgemein: Name, Strompreis, Start, Aktualisierung, Verlauf

struct GeneralSettings: View {
    @Environment(ACController.self) var model
    @State private var customRefresh = false
    /// Entwurf des Anzeigenamens: übernommen erst bei Return oder Fokusverlust – der Kern bereinigt den Namen
    /// (Leerzeichen am Ende, leer → „Klimaanlage“), bei jedem Tastendruck ließe sich kein Leerzeichen tippen.
    @State private var nameDraft: String?
    @FocusState private var nameFocused: Bool
    @State private var launchAtLogin = LoginItem.enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            displaySection
            refreshSection
            historySection
            startSection
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.enabled }
    }

    @ViewBuilder
    private var displaySection: some View {
        @Bindable var model = model
        Section("Anzeige") {
            SettingRow(title: "Name", help: "Steht im Fenster und in der Menüleiste.") {
                TextField("", text: Binding(get: { nameDraft ?? model.displayName }, set: { nameDraft = $0 }))
                    .frame(width: 200)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    .onDisappear(perform: commitName)
                    .accessibilityLabel("Name der Anlage")
            }
            SettingRow(title: "Strompreis", help: "Für die Kosten in der Übersicht und im Verlauf (gilt auch rückwirkend für den Verlauf).") {
                HStack(spacing: 4) {
                    TextField("", value: $model.pricePerKWh, format: .number.precision(.fractionLength(UIOptions.priceFractionDigitsMin...UIOptions.priceFractionDigitsMax)).locale(Fmt.locale))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                        .accessibilityLabel("Strompreis in Euro je Kilowattstunde")
                    Text("€ je kWh").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var refreshSection: some View {
        @Bindable var model = model
        Section("Aktualisierung") {
            SettingRow(title: "Anlage abfragen alle", help: "Kürzer = aktueller, aber mehr Verkehr zur Anlage.") {
                Picker("Anlage abfragen alle", selection: refreshChoice) {
                    ForEach(UIOptions.refreshChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    Text(UIOptions.refreshCustomLabel).tag(0)
                }
                .labelsHidden().fixedSize()
            }
            if customRefresh || !UIOptions.isRefreshPreset(model.refreshSeconds) {
                SettingRow(title: "Eigener Wert", help: UIOptions.refreshCustomHelp) {
                    HStack(spacing: 6) {
                        TextField("", value: $model.refreshSeconds, format: .number)
                            .frame(width: 50).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Eigener Wert in Sekunden")
                        Stepper("Eigener Wert", value: $model.refreshSeconds, in: UIOptions.refreshMin...UIOptions.refreshMax, step: 1).labelsHidden()
                        Text("s").foregroundStyle(.secondary)
                    }
                }
            }
            if let warning = UIOptions.refreshWarning(forSeconds: model.refreshSeconds) {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        @Bindable var model = model
        Section("Verlauf") {
            SettingRow(title: "Zusätzlich als CSV schreiben",
                       help: "Der Verlauf liegt immer in verlauf.sqlite. Auf Wunsch zusätzlich alle 30 s eine Zeile in verlauf.csv.") {
                Toggle("Zusätzlich als CSV schreiben", isOn: $model.historyCSV).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(title: "Ganzen Verlauf exportieren", help: "Als CSV-Datei mit Ortszeit und deutschen Spalten, z. B. für Numbers oder Excel.") {
                HStack {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([model.history.db.url]) }
                    Button("Exportieren …") { Task { exportFeedback = await model.exportHistoryCSV() } }
                }
            }
            if let exportFeedback { FeedbackLine(feedback: exportFeedback) }
        }
    }

    private var startSection: some View {
        Section("Start") {
            SettingRow(title: "Beim Anmelden starten",
                       help: "Timer und Verlauf laufen nur, solange Klimacontrol geöffnet ist – so startet es mit dem Mac.") {
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in
                        launchError = LoginItem.set(on)
                        let now = LoginItem.enabled
                        if now != on { launchAtLogin = now }
                    }
            }
            if LoginItem.needsApproval {
                HStack {
                    Text("macOS wartet auf deine Zustimmung unter Systemeinstellungen → Allgemein → Anmeldeobjekte.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Öffnen") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let launchError { FeedbackLine(feedback: .failed(launchError)) }
        }
    }

    @State private var exportFeedback: ActionFeedback?

    private func commitName() {
        guard let draft = nameDraft else { return }
        nameDraft = nil
        if draft != model.displayName { model.displayName = draft }
    }

    /// Voreinstellung oder 0 für „Eigener Wert“.
    private var refreshChoice: Binding<Int> {
        Binding(
            get: { customRefresh || !UIOptions.isRefreshPreset(model.refreshSeconds) ? 0 : model.refreshSeconds },
            set: { v in
                customRefresh = v == 0
                if v != 0 { model.refreshSeconds = v }
            })
    }
}

/// Allgemein → Updates. „Update“ = neue Version der App, nicht zu verwechseln mit „Aktualisieren“ (Werte neu lesen).
struct UpdateSettingsSection: View {
    private var updater = AppUpdater.shared

    var body: some View {
        Section("Updates") {
            SettingRow(title: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
                       help: UIText.updatesHelp()) {
                Button(UIText.updatesCheckButton) { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            if let status = updater.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!updater.available)
        if !updater.available {
            Text("Updates gibt es nur in der fertig gebauten App (tools/build_app.sh).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// „Beim Anmelden starten“ über `SMAppService.mainApp` (macOS 13+; die App muss als Bundle laufen).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Fehlertext oder nil.
    @MainActor
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            AppLog.write("Beim Anmelden starten: \(on ? "an" : "aus")")
            return nil
        } catch {
            AppLog.error("Anmeldeobjekt nicht geändert: \(error.localizedDescription)")
            return on
                ? "Klimacontrol ließ sich nicht als Anmeldeobjekt eintragen. In Systemeinstellungen → Allgemein → Anmeldeobjekte von Hand hinzufügen."
                : "Klimacontrol ließ sich nicht austragen. In Systemeinstellungen → Allgemein → Anmeldeobjekte von Hand entfernen."
        }
    }
}

/// Signalton der Anlage (Reiter „Anlage“). Eigene Ansicht, weil sie `model.state` liest: sonst rechnet jede Abfrage
/// das ganze Formular neu.
struct SoundSettingRow: View {
    @Environment(ACController.self) var model

    var body: some View {
        SettingRow(title: "Signalton", help: "Piepen der Anlage bei Befehlen aus dieser App.") {
            Toggle("Signalton", isOn: Binding(get: { model.state?.sound ?? model.beep }, set: { model.setSound($0) }))
                .labelsHidden().toggleStyle(.switch)
        }
        .disabled(model.state == nil)
    }
}

// MARK: Verbindung: Weg, Midea-Konto

struct ConnectionSettings: View {
    @Environment(ACController.self) var model
    @State private var needsAccount = false

    var body: some View {
        Form {
            if let cfg = model.config {
                Section {
                    let status = model.connectionStatus
                    LabeledContent("Status") {
                        Label {
                            Text(status.text)
                        } icon: {
                            Image(systemName: status.connected ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(status.connected ? Color.green : Color.secondary)
                        }
                    }
                    SettingRow(title: "Weg zur Anlage", help: UIText.wayHelp(model.connectionMode)) {
                        Picker("Weg zur Anlage", selection: modeChoice) {
                            ForEach(ConnectionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .disabled(!cfg.hasLAN && !model.cloudConfigured)
                }
                CloudSettings(config: cfg)
            } else {
                Text("Noch keine Anlage eingerichtet – das geht im Hauptfenster.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(UIText.cloudNeedsAccount.title, isPresented: $needsAccount) {
            Button("OK", role: .cancel) {}
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
                LabeledContent("Midea-Konto", value: acc)
                Button("Midea-Konto entfernen …", role: .destructive) { confirmLogout = true }
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
                Text("Erst eine Anlage einrichten – für das Midea-Konto braucht es die Anlagen-ID.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("E-Mail (wie in der App MSmartHome)", text: $account).textContentType(.username)
                SecureField("Passwort", text: $password).textContentType(.password).onSubmit(login)
                HStack {
                    Button(model.cloudLoginRunning ? "Melde an …" : "Anmelden und speichern", action: login)
                        .disabled(model.cloudLoginRunning || account.isEmpty || password.isEmpty)
                    if model.cloudLoginRunning { ProgressView().controlSize(.small) }
                }
            }
            if let result { FeedbackLine(feedback: result) }
        } header: {
            Text("Midea-Konto – Steuerung von unterwegs")
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
