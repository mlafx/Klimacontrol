import Foundation
import Synchronization

/// Verbindungsdaten einer Anlage (Token und Schlüssel aus einer Backup-Datei).
public struct DeviceConfig: Codable, Equatable, Sendable {
    public var name: String
    public var ip: String
    public var port: UInt16
    public var deviceId: UInt64
    public var token: String
    public var key: String
    /// Seriennummer der Anlage (z. B. „00000Q1CAC1A2B“) aus Bluetooth-Einrichtungen; wird nur noch mitgeführt,
    /// der Schlüsselname bleibt für alte `device.json`.
    public var bleSerial: String?

    public init(name: String, ip: String, port: UInt16, deviceId: UInt64, token: String, key: String, bleSerial: String? = nil) {
        self.name = name
        self.ip = ip
        self.port = port
        self.deviceId = deviceId
        self.token = token
        self.key = key
        self.bleSerial = bleSerial
    }

    /// WLAN-Zugangsdaten vorhanden?
    public var hasLAN: Bool { !ip.isEmpty && !token.isEmpty && !key.isEmpty }

    /// Prüft eine Einrichtung aus fremder Quelle (Backup-Datei, Cloud) bevor sie gespeichert wird:
    /// IPv4-Adresse (oder leer ohne WLAN-Zugangsdaten), Port 1–65535, Token 128 und Schlüssel 64 Hex-Zeichen.
    /// Der Name wird von Steuerzeichen befreit und auf 60 Zeichen gekürzt (sonst ließen sich Protokollzeilen fälschen).
    public func validated() throws -> DeviceConfig {
        var c = self
        c.name = Self.cleanText(name, fallback: "PortaSplit")
        c.ip = ip.trimmingCharacters(in: .whitespaces)
        if !c.ip.isEmpty || !token.isEmpty || !key.isEmpty {
            guard Self.isIPv4(c.ip) else { throw ConfigError.invalidAddress }
            guard port != 0 else { throw ConfigError.invalidAddress }
            guard Self.isHex(token, length: 128), Self.isHex(key, length: 64) else { throw ConfigError.invalidHex }
        }
        if let serial = bleSerial {
            c.bleSerial = String(String.UnicodeScalarView(serial.unicodeScalars.filter { ("0"..."9").contains($0) || ("A"..."Z").contains($0) || ("a"..."z").contains($0) }.prefix(32)))
        }
        return c
    }

    /// Streng: vier Gruppen aus 1–3 ASCII-Ziffern, 0–255, ohne Vorzeichen und ohne führende Null.
    public static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            (1...3).contains(p.count) && p.allSatisfy { ("0"..."9").contains($0) }
                && (p.count == 1 || p.first != "0") && (Int(p) ?? 256) <= 255
        }
    }

    static func isHex(_ s: String, length: Int) -> Bool {
        s.count == length && s.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Text aus fremder Quelle: Steuerzeichen raus, höchstens `maxLength` Zeichen, leer → Ersatz.
    public static func cleanText(_ s: String, fallback: String, maxLength: Int = 60) -> String {
        let banned: [Unicode.GeneralCategory] = [.control, .format, .lineSeparator, .paragraphSeparator]
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { !banned.contains($0.properties.generalCategory) }))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(maxLength))
    }

    /// Liest die erste Anlage aus einer Backup-Datei (JSON mit `devices`: ip, port, deviceId, token, key).
    public static func fromBackup(_ url: URL) throws -> DeviceConfig {
        struct Backup: Decodable {
            struct Device: Decodable {
                let deviceId: UInt64
                let discoveredName: String?
                let ip: String
                let key: String
                let port: UInt16?
                let token: String
                let version: Int?
            }
            let devices: [Device]
        }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        guard let d = backup.devices.first else { throw ConfigError.noDevice }
        guard d.version ?? 3 == 3 else { throw ConfigError.unsupportedVersion(d.version ?? 0) }
        return try DeviceConfig(name: d.discoveredName ?? "PortaSplit", ip: d.ip, port: d.port ?? 6444,
                                deviceId: d.deviceId, token: d.token, key: d.key).validated()
    }

    /// Schreibt Zugangsdaten (und Szenen) im Backup-Format – lässt sich mit „Backup-Datei wählen“ wieder einlesen.
    public func exportBackup(to url: URL, scenes: [ACScene]) throws {
        struct Device: Encodable {
            let deviceId: UInt64, discoveredName: String, ip: String, key: String, port: UInt16, token: String
            let type = 172, version = 3
        }
        struct Backup: Encodable { let devices: [Device]; let scenes: [ACScene]; let version = 1 }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let backup = Backup(devices: [Device(deviceId: deviceId, discoveredName: name, ip: ip, key: key, port: port, token: token)],
                            scenes: scenes)
        try Self.writePrivate(enc.encode(backup), to: url)
    }

    /// Ablageordner für device.json, Szenen, Protokoll und Verlauf:
    /// macOS ~/Library/Application Support/Klimacontrol, Windows %LOCALAPPDATA%\Klimacontrol.
    public static var supportDirectory: URL {
        #if os(Windows)
        if let dir = windowsSupportDirectory { return dir }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klimacontrol", isDirectory: true)
    }

    #if os(Windows)
    /// %LOCALAPPDATA% statt %APPDATA%: Roaming-Profile würden device.json (Token/Schlüssel) auf andere Rechner
    /// kopieren. Dateien aus dem alten Ordner %APPDATA%\PortaSplit werden einmal herübergeholt, vorhandene nie überschrieben.
    /// Kein AppLog hier – das Protokoll liegt selbst in diesem Ordner.
    private static let windowsSupportDirectory: URL? = {
        let env = ProcessInfo.processInfo.environment
        guard let local = env["LOCALAPPDATA"], !local.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: local, isDirectory: true).appendingPathComponent("Klimacontrol", isDirectory: true)
        guard let roaming = env["APPDATA"], !roaming.isEmpty else { return dir }
        let old = URL(fileURLWithPath: roaming, isDirectory: true).appendingPathComponent("PortaSplit", isDirectory: true)
        let fm = FileManager.default
        guard old.standardizedFileURL != dir.standardizedFileURL,
              let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return dir }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files where !fm.fileExists(atPath: dir.appendingPathComponent(file.lastPathComponent).path) {
            try? fm.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
        return dir
    }()
    #endif

    public static var defaultURL: URL { supportDirectory.appendingPathComponent("device.json") }

    /// Schreibt eine Datei, die von Anfang an nur für den eigenen Benutzer lesbar ist (kein kurzes 0644-Fenster).
    public static func writePrivate(_ data: Data, to url: URL) throws {
        #if os(Windows)
        try data.write(to: url, options: .atomic)
        #else
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            // Ohne `.usingNewMetadataOnly` übernimmt das Ersetzen die Rechte einer vorhandenen Datei (z. B. 0644).
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil,
                                                      options: .usingNewMetadataOnly)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try restrictToOwner(url, 0o600)
        #endif
    }

    /// Nur für den eigenen Benutzer lesbar. Unter Windows nichts zu tun: %LOCALAPPDATA% ist ohnehin benutzereigen.
    public static func restrictToOwner(_ url: URL, _ mode: Int) throws {
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        #endif
    }

    /// Fehlende Datei = noch keine Anlage eingerichtet (still nil). Eine vorhandene, aber unlesbare Datei wird
    /// gemeldet und beiseitegelegt – sonst sähe die App „nicht eingerichtet“ und eine Neueinrichtung
    /// überschriebe die alten Zugangsdaten unbemerkt.
    public static func load(from url: URL = defaultURL) -> DeviceConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(DeviceConfig.self, from: data)
        } catch {
            let aside = moveAside(url)
            AppLog.error(LogText.t("log.device.configUnreadable", "{file} unlesbar ({error}) – beiseitegelegt als {aside}", ["file": url.lastPathComponent, "error": error.localizedDescription, "aside": aside]))
            return nil
        }
    }

    /// Verschiebt die Datei nach `<Name>.defekt-<ISO-Zeit ohne Doppelpunkte>`; liefert den neuen Dateinamen.
    static func moveAside(_ url: URL, now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let name = "\(url.lastPathComponent).defekt-\(stamp)"
        try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
        return name
    }

    /// Speichert nur für den eigenen Benutzer lesbar (0600, von Anfang an), nie in iCloud.
    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.restrictToOwner(url.deletingLastPathComponent(), 0o700)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivate(enc.encode(self), to: url)
    }
}

public enum ConfigError: Error, LocalizedError {
    case noDevice, unsupportedVersion(Int), invalidHex, invalidAddress

    public var errorDescription: String? {
        switch self {
        case .noDevice: return LogText.t("kit.config.noDevice", "Die Datei enthält keine Anlage.")
        case .unsupportedVersion(let v): return LogText.t("kit.config.unsupportedVersion", "Protokollversion V{version} wird nicht unterstützt (nur V3).", ["version": String(v)])
        case .invalidHex: return LogText.t("kit.config.invalidHex", "Token oder Schlüssel sind kein gültiges Hex (erwartet 128 bzw. 64 Zeichen).")
        case .invalidAddress: return LogText.t("kit.config.invalidAddress", "Die Adresse der Anlage ist keine gültige IPv4-Adresse mit Port.")
        }
    }
}

/// Steuerung einer Midea-Anlage (Klimacontrol) im lokalen WLAN oder über die Cloud (`connectionMode`).
/// `@unchecked Sendable`: `beep`, `onPhase`, `commandBudget` und `idleDisconnect` liegen im `Mutex` `shared`; `last`,
/// `lastAt`, `idleWork` und der Transport werden nur auf der seriellen `queue` benutzt.
public final class PortaSplitDevice: @unchecked Sendable {
    public let config: DeviceConfig
    /// Signalton bei Befehlen (die PortaSplit piept ohnehin nur bei Ein/Aus). Die App setzt ihn vom Hauptthread,
    /// die Geräte-Queue liest und schreibt ihn (`applyProperties`) – darum im `Mutex` wie `AutoTransport.mode`.
    public var beep: Bool {
        get { shared.withLock { $0.beep } }
        set { shared.withLock { $0.beep = newValue } }
    }

    /// Von Hauptthread und Geräte-Queue benutzte Einstellungen.
    private struct Shared {
        var beep = true
        var onPhase: (@Sendable (ConnectPhase) -> Void)?
        var commandBudget: TimeInterval = 10
        var idleDisconnect: TimeInterval = 8
    }
    private let shared = Mutex(Shared())

    /// Beim Prüfen eines Tokens sind Ablehnungen erwartbar – dann nicht als Fehler protokollieren.
    public var quietErrors: Bool {
        get { client.quietErrors }
        set { client.quietErrors = newValue }
    }

    private let queue = DispatchQueue(label: "klimacontrol.lan")
    private let client: AutoTransport
    private var last: ACState?
    /// Zeitpunkt von `last` (nur auf der Queue).
    private var lastAt: Date?

    /// Verbindungsschritt (Anlage suchen · Anmelden · Werte lesen) für die Startanzeige. Wird auf der Geräte-Queue
    /// aufgerufen; die App springt selbst auf den Hauptthread.
    public var onPhase: (@Sendable (ConnectPhase) -> Void)? {
        get { shared.withLock { $0.onPhase } }
        set { shared.withLock { $0.onPhase = newValue } }
    }

    /// Gesamtlimit je Auftrag (Abfrage oder Befehl) im WLAN: danach Abbruch mit klarer Meldung statt bis zu
    /// 30 s Warten. Die Pausen 0,5 s / 1,5 s bleiben, nur die Wartezeiten aufs Antworten werden gekürzt.
    public var commandBudget: TimeInterval {
        get { shared.withLock { $0.commandBudget } }
        set { shared.withLock { $0.commandBudget = max(2, newValue) } }
    }
    /// So jung darf der letzte gelesene Zustand sein, damit `update` ihn statt einer neuen Abfrage nutzt.
    static let freshStateAge: TimeInterval = 3

    /// Für Tests: eigener Weg (nachgebildete Transporte), keine Sockets.
    init(config: DeviceConfig, transport: AutoTransport) {
        self.config = config
        self.client = transport
    }

    public init(config: DeviceConfig, mode: ConnectionMode = .auto, cloud: CloudCredentials? = nil) throws {
        var lan: LANClient?
        if config.hasLAN {
            guard let token = Data(hex: config.token), let key = Data(hex: config.key) else { throw ConfigError.invalidHex }
            lan = LANClient(host: config.ip, port: config.port, deviceId: config.deviceId, token: token, key: key)
        }
        // Cloud-Weg (unterwegs) nur, wenn Kontodaten vorliegen und die Geräte-ID bekannt ist.
        var cloudTransport: (any FrameTransport)?
        if let cloud, config.deviceId != 0 {
            let client = CloudControlClient(account: cloud.account, password: cloud.password,
                                            deviceId: config.deviceId, serialSuffix: config.bleSerial ?? "")
            cloudTransport = CloudTransport(client: client)
        }
        self.config = config
        self.client = AutoTransport(lan: lan, cloud: cloudTransport, mode: mode)
        lan?.onPhase = { [weak self] phase in self?.onPhase?(phase) }
    }

    /// Weg wählen (Automatisch: WLAN zuerst, dann Cloud).
    public var connectionMode: ConnectionMode {
        get { client.mode }
        set { client.mode = newValue }
    }

    /// Zuletzt erfolgreich genutzter Weg (nil = noch keine Antwort).
    public var connectionPath: ConnectionPath? { client.path }

    /// Liest Grundzustand, Eigenschaften (Außen leise, Selbstreinigung, iECO) und Leistung.
    public func refresh() async throws -> ACState {
        try await run { [self] in
            var state = try queryState()
            applyProperties(try? queryProperties(optional: true), to: &state)
            if let (watts, kwh) = try? queryEnergy() {
                state.powerWatts = watts
                state.totalEnergyKWh = kwh
            }
            remember(state)
            return state
        }
    }

    /// Schnellabruf: nur der Grundzustand (1 Abfrage, ~0,35 s); Eigenschaften und Verbrauch vom letzten Stand.
    /// Mit `extras` zusätzlich Eigenschaften + Verbrauch (für den Wechselbetrieb im 1-s-Takt).
    public func refreshFast(extras: Bool) async throws -> ACState {
        try await run { [self] in
            var state = carry(try queryState())
            if extras {
                applyProperties(try? queryProperties(optional: true), to: &state)
                if let (watts, kwh) = try? queryEnergy() {
                    state.powerWatts = watts
                    state.totalEnergyKWh = kwh
                }
            }
            remember(state)
            return state
        }
    }

    /// Ändert den Grundzustand (Ein/Aus, Modus, Temperatur, Lüfter, Swing, Eco, Turbo, Ionisierer, Frostschutz).
    public func update(_ change: @escaping @Sendable (inout ACState) -> Void) async throws -> ACState {
        try await run { [self] in
            // Frisch lesen (eine andere App oder die Fernbedienung kann etwas geändert haben) – außer der letzte
            // Stand ist erst Sekunden alt: dann spart der Befehl eine Abfrage.
            let before = try freshState()
            var target = before
            change(&target)
            // Nur ganze Grad – aber nur, wenn dieser Befehl die Temperatur ändert;
            // sonst würde z. B. ein Lüfterwechsel 22,5 still auf 23 °C stellen.
            if target.targetTemperature != before.targetTemperature {
                target.targetTemperature = min(30, max(16, target.targetTemperature.rounded()))
            }
            if target.turbo { target.eco = false }
            // Frostschutz gibt es nur beim Heizen.
            if target.mode != .heat { target.freezeProtection = false }

            // Genau die Felder, die dieser Befehl ändert – nur die werden geprüft.
            let changed = Self.changedControls(before, target)
            var result = before
            // Bis zu 3 Versuche; die Anlage nimmt dicht aufeinanderfolgende Befehle nicht immer an.
            for attempt in 1...3 {
                if attempt > 1 { Thread.sleep(forTimeInterval: 1.5) }
                do {
                    result = carry(try stateFrom(client.send(Frame.setState(target, beep: beep), expect: 0xC0)) ?? queryState())
                } catch {
                    // Abbruch nach dem Senden: offen sagen, dass das Ergebnis unklar ist.
                    throw Self.unclearOutcome(error)
                }
                if Self.controlsMatch(result, target, changed) {
                    remember(result)
                    return result
                }
                AppLog.error(LogText.t("log.device.notApplied", "Stellbefehl nicht übernommen (Versuch {attempt}/3): {fields}", ["attempt": String(attempt), "fields": "\(Self.mismatch(result, target, changed))"]))
            }
            // Dreimal nicht übernommen: aktuellen Stand der Anlage (frischer Pull) zurückgeben und melden.
            remember(result)
            throw MideaError.commandNotApplied(result)
        }
    }

    /// Fehler nach dem Absenden eines Befehls: Verbindung weg oder Zeitlimit – ob er ankam, ist offen. Meldet die
    /// Cloud die Anlage als aus, kam der Befehl sicher nicht an: dann bleibt der Fehler, wie er ist.
    static func unclearOutcome(_ error: any Error) -> any Error {
        guard let m = error as? MideaError else { return error }
        switch m {
        case .commandNotApplied, .authenticationFailed, .outcomeUnknown: return m
        case .allPathsFailed(let failures) where failures.contains(where: \.isApplianceOffline): return m
        default: return MideaError.outcomeUnknown(m.errorDescription ?? LogText.t("kit.error.noReply", "Keine Antwort."))
        }
    }

    /// Steuerfelder eines Stellbefehls; nach dem Setzen werden nur die geänderten geprüft.
    enum ControlField: CaseIterable {
        case power, mode, temp, fan, swing, eco, turbo, purifier, freeze

        /// Name im Protokoll („Stellbefehl nicht übernommen: soll“).
        var label: String {
            switch self {
            case .power: return LogText.t("kit.control.power", "ein/aus")
            case .mode: return LogText.t("kit.control.mode", "modus")
            case .temp: return LogText.t("kit.control.target", "soll")
            case .fan: return LogText.t("kit.control.fan", "lüfter")
            case .swing: return LogText.t("kit.control.swing", "swing")
            case .eco: return LogText.t("kit.control.eco", "eco")
            case .turbo: return LogText.t("kit.control.turbo", "turbo")
            case .purifier: return LogText.t("kit.control.purifier", "ionisierer")
            case .freeze: return LogText.t("kit.control.freeze", "frostschutz")
            }
        }

        func same(_ a: ACState, _ b: ACState) -> Bool {
            switch self {
            case .power: return a.power == b.power
            case .mode: return a.mode == b.mode
            case .temp: return a.targetTemperature == b.targetTemperature
            case .fan: return a.fanSpeed == b.fanSpeed
            case .swing: return a.swing == b.swing
            case .eco: return a.eco == b.eco
            case .turbo: return a.turbo == b.turbo
            case .purifier: return a.purifier == b.purifier
            case .freeze: return a.freezeProtection == b.freezeProtection
            }
        }
    }

    /// Steuerfelder, die sich zwischen zwei Zuständen unterscheiden.
    static func changedControls(_ a: ACState, _ b: ACState) -> Set<ControlField> {
        Set(ControlField.allCases.filter { !$0.same(a, b) })
    }

    static func controlsMatch(_ result: ACState, _ target: ACState, _ fields: Set<ControlField>) -> Bool {
        mismatch(result, target, fields).isEmpty
    }

    /// Liste der Felder, die nach dem Setzen noch nicht stimmen (leer = alles übernommen).
    static func mismatch(_ result: ACState, _ target: ACState, _ fields: Set<ControlField>) -> [String] {
        ControlField.allCases.filter { f in
            guard fields.contains(f), !f.same(result, target) else { return false }
            // Alles außer Ein/Aus nur prüfen, wenn das Gerät eingeschaltet bleibt.
            if f != .power, !target.power { return false }
            // Im Trocknen-Modus regelt die Anlage den Lüfter selbst.
            return !(f == .fan && target.mode == .dry)
        }.map(\.label)
    }

    /// Nächste Stufe der Leistungsbegrenzung, die die Anlage kennt: 50, 75 oder 100 (keine) Prozent.
    public static func nearestRate(_ percent: Int) -> Int {
        [50, 75, 100].min { abs($0 - percent) < abs($1 - percent) } ?? 100
    }

    public func setOutdoorSilent(_ on: Bool) async throws -> ACState {
        try await setProperty(.outSilent, on)
    }

    /// Selbstreinigung starten (dauert ca. 15 Minuten) bzw. abbrechen.
    public func setSelfClean(_ on: Bool) async throws -> ACState {
        try await setProperty(.selfClean, on)
    }

    public func setIECO(_ on: Bool) async throws -> ACState {
        try await setProperty(.ieco, on)
    }

    /// Signalton der Anlage (Eigenschaft) – zusätzlich zum Piep-Bit in jedem Befehl.
    public func setSound(_ on: Bool) async throws -> ACState {
        beep = on
        return try await setProperty(.sound, on)
    }

    /// Leistungsbegrenzung setzen: 100 (keine), 75 oder 50 Prozent.
    public func setRate(_ percent: Int) async throws -> ACState {
        let value = Self.nearestRate(percent)
        return try await run { [self] in
            var state = ACState()
            var readBack = false
            // Die Anlage verwirft Eigenschaftsbefehle, die zu dicht aufeinander folgen: zurücklesen, ggf. einmal wiederholen.
            for attempt in 0..<2 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1.5) }
                do {
                    _ = try client.send(Frame.setRateSelect(value))
                    state = carry(try queryState())
                } catch {
                    throw Self.unclearOutcome(error)
                }
                let props = try? queryProperties()
                applyProperties(props, to: &state)
                readBack = props?.1[.rateSelect] != nil
                if state.ratePercent == value { break }
                AppLog.write(attempt == 0
                    ? LogText.t("log.device.rateRetry", "Leistungsbegrenzung {value} % nicht übernommen – wiederhole", ["value": String(value)])
                    : LogText.t("log.device.rateGaveUp", "Leistungsbegrenzung {value} % nicht übernommen – aufgegeben", ["value": String(value)]))
            }
            remember(state)
            // Nicht übernommen (z. B. 75 % bei der PortaSplit): als Fehler melden statt still den alten Wert.
            // Ließ sich der Wert gar nicht zurücklesen, bleibt es beim Stand ohne Fehler (Ergebnis unbekannt).
            if readBack, state.ratePercent != value { throw MideaError.commandNotApplied(state) }
            return state
        }
    }

    private func setProperty(_ prop: PropertyId, _ on: Bool) async throws -> ACState {
        try await run { [self] in
            var state = ACState()
            var applied = true
            for attempt in 0..<2 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1.5) }
                do {
                    _ = try client.send(Frame.setProperty(prop, on))
                    state = carry(try queryState())
                } catch {
                    throw Self.unclearOutcome(error)
                }
                let result = try? queryProperties()
                applyProperties(result, to: &state)
                // Nicht übernommen? (Außen leise z. B. nur beim Kühlen/Heizen) – einmal nachfassen.
                // Ließ sich der Wert nicht zurücklesen, gilt er als übernommen (Ergebnis unbekannt).
                applied = result?.0[prop] == nil || result?.0[prop] == on
                if applied { break }
                AppLog.write(attempt == 0
                    ? LogText.t("log.device.propertyRetry", "{property} = {value} nicht übernommen – wiederhole", ["property": "\(prop)", "value": "\(on)"])
                    : LogText.t("log.device.propertyGaveUp", "{property} = {value} nicht übernommen – aufgegeben", ["property": "\(prop)", "value": "\(on)"]))
            }
            remember(state)
            if !applied { throw MideaError.commandNotApplied(state) }
            return state
        }
    }

    /// Display am Gerät umschalten (die Anlage kennt nur „umschalten“). Ohne blinde Wiederholung: ging
    /// nur die Antwort verloren, schaltete eine Wiederholung das Display wieder zurück. Darum einmal senden,
    /// danach `displayOn` lesen und nur bei unverändertem Wert genau einmal nachfassen.
    public func toggleDisplay() async throws -> ACState {
        try await run { [self] in
            let before = try freshState().displayOn
            var state: ACState
            for attempt in 0..<2 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1.5) }
                let reply = try? stateFrom(client.sendSingle(Frame.toggleDisplay(beep: beep), expect: 0xC0))
                do {
                    state = carry(try reply ?? queryState())
                } catch {
                    throw Self.unclearOutcome(error)
                }
                if state.displayOn != before || attempt == 1 {
                    if state.displayOn == before { AppLog.write(LogText.t("log.device.displayGaveUp", "Anzeige umschalten nicht übernommen – aufgegeben")) }
                    remember(state)
                    return state
                }
                AppLog.write(LogText.t("log.device.displayRetry", "Anzeige umschalten nicht übernommen – wiederhole einmal"))
            }
            preconditionFailure("unerreichbar")
        }
    }

    public func disconnect() {
        queue.async { [client] in client.disconnect() }
    }

    /// Sperren der Wegwahl aufheben (WLAN-Sperre, Cloud-Rückzug nach „Anlage offline“) – für ein manuelles
    /// „Jetzt aktualisieren“, damit sofort wieder alle Wege probiert werden.
    public func resetBackoff() {
        queue.async { [client] in client.resetBackoff() }
    }

    // MARK: - intern (nur auf `queue`)

    private func remember(_ state: ACState) {
        last = state
        lastAt = Date()
    }

    /// Letzter Stand, wenn er höchstens `freshStateAge` alt ist; sonst eine neue Abfrage.
    private func freshState() throws -> ACState {
        if let last, let lastAt, Date().timeIntervalSince(lastAt) <= Self.freshStateAge { return last }
        return try queryState()
    }

    /// Werte, die nicht in der Zustandsmeldung stehen, vom letzten Stand übernehmen.
    private func carry(_ new: ACState) -> ACState {
        var s = new
        guard let last else { return s }
        s.outSilent = last.outSilent
        s.selfClean = last.selfClean
        s.ieco = last.ieco
        s.sound = last.sound
        s.ratePercent = last.ratePercent
        s.powerWatts = last.powerWatts
        s.totalEnergyKWh = last.totalEnergyKWh
        return s
    }

    private func applyProperties(_ result: ([PropertyId: Bool], [PropertyId: [UInt8]])?, to state: inout ACState) {
        guard let (props, raw) = result else { return }
        if let r = raw[.rateSelect]?.first { state.ratePercent = Int(r) }
        if let v = props[.outSilent] { state.outSilent = v }
        if let v = props[.selfClean] { state.selfClean = v }
        if let v = props[.ieco] { state.ieco = v }
        if let v = props[.sound] { state.sound = v; beep = v }
    }

    private func queryState() throws -> ACState {
        guard let s = try stateFrom(client.send(Frame.getState(), expect: 0xC0)) else {
            throw MideaError.invalidResponse(LogText.t("kit.device.noState", "keine Zustandsmeldung"))
        }
        return s
    }

    /// `optional`: nur ein Versuch auf dem aktuellen Weg, ein Fehler sperrt das WLAN nicht.
    private func queryProperties(optional: Bool = false) throws -> ([PropertyId: Bool], [PropertyId: [UInt8]]) {
        var out: [PropertyId: Bool] = [:]
        var raw: [PropertyId: [UInt8]] = [:]
        let frame = Frame.getProperties([.ieco, .outSilent, .selfClean, .sound, .rateSelect])
        for frame in try (optional ? client.sendSingle(frame, expect: 0xB1) : client.send(frame, expect: 0xB1)) {
            if case .properties(let p, let r)? = try? Response.parse(frame) {
                out.merge(p) { $1 }
                raw.merge(r) { $1 }
            }
        }
        return (out, raw)
    }

    private func queryEnergy() throws -> (Double?, Double?)? {
        // Verbrauch ist optional: ein Fehler sperrt das WLAN nicht.
        for frame in try client.sendSingle(Frame.getGroupData(4), expect: 0xC1) {
            if case .energy(let w, let kwh)? = try? Response.parse(frame) { return (w, kwh) }
        }
        return nil
    }

    private func stateFrom(_ frames: [Data]) -> ACState? {
        for frame in frames.reversed() {
            if case .state(let s)? = try? Response.parse(frame) { return s }
        }
        return nil
    }

    private var idleWork: DispatchWorkItem?

    func runRaw<T: Sendable>(_ body: @escaping @Sendable (any FrameTransport) throws -> T) async throws -> T {
        try await run { [client] in try body(client) }
    }

    /// Führt einen Auftrag seriell aus. Danach wird die Verbindung nach `idleDisconnect` Sekunden getrennt,
    /// weil die Anlage nur eine Verbindung gleichzeitig annimmt (sonst sperrt sie andere Apps aus).
    public var idleDisconnect: TimeInterval {
        get { shared.withLock { $0.idleDisconnect } }
        set { shared.withLock { $0.idleDisconnect = newValue } }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                idleWork?.cancel()
                client.setDeadline(Date().addingTimeInterval(commandBudget))
                if client.mode == .cloud { onPhase?(.reading) }
                let result = Result { try body() }
                client.setDeadline(nil)
                cont.resume(with: result)
                let work = DispatchWorkItem { [client] in client.idle() }
                idleWork = work
                queue.asyncAfter(deadline: .now() + idleDisconnect, execute: work)
            }
        }
    }
}

extension PortaSplitDevice {
    /// Rohantworten der Gruppenabfragen (0x41 0x21 0x01 0x40|n) – für Diagnose und Analyse.
    public func rawGroups(_ groups: [UInt8]) async throws -> [UInt8: Data] {
        try await runRaw { client in
            var out: [UInt8: Data] = [:]
            for g in groups {
                if let frames = try? client.sendSingle(Frame.getGroupData(g), expect: 0xC1) {
                    // Gruppenbyte prüfen: ein verspäteter Rahmen einer anderen Gruppe gehört nicht hierher.
                for f in frames where Self.isGroupReply(f, g) {
                        out[g] = f
                    }
                }
            }
            return out
        }
    }

    /// Antwort 0xC1 genau dieser Gruppe (Byte 13, unteres Halbbyte)?
    static func isGroupReply(_ f: Data, _ group: UInt8) -> Bool {
        f.count > 14 && f[f.startIndex + 10] == 0xC1 && f[f.startIndex + 13] & 0x0F == group & 0x0F
    }
}

extension PortaSplitDevice {
    /// Gerätekennung aus der undokumentierten Eigenschaft 0x00AB (ASCII, z. B. „00AC000111171206000046091012“).
    public func identifier() async throws -> String? {
        for f in try await query([0xB1, 1, 0xAB, 0x00]) {
            let b = [UInt8](f.dropFirst(10).dropLast(2))
            guard b.count > 6, b[0] == 0xB1, b[2] == 0xAB, b[3] == 0x00 else { continue }
            let size = Int(b[5])
            let text = String(decoding: b[6..<min(b.count, 6 + size)], as: UTF8.self)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Beliebige Abfrage (Rahmentyp 0x03, nur lesend) – für Analyse. Liefert alle Antwortrahmen.
    public func query(_ payload: [UInt8]) async throws -> [Data] {
        try await runRaw { client in try client.sendSingle(Frame.build(.query, payload), expect: nil) }
    }
}
