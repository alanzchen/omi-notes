import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
@testable import OmiWatchKit

/// All-day Watch recording: a recording that is never stopped is still cut into whole segments,
/// handed on and uploaded part by part, and the Watch pauses (never deletes) when it fills up.
@Suite(.serialized) struct WatchAllDayTests {
    @Test func aLongRecordingIsCutIntoContiguousSegmentsWithoutStopping() {
        var clock = SegmentClock(framesPerSegment: 60 * 16_000)
        var segments: [Int] = [], open = 0, fed = 0
        let sizes = [1_600, 4_096, 1_365, 37, 16_000, 2_048]  // irregular buffers, as the input tap delivers them
        var i = 0
        while fed < 10 * 60 * 16_000 + 12_345 {  // 10 minutes and a bit, never stopped
            let n = sizes[i % sizes.count]; i += 1
            fed += n
            for run in clock.split(n) {
                open += run.frames
                if run.closesSegment { segments.append(open); open = 0 }
            }
        }
        #expect(segments.count == 10 && segments.allSatisfy { $0 == 960_000 }, "every segment exactly 60 s: \(segments)")
        #expect(segments.reduce(0, +) + open == fed, "no frame lost or repeated at a boundary")
        #expect(clock.framesInSegment == open)
    }

    @Test func aFullWatchPausesRecordingAndKeepsWhatIsWaiting() throws {
        #expect(WatchStorage.pauseReason(freeBytes: 2_000_000_000, waitingBytes: 50_000_000) == nil)
        #expect(WatchStorage.pauseReason(freeBytes: nil, waitingBytes: 0) == nil, "unknown free space doesn't block")
        #expect(WatchStorage.pauseReason(freeBytes: 100_000_000, waitingBytes: 0)?.contains("almost full") == true)
        #expect(WatchStorage.pauseReason(freeBytes: 2_000_000_000, waitingBytes: WatchStorage.maximumWaiting)?.contains("Resume") == true)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-wfull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let out = WatchOutbox(root: root.appendingPathComponent("outbox"))
        let a = try WatchRelayTests.segmentFile(seconds: 1, in: root, name: "a")
        let m = WatchRelayTests().manifest(a, recording: "r", index: 0, binding: "p", start: 0)
        try out.add(segmentFile: a, segment: m)
        #expect(out.waitingBytes == Int64(m.bytes) && m.bytes > 0)
    }

    @Test func anUnstoppedRecordingIsQueuedAndUploadedPartByPart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-wday-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-wday-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.tail1234.ts.net")!, token: "tok-watch-day")
        let engine = OmiEngine(
            config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "test", timezone: "UTC",
                                        useCoreBluetooth: false, tickInterval: 0.2),
            settings: settings, uploadTransport: CountingUploadTransport())
        let tmp = root.appendingPathComponent("from-watch")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let rec = UUID().uuidString.lowercased()
        for i in 0..<3 {  // three minutes of a recording the wearer hasn't stopped (no end marker)
            let f = try WatchRelayTests.segmentFile(seconds: 1, in: tmp, name: "s\(i)")
            let m = WatchRelayTests().manifest(f, recording: rec, index: i, binding: settings.phoneInstallId, start: Int64(i) * 60_000_000)
            #expect(try engine.acceptWatchSegment(file: f, manifest: WatchWire.encode(m)) == m.id)
        }
        func waitFor(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
            return condition()
        }
        #expect(await waitFor { engine.snapshotNow().watchWaitingUpload == 3 }, "\(engine.snapshotNow().watchWaitingUpload)")
        let outbox = Outbox(dirs: CaptureDirectories(root: root))
        #expect(outbox.pending().filter { $0.kind == .seal(captureId: rec) }.isEmpty, "nothing waits for Stop: chunks go up unsealed")

        try outbox.markSent(OutboxKind.chunk(captureId: rec, sequence: 0).fileName)  // the server acknowledged the first part
        #expect(await waitFor { engine.snapshotNow().watchWaitingUpload == 2 })
        let s = engine.snapshotNow()
        #expect(s.watchReceived == 3 && s.watchPending == 0 && s.watchLastUploadedAt != nil)
    }
}
