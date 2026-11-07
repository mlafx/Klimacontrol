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
                    Label(L.Diagnostics.Panel.title, systemImage: "stethoscope").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help(L.Diagnostics.Panel.hideHelp).accessibilityLabel(L.Diagnostics.Panel.hide)
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
                section(L.Diagnostics.Panel.sectionCompressor, [
                    Row(L.Diagnostics.Panel.power, n(d.compressorPowerW, "W")),
                    Row(L.Diagnostics.Panel.frequency,
                        withTarget(n(d.compressorHz, "Hz"), n(d.compressorTargetHz, "Hz"))),
                    Row(L.Diagnostics.Panel.currentVoltage, n(d.currentA, "A") + " · " + n(d.voltageV, "V"),
                        help: L.Diagnostics.Panel.currentHelp),
                    Row(L.Diagnostics.Panel.outdoorFan, n(d.outdoorFanRpm, rpm)),
                    Row(L.Diagnostics.Panel.defrost, flag(d.defrost, L.Diagnostics.Panel.running, L.Diagnostics.Panel.no)),
                ])
                section(L.Diagnostics.Panel.sectionCircuit, [
                    Row(L.Diagnostics.Panel.t1, t(d.t1IndoorAir)),
                    Row(L.Diagnostics.Panel.indoorSensor2, t(d.indoorTemp2), help: L.Diagnostics.Panel.indoorSensor2Help),
                    Row(L.Diagnostics.Panel.t2(role: heating ? L.Diagnostics.Panel.condenser : L.Diagnostics.Panel.evaporator),
                        t(d.t2IndoorCoil)),
                    Row(L.Diagnostics.Panel.t3(role: heating ? L.Diagnostics.Panel.evaporator : L.Diagnostics.Panel.condenser),
                        t(d.t3OutdoorCoil)),
                    Row(L.Diagnostics.Panel.t4, t(d.t4OutdoorAir)),
                    Row(L.Diagnostics.Panel.tp, n(d.tpDischarge, "°C")),
                    Row(L.Diagnostics.Panel.eev, n(d.eevOpening, L.Diagnostics.Panel.unitSteps), help: L.Diagnostics.Panel.eevHelp),
                ])
                section(L.Diagnostics.Panel.sectionIndoor, [
                    Row(L.Diagnostics.Panel.indoorFan,
                        withTarget(n(d.indoorFanRpm, rpm), n(d.indoorFanTargetRpm, rpm))),
                    Row(L.Diagnostics.Panel.condensatePump, flag(d.condensatePump, L.Diagnostics.Panel.running, L.Common.switchOff)),
                    Row(L.Diagnostics.Panel.filter, UIText.filterValue(alert: state.filterAlert)),
                    Row(L.Diagnostics.Panel.errorCode, UIText.errorCodeValue(state.errorCode),
                        help: L.Diagnostics.Panel.errorCodeHelp),
                    Row(L.Diagnostics.Panel.meter, Fmt.kwh(state.totalEnergyKWh)),
                ])
                HStack {
                    Text(L.Diagnostics.Panel.historyFile).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(L.Diagnostics.Panel.Mac.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([model.history.db.url]) }
                        .buttonStyle(.link).font(.caption2)
                }
            }
        } else {
            Text(L.Diagnostics.Panel.loading).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var heating: Bool { state.mode == .heat }
    private var rpm: String { L.Diagnostics.Panel.unitRpm }

    private func withTarget(_ value: String, _ target: String) -> String {
        L.Diagnostics.Panel.withTarget(value: value, target: target)
    }

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
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
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
