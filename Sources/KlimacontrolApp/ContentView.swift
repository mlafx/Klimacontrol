import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Hauptfenster
//
// Reihenfolge nach Häufigkeit: Zustand + Temperatur → Modus → Lüfter → Komfort → Szenen/Timer.
// Verlauf und Diagnose sind eigene Spalten zum Einblenden. Ist die Anlage aus, bleibt nur,
// was zum Einschalten führt (Ein-Knopf, Modus, Szenen, Timer). Nie die ganze Oberfläche skalieren.

enum ColumnRole: Hashable { case history, control, diagnostics }

private struct ColumnRoleKey: LayoutValueKey {
    static let defaultValue = ColumnRole.control
}

/// Verteilt die Breite nach den Regeln des Kerns (`MainWindowLayout`): Steuerung fest, Verlauf links und Diagnose
/// rechts bekommen den Rest. Mindestgröße = Mindestbreiten der gezeigten Spalten, Mindesthöhe nach Darstellungsgröße;
/// die ideale Größe ist die Summe der Mindestbreiten und die Höhe der Steuerspalte.
struct ColumnsLayout: Layout {
    let minHeight: Double
    let topInset: Double

    private func visible(_ subviews: Subviews) -> MainWindowLayout.Visible {
        MainWindowLayout.Visible(history: subviews.contains { $0[ColumnRoleKey.self] == .history },
                                 diagnostics: subviews.contains { $0[ColumnRoleKey.self] == .diagnostics })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let minWidth = MainWindowLayout.minimumWidth(visible(subviews))
        let width = proposal.width.map { max(Double($0), minWidth) } ?? minWidth
        let height: Double
        if let h = proposal.height {
            height = max(Double(h), minHeight)
        } else {
            let control = subviews.first { $0[ColumnRoleKey.self] == .control }
            let ideal = control?.sizeThatFits(ProposedViewSize(width: MainWindowLayout.controlWidth, height: nil)).height ?? 0
            height = max(minHeight, Double(ideal) + topInset)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = MainWindowLayout.widths(total: Double(bounds.width), visible: visible(subviews))
        // Steuerung allein in einem breiten Fenster (maximiert, gekachelt): mittig statt links.
        let lead = w.history == 0 && w.diagnostics == 0 ? w.margin / 2 : 0
        let height = max(0, bounds.height - topInset)
        func place(_ role: ColumnRole, x: Double, width: Double) {
            guard let v = subviews.first(where: { $0[ColumnRoleKey.self] == role }) else { return }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + topInset), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height))
        }
        place(.history, x: 0, width: w.history)
        place(.control, x: lead + w.history, width: w.control)
        place(.diagnostics, x: w.history + w.control, width: w.diagnostics)
    }
}

/// Steuerspalte: Inhalt scrollt, Meldungen und Fußzeile bleiben darunter. Passt der Inhalt, folgt die Fußzeile direkt
/// auf ihn; ist das Fenster niedriger, sitzt sie am unteren Rand.
private struct StickyFooterLayout: Layout {
    let contentHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? MainWindowLayout.controlWidth
        let footer = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let natural = contentHeight + footer
        return CGSize(width: width, height: proposal.height.map { min(natural, max(0, $0)) } ?? natural)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let footer = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let scroll = max(0, min(contentHeight, bounds.height - footer))
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: scroll))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + scroll), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: footer))
    }
}

struct ContentView: View {
    @Environment(ACController.self) var model
    @Environment(WindowRef.self) private var window
    @AppStorage(SettingsKey.showDiagnosticsPanel) private var showDiagnostics = false
    @AppStorage(SettingsKey.showChartsPanel) private var showCharts = false
    @AppStorage(SettingsKey.lastOpenedColumn) private var lastOpenedRaw = ""
    @AppStorage(SettingsKey.columnsBeforeFullScreen) private var beforeFullScreen = ""
    @Environment(\.klimaTheme) private var theme

    /// Was gezeigt wird: gewünschte Spalten, soweit sie auf den Bildschirm passen (Regel im Kern).
    private var resolution: MainWindowLayout.Resolution {
        let configured = model.config != nil
        let wanted = MainWindowLayout.Visible(history: showCharts && configured,
                                              diagnostics: showDiagnostics && configured && model.hasState)
        return MainWindowLayout.resolve(wanted: wanted, available: window.availableWidth,
                                        lastOpened: MainWindowLayout.Column(rawValue: lastOpenedRaw))
    }

    var body: some View {
        let shown = resolution.shown
        let fade: AnyTransition = theme.motionAllowed ? .opacity.animation(.easeOut(duration: 0.2)) : .identity
        ColumnsLayout(minHeight: MainWindowLayout.minimumHeight(model.appearance.size),
                      topInset: window.isFullScreen ? Self.fullScreenTopInset : 0) {
            if shown.history {
                ChartsColumn { SideColumns.set(.history, false) }
                    .environment(model.history)
                    .overlay(alignment: .trailing) { SideDivider() }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(UIText.columnHistory)
                    .layoutValue(key: ColumnRoleKey.self, value: .history)
                    .transition(fade)
            }
            // Glas-Container nur um die Steuerung: Umfasste er auch den Verlauf, rechnete jedes Neuzeichnen der
            // Graphen alle Glasflächen des Fensters neu.
            ControlColumn()
                .modifier(GlassContainer())
                .accessibilityElement(children: .contain)
                .accessibilityLabel(UIText.columnControls)
                .layoutValue(key: ColumnRoleKey.self, value: .control)
            if shown.diagnostics {
                DiagnosticsColumn { SideColumns.set(.diagnostics, false) }
                    .overlay(alignment: .leading) { SideDivider() }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(UIText.columnDiagnostics)
                    .layoutValue(key: ColumnRoleKey.self, value: .diagnostics)
                    .transition(fade)
            }
        }
        // Menü-Kürzel (⌘↑/⌘↓/⌘P) nur, wenn dieses Fenster Key ist – nicht in den Textfeldern der Einstellungen.
        .focusedSceneValue(\.klimacontrolControls, true)
        .focusedSceneValue(\.klimacontrolFullScreen, window.isFullScreen)
        .onChange(of: shown.diagnostics, initial: true) { _, visible in model.diagnosticsVisible = visible }
        .onChange(of: shown) { old, new in window.columnsChanged(from: old, to: new) }
        .onChange(of: shown, initial: true) { _, new in window.setControlsOnly(!new.history && !new.diagnostics) }
        .onChange(of: resolution.hidden, initial: true) { _, hidden in hide(hidden) }
        .onChange(of: model.appearance.size, initial: true) { _, size in
            window.ensureMinimumHeight(MainWindowLayout.minimumHeight(size))
        }
        .onChange(of: window.isFullScreen) { _, full in fullScreenChanged(full) }
        .onAppear { restoreAfterInterruptedFullScreen() }
        // Lebendiger Hintergrund und Wetter-Effekte hinter dem ganzen Fenster (nur, wenn eingeschaltet).
        .background { EffectsBackdrop() }
        .background(VisibilityProbe { model.setUIVisible("main", $0) })
    }

    /// Abstand oben im Vollbild: Die eingeblendete Menüleiste soll nichts verdecken.
    private static let fullScreenTopInset = 24.0

    private func hide(_ hidden: [MainWindowLayout.Column]) {
        for column in hidden {
            SideColumns.set(column, false)
            let text = UIText.columnHidden(column)
            model.showNotice(text)
            AccessibilityNotification.Announcement(text).post()
        }
    }

    /// Im Vollbild sind Verlauf und Diagnose eingeblendet, ohne die Wahl des Nutzers zu ändern.
    private func fullScreenChanged(_ full: Bool) {
        if full {
            beforeFullScreen = (showCharts ? "1" : "0") + "," + (showDiagnostics ? "1" : "0")
            if model.config != nil {
                SideColumns.set(.diagnostics, true)
                SideColumns.set(.history, true)
            }
        } else {
            restoreAfterInterruptedFullScreen()
        }
    }

    private func restoreAfterInterruptedFullScreen() {
        guard !window.isFullScreen, !beforeFullScreen.isEmpty else { return }
        let parts = beforeFullScreen.split(separator: ",")
        beforeFullScreen = ""
        guard parts.count == 2 else { return }
        SideColumns.set(.diagnostics, parts[1] == "1")
        SideColumns.set(.history, parts[0] == "1")
    }
}

private struct SideDivider: View {
    @Environment(\.klimaTheme) private var theme

    var body: some View {
        Rectangle().fill(theme.separator).frame(width: 1).padding(.vertical, 16).accessibilityHidden(true)
    }
}

/// Steuerung (Kopf bis Timer) in einer Scroll-Ansicht, darunter Meldungen und Fußzeile. Dieser Body liest `model.state`
/// nicht – jede Abfrage rechnet nur die Leser-Ansichten darunter neu (LiveColumn, ChartsColumn, DiagnosticsColumn,
/// FooterHost). Die Graphen treiben ihre Zeitscheibe selbst.
private struct ControlColumn: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    @State private var contentHeight: CGFloat = 0

    /// Höhe vor der ersten Messung (Erstgröße des Fensters).
    private static let firstGuess: CGFloat = 760

    var body: some View {
        StickyFooterLayout(contentHeight: contentHeight > 0 ? contentHeight : Self.firstGuess) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.config == nil {
                        SetupView()
                    } else {
                        LiveColumn()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .modifier(ScrollEdgeHint())
            VStack(alignment: .leading, spacing: 12) {
                if let msg = model.uiMessage {
                    MessageBanner(message: msg, quiet: model.uiDeviceOff,
                                  retry: model.lastRefreshFailed ? { Task { await model.refreshNow() } } : nil)
                    RelocateHint()
                }
                if let note = model.noticeMessage {
                    NoticeBanner(message: note)
                }
                FooterHost()
            }
            .lineLimit(3)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
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

/// Weicher Rand unten als Hinweis, dass die Steuerung weiterläuft (macOS 26).
private struct ScrollEdgeHint: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
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
            Text(expanded ? L.Main.More.less : L.Main.More.more).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .accessibilityHint(L.Main.More.hint)
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

/// Diagnose rechts, nur mit Zustand; oben ausgerichtet, scrollt.
private struct DiagnosticsColumn: View {
    @Environment(ACController.self) var model
    let close: () -> Void

    var body: some View {
        if let s = model.state {
            DiagnosticsPanel(state: s, close: close)
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            Color.clear
        }
    }
}

/// Fußzeile: liest nur, ob ein Zustand da ist.
private struct FooterHost: View {
    @Environment(ACController.self) var model
    @AppStorage(SettingsKey.showDiagnosticsPanel) private var showDiagnostics = false
    @AppStorage(SettingsKey.showChartsPanel) private var showCharts = false

    var body: some View {
        FooterView(hasState: model.state != nil, hasConfig: model.config != nil,
                   showDiagnostics: Binding(get: { showDiagnostics }, set: { SideColumns.set(.diagnostics, $0) }),
                   showCharts: Binding(get: { showCharts }, set: { SideColumns.set(.history, $0) }))
    }
}
