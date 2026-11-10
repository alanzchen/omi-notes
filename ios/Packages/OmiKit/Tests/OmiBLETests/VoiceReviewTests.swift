import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

/// A scripted server for this suite only (its own state, so it can't race other suites' stubs).
final class VoicesHubStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var requests: [(method: String, path: String, query: String?, body: [String: Any])] = []
    /// Seconds a route ("GET /v1/speakers/settings") takes to answer.
    nonisolated(unsafe) static var delays: [String: Double] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.requests.append((request.httpMethod ?? "GET", path, request.url?.query, body))
        // a route with its query ("GET /v1/speakers/review?limit=50&offset=50") wins over the bare path
        let bare = "\(request.httpMethod ?? "GET") \(path)"
        let withQuery = request.url?.query.map { "\(bare)?\($0)" }
        let key = withQuery.flatMap { Self.routes[$0] != nil ? $0 : nil } ?? bare
        var queue = Self.routes[key] ?? [(404, #"{"error":"not_found","detail":"no route"}"#)]
        let (status, text) = queue.count > 1 ? queue.removeFirst() : queue[0]
        Self.routes[key] = queue
        // -1: the request times out; -2: no connection (what URLSession reports, before any response)
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(status == -1 ? .timedOut : .notConnectedToInternet))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let answer = { [self] in
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if let delay = Self.delays[bare] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { answer() }
        } else {
            answer()
        }
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized) struct VoiceReviewTests {
    static func item(_ id: String, person: String = "p-alan", sample: String? = nil, playable: Bool = true, reasons: [String] = []) -> String {
        let sampleField = sample.map { #","sample_id":"\#($0)""# } ?? ""
        let clip = playable ? #","clip":{"id":"sample.\#(sample ?? id).0","seconds":4.2}"# : ""
        let r = reasons.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":"\#(id)","kind":"\#(sample == nil ? "label" : "sample")","person_id":"\#(person)"\#(sampleField),"reasons":[\#(r)],"playable":\#(playable)\#(clip),"text":"t \#(id)","conversation":{"id":"c1"}}"#
    }

    static func batch(_ items: [String]) -> String { #"{"items":[\#(items.joined(separator: ","))]}"# }

    static let first = batch([item("s.a.1", sample: "a", reasons: ["pitch"]), item("s.b.1", sample: "b"), item("l.c.S1.2.p-gigi.x", person: "p-gigi")])

    func speakers() throws -> SpeakersModel {
        VoicesHubStub.routes = [:]
        VoicesHubStub.requests = []
        VoicesHubStub.delays = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-voices-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok")
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        let speakers = SpeakersModel(engine: engine)
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [VoicesHubStub.self]
        speakers.session = URLSession(configuration: c)
        return speakers
    }

    func sent(_ method: String, _ suffix: String) -> [(query: String?, body: [String: Any])] {
        VoicesHubStub.requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.map { ($0.query, $0.body) }
    }

    // MARK: Review queue

    @Test func aBatchIsTenInTheServersOrder() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        await queue.load()
        #expect(sent("GET", "/v1/speakers/review").first?.query == "limit=50")  // the backend has no paging: one window, paged here
        #expect(queue.items.map(\.id) == ["s.a.1", "s.b.1", "l.c.S1.2.p-gigi.x"] && queue.current?.id == "s.a.1")
        #expect(queue.phase == .ready && queue.current?.isSuspicious == true)
    }

    @Test func confirmSendsTheDecisionAndKeepsItsUndoToken() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(200, #"{"item_id":"s.a.1","decision":"confirm","request_id":"srv","undo_token":"tok-a"}"#)]
        await queue.load()
        #expect(await queue.decide(.confirm))
        let body = try #require(sent("POST", "/review/s.a.1").first?.body)
        #expect(body["decision"] as? String == "confirm" && (body["request_id"] as? String)?.isEmpty == false && body["person_id"] == nil)
        #expect(queue.current?.id == "s.b.1" && queue.undoable?.undoToken == "tok-a" && queue.undoable?.decision == .confirm)
        #expect(queue.decided == 1)
    }

    @Test func withoutAnUndoTokenTheRequestIdIsUsed() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(200, #"{"item_id":"s.a.1","decision":"reject"}"#)]
        await queue.load()
        #expect(await queue.decide(.reject))
        let sentId = try #require(sent("POST", "/review/s.a.1").first?.body["request_id"] as? String)
        #expect(queue.undoable?.undoToken == sentId)
    }

    @Test func moveSendsThePerson() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(200, #"{"undo_token":"t"}"#)]
        await queue.load()
        #expect(await queue.decide(.move, personId: "p-gigi"))
        let body = try #require(sent("POST", "/review/s.a.1").first?.body)
        #expect(body["decision"] as? String == "move" && body["person_id"] as? String == "p-gigi")
    }

    @Test func undoUsesTheTokenThenAsksForTheQueueAgain() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        let after = Self.batch([Self.item("s.a.3", sample: "a", reasons: ["pitch"]), Self.item("s.b.1", sample: "b")])
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first), (200, after)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(200, #"{"undo_token":"tok-a"}"#)]
        VoicesHubStub.routes["POST /v1/speakers/undo"] = [(200, #"{"undone":[],"skipped":[],"samples":{"undone":["a"],"skipped":[]}}"#)]
        await queue.load()
        await queue.decide(.reject)
        await queue.undo()
        let body = try #require(sent("POST", "/v1/speakers/undo").first?.body)
        #expect(body["request_id"] as? String == "tok-a" && (body["undo_request_id"] as? String)?.isEmpty == false)
        // the item's id changed with the undo (it is bound to the sample's revision): the fresh queue has it
        #expect(queue.current?.id == "s.a.3" && queue.undoable == nil && queue.notice == .undone)
        #expect(queue.decided == 0)
    }

    @Test func anUndoThatChangedNothingSaysSoAndKeepsTheDecision() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(200, #"{"undo_token":"tok-a"}"#)]
        VoicesHubStub.routes["POST /v1/speakers/undo"] = [(200, #"{"undone":[],"skipped":[],"samples":{"undone":[],"skipped":[{"id":"a","reason":"changed"}]}}"#)]
        await queue.load()
        await queue.decide(.reject)
        await queue.undo()
        #expect(queue.notice == .undoFailed && queue.undoable == nil && queue.current?.id == "s.b.1" && queue.decided == 1)
        #expect(sent("GET", "/v1/speakers/review").count == 1)
    }

    @Test func aStaleItemRefetchesTheQueueInsteadOfAdvancing() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        let fresh = Self.batch([Self.item("s.a.2", sample: "a"), Self.item("s.b.1", sample: "b")])
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first), (200, fresh)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(409, #"{"error":"stale_review","detail":"this review item is from an older queue; fetch it again"}"#)]
        await queue.load()
        #expect(await queue.decide(.confirm) == false)
        #expect(sent("GET", "/v1/speakers/review").count == 2)
        #expect(queue.current?.id == "s.a.2" && queue.undoable == nil && queue.notice == .refreshed && queue.decided == 0)
    }

    @Test func anotherFailureStaysOnTheItemAndSaysWhy() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(503, #"{"error":"vault_read_only","detail":"read only"}"#)]
        await queue.load()
        #expect(await queue.decide(.confirm) == false)
        #expect(queue.current?.id == "s.a.1" && queue.error != nil && sent("GET", "/v1/speakers/review").count == 1)
    }

    @Test func skipSendsNothingAndTheNextBatchLeavesItOut() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        let second = Self.batch([Self.item("s.a.1", sample: "a"), Self.item("s.d.1", sample: "d")])
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.batch([Self.item("s.a.1", sample: "a")])), (200, second)]
        await queue.load()
        queue.skip()
        #expect(queue.phase == .onlySkipped && VoicesHubStub.requests.filter { $0.method == "POST" }.isEmpty)
        await queue.load()
        #expect(queue.items.map(\.id) == ["s.d.1"] && queue.phase == .ready)
    }

    @Test func aBatchOfOnlySkippedItemsIsFinished() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.batch([Self.item("s.a.1", sample: "a")]))]
        await queue.load()
        queue.skip()
        await queue.load()
        #expect(queue.items.isEmpty && queue.phase == .onlySkipped)
    }

    @Test func aFailedLoadSaysWhy() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(503, #"{"error":"x","detail":"down"}"#)]
        await queue.load()
        if case .failed = queue.phase {} else { Issue.record("expected failed, got \(queue.phase)") }
    }

    // MARK: A person's samples

    static let samples = #"""
    {"samples":[
      {"id":"a","person_id":"p-alan","state":"active","revision":2,"flag":{"reasons":["pitch"],"open":true},"playable":true,
       "clip":{"id":"sample.a.0","seconds":5},"text":"欢迎回到频道","review_id":"s.a.2"},
      {"id":"b","person_id":"p-alan","state":"active","revision":0,"playable":false,"text":"那我们明天再对一下","review_id":"s.b.0"}]}
    """#

    @Test func samplesAreListedByState() async throws {
        let m = VoiceSamplesModel(speakers: try speakers(), personId: "p-alan", tab: .flagged)
        VoicesHubStub.routes["GET /v1/people/p-alan/samples"] = [(200, Self.samples)]
        await m.load()
        #expect(sent("GET", "/samples").first?.query == "state=flagged")
        #expect(m.samples.map(\.id) == ["a", "b"])
        m.tab = .removed
        await m.load()
        #expect(sent("GET", "/samples").last?.query == "state=removed")
    }

    @Test func removeIsRestorableAndUndoable() async throws {
        let m = VoiceSamplesModel(speakers: try speakers(), personId: "p-alan", tab: .active)
        VoicesHubStub.routes["GET /v1/people/p-alan/samples"] = [(200, Self.samples)]
        VoicesHubStub.routes["POST /v1/samples/a/remove"] = [(200, #"{"sample":{"id":"a","state":"removed","revision":3},"request_id":"r","undo_token":"tok-rm"}"#)]
        VoicesHubStub.routes["POST /v1/speakers/undo"] = [(200, #"{"undone":[],"skipped":[],"samples":{"undone":["a"],"skipped":[]}}"#)]
        await m.load()
        #expect(await m.remove(m.samples[0]))
        let body = try #require(sent("POST", "/samples/a/remove").first?.body)
        #expect(body["expected_revision"] as? Int == 2 && (body["request_id"] as? String)?.isEmpty == false)
        #expect(m.samples.map(\.id) == ["b"] && m.undoable?.undoToken == "tok-rm" && m.undoable?.action == .remove)
        await m.undo()
        #expect(sent("POST", "/v1/speakers/undo").first?.body["request_id"] as? String == "tok-rm")
        #expect(m.undoable == nil && sent("GET", "/samples").count == 2)  // listed again from the server
    }

    @Test func restoreAndMoveSendTheirBodies() async throws {
        let m = VoiceSamplesModel(speakers: try speakers(), personId: "p-alan", tab: .removed)
        VoicesHubStub.routes["GET /v1/people/p-alan/samples"] = [(200, Self.samples)]
        VoicesHubStub.routes["POST /v1/samples/a/restore"] = [(200, #"{"sample":{"id":"a","state":"active"},"undo_token":"t1"}"#)]
        VoicesHubStub.routes["POST /v1/samples/b/move"] = [(200, #"{"sample":{"id":"b","state":"moved"},"undo_token":"t2"}"#)]
        await m.load()
        #expect(await m.restore(m.samples[0]))
        #expect(await m.move(m.samples[0], to: "p-gigi"))
        #expect(sent("POST", "/samples/b/move").first?.body["person_id"] as? String == "p-gigi")
        #expect(m.samples.isEmpty && m.undoable?.action == .move)
    }

    @Test func aMoveWithoutConsentAsksForTheirConsentAndKeepsTheList() async throws {
        let m = VoiceSamplesModel(speakers: try speakers(), personId: "p-alan", tab: .active)
        VoicesHubStub.routes["GET /v1/people/p-alan/samples"] = [(200, Self.samples)]
        VoicesHubStub.routes["POST /v1/samples/a/move"] = [(409, #"{"error":"consent_required","detail":"no attestation"}"#)]
        await m.load()
        #expect(await m.move(m.samples[0], to: "p-gigi") == false)
        #expect(m.error == VoiceConflict.consentRequired.message && m.consentNeeded == "p-gigi" && m.samples.count == 2)
        #expect(sent("GET", "/samples").count == 1)  // nothing changed: no reload
    }

    @Test func confirmingAFlaggedSampleUsesItsReviewItem() async throws {
        let m = VoiceSamplesModel(speakers: try speakers(), personId: "p-alan", tab: .flagged)
        VoicesHubStub.routes["GET /v1/people/p-alan/samples"] = [(200, Self.samples)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.2"] = [(200, #"{"undo_token":"tc"}"#)]
        await m.load()
        #expect(await m.confirm(m.samples[0]))
        #expect(sent("POST", "/review/s.a.2").first?.body["decision"] as? String == "confirm")
        #expect(m.samples.map(\.id) == ["b"] && m.undoable?.action == .confirm)  // no longer flagged
    }

    // MARK: Astra review (deployed backend 1b7ef4e)

    /// Skipping a whole batch must not end the queue while more is pending: the backend has no offset
    /// or cursor (`GET /v1/speakers/review?limit≤50`), so the phone asks for the whole window and pages it.
    @Test func skippingABatchShowsTheNextOneNotAnEmptyQueue() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        let twelve = Self.batch((1...12).map { Self.item("s.x\($0).1", sample: "x\($0)") })
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, twelve)]
        await queue.load()
        #expect(queue.items.count == 10)
        for _ in 0..<10 { queue.skip() }
        #expect(queue.phase == .batchDone)  // more is waiting, not "没有待确认的了"
        await queue.load()
        #expect(queue.items.map(\.id) == ["s.x11.1", "s.x12.1"])
        queue.skip(); queue.skip()
        #expect(queue.phase == .onlySkipped)
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, #"{"items":[]}"#)]
        await queue.load()
        #expect(queue.phase == .empty)
    }

    /// Server paging (`offset`, `next_offset`, `total`): a page of only skipped items is passed over to
    /// the next one, and "剩下的都跳过了" waits for `next_offset: null`.
    @Test func skippingPastTheFirstPageFetchesTheNext() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        let first = (1...50).map { Self.item("s.p\($0).1", sample: "p\($0)") }.joined(separator: ",")
        let second = (51...60).map { Self.item("s.p\($0).1", sample: "p\($0)") }.joined(separator: ",")
        VoicesHubStub.routes["GET /v1/speakers/review?limit=50"] = [(200, #"{"items":[\#(first)],"next_offset":50,"total":60}"#)]
        VoicesHubStub.routes["GET /v1/speakers/review?limit=50&offset=50"] = [(200, #"{"items":[\#(second)],"next_offset":null,"total":60}"#)]
        await queue.load()
        #expect(queue.total == 60)
        for round in 0..<5 {
            #expect(queue.items.first?.id == "s.p\(round * 10 + 1).1")
            for _ in 0..<10 { queue.skip() }
            #expect(queue.phase == .batchDone)
            await queue.load()
        }
        // the first page is all skipped: the next page is asked for, not "剩下的都跳过了"
        #expect(queue.items.map(\.id) == (51...60).map { "s.p\($0).1" })
        #expect(sent("GET", "/v1/speakers/review").last?.query == "limit=50&offset=50")
        for _ in 0..<10 { queue.skip() }
        #expect(queue.phase == .onlySkipped)  // next_offset null: nothing more on the server
        await queue.load()
        #expect(queue.phase == .onlySkipped && queue.items.isEmpty)
    }

    @Test func aPagedServerWithAnEmptyQueueIsEmpty() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, #"{"items":[],"next_offset":null,"total":0}"#)]
        await queue.load()
        #expect(queue.phase == .empty && queue.total == 0)
    }

    @Test func refreshReadsTheQueueTotalForTheHub() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/status"] = [(200, #"{"features":["voice_review"]}"#)]
        VoicesHubStub.routes["GET /v1/people"] = [(200, #"{"people":[]}"#)]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(200, #"{"unknown_voices_enabled":false,"auto_assign":true}"#)]
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, #"{"items":[{"id":"s.a.1"}],"next_offset":1,"total":163}"#)]
        await speakers.refresh()
        #expect(speakers.reviewTotal == 163 && sent("GET", "/v1/speakers/review").first?.query == "limit=1")
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, #"{"items":[]}"#)]  // an older server: no total
        await speakers.refresh()
        #expect(speakers.reviewTotal == nil)
    }

    /// Nightly walkthrough 2026-11-10: with the server unreachable the hub offered "录入我的声音" to
    /// a wearer whose voice is already enrolled; it asks only once a people list says there is no 我.
    @Test func theHubAsksForTheWearersVoiceOnlyWhenThePeopleListSaysThereIsNone() async throws {
        let speakers = try speakers()
        #expect(!speakers.needsWearer, "nothing loaded yet")
        VoicesHubStub.routes["GET /v1/status"] = [(-2, "")]
        VoicesHubStub.routes["GET /v1/people"] = [(-2, "")]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(-2, "")]
        await speakers.refresh()
        #expect(speakers.error != nil && !speakers.needsWearer, "offline: unknown, not missing")
        VoicesHubStub.routes["GET /v1/people"] = [(200, #"{"people":[{"id":"p","name":"Priya"}]}"#)]
        await speakers.refresh()
        #expect(speakers.needsWearer)
        VoicesHubStub.routes["GET /v1/people"] = [(200, #"{"people":[{"id":"p","name":"Alan","me":true}]}"#)]
        await speakers.refresh()
        #expect(!speakers.needsWearer)
        speakers.serverChanged()
        #expect(!speakers.needsWearer, "another server's list is not this one's")
    }

    @Test func answeringAFullWindowLeavesMoreToFetch() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        let fifty = Self.batch((1...50).map { Self.item("s.y\($0).1", sample: "y\($0)") })
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, fifty)]
        await queue.load()
        #expect(queue.items.count == 10 && queue.phase == .ready)
    }

    @Test func aRecoveringVaultSaysSoAndStaysOnTheItem() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(409, #"{"error":"recovery_pending","detail":"try again later"}"#)]
        await queue.load()
        #expect(await queue.decide(.confirm) == false)
        #expect(queue.current?.id == "s.a.1" && queue.error == "正在恢复，稍后再试" && sent("GET", "/v1/speakers/review").count == 1)
    }

    @Test func aMoveWithoutConsentAsksForThatPersonsConsent() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(409, #"{"error":"consent_required","detail":"no attestation"}"#)]
        await queue.load()
        #expect(await queue.decide(.move, personId: "p-gigi") == false)
        #expect(queue.consentNeeded == "p-gigi" && queue.current?.id == "s.a.1")
        queue.clearConsentNeeded()
        #expect(queue.consentNeeded == nil)
    }

    @Test func aFailedUndoShowsTheBackendsReasons() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(200, #"{"undo_token":"tok-a"}"#)]
        VoicesHubStub.routes["POST /v1/speakers/undo"] = [(200, #"{"undone":[],"skipped":[],"samples":{"undone":[],"skipped":[{"id":"a","reason":"changed since"}]}}"#)]
        await queue.load()
        await queue.decide(.reject)
        await queue.undo()
        #expect(queue.error?.contains("之后又改过") == true)
    }

    @Test func everyLoadIsANewClipGeneration() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        await queue.load()
        let first = queue.generation
        await queue.load()
        #expect(queue.generation != first)
        // the item id carries its revision (and, for a label, the transcript's speakers revision)
        #expect(VoiceReviewQueue.clipVersion(queue.items[2]) == "l.c.S1.2.p-gigi.x")
    }

    @Test func aSampleUndoThatFailsKeepsItsTokenToRetry() async throws {
        let m = VoiceSamplesModel(speakers: try speakers(), personId: "p-alan", tab: .active)
        VoicesHubStub.routes["GET /v1/people/p-alan/samples"] = [(200, Self.samples)]
        VoicesHubStub.routes["POST /v1/samples/a/remove"] = [(200, #"{"sample":{"id":"a","state":"removed"},"undo_token":"tok-rm"}"#)]
        VoicesHubStub.routes["POST /v1/speakers/undo"] = [(503, #"{"error":"vault_read_only","detail":"x"}"#),
                                                          (200, #"{"undone":[],"skipped":[],"samples":{"undone":["a"],"skipped":[]}}"#)]
        await m.load()
        await m.remove(m.samples[0])
        await m.undo()
        #expect(m.undoable?.undoToken == "tok-rm" && m.error != nil)  // still undoable
        await m.undo()
        #expect(m.undoable == nil && sent("POST", "/v1/speakers/undo").allSatisfy { $0.body["request_id"] as? String == "tok-rm" })
    }

    @Test func aSampleConflictKeepsItsOwnExplanation() async throws {
        let m = VoiceSamplesModel(speakers: try speakers(), personId: "p-alan", tab: .active)
        VoicesHubStub.routes["GET /v1/people/p-alan/samples"] = [(200, Self.samples)]
        VoicesHubStub.routes["POST /v1/samples/a/remove"] = [(409, #"{"error":"forget_in_progress","detail":"x"}"#)]
        await m.load()
        #expect(await m.remove(m.samples[0]) == false)
        #expect(m.error == VoiceConflict.forgetInProgress.message && sent("GET", "/samples").count == 1)
        VoicesHubStub.routes["POST /v1/samples/a/move"] = [(409, #"{"error":"consent_required","detail":"x"}"#)]
        #expect(await m.move(m.samples[0], to: "p-gigi") == false)
        #expect(m.consentNeeded == "p-gigi")
    }

    @Test func forgettingReportsWhetherItWorked() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["DELETE /v1/people/p-gigi"] = [(409, #"{"error":"recovery_pending","detail":"x"}"#),
                                                            (200, #"{"person_id":"p-gigi","voice_forgotten":true}"#)]
        #expect(await speakers.forgetVoice(Person(id: "p-gigi", name: "Gigi")) == false)
        #expect(speakers.error != nil)
        #expect(await speakers.forgetVoice(Person(id: "p-gigi", name: "Gigi")))
    }

    @Test func attestingSendsTheNameAndTheAttestation() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["PUT /v1/people/p-gigi"] = [(200, #"{"id":"p-gigi","name":"Gigi"}"#)]
        #expect(await speakers.attest(Person(id: "p-gigi", name: "Gigi")))
        let body = try #require(sent("PUT", "/v1/people/p-gigi").first?.body)
        #expect(body["attest_knows"] as? Bool == true && body["name"] as? String == "Gigi")
    }

    // MARK: Build 48 feedback: "TA 是谁？" and "The request timed out."

    static let settingsJSON = #"{"acknowledged_at":"2026-10-03T16:00:00.000Z","unknown_voices_enabled":true,"auto_assign":true}"#
    static let peopleJSON = #"{"people":[{"id":"p-alan","name":"Alan","me":true}]}"#

    /// One slow call (suggestions timed out on the phone) must not leave the people list empty.
    @Test func peopleLoadEvenWhenSuggestionsFail() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/status"] = [(200, #"{"features":["voice_review"]}"#)]
        VoicesHubStub.routes["GET /v1/people"] = [(200, Self.peopleJSON)]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(200, Self.settingsJSON)]
        VoicesHubStub.routes["GET /v1/speakers/suggestions"] = [(-1, "")]
        await speakers.refresh()
        #expect(speakers.people.map(\.name) == ["Alan"] && speakers.settings?.unknownVoicesEnabled == true)
        #expect(speakers.error == NetworkTrouble.slow.message)
    }

    @Test func peopleLoadEvenWhenSettingsFail() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/people"] = [(200, Self.peopleJSON)]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(503, #"{"error":"x","detail":"down"}"#)]
        await speakers.refresh()
        #expect(speakers.people.map(\.name) == ["Alan"] && speakers.error != nil)
    }

    @Test func aFailedPeopleCallKeepsTheLastGoodPeople() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/people"] = [(200, Self.peopleJSON), (503, #"{"error":"x","detail":"down"}"#)]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(200, Self.settingsJSON)]
        VoicesHubStub.routes["GET /v1/speakers/suggestions"] = [(200, #"{"suggestions":[]}"#)]
        await speakers.refresh()
        await speakers.refresh()
        #expect(speakers.people.map(\.name) == ["Alan"] && speakers.error != nil)
    }

    /// An idempotent GET is tried once more before the error shows; the server is fast now.
    @Test func aTimedOutGetIsRetriedOnce() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/people"] = [(-1, ""), (200, Self.peopleJSON)]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(200, Self.settingsJSON)]
        VoicesHubStub.routes["GET /v1/speakers/suggestions"] = [(200, #"{"suggestions":[]}"#)]
        await speakers.refresh()
        #expect(speakers.people.map(\.name) == ["Alan"] && speakers.error == nil)
        #expect(sent("GET", "/v1/people").count == 2)
        VoicesHubStub.routes["GET /v1/clips/c.S1.0"] = [(-2, ""), (200, "RIFF")]
        #expect(try await speakers.clip("c.S1.0") == Data("RIFF".utf8))  // clips too
    }

    /// A decision is never sent twice by itself; it fails in short Chinese and can be retried by tap.
    @Test func aTimedOutDecisionIsNotResentButCanBeRetried() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(-1, ""), (200, #"{"undo_token":"t"}"#)]
        await queue.load()
        #expect(await queue.decide(.reject) == false)
        #expect(sent("POST", "/review/s.a.1").count == 1)
        #expect(queue.error == NetworkTrouble.slow.message && queue.canRetry)
        await queue.retry()
        #expect(queue.current?.id == "s.b.1" && queue.undoable?.decision == .reject && queue.error == nil && !queue.canRetry)
        let bodies = sent("POST", "/review/s.a.1").map { $0.body["request_id"] as? String }
        #expect(bodies.count == 2 && bodies[0] == bodies[1])  // the same request id: the server dedupes it
    }

    @Test func networkErrorsReadAsShortChinese() {
        #expect(NetworkTrouble(URLError(.timedOut)) == .slow)
        #expect(NetworkTrouble(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(NetworkTrouble(URLError(.networkConnectionLost)) == .unreachable)
        #expect(NetworkTrouble(URLError(.cannotConnectToHost)) == .unreachable)
        #expect(NetworkTrouble(URLError(.badURL)) == nil)
        #expect(NetworkTrouble.slow.message == "网络有点慢，点这里重试" && NetworkTrouble.unreachable.message == "连不上服务器")
        #expect(SpeakersModel.describe(NetworkTrouble.slow) == "网络有点慢，点这里重试")
    }

    /// "这是谁？": choosing the person the item proposed confirms it; anyone else moves it to them.
    @Test func choosingAPersonConfirmsOrMoves() async throws {
        let queue = VoiceReviewQueue(speakers: try speakers())
        VoicesHubStub.routes["GET /v1/speakers/review"] = [(200, Self.first)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.a.1"] = [(200, #"{"undo_token":"t1"}"#)]
        VoicesHubStub.routes["POST /v1/speakers/review/s.b.1"] = [(200, #"{"undo_token":"t2"}"#)]
        await queue.load()
        #expect(await queue.choose("p-alan"))
        #expect(sent("POST", "/review/s.a.1").first?.body["decision"] as? String == "confirm")
        #expect(await queue.choose("p-gigi"))
        let body = try #require(sent("POST", "/review/s.b.1").first?.body)
        #expect(body["decision"] as? String == "move" && body["person_id"] as? String == "p-gigi")
    }

    // MARK: Astra quick review of 02a9306

    /// People are published as soon as their own answer arrives, not after settings (up to 40 s with a retry).
    @Test func peopleShowWhileSettingsAreStillLoading() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/people"] = [(200, Self.peopleJSON)]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(200, Self.settingsJSON)]
        VoicesHubStub.routes["GET /v1/speakers/suggestions"] = [(200, #"{"suggestions":[]}"#)]
        VoicesHubStub.delays["GET /v1/speakers/settings"] = 1.5
        let refresh = Task { await speakers.refresh() }
        let deadline = Date().addingTimeInterval(1.0)
        while speakers.people.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(speakers.people.map(\.name) == ["Alan"] && speakers.settings == nil)  // settings still on their way
        await refresh.value
        #expect(speakers.settings != nil)
    }

    /// "新的人" from a review item names the speaker it was reviewed against: if the conversation was
    /// reprocessed meanwhile (another revision), nothing is saved and the owner is asked to listen again.
    @Test func namingFromReviewRefusesAChangedSpeaker() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/conversations/c9/speakers"] = [(200, #"{"revision":6,"labels":[{"label":"S1"}]}"#)]
        var item = VoiceItem(label: SpeakerLabel(label: "S1"), in: ConversationContext(id: "c9"))
        item.reviewedRevision = 4
        let flow = NameVoiceFlow(speakers: speakers, items: [item])
        #expect(await flow.name(Person(id: "p-gigi", name: "Gigi")) == false)
        #expect(flow.error == NameVoiceFlow.changedSinceReview && sent("PUT", "/speakers/S1").isEmpty)
        #expect(flow.current?.id == item.id)
    }

    @Test func namingFromReviewSendsTheReviewedRevision() async throws {
        let speakers = try speakers()
        let labels = #"{"revision":4,"labels":[{"label":"S1"}]}"#
        VoicesHubStub.routes["GET /v1/conversations/c9/speakers"] = [(200, labels)]
        VoicesHubStub.routes["PUT /v1/conversations/c9/speakers/S1"] = [(200, labels)]
        var item = VoiceItem(label: SpeakerLabel(label: "S1"), in: ConversationContext(id: "c9"))
        item.reviewedRevision = 4
        let flow = NameVoiceFlow(speakers: speakers, items: [item])
        #expect(await flow.name(Person(id: "p-gigi", name: "Gigi")))
        #expect(sent("PUT", "/speakers/S1").first?.body["expected_revision"] as? Int == 4)
        #expect(sent("GET", "/c9/speakers").count == 1)  // checked fresh, not from a remembered revision
    }

    // MARK: Capabilities

    @Test func refreshReadsTheHubFeatures() async throws {
        let speakers = try speakers()
        VoicesHubStub.routes["GET /v1/status"] = [(200, #"{"features":["name_voice","voice_review","voice_calibration"]}"#)]
        VoicesHubStub.routes["GET /v1/people"] = [(200, #"{"people":[{"id":"p","name":"Alan","me":true,"review_count":3,"status_line":"已启用"}]}"#)]
        VoicesHubStub.routes["GET /v1/speakers/settings"] = [(200, #"{"acknowledged_at":null,"unknown_voices_enabled":false,"auto_assign":true}"#)]
        await speakers.refresh()
        #expect(speakers.serverSupportsVoiceReview && speakers.serverSupportsVoiceCalibration)
        #expect(speakers.people.first?.statusLine == "已启用" && speakers.people.first?.reviewCount == 3)
        speakers.serverChanged()
        #expect(!speakers.serverSupportsVoiceReview && !speakers.serverSupportsVoiceCalibration)
    }
}
