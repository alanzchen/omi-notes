import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

/// A scripted server for this suite only.
final class PriorityServerStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var puts: [[String: Any]] = []
    /// state → seconds to hold that PUT's answer.
    nonisolated(unsafe) static var hold: [String: TimeInterval] = [:]
    static let status = #"{"ok":true,"vault_id":"vault-a","features":["issues","retry","value_notes"],"queue":{"failed":0},"worker":{"present":true}}"#
    static let page = #"{"conversations":[{"id":"c1","status":"done","title":"Lunch","started_at":"2026-10-09T12:00:00.000Z","value":{"assessment":"normal","recommended":false,"user":{"state":"auto","revision":0}}}],"next_cursor":null}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let path = request.url?.path ?? ""
        var text = #"{"issues":[]}"#
        var delay: TimeInterval = 0
        if path == "/v1/status" { text = Self.status }
        if path == "/v1/conversations/recent" { text = Self.page }
        if path.hasSuffix("/priority") {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
                stream.close()
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Self.puts.append(body)
            let state = body["state"] as? String ?? "auto"
            delay = Self.hold[state] ?? 0
            text = #"{"state":"\#(state)","revision":\#(Self.puts.count),"set_at":"\#(body["set_at"] as? String ?? "")","applied":true}"#
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let reply = Data(text.utf8)
        let answer: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: answer) } else { answer() }
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized) struct PriorityTests {
    func model(root existing: URL? = nil) throws -> (AppModel, URL) {
        if existing == nil {
            PriorityServerStub.offline = false
            PriorityServerStub.puts = []
            PriorityServerStub.hold = [:]
        }
        let root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-priority-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok")
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        let m = AppModel(engine: engine, noteCache: NoteCache(root: root.appendingPathComponent("cache")))
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [PriorityServerStub.self]
        m.session = URLSession(configuration: c)
        return (m, root)
    }

    var c1: ConversationSummary { ConversationSummary(id: "c1", status: "done") }

    @Test func offlineChoicesShowAtOnceAndOnlyTheLatestIsSentLater() async throws {
        let (m, root) = try model()
        await m.refreshServer()
        PriorityServerStub.offline = true
        await m.setPriority("c1", "less_useful")
        #expect(m.priority(of: c1) == ("less_useful", true))      // optimistic, marked pending
        await m.setPriority("c1", "auto")                           // changed mind, still offline
        #expect(m.priority(of: c1) == ("auto", true))
        // relaunched before going online: the pending choice is still there
        let (again, _) = try model(root: root)
        await again.refreshServer()                                  // still offline
        PriorityServerStub.offline = false
        await again.refreshServer()
        #expect(PriorityServerStub.puts.count == 1 && PriorityServerStub.puts[0]["state"] as? String == "auto",
                "the older less_useful was never sent")
        #expect(again.priority(of: c1) == ("auto", false))
    }

    @Test func aDelayedOldAnswerNeverReplacesANewerChoice() async throws {
        let (m, _) = try model()
        await m.refreshServer()
        PriorityServerStub.hold = ["less_useful": 0.6]
        async let slow: Void = m.setPriority("c1", "less_useful")   // its answer is late…
        try await Task.sleep(for: .milliseconds(100))
        await m.setPriority("c1", "important")                      // …the newer choice is answered first
        await slow
        #expect(m.priority(of: c1) == ("important", false))
        #expect(m.recent.first?.value?.user?.state == "important")
    }

    @Test func offlineMarkingNeedsTheSameConfirmedScopeAndNothingCrossesARePair() async throws {
        let (m, root) = try model()
        await m.refreshServer()                                      // saves the list for this scope…
        let scope = NoteCache.Scope(serverURL: "https://mac.ts.net", generation: 1, vaultId: "vault-a")
        if m.noteCache.lastScope == nil {                            // …except on a Mac host, which refuses
            try JSONEncoder().encode(scope).write(to: root.appendingPathComponent("cache/scope.json"))  // file protection
        }
        #expect(m.noteCache.lastScope == scope)
        PriorityServerStub.offline = true
        // relaunched offline: the same server, pairing and vault said it supports value notes
        let (offline, _) = try model(root: root)
        await offline.refreshServer()
        #expect(offline.serverStatus == nil && offline.supportsValueNotes, "a saved note can be marked offline")
        await offline.setPriority("c1", "less_useful")
        #expect(offline.priority(of: c1) == ("less_useful", true))
        // re-paired (a new generation) while offline: neither the capability nor the choice carries over
        try offline.engine.settings.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok2")
        #expect(!offline.supportsValueNotes && offline.priorityKey == nil)
        // back online with the original pairing: the pending choice is sent and settles
        PriorityServerStub.offline = false
        let (back, _) = try model(root: root)
        await back.refreshServer()
        #expect(PriorityServerStub.puts.last?["state"] as? String == "less_useful")
        #expect(back.priority(of: c1) == ("less_useful", false))
    }

    @Test func retriesAreBoundedAndThenSaySo() async throws {
        let (m, _) = try model()
        await m.refreshServer()
        PriorityServerStub.offline = true
        await m.setPriority("c1", "important")
        for _ in 0..<PriorityStore.maxAttempts { _ = m.priorityStore.failed(m.priorityStore.entries(server: m.retryServerKey!).first?.requestId ?? "") }
        #expect(m.priority(of: c1).pending == false)  // given up: the server's state shows again
        PriorityServerStub.offline = false
    }
}
