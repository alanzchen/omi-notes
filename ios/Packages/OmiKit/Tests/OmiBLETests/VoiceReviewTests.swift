import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

/// A scripted server for this suite only (its own state, so it can't race other suites' stubs).
final class VoicesHubStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var requests: [(method: String, path: String, query: String?, body: [String: Any])] = []

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
        let key = "\(request.httpMethod ?? "GET") \(path)"
        var queue = Self.routes[key] ?? [(404, #"{"error":"not_found","detail":"no route"}"#)]
        let (status, text) = queue.count > 1 ? queue.removeFirst() : queue[0]
        Self.routes[key] = queue
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
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
