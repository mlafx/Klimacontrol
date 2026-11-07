import AppKit
import KlimacontrolCore
import MideaKit
import Observation
import Sparkle

/// Updates über Sparkle: immer automatisch laden und installieren, kein Überspringen, kein Abschalten. Feed und
/// Schlüssel stehen in der Info.plist (`tools/build_app.sh`).
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
        AppLog.write("Updates: automatisch laden und installieren (\(AppUpdate.feedMac))")
    }

    /// Stiller Weg ohne Sparkle-Dialog (der „Überspringen“ anböte).
    func checkForUpdates() {
        guard let controller else { return }
        status = UIText.updatesChecking
        controller.updater.checkForUpdatesInBackground()
    }
}

@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onStatus: ((String) -> Void)?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        AppLog.write("Updates: Version \(item.displayVersionString) gefunden")
        onStatus?(UIText.updatesInstalling(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onStatus?(UIText.updatesCurrent)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Sparkle meldet „kein Update“ hier zusätzlich als Fehler – das ist kein Fehlschlag.
        let e = error as NSError
        if e.domain == SUSparkleErrorDomain, e.code == Int(SUError.noUpdateError.rawValue) { return }
        AppLog.write("Updates: abgebrochen (\(error.localizedDescription))")
        onStatus?(UIText.updatesFailed)
    }

    /// Die App läuft meist dauerhaft in der Menüleiste; ohne das käme die neue Version erst beim nächsten Beenden.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        AppLog.write("Updates: installiere Version \(item.displayVersionString) sofort")
        immediateInstallHandler()
        return true
    }
}
