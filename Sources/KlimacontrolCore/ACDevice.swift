import Foundation
import MideaKit

/// Was der Kern von einer Anlage braucht. `PortaSplitDevice` erfüllt es; Tests setzen ein nachgebildetes Gerät ein.
/// `Sendable`: Der Kern ruft die async-Methoden vom MainActor aus auf, sie laufen aber außerhalb davon (Swift 6).
/// Umsetzungen müssen ihren Zustand selbst schützen (`PortaSplitDevice`: Lock bzw. serielle Queue).
public protocol ACDevice: AnyObject, Sendable {
    var connectionMode: ConnectionMode { get set }
    var connectionPath: ConnectionPath? { get }
    var beep: Bool { get set }
    func refresh() async throws -> ACState
    func refreshFast(extras: Bool) async throws -> ACState
    /// `full == false` lässt die Zusatzabfrage des zweiten Innenfühlers (0x00E0) weg – reicht für den Verlauf.
    func diagnostics(full: Bool) async throws -> Diagnostics
    func rawGroups(_ groups: [UInt8]) async throws -> [UInt8: Data]
    /// Hebt die Sperren der Wegwahl auf (WLAN-Sperre nach Fehler, Cloud-Backoff bei „Anlage offline“), damit die
    /// nächste Abfrage wieder alle Wege probiert.
    func resetBackoff()
    func identifier() async throws -> String?
    func update(_ change: @escaping @Sendable (inout ACState) -> Void) async throws -> ACState
    func setOutdoorSilent(_ on: Bool) async throws -> ACState
    func setSelfClean(_ on: Bool) async throws -> ACState
    func setIECO(_ on: Bool) async throws -> ACState
    func setSound(_ on: Bool) async throws -> ACState
    func setRate(_ percent: Int) async throws -> ACState
    func toggleDisplay() async throws -> ACState
    func apply(_ scene: ACScene) async throws -> ACState
    func disconnect()
    /// Meldet die Schritte beim Verbinden (Anlage suchen · Anmelden · Werte lesen) für die Startanzeige.
    /// Geräte ohne eigene Meldung erben die leere Umsetzung unten; der Kern zeigt dann nur „Anlage suchen“.
    var onPhase: (@Sendable (ConnectPhase) -> Void)? { get set }
}

extension ACDevice {
    public var onPhase: (@Sendable (ConnectPhase) -> Void)? {
        get { nil }
        set {}
    }
}

extension PortaSplitDevice: ACDevice {}

/// Baut aus einer Einrichtung das Gerät (Weg, Cloud-Zugang).
public typealias ACDeviceFactory = @MainActor (DeviceConfig, ConnectionMode, CloudCredentials?) throws -> any ACDevice

/// Midea-Konto für den Cloud-Weg: laden, prüfen, ablegen, entfernen. Standard ist der Geheimnisspeicher des
/// Systems (macOS Schlüsselbund, Windows Anmeldeinformationsverwaltung); Tests nehmen einen Speicher im RAM.
public struct CloudAccountStore {
    public var load: () -> CloudCredentials?
    /// Legt das Konto ab. Wirft, wenn es danach nicht wirklich im Geheimnisspeicher steht – dann gilt die
    /// Anmeldung als gescheitert (sonst zeigte die Oberfläche „angemeldet“ ohne gespeichertes Konto).
    public var save: (CloudCredentials) throws -> Void
    /// Entfernt Konto und gespeicherte Cloud-Sitzung.
    public var clear: () -> Void
    /// Entfernt nur die gespeicherte Cloud-Sitzung (sie gilt für eine Anlage), das Konto bleibt.
    public var clearSession: () -> Void
    /// Meldet sich einmal an und prüft, ob die Anlage im Konto ist. Wirft mit lesbarer Meldung.
    public var verify: (CloudCredentials, DeviceConfig) async throws -> Void

    public init(load: @escaping () -> CloudCredentials?, save: @escaping (CloudCredentials) throws -> Void,
                clear: @escaping () -> Void, verify: @escaping (CloudCredentials, DeviceConfig) async throws -> Void,
                clearSession: @escaping () -> Void = {}) {
        self.load = load
        self.save = save
        self.clear = clear
        self.clearSession = clearSession
        self.verify = verify
    }

    public static var system: CloudAccountStore {
        CloudAccountStore(
            load: { CloudKeychain.load() },
            save: { try CloudKeychain.store($0) },
            clear: { CloudKeychain.clear(); CloudSessionStore.clear() },
            verify: { creds, cfg in
                let client = CloudControlClient(account: creds.account, password: creds.password,
                                                deviceId: cfg.deviceId, serialSuffix: cfg.bleSerial ?? "")
                try await client.verifyLogin()
            },
            clearSession: { CloudSessionStore.clear() })
    }
}

public enum CloudAccountError: Error, LocalizedError, Equatable {
    /// Das Konto steht nach dem Speichern nicht im Geheimnisspeicher.
    case notSaved

    public var errorDescription: String? {
        switch self {
        case .notSaved:
            return "Das Midea-Konto wurde nicht im Schlüsselbund gespeichert. Prüfe den Zugriff auf den Schlüsselbund "
                + "und melde dich noch einmal an."
        }
    }
}
