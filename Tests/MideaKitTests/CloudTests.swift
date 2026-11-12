import Synchronization
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MideaKit

/// Nachgebildete Midea-Cloud: beantwortet Anfragen ohne Netz (Fake-`URLProtocol`) und zählt sie.
final class FakeCloudProtocol: URLProtocol {
    /// Antwort; das JSON wird gleich serialisiert, damit die Antwort `Sendable` ist.
    struct Reply: Sendable {
        var status: Int
        var body: Data
        init(status: Int = 200, json: [String: Any]) {
            self.status = status
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
    }
    typealias Handler = @Sendable (_ path: String, _ body: Data) -> Reply
    private struct State { var handler: Handler?; var paths: [String] = [] }
    private static let state = Mutex(State())

    static func reset(_ h: @escaping Handler) {
        state.withLock { $0 = State(handler: h) }
    }
    static var count: Int { state.withLock { $0.paths.count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let alias = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "alias" }?.value
        let path = (url.host ?? "") + (alias ?? url.path)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let h = Self.state.withLock { s -> Handler? in
            s.paths.append(path)
            return s.handler
        }
        let reply = h?(path, body) ?? Reply(status: 500, json: [:])
        let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CloudTests: XCTestCase {
    static let deviceId: UInt64 = 111122223333444
    static let aesKey = Data(repeating: 0x11, count: 16)
    static let aesIv = Data(repeating: 0x22, count: 16)
    static let innerFrame = Data([0xAA, 0x05, 0x01, 0x02, 0x03, 0x04])

    private var savedSession: URLSession!
    private var savedBackend: (any KeychainStore)!
    private var keychain: InMemoryKeychain!

    override func setUp() {
        savedSession = MideaCloud.urlSession
        savedBackend = SecretStore.backend
        keychain = InMemoryKeychain()
        SecretStore.backend = keychain
        MideaCloud.urlSession = MideaCloud.makeURLSession(protocolClasses: [FakeCloudProtocol.self])
    }

    override func tearDown() {
        MideaCloud.urlSession = savedSession
        SecretStore.backend = savedBackend
        FakeCloudProtocol.reset { _, _ in .init(status: 500, json: [:]) }
    }

    // MARK: Antworten

    static func smartOK(_ data: [String: Any]) -> FakeCloudProtocol.Reply { .init(json: ["code": 0, "data": data]) }

    static func loginData() throws -> [String: Any] {
        let (k, iv) = SmartHomeClient.tmpKeyIv()
        return ["mdata": ["accessToken": "AT"],
                "accessToken": try MideaCrypto.encryptCBC(key: k, iv: iv, aesKey).hex,
                "randomData": try MideaCrypto.encryptCBC(key: k, iv: iv, aesIv).hex]
    }

    static func sendReply() throws -> String {
        let packet = CloudPacket.encode(deviceId: deviceId, frame: innerFrame)
        return try MideaCrypto.encryptCBC(key: aesKey, iv: aesIv, Data(CloudControlClient.csv(packet).utf8)).hex
    }

    /// Funktionierende MSmartHome-Cloud; `send` kann überschrieben werden.
    func healthyCloud(send: (@Sendable () -> FakeCloudProtocol.Reply)? = nil) throws {
        let login = try Self.smartOK(Self.loginData()), reply = try Self.sendReply()
        FakeCloudProtocol.reset { path, _ in
            if path.hasSuffix("/v1/user/login/id/get") { return Self.smartOK(["loginId": "LID"]) }
            if path.hasSuffix("/mj/user/login") { return login }
            if path.hasSuffix("/v1/appliance/user/list/get") {
                return Self.smartOK(["list": [["id": "\(Self.deviceId)", "type": "0xAC", "name": "PS"]]])
            }
            if path.hasSuffix("/v1/appliance/transparent/send") { return send?() ?? Self.smartOK(["reply": reply]) }
            return .init(status: 404, json: [:])
        }
    }

    func makeSession(_ clock: TestClock) -> MideaCloudSession {
        MideaCloudSession(account: "nutzer@example.com", password: "pw", now: { clock.now })
    }

    // MARK: Sitzung

    func testLoginOnceThenReuse() async throws {
        try healthyCloud()
        let s = makeSession(TestClock())
        let a = try await s.send(Data([0x41]), deviceId: Self.deviceId)
        let b = try await s.send(Data([0x41]), deviceId: Self.deviceId)
        XCTAssertEqual(a, [Self.innerFrame]); XCTAssertEqual(b, [Self.innerFrame])
        let st = await s.status
        XCTAssertEqual(st.logins, 1)
        XCTAssertEqual(FakeCloudProtocol.count, 2 + 1 + 2, "Anmeldung (2) + Liste (1) + 2 Befehle")
        let saved = try CloudSessionStore.lookup(account: "nutzer@example.com", deviceId: Self.deviceId)
        XCTAssertEqual(saved?.applianceId, "\(Self.deviceId)")
    }

    func testRestoredSessionNeedsNoLogin() async throws {
        try healthyCloud()
        try CloudSessionStore.store(CloudSession(account: "nutzer@example.com", cloud: "MSmartHome", accessToken: "AT",
                                                 aesKeyHex: Self.aesKey.hex, aesIvHex: Self.aesIv.hex, sessionId: "",
                                                 applianceId: "\(Self.deviceId)", savedAt: TestClock().now,
                                                 deviceId: Self.deviceId))
        let s = makeSession(TestClock())
        _ = try await s.send(Data([0x41]), deviceId: Self.deviceId)
        let logins = await s.status.logins
        XCTAssertEqual(logins, 0)
        XCTAssertEqual(FakeCloudProtocol.count, 1)
    }

    func testWrongPasswordStopsUntilUserActs() async throws {
        FakeCloudProtocol.reset { path, _ in
            path.contains("mapp") ? .init(json: ["errorCode": 3101, "msg": "password error"])
                                  : .init(json: ["code": 3101, "msg": "password error"])
        }
        let s = makeSession(TestClock())
        do { _ = try await s.send(Data([0x41]), deviceId: Self.deviceId); XCTFail() } catch let e as MideaCloud.CloudError {
            XCTAssertEqual(e.kind, .wrongCredentials)
            XCTAssertTrue(e.errorDescription!.hasSuffix("(3101)"), e.errorDescription!)
        }
        let first = FakeCloudProtocol.count
        XCTAssertEqual(first, 2, "je Zugang nur die erste Anfrage")
        for _ in 0..<5 { _ = try? await s.send(Data([0x41]), deviceId: Self.deviceId) }
        XCTAssertEqual(FakeCloudProtocol.count, first, "gestoppt: keine weitere Anmeldung")
        let st = await s.status
        XCTAssertNotNil(st.stoppedReason)
        await s.userActed()
        _ = try? await s.send(Data([0x41]), deviceId: Self.deviceId)
        XCTAssertGreaterThan(FakeCloudProtocol.count, first)
    }

    func testBackoffAfterFailedLogin() async throws {
        FakeCloudProtocol.reset { _, _ in .init(status: 503, json: [:]) }
        let clock = TestClock()
        let s = makeSession(clock)
        _ = try? await s.send(Data([0x41]), deviceId: Self.deviceId)
        let first = FakeCloudProtocol.count
        do { _ = try await s.send(Data([0x41]), deviceId: Self.deviceId); XCTFail() } catch let e as MideaCloud.CloudError {
            XCTAssertEqual(e.kind, .paused)
        }
        XCTAssertEqual(FakeCloudProtocol.count, first, "Rückzug: kein Netz")
        clock.advance(61)
        _ = try? await s.send(Data([0x41]), deviceId: Self.deviceId)
        let second = FakeCloudProtocol.count
        XCTAssertGreaterThan(second, first)
        clock.advance(61) // Rückzug jetzt 120 s
        _ = try? await s.send(Data([0x41]), deviceId: Self.deviceId)
        XCTAssertEqual(FakeCloudProtocol.count, second, "Rückzug verdoppelt")
    }

    func testSessionErrorReloginOnlyOnce() async throws {
        let flag = TestClock() // nur als Schalter: Zeit vorgerückt = Sitzung abgelaufen
        let start = flag.now
        let reply = try Self.sendReply()
        try healthyCloud(send: {
            flag.now > start ? .init(json: ["code": 3004, "msg": "token expired"]) : Self.smartOK(["reply": reply])
        })
        let clock = TestClock()
        let s = makeSession(clock)
        _ = try await s.send(Data([0x41]), deviceId: Self.deviceId)
        clock.advance(120)
        flag.advance(1)
        do { _ = try await s.send(Data([0x41]), deviceId: Self.deviceId); XCTFail() } catch {}
        let logins = await s.status.logins
        XCTAssertEqual(logins, 2, "höchstens eine Neuanmeldung je Vorgang")
        let before = FakeCloudProtocol.count
        _ = try? await s.send(Data([0x41]), deviceId: Self.deviceId)
        let after = await s.status.logins
        XCTAssertEqual(after, 2, "innerhalb des Rückzugs keine weitere Anmeldung")
        XCTAssertLessThanOrEqual(FakeCloudProtocol.count - before, 1)
    }

    /// Kein Internet oder Midea-Störung (HTTP 5xx) sagt nichts über die Sitzung: Sie bleibt gespeichert, es gibt
    /// keine neue Anmeldung (die „Konto anderswo eingeloggt“ auslösen würde).
    func testNetworkErrorsKeepSession() async throws {
        let down = TestClock() // als Schalter: vorgerückt = Midea antwortet mit 503
        let start = down.now
        let reply = try Self.sendReply()
        try healthyCloud(send: { down.now > start ? .init(status: 503, json: [:]) : Self.smartOK(["reply": reply]) })
        let s = makeSession(TestClock())
        _ = try await s.send(Data([0x41]), deviceId: Self.deviceId)
        down.advance(1)
        for _ in 0..<3 {
            do { _ = try await s.send(Data([0x41]), deviceId: Self.deviceId); XCTFail() } catch let e as MideaCloud.CloudError {
                XCTAssertEqual(e.kind, .network)
            }
        }
        let st = await s.status
        XCTAssertEqual(st.logins, 1, "keine Neuanmeldung wegen Netzfehlern")
        XCTAssertTrue(st.active, "Sitzung bleibt")
        XCTAssertNotNil(try CloudSessionStore.lookup(account: "nutzer@example.com", deviceId: Self.deviceId), "gespeicherte Sitzung bleibt")
    }

    /// Zwei gleichzeitige Vorgänge ohne Sitzung melden sich nur einmal an.
    func testConcurrentCallsShareOneLogin() async throws {
        try healthyCloud()
        let s = makeSession(TestClock())
        async let a = s.send(Data([0x41]), deviceId: Self.deviceId)
        async let b = s.send(Data([0x41]), deviceId: Self.deviceId)
        _ = try await (a, b)
        let logins = await s.status.logins
        XCTAssertEqual(logins, 1)
    }

    func testBadKeyIsSessionErrorNotCrash() async throws {
        try healthyCloud(send: { Self.smartOK(["reply": Data(repeating: 0x33, count: 32).hex]) })
        let s = makeSession(TestClock())
        do { _ = try await s.send(Data([0x41]), deviceId: Self.deviceId); XCTFail() } catch let e as MideaCloud.CloudError {
            XCTAssertEqual(e.kind, .sessionExpired)
        }
        let logins = await s.status.logins
        XCTAssertEqual(logins, 1, "frische Anmeldung im selben Vorgang wird nicht wiederholt")
    }

    func testLockedKeychainDoesNotLogin() async throws {
        try healthyCloud()
        keychain.failReads = .unavailable(-25308)
        let s = makeSession(TestClock())
        do { _ = try await s.send(Data([0x41]), deviceId: Self.deviceId); XCTFail() } catch let e as MideaCloud.CloudError {
            XCTAssertEqual(e.kind, .keychainLocked)
        }
        XCTAssertEqual(FakeCloudProtocol.count, 0)
    }

    func testIncompleteLoginIsError() async throws {
        FakeCloudProtocol.reset { path, _ in
            if path.contains("mapp") { return .init(json: ["errorCode": 0, "result": ["loginId": "L"]]) }
            if path.hasSuffix("/v1/user/login/id/get") { return Self.smartOK(["loginId": "LID"]) }
            return Self.smartOK([:]) // Anmeldung ohne Token
        }
        let s = makeSession(TestClock())
        do { _ = try await s.appliances(kind: .smartHome); XCTFail() } catch let e as MideaCloud.CloudError {
            XCTAssertEqual(e.kind, .sessionExpired)
        }
    }

    // MARK: Anlage wählen, CSV

    func testPickApplianceFallbackOnlyWhenAllowed() throws {
        let one: [[String: Any]] = [["applianceCode": 42, "type": "0xAC"]]
        XCTAssertThrowsError(try CloudControlClient.pickAppliance(one, deviceId: 7))
        XCTAssertEqual(try CloudControlClient.pickAppliance(one, deviceId: 7, allowSingleFallback: true), "42")
        XCTAssertEqual(try CloudControlClient.pickAppliance(one, deviceId: 0), "42")
        XCTAssertEqual(try CloudControlClient.pickAppliance(one, deviceId: 42), "42", "applianceCode zählt wie id")
        let dryer: [[String: Any]] = [["id": "42", "type": "0xA1"]]
        XCTAssertThrowsError(try CloudControlClient.pickAppliance(dryer, deviceId: 0, allowSingleFallback: true))
        XCTAssertEqual(MideaCloud.parseAppliance(["applianceCode": "99", "type": "AC"])?.deviceId, 99)
    }

    func testFromCSVRejectsGarbage() {
        XCTAssertNil(CloudControlClient.fromCSV("1,x,3"))
        XCTAssertNil(CloudControlClient.fromCSV("1,999"))
        XCTAssertEqual(CloudControlClient.fromCSV("-1,0,127"), Data([0xFF, 0x00, 0x7F]))
    }

    func testErrorTextsFollowPattern() {
        let e = MideaCloud.CloudError.api(3101, "x")
        XCTAssertEqual(e.errorDescription, e.what + " " + e.todo + " (3101)")
        XCTAssertNil(MideaCloud.CloudError.paused(until: Date()).codeText)
        XCTAssertEqual(MideaCloud.CloudError.api(-1, "x").codeText, "-1", "Code fehlte in der Antwort")
        XCTAssertTrue(MideaCloud.CloudError.noToken.errorDescription!.hasPrefix("Die Cloud kennt diese Anlage nicht"))
    }

    // MARK: Schlüsselbund

    func testKeychainStoreAndLookup() throws {
        XCTAssertNil(try CloudKeychain.lookup())
        try CloudKeychain.store(CloudCredentials(account: "a", password: "p"))
        XCTAssertEqual(try CloudKeychain.lookup(), CloudCredentials(account: "a", password: "p"))
        keychain.failWrites = .saveFailed(-1)
        XCTAssertThrowsError(try CloudKeychain.store(CloudCredentials(account: "a", password: "neu")))
        keychain.failWrites = nil
        XCTAssertEqual(CloudKeychain.load()?.password, "p", "Fehler beim Speichern verliert die alten Daten nicht")
        keychain.failReads = .unavailable(-25308)
        XCTAssertThrowsError(try CloudKeychain.lookup()) { XCTAssertEqual($0 as? KeychainError, .unavailable(-25308)) }
        XCTAssertNil(CloudKeychain.load())
    }

    func testTestsUseInMemoryKeychainByDefault() {
        XCTAssertTrue(TestEnvironment.isRunningTests)
        XCTAssertTrue(SecretStore.defaultBackend() is InMemoryKeychain)
    }

    // MARK: Protokoll (Testisolation)

    func testLogRedirectAndClearRemovesBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("A06-\(UUID().uuidString)")
        let old = AppLog.url
        AppLog.redirect(to: dir)
        defer { AppLog.redirect(to: nil); try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(AppLog.url, dir.appendingPathComponent("klimacontrol.log"))
        AppLog.write("A06-Marke")
        XCTAssertTrue(AppLog.tail(10).contains("A06-Marke"))
        try Data("alt".utf8).write(to: AppLog.url.appendingPathExtension("1"))
        AppLog.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppLog.url.appendingPathExtension("1").path))
        XCTAssertNotEqual(old.path, DeviceConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("klimacontrol.log").path,
                          "Tests schreiben nie ins echte Protokoll")
    }

    func testRedactionCoversPersonalFields() {
        let s = #"{"userInfo":{"email":"kontakt@example.com","uid":123},"phone":"0170","user_id":42,"access_token":"T","udpId":"ok"}"#
        let r = AppLog.redact(s)
        for secret in ["kontakt@example.com", "123", "0170", "42", "\"T\""] { XCTAssertFalse(r.contains(secret), secret) }
        XCTAssertTrue(r.contains("\"udpId\":\"ok\""))
        // Cloud-Geräteliste und Suche: Seriennummer, Zuhause, Beschreibung
        let list = #"{"sn":"000000P0000000Q1","homeName":"Wohnung","homegroupId":4711,"des":"Büro","name":"PS"}"#
        let rl = AppLog.redact(list)
        for secret in ["000000P0000000Q1", "Wohnung", "4711", "Büro"] { XCTAssertFalse(rl.contains(secret), secret) }
        XCTAssertTrue(rl.contains("\"sn\":\"***\""))
        XCTAssertTrue(rl.contains("\"name\":\"PS\""))
        XCTAssertEqual(AppLog.redact("des=x&homegroupId=1&a=2"), "des=***&homegroupId=***&a=2")
    }

    /// Fehlertexte aus Cloud-Antworten kommen ohne Zeilenumbrüche und Steuerzeichen ins Protokoll.
    func testCloudMessageIsCleaned() async throws {
        FakeCloudProtocol.reset { path, _ in
            path.contains("mapp") ? .init(json: ["errorCode": 1234, "msg": "net\nhome\u{7}"])
                                  : .init(json: ["code": 1234, "msg": "zeile1\r\nFEHLER gefälscht\u{0}"])
        }
        do { _ = try await SmartHomeClient(account: "nutzer@example.com", password: "pw").login(); XCTFail() } catch let e as MideaCloud.CloudError {
            guard case .api(1234, let msg) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(msg, "zeile1FEHLER gefälscht")
        }
        do { _ = try await NetHomePlusClient(account: "nutzer@example.com", password: "pw").login(); XCTFail() } catch let e as MideaCloud.CloudError {
            guard case .api(1234, let msg) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(msg, "nethome")
        }
    }

    /// Eigene Fehlerarten: Art, Text und Code wie zuvor die negativen Codes.
    func testTypedCloudErrors() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(MideaCloud.CloudError, CloudErrorKind, Int)] = [
            (.tokenRejected, .tokenRejected, -1002), (.notInAccount, .notInAccount, -1004),
            (.badReply("x"), .badReply, -1010), (.sessionKeys("x"), .sessionExpired, -1011),
            (.incompleteLogin("x"), .sessionExpired, -1012), (.paused(until: until), .paused, -1021),
            (.keychainLocked, .keychainLocked, -1030),
        ]
        for (e, kind, code) in cases {
            XCTAssertEqual(e.kind, kind, "\(e)")
            XCTAssertEqual(e.code, code, "\(e)")
            XCTAssertNil(e.codeText, "eigene Codes nicht in der Meldung")
        }
        let paused = MideaCloud.CloudError.paused(until: until)
        XCTAssertEqual(paused.errorDescription, "Die Cloud-Anmeldung ist nach Fehlschlägen pausiert. Klimacontrol versucht es ab "
                       + "\(MideaCloudSession.clock(until)) wieder.")
        XCTAssertTrue(MideaCloud.CloudError.keychainLocked.errorDescription!.hasPrefix("Der Schlüsselbund ist gesperrt."))
        XCTAssertTrue(CloudControlClient.isSessionError(.sessionKeys("x")))
        XCTAssertFalse(CloudControlClient.isSessionError(.notInAccount))
    }

    // MARK: Szenen

    func testUnreadableScenesAreMovedAsideAndRescued() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("A06-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("szenen.json")
        let good = #"{"id":"1","name":"Gut","powerOn":true,"mode":2,"tempC":22,"fan":102,"swing":false,"eco":false,"anion":false,"outdoorSilent":false,"selfClean":false}"#
        try Data("[\(good),{\"id\":5}]".utf8).write(to: url)
        let r = ACScene.loadReporting(from: url)
        XCTAssertEqual(r.scenes.map(\.name), ["Gut"])
        XCTAssertNotNil(r.movedAside)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Original liegt beiseite, wird nicht überschrieben")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(r.movedAside!).path))
        XCTAssertEqual(ACScene.loadReporting(from: url).movedAside, nil, "fehlende Datei: still")
    }
}

/// Token-Abruf bei der Einrichtung über das Midea-Konto: nur eine echte Ablehnung im Handshake heißt „lehnt das
/// Token ab“. Belegt oder ohne Antwort nennt die Einrichtung den wahren Grund; die Reihenfolge big/little bleibt.
final class TokenTrialTests: XCTestCase {
    private func run(_ outcomes: [String: (any Error)?]) async -> (Result<String, any Error>, [String]) {
        let tried = Locked<[String]>([])
        do {
            let found = try await MideaCloud.firstAcceptedToken(
                kinds: [.smartHome],
                fetch: { _, big in (big ? "big" : "little", "key") },
                check: { token, _ in
                    tried.mutate { $0.append(token) }
                    return outcomes[token] ?? nil
                })
            return (.success(found.token), tried.value)
        } catch {
            return (.failure(error), tried.value)
        }
    }

    func testBusyIsNotReportedAsRejection() async {
        let (result, tried) = await run(["big": MideaError.busy(.otherApp), "little": MideaError.busy(.otherApp)])
        XCTAssertEqual(tried, ["big", "little"], "Reihenfolge big, dann little endian")
        guard case .failure(let error) = result else { return XCTFail("darf nicht gelingen") }
        XCTAssertEqual(error as? MideaError, .busy(.otherApp))
        XCTAssertNil(error as? MideaCloud.CloudError, "kein „lehnt das Token ab“")
    }

    func testNoAnswerIsNotReportedAsRejection() async {
        let (result, _) = await run(["big": MideaError.authenticationFailed("falsch"), "little": MideaError.timeout])
        guard case .failure(let error) = result else { return XCTFail("darf nicht gelingen") }
        XCTAssertEqual(error as? MideaError, .timeout)
    }

    func testRealRejectionStaysRejection() async {
        let (result, _) = await run(["big": MideaError.authenticationFailed("falsch"),
                                     "little": MideaError.authenticationFailed("falsch")])
        guard case .failure(let error) = result else { return XCTFail("darf nicht gelingen") }
        guard case .tokenRejected? = error as? MideaCloud.CloudError else { return XCTFail("\(error)") }
    }

    func testLittleEndianAfterBigFails() async {
        let (result, tried) = await run(["big": MideaError.authenticationFailed("falsch")])
        XCTAssertEqual(tried, ["big", "little"])
        guard case .success(let token) = result else { return XCTFail("little endian muss gelingen") }
        XCTAssertEqual(token, "little")
    }
}
