import AppKit
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

/// Schwacher Verweis auf das Fenster der Ansicht (für das Verschieben beim Einblenden des Verlaufs).
@MainActor
final class WindowRef {
    weak var window: NSWindow?

    /// Fenster waagerecht verschieben, links nicht über den sichtbaren Bildschirmrand hinaus.
    func shift(by dx: CGFloat) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        var origin = window.frame.origin
        origin.x += dx
        if let vf = (window.screen ?? NSScreen.main)?.visibleFrame { origin.x = max(vf.minX, origin.x) }
        window.setFrameOrigin(origin)
    }
}

struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.ref = ref
        return p
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.ref = ref; ref.window = nsView.window }

    final class Probe: NSView {
        var ref: WindowRef?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref?.window = window
        }
    }
}

/// Hält das Fenster auf dem Bildschirm: Wächst es beim Einblenden von Verlauf oder Diagnose über den Rand,
/// rückt es gerade so weit herein. Die obere linke Ecke bleibt sonst stehen (das Fenster springt nicht).
struct KeepOnScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { Probe.fit(window) } }
            }
        }

        static func fit(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
            let vf = screen.visibleFrame
            var f = window.frame
            if f.maxX > vf.maxX { f.origin.x = max(vf.minX, vf.maxX - f.width) }
            if f.minY < vf.minY { f.origin.y = min(vf.minY, vf.maxY - f.height) }
            if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
            if f.origin != window.frame.origin { window.setFrameOrigin(f.origin) }
        }
    }
}

// MARK: - Menü-Kürzel nur im eigenen Fenster

/// `true`, solange Hauptfenster oder Menüleisten-Fenster Key ist. `AppCommands` fragt das per
/// `@FocusedValue(\.klimacontrolControls)` ab und sperrt ⌘↑/⌘↓/⌘P sonst.
struct KlimacontrolControlsKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var klimacontrolControls: Bool? {
        get { self[KlimacontrolControlsKey.self] }
        set { self[KlimacontrolControlsKey.self] = newValue }
    }
}

// MARK: - Fenster immer im Vordergrund

/// Setzt die Ebene des umgebenden Fensters: schwebend oder normal. Unsichtbar, als `.background` anhängen.
struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> LevelView { LevelView() }

    func updateNSView(_ nsView: LevelView, context: Context) {
        nsView.floating = floating
        nsView.apply()
    }

    final class LevelView: NSView {
        var floating = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            let level: NSWindow.Level = floating ? .floating : .normal
            if window.level != level { window.level = level }
        }
    }
}
