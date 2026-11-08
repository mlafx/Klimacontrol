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
            GeneralSettings().tabItem { Label(L.Settings.Tabs.general, systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label(L.Settings.Tabs.appearance, systemImage: "paintpalette") }
            ConnectionSettings().tabItem { Label(L.Settings.Tabs.connection, systemImage: "wifi") }
            DeviceSettings().tabItem { Label(L.Settings.Tabs.device, systemImage: "air.conditioner.horizontal") }
            LogSettings().tabItem { Label(L.Settings.Tabs.log, systemImage: "list.bullet.rectangle") }
            NoticesSettings().tabItem { Label(L.Settings.Tabs.notices, systemImage: "doc.text") }
        }
        // 640 hoch: Platz für „Adresse neu suchen“ und die Rückmeldezeile unter „Anlage“ sowie Sprache und Währung
        // unter „Allgemein“; längere englische Texte brechen um.
        .frame(width: 580, height: 640)
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
    @State private var languageChoice = AppRestart.storedChoice()
    @State private var currencyDraft: String?
    @State private var currencyFeedback: ActionFeedback?
    @FocusState private var currencyFocused: Bool

    var body: some View {
        Form {
            languageSection
            displaySection
            refreshSection
            historySection
            startSection
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.enabled }
    }

    private var languageSection: some View {
        Section(L.Settings.Language.title) {
            SettingRow(title: L.Settings.Language.title, help: L.Settings.Language.restartHint) {
                HStack {
                    Picker(L.Settings.Language.title, selection: $languageChoice) {
                        ForEach(LanguageChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel(L.Settings.General.languageAccessibility)
                    .onChange(of: languageChoice) { _, choice in AppRestart.store(choice) }
                    if languageChoice != AppRestart.startChoice, AppRestart.canRelaunch {
                        Button(L.App.restartNow) { AppRestart.relaunch() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var displaySection: some View {
        @Bindable var model = model
        Section(L.Settings.General.sectionDisplay) {
            SettingRow(title: L.Settings.General.nameTitle, help: L.Settings.General.nameHelp) {
                TextField("", text: Binding(get: { nameDraft ?? model.displayName }, set: { nameDraft = $0 }))
                    .frame(width: 200)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    .onDisappear(perform: commitName)
                    .accessibilityLabel(L.Settings.General.nameAccessibility)
            }
            SettingRow(title: L.Settings.General.priceTitle, help: L.Settings.General.priceHelp) {
                HStack(spacing: 4) {
                    TextField("", value: $model.pricePerKWh, format: .number.precision(.fractionLength(UIOptions.priceFractionDigitsMin...UIOptions.priceFractionDigitsMax)).locale(Fmt.locale))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                        .accessibilityLabel(L.Settings.General.priceAccessibility(currency: model.currency))
                    Text(L.Settings.General.pricePerKWh(currency: model.currency)).foregroundStyle(.secondary)
                }
            }
            SettingRow(title: L.Settings.Currency.title, help: L.Settings.General.currencyHelp) {
                TextField("", text: Binding(get: { currencyDraft ?? model.currency }, set: { currencyDraft = $0 }))
                    .frame(width: 50).multilineTextAlignment(.trailing)
                    .focused($currencyFocused)
                    .onSubmit(commitCurrency)
                    .onChange(of: currencyFocused) { _, focused in if !focused { commitCurrency() } }
                    .onDisappear(perform: commitCurrency)
                    .accessibilityLabel(L.Settings.General.currencyAccessibility)
            }
            if let currencyFeedback { FeedbackLine(feedback: currencyFeedback) }
        }
    }

    @ViewBuilder
    private var refreshSection: some View {
        @Bindable var model = model
        Section(L.Settings.General.sectionRefresh) {
            SettingRow(title: L.Settings.General.refreshTitle, help: L.Settings.General.refreshHelp) {
                Picker(L.Settings.General.refreshTitle, selection: refreshChoice) {
                    ForEach(UIOptions.refreshChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    Text(UIOptions.refreshCustomLabel).tag(0)
                }
                .labelsHidden().fixedSize()
            }
            if customRefresh || !UIOptions.isRefreshPreset(model.refreshSeconds) {
                SettingRow(title: L.Settings.General.customTitle, help: UIOptions.refreshCustomHelp) {
                    HStack(spacing: 6) {
                        TextField("", value: $model.refreshSeconds, format: .number)
                            .frame(width: 50).multilineTextAlignment(.trailing)
                            .accessibilityLabel(L.Settings.General.customAccessibility)
                        Stepper(L.Settings.General.customTitle, value: $model.refreshSeconds, in: UIOptions.refreshMin...UIOptions.refreshMax, step: 1).labelsHidden()
                        Text(L.Settings.General.secondsUnit).foregroundStyle(.secondary)
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
        Section(L.Settings.General.sectionHistory) {
            SettingRow(title: L.Settings.General.csvTitle, help: L.Settings.General.csvHelp) {
                Toggle(L.Settings.General.csvTitle, isOn: $model.historyCSV).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(title: L.Settings.General.exportTitle, help: L.Settings.General.exportHelp) {
                HStack {
                    Button(L.Settings.General.Mac.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([model.history.db.url]) }
                    Button(L.Settings.General.exportButton) { Task { exportFeedback = await model.exportHistoryCSV() } }
                }
            }
            if let exportFeedback { FeedbackLine(feedback: exportFeedback) }
        }
    }

    private var startSection: some View {
        Section(L.Settings.General.sectionStart) {
            SettingRow(title: L.Settings.General.Mac.loginTitle, help: L.Settings.General.Mac.loginHelp) {
                Toggle(L.Settings.General.Mac.loginTitle, isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in
                        launchError = LoginItem.set(on)
                        let now = LoginItem.enabled
                        if now != on { launchAtLogin = now }
                    }
            }
            if LoginItem.needsApproval {
                HStack {
                    Text(L.Settings.General.Mac.loginApproval)
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L.Settings.General.Mac.openSettings) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let launchError { FeedbackLine(feedback: .failed(launchError)) }
        }
    }

    @State private var exportFeedback: ActionFeedback?

    private func commitCurrency() {
        guard let draft = currencyDraft else { return }
        currencyDraft = nil
        guard draft != model.currency else { currencyFeedback = nil; return }
        if ACController.validCurrency(draft) != nil {
            model.currency = draft
            currencyFeedback = nil
        } else {
            currencyFeedback = .failed(ACController.currencyHint)
        }
    }

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
    @Environment(ACController.self) private var model
    private var updater = AppUpdater.shared

    var body: some View {
        @Bindable var model = model
        Section(L.Settings.General.updatesSection) {
            SettingRow(title: L.Settings.General.versionTitle(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"),
                       help: UIText.updatesHelp()) {
                Button(UIText.updatesCheckButton) { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            if let status = updater.status {
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if updater.readyVersion != nil {
                        Spacer()
                        Button(L.App.restartNow) { AppRestart.relaunch() }
                    }
                }
            }
            SettingRow(title: L.Settings.Updates.betaChannel, help: L.Updates.Mac.betaHelp) {
                Toggle(L.Settings.Updates.betaChannel, isOn: $model.updateBetaChannel).labelsHidden().toggleStyle(.switch)
                    .onChange(of: model.updateBetaChannel) { _, on in updater.betaChannelChanged(to: on) }
            }
            .help(L.Updates.Mac.betaHelp)
        }
        .disabled(!updater.available)
        if !updater.available {
            Text(L.Updates.Mac.onlyInBundle)
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
            AppLog.write(L.Log.App.loginItem(state: on ? L.Log.Common.on : L.Log.Common.off))
            return nil
        } catch {
            AppLog.error(L.Log.App.loginItemFailed(error: error.localizedDescription))
            return on
                ? L.Settings.General.Mac.loginAddFailed
                : L.Settings.General.Mac.loginRemoveFailed
        }
    }
}

/// Signalton der Anlage (Reiter „Anlage“). Eigene Ansicht, weil sie `model.state` liest: sonst rechnet jede Abfrage
/// das ganze Formular neu.
struct SoundSettingRow: View {
    @Environment(ACController.self) var model

    var body: some View {
        SettingRow(title: L.Settings.General.soundTitle, help: L.Settings.General.soundHelp) {
            Toggle(L.Settings.General.soundTitle, isOn: Binding(get: { model.state?.sound ?? model.beep }, set: { model.setSound($0) }))
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
