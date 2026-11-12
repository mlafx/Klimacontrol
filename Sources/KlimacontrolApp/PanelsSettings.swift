import MideaKit
import KlimacontrolCore
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
