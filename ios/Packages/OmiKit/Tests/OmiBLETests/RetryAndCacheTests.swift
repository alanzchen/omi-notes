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

    func model() throws -> (AppModel, URL) {
        AppServerStub.reset()
        AppServerStub.routes["/v1/status"] = [(200, Self.status)]
        AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[]}"#)]
        AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[],"next_cursor":null}"#)]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        AppServerStub.routes["/v1/status"] = [(200, Self.status.replacingOccurrences(of: "vault-a", with: "vault-b"))]
        AppServerStub.routes["/v1/conversations/recent"] = [(200, #"{"conversations":[],"next_cursor":null}"#)]
        await m.refreshServer()
        #expect(m.serverIdentity != before && m.details.isEmpty && m.recent.isEmpty)
        #expect(m.noteCache.lastScope?.vaultId != "vault-a" && m.savedConversations().isEmpty)
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
