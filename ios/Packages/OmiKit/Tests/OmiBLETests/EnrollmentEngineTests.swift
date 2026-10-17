import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// Voice enrollment through the engine with the simulated device, in real time.
@Suite(.serialized) struct EnrollmentEngineTests {
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func makeEngine() throws -> (OmiEngine, CountingUploadTransport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-enroll-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "omi-enroll-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.tail1234.ts.net")!, token: "tok-enroll")
        let uploads = CountingUploadTransport()
        let engine = OmiEngine(
            config: EngineConfiguration(
                dirs: CaptureDirectories(root: root), appVersion: "test", timezone: "UTC",
                simulatedTrace: SimulatedTrace.synthetic(seconds: 3), useCoreBluetooth: false, tickInterval: 0.2),
            settings: settings, uploadTransport: uploads)
        return (engine, uploads, root)
    }

    func events(_ root: URL) -> [[String: Any]] {
        let outbox = Outbox(dirs: CaptureDirectories(root: root))
        return (outbox.pending() + outbox.sent())
            .filter { if case .event = $0.kind { return true } else { return false } }
            .compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0.url)) as? [String: Any] }
    }

    @MainActor func speakers(_ engine: OmiEngine) -> SpeakersModel {
        let model = SpeakersModel(engine: engine)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerStub.self]
        model.session = URLSession(configuration: config)
        return model
    }

    @MainActor @Test func theAppOnlyEnrollsAgainstAServerThatSupportsIt() async throws {
        let (engine, _, root) = try makeEngine()
        let model = speakers(engine)
        #expect(model.serverSupportsEnrollment == nil && !model.canStartEnrollment)
        ServerStub.routes = ["/v1/status": (200, #"{"ok":true,"server_version":"0.0.9"}"#)]  // an older server
        await model.startEnrollment()
        guard case .failed(let reason) = model.enrollment else { Issue.record("started against an older server"); return }
        #expect(reason == SpeakersModel.serverTooOld)
        #expect(startEvents(root).isEmpty, "no start event was written")
    }

    @MainActor @Test func aFailedRefreshForgetsTheLastServersCapabilities() async throws {
        let (engine, _, _) = try makeEngine()
        let model = speakers(engine)
        ServerStub.routes = [
            "/v1/status": (200, #"{"ok":true,"features":["voice_enrollment"]}"#),
            "/v1/people": (200, #"{"people":[]}"#),
            "/v1/speakers/settings": (200, #"{"acknowledged_at":null,"unknown_voices_enabled":false,"auto_assign":true}"#),
        ]
        await model.refresh()
        #expect(model.serverSupportsEnrollment == true)
        ServerStub.routes = ["/v1/status": (200, #"{"ok":true}"#)]  // rolled back: no People API, no feature
        await model.refresh()
        #expect(model.serverSupportsEnrollment == false && !model.canStartEnrollment)
    }

    @MainActor func waitOnMain(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @MainActor func streamingModel() async throws -> (OmiEngine, SpeakersModel, URL) {
        let (engine, _, root) = try makeEngine()
        engine.setSimulatedMode(true)
        #expect(await waitOnMain(10) { engine.snapshotNow().connection == .streaming })
        ServerStub.routes = ["/v1/status": (200, #"{"ok":true,"features":["voice_enrollment"]}"#)]
        ServerStub.delay = 0.5
        return (engine, speakers(engine), root)
    }

    func startEvents(_ root: URL) -> [[String: Any]] { events(root).filter { $0["type"] as? String == "voice_enrollment_start" } }

    @MainActor @Test func cancellingWhileTheServerIsCheckedStartsNothing() async throws {
        let (engine, model, root) = try await streamingModel()
        defer { ServerStub.delay = 0 }
        let attempt = Task { await model.startEnrollment() }
        #expect(await waitOnMain(2) { model.enrollment == .checking })
        await model.startEnrollment()  // a second tap while checking is ignored
        model.cancelEnrollment()
        await attempt.value
        #expect(model.enrollment == .idle && engine.snapshotNow().activeEnrollmentId == nil)
        #expect(startEvents(root).isEmpty)
    }

    @MainActor @Test func closingTheScreenWhileCheckingOrReadingEndsTheAttempt() async throws {
        let (engine, model, root) = try await streamingModel()
        defer { ServerStub.delay = 0 }
        let attempt = Task { await model.startEnrollment() }
        #expect(await waitOnMain(2) { model.enrollment == .checking })
        model.enrollmentScreenClosed()  // swiped away while checking
        await attempt.value
        #expect(model.enrollment == .idle && engine.snapshotNow().activeEnrollmentId == nil && startEvents(root).isEmpty)

        ServerStub.delay = 0
        await model.startEnrollment()
        guard case .reading = model.enrollment else { Issue.record("\(model.enrollment)"); return }
        model.enrollmentScreenClosed()  // gone while reading: the window is closed, not left open
        #expect(model.enrollment == .idle)
        #expect(await waitOnMain(2) { engine.snapshotNow().activeEnrollmentId == nil })
        #expect(await waitOnMain(2) { self.events(root).contains { ($0["data"] as? [String: Any])?["outcome"] as? String == "cancelled" } })
    }

    @MainActor @Test func aServerChangedWhileItWasCheckedStartsNothing() async throws {
        let (engine, model, root) = try await streamingModel()
        defer { ServerStub.delay = 0 }
        let attempt = Task { await model.startEnrollment() }
        #expect(await waitOnMain(2) { model.enrollment == .checking })
        try engine.configureServer(url: URL(string: "https://older.tail1234.ts.net")!, token: "tok-older")
        await attempt.value
        guard case .failed(let reason) = model.enrollment else { Issue.record("started for another server"); return }
        #expect(reason.contains("changed"))
        #expect(engine.snapshotNow().activeEnrollmentId == nil && startEvents(root).isEmpty)
    }

    @MainActor @Test func aCheckedServerStartsTheEnrollment() async throws {
        let (engine, model, root) = try await streamingModel()
        defer { ServerStub.delay = 0 }
        await model.startEnrollment()
        guard case .reading(let id, 0) = model.enrollment else { Issue.record("\(model.enrollment)"); return }
        #expect(engine.snapshotNow().activeEnrollmentId == id)
        #expect(await waitOnMain(2) { !startEvents(root).isEmpty })
        model.cancelEnrollment()
    }

    @Test func enrollmentWindowIsMarkedAndItsAudioHeldUntilTheStartIsAcknowledged() async throws {
        let (engine, uploads, root) = try makeEngine()
        #expect(throws: OmiEngine.EnrollmentError.notRecording) { try engine.startVoiceEnrollment() }

        engine.setSimulatedMode(true)
        let streaming = await waitFor(10) { engine.snapshotNow().connection == .streaming && (engine.snapshotNow().live?.totalRecords ?? 0) > 20 }
        #expect(streaming)
        let id = try engine.startVoiceEnrollment()
        #expect(throws: OmiEngine.EnrollmentError.alreadyRunning) { try engine.startVoiceEnrollment() }
        #expect(engine.snapshotNow().activeEnrollmentId == id)
        let hold = try #require(engine.enrollmentGate.snapshot.first)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        engine.finishVoiceEnrollment(outcome: .completed)
        try await Task.sleep(nanoseconds: 500_000_000)

        let evs = events(root)
        let start = try #require(evs.first { $0["type"] as? String == "voice_enrollment_start" })
        let end = try #require(evs.first { $0["type"] as? String == "voice_enrollment_end" })
        #expect((start["data"] as? [String: Any])?["enrollment_id"] as? String == id)
        #expect(start["capture_id"] as? String == hold.captureId)
        let endData = try #require(end["data"] as? [String: Any])
        #expect(endData["outcome"] as? String == "completed")
        #expect((endData["end_offset_us"] as? Int ?? 0) > (start["offset_us"] as? Int ?? .max))
        #expect(engine.snapshotNow().activeEnrollmentId == nil)

        // The test transport never completes uploads, so the start event is never acknowledged:
        // no chunk of the window (nor the end event) may have been handed to the uploader.
        let outbox = Outbox(dirs: CaptureDirectories(root: root))
        let windowChunks = outbox.pending().filter {
            if case .chunk(let c, let seq) = $0.kind { return c == hold.captureId && seq >= hold.fromSequence } else { return false }
        }
        #expect(!windowChunks.isEmpty, "finishing rotates the window's chunk into the outbox")
        let started = uploads.startedNames
        #expect(windowChunks.allSatisfy { !started.contains($0.name) })
        #expect(started.contains { $0.hasPrefix("event_") }, "the start event itself uploads")
    }

    @Test func disconnectDuringEnrollmentEndsItAsInterrupted() async throws {
        let (engine, _, root) = try makeEngine()
        engine.setSimulatedMode(true)
        _ = await waitFor(10) { engine.snapshotNow().connection == .streaming && (engine.snapshotNow().live?.totalRecords ?? 0) > 20 }
        let id = try engine.startVoiceEnrollment()
        engine.simulateOutOfRange(returnAfter: 60)
        try await Task.sleep(nanoseconds: 800_000_000)
        let end = try #require(events(root).first { $0["type"] as? String == "voice_enrollment_end" })
        let data = try #require(end["data"] as? [String: Any])
        #expect(data["enrollment_id"] as? String == id && data["outcome"] as? String == "interrupted")
        #expect(engine.snapshotNow().activeEnrollmentId == nil)
    }
}


/// Canned JSON by path for `SpeakersModel` (404 otherwise).
final class ServerStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    /// Seconds before answering (a slow server).
    nonisolated(unsafe) static var delay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.routes[request.url?.path ?? ""] ?? (404, #"{"error":"not_found","detail":"no route"}"#)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let answer: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: answer) } else { answer() }
    }
    override func stopLoading() {}
}
