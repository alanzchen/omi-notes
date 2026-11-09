import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

/// A scripted server for these suites only (own state, so it can't race other suites' stubs).
final class AppServerStub: URLProtocol, @unchecked Sendable {
    /// path → queue of answers (the last one repeats).
    nonisolated(unsafe) static var routes: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var requests: [(path: String, body: Data)] = []
    nonisolated(unsafe) static var offline = false
    /// path → seconds to hold the next answer to that path (once).
    nonisolated(unsafe) static var delayNext: [String: TimeInterval] = [:]

    static func reset() {
        routes = [:]
        requests = []
        offline = false
        delayNext = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        Self.requests.append((path, body))
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var queue = Self.routes[path] ?? [(404, #"{"error":"not_found","detail":"no route"}"#)]
        let (status, text) = queue.count > 1 ? queue.removeFirst() : queue[0]
        Self.routes[path] = queue
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let answer: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if let delay = Self.delayNext.removeValue(forKey: path) {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: answer)
        } else {
            answer()
        }
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized) struct RetryFlowTests {
    static let status = #"{"ok":true,"vault_id":"vault-a","features":["issues","retry","search","conversation_detail"],"queue":{"failed":1},"worker":{"present":true}}"#
    static func opJSON(_ id: String, _ state: String) -> String {
        #"{"operation":{"id":"\#(id)","kind":"retry","conversation_id":"conv-1","stage":"summarizing","state":"\#(state)"}}"#
    }

    /// `root`: reuse an earlier model's files (an app relaunch), keeping the stub's routes.
    func model(root existing: URL? = nil) throws -> (AppModel, URL) {
        if existing == nil {
            AppServerStub.reset()
            AppServerStub.routes["/v1/status"] = [(200, Self.status)]
            AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[]}"#)]
            AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[],"next_cursor":null}"#)]
        }
        let root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-retry-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok")
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        let m = AppModel(engine: engine, noteCache: NoteCache(root: root.appendingPathComponent("cache")))
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [AppServerStub.self]
        m.session = URLSession(configuration: c)
        return (m, root)
    }

    func sentRequestIds() -> [String] {
        AppServerStub.requests.filter { $0.path.hasSuffix("/retry") }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: String] }.compactMap { $0["request_id"] }
    }

    /// The diagnostic log tail goes to a server that advertises `phone_log` (and only then), after the
    /// last acknowledged line, at most every 5 minutes.
    @Test func theDiagnosticLogGoesOnlyToAServerThatTakesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("diagnostic-log.jsonl")
        let rows = (0..<3).map { PhoneLogLine(at: "2026-11-07T21:00:0\($0).000Z", level: "info", category: "upload", message: "line \($0)") }
        try Data(rows.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! + "\n" }.joined().utf8).write(to: url)
        func model(features: String) throws -> AppModel {
            AppServerStub.reset()
            AppServerStub.routes["/v1/status"] = [(200, #"{"ok":true,"vault_id":"vault-a","features":[\#(features)]}"#)]
            AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[],"next_cursor":null}"#)]
            AppServerStub.routes["/v1/diagnostics/phone-log"] = [(200, #"{"stored":3}"#)]
            let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-plog-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
            try settings.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok")
            var config = EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false)
            config.diagnosticLogURL = url
            let m = AppModel(engine: OmiEngine(config: config, settings: settings, uploadTransport: CountingUploadTransport()),
                             noteCache: NoteCache(root: root.appendingPathComponent("cache")))
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [AppServerStub.self]
            m.session = URLSession(configuration: c)
            return m
        }
        func logPuts() -> [Data] { AppServerStub.requests.filter { $0.path == "/v1/diagnostics/phone-log" }.map(\.body) }

        let old = try model(features: #""issues""#)
        await old.refreshServer()
        try await Task.sleep(for: .milliseconds(300))
        #expect(logPuts().isEmpty, "an older server is never asked")

        let m = try model(features: #""issues","phone_log""#)
        await m.refreshServer()
        for _ in 0..<40 where m.engine.settings.phoneLogCursor == nil { try await Task.sleep(for: .milliseconds(50)) }
        let body = try #require(logPuts().first)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((sent["lines"] as? [[String: String]])?.map { $0["message"] } == ["line 0", "line 1", "line 2"])
        #expect((sent["device_id"] as? String)?.hasPrefix("phone-") == true)
        #expect(m.engine.settings.phoneLogCursor == rows[2].at)
        await m.refreshServer()  // within 5 minutes: nothing more
        try await Task.sleep(for: .milliseconds(200))
        #expect(logPuts().count == 1)
    }

    /// R42-02: a batch the server refuses as too large is halved (oldest half first), never resent
    /// unchanged; a single line it still refuses is skipped so it can't block the log forever.
    @Test func aTooLargeLogBatchIsHalvedNotRepeated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("diagnostic-log.jsonl")
        let rows = (0..<8).map { PhoneLogLine(at: "2026-11-07T21:00:0\($0).000Z", level: "warning", category: "upload", message: "line \($0)") }
        try Data(rows.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! + "\n" }.joined().utf8).write(to: url)
        AppServerStub.reset()
        AppServerStub.routes["/v1/status"] = [(200, #"{"ok":true,"vault_id":"vault-a","features":["phone_log"]}"#)]
        AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[],"next_cursor":null}"#)]
        let tooLarge = (413, #"{"error":"too_large","detail":"body too large"}"#)
        AppServerStub.routes["/v1/diagnostics/phone-log"] = [tooLarge, tooLarge, (200, #"{"stored":2}"#)]
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-plog-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok")
        var config = EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false)
        config.diagnosticLogURL = url
        let m = AppModel(engine: OmiEngine(config: config, settings: settings, uploadTransport: CountingUploadTransport()),
                         noteCache: NoteCache(root: root.appendingPathComponent("cache")))
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [AppServerStub.self]
        m.session = URLSession(configuration: c)
        await m.refreshServer()
        for _ in 0..<60 where m.engine.settings.phoneLogCursor == nil { try await Task.sleep(for: .milliseconds(50)) }
        let sizes = AppServerStub.requests.filter { $0.path == "/v1/diagnostics/phone-log" }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["lines"] as? [Any] }.map(\.count)
        #expect(sizes == [8, 4, 2], "halved after each 413")
        #expect(m.engine.settings.phoneLogCursor == rows[1].at, "the cursor covers only what was stored")

        AppServerStub.routes["/v1/diagnostics/phone-log"] = [tooLarge]
        settings.phoneLogCursor = rows[6].at  // one line left to send
        m.uploadPhoneLogIfDue(api: APIClient(endpoint: try #require(settings.serverConfig().endpoint), session: m.session),
                              now: Date().addingTimeInterval(600))
        for _ in 0..<60 where m.engine.settings.phoneLogCursor != rows[7].at { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.engine.settings.phoneLogCursor == rows[7].at, "one line still refused is skipped, not retried forever")
    }

    /// R42-01: a rejected link is logged as a reason, never as its raw (possibly encoded) URL.
    @Test func aRejectedLinkIsLoggedWithoutItsURL() throws {
        let (m, _) = try model()
        let secret = "SYNTH-\(UUID().uuidString)"
        #expect(!m.handleOpenURL(URL(string: "omi-notes://configure?%74oken=\(secret)")!))
        #expect(!m.handleOpenURL(URL(string: "omi-notes://elsewhere?token=\(secret)")!))
        let logged = OmiLog.shared.recent().map(\.message).filter { $0.hasPrefix("ignored") }.suffix(2)
        #expect(logged.count == 2)
        for message in logged {
            #expect(!message.contains("omi-notes://") && !OmiLog.percentDecoded(message).contains(secret), "\(message)")
        }
    }

    @Test func aLostResponseIsAskedAgainWithTheSameRequestId() async throws {
        let (m, root) = try model()
        await m.refreshServer()
        #expect(m.canRetry)
        AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(502, #"{"error":"bad_gateway"}"#), (200, Self.opJSON("x", "queued"))]
        await m.retry(conversationId: "conv-1")
        #expect(m.retries["conv-1"] == nil && m.retryMessages["conv-1"]?.contains("asks again") == true)
        // saved before sending: a new model on the same files (an app restart) still knows it
        let stored = RetryStore(url: root.appendingPathComponent("app-retries.json"))
        #expect(stored.entries(server: RetryStore.serverKey(baseURL: URL(string: "https://mac.ts.net")!, vaultId: "vault-a")).count == 1)
        await m.refreshServer()  // the next refresh re-sends it
        let ids = sentRequestIds()
        #expect(ids.count == 2 && ids[0] == ids[1])
        #expect(m.retries["conv-1"]?.state == "queued")
        // tapping again while it is unsettled reuses the id too
        await m.retry(conversationId: "conv-1")
        #expect(Set(sentRequestIds()).count == 1)
    }

    static let keepStatus = status.replacingOccurrences(of: #""retry","#, with: #""retry","keep","#)
    static func keepJSON(_ id: String, _ state: String) -> String {
        #"{"operation":{"id":"\#(id)","kind":"keep","conversation_id":"conv-1","stage":"transcribing","state":"\#(state)"}}"#
    }
    static let noSpeakerIssue = #"{"issues":[{"code":"conversation_failed","severity":"action","message":"m","retryable":false,"can_keep":true,"conversation_id":"conv-1"}]}"#

    func sentKeeps() -> [String] {
        AppServerStub.requests.filter { $0.path.hasSuffix("/keep") }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: String] }.compactMap { $0["request_id"] }
    }

    /// OMI-SPLITTER-502: a failure that keeps failing could only be retried. The owner can now set it
    /// aside (servers with `dismiss`); the issue leaves the list at once and after the next refresh.
    @Test func aFailedConversationCanBeDismissed() async throws {
        let (m, _) = try model()
        let dismissStatus = Self.status.replacingOccurrences(of: #""retry","#, with: #""retry","dismiss","#)
        AppServerStub.routes["/v1/status"] = [(200, dismissStatus)]
        AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[{"code":"conversation_failed","severity":"action","message":"m","can_dismiss":true,"conversation_id":"conv-1","failure_id":"f-1"}]}"#)]
        await m.refreshServer()
        #expect(m.canDismiss && m.issues.first?.canDismissFromPhone == true && m.issues.first?.failureId == "f-1")
        AppServerStub.routes["/v1/conversations/conv-1/dismiss"] = [(200, #"{"dismissed":{"conversation_id":"conv-1","request_id":"r","resolved_at":null}}"#)]
        AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[]}"#)]
        #expect(await m.dismiss(conversationId: "conv-1"))
        #expect(m.issues.isEmpty)
        let sent = AppServerStub.requests.filter { $0.path == "/v1/conversations/conv-1/dismiss" }
        let body = try #require(sent.first.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: String] })
        #expect(sent.count == 1 && body["request_id"].map { UUID(uuidString: $0) != nil && $0 == $0.lowercased() } == true)
        #expect(body["failure_id"] == "f-1", "ASTRA-IT3-02: the dismissal names the failure it is for")

        AppServerStub.routes["/v1/conversations/conv-2/dismiss"] = [(409, #"{"error":"retry_in_progress","detail":"a retry is queued"}"#)]
        #expect(await m.dismiss(conversationId: "conv-2") == false)
        #expect(m.retryMessages["conv-2"] != nil, "the refusal is shown")
    }

    /// ASTRA-IT1-04: after an uncertain answer (no response, or a server error) the same request id is
    /// sent again, so one decision never becomes two; a settled answer starts a fresh id next time.
    @Test func aDismissAfterAnUncertainAnswerReusesItsRequestId() async throws {
        let (m, _) = try model()
        AppServerStub.routes["/v1/status"] = [(200, Self.status.replacingOccurrences(of: #""retry","#, with: #""retry","dismiss","#))]
        await m.refreshServer()
        let ok = (200, #"{"dismissed":{"conversation_id":"conv-1","request_id":"r","failure_id":"f","resolved_at":null}}"#)
        AppServerStub.routes["/v1/conversations/conv-1/dismiss"] = [(502, #"{"error":"bad_gateway"}"#), ok]
        #expect(await m.dismiss(conversationId: "conv-1") == false)
        #expect(await m.dismiss(conversationId: "conv-1"))
        func ids() -> [String] {
            AppServerStub.requests.filter { $0.path == "/v1/conversations/conv-1/dismiss" }
                .compactMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [String: String])?["request_id"] }
        }
        #expect(ids().count == 2 && ids()[0] == ids()[1])
        _ = await m.dismiss(conversationId: "conv-1")
        #expect(ids().count == 3 && ids()[2] != ids()[1], "a settled request isn't reused")
    }

    @Test func aKeepSurvivesARelaunchAndIsSentOnceToKeep() async throws {
        let (m, root) = try model()
        AppServerStub.routes["/v1/status"] = [(200, Self.keepStatus)]
        AppServerStub.routes["/v1/issues"] = [(200, Self.noSpeakerIssue)]
        await m.refreshServer()
        #expect(m.canKeep && m.issues.first?.canKeepFromPhone == true)
        AppServerStub.routes["/v1/conversations/conv-1/keep"] = [(502, #"{"error":"bad_gateway"}"#), (202, Self.keepJSON("k-1", "queued"))]
        await m.keep(conversationId: "conv-1")
        #expect(m.retries["conv-1"] == nil && m.retryMessages["conv-1"]?.contains("asks again") == true)

        // the app is relaunched before the answer: the saved request goes to /keep with the same id
        let (relaunched, _) = try model(root: root)
        await relaunched.refreshServer()
        #expect(relaunched.retries["conv-1"]?.kind == "keep" && relaunched.retries["conv-1"]?.state == "queued")
        let ids = sentKeeps()
        #expect(ids.count == 2 && ids[0] == ids[1] && sentRequestIds().isEmpty)  // never sent as a retry

        // done on the server: the failure leaves the issues and the failed count after a reload
        AppServerStub.routes["/v1/operations/k-1"] = [(200, Self.keepJSON("k-1", "done"))]
        AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[]}"#)]
        AppServerStub.routes["/v1/status"] = [(200, Self.keepStatus.replacingOccurrences(of: #""failed":1"#, with: #""failed":0,"conversations_failed":0"#))]
        await relaunched.refreshServer()
        #expect(relaunched.retries["conv-1"]?.state == "done" && relaunched.issues.isEmpty)
        #expect(relaunched.serverStatus?.queue?.conversationsFailed == 0)
        #expect(RetryStore(url: root.appendingPathComponent("app-retries.json")).entries(server: "https://mac.ts.net|vault-a").isEmpty)
        #expect(Set(sentKeeps()).count == 1)
    }

    @Test func aRefusedKeepSaysWhyAndIsNotRepeated() async throws {
        let (m, root) = try model()
        AppServerStub.routes["/v1/status"] = [(200, Self.keepStatus)]
        await m.refreshServer()
        AppServerStub.routes["/v1/conversations/conv-1/keep"] = [(409, #"{"error":"not_keepable","detail":"only a no-speaker result"}"#)]
        await m.keep(conversationId: "conv-1")
        #expect(m.retryMessages["conv-1"] == "This one can't be kept as it is; it needs a fix on the server.")
        #expect(RetryStore(url: root.appendingPathComponent("app-retries.json")).entries(server: "https://mac.ts.net|vault-a").isEmpty)
    }

    @Test func anOlderServerOffersNoKeep() async throws {
        let (m, _) = try model()
        await m.refreshServer()
        #expect(m.canRetry && !m.canKeep)
    }

    @Test func aQuickResultShowsWithoutWaitingForTheNextRefresh() async throws {
        let (m, _) = try model()
        m.retryFollowUpInterval = .milliseconds(10)
        await m.refreshServer()
        AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(202, Self.opJSON("op-1", "queued"))]
        AppServerStub.routes["/v1/operations/op-1"] = [(200, Self.opJSON("op-1", "running")), (200, Self.opJSON("op-1", "failed"))]
        await m.retry(conversationId: "conv-1")
        #expect(m.retries["conv-1"]?.state == "failed" && m.retries["conv-1"]?.displayMessage != "Queued on the server")
        #expect(sentRequestIds().count == 1)  // status reads only: never a second retry
    }

    @Test func aRefusalSettlesTheRequest() async throws {
        let (m, root) = try model()
        await m.refreshServer()
        AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(409, #"{"error":"not_failed","detail":"only a failed conversation can be retried"}"#)]
        await m.retry(conversationId: "conv-1")
        #expect(m.retryMessages["conv-1"] == "This conversation isn't failed anymore.")
        let stored = RetryStore(url: root.appendingPathComponent("app-retries.json"))
        #expect(stored.entries(server: "https://mac.ts.net|vault-a").isEmpty)
    }

    @Test func anotherVaultBehindTheSameAddressStartsClean() async throws {
        let (m, _) = try model()
        AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[{"id":"c1","status":"done","title":"Budget review","started_at":"2026-09-26T19:00:00.000Z"}],"next_cursor":null}"#)]
        AppServerStub.routes["/v1/conversations/c1"] = [(200, NoteCacheTests().detailJSON)]
        await m.refreshServer()
        _ = try await m.conversation("c1")
        let before = m.serverIdentity
        let vaultA = try #require(m.noteCache.lastScope)
        #expect(vaultA.vaultId == "vault-a" && !m.noteCache.details(scope: vaultA).isEmpty)  // saved, so there is something to clear
        AppServerStub.routes["/v1/status"] = [(200, Self.status.replacingOccurrences(of: "vault-a", with: "vault-b"))]
        AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[],"next_cursor":null}"#)]
        await m.refreshServer()
        #expect(m.serverIdentity != before && m.details.isEmpty && m.recent.isEmpty)
        #expect(m.noteCache.lastScope?.vaultId != "vault-a" && m.savedConversations().isEmpty)
        #expect(m.noteCache.details(scope: vaultA).isEmpty && m.noteCache.recent(scope: vaultA) == nil, "the other vault's saved notes are removed")
    }

    @Test func aLateAnswerFromBeforeAVaultChangeIsDropped() async throws {
        let (m, _) = try model()
        await m.refreshServer()  // vault-a
        let vaultB = Self.status.replacingOccurrences(of: "vault-a", with: "vault-b")
        // the next status answer (vault-a, stale) is slow; the one after (vault-b) is fast
        AppServerStub.routes["/v1/status"] = [(200, Self.status), (200, vaultB)]
        AppServerStub.delayNext["/v1/status"] = 0.6
        async let slow: Void = m.refreshServer()
        try await Task.sleep(for: .milliseconds(150))
        await m.refreshServer()
        #expect(m.serverStatus?.vaultId == "vault-b")
        await slow
        #expect(m.serverStatus?.vaultId == "vault-b" && m.serverIdentity.hasSuffix("vault-b"))
    }

    @Test func aLateNotFoundAfterAVaultChangeSendsNothing() async throws {
        let (m, _) = try model()
        await m.refreshServer()
        AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(202, Self.opJSON("op-1", "queued"))]
        await m.retry(conversationId: "conv-1")
        AppServerStub.routes["/v1/operations/op-1"] = [(404, #"{"error":"not_found","detail":"unknown operation"}"#)]
        AppServerStub.delayNext["/v1/operations/op-1"] = 0.6
        async let following: Void = m.refreshServer()  // asks about op-1; the answer is late
        try await Task.sleep(for: .milliseconds(200))
        AppServerStub.routes["/v1/status"] = [(200, Self.status.replacingOccurrences(of: "vault-a", with: "vault-b"))]
        await m.refreshServer()
        await following
        #expect(sentRequestIds().count == 1)  // the old vault's retry was not sent to the new one
    }

    @Test func busyIsNotAnAnswer() async throws {
        let (m, root) = try model()
        await m.refreshServer()
        AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(409, #"{"error":"busy","detail":"try again"}"#), (202, Self.opJSON("op-2", "queued"))]
        await m.retry(conversationId: "conv-1")
        #expect(RetryStore(url: root.appendingPathComponent("app-retries.json")).entries(server: "https://mac.ts.net|vault-a").count == 1)
        await m.refreshServer()
        #expect(m.retries["conv-1"]?.id == "op-2" && Set(sentRequestIds()).count == 1)
    }

    @Test func progressIsFollowedUntilTheOperationFinishes() async throws {
        let (m, root) = try model()
        await m.refreshServer()
        AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(202, Self.opJSON("op-1", "queued"))]
        await m.retry(conversationId: "conv-1")
        AppServerStub.routes["/v1/operations/op-1"] = [(200, Self.opJSON("op-1", "done"))]
        await m.refreshServer()
        #expect(m.retries["conv-1"]?.state == "done")
        #expect(RetryStore(url: root.appendingPathComponent("app-retries.json")).entries(server: "https://mac.ts.net|vault-a").isEmpty)
    }

    /// A reachable server without search: only saved notes are searched, and that isn't called
    /// "can't be reached".
    @Test func aServerWithoutSearchIsNotCalledUnreachable() async throws {
        let (m, _) = try model()
        AppServerStub.routes["/v1/status"] = [(200, Self.status.replacingOccurrences(of: #""search","#, with: ""))]
        await m.refreshServer()
        #expect(m.serverStatus?.supportsSearch == false)
        let r = try await m.search("budget", personId: nil, range: .any).get()
        #expect(r.serverLacksSearch && !r.offline)
    }

    // The stub's state is shared: offline reading runs in this serialized suite too.

    @Test func anUnreachableServerShowsTheSavedListAndNotes() async throws {
        let (m, _) = try model()
        AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[{"id":"c1","status":"done","title":"Budget review","started_at":"2026-09-26T19:00:00.000Z"}],"next_cursor":null}"#)]
        AppServerStub.routes["/v1/conversations/c1"] = [(200, NoteCacheTests().detailJSON)]
        await m.refreshServer()
        _ = try await m.conversation("c1")
        #expect(m.recentSavedAt == nil)

        // relaunch while the server is away
        let again = AppModel(engine: m.engine, noteCache: m.noteCache)
        again.session = m.session
        AppServerStub.offline = true
        await again.refreshServer()
        #expect(again.recent.map(\.id) == ["c1"] && again.recentSavedAt != nil && again.recentError != nil)
        _ = try? await again.conversation("c1")
        #expect(again.details["c1"]?.summary?.overview == "The team agreed on the Q2 budget." && again.detailSavedAt["c1"] != nil)
        let offline = await again.search("budget", personId: nil, range: .any)
        #expect((try? offline.get())?.offline == true && (try? offline.get())?.conversations.map(\.id) == ["c1"])
        let byPerson = await again.search("budget", personId: "p1", range: .any)
        if case .failure(let e) = byPerson { #expect(e is AppModel.SearchError) } else { Issue.record("person filter offline") }
        let lastWeek = await again.search("budget", personId: nil, range: .week)
        let saved = try #require(ISO8601UTC.parse("2026-09-26T19:00:00.000Z"))
        let weekStart = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -6, to: Date())!)
        #expect((try? lastWeek.get())?.conversations.count == (saved >= weekStart ? 1 : 0))

        again.clearSavedNotes()
        #expect(again.savedConversations().isEmpty)

        // pairing with another server removes what the previous one's notes left on disk
        AppServerStub.offline = false
        _ = try await m.conversation("c1")
        #expect(!m.noteCache.details(scope: try #require(m.noteCache.lastScope)).isEmpty)
        try m.engine.settings.setServer(url: URL(string: "https://other.ts.net")!, token: "tok2")
        await m.refreshServer()
        #expect(m.noteCache.lastScope == nil || m.noteCache.lastScope?.serverURL == "https://other.ts.net")
    }

    /// ASTRA-20261109-IT1-05: after a healthy answer, a refresh that fails kept the Server page's service
    /// dots green from the cached status. The cached names stay; the health becomes last-known.
    @Test func serviceDotsAreLastKnownAfterARefreshFails() async throws {
        let (m, _) = try model()
        AppServerStub.routes["/v1/status"] = [(200, #"{"ok":true,"stt":{"provider":"local","model":"Qwen3-ASR-1.7B-bf16","ready":true,"engine":{"healthy":true}},"llm":{"provider":"openai","model":"gpt-6-luna","ready":true}}"#)]
        await m.refreshServer()
        let answered = try #require(m.serverStatusAt)
        #expect(m.serviceLabels(now: answered)?.transcription.health == .ok && m.serviceLabels(now: answered)?.summaries.health == .ok)
        #expect(m.serviceLabels(now: answered.addingTimeInterval(ServiceLabel.currentFor + 1))?.transcription.health == .lastKnown,
                "green expires without another answer")
        AppServerStub.offline = true
        await m.refreshServer()
        let labels = try #require(m.serviceLabels(now: answered), "the cached configuration stays")
        #expect(labels.transcription.health == .lastKnown && labels.summaries.health == .lastKnown)
        #expect(labels.transcription.text == "Local · Qwen3-ASR-1.7B" && labels.summaries.text == "gpt-6-luna")
    }
}

@Suite struct RetryStoreTests {
    @Test func anUnreadableStoreIsKeptAndBlocksNewRetries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app-retries.json")
        try Data("{broken".utf8).write(to: url)
        let store = RetryStore(url: url)
        #expect(store.unreadable)
        #expect(throws: RetryStore.StoreError.self) { try store.begin(conversationId: "c", server: "s") }
        store.settle("anything")
        #expect(try Data(contentsOf: url) == Data("{broken".utf8))
    }
}

@Suite struct NoteCacheTests {
    let detailJSON = #"{"id":"c1","status":"done","title":"Budget review","started_at":"2026-09-26T19:00:00.000Z","summary_state":"ready","summary":{"overview":"The team agreed on the Q2 budget.","sections":[],"action_items":[],"decisions":[],"open_questions":[]},"transcript_state":"ready","speakers":[{"label":"S1","name":"Priya"}],"transcript":{"total":2,"from":0,"next_from":1,"segments":[{"start":"a","end":"b","speaker":"S1","name":"Priya","text":"Let's ship on Friday"}]}}"#

    func cache() -> NoteCache { NoteCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }

    @Test func savedCopiesRoundTripAndStayInTheirScope() throws {
        let c = cache()
        let a = NoteCache.Scope(serverURL: "https://a", generation: 1, vaultId: "v1")
        let b = NoteCache.Scope(serverURL: "https://a", generation: 1, vaultId: "v2")
        let d = try JSONDecoder().decode(ConversationDetail.self, from: Data(detailJSON.utf8))
        c.saveDetail(d, scope: a)
        #expect(c.detail("c1", scope: a)?.value == d)
        #expect(c.detail("c1", scope: b) == nil && c.details(scope: b).isEmpty)
        #expect(c.lastScope == a)
        #expect(d.transcriptComplete == false)
        #expect(c.search("FRIDAY priya", scope: a).map(\.id) == ["c1"] && c.search("friday", scope: b).isEmpty)
        c.clear()
        #expect(c.detail("c1", scope: a) == nil && c.lastScope == nil)
    }

    /// Field log, build 42 (2026-11-08 05:10Z): "no permission to save recent.json" (NSCocoaErrorDomain
    /// 513). Complete protection can't create a file while the phone is locked, and every atomic save
    /// creates one. Saved copies use "until first unlock" (still encrypted at rest until the phone
    /// is first unlocked after a restart, like the rest of the app's data). Only the option can be
    /// checked here: the simulator reports no class and macOS refuses it, so its effect needs a device.
    @Test func savedCopiesAreWrittenSoTheyCanBeSavedWhileLocked() {
        #if os(macOS)
        #expect(NoteCache.writeOptions == [.atomic])
        #else
        #expect(NoteCache.writeOptions == [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    /// Folders and files an earlier build wrote with complete protection are moved to the new class
    /// (once per launch, retried after a failure, e.g. while still locked).
    @Test func earlierCompleteProtectionIsMigrated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-cache-\(UUID().uuidString)")
        let s = NoteCache.Scope(serverURL: "https://a", generation: 1, vaultId: "v1")
        NoteCache(root: root).saveRecent([], scope: s)
        var visited: [String] = []
        var failNext = true
        let c = NoteCache(root: root)
        c.setProtection = { url in
            if failNext { failNext = false; throw CocoaError(.fileWriteNoPermission) }
            visited.append(url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.resolvingSymlinksInPath().path, with: ""))
        }
        c.saveRecent([], scope: s)
        #expect(visited.isEmpty, "a failed migration (locked) is tried again on the next save")
        c.saveRecent([], scope: s)
        #expect(visited.contains("") && visited.contains("/\(s.folder)") && visited.contains("/\(s.folder)/recent.json") && visited.contains("/scope.json"))
        let count = visited.count
        c.saveRecent([], scope: s)
        #expect(visited.count == count, "once per launch")
    }

    @Test func theOldestSavedCopiesAreEvicted() throws {
        let c = cache()
        let s = NoteCache.Scope(serverURL: "https://a", generation: 1, vaultId: "v1")
        for i in 0..<(NoteCache.maxDetails + 3) {
            let json = detailJSON.replacingOccurrences(of: #""id":"c1""#, with: #""id":"c\#(i)""#)
            c.saveDetail(try JSONDecoder().decode(ConversationDetail.self, from: Data(json.utf8)), scope: s)
        }
        #expect(c.details(scope: s).count == NoteCache.maxDetails)
    }
}

@Suite struct ActivityHealthTests {
    @Test func aFailingServiceWhileRetryingSaysSo() throws {
        let json = #"{"queue":{"failed":0,"conversations_failed":0,"chunks_failed":0,"conversations_retrying":1,"notes_conflicted":0},"worker":{"present":true},"features":["issues"],"last_note_at":"2026-09-21T12:00:00.000Z","activity":{"stt":{"last_ok_at":"2026-09-26T10:00:00.000Z","last_error_at":"2026-09-26T11:00:00.000Z","last_error_kind":"transient"}}}"#
        let st = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
        #expect(st.activity?.stt?.lastFailed == true)
        var s = EngineSnapshot()
        s.connection = .streaming
        s.serverConfigured = true
        let now = Date()
        let h = SystemHealth.evaluate(snapshot: s, server: .reachable(version: nil, detail: ""), status: st, statusAt: now, now: now)
        #expect(h.level == .delayed && h.headline == "The transcription service is having trouble")
    }

    @Test func retryRefusalsReadPlainly() {
        #expect(AppModel.retryRefusal("note_frozen: the note is frozen") == "The note is frozen on the server, so it can't be updated.")
        #expect(AppModel.retryRefusal("weird").hasPrefix("The server refused the retry"))
    }
}
