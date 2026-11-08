import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Startanzeige

/// Bis die erste Antwort da ist (auch nach einem Startfehler): Name, zuletzt bekannte Werte abgeblendet mit
/// „Stand HH:MM“ (aus dem Verlauf; ohne Verlauf ein Skelett), darunter die Schrittzeile.
struct StartupView: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    var compact = false
    @State private var last: StartupValues?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(compact ? .headline : .title3.weight(.semibold))
                    ConnectionLine()
                }
                Spacer()
            }
            if let last {
                lastValues(last)
            } else if loaded {
                skeleton
            }
            if model.message == nil {
                ConnectSteps()
            }
        }
        .padding(compact ? 0 : 16)
        .modifier(StartupGlass(on: !compact))
        .task {
            last = model.uiLastSample()
            loaded = true
        }
    }

    private var big: CGFloat { compact ? 40 : 56 }

    private func lastValues(_ s: StartupValues) -> some View {
        VStack(spacing: 4) {
            Text(s.main)
                .font(HeroLook(theme).font(big))
                .foregroundStyle(.secondary)
                .opacity(0.6)
            Text(s.caption)
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach(s.extras, id: \.self) { Text($0) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.accessibility)
    }

    private var skeleton: some View {
        VStack(spacing: 6) {
            Text(verbatim: "24°").font(HeroLook(theme).font(big, monospaced: false))
            Text(L.Main.Startup.placeholder).font(.callout)
        }
        .frame(maxWidth: .infinity)
        .redacted(reason: .placeholder)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

private struct StartupGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.klimaCard(tint: nil, radius: 20) } else { content }
    }
}

/// „Anlage suchen ✓ · Anmelden … · Werte lesen“; nach 10 s „Dauert länger als üblich“ und „Erneut versuchen“.
struct ConnectSteps: View {
    @Environment(ACController.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.connectStepsLine).font(.caption).foregroundStyle(.secondary)
            }
            // Der Kern setzt `connectSlow` nach 10 s und beim nächsten Versuch wieder zurück.
            if model.connectSlow {
                HStack(spacing: 8) {
                    Text(UIText.connectSlowText).font(.caption).foregroundStyle(.secondary)
                    Button(UIText.retryButton) { Task { await model.refreshNow() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

}

// MARK: - Kern-Werte für Startanzeige und alte Werte
//
// Dünne Hülle um die Kern-Felder (`staleSince`, `deviceOffNotice` – typisiert über `UserMessage.isDeviceOff` –,
// `connectPhase`, `connectSlow`, `relocate()`, `history.lastSample()`), damit beide Fenster dieselbe Lesart nutzen.

extension ACController {
    /// Zuletzt bekannte Werte aus dem Verlauf (für die Startanzeige), höchstens 7 Tage alt.
    func uiLastSample() -> StartupValues? { startupValues(from: lastKnown ?? history.lastSample(), now: Date()) }
}
