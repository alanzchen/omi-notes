import Foundation
import Testing
import OmiProtocol
@testable import OmiWatchKit

/// The phone ↔ Watch messages, byte for byte, as build 38's Watch and phone apps exchange them
/// (WatchRelay.swift and WatchPerfQueue.swift are unchanged since 253a7ed). A renamed key or another
/// date encoding would still pass the round-trip tests, but Watch apps already in the field are
/// updated separately from the phone: these catch it.
@Suite struct WatchWireCompatibilityTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000.123)

    @Test func theMessagesKeepTheirShape() {
        let segment = WatchSegment(recordingId: "rec-1", index: 3, deviceId: "watch-1", deviceName: "Apple Watch", binding: "phone-A",
                                   recordingStartedAt: t0, startOffsetUs: 180_000_000, endOffsetUs: 240_000_000, bytes: 240_000, sha256: "ab12")
        #expect(String(decoding: WatchWire.encode(segment), as: UTF8.self) == #"{"binding":"phone-A","bytes":240000,"deviceId":"watch-1","deviceName":"Apple Watch","endOffsetUs":240000000,"index":3,"recordingId":"rec-1","recordingStartedAt":1791000000123,"sha256":"ab12","startOffsetUs":180000000}"#)
        let end = WatchRecordingEnd(recordingId: "rec-1", deviceId: "watch-1", binding: "phone-A", lastIndex: 3, endOffsetUs: 241_500_000,
                                    endedAt: t0.addingTimeInterval(241.5), reason: .userStopped)
        #expect(String(decoding: WatchWire.encode(end), as: UTF8.self) == #"{"binding":"phone-A","deviceId":"watch-1","endOffsetUs":241500000,"endedAt":1791000241623,"lastIndex":3,"reason":"user_stopped","recordingId":"rec-1"}"#)
        let report = WatchReport(state: .recording, since: t0, waitingParts: 2, waitingSeconds: 120, at: t0.addingTimeInterval(300), deviceId: "watch-1",
                                 stats: ["transfers": 4])
        #expect(String(decoding: WatchWire.encode(report), as: UTF8.self) == #"{"at":1791000300123,"deviceId":"watch-1","since":1791000000123,"state":"recording","stats":{"transfers":4},"waitingParts":2,"waitingSeconds":120}"#)
        let perf = WatchPerfBatch(id: "batch-1", deviceId: "watch-1", binding: "phone-A", data: WatchPerfData(batchId: "batch-1", samples: [
            WatchPerfSample(id: "s1", at: "2026-10-15T09:00:00.000Z", monoS: 0, bootId: "boot", launchId: "launch", recordingId: "rec-1",
                            event: "start", state: "recording", battery: 0.9, batteryState: "unplugged", counters: ["callbacks": 1],
                            gauges: ["outbox_parts": 1], app: "0.1.0 (38)", os: "11.0", model: "Watch7,1")], droppedBatches: 0))
        #expect(String(decoding: WatchWire.encode(perf), as: UTF8.self) == #"{"binding":"phone-A","data":{"batch_id":"batch-1","dropped_batches":0,"samples":[{"app":"0.1.0 (38)","at":"2026-10-15T09:00:00.000Z","battery":0.9,"battery_state":"unplugged","boot_id":"boot","counters":{"callbacks":1},"event":"start","gauges":{"outbox_parts":1},"id":"s1","launch_id":"launch","model":"Watch7,1","mono_s":0,"os":"11.0","recording_id":"rec-1","state":"recording"}],"schema":1},"deviceId":"watch-1","id":"batch-1"}"#)
    }

    @Test func thePhoneReadsWhatABuild38WatchSends() throws {
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let segment = try #require(WatchWire.decode(WatchSegment.self, Data(#"{"binding":"phone-A","bytes":240000,"deviceId":"watch-1","deviceName":"Apple Watch","endOffsetUs":240000000,"index":3,"recordingId":"rec-1","recordingStartedAt":1791000000000,"sha256":"ab12","startOffsetUs":180000000}"#.utf8)))
        #expect(segment == WatchSegment(recordingId: "rec-1", index: 3, deviceId: "watch-1", deviceName: "Apple Watch", binding: "phone-A",
                                        recordingStartedAt: start, startOffsetUs: 180_000_000, endOffsetUs: 240_000_000, bytes: 240_000, sha256: "ab12"))
        let end = try #require(WatchWire.decode(WatchRecordingEnd.self, Data(#"{"binding":"phone-A","deviceId":"watch-1","endOffsetUs":241500000,"endedAt":1791000241000,"lastIndex":-1,"reason":"app_recovered","recordingId":"rec-1"}"#.utf8)))
        #expect(end == WatchRecordingEnd(recordingId: "rec-1", deviceId: "watch-1", binding: "phone-A", lastIndex: -1, endOffsetUs: 241_500_000,
                                         endedAt: start.addingTimeInterval(241), reason: .appRecovered))
    }

    @Test func anOlderWatchAppsReportStillReads() throws {
        // before waiting seconds, the device id and counters were added
        let report = try #require(WatchWire.decode(WatchReport.self, Data(#"{"at":1791000300000,"state":"paused","waitingParts":1}"#.utf8)))
        #expect(report == WatchReport(state: .paused, since: nil, waitingParts: 1, at: Date(timeIntervalSince1970: 1_791_000_300)))
    }

    @Test func thePayloadKeysKeepTheirNames() {
        #expect([WatchWire.kind, WatchWire.manifest, WatchWire.acks, WatchWire.rejects, WatchWire.binding]
                == ["kind", "manifest", "acks", "rejects", "binding"])
        #expect([WatchWire.segment, WatchWire.end, WatchWire.report, WatchWire.perf] == ["segment", "end", "report", "perf"])
    }
}
