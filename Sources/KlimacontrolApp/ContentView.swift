import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Hauptfenster
//
// Reihenfolge nach Häufigkeit: Zustand + Temperatur → Modus → Lüfter → Komfort → Szenen/Timer.
// Verlauf und Diagnose sind eigene Spalten zum Einblenden. Ist die Anlage aus, bleibt nur,
// was zum Einschalten führt (Ein-Knopf, Modus, Szenen, Timer). Nie die ganze Oberfläche skalieren.

struct ContentView: View {
    @Environment(ACController.self) var model
    @AppStorage(SettingsKey.showDiagnosticsPanel) private var showDiagnostics = false
    @AppStorage(SettingsKey.showChartsPanel) private var showCharts = false
    @Environment(\.klimaTheme) private var theme
    @State private var window = WindowRef()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showCharts, model.config != nil {
                ChartsColumn { showCharts = false }
                    .environment(model.history)
                    .frame(width: 460)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().padding(.vertical, 16)
            }
            // Glas-Container nur um die Steuerung: Umfasste er auch den Verlauf, rechnete jedes Neuzeichnen der
            // Graphen alle Glasflächen des Fensters neu.
            mainColumn
                .frame(width: 480)
                .modifier(GlassContainer())
            if showDiagnostics, model.config != nil {
                DiagnosticsColumn { showDiagnostics = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Menü-Kürzel (⌘↑/⌘↓/⌘P) nur, wenn dieses Fenster Key ist – nicht in den Textfeldern der Einstellungen.
        .focusedSceneValue(\.klimacontrolControls, true)
        .onChange(of: showDiagnostics, initial: true) { _, visible in model.diagnosticsVisible = visible }
        .animation(.snappy(duration: 0.25), value: showDiagnostics)
        .animation(.snappy(duration: 0.25), value: showCharts)
        // Verlauf erscheint links: Fenster um dessen Breite nach links rücken, damit die Steuerung an ihrem Platz
        // bleibt. KeepOnScreen holt es zurück, falls es dabei über den linken Rand ginge.
        .onChange(of: showCharts) { _, visible in
            guard model.config != nil else { return }
            window.shift(by: visible ? -461 : 461)
        }
        // Lebendiger Hintergrund und Wetter-Effekte hinter dem ganzen Fenster (nur, wenn eingeschaltet).
        .background { EffectsBackdrop() }
        .background(WindowReader(ref: window))
        .background(KeepOnScreen())
        .background(VisibilityProbe { model.setUIVisible("main", $0) })
    }

    // Dieser Body liest `model.state` nicht – jede Abfrage rechnet nur die Leser-Ansichten darunter neu
    // (LiveColumn, ChartsColumn, DiagnosticsColumn, FooterHost). Die Graphen treiben ihre Zeitscheibe selbst.
    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.config == nil {
                SetupView()
            } else {
                LiveColumn()
            }
            if let msg = model.uiMessage {
                MessageBanner(message: msg, quiet: model.uiDeviceOff,
                              retry: model.lastRefreshFailed ? { Task { await model.refreshNow() } } : nil)
                RelocateHint()
            }
            if let note = model.noticeMessage {
                NoticeBanner(message: note)
            }
            FooterHost(showDiagnostics: $showDiagnostics, showCharts: $showCharts)
        }
        .padding(20)
        .controlSize(theme.controlSize)
        // VoiceOver: Fehler und Hinweise ansagen (ein gescheiterter Befehl setzt die Anzeige sonst stumm zurück).
        .onChange(of: model.message) { _, text in announce(text) }
        .onChange(of: model.notice) { _, text in announce(text) }
    }

    private func announce(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Steuerung bei vorhandenem Zustand, sonst die Startanzeige. Liest `model.state` – eigene Ansicht, damit eine neue
/// Abfrage nicht das ganze Fenster neu rechnet.
private struct LiveColumn: View {
    @Environment(ACController.self) var model

    var body: some View {
        let simple = model.appearance.scope == .simple
        VStack(alignment: .leading, spacing: 18) {
            if let s = model.state {
                let stale = model.uiStaleSince != nil
                HeroView(state: s, showReadings: !simple)
                MaintenanceHint(state: s)
                ControlStack(state: s, stale: stale, simple: simple)
            } else {
                // Startanzeige (auch bei Startfehler): Name, zuletzt bekannte Werte, Schritte.
                StartupView()
            }
        }
        // Nur Ein/Aus und Umfang animieren (Bereiche erscheinen/verschwinden). Eine Animation auf den ganzen Zustand
        // ließ bei jeder Abfrage alle Glasflächen neu rendern – je ~190 MB Grafikspeicher für eine Sekunde.
        .animation(.snappy(duration: 0.25), value: model.state?.power)
        .animation(.snappy(duration: 0.25), value: simple)
    }
}

/// Bedienung unter dem Kopf, gleich in Hauptfenster und Menüleisten-Fenster: Modus, Lüfter, Komfort, Szenen, Timer.
/// Mehrere Ansichten nebeneinander – der umgebende Stapel setzt seinen Abstand. Die vergleichbaren Teile rechnen nur
/// neu, wenn sich ihre Eingaben ändern (`.equatable()`).
struct ControlStack: View {
    let state: ACState
    let stale: Bool
    let simple: Bool

    var body: some View {
        let s = state
        // Alte Werte: Bedienelemente bleiben benutzbar, sehen aber nicht wie live aus.
        Group {
            ModePicker(state: s).equatable()
            if s.power {
                FanControl(state: s).equatable()
                if !simple { ComfortSection(state: s).equatable() }
            }
        }
        .staleDimmed(stale)
        if simple {
            // Umfang „Einfach“: Ein/Aus, Modus, Temperatur, Lüfter, Timer; der Rest unter „Mehr …“.
            TimerRow(state: s).equatable()
            MoreSection {
                ReadingsStrip(state: s)
                if s.power { ComfortSection(state: s).equatable().staleDimmed(stale) }
                ScenesSection()
            }
        } else {
            ScenesSection()
            TimerRow(state: s).equatable()
        }
    }
}

/// „Mehr …“ beim Umfang „Einfach“: eingeklappt, merkt sich den Zustand. Gleiche Optik wie die Szenen-Überschrift.
struct MoreSection<Content: View>: View {
    @AppStorage(SettingsKey.showMoreControls) private var expanded = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.top, 6)
        } label: {
            Text(expanded ? "Weniger" : "Mehr …").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .accessibilityHint("Zeigt Kennzahlen, Komfort und Szenen")
    }
}

/// Lebendiger Hintergrund und Wetter-Effekte hinter dem Fenster. Liest den Zustand selbst (nicht der Fenster-Body)
/// und reicht nur Modus/„arbeitet“ an eine gleichwertige Ansicht weiter: Neue Messwerte zeichnen nichts neu.
/// Gezeichnet wird nur bei laufender Anlage und erlaubter Bewegung; sichtbares Fenster prüfen die Effekte selbst.
/// Ohne eingeschalteten Effekt entsteht keine Ansicht und kein Zeitgeber.
struct EffectsBackdrop: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme

    var body: some View {
        if theme.livelyEnabled || theme.weatherEnabled {
            let s = model.state
            EffectsLayer(mode: s?.mode, running: model.isWorking,
                         lively: theme.livelyEnabled, weather: theme.weatherEnabled)
                .equatable()
        }
    }
}

private struct EffectsLayer: View, Equatable {
    let mode: OperationalMode?
    let running: Bool
    let lively: Bool
    let weather: Bool

    var body: some View {
        ZStack {
            if lively { LivelyBackground(active: running, mode: mode) }
            if weather { WeatherEffect(mode: mode, active: running) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Verlauf links; reicht nur den Modus (Farbe der Leistungskurve) weiter.
private struct ChartsColumn: View {
    @Environment(ACController.self) var model
    let close: () -> Void

    var body: some View {
        ChartsPanel(mode: model.state?.mode, close: close)
    }
}

/// Diagnose rechts, nur mit Zustand.
private struct DiagnosticsColumn: View {
    @Environment(ACController.self) var model
    let close: () -> Void

    var body: some View {
        if let s = model.state {
            HStack(alignment: .top, spacing: 0) {
                Divider().padding(.vertical, 16)
                DiagnosticsPanel(state: s, close: close)
                    .equatable()
                    .frame(width: 340)
            }
        }
    }
}

/// Fußzeile: liest nur, ob ein Zustand da ist.
private struct FooterHost: View {
    @Environment(ACController.self) var model
    @Binding var showDiagnostics: Bool
    @Binding var showCharts: Bool

    var body: some View {
        FooterView(hasState: model.state != nil, hasConfig: model.config != nil,
                   showDiagnostics: $showDiagnostics, showCharts: $showCharts)
    }
}
