import Foundation

/// Szene (gespeicherter Wunschzustand), Format wie in der Backup-Datei.
public struct ACScene: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var powerOn: Bool
    public var mode: Int
    public var tempC: Double
    public var fan: Int
    public var swing: Bool
    public var eco: Bool
    public var anion: Bool
    public var outdoorSilent: Bool
    public var selfClean: Bool

    public init(id: String, name: String, powerOn: Bool, mode: Int, tempC: Double, fan: Int, swing: Bool, eco: Bool,
                anion: Bool, outdoorSilent: Bool, selfClean: Bool) {
        self.id = id
        self.name = name
        self.powerOn = powerOn
        self.mode = mode
        self.tempC = tempC
        self.fan = fan
        self.swing = swing
        self.eco = eco
        self.anion = anion
        self.outdoorSilent = outdoorSilent
        self.selfClean = selfClean
    }

    public static var defaultURL: URL {
        DeviceConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("szenen.json")
    }

    /// Szenen aus der Backup-Datei; gleiche Einstellungen unter gleichem Namen nur einmal.
    public static func fromBackup(_ url: URL) throws -> [ACScene] { try fromBackupReporting(url).scenes }

    /// Szenen einer Sicherung und wie viele davon unlesbar waren.
    public struct BackupScenes: Equatable, Sendable {
        public var scenes: [ACScene]
        /// Unlesbare Einträge (ein unlesbarer Block `scenes` zählt als einer).
        public var unreadable: Int

        public init(scenes: [ACScene], unreadable: Int) {
            self.scenes = scenes
            self.unreadable = unreadable
        }
    }

    /// Wie `fromBackup`, rettet aber jede lesbare Szene einzeln und zählt die unlesbaren, damit die Oberfläche sie
    /// melden kann. Wirft nur, wenn die Datei selbst nicht lesbar ist.
    public static func fromBackupReporting(_ url: URL) throws -> BackupScenes {
        struct Lossy: Decodable {
            let scene: ACScene?
            init(from decoder: any Decoder) throws { scene = try? ACScene(from: decoder) }
        }
        struct Backup: Decodable {
            enum Keys: String, CodingKey { case scenes }
            let entries: [Lossy]
            let broken: Bool
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                if !c.contains(.scenes) || (try? c.decodeNil(forKey: .scenes)) == true {
                    (entries, broken) = ([], false)
                } else if let list = try? c.decode([Lossy].self, forKey: .scenes) {
                    (entries, broken) = (list, false)
                } else {
                    (entries, broken) = ([], true)
                }
            }
        }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        let entries = backup.entries.prefix(100)
        let readable = entries.compactMap(\.scene).map(\.sanitized)
        let unreadable = entries.count - readable.count + (backup.broken ? 1 : 0)
        if unreadable > 0 {
            AppLog.error(LogText.t("log.scene.backupUnreadable", "Sicherung {file}: {count} Szene(n) unlesbar, nicht übernommen",
                                   ["file": url.lastPathComponent, "count": String(unreadable)]))
        }
        var seen = Set<String>()
        let unique = readable.filter { s in
            let sig = "\(s.name)|\(s.powerOn)|\(s.mode)|\(s.tempC)|\(s.fan)|\(s.swing)|\(s.eco)|\(s.anion)|\(s.outdoorSilent)"
            return seen.insert(sig).inserted
        }
        return BackupScenes(scenes: unique, unreadable: unreadable)
    }

    public static func load(from url: URL = defaultURL) -> [ACScene] { loadReporting(from: url).scenes }

    /// Ergebnis des Ladens: die lesbaren Szenen und – falls die Datei ganz oder teilweise unlesbar war – der Name,
    /// unter dem die Originaldatei beiseitegelegt wurde (`szenen.json.defekt-<Zeit>`). Die Oberfläche kann das melden.
    public struct LoadResult: Equatable, Sendable {
        public var scenes: [ACScene]
        public var movedAside: String?
    }

    /// Wie `load`, aber meldet eine beiseitegelegte Datei. Fehlende Datei = keine Szenen, still.
    /// Unlesbare Datei: Original unverändert beiseitelegen (nie überschreiben), lesbare Einträge trotzdem liefern –
    /// das nächste Speichern schreibt dann eine neue `szenen.json`, ohne die alte zu verlieren.
    public static func loadReporting(from url: URL = defaultURL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return LoadResult(scenes: [], movedAside: nil) }
        if let all = try? JSONDecoder().decode([ACScene].self, from: data) {
            return LoadResult(scenes: all.map(\.sanitized), movedAside: nil)
        }
        // Einzeln retten, was lesbar ist (ein kaputter Eintrag soll nicht alle anderen mitnehmen).
        struct Lossy: Decodable {
            let scene: ACScene?
            init(from decoder: any Decoder) throws { scene = try? ACScene(from: decoder) }
        }
        let rescued = ((try? JSONDecoder().decode([Lossy].self, from: data)) ?? []).compactMap(\.scene).map(\.sanitized)
        let aside = DeviceConfig.moveAside(url)
        AppLog.error(LogText.t("log.scene.unreadable", "{file} unlesbar – beiseitegelegt als {aside}, {count} Szene(n) gerettet",
                               ["file": url.lastPathComponent, "aside": "\(aside)", "count": String(rescued.count)]))
        return LoadResult(scenes: rescued, movedAside: aside)
    }

    /// Werte in den Bereich der Anlage holen (Datei kann von Hand oder aus fremder Quelle stammen):
    /// 16–30 °C, gültiger Modus, Lüfter 1–100 oder Auto, Name ohne Steuerzeichen, höchstens 60 Zeichen.
    public var sanitized: ACScene {
        var s = self
        s.name = DeviceConfig.cleanText(name, fallback: "Szene")
        s.tempC = tempC.isFinite ? min(30, max(16, (tempC * 2).rounded() / 2)) : 24
        if OperationalMode(rawValue: mode) == nil { s.mode = OperationalMode.auto.rawValue }
        if fan != FanSpeed.auto.rawValue { s.fan = min(100, max(1, fan)) }
        s.id = String(id.prefix(64))
        return s
    }

    /// Wie device.json nur für den eigenen Benutzer lesbar (0600, von Anfang an).
    public static func save(_ scenes: [ACScene], to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DeviceConfig.writePrivate(enc.encode(scenes), to: url)
    }

    /// Protokoll und Datenbank (deutsch); Anzeige über `summaryText` im Kern (`DisplayNames.swift`).
    public var summary: String {
        guard powerOn else { return "Aus" }
        let m = OperationalMode(rawValue: mode)?.label ?? "Modus \(mode)"
        let f = FanSpeed(rawValue: fan)?.label ?? "\(fan) %"
        return "\(m) · " + String(format: "%.0f", tempC) + "° · \(f)"
    }
}

extension PortaSplitDevice {
    /// Szene anwenden: Grundzustand in einem Befehl, danach „Außen leise“ falls nötig.
    public func apply(_ scene: ACScene) async throws -> ACState {
        var state = try await update { s in
            s.power = scene.powerOn
            if let m = OperationalMode(rawValue: scene.mode) { s.mode = m }
            s.targetTemperature = scene.tempC
            s.fanSpeed = scene.fan
            s.swing = scene.swing ? .vertical : .off
            s.eco = scene.eco
            s.purifier = scene.anion
        }
        if scene.powerOn, state.outSilent != scene.outdoorSilent {
            state = try await setOutdoorSilent(scene.outdoorSilent)
        }
        return state
    }
}
