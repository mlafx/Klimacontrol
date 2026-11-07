import MideaKit
import KlimacontrolCore
import SwiftUI

struct DiagnosticsPanel: View, Equatable {
    @Environment(ACController.self) var model
    /// Nur, was die Tafel aus dem Zustand zeigt; die Messwerte kommen aus `model.diagnostics`.
    let state: DiagnosticsInput
    let close: () -> Void

    init(state: ACState, close: @escaping () -> Void) {
        self.state = DiagnosticsInput(state)
        self.close = close
    }

    /// `close` blendet nur die Tafel aus und ändert sich nicht – darum nicht verglichen.
    nonisolated static func == (a: DiagnosticsPanel, b: DiagnosticsPanel) -> Bool { a.state == b.state }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Diagnose", systemImage: "stethoscope").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Diagnose ausblenden (⌘D)").accessibilityLabel("Diagnose ausblenden")
                }
                NextRefreshLine()
                content
            }
            .padding(20)
        }
        // Volle Diagnose-Abfrage nur, solange die Tafel wirklich zu sehen ist – nicht bei verdecktem oder
        // geschlossenem Fenster. Ein- und Ausblenden der Tafel setzt der Schalter im Hauptfenster.
        .background(VisibilityProbe { visible in model.diagnosticsVisible = visible })
    }

    @ViewBuilder
    private var content: some View {
        if let d = model.diagnostics {
            VStack(alignment: .leading, spacing: 14) {
                section("VERDICHTER · AUSSENGERÄT", [
                    Row("Leistungsaufnahme", n(d.compressorPowerW, "W")),
                    Row("Frequenz", n(d.compressorHz, "Hz") + "  (Soll " + n(d.compressorTargetHz, "Hz") + ")"),
                    Row("Strom · Spannung", n(d.currentA, "A") + " · " + n(d.voltageV, "V"),
                        help: "Die Anlage meldet den Strom nur in ganzen Ampere."),
                    Row("Lüfter außen", n(d.outdoorFanRpm, "U/min")),
                    Row("Abtauen", flag(d.defrost, "läuft", "nein")),
                ])
                section("KÄLTEKREIS", [
                    Row("T1 · Innenluft", t(d.t1IndoorAir)),
                    Row("Innenfühler 2", t(d.indoorTemp2), help: "Zweiter Innenfühler (Eigenschaft 0x00E0)"),
                    Row("T2 · Innenregister (\(heating ? "Verflüssiger" : "Verdampfer"))", t(d.t2IndoorCoil)),
                    Row("T3 · Außenregister (\(heating ? "Verdampfer" : "Verflüssiger"))", t(d.t3OutdoorCoil)),
                    Row("T4 · Außenluft", t(d.t4OutdoorAir)),
                    Row("TP · Heißgasleitung", n(d.tpDischarge, "°C")),
                    Row("EEV-Öffnung", n(d.eevOpening, "Schritte"), help: "Öffnung des elektronischen Expansionsventils"),
                ])
                section("INNENGERÄT", [
                    Row("Lüfter innen", n(d.indoorFanRpm, "U/min") + "  (Soll " + n(d.indoorFanTargetRpm, "U/min") + ")"),
                    Row("Kondensatpumpe", flag(d.condensatePump, "läuft", "aus")),
                    Row("Filter", UIText.filterValue(alert: state.filterAlert)),
                    Row("Fehlercode", UIText.errorCodeValue(state.errorCode),
                        help: "Nummer, wie die Anlage sie meldet. Die Bedeutung steht in der Bedienungsanleitung der Anlage."),
                    Row("Zählerstand", Fmt.kwh(state.totalEnergyKWh)),
                ])
                HStack {
                    Text("Verlauf in verlauf.sqlite").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([model.history.db.url]) }
                        .buttonStyle(.link).font(.caption2)
                }
            }
        } else {
            Text("Diagnosedaten werden geladen …").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var heating: Bool { state.mode == .heat }

    /// Eine Zeile der Tafel; technische Herkunft (Eigenschaftscodes) nur im Tooltip, nicht im Text.
    private struct Row: Identifiable {
        let label: String
        let value: String
        var help: String? = nil
        var id: String { label }

        init(_ label: String, _ value: String, help: String? = nil) {
            self.label = label; self.value = value; self.help = help
        }
    }

    private func section(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack {
                    Text(row.label)
                    Spacer()
                    Text(row.value).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .help(row.help ?? "")
                // VoiceOver liest „Leistungsaufnahme, 412 W“ als eine Einheit statt zwei getrennter Texte.
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func n(_ v: Int?, _ unit: String) -> String {
        v.map { unit.isEmpty ? "\($0)" : "\($0) \(unit)" } ?? "–"
    }

    private func t(_ v: Double?) -> String { v.map { Fmt.num($0, 1) + " °C" } ?? "–" }

    private func flag(_ v: Bool?, _ yes: String, _ no: String) -> String { v.map { $0 ? yes : no } ?? "–" }
}

struct DiagnosticsInput: Equatable, Sendable {
    let mode: OperationalMode
    let filterAlert: Bool
    let errorCode: Int
    let totalEnergyKWh: Double?

    init(_ s: ACState) {
        mode = s.mode; filterAlert = s.filterAlert; errorCode = s.errorCode; totalEnergyKWh = s.totalEnergyKWh
    }
}

/// Ruhiger Hinweis „Filter reinigen“ bzw. Fehlercode der Anlage – für Hauptfenster und Menüleisten-Fenster
/// Zeigt nichts, solange alles in Ordnung ist. Vergleichbar: rechnet nur bei geänderter Meldung neu.
struct MaintenanceHint: View, Equatable {
    let filterAlert: Bool
    let errorCode: Int
    var compact = false

    init(state: ACState, compact: Bool = false) {
        filterAlert = state.filterAlert
        errorCode = state.errorCode
        self.compact = compact
    }

    nonisolated static func == (a: MaintenanceHint, b: MaintenanceHint) -> Bool {
        a.filterAlert == b.filterAlert && a.errorCode == b.errorCode && a.compact == b.compact
    }

    var body: some View {
        if filterAlert || errorCode != 0 {
            VStack(alignment: .leading, spacing: 4) {
                // Reihenfolge des Kerns: erst die Störung (falls vorhanden), dann der Filter.
                ForEach(Array(UIText.maintenanceHints(filterAlert: filterAlert, errorCode: errorCode).enumerated()), id: \.offset) { i, hint in
                    Label(hint, systemImage: errorCode != 0 && i == 0 ? "exclamationmark.circle" : "aqi.medium")
                }
            }
            .font(compact ? .caption : .callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 0 : 10)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Einzige Zeile, die jede Sekunde neu zeichnet. Eigene Ansicht ohne Eingaben: Neuzeichnen der Diagnose
/// (neue Messwerte) startet den Takt nicht neu, und der Takt zeichnet nur diese Zeile.
private struct NextRefreshLine: View {
    @Environment(ACController.self) var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(model.nextRefreshLine)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
