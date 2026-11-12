import Foundation
import Synchronization

/// Blockierende TCP-Verbindung zur Anlage (Port 6444) mit V3-Anmeldung.
/// Nicht threadsicher – `PortaSplitDevice` ruft sie nur aus einer seriellen Queue auf.
final class LANClient {
    let host: String
    let port: UInt16
    let deviceId: UInt64
    let token: Data
    let key: Data

    /// Wird vom Hauptthread gesetzt und auf der Geräte-Queue gelesen – darum im `Mutex`.
    var quietErrors: Bool {
        get { quiet.withLock { $0 } }
        set { quiet.withLock { $0 = newValue } }
    }
    private let quiet = Mutex(false)
    private var socket: NetSocket?
    private var codec = V3Codec()
    private var authenticatedAt: Date?
    private var pending: [Data] = []
    /// Zeitüberschreitungen beim Lesen in einer schon angemeldeten Sitzung hintereinander: die erste
    /// trennt nicht, erst die zweite gilt als kaputte Sitzung.
    private var readTimeoutsInRow = 0
    /// Der zuletzt gesendete Rahmen ging hinaus, bevor der Fehler kam (ob er ankam, ist offen).
    private var wroteFrame = false
    /// Der letzte endgültige Fehler kam nach dem Senden des Rahmens.
    private(set) var failedAfterWrite = false
    /// Letzte gelungene Anmeldung bzw. Antwort unter dieser Adresse (Hinweis für „belegt“).
    var lastReachableAt: Date?
    /// So lange nach der letzten Antwort gilt „abgewiesen“/„keine Anmeldeantwort“ als „belegt“.
    static let busyEvidenceWindow: TimeInterval = 5 * 60
    var recentlyReachable: Bool {
        lastReachableAt.map { Date().timeIntervalSince($0) < Self.busyEvidenceWindow } ?? false
    }
    static var notConnectedText: String { LogText.t("kit.lan.notConnected", "nicht verbunden") }
    static var closedText: String { LogText.t("reason.closed", "Die Anlage hat die Verbindung geschlossen.") }
    /// Spätester Zeitpunkt für den laufenden Auftrag (gesetzt von `PortaSplitDevice.run`): alle Warte-
    /// zeiten werden darauf gekürzt, Wiederholungen nur mit genug Restzeit. nil = ohne Gesamtlimit.
    var deadline: Date?
    /// Verbindungsschritt für die Anzeige (wird einmal nach `init` gesetzt, dann nur auf der Geräte-Queue gelesen).
    var onPhase: (@Sendable (ConnectPhase) -> Void)?
    /// Mindest-Restzeit für eine Wiederholung (Verbinden + Anmelden + Lesen brauchen sonst nur halb Platz).
    static let minRetryBudget: TimeInterval = 1.0
    /// Höchstens so viele Zusatzrahmen nach der ersten Antwort einsammeln.
    static let maxExtraFrames = 8
    /// Die Gegenstelle hat die Verbindung selbst geschlossen (Lesen lieferte 0 Byte); getrennt vom Text der Meldung.
    private var closedByPeer = false
    /// Lesepuffer, einmal angelegt statt je Paket (4 KB).
    private var readBuffer = [UInt8](repeating: 0, count: 4096)
    private static let authLifetime: TimeInterval = 12 * 3600
    #if os(Windows)
    static var localNetworkHint: String { LogText.t("kit.lan.localNetworkWindows", "Die Anlage ist im Netz nicht erreichbar. Ist der PC im selben WLAN/Netz wie die Anlage? Sonst Windows-Firewall bzw. Netzwerkprofil („Privat“) prüfen.") }
    #else
    static var localNetworkHint: String { LogText.t("kit.lan.localNetworkMac", "macOS lässt die App nicht ins lokale Netzwerk. Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk → Klimacontrol einschalten (oder Anlage nicht im WLAN).") }
    #endif
    /// Meldung bei belegter Anlage: sie nimmt nur eine Verbindung gleichzeitig an.
    /// Text hinter „Die Anlage ist gerade belegt.“ (`MideaError.busy`).
    static var busyHint: String { LogText.t("reason.busyHint", "Vermutlich hält sie die Klimacontrol-App (Diagnose offen) oder die Midea-App. Die andere App schließen oder 10 Sekunden warten und erneut versuchen.") }
    /// Meldung, wenn das Zeitlimit eines Auftrags erreicht ist.
    static var budgetHint: String { LogText.t("kit.lan.budget", "Die Anlage hat nicht rechtzeitig geantwortet (Zeitlimit erreicht). Erneut versuchen.") }

    init(host: String, port: UInt16, deviceId: UInt64, token: Data, key: Data) {
        self.host = host
        self.port = port
        self.deviceId = deviceId
        self.token = token
        self.key = key
    }

    deinit { disconnect() }

    func disconnect() {
        if let socket {
            socket.close()
            AppLog.debug(LogText.t("log.lan.disconnected", "Verbindung zu {host} getrennt", ["host": host]))
        }
        socket = nil
        authenticatedAt = nil
        codec = V3Codec()
        pending.removeAll()
        readTimeoutsInRow = 0
    }

    /// Sendet einen Befehlsrahmen und gibt alle Antwortrahmen zurück (inkl. spontaner Meldungen).
    /// `expect` = erwartete Antwort-ID (Byte 10, z. B. 0xC0 Zustand, 0xC1 Gruppe, 0xB1 Eigenschaften):
    /// Die Anlage schiebt manchmal unaufgeforderte Meldungen (Frame-Typ 0x04/0x05) voran und liefert die
    /// eigentliche Antwort verspätet – dann wird weitergelesen, bis sie da ist.
    func send(_ frame: Data, retries: Int = 2, expect: UInt8? = nil) throws -> [Data] {
        failedAfterWrite = false
        return try send(frame, retries: retries, expect: expect, sentBefore: false)
    }

    private func send(_ frame: Data, retries: Int, expect: UInt8?, sentBefore: Bool) throws -> [Data] {
        let hadSession = isAuthenticated
        do {
            let frames = try sendOnce(frame, expect: expect)
            readTimeoutsInRow = 0
            lastReachableAt = Date()
            return frames
        } catch let error as MideaError {
            // Zeitüberschreitung in einer bestehenden Sitzung: die Sitzung bleibt beim ersten Mal stehen (die
            // verspätete Antwort wird vor dem nächsten Senden verworfen). Sonst trennen und neu anmelden.
            if case .timeout = error, hadSession, readTimeoutsInRow == 0 {
                readTimeoutsInRow += 1
            } else {
                disconnect()
            }
            // Nur der endgültige Fehlschlag ist ein Fehler; Zwischenversuche nur im Debug-Protokoll
            // (sonst stehen für einen Ausfall drei Fehlerzeilen da).
            var isFinal = retries == 0
            if case .authenticationFailed = error { isFinal = true }
            if let deadline, deadline.timeIntervalSinceNow < Self.minRetryBudget { isFinal = true }
            if isFinal {
                failedAfterWrite = sentBefore || wroteFrame
                if !quietErrors { AppLog.error(LogText.t("log.lan.error", "{host}: {error}", ["host": host, "error": error.localizedDescription])) }
                throw error
            }
            AppLog.debug(LogText.t("log.lan.retry", "{host}: {error} – wiederhole", ["host": host, "error": error.localizedDescription]))
            // Ging der Rahmen schon hinaus, braucht die Anlage dieselbe Pause wie zwischen Stellversuchen.
            if wroteFrame, let pause = try? budgeted(1.5) { Thread.sleep(forTimeInterval: pause) }
            return try send(frame, retries: retries - 1, expect: expect, sentBefore: sentBefore || wroteFrame)
        }
    }

    /// Antwort-ID eines Rahmens (Byte 10), oder nil bei zu kurzem Rahmen.
    private static func responseId(_ frame: Data) -> UInt8? {
        frame.count > 10 ? frame[frame.startIndex + 10] : nil
    }

    private var isAuthenticated: Bool {
        if let at = authenticatedAt, socket != nil, Date().timeIntervalSince(at) < Self.authLifetime { return true }
        return false
    }

    /// Wartezeit, auf die Restzeit des Auftrags gekürzt; ist sie aufgebraucht, Abbruch mit klarer Meldung.
    func budgeted(_ t: TimeInterval) throws -> TimeInterval {
        guard let deadline else { return t }
        let rest = deadline.timeIntervalSinceNow
        if rest <= 0.05 { throw MideaError.connectionFailed(.budget) }
        return min(t, rest)
    }

    private func sendOnce(_ frame: Data, expect: UInt8?) throws -> [Data] {
        wroteFrame = false
        try ensureSession()
        AppLog.debug("→ \(host) \(Self.label(frame)) \(frame.hex)")
        // Alte, verspätet eingetroffene Rahmen verwerfen – auch die, die noch im Socket stecken –, damit sie
        // nicht dieser Anfrage zugeordnet werden.
        try drainSocket()
        let packet = try V2Packet.encode(deviceId: deviceId, frame: frame)
        try write(try codec.encodeEncrypted(packet))
        wroteFrame = true
        var frames: [Data] = []
        let first = try readPacket(timeout: try budgeted(4))
        frames.append(try decodeFrame(first))
        // Kurz (0,1 s reicht laut Messung) auf Zusatzmeldungen warten – nur, wenn die erwartete Antwort noch fehlt.
        // Nachzügler landen in `pending` und werden bei der nächsten Sendung verworfen.
        if expect == nil || !frames.contains(where: { Self.responseId($0) == expect }) {
            // Begrenzt: eine Anlage, die ununterbrochen Meldungen schickt, hielte die Queue sonst endlos fest.
            for _ in 0..<Self.maxExtraFrames {
                guard let more = try? readPacket(timeout: 0.1) else { break }
                if let f = try? decodeFrame(more) { frames.append(f) }
            }
        }
        // Erwartete Antwort noch nicht dabei (nur unaufgeforderte Meldungen gekommen)? Gezielt weiterlesen.
        if let expect, !frames.contains(where: { Self.responseId($0) == expect }) {
            for _ in 0..<4 {
                guard let wait = try? budgeted(2), let more = try? readPacket(timeout: wait) else { break }
                if let f = try? decodeFrame(more) {
                    frames.append(f)
                    if Self.responseId(f) == expect { break }
                }
            }
        }
        for f in frames { AppLog.debug("← \(host) \(Self.label(f)) \(f.hex)") }
        return frames
    }

    private func decodeFrame(_ packet: Data) throws -> Data {
        let (type, payload) = try codec.decode(packet)
        guard type == .encryptedResponse else { throw MideaError.protocolError(LogText.t("kit.packet.unexpectedHandshake", "Unerwartete Handshake-Antwort")) }
        return try V2Packet.decode(payload)
    }

    /// Verwirft alles, was schon im Socket bzw. Puffer liegt (Nachzügler früherer Anfragen). Die Rohdaten laufen
    /// durch den Decoder, damit dessen Puffer an der Paketgrenze bleibt.
    private func drainSocket() throws {
        pending.removeAll()
        guard let socket else { return }
        var dropped = 0
        while socket.wait(timeoutMs: 0) > 0 {
            let n = socket.receive(into: &readBuffer)
            if n == 0 { throw MideaError.connectionFailed(.closed) }
            if n < 0 { break }
            dropped += codec.feed(Data(readBuffer[0..<n])).count
        }
        if dropped > 0 { AppLog.debug(LogText.t("log.lan.droppedFrames", "{host}: {count} verspätete Rahmen verworfen", ["host": host, "count": String(dropped)])) }
    }

    private func ensureSession() throws {
        if isAuthenticated { return }
        disconnect()
        AppLog.debug(LogText.t("log.lan.connecting", "Verbinde mit {host}:{port} (TCP, V3) …", ["host": host, "port": String(port)]))
        onPhase?(.searching)
        do {
            try connectSocket()
        } catch MideaError.refused where recentlyReachable {
            // Eben ging es noch unter dieser Adresse – dann ist „abgewiesen“ ein belastbarer Hinweis auf „belegt“.
            throw MideaError.busy(.otherApp)
        }
        AppLog.debug(LogText.t("log.lan.handshake", "TCP verbunden, sende Handshake (Token {bytes} Byte, geschwärzt)", ["bytes": String(token.count)]))
        onPhase?(.handshake)
        try write(codec.encodeHandshake(token: token))
        let response: Data
        do {
            closedByPeer = false
            response = try readPacket(timeout: try budgeted(4))
        } catch MideaError.timeout {
            // Keine Antwort ist kein Token-Fehler: „belegt“ nur, wenn die Anlage hier kurz vorher
            // antwortete; sonst neutral „antwortet nicht“ (z. B. alte IP gehört jetzt einem anderen Gerät).
            throw recentlyReachable ? MideaError.busy(.otherApp) : MideaError.timeout
        } catch MideaError.connectionFailed where closedByPeer {
            // Verbindung angenommen und sofort wieder geschlossen: die Anlage hält schon eine andere.
            throw MideaError.busy(.otherApp)
        }
        let (type, payload) = try codec.decode(response)
        guard type == .handshakeResponse else { throw MideaError.authenticationFailed(LogText.t("kit.lan.unexpectedType", "unerwarteter Pakettyp")) }
        codec.localKey = try V3Codec.localKey(key: key, response: payload)
        authenticatedAt = Date()
        lastReachableAt = authenticatedAt
        AppLog.debug(LogText.t("log.lan.handshakeOk", "Handshake ok, Sitzungsschlüssel ausgehandelt (gültig 12 h)"))
        // msmart-ng wartet nach der Anmeldung kurz, bevor es Befehle schickt.
        Thread.sleep(forTimeInterval: 0.5)
        onPhase?(.reading)
    }

    private func connectSocket() throws {
        let wait = try budgeted(5)
        socket = try NetSocket.connectTCP(host: host, port: port, timeoutMs: Int32(max(1, wait * 1000)))
    }

    private func write(_ data: Data) throws {
        guard let socket else { throw MideaError.connectionFailed(.notConnected) }
        try socket.send(data)
    }

    /// Kurzname eines Rahmens fürs Protokoll (Richtung egal).
    static func label(_ frame: Data) -> String {
        let f = [UInt8](frame)
        guard f.count > 13 else { return "?" }
        let type: String
        switch f[9] {
        case 0x02: type = LogText.t("log.frame.set", "Stellbefehl")
        case 0x03: type = LogText.t("log.frame.query", "Abfrage")
        case 0x04, 0x05: type = LogText.t("log.frame.notice", "Meldung")
        case 0x06: type = LogText.t("log.frame.fault", "Störmeldung")
        default: type = LogText.t("log.frame.type", "Typ {code}", ["code": String(format: "%02X", f[9])])
        }
        let what: String
        switch f[10] {
        case 0x40: what = LogText.t("log.frame.setState", "Zustand setzen")
        case 0x41: what = f[11] == 0x21 ? LogText.t("log.frame.group", "Gruppe {number}", ["number": String(f[13] & 0xF)]) : LogText.t("log.frame.state", "Zustand")
        case 0xB0: what = LogText.t("log.frame.setProperties", "Eigenschaften setzen")
        case 0xB1: what = LogText.t("log.frame.properties", "Eigenschaften")
        case 0xB5: what = LogText.t("log.frame.capabilities", "Fähigkeiten")
        case 0xC0: what = LogText.t("log.frame.state", "Zustand")
        case 0xC1: what = LogText.t("log.frame.group", "Gruppe {number}", ["number": String(f[13] & 0xF)])
        default: what = String(format: "0x%02X", f[10])
        }
        return "[\(type) · \(what)]"
    }

    /// Liest bis ein vollständiges 8370-Paket da ist.
    private func readPacket(timeout: TimeInterval) throws -> Data {
        if !pending.isEmpty { return pending.removeFirst() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw MideaError.timeout }
            guard let socket else { throw MideaError.connectionFailed(.notConnected) }
            let r = socket.wait(timeoutMs: Int32(remaining * 1000))
            if r == 0 { throw MideaError.timeout }
            if r < 0 { throw NetSocket.failure(NetSocket.lastError) }
            let n = socket.receive(into: &readBuffer)
            if n == 0 { closedByPeer = true; throw MideaError.connectionFailed(.closed) }
            if n < 0 { throw NetSocket.failure(NetSocket.lastError) }
            pending += codec.feed(Data(readBuffer[0..<n]))
            if !pending.isEmpty { return pending.removeFirst() }
        }
    }
}
