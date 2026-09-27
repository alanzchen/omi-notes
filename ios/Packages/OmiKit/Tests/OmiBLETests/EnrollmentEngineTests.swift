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
