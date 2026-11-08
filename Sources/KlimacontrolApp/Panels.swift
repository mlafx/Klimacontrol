import MideaKit
import KlimacontrolCore
import SwiftUI

// Fußzeile und gemeinsame Bausteine. Meldungen: Messages.swift · Timer: PanelsTimer.swift · Diagnose:
// PanelsDiagnostics.swift · Einstellungen: PanelsSettings.swift, PanelsDevice.swift (Anlage), PanelsLog.swift.

// MARK: - Fußzeile

/// Fußzeile. Bekommt nur zwei Bools statt `model.state`/`model.config` zu lesen – sonst liefe ihr Body bei jeder
/// Abfrage. Die Tastenkürzel ⌘G/⌘D/⌘R liegen im Menü (AppCommands); die Beschriftungen bleiben fest („Verlauf“,
/// „Diagnose“), damit die Zeile beim Umschalten nicht springt – der Zustand steckt im gefüllten Symbol.
struct FooterView: View {
    let hasState: Bool
    let hasConfig: Bool
    @Binding var showDiagnostics: Bool
    @Binding var showCharts: Bool
    @Environment(ACController.self) var model

    var body: some View {
        // Drei Spalten: Verlauf links, Aktualisieren + Einstellungen genau in der Mitte, Diagnose rechts.
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                // Verlauf auch ohne aktuellen Zustand (Anlage nicht erreichbar): die Daten liegen ja vor.
                if hasConfig {
                    Button { showCharts.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sidebar.left").font(.title3).symbolVariant(showCharts ? .fill : .none)
                            Text(L.Main.Footer.history)
                        }
                        .frame(minHeight: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(showCharts ? L.Main.Footer.historyHide : L.Main.Footer.historyShow)
                    .accessibilityAddTraits(showCharts ? .isSelected : [])
                }
                BusySpinner()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                if hasConfig {
                    // refreshNow statt refresh: hebt die Sperren der Wegwahl auf (WLAN nach Fehler, Cloud-Pause bei
                    // ausgeschalteter Anlage) – ein Klick soll wirklich jetzt und über jeden Weg probieren.
                    Button { Task { await model.refreshNow() } } label: {
                        Image(systemName: "arrow.clockwise").font(.title3).frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                        .buttonStyle(.borderless).help(L.Main.Footer.refreshHelp)
                        .accessibilityLabel(L.Main.Footer.refresh)
                }
                SettingsLink { Image(systemName: "gearshape").font(.title3).frame(width: 30, height: 30).contentShape(Rectangle()) }
                    .buttonStyle(.borderless).help(L.Main.Footer.settingsHelp)
                    .accessibilityLabel(L.Main.Footer.settings)
            }

            HStack(spacing: 12) {
                if hasState {
                    Button { showDiagnostics.toggle() } label: {
                        // Symbol rechts vom Text – es zeigt auf die Seite, auf der die Diagnose aufgeht.
                        HStack(spacing: 6) {
                            Text(L.Main.Footer.diagnostics)
                            Image(systemName: "sidebar.right").font(.title3).symbolVariant(showDiagnostics ? .fill : .none)
                        }
                        .frame(minHeight: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(showDiagnostics ? L.Main.Footer.diagnosticsHide : L.Main.Footer.diagnosticsShow)
                    .accessibilityAddTraits(showDiagnostics ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // Symbole groß (Hauptnavigation des Fensters), Beschriftung in normaler Textgröße.
        .imageScale(.large)
    }
}

/// Eigene Ansicht: „beschäftigt“ wechselt bei jeder Abfrage zweimal – das soll nicht die ganze Fußzeile neu rechnen.
private struct BusySpinner: View {
    @Environment(ACController.self) var model

    var body: some View {
        if model.busy { ProgressView().controlSize(.small) }
    }
}

// MARK: - Gemeinsame Bausteine

/// Abschnittsüberschrift – ruhig, klein, einheitlich.
struct SectionTitle: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Alte Werte

extension View {
    /// Bedienelemente bei alten Werten: grau und blasser, aber weiter bedienbar (ein Befehl verbindet neu).
    func staleDimmed(_ stale: Bool) -> some View {
        saturation(stale ? 0 : 1).opacity(stale ? 0.55 : 1)
    }
}
