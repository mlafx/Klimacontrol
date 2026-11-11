import AppKit
import KlimacontrolCore
import MideaKit
import Observation
import Sparkle

/// Updates über Sparkle: immer automatisch laden, kein Überspringen, kein Abschalten. Ein geladenes Update
/// installiert die App auf Wunsch sofort („Jetzt neu starten“), sonst beim Beenden. Feed und Schlüssel stehen in der
/// Info.plist (`tools/build_app.sh`); nur der Beta-Kanal setzt die Adresse über den Delegate.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// false, solange Sparkle gerade sucht oder ein Update-Fenster offen ist.
    private(set) var canCheck = false
    /// Satz zur letzten Suche (Katalogtext), nil = noch nichts gesucht.
    private(set) var status: String?
    /// Version des geladenen, noch nicht installierten Updates.
    private(set) var readyVersion: String?
    @ObservationIgnored private var installBlock: (() -> Void)?
    @ObservationIgnored private var remindAt = Date.distantPast
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var reminderTimer: Timer?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    var hasPendingInstall: Bool { installBlock != nil }

    /// Nur im fertigen Bundle mit Schlüssel – bei `swift run` meldete Sparkle sonst beim Start einen Fehler.
    var available: Bool { controller != nil }

    private init() {
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        guard bundled else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        self.controller = controller
        // Überschreibt eine frühere Abwahl, die Sparkle in den UserDefaults hält.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
        delegate.onStatus = { [weak self] in self?.status = $0 }
        delegate.onManualResult = { [weak self] title, message in self?.showManualResult(title: title, message: message) }
        delegate.onReady = { [weak self] version, install in self?.updateIsReady(version: version, install: install) }
        AppLog.write(L.Log.Updates.automatic(state: UpdaterDelegate.betaEnabled ? L.Log.Common.on : L.Log.Common.off, feed: AppUpdate.feedMac(beta: UpdaterDelegate.betaEnabled)))
    }

    /// Nach dem Einschalten des Beta-Kanals sofort suchen; beim Ausschalten bleibt die Fassung, bis eine neuere stabile kommt.
    func betaChannelChanged(to on: Bool) {
        AppLog.write(L.Log.Updates.betaChannel(state: on ? L.Log.Common.on : L.Log.Common.off))
        if on { checkForUpdates() }
    }

    /// Installiert das geladene Update und startet die App neu, ohne die Timer-Rückfrage.
    func installNow() {
        guard let block = installBlock else { return }
        AppLog.write(L.Log.Updates.installNow(version: readyVersion ?? "?"))
        installBlock = nil
        AppRestart.skipQuitPrompt = true
        block()
    }

    private func updateIsReady(version: String, install: @escaping () -> Void) {
        installBlock = install
        readyVersion = version
        status = L.Updates.Mac.ready(version: version)
        remindAt = Date()
        startReminders()
        Task { @MainActor in self.askIfDue() }
    }

    /// Wanduhr statt Zeitschaltuhr, damit die Erinnerung auch nach dem Ruhezustand pünktlich kommt.
    private func startReminders() {
        if reminderTimer == nil {
            reminderTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.askIfDue() }
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.askIfDue() }
            }
        }
    }

    private func askIfDue() {
        guard installBlock != nil, !asking, Date() >= remindAt, let version = readyVersion else { return }
        if NSApp.modalWindow != nil {
            retryTask?.cancel()
            retryTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { self.askIfDue() }
            }
            return
        }
        asking = true
        defer { asking = false }
        let alert = NSAlert()
        alert.messageText = L.Updates.Mac.promptTitle
        alert.informativeText = L.Updates.Mac.promptMessage(version: version)
        alert.addButton(withTitle: L.App.restartNow)
        alert.addButton(withTitle: L.Updates.Restart.later)
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            installNow()
        } else {
            remindAt = Date().addingTimeInterval(24 * 3600)
            AppLog.write(L.Log.Updates.remind)
        }
    }

    /// Stiller Weg ohne Sparkle-Dialog (der „Überspringen“ anböte).
    func checkForUpdates() {
        guard let controller else { return }
        status = UIText.updatesChecking
        delegate.userInitiated = true
        controller.updater.checkForUpdatesInBackground()
    }

    private func showManualResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L.Common.ok)
        NSApp.activate()
        alert.runModal()
    }
}

@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onStatus: ((String) -> Void)?
    var onReady: ((String, @escaping () -> Void) -> Void)?
    var onManualResult: ((String, String) -> Void)?
    /// Nur eine vom Nutzer angestoßene Suche meldet ihr Ergebnis in einem Fenster; Hintergrundsuchen bleiben still.
    var userInitiated = false

    /// Der Mac-Kern speichert den Schalter in den UserDefaults.
    static var betaEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.updateBetaChannel) }

    /// true für genau eine Suche im stabilen Kanal, nachdem die Beta-Datei nicht lesbar war.
    private var stableFallback = false
    private var fallbackPending = false
    private var betaFeedUsed = false
    private var updateFound = false

    /// Ohne Beta nil: dann gelten `SUFeedURL` aus den Einstellungen (Testumleitung per `defaults write`) und die
    /// Info.plist. Sparkle fragt den Delegate zuerst.
    func feedURLString(for updater: SPUUpdater) -> String? {
        let feed = AppUpdate.macFeedOverride(beta: Self.betaEnabled,
                                             testFeed: ProcessInfo.processInfo.environment[AppUpdate.testFeedVariable],
                                             stableFallback: stableFallback)
        betaFeedUsed = feed == AppUpdate.feedMacBeta
        return feed
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        AppLog.write(L.Log.Updates.found(version: item.displayVersionString))
        updateFound = true
        userInitiated = false
        onStatus?(L.Updates.Mac.downloading(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onStatus?(UIText.updatesCurrent)
        guard userInitiated else { return }
        userInitiated = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        onManualResult?(UIText.updatesManualCurrentTitle, UIText.updatesManualCurrentMessage(version: version))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        AppRestart.skipQuitPrompt = false
        // Sparkle meldet „kein Update“ hier zusätzlich als Fehler – das ist kein Fehlschlag.
        let e = error as NSError
        let noUpdate = e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue)
        // Die Beta-Datei gibt es erst mit der ersten Beta; ohne Rückfall bekäme der Beta-Kanal auch keine stabilen Updates.
        if AppUpdate.fallsBackToStable(betaFeedUsed: betaFeedUsed, updateFound: updateFound, noUpdate: noUpdate) {
            AppLog.write(L.Log.Updates.betaFallback(error: error.localizedDescription))
            fallbackPending = true
            return
        }
        if noUpdate { return }
        AppLog.write(L.Log.Updates.aborted(error: error.localizedDescription))
        onStatus?(UIText.updatesFailed)
        guard userInitiated else { return }
        userInitiated = false
        onManualResult?(UIText.updatesManualFailedTitle, UIText.updatesManualFailedMessage)
    }

    /// Kommt nach `didAbortWithError`, wenn Sparkle die Sitzung schon beendet hat; eine neue Suche ist hier erlaubt.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        betaFeedUsed = false
        updateFound = false
        stableFallback = fallbackPending
        fallbackPending = false
        if stableFallback { updater.checkForUpdatesInBackground() }
    }

    /// Sparkle installiert beim Beenden ohnehin; true meldet, dass die App den sofortigen Weg über den Block anbietet.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        AppLog.write(L.Log.Updates.downloaded(version: item.displayVersionString))
        // Die Sitzung bleibt bis zur Installation stehen, ihr Ende kommt nicht mehr an.
        stableFallback = false
        onReady?(item.displayVersionString, immediateInstallHandler)
        return true
    }
}
