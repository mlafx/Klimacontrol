import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Einrichtung: erst den Weg wählen (Midea-Konto, Zugangsdaten, Sicherung), dann nur dessen kurzer Ablauf.
// Das Midea-Konto ist optional – mit Token und Schlüssel geht es ganz ohne.

struct SetupView: View {
    @Environment(ACController.self) var model

    var body: some View {
        Group {
            switch model.setup.path {
            case .account: AccountSetup()
            case .manual: ManualSetup()
            case .backup, nil: SetupStart()
            }
        }
        // Die WLAN-Suche läuft schon auf der Startseite – beide Wege brauchen die gefundene Anlage.
        .onAppear { if model.setup.discovered.isEmpty && !model.setup.scanning { model.setup.scan() } }
    }
}

// MARK: Startseite

private struct SetupStart: View {
    @Environment(ACController.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "air.conditioner.horizontal").font(.system(size: 30)).foregroundStyle(.tint)
                Text("Wie möchtest du verbinden?").font(.title2.weight(.semibold))
                Text("Klimacontrol steuert die Anlage direkt im WLAN. Dafür braucht es einmalig Token und Schlüssel der Anlage.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            choice("person.crop.circle", "Mit Midea-Konto", recommended: true,
                   "Holt Token und Schlüssel automatisch. Findet die Anlage auch, wenn sie ausgeschaltet ist. Konto und Passwort gehen zur Anmeldung an Midea.") {
                model.setup.choose(.account)
            }
            choice("key", "Zugangsdaten eingeben", recommended: false,
                   "Token und Schlüssel liegen dir schon vor. Keine Verbindung zu Midea, kein Internet nötig.") {
                model.setup.choose(.manual)
            }
            choice("doc.badge.arrow.up", "Sicherung einlesen", recommended: false,
                   "Sicherungsdatei mit den Zugangsdaten, z. B. von einem anderen Rechner. Keine Verbindung zu Midea.") {
                model.importBackup()
            }
            if let err = model.setup.error { MessageBanner(text: err) }
            HStack {
                Spacer()
                SettingsLink { Text("Einstellungen …") }.buttonStyle(.link).font(.caption)
                    .help("Protokoll und Verbindung in den Einstellungen (⌘,)")
            }
        }
    }

    private func choice(_ icon: String, _ title: String, recommended: Bool, _ detail: String,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if recommended {
                            Text("empfohlen").font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .klimaCard(radius: 14, interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Kopf eines Ablaufs: „‹ Zurück“ zur Startseite und Titel.
private struct SetupHeader: View {
    @Environment(ACController.self) var model
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { model.setup.choose(nil) } label: { Label("Zurück", systemImage: "chevron.left") }
                .buttonStyle(.link).font(.callout)
                .keyboardShortcut(.cancelAction)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Nummerierter Abschnitt mit Fehlermeldung darunter (nur beim Abschnitt der zuletzt ausgelösten Aktion).
private struct SetupStep<Content: View>: View {
    @Environment(ACController.self) var model
    let number: Int?
    let title: String
    let showsError: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let number {
                    Text("\(number)").font(.caption.weight(.bold)).frame(width: 20, height: 20)
                        .background(Circle().fill(Color.accentColor.opacity(0.2)))
                }
                Text(title).font(.headline)
            }
            content()
            if showsError, let err = model.setup.error {
                MessageBanner(text: err)
                if model.setup.issue?.showsNetworkHelp == true { LocalNetworkHint() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .klimaCard(radius: 14)
    }
}

/// Findet die Suche nichts, ist oft die macOS-Freigabe „Lokales Netzwerk“ aus – eine verweigerte Freigabe liefert
/// meist nur eine leere Antwort statt eines Fehlers.
private struct LocalNetworkHint: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Nichts gefunden? Prüfe, ob Klimacontrol auf das lokale Netzwerk zugreifen darf, und ob der Mac im selben WLAN wie die Anlage ist (nicht im Gast-WLAN).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Freigabe öffnen") {
                if let url = URL(string: SetupFlow.localNetworkSettingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .help("Öffnet Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk")
        }
    }
}

/// Suchknöpfe (WLAN, Netz) – gleich in beiden Abläufen.
private struct SearchButtons: View {
    @Environment(ACController.self) var model
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onAction(); model.setup.scan()
            } label: {
                Label(model.setup.scanning ? "Suche …" : "Im WLAN suchen", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(model.setup.scanning)
            if model.setup.scanning { ProgressView().controlSize(.small) }
            Button {
                onAction(); model.setup.scanSubnet()
            } label: {
                // Fortschritt „37 von 254“ im Knopf selbst – in 480 px ist neben zwei Knöpfen kein Platz für mehr.
                Label(model.setup.subnetScanning
                      ? model.setup.subnetProgress.map { "\($0.0) von \($0.1)" } ?? "Netz …"
                      : "Netz durchsuchen", systemImage: "network")
                    .monospacedDigit()
            }
            .disabled(model.setup.subnetScanning)
            .help("Fragt jede Adresse deines Netzes einzeln – hilft, wenn die normale Suche nichts findet")
            if model.setup.subnetScanning { ProgressView().controlSize(.small) }
            Spacer()
        }
    }
}

/// Fundliste; `pick` übernimmt eine Anlage.
private struct FoundList: View {
    @Environment(ACController.self) var model
    var lanOnly = false
    let pick: (DiscoveredDevice) -> Void

    var body: some View {
        ForEach(model.setup.discovered.filter { !lanOnly || !$0.isCloudOnly }) { dev in
            let chosen = model.setup.selected == dev
            Button { pick(dev) } label: {
                HStack {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dev.name).font(.callout.weight(.medium))
                        Text(dev.isCloudOnly
                            ? "über Midea-Konto · \(dev.cloudOnline == false ? "ausgeschaltet" : "online")"
                            : "\(dev.ip) · Protokoll V\(dev.version) · SN …\(dev.sn.suffix(8))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .klimaCard(tint: chosen ? .accentColor : nil, radius: 10, interactive: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
        }
    }
}

// MARK: Weg „Mit Midea-Konto“: Konto → Anlage finden → Verbinden

private struct AccountSetup: View {
    @Environment(ACController.self) var model
    @State private var manualIP = ""
    @State private var account = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    /// Schritt der zuletzt ausgelösten Aktion – darunter erscheint die Fehlermeldung.
    @State private var activeStep = 2
    enum Field { case ip, account, password }

    private var needsAccount: Bool { account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "Mit Midea-Konto verbinden",
                        detail: "Klimacontrol holt Token und Schlüssel einmalig über dein Midea-Konto. Gesteuert wird danach im WLAN; unterwegs springt das Konto ein.")
            SetupStep(number: 1, title: "Midea-Konto", showsError: activeStep == 1) { accountStep }
            SetupStep(number: 2, title: "Anlage finden", showsError: activeStep == 2) { findStep }
            SetupStep(number: 3, title: "Verbinden", showsError: activeStep == 3) { connectStep }
        }
        .defaultFocus($focus, .account)
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Das Konto der App MSmartHome. " + HostWords.current.passwordStorage)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("E-Mail", text: $account)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .focused($focus, equals: .account)
                .onSubmit { focus = .password }
            SecureField("Passwort", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .focused($focus, equals: .password)
                // Return: verbinden, sobald das geht – sonst weiter zu Schritt 2.
                .onSubmit { if model.setup.canConnect(account: account, password: password) { connect() } else { focus = .ip } }
        }
    }

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchButtons { activeStep = 2 }
            HStack(spacing: 8) {
                Button {
                    activeStep = 2; model.setup.scanCloud(account: account, password: password)
                } label: {
                    Label(model.setup.cloudScanning ? "Cloud-Suche …" : "In der Cloud suchen", systemImage: "cloud")
                }
                .disabled(model.setup.cloudScanning || needsAccount)
                if model.setup.cloudScanning { ProgressView().controlSize(.small) }
                Spacer()
            }
            // Tooltip auch auf dem Rahmen: Ein ausgegrauter Knopf allein sagt nicht, warum er aus ist.
            .help(needsAccount ? "Erst Schritt 1 ausfüllen" : "Anlagen des Midea-Kontos auflisten – auch ausgeschaltet oder in einem anderen WLAN")
            HStack(spacing: 6) {
                TextField(UIOptions.addressOrHostPrompt, text: $manualIP)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .ip)
                    .onSubmit { activeStep = 2; model.setup.scan(ip: manualIP) }
                Button("Suchen") { activeStep = 2; model.setup.scan(ip: manualIP) }
                    .disabled(manualIP.isEmpty || model.setup.scanning)
            }
            FoundList { model.setup.selected = $0 }
        }
    }

    private var connectStep: some View {
        HStack {
            Button(model.setup.busy ? "Verbinde …" : "Verbinden") { connect() }
                .buttonStyle(.borderedProminent)
                // Return gehört dem Feld, solange eines aktiv ist (eigene onSubmit-Aktionen).
                .keyboardShortcut(focus == nil ? KeyboardShortcut.defaultAction : nil)
                .disabled(!model.setup.canConnect(account: account, password: password))
            if model.setup.busy { ProgressView().controlSize(.small) }
            Text(model.setup.selected?.isCloudOnly == true
                ? "Richtet die Steuerung über das Konto ein"
                : "Holt Token und Schlüssel über das Konto")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func connect() {
        guard model.setup.canConnect(account: account, password: password) else { return }
        activeStep = 3
        let pw = password
        Task {
            if await model.setup.connect(account: account, password: pw) { model.presentSetupCompletion() }
            password = "" // auch nach einem Fehler nicht im Speicher lassen
        }
    }
}

// MARK: Weg „Zugangsdaten eingeben“: Anlage, Anlagen-ID, Token, Schlüssel → Prüfen / Verbinden (ohne Konto)

private struct ManualSetup: View {
    @Environment(ACController.self) var model
    /// Was „Aus Zwischenablage einfügen“ erkannt hat (kurze Bestätigung).
    @State private var pasted: String?
    /// Fehler unter der Anlagen-Auswahl (Suche) oder unter den Zugangsdaten (Prüfen/Verbinden).
    @State private var errorAtSearch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "Zugangsdaten eingeben",
                        detail: "Token und Schlüssel der Anlage liegen dir vor – dann braucht es kein Midea-Konto. Für die Cloud unterwegs lässt sich ein Konto später unter Einstellungen → Verbindung nachtragen.")
            SetupStep(number: 1, title: "Anlage", showsError: errorAtSearch) { deviceStep }
            SetupStep(number: 2, title: "Token und Schlüssel", showsError: !errorAtSearch) { credentialsStep }
            actionRow
        }
    }

    @ViewBuilder
    private var deviceStep: some View {
        @Bindable var setup = model.setup
        let m = model.setup.manual
        VStack(alignment: .leading, spacing: 8) {
            SearchButtons { errorAtSearch = true }
            FoundList(lanOnly: true) { errorAtSearch = false; model.setup.useForManual($0) }
            field("Adresse", problem: m.ip.isEmpty ? nil : m.problems["ip"]) {
                HStack(spacing: 6) {
                    TextField(UIOptions.addressExample, text: $setup.manual.ip).textFieldStyle(.roundedBorder)
                    Text("Port").foregroundStyle(.secondary)
                    TextField(String(UIOptions.defaultPort), text: $setup.manual.port).textFieldStyle(.roundedBorder).frame(width: 64)
                }
            }
            field("Anlagen-ID", problem: m.deviceId.isEmpty ? nil : m.problems["deviceId"]) {
                TextField("aus der Suche (nur Ziffern)", text: $setup.manual.deviceId)
                    .textFieldStyle(.roundedBorder).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var credentialsStep: some View {
        @Bindable var setup = model.setup
        let m = model.setup.manual
        VStack(alignment: .leading, spacing: 8) {
            field("Token", status: count(m.tokenHex.count, of: UIOptions.tokenLength, ok: m.tokenValid)) {
                TextField(UIOptions.tokenPrompt, text: $setup.manual.token, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            field("Schlüssel", status: count(m.keyHex.count, of: UIOptions.keyLength, ok: m.keyValid)) {
                TextField(UIOptions.keyPrompt, text: $setup.manual.key, axis: .vertical)
                    .lineLimit(1...2).textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button {
                    errorAtSearch = false
                    pasted = model.setup.pasteCredentials(NSPasteboard.general.string(forType: .string) ?? "")
                } label: { Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") }
                    .help("Erkennt Token und Schlüssel – auch den ganzen Inhalt einer Sicherungsdatei")
                if let pasted {
                    Text("Übernommen: \(pasted)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let m = model.setup.manual
        HStack(spacing: 8) {
            Button("Testen") { errorAtSearch = false; Task { await model.setup.checkManual() } }
                .disabled(!m.isComplete || model.setup.busy)
                .help("Meldet sich mit diesen Zugangsdaten bei der Anlage an, ohne etwas zu speichern")
            Button(model.setup.busy ? "Verbinde …" : "Verbinden") {
                errorAtSearch = false
                Task { if await model.setup.connectManual() { model.presentSetupCompletion() } }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!m.isComplete || model.setup.busy)
            if model.setup.busy { ProgressView().controlSize(.small) }
            if model.setup.manualCheckOK == true {
                Label {
                    Text("Anlage nimmt die Zugangsdaten an")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.caption)
            }
            Spacer()
        }
    }

    /// Feld mit Beschriftung links und Hinweis darunter (Fehler orange, Zähler grau bzw. grün).
    private func field<C: View>(_ label: String, problem: String? = nil, status: (String, Bool)? = nil,
                                @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                control()
            }
            if let problem {
                // Text in Primärfarbe (WCAG AA), nur das Symbol farbig – wie in den Einstellungen.
                Label {
                    Text(problem).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption).padding(.leading, 80)
            } else if let (text, ok) = status {
                Label {
                    Text(text).foregroundStyle(ok ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                } icon: {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(ok ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .font(.caption).monospacedDigit().padding(.leading, 80)
            }
        }
    }

    private func count(_ n: Int, of total: Int, ok: Bool) -> (String, Bool) {
        (ok ? "\(total) Zeichen" : "\(n) von \(total) Zeichen", ok)
    }
}
