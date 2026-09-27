import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite struct EnrollmentEventTests {
    @Test func startAndEndEventShapes() throws {
        let t = TestEnv()
        let w = EventWriter(outbox: t.outbox, clock: t.clock)
        let start = try w.voiceEnrollmentStart(enrollmentId: "e1", deviceId: "dev-1", captureId: "cap-1", offsetUs: 5_000_000)
        let end = try w.voiceEnrollmentEnd(enrollmentId: "e1", deviceId: "dev-1", captureId: "cap-1", endOffsetUs: 55_000_000, outcome: .completed)
        let s = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: start.url)) as? [String: Any])
        #expect(s["type"] as? String == "voice_enrollment_start")
        #expect(s["capture_id"] as? String == "cap-1" && s["offset_us"] as? Int == 5_000_000)
        #expect((s["data"] as? [String: Any])?["enrollment_id"] as? String == "e1")
        let e = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: end.url)) as? [String: Any])
        #expect(e["type"] as? String == "voice_enrollment_end")
        let data = try #require(e["data"] as? [String: Any])
        #expect(data["enrollment_id"] as? String == "e1" && data["end_offset_us"] as? Int == 55_000_000)
        #expect(data["outcome"] as? String == "completed")
        #expect(e["offset_us"] as? Int == 55_000_000)
    }
}

@Suite struct EnrollmentGateTests {
    func chunk(_ t: TestEnv, _ captureId: String, _ seq: Int) throws -> OutboxItem {
        try t.outbox.write(Data("chunk \(captureId) \(seq)".utf8), kind: .chunk(captureId: captureId, sequence: seq))
    }

    func setUp() throws -> (TestEnv, EnrollmentGate, OutboxItem) {
        let t = TestEnv()
        let start = try EventWriter(outbox: t.outbox, clock: t.clock)
            .voiceEnrollmentStart(enrollmentId: "e1", deviceId: "dev-1", captureId: "cap-1", offsetUs: 1)
        guard case .event(let eventId) = start.kind else { throw InjectedFault(what: "kind") }
        let gate = EnrollmentGate(stateDir: t.dirs.state, outbox: t.outbox)
        try gate.hold(.init(enrollmentId: "e1", captureId: "cap-1", fromSequence: 3, startEventId: eventId))
        return (t, gate, start)
    }

    @Test func holdsChunksFromTheStartUntilTheStartEventIsAcknowledged() throws {
        let (t, gate, start) = try setUp()
        #expect(gate.mayUpload(try chunk(t, "cap-1", 2)), "chunks before the window upload normally")
        let held = try chunk(t, "cap-1", 3)
        #expect(!gate.mayUpload(held))
        #expect(gate.mayUpload(try chunk(t, "cap-2", 5)), "other captures are unaffected")
        #expect(gate.mayUpload(start), "the start event itself is never held")
        try t.outbox.markSent(start.name)
        gate.didAcknowledge(start)
        #expect(gate.mayUpload(held))
        #expect(gate.snapshot.isEmpty)
    }

    @Test func endEventWaitsForTheStartEvent() throws {
        let (t, gate, start) = try setUp()
        let end = try EventWriter(outbox: t.outbox, clock: t.clock)
            .voiceEnrollmentEnd(enrollmentId: "e1", deviceId: "dev-1", captureId: "cap-1", endOffsetUs: 9, outcome: .completed)
        guard case .event(let endId) = end.kind else { return }
        gate.attachEndEvent(enrollmentId: "e1", endEventId: endId)
        #expect(!gate.mayUpload(end))
        try t.outbox.markSent(start.name)
        #expect(gate.mayUpload(end))
    }

    @Test func holdsSurviveARelaunch() throws {
        let (t, _, _) = try setUp()
        let relaunched = EnrollmentGate(stateDir: t.dirs.state, outbox: t.outbox)
        #expect(!relaunched.mayUpload(try chunk(t, "cap-1", 4)))
    }

    @Test func aRejectedStartEventReleasesTheAudio() throws {
        let (t, gate, start) = try setUp()
        try t.outbox.quarantine(start.name, reason: "HTTP 422")
        #expect(gate.mayUpload(try chunk(t, "cap-1", 3)), "holding audio forever would be worse")
    }

    @Test func aMissingStartEventIsWrittenAgainAndTheAudioStaysHeld() throws {
        let t = TestEnv()
        let writer = EventWriter(outbox: t.outbox, clock: t.clock)
        let start = try writer.voiceEnrollmentStart(enrollmentId: "e1", deviceId: "dev-1", captureId: "cap-1", offsetUs: 7,
                                                    at: "2026-09-26T19:32:05.200Z")
        guard case .event(let eventId) = start.kind else { throw InjectedFault(what: "kind") }
        let gate = EnrollmentGate(stateDir: t.dirs.state, outbox: t.outbox)
        try gate.hold(.init(enrollmentId: "e1", captureId: "cap-1", fromSequence: 3, startEventId: eventId,
                            deviceId: "dev-1", startAt: "2026-09-26T19:32:05.200Z", startOffsetUs: 7))
        try FileManager.default.removeItem(at: try #require(t.outbox.locate(start.kind)))  // unexplained: never acknowledged

        #expect(!gate.mayUpload(try chunk(t, "cap-1", 3)), "without a way to rewrite it, the audio stays held")
        gate.reemitStart = { h in
            let item = try writer.voiceEnrollmentStart(enrollmentId: h.enrollmentId, deviceId: h.deviceId ?? "", captureId: h.captureId,
                                                       offsetUs: h.startOffsetUs ?? 0, at: h.startAt)
            guard case .event(let id) = item.kind else { throw InjectedFault(what: "kind") }
            return id
        }
        #expect(!gate.mayUpload(try chunk(t, "cap-1", 4)))
        let hold = try #require(gate.snapshot.first)
        #expect(hold.startEventId != eventId)
        let rewritten = try #require(t.outbox.pending().first { $0.kind == .event(eventId: hold.startEventId) })
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: rewritten.url)) as? [String: Any]
        #expect(body?["at"] as? String == "2026-09-26T19:32:05.200Z" && body?["offset_us"] as? Int == 7)
        #expect((body?["data"] as? [String: Any])?["enrollment_id"] as? String == "e1")
        try t.outbox.markSent(rewritten.name)
        gate.didAcknowledge(rewritten)
        #expect(gate.mayUpload(try chunk(t, "cap-1", 4)), "released once the rewritten start is acknowledged")
    }

    @Test func compositeGateRequiresEveryGate() throws {
        let (t, gate, _) = try setUp()
        let ledger = RingCaptureLedger(dirs: t.dirs, outbox: t.outbox)
        let both = CompositeUploadGate([ledger, gate])
        let held = try chunk(t, "cap-1", 3)
        #expect(!both.mayUpload(held))
        #expect(both.heldReason(held)?.contains("voice enrollment") == true)
        #expect(both.mayUpload(try chunk(t, "cap-9", 0)))
    }
}

@Suite struct SpeakerModelTests {
    @Test func unassigningEncodesAnExplicitNull() throws {
        let body = try APIClient.snakeEncoder.encode(AssignSpeakerRequest(personId: nil, expectedRevision: 4, requestId: "r1"))
        let o = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(o.keys.contains("person_id") && o["person_id"] is NSNull)
        #expect(o["expected_revision"] as? Int == 4 && o["request_id"] as? String == "r1")
        #expect(!o.keys.contains("not_person_id"))
    }

    @Test func decodesSnakeCaseResponses() throws {
        let json = #"{"revision":3,"transcript_sha":"abc","audio_available":true,"labels":[{"label":"S1","person_id":"p1","name":"Alan","source":"auto","distance":0.31,"margin":0.2,"evidence_s":12.5,"clip_id":"c1","excerpt":"hi"}]}"#
        let r = try APIClient.snakeDecoder.decode(ConversationSpeakers.self, from: Data(json.utf8))
        #expect(r.revision == 3 && r.audioAvailable == true)
        #expect(r.labels.first?.personId == "p1" && r.labels.first?.evidenceS == 12.5 && r.labels.first?.isAuto == true)
    }

    @Test func serverFeaturesTellWhetherEnrollmentIsSupported() throws {
        let json = #"{"ok":true,"server_version":"0.1.0","protocol_version":1,"features":["voice_enrollment"]}"#
        let new = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))  // as `APIClient.status()` decodes
        let old = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"server_version":"0.0.9"}"#.utf8))
        #expect(new.supportsVoiceEnrollment && new.serverVersion == "0.1.0" && !old.supportsVoiceEnrollment)
    }

    @Test func enrollmentPollingStopsOnEveryServerDecision() {
        #expect(!EnrollmentStatus(state: "waiting_audio").isFinal && !EnrollmentStatus(state: "processing").isFinal)
        for state in ["accepted", "needs_another_sample", "cancelled", "interrupted"] {
            #expect(EnrollmentStatus(state: state).isFinal, "\(state)")
        }
    }
}

/// Serves canned responses to `APIClient` and records requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            req.httpBody = data
        }
        Self.requests.append(req)
        let (status, body) = Self.handler?(req) ?? (500, Data())
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct SpeakerAPIClientTests {
    func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.requests = []
        return APIClient(endpoint: ServerEndpoint(baseURL: URL(string: "https://mac.tail1234.ts.net")!, token: "tok"),
                         session: URLSession(configuration: config))
    }

    @Test func requestShapes() async throws {
        let api = client()
        StubURLProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("GET", "/v1/people"):
                return (200, Data(#"{"people":[{"id":"p1","name":"Alan","me":true,"samples":4,"auto_active":false}]}"#.utf8))
            case ("PUT", "/v1/conversations/c1/speakers/S2"):
                return (200, Data(#"{"revision":5,"labels":[]}"#.utf8))
            case ("GET", "/v1/clips/k1"):
                return (410, Data(#"{"error":"audio_expired","detail":"raw audio deleted"}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let people = try await api.people()
        #expect(people.first?.isMe == true && people.first?.autoActive == false)
        _ = try await api.assignSpeaker(conversationId: "c1", label: "S2", AssignSpeakerRequest(personId: "p9", expectedRevision: 4, requestId: "r1"))
        let put = try #require(StubURLProtocol.requests.last)
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        #expect(body["person_id"] as? String == "p9" && body["expected_revision"] as? Int == 4)
        await #expect(throws: APIError.self) { _ = try await api.clip("k1") }
        do {
            _ = try await api.clip("k1")
        } catch APIError.http(let code, _) {
            #expect(code == 410)
        }
    }
}
