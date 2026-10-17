import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
@testable import OmiWatchKit

/// Watch performance telemetry from the Watch's queue to the phone's upload outbox. SYNTHETIC
/// values: no Watch battery is read here.
@Suite(.serialized) struct WatchTelemetryTests {
    func sample(_ n: Int, battery: Double? = 0.8, event: String = "periodic") -> WatchPerfSample {
        WatchPerfSample(id: UUID().uuidString.lowercased(), at: ISO8601UTC.format(Date(timeIntervalSince1970: 1_791_000_000 + Double(n) * 300)),
                        monoS: Double(n) * 300, bootId: "boot", launchId: "launch", recordingId: "rec", event: event,
                        state: "recording", battery: battery, batteryState: battery == nil ? "unknown" : "unplugged",
                        counters: ["callbacks": n], gauges: [:], app: "t", os: "t", model: "t")
    }

    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("omi-perf-\(UUID().uuidString)") }

    @Test func samplesSurviveARelaunchAreSealedInOrderAndOnlyAcknowledgedOnesLeave() throws {
        let dir = root()
        var q = WatchPerfQueue(root: dir)
        q.append(sample(0, event: "start"), deviceId: "watch-1", binding: "phone-A")
        q.append(sample(1, battery: nil), deviceId: "watch-1", binding: "phone-A")
        #expect(q.ids().isEmpty, "still open")
        q = WatchPerfQueue(root: dir)  // the app was killed: the open batch is on disk
        q.seal(deviceId: "watch-1", binding: "phone-A")
        for n in 2..<(2 + WatchPerfQueue.maxSamplesPerBatch) { q.append(sample(n), deviceId: "watch-1", binding: "phone-A") }
        q.append(sample(20, event: "stopped"), deviceId: "watch-1", binding: "phone-A", seal: true)
        let batches = q.batches()
        #expect(batches.map { $0.data.samples.count } == [2, WatchPerfQueue.maxSamplesPerBatch, 1])
        #expect(batches[0].data.samples[1].battery == nil, "unknown stays unknown")
        #expect(q.ids() == batches.map(\.id) && batches.allSatisfy { $0.id == $0.data.batchId })
        q.acknowledge([batches[1].id])
        #expect(q.ids() == [batches[0].id, batches[2].id])
    }

    @Test func overTheCapTheOldestTelemetryGoesAndTheGapIsReported() {
        let q = WatchPerfQueue(root: root())
        for n in 0..<(WatchPerfQueue.maxBatches + 3) { q.append(sample(n), deviceId: "w", binding: "p", seal: true) }
        #expect(q.ids().count == WatchPerfQueue.maxBatches)
        q.append(sample(999), deviceId: "w", binding: "p", seal: true)
        q.append(sample(1000), deviceId: "w", binding: "p", seal: true)
        // 5 batches over the cap were discarded: each is reported once, by the next batch sealed
        // (4 so far; the last is reported by the next one), never silently
        #expect(q.batches().map(\.data.droppedBatches).reduce(0, +) == 4)
        #expect(q.batches().suffix(2).map(\.data.droppedBatches) == [1, 1] && q.ids().count == WatchPerfQueue.maxBatches)
    }

    @Test func theHeartbeatCarriesTheWatchRelayOnlyWhenThereIsOne() throws {
        let none = try JSONSerialization.jsonObject(with: ContractJSON.encode(HeartbeatData(battery: 80))) as? [String: Any]
        #expect(none?["watch_relay"] == nil, "older shape unchanged without Watch audio")
        let relay = HeartbeatData(watchRelay: WatchRelayHealth(received: 25, refused: 3, lastRefusal: "segment: damaged", lastReceivedAt: nil, inboxPending: 1))
        let body = try #require(JSONSerialization.jsonObject(with: ContractJSON.encode(relay)) as? [String: Any])
        let r = try #require(body["watch_relay"] as? [String: Any])
        #expect(r["received"] as? Int == 25 && r["refused"] as? Int == 3 && r["last_refusal"] as? String == "segment: damaged" && r["inbox_pending"] as? Int == 1)
    }

    @Test func thePhoneQueuesEachBatchOnceAsAnEventAndRefusesAnotherPhones() async throws {
        let dir = root()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-perf-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: dir), appVersion: "t", timezone: "UTC", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        let q = WatchPerfQueue(root: dir.appendingPathComponent("w"))
        q.append(sample(0, event: "start"), deviceId: "watch-1", binding: settings.phoneInstallId!)
        q.append(sample(1, event: "stopped"), deviceId: "watch-1", binding: settings.phoneInstallId!, seal: true)
        let batch = try #require(q.batches().first)
        #expect(try engine.acceptWatchPerf(WatchWire.encode(batch)) == batch.id)
        let outbox = Outbox(dirs: CaptureDirectories(root: dir))
        let item = try #require(outbox.pending().first { $0.kind == .event(eventId: batch.id) })
        let first = try Data(contentsOf: item.url)
        #expect(try engine.acceptWatchPerf(WatchWire.encode(batch)) == batch.id, "a resend is acknowledged again")
        #expect(try Data(contentsOf: item.url) == first && outbox.pending().filter { $0.kind == .event(eventId: batch.id) }.count == 1)
        let body = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(body["type"] as? String == "watch_perf" && body["device_id"] as? String == "watch-1" && body["capture_id"] == nil,
                "telemetry, not part of any capture")
        var other = batch
        other.binding = "another-phone"
        #expect(throws: WatchRelayError.wrongPhone) { try engine.acceptWatchPerf(WatchWire.encode(other)) }
    }
}
