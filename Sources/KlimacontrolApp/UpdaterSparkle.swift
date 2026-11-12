import AppKit
import KlimacontrolCore
import MideaKit
import Observation
import Sparkle

/// Sparkles Standardoberfläche, nur bei „Updates automatisch installieren“ aus abgefangen: Gefundene Updates werden ohne
/// Fenster geladen, „bereit zum Installieren“ geht an `AppUpdater` (eigener Hinweis ohne „Überspringen“). Alles andere
/// (z. B. reine Info-Updates) zeigt Sparkle wie gewohnt.
@MainActor
final class HeldUserDriver: NSObject, SPUUserDriver {
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
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
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
