import Foundation
import MideaKit

extension ACController {
    /// Einmal beim Start: zeigt, was seit der zuletzt bestätigten Version neu ist. Frische Installation und Fassungen
    /// ohne Versionsnummer zeigen nichts.
    func loadWhatsNew() {
        let seen = settings.object(forKey: SettingsKey.lastSeenVersion) as? String
        let usedBefore = DeviceConfig.load(from: paths.config) != nil
        guard ReleaseNotes.numbers(appVersion) != nil else { return }
        pendingReleaseNotes = WhatsNew.pending(lastSeen: seen, current: appVersion, usedBefore: usedBefore,
                                               notes: ReleaseNotes.parse(ReleaseNotes.changelog))
        whatsNew = ReleaseNotes.notes(pendingReleaseNotes, for: .current)
        if whatsNew.isEmpty, seen != appVersion { settings.set(appVersion, forKey: SettingsKey.lastSeenVersion) }
    }

    /// Die Oberfläche hat „Neu in dieser Version“ mit OK bestätigt.
    public func dismissWhatsNew() {
        settings.set(appVersion, forKey: SettingsKey.lastSeenVersion)
        whatsNew = []
        pendingReleaseNotes = []
    }

    /// Die Hinweise für eine bestimmte Plattform (Bridge: Windows).
    public func whatsNew(for host: HostWords) -> [ReleaseNote] {
        ReleaseNotes.notes(pendingReleaseNotes, for: host)
    }
}
