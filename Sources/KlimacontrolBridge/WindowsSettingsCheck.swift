#if os(Windows)
import Foundation
import KlimacontrolCore
import MideaKit
import WinSDK

/// Prüft `%LOCALAPPDATA%\<exe>.plist` einmal vor dem ersten Zugriff auf `UserDefaults.standard` (in `kc_set_locale`,
/// sonst in `kc_init`). swift-corelibs-foundation läse eine defekte Datei still als leer und überschriebe sie beim
/// nächsten Speichern. Das Ergebnis meldet `kc_init` dem Kern, sobald es den Controller gibt (Sprache ist dann fest).
@MainActor
enum WindowsSettingsCheck {
    private static var checked = false
    private static var pending: (outcome: SettingsFileCheck.Outcome, fileName: String)?

    /// Läuft nur beim ersten Aufruf. In Testprozessen wird die echte Datei nie angefasst.
    static func runOnce(fileURL: () -> URL? = windowsSettingsFileURL, skip: Bool = TestEnvironment.isRunningTests) {
        guard !checked else { return }
        checked = true
        guard !skip, let url = fileURL() else { return }
        pending = (SettingsFileCheck.run(fileAt: url), url.lastPathComponent)
    }

    /// Gibt das gemerkte Ergebnis genau einmal an den Kern (Protokollzeile, Hinweis über `notice`).
    static func report(to controller: ACController) {
        guard let result = pending else { return }
        pending = nil
        controller.reportSettingsFileCheck(result.outcome, fileName: result.fileName)
    }

    /// Nur für Tests: Zustand zurücksetzen.
    static func reset() {
        checked = false
        pending = nil
    }

    static var pendingOutcome: SettingsFileCheck.Outcome? { pending?.outcome }
}

/// Ort wie bei Foundation: Ordner FOLDERID_LocalAppData plus Dateiname der laufenden exe plus „.plist“.
func windowsSettingsFileURL() -> URL? {
    guard let folder = localAppDataFolder(), let exe = executablePath() else { return nil }
    return SettingsFileCheck.windowsSettingsURL(localAppData: folder, executablePath: exe)
}

func localAppDataFolder() -> String? {
    var path: PWSTR?
    defer { if let path { CoTaskMemFree(path) } }
    var id = FOLDERID_LocalAppData
    guard SHGetKnownFolderPath(&id, DWORD(KF_FLAG_DEFAULT.rawValue), nil, &path) == S_OK, let path else { return nil }
    let folder = String(decodingCString: path, as: UTF16.self)
    return folder.isEmpty ? nil : folder
}

func executablePath() -> String? {
    var size = Int(MAX_PATH)
    // Lange Pfade: Puffer vergrößern, solange GetModuleFileNameW abschneidet.
    while size <= 32_768 {
        var buffer = [WCHAR](repeating: 0, count: size)
        let length = Int(GetModuleFileNameW(nil, &buffer, DWORD(size)))
        if length == 0 { return nil }
        if length < size { return String(decoding: buffer.prefix(length), as: UTF16.self) }
        size *= 2
    }
    return nil
}
#endif
