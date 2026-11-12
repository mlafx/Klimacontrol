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

/// Sparkles Standardoberfläche, nur bei „Updates automatisch installieren“ aus abgefangen: Gefundene Updates werden ohne
/// Fenster geladen, „bereit zum Installieren“ geht an `AppUpdater` (eigener Hinweis ohne „Überspringen“). Alles andere
/// (z. B. reine Info-Updates) zeigt Sparkle wie gewohnt.
@MainActor
private final class HeldUserDriver: NSObject, SPUUserDriver {
    private let standard: SPUStandardUserDriver
    /// true = die Sitzung läuft still über `AppUpdater`.
    private var silent = false
    var onFound: ((SUAppcastItem, SPUUserUpdateState, @escaping (SPUUserUpdateChoice) -> Void) -> Bool)?
    var onReady: ((String, @escaping (SPUUserUpdateChoice) -> Void) -> Void)?
    private var version = "?"

    init(standard: SPUStandardUserDriver) {
        self.standard = standard
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        silent = true
        if onFound?(appcastItem, state, reply) == true { return }
        silent = false
        standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if !silent { standard.showUpdateReleaseNotes(with: downloadData) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        if !silent { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    /// Still: Der Delegate protokolliert den Fehler und meldet ihn nach einer Suche von Hand.
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if silent {
            silent = false
            acknowledgement()
        } else {
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if !silent { standard.showDownloadInitiated(cancellation: cancellation) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if !silent { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if !silent { standard.showDownloadDidReceiveData(ofLength: length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        if !silent { standard.showDownloadDidStartExtractingUpdate() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if !silent { standard.showExtractionReceivedProgress(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if silent, let onReady {
            onReady(version, reply)
        } else {
            standard.showReady(toInstallAndRelaunch: reply)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                      retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        if !silent { standard.showUpdateInFocus() }
    }

    func dismissUpdateInstallation() {
        silent = false
        standard.dismissUpdateInstallation()
    }
}

@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onStatus: ((String) -> Void)?
    var onReady: ((String, @escaping () -> Void) -> Void)?
    var onManualResult: ((String, String) -> Void)?
    /// Nur eine vom Nutzer angestoßene Suche meldet ihr Ergebnis in einem Fenster; Hintergrundsuchen bleiben still.
    var userInitiated = false
    /// Die laufende Suche hat der Nutzer angestoßen (bleibt bis zum Ende der Sitzung, anders als `userInitiated`).
    var manualCycle = false

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
        manualCycle = false
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
