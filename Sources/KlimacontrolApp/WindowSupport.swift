import AppKit
import KlimacontrolCore
import SwiftUI

// MARK: - Fensterhelfer

/// Meldet, ob das Fenster dieser Ansicht gerade sichtbar ist (offen, nicht verdeckt/minimiert). Ohne sichtbares
/// Fenster fragt der Kern seltener ab.
struct VisibilityProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.onChange = onChange
        return p
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.onChange = onChange }

    static func dismantleNSView(_ nsView: Probe, coordinator: ()) { nsView.report(false) }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [any NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report(false); return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated { self?.report(window?.occlusionState.contains(.visible) ?? false) }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(false) }
                },
            ]
            report(window.occlusionState.contains(.visible))
        }

        func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            onChange?(visible)
        }
    }
}

/// Hält das Fenster des `MenuBarExtra` genau so groß wie seinen Inhalt, mit der Oberkante dort, wo das System es beim
/// Öffnen unter die Menüleiste gesetzt hat. Das Fenster folgt dem Inhalt selbst nur beim Wachsen; wird der Inhalt
/// kürzer (Anlage aus, Szenen zu, Umfang „Einfach“), bleibt es zu hoch, der Inhalt rutscht an den unteren Rand und
/// die Glasfläche des Fensters steht leer darüber. `size` ist die gemessene Inhaltsgröße; das Fenster folgt ihr nur,
/// die Messung hängt nicht von der Fenstergröße ab.
struct MenuBarWindowFitter: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> Fitter { Fitter() }

    func updateNSView(_ nsView: Fitter, context: Context) {
        guard nsView.size != size else { return }
        nsView.size = size
        nsView.scheduleFit()
    }

    final class Fitter: NSView {
        var size: CGSize = .zero
        /// Oberkante beim Öffnen; eigene Größenänderungen verschieben sie nicht.
        private var top: CGFloat?
        private var pending = false
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            top = nil
            guard let window else { return }
            observers = [
                // Das Menüleisten-Fenster wird beim Schließen nur ausgeblendet; beim nächsten Öffnen setzt das System
                // es neu unter das Symbol. Darum die Oberkante je Öffnen neu merken.
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        if window.occlusionState.contains(.visible) {
                            if self.top == nil { self.top = window.frame.maxY }
                            self.scheduleFit()
                        } else if !window.isVisible {
                            self.top = nil
                        }
                    }
                },
            ]
            if window.isVisible { top = window.frame.maxY }
            scheduleFit()
        }

        /// Nicht während der Aktualisierung der Ansicht: `setFrame` löst sofort ein neues Layout aus.
        func scheduleFit() {
            guard !pending else { return }
            pending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending = false
                self.fit()
            }
        }

        private func fit() {
            guard let window, window.isVisible, size.width > 0, size.height > 0 else { return }
            let current = window.frame
            let anchor = top ?? current.maxY
            var target = window.frameRect(forContentRect: NSRect(origin: current.origin, size: size))
            target.origin.x = current.minX
            target.origin.y = anchor - target.height
            guard abs(target.height - current.height) > 0.5 || abs(target.width - current.width) > 0.5
                || abs(target.maxY - current.maxY) > 0.5 else { return }
            window.setFrame(target, display: true, animate: false)
            // Randloses Fenster: ohne neu berechneten Schatten bliebe der Umriss der alten Größe stehen.
            window.invalidateShadow()
        }
    }
}

/// Zustand und Rahmenlogik des Hauptfensters. Alle Rahmenänderungen beim Ein- und Ausblenden der Seitenspalten laufen
/// hier; die Rechnung selbst steht im Kern (`MainWindowFrame`).
@MainActor
@Observable
final class WindowRef {
    @ObservationIgnored private(set) weak var window: NSWindow?
    /// Von „Vollbild erreicht“ bis „Verlassen beginnt“.
    private(set) var isFullScreen = false
    /// Das Fenster ändert gerade seine Größe (Ziehen, Zoomen, Übergänge); Graphen zeichnen dann nicht neu.
    private(set) var isResizing = false
    /// Breite, die den Spalten zur Verfügung steht: Bildschirm, bei maximierten oder gekachelten Fenstern die Fensterbreite.
    private(set) var availableWidth = 100_000.0

    @ObservationIgnored private var inTransition = false
    @ObservationIgnored private var liveResizing = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var stableFrame: CGRect?
    @ObservationIgnored private var grown: [MainWindowLayout.Column: Double] = [:]
    @ObservationIgnored private var grownFrame: CGRect?
    @ObservationIgnored private var frameBeforeFullScreen: CGRect?
    @ObservationIgnored private var controlsOnly = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    func attach(_ new: NSWindow?) {
        guard new !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = new
        guard let w = new else { return }
        if w.styleMask.contains(.resizable) { w.collectionBehavior.insert(.fullScreenPrimary) }
        stableFrame = w.frame
        refreshAvailable()
        enforceControlsOnlyWidth()
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, _ action: @escaping @MainActor (WindowRef, NSWindow) -> Void) {
            observers.append(center.addObserver(forName: name, object: w, queue: .main) { [weak self, weak w] _ in
                MainActor.assumeIsolated { if let self, let w { action(self, w) } }
            })
        }
        watch(NSWindow.willEnterFullScreenNotification) { r, w in
            r.frameBeforeFullScreen = r.stableFrame ?? w.frame
            r.inTransition = true
        }
        watch(NSWindow.didEnterFullScreenNotification) { r, _ in
            r.inTransition = false
            r.isFullScreen = true
            r.refreshAvailable()
        }
        watch(NSWindow.willExitFullScreenNotification) { r, _ in
            r.inTransition = true
            r.isFullScreen = false
        }
        watch(NSWindow.didExitFullScreenNotification) { r, w in
            r.inTransition = false
            r.restoreFrameAfterFullScreen(w)
            r.refreshAvailable()
        }
        watch(NSWindow.willStartLiveResizeNotification) { r, _ in
            r.liveResizing = true
            r.setResizing(true)
        }
        watch(NSWindow.didEndLiveResizeNotification) { r, w in
            r.liveResizing = false
            r.settle(w)
        }
        watch(NSWindow.didResizeNotification) { r, w in
            r.setResizing(true)
            guard !r.liveResizing else { return }
            r.settleTask?.cancel()
            r.settleTask = Task { [weak r, weak w] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let r, let w else { return }
                r.settle(w)
            }
        }
        watch(NSWindow.didMoveNotification) { r, w in
            guard !r.isResizing, !r.inTransition, !w.styleMask.contains(.fullScreen) else { return }
            r.stableFrame = w.frame
            r.refreshAvailable()
        }
        watch(NSWindow.didChangeScreenNotification) { r, _ in r.refreshAvailable() }
    }

    private func setResizing(_ on: Bool) {
        if isResizing != on { isResizing = on }
    }

    private func settle(_ w: NSWindow) {
        setResizing(false)
        guard !inTransition, !w.styleMask.contains(.fullScreen) else { return }
        stableFrame = w.frame
        // Hat der Nutzer die Breite geändert, gehört sie ihm: nichts davon später zurücknehmen.
        if let g = grownFrame, abs(g.width - w.frame.width) > 2 {
            grown = [:]
            grownFrame = nil
        }
        refreshAvailable()
    }

    private func refreshAvailable() {
        guard let w = window, let screen = w.screen else { return }
        let width: Double
        if w.styleMask.contains(.fullScreen) || isFullScreen {
            width = screen.frame.width
        } else if w.isZoomed || MainWindowFrame.isConstrained(w.frame, screen: screen.visibleFrame) {
            width = w.frame.width
        } else {
            width = screen.visibleFrame.width
        }
        if width != availableWidth { availableWidth = width }
    }

    /// Frei veränderbar: weder Vollbild noch Übergang noch maximiert oder gekachelt.
    private func isFree(_ w: NSWindow) -> Bool {
        guard !isFullScreen, !inTransition, !w.styleMask.contains(.fullScreen), !w.isZoomed,
              let screen = w.screen else { return false }
        return !MainWindowFrame.isConstrained(w.frame, screen: screen.visibleFrame)
    }

    /// Verlauf wächst nach links, Diagnose nach rechts; die Steuerung bleibt am Platz. Zurückgenommen wird nur, was
    /// hier angebaut wurde und was der Nutzer nicht inzwischen selbst geändert hat.
    func columnsChanged(from old: MainWindowLayout.Visible, to new: MainWindowLayout.Visible) {
        guard let w = window, isFree(w), let screen = w.screen?.visibleFrame else { return }
        var f = stableFrame ?? w.frame
        let needed = MainWindowLayout.minimumWidth(new)
        for column in [MainWindowLayout.Column.history, .diagnostics] {
            let side: MainWindowFrame.Side = column == .history ? .left : .right
            if new.contains(column) && !old.contains(column) {
                guard let g = MainWindowFrame.grow(f, toMinimumWidth: needed, side: side, screen: screen) else { continue }
                f = g.frame
                grown[column] = g.added
            } else if !new.contains(column) && old.contains(column) {
                if let amount = grown[column], amount > 0, let gf = grownFrame, abs(gf.width - f.width) <= 2 {
                    f = MainWindowFrame.shrink(f, by: amount, side: side, minimumWidth: needed)
                }
                grown[column] = nil
                if !new.history && !new.diagnostics {
                    f = MainWindowFrame.limitWidth(f, to: MainWindowLayout.controlsOnlyMaxWidth,
                                                   keeping: column == .history ? .right : .left)
                }
            }
        }
        grownFrame = f
        stableFrame = f
        if f != w.frame { w.setFrame(f, display: true, animate: false) }
    }

    /// Nach dem Vollbild gilt wieder der Rahmen von davor; die Spalten kommen gleichzeitig zurück und dürfen ihn nicht
    /// aufweiten. Die Spaltenansicht stellt ihre Mindestgröße erst nach dem Umschalten ein, darum ein zweiter Versuch.
    private func restoreFrameAfterFullScreen(_ w: NSWindow) {
        grown = [:]
        grownFrame = nil
        guard let saved = frameBeforeFullScreen else {
            stableFrame = w.frame
            enforceControlsOnlyWidth()
            return
        }
        frameBeforeFullScreen = nil
        let screen = w.screen?.visibleFrame
        let target = screen.map { MainWindowFrame.fit(saved, in: $0) } ?? saved
        func apply(_ w: NSWindow) {
            if w.frame != target { w.setFrame(target, display: true, animate: false) }
            stableFrame = target
        }
        apply(w)
        Task { [weak self, weak w] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, let w, !self.inTransition, !w.styleMask.contains(.fullScreen) else { return }
            apply(w)
            self.enforceControlsOnlyWidth()
        }
    }

    /// Ohne Verlauf und Diagnose ist das Fenster höchstens `controlsOnlyMaxWidth` breit, auch nach einer
    /// wiederhergestellten Größe beim Start.
    func setControlsOnly(_ on: Bool) {
        controlsOnly = on
        enforceControlsOnlyWidth()
    }

    private func enforceControlsOnlyWidth() {
        guard controlsOnly, let w = window, isFree(w),
              Double(w.frame.width) > MainWindowLayout.controlsOnlyMaxWidth + 2 else { return }
        let f = MainWindowFrame.limitWidth(w.frame, to: MainWindowLayout.controlsOnlyMaxWidth, keeping: .left)
        w.setFrame(f, display: true, animate: false)
        stableFrame = f
    }

    /// Größere Darstellungsgröße: das Fenster wächst bis zur neuen Mindesthöhe, soweit Platz ist.
    func ensureMinimumHeight(_ height: Double) {
        guard let w = window, isFree(w), let screen = w.screen?.visibleFrame else { return }
        let f = MainWindowFrame.growHeight(w.frame, toMinimum: height + Double(w.frame.height - w.contentRect(forFrameRect: w.frame).height),
                                           screen: screen)
        if f != w.frame {
            w.setFrame(f, display: true, animate: false)
            stableFrame = f
        }
    }
}

struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.ref = ref
        return p
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.ref = ref }

    final class Probe: NSView {
        var ref: WindowRef?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            // Nicht während einer Aktualisierung der Ansicht: `attach` ändert beobachteten Zustand.
            Task { @MainActor [weak ref] in ref?.attach(w) }
        }
    }
}

/// Seitenspalten des Hauptfensters: öffnen merkt sich, welche zuletzt aufging (bei zu schmalem Bildschirm bleibt diese).
@MainActor
enum SideColumns {
    static func key(_ c: MainWindowLayout.Column) -> String {
        c == .history ? SettingsKey.showChartsPanel : SettingsKey.showDiagnosticsPanel
    }

    static func set(_ c: MainWindowLayout.Column, _ on: Bool) {
        let d = UserDefaults.standard
        if on { d.set(c.rawValue, forKey: SettingsKey.lastOpenedColumn) }
        d.set(on, forKey: key(c))
    }

    static func toggle(_ c: MainWindowLayout.Column) {
        set(c, !UserDefaults.standard.bool(forKey: key(c)))
    }

    static func binding(_ c: MainWindowLayout.Column) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: key(c)) }, set: { set(c, $0) })
    }
}

// MARK: - Menü-Kürzel nur im eigenen Fenster

/// `true`, solange Hauptfenster oder Menüleisten-Fenster Key ist. `AppCommands` fragt das per
/// `@FocusedValue(\.klimacontrolControls)` ab und sperrt ⌘↑/⌘↓/⌘P sonst.
struct KlimacontrolControlsKey: FocusedValueKey {
    typealias Value = Bool
}

struct KlimacontrolFullScreenKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var klimacontrolControls: Bool? {
        get { self[KlimacontrolControlsKey.self] }
        set { self[KlimacontrolControlsKey.self] = newValue }
    }

    /// `true`, solange das Hauptfenster im Vollbild ist („Immer im Vordergrund“ ist dann ausgesetzt).
    var klimacontrolFullScreen: Bool? {
        get { self[KlimacontrolFullScreenKey.self] }
        set { self[KlimacontrolFullScreenKey.self] = newValue }
    }
}

// MARK: - Fenster immer im Vordergrund

/// Setzt die Ebene des umgebenden Fensters: schwebend oder normal. Im Vollbild (und im Übergang dorthin) bleibt sie
/// normal; die Einstellung bleibt gespeichert. Unsichtbar, als `.background` anhängen.
struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> LevelView { LevelView() }

    func updateNSView(_ nsView: LevelView, context: Context) {
        nsView.floating = floating
        nsView.apply()
    }

    final class LevelView: NSView {
        var floating = false
        private var suspended = false
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                suspended = window.styleMask.contains(.fullScreen)
                let center = NotificationCenter.default
                for (name, value) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.didEnterFullScreenNotification, true),
                                      (NSWindow.didExitFullScreenNotification, false)] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.suspended = value
                            self?.apply()
                        }
                    })
                }
            }
            apply()
        }

        func apply() {
            guard let window else { return }
            let level: NSWindow.Level = floating && !suspended ? .floating : .normal
            if window.level != level { window.level = level }
        }
    }
}
