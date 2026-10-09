import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

/// A scripted server for this suite only (its own state, so it can't race other suites' stubs).
final class VoiceServerStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var requests: [(method: String, path: String, body: [String: Any])] = []

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
        Self.requests.append((request.httpMethod ?? "GET", path, body))
        var queue = Self.routes["\(request.httpMethod ?? "GET") \(path)"] ?? [(404, #"{"error":"not_found","detail":"no route"}"#)]
        let (status, text) = queue.count > 1 ? queue.removeFirst() : queue[0]
        Self.routes["\(request.httpMethod ?? "GET") \(path)"] = queue
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized) struct NameVoiceFlowTests {
    static let suggestionJSON = #"""
    {"id":"sug1","kind":"is_this_person","person_id":"p-priya","clip_id":"c1.S2.0","seconds":42,"excerpt":"first sentence",
     "conversations":3,"days":2,"conversation":{"id":"c1","started_at":"2026-10-07T19:14:00.000Z","title":"Sprint planning"},
     "clips":[{"id":"c1.S2.0","seconds":6.5,"text":"I can take the budget sheet","conversation_id":"c1"},
              {"id":"c1.S2.1","seconds":4.0,"text":"Friday works","conversation_id":"c1"}],
     "other_day":{"id":"c3.S2.0","seconds":5,"text":"Lunch is on me","conversation_id":"c3","conversation":{"id":"c3","started_at":"2026-10-05T17:00:00.000Z"}},
     "scope":[{"id":"c1"},{"id":"c2"},{"id":"c3"}]}
    """#
    static let priya = Person(id: "p-priya", name: "Priya")

    func model() throws -> SpeakersModel {
        VoiceServerStub.routes = [:]
        VoiceServerStub.requests = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-voice-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok")
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        let speakers = SpeakersModel(engine: engine)
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [VoiceServerStub.self]
        speakers.session = URLSession(configuration: c)
        return speakers
    }

    func suggestion() throws -> SpeakerSuggestion {
        try APIClient.snakeDecoder.decode(SpeakerSuggestion.self, from: Data(Self.suggestionJSON.utf8))
    }

    func sent(_ method: String, _ suffix: String) -> [[String: Any]] {
        VoiceServerStub.requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }.map(\.body)
    }

    @Test func aSuggestionShowsItsOwnClipsContextAndScope() throws {
        let item = VoiceItem(suggestion: try suggestion())
        #expect(item.question == .isThis(personId: "p-priya"))
        #expect(item.clips.map(\.text) == ["I can take the budget sheet", "Friday works"])  // never the first sentence
        #expect(item.context?.title == "Sprint planning" && item.otherDay?.conversationId == "c3")
        #expect(item.spansConversations && item.scope.count == 3)
    }

    @Test func namingThenUndoAsksAboutTheSameVoiceAgain() async throws {
        let speakers = try model()
        VoiceServerStub.routes["POST /v1/speakers/suggestions/sug1/assign"] = [(200, #"{"relabeled_conversations":["c1","c2","c3"]}"#)]
        VoiceServerStub.routes["POST /v1/speakers/undo"] = [(200, #"{"undone":["c1","c2","c3"],"skipped":[]}"#)]
        let flow = NameVoiceFlow(speakers: speakers, items: [VoiceItem(suggestion: try suggestion())])
        #expect(await flow.name(Self.priya))
        #expect(flow.isFinished && flow.saved.count == 1 && flow.undoable != nil)
        let requestId = try #require(sent("POST", "/assign").first?["request_id"] as? String)
        await flow.undo()
        #expect(sent("POST", "/v1/speakers/undo").first?["request_id"] as? String == requestId)
        #expect(flow.current?.id == "s:sug1" && flow.saved.isEmpty && flow.undoable == nil)
    }

    @Test func keepUnknownIsPermanentNotADismissal() async throws {
        let speakers = try model()
        VoiceServerStub.routes["POST /v1/speakers/suggestions/sug1/keep-unknown"] = [(200, #"{"conversations":["c1","c2","c3"]}"#)]
        let flow = NameVoiceFlow(speakers: speakers, items: [VoiceItem(suggestion: try suggestion())])
        #expect(await flow.keepUnknown())
        #expect(sent("POST", "/keep-unknown").count == 1 && sent("POST", "/dismiss").isEmpty)
        #expect(flow.saved.first?.person == nil && flow.isFinished)
    }

    @Test func skipSendsNothing() throws {
        let speakers = try model()
        let flow = NameVoiceFlow(speakers: speakers, items: [VoiceItem(suggestion: try suggestion())])
        flow.skip()
        #expect(flow.isFinished && flow.skipped.count == 1 && VoiceServerStub.requests.isEmpty)
    }

    @Test func aFailedSaveStaysOnTheVoiceAndSaysWhy() async throws {
        let speakers = try model()
        VoiceServerStub.routes["POST /v1/speakers/suggestions/sug1/assign"] = [(503, #"{"error":"vault_read_only","detail":"read only"}"#)]
        let flow = NameVoiceFlow(speakers: speakers, items: [VoiceItem(suggestion: try suggestion())])
        #expect(await flow.name(Self.priya) == false)
        #expect(flow.current?.id == "s:sug1" && flow.error?.hasPrefix("Couldn't save") == true && flow.saved.isEmpty)
    }

    @Test func aConversationsSpeakerUsesTheCurrentRevisionAndRecoversFromAConflict() async throws {
        let speakers = try model()
        let labels = #"{"revision":4,"labels":[{"label":"S1","person_id":"p-me","name":"Alan","source":"user"},{"label":"S2","clips":[{"id":"c9.S2.0","text":"Hello there"}]},{"label":"S3","kept_unknown":true}]}"#
        VoiceServerStub.routes["GET /v1/conversations/c9/speakers"] = [(200, labels)]
        VoiceServerStub.routes["PUT /v1/conversations/c9/speakers/S2"] = [(409, #"{"error":"stale_revision","detail":"x"}"#), (200, labels.replacingOccurrences(of: #""revision":4"#, with: #""revision":6"#))]
        let data = try APIClient.snakeDecoder.decode(ConversationSpeakers.self, from: Data(labels.utf8))
        let items = VoiceItem.unnamed(data, in: ConversationContext(id: "c9"))
        #expect(items.map(\.id) == ["l:c9:S2"] && items[0].clips.first?.text == "Hello there")  // named and kept-unknown left out
        let flow = NameVoiceFlow(speakers: speakers, items: items)
        #expect(await flow.name(Self.priya) == false && flow.error?.contains("changed") == true)
        #expect(await flow.name(Self.priya))
        let puts = sent("PUT", "/speakers/S2")
        #expect(puts.count == 2 && puts.allSatisfy { $0["expected_revision"] as? Int == 4 && $0["person_id"] as? String == "p-priya" })
        #expect(sent("GET", "/speakers").count == 2)  // the revision was read again after the conflict
    }

    @Test func keepingASpeakerUnknownSendsTheDurableFlag() async throws {
        let speakers = try model()
        let labels = #"{"revision":1,"labels":[{"label":"S2"}]}"#
        VoiceServerStub.routes["GET /v1/conversations/c9/speakers"] = [(200, labels)]
        VoiceServerStub.routes["PUT /v1/conversations/c9/speakers/S2"] = [(200, labels)]
        let flow = NameVoiceFlow(speakers: speakers, items: [VoiceItem(label: SpeakerLabel(label: "S2"), in: ConversationContext(id: "c9"))])
        #expect(await flow.keepUnknown())
        let body = try #require(sent("PUT", "/speakers/S2").first)
        #expect(body["keep_unknown"] as? Bool == true && body["person_id"] is NSNull)
    }

    @Test func anUndoOfSomethingChangedSinceKeepsTheLaterChoice() async throws {
        let speakers = try model()
        VoiceServerStub.routes["POST /v1/speakers/suggestions/sug1/assign"] = [(200, #"{"relabeled_conversations":[]}"#)]
        VoiceServerStub.routes["POST /v1/speakers/undo"] = [(200, #"{"undone":[],"skipped":["c1"]}"#)]
        let flow = NameVoiceFlow(speakers: speakers, items: [VoiceItem(suggestion: try suggestion())])
        await flow.name(Self.priya)
        await flow.undo()
        #expect(flow.isFinished && flow.error?.contains("later choice") == true)
    }

    @Test func theWaveformComesFromTheClipsSamples() {
        var pcm = [Int16](repeating: 0, count: 8000) + (0..<8000).map { Int16(sin(Double($0) / 3) * 12000) }
        pcm += [Int16](repeating: 0, count: 0)
        let wav = Self.wav(pcm)
        let bars = Waveform.bars(wav: wav, count: 4) ?? []
        #expect(bars.count == 4 && bars[0] == 0 && bars[1] == 0 && bars[3] > 0.9)
        #expect(Waveform.bars(wav: Data("not audio".utf8), count: 4) == nil)
    }

    static func wav(_ pcm: [Int16]) -> Data {
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
        let data = pcm.flatMap { [UInt8(UInt16(bitPattern: $0) & 255), UInt8(UInt16(bitPattern: $0) >> 8)] }
        var out = Array("RIFF".utf8) + le32(36 + data.count) + Array("WAVE".utf8)
        out += Array("fmt ".utf8) + le32(16) + [1, 0, 1, 0] + le32(16000) + le32(32000) + [2, 0, 16, 0]
        out += Array("data".utf8) + le32(data.count) + data
        return Data(out)
    }
}
