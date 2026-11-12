import AppKit
import KlimacontrolCore
import MideaKit
import Observation
import Sparkle

/// Updates über Sparkle: immer automatisch suchen und laden, kein Überspringen. „Updates automatisch installieren“ an
/// (Standard): Sparkles stiller Weg, ein geladenes Update installiert auf Wunsch sofort („Jetzt neu starten“), sonst beim
/// Beenden. Aus: Sparkles Weg über den Nutzer (`HeldUserDriver`), still geladen, installiert nur nach „Jetzt
/// installieren“; „Später“ und das Beenden nehmen die vorbereitete Installation zurück (Antwort `.skip` auf „bereit zum
/// Installieren“ bricht nur ab, überspringt die Version nicht). Feed und Schlüssel stehen in der Info.plist
/// (`tools/build_app.sh`); nur der Beta-Kanal setzt die Adresse über den Delegate.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let updater: SPUUpdater?
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private let userDriver: HeldUserDriver?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// false, solange Sparkle gerade sucht oder ein Update-Fenster offen ist.
    private(set) var canCheck = false
    /// Satz zur letzten Suche (Katalogtext), nil = noch nichts gesucht.
    private(set) var status: String?
    /// Version des geladenen Updates, das beim Beenden installiert wird (automatisch installieren an).
    private(set) var readyVersion: String?
    /// Version eines Updates, das auf „Jetzt installieren“ wartet (automatisch installieren aus).
    private(set) var heldVersion: String?
    @ObservationIgnored private var installBlock: (() -> Void)?
    /// Aus: Antwort an Sparkle für die vorbereitete Installation (`.install` oder `.skip`), solange der Hinweis aussteht.
    @ObservationIgnored private var heldReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var remindAt: Date?
    /// „Jetzt installieren“ ohne geladenes Update: das nächste bereite Update ohne weitere Rückfrage installieren.
    @ObservationIgnored private var installWhenReady = false
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var reminderTimer: Timer?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// Nur mit „automatisch installieren“: Sparkle installiert beim Beenden ohnehin, ein Neustart darf es gleich tun.
    var hasPendingInstall: Bool { installBlock != nil }

    /// Nur im fertigen Bundle mit Schlüssel – bei `swift run` meldete Sparkle sonst beim Start einen Fehler.
    var available: Bool { updater != nil }

    /// Der Mac-Kern speichert die Einstellungen in den UserDefaults.
    static var autoInstall: Bool { AppUpdate.autoInstall(stored: UserDefaults.standard.object(forKey: SettingsKey.updateAutoInstall)) }
    static var interval: UpdateInterval { UpdateInterval(stored: UserDefaults.standard.object(forKey: SettingsKey.updateInterval)) }

    private init() {
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        guard bundled else {
            updater = nil
            userDriver = nil
            return
        }
        let driver = HeldUserDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: nil))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        self.updater = updater
        userDriver = driver
        do {
            try updater.start()
        } catch {
            AppLog.error(L.Log.Updates.aborted(error: error.localizedDescription))
        }
        applySettings()
        canCheck = updater.canCheckForUpdates
        observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
        delegate.onStatus = { [weak self] in self?.status = $0 }
        delegate.onManualResult = { [weak self] title, message in self?.showManualResult(title: title, message: message) }
        delegate.onReady = { [weak self] version, install in self?.updateIsReady(version: version, install: install) }
        driver.onFound = { [weak self] item, state, reply in self?.heldUpdateFound(item: item, state: state, reply: reply) ?? false }
        driver.onReady = { [weak self] version, reply in self?.heldUpdateIsReady(version: version, reply: reply) }
        AppLog.write(L.Log.Updates.automatic(state: UpdaterDelegate.betaEnabled ? L.Log.Common.on : L.Log.Common.off, feed: AppUpdate.feedMac(beta: UpdaterDelegate.betaEnabled)))
    }

    /// Überschreibt frühere Werte, die Sparkle in den UserDefaults hält; maßgeblich sind die Einstellungen des Kerns.
    /// Ohne automatische Installation lädt der Weg über den Nutzer (`HeldUserDriver`) still.
    private func applySettings() {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = Self.autoInstall
        updater.updateCheckInterval = TimeInterval(Self.interval.seconds)
        AppLog.write(L.Log.Updates.settings(state: Self.autoInstall ? L.Log.Common.on : L.Log.Common.off, interval: Self.interval.title))
    }

    /// Nach dem Umschalten in den Einstellungen. Ein schon geladenes Update behält den Weg, mit dem es geladen wurde.
    func settingsChanged() {
        applySettings()
        if Self.autoInstall, heldReply == nil {
            heldVersion = nil
            installWhenReady = false
        }
    }

    /// Nach dem Einschalten des Beta-Kanals sofort suchen; beim Ausschalten bleibt die Fassung, bis eine neuere stabile kommt.
    func betaChannelChanged(to on: Bool) {
        AppLog.write(L.Log.Updates.betaChannel(state: on ? L.Log.Common.on : L.Log.Common.off))
        if on { checkForUpdates() }
    }

    /// Installiert das geladene Update und startet die App neu, ohne die Timer-Rückfrage.
    func installNow() {
        if let reply = heldReply {
            AppLog.write(L.Log.Updates.installNow(version: heldVersion ?? "?"))
            heldReply = nil
            AppRestart.skipQuitPrompt = true
            reply(.install)
            return
        }
        guard let block = installBlock else { return }
        AppLog.write(L.Log.Updates.installNow(version: readyVersion ?? "?"))
        installBlock = nil
        AppRestart.skipQuitPrompt = true
        block()
    }

    /// „Jetzt installieren“ in den Einstellungen: ein wartendes Update installieren, sonst laden und dann installieren.
    func installHeld() {
        if heldReply != nil {
            installNow()
            return
        }
        installWhenReady = true
        checkForUpdates()
    }

    /// Vor dem Beenden: Ohne automatische Installation darf eine vorbereitete Installation nicht mit dem Beenden laufen.
    /// true = zurückgenommen; Sparkle braucht dann einen Augenblick, bis der Installer die Absage hat.
    func withdrawHeldInstallBeforeQuit() -> Bool {
        guard let reply = heldReply else { return false }
        AppLog.write(L.Log.Updates.withdrawn(version: heldVersion ?? "?"))
        heldReply = nil
        reply(.skip)
        return true
    }

    private func updateIsReady(version: String, install: @escaping () -> Void) {
        installBlock = install
        readyVersion = version
        status = L.Updates.Mac.ready(version: version)
        remindAt = Date()
        startReminders()
        Task { @MainActor in self.askIfDue() }
    }

    /// Aus: Sparkle hat ein Update gefunden. true = still laden (keine Sparkle-Fenster), sonst übernimmt Sparkle.
    private func heldUpdateFound(item: SUAppcastItem, state: SPUUserUpdateState,
                                 reply: @escaping (SPUUserUpdateChoice) -> Void) -> Bool {
        guard !Self.autoInstall, !item.isInformationOnlyUpdate else { return false }
        let version = item.displayVersionString
        heldVersion = version
        status = UIText.updatesHeldBackStatus(version: version)
        startReminders()
        let manual = delegate.manualCycle || installWhenReady
        if state.stage == .installing || AppUpdate.offersUpdate(userInitiated: manual, now: Date(), remindAt: remindAt) {
            reply(.install)
        } else {
            AppLog.write(L.Log.Updates.deferred(version: version))
            reply(.dismiss)
        }
        return true
    }

    /// Aus: Das Update ist geladen und vorbereitet; ohne Antwort würde es beim Beenden installiert.
    private func heldUpdateIsReady(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        AppLog.write(L.Log.Updates.heldBack(version: version))
        heldVersion = version
        heldReply = reply
        status = UIText.updatesHeldBackStatus(version: version)
        if installWhenReady {
            installWhenReady = false
            installNow()
            return
        }
        remindAt = Date()
        askIfDue()
    }

    /// Wanduhr statt Zeitschaltuhr, damit die Erinnerung auch nach dem Ruhezustand pünktlich kommt.
    private func startReminders() {
        if reminderTimer == nil {
            reminderTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reminderTick() }
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reminderTick() }
            }
        }
    }

    /// Aus und nach „Später“: Das Update ist nicht mehr vorbereitet; bei fälliger Erinnerung neu laden, dann fragen.
    private func reminderTick() {
        if heldReply == nil, heldVersion != nil, !Self.autoInstall,
           AppUpdate.reminderDue(now: Date(), remindAt: remindAt), updater?.canCheckForUpdates == true {
            updater?.checkForUpdatesInBackground()
            return
        }
        askIfDue()
    }

    private func askIfDue() {
        let held = heldReply != nil
        guard held || installBlock != nil, !asking, AppUpdate.reminderDue(now: Date(), remindAt: remindAt),
              let version = held ? heldVersion : readyVersion else { return }
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
        alert.messageText = held ? UIText.updatesHeldBackTitle : L.Updates.Mac.promptTitle
        alert.informativeText = held ? UIText.updatesHeldBackMessage(version: version) : L.Updates.Mac.promptMessage(version: version)
        alert.addButton(withTitle: held ? UIText.updatesInstallNow : L.App.restartNow)
        alert.addButton(withTitle: UIText.updatesLater)
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            installNow()
            return
        }
        remindAt = AppUpdate.nextReminder(after: Date())
        AppLog.write(L.Log.Updates.remind)
        // Aus: nichts vorbereitet lassen, sonst liefe die Installation beim Beenden.
        if held { _ = withdrawHeldInstallBeforeQuit() }
    }

    /// Stiller Weg ohne Sparkle-Dialog (der „Überspringen“ anböte).
    func checkForUpdates() {
        guard let updater else { return }
        status = UIText.updatesChecking
        delegate.userInitiated = true
        delegate.manualCycle = true
        updater.checkForUpdatesInBackground()
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
