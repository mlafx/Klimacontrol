import Foundation
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Meldungen: Code klein am Ende
//
// Muster „Was ist passiert. Was tun. (Code 3123)“ (AGENTS.md 7.9): Verbindungsfehler kommen in Teilen aus dem Kern
// (`ACController.messageDetail`), Hinweise und Meldungen der Einrichtung als fertige Sätze.

/// Fehler orange mit Warndreieck; `quiet` (Anlage ausgeschaltet/stromlos) ruhig in Grau. `retry` hängt einen Knopf
/// „Erneut versuchen“ an – für Verbindungsfehler, damit niemand bis zur nächsten Abfrage warten muss.
struct MessageBanner: View {
    let message: UserMessage
    var quiet = false
    var retry: (() -> Void)? = nil

    init(message: UserMessage, quiet: Bool = false, retry: (() -> Void)? = nil) {
        self.message = message
        self.quiet = quiet
        self.retry = retry
    }

    /// Fertiger Satz (Einrichtung): nur ein Code am Satzende wird abgetrennt.
    init(text: String, quiet: Bool = false, retry: (() -> Void)? = nil) {
        self.init(message: MessageText.parts(text), quiet: quiet, retry: retry)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Farbe nur am Symbol, der Text bleibt gut lesbar.
            Label {
                MessageText.text(message).foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            } icon: {
                Image(systemName: quiet ? "powersleep" : "exclamationmark.triangle.fill")
                    .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button(UIText.retryButton, action: retry)
                    .buttonStyle(.bordered).controlSize(.small)
                    .help(L.Main.Message.refreshHelp)
            }
        }
        .padding(10)
        .klimaCard(tint: quiet ? nil : .orange.opacity(0.4), radius: 12)
    }
}

/// Hinweis zu einem Befehl (nicht übernommen, Timer, Backup): kein Fehler der Verbindung, darum ruhig und ohne Rahmen.
struct NoticeBanner: View {
    let message: UserMessage

    var body: some View {
        Label { MessageText.text(message) } icon: { Image(systemName: "info.circle") }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .klimaCard(tint: nil, radius: 12)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum MessageText {
    /// Code am Satzende: „(3123)“, „(Code 3123)“, „(Fehler 9999)“ oder kurz ohne Zahl wie „(path-missing)“, „(V2)“.
    private static let trailingCode = try! NSRegularExpression(
        pattern: #"\s*\((?:(?:Code |Fehler )?(\d{3,5})|([A-Za-z][A-Za-z0-9._-]{0,30}))\)\s*$"#)

    /// Fertiger Satz → Teile; nur ein Code am Satzende wird abgetrennt, der Rest bleibt unverändert.
    static func parts(_ s: String) -> UserMessage {
        let ns = s as NSString
        guard let m = trailingCode.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return UserMessage(what: s, todo: "")
        }
        let codeRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
        return UserMessage(what: ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces), todo: "",
                           code: ns.substring(with: codeRange))
    }

    /// Haupttext („Was ist passiert. Was tun.“) mit kleinem, grauem Code am Ende: Zahlen als „(Code 3123)“,
    /// sonst der Code selbst („(path-missing)“).
    static func text(_ m: UserMessage) -> Text {
        let main = m.todo.isEmpty ? m.what : m.what + " " + m.todo
        guard let code = m.code, !code.isEmpty else { return Text(main) }
        let label = code.first?.isNumber == true ? L.Main.Message.codeLabel(code: code) : code
        return Text(main) + Text("  (\(label))").font(.caption2).foregroundColor(.secondary)
    }

    static func text(_ s: String) -> Text { text(parts(s)) }
}

extension ACController {
    /// Verbindungsfehler in Teilen. `messageDetail` gilt, solange es denselben Satz ergibt wie `message`; ein nur als
    /// Text gesetzter Fehler (z. B. „Einrichtung unvollständig“) wird am Satzende zerlegt.
    var uiMessage: UserMessage? {
        guard let message else { return nil }
        if let detail = messageDetail, detail.text == message { return detail }
        return MessageText.parts(message)
    }
}

// MARK: - Adresse neu suchen

/// Bei Verbindungsfehler im WLAN: Adresse der Anlage neu suchen (neuer Router, neue IP) – die Zugangsdaten bleiben.
struct RelocateHint: View {
    @Environment(ACController.self) var model
    @State private var running = false
    @State private var result: Bool?

    var body: some View {
        if model.lastRefreshFailed, !model.uiDeviceOff, model.config?.hasLAN == true {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(resultText).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(running ? L.Main.Relocate.searching : L.Main.Relocate.search) {
                    running = true
                    result = nil
                    Task {
                        result = await model.relocate()
                        running = false
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(running)
                .help(L.Main.Relocate.help)
            }
            .padding(.horizontal, 4)
        }
    }

    private var resultText: String {
        guard result != nil, let text = model.relocateMessage else {
            return L.Main.Relocate.hint
        }
        return text
    }
}
