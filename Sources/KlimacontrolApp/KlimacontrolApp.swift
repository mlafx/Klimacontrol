import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI
import UserNotifications

@main
struct KlimacontrolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: ACController

    init() {
        _model = State(initialValue: ACController(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))
        // Früh starten, damit Sparkle den täglichen Takt auch ohne geöffnete Einstellungen einhält.
        _ = AppUpdater.shared
    }

    var body: some Scene {
        // Einmalig verknüpfen: Rückfrage beim Beenden (aktive Timer) und Mitteilungen der Timer.
        let _ = appDelegate.attach(model)
        Window("Klimacontrol", id: "main") {
            MainWindowRoot()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { AppCommands(model: model) }

        // Mini-Fenster: rahmenlos, schwebt immer (Darstellung → Fenster).
        Window("Mini-Fenster", id: "mini") {
            MiniWindowView()
                .klimaThemeRoot()
                .environment(model)
                .containerBackground(.clear, for: .window)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)

        Window(UIText.whatsNewTitle(version: model.appVersion), id: "whatsnew") {
            WhatsNewView()
                .klimaThemeRoot()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            CompactView()
                .klimaThemeRoot()
                .environment(model)
        } label: {
            // Nur die Umgebung, kein eigenes Hell/Dunkel – das bestimmt die Menüleiste.
            MenuBarStatusLabel().klimaThemeRoot(applyScheme: false).environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().klimaThemeRoot().environment(model)
        }
    }
}

// MARK: - Hauptfenster: Thema, Fensterhintergrund, immer im Vordergrund

/// Wurzel des Hauptfensters. Liest nur die Darstellung, nicht den Zustand der Anlage –
/// sonst rechnete jede Abfrage das ganze Fenster neu.
private struct MainWindowRoot: View {
    var body: some View {
        WindowChrome { ContentView().fixedSize() }.klimaThemeRoot().modifier(WhatsNewOpener())
    }
}

private struct WindowChrome<Content: View>: View {
    @Environment(ACController.self) private var model
    @Environment(\.klimaTheme) private var theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .containerBackground(theme.windowBackground, for: .window)
            .background(WindowLevelSetter(floating: model.appearance.alwaysOnTop))
    }
}

// MARK: - Beenden mit aktiven Timern, Timer-Mitteilungen

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: ACController?

    /// Wird bei jeder Auswertung der Szenen gerufen; verknüpft nur beim ersten Mal.
    @discardableResult
    func attach(_ model: ACController) -> Bool {
        guard self.model !== model else { return false }
        self.model = model
        model.onTimerResult = { outcome in TimerNotifier.shared.post(outcome) }
        applyLoginItemDefault()
        return true
    }

    /// Beim ersten Start aus „Programme“ einmalig als Anmeldeobjekt eintragen; danach entscheidet nur der Nutzer.
    private func applyLoginItemDefault() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let defaults = UserDefaults.standard
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let decision = LoginItemDefault.decide(
            applied: defaults.bool(forKey: SettingsKey.loginItemDefaultOn),
            installed: LoginItemDefault.isInstalledLocation(path, home: home))
        switch decision {
        case .none, .wait: return
        case .register:
            if !LoginItem.enabled {
                AppLog.write("Beim Anmelden starten: Standard beim ersten Start")
                _ = LoginItem.set(true)
            }
        }
        defaults.set(true, forKey: SettingsKey.loginItemDefaultOn)
    }

    /// Ein gestellter Timer würde mit dem Beenden still verfallen – vorher fragen.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prompt = model?.quitPrompt() else { return .terminateNow }
        NSApp.activate()
        return runConfirm(prompt) ? .terminateNow : .terminateCancel
    }
}

/// Mitteilungen „Anlage um 7:00 eingeschaltet“ bzw. „Timer nicht ausgeführt“. Die Erlaubnis wird erst
/// erfragt, wenn jemand einen Timer stellt. Ohne App-Bundle (z. B. `swift run`) gibt es keine Mitteilungen.
@MainActor
final class TimerNotifier {
    static let shared = TimerNotifier()
    private var asked = false

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Beim Stellen eines Timers: einmal um Erlaubnis für Mitteilungen bitten.
    func prepare() {
        guard !asked, let center else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { AppLog.debug("Mitteilungen: \(error.localizedDescription)") }
            if !granted { AppLog.write("Mitteilungen für Timer nicht erlaubt") }
        }
    }

    func post(_ outcome: TimerOutcome) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = outcome.title
        content.body = outcome.message
        if !outcome.succeeded { content.sound = .default }
        center.add(UNNotificationRequest(identifier: "timer-\(outcome.powerOn ? "on" : "off")", content: content, trigger: nil))
    }
}
