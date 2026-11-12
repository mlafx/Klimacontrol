import AppKit
import KlimacontrolCore
import SwiftUI

/// Fenster „Neu in Klimacontrol …“ (Szene `whatsnew`): erscheint nach einem Update, solange der Nutzer nicht mit OK
/// bestätigt hat. Schließen ohne OK zeigt es beim nächsten Start erneut.
struct WhatsNewView: View {
    @Environment(ACController.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let notes = model.whatsNew
        VStack(alignment: .leading, spacing: 16) {
            Text(UIText.whatsNewTitle(version: model.appVersion))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(notes, id: \.version) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            if notes.count > 1 {
                                Text(UIText.whatsNewVersionHeading(note.version)).font(.headline)
                            }
                            ForEach(Array(note.sections.enumerated()), id: \.offset) { _, section in
                                VStack(alignment: .leading, spacing: 4) {
                                    if !section.title.isEmpty {
                                        Text(section.title).font(.subheadline.weight(.semibold))
                                    }
                                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            if !section.title.isEmpty { Text("•").accessibilityHidden(true) }
                                            Text(item).fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.callout)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 720)
            HStack {
                Spacer()
                Button(UIText.whatsNewOK) {
                    model.dismissWhatsNew()
                    dismissWindow(id: "whatsnew")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onChange(of: notes.isEmpty) { _, empty in
            if empty { dismissWindow(id: "whatsnew") }
        }
    }
}

/// Öffnet „Neu in dieser Version“, sobald es etwas zu zeigen gibt. Mehrfaches Öffnen holt nur das Fenster nach vorn.
struct WhatsNewOpener: ViewModifier {
    @Environment(ACController.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard !model.whatsNew.isEmpty else { return }
            openWindow(id: "whatsnew")
            NSApp.activate()
        }
    }
}
