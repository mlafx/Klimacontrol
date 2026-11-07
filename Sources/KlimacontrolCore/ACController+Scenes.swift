import Foundation
import MideaKit

/// Szenen: gespeicherte Wunschzustände (szenen.json, gleiches Format wie in der Backup-Datei).
extension ACController {
    public func apply(_ scene: ACScene) {
        let scene = scene.sanitized
        if let s = state, s.power != scene.powerOn { timerRuntime.userPowerAt = now() }
        command { try await $0.apply(scene) }
    }

    public func saveCurrentAsScene(named name: String) {
        guard let s = state else { return }
        let name = DeviceConfig.cleanText(name, fallback: "")
        guard !name.isEmpty else { return }
        let scene = ACScene(id: UUID().uuidString, name: name, powerOn: s.power, mode: s.mode.rawValue,
                            tempC: s.targetTemperature, fan: s.fanSpeed, swing: s.swing == .vertical, eco: s.eco,
                            anion: s.purifier, outdoorSilent: s.outSilent ?? false, selfClean: false)
        scenes.append(scene.sanitized)
        saveScenes()
    }

    /// Szene entspricht dem aktuellen Zustand (zur Markierung „aktiv“).
    public func isActive(_ scene: ACScene) -> Bool {
        guard let s = state else { return false }
        if !scene.powerOn { return !s.power }
        return s.power && s.mode.rawValue == scene.mode && s.targetTemperature == scene.tempC
            && s.fanSpeed == scene.fan && (s.swing == .vertical) == scene.swing && s.eco == scene.eco
    }

    public func deleteScene(_ scene: ACScene) {
        scenes.removeAll { $0.id == scene.id }
        saveScenes()
    }

    func saveScenes() {
        do { try ACScene.save(scenes, to: paths.scenes) } catch {
            AppLog.error("Szenen nicht gespeichert: \(error.localizedDescription)")
            showNotice(L.Message.Scenes.notSaved(reason: UserMessage.from(error).text))
        }
    }
}
