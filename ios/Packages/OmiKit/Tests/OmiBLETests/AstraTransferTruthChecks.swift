import Foundation
import Testing
@testable import OmiBLE
import OmiCapture

@Suite struct AstraTransferTruthChecks {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let second: UInt64 = 1_000_000_000
    func transmitting() -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ready = true; s.serverConfigured = true
        s.outbox.pendingCount = 2; s.outbox.pendingChunks = 2; s.outbox.pendingBytes = 10_000
        s.transfer.meter.start(atMono: 0, wall: now)
        s.transfer.meter.began(id: "1.1|chunk_test_000000.omnc", audio: true, expected: 2_000)
        s.transfer.meter.progress(id: "1.1|chunk_test_000000.omnc", audio: true, sent: 1_000, expected: 2_000, atMono: 2 * second)
        return s
    }
    func summary(_ s: EngineSnapshot, mono: UInt64 = 2_000_000_000) -> TransferSummary {
        TransferSummary.evaluate(snapshot: s, server: .unreachable("synthetic status timeout"), status: nil, statusAt: now,
                                 watchInstalled: false, nowMono: mono, now: now)
    }
    @Test func outboundProgressWithoutAnACKDoesNotProveServerReachability() {
        let s = transmitting()
        let t = summary(s)
        #expect(t.phone.state == .sending, "transport bytes really moved: sending label itself is appropriate")
        #expect(t.phone.deliveredAudioBytes == 0 && t.phone.deliveredAudioFiles == 0)
        #expect(t.problemLine(now: now) != nil,
                "no server ACK exists; outbound body progress alone must not erase the status failure")
        #expect(summary(s, mono: 6 * second).problemLine(now: now) == "连不上服务器",
                "control: when rate expires, the same server failure reappears")
    }
    @Test func switchingConfigurationCannotCarryTheOldRateOrACKTotals() {
        var s = transmitting()
        s.transfer.meter.finished(id: "1.1|chunk_test_000000.omnc", audio: true, bytes: 2_000, outcome: .delivered, atMono: 2 * second)
        // Production snapshot/configureServer uses exactly this retain step; no meter.start/reset occurs on Save.
        s.transfer.meter.retain(key: "2.1")
        let t = summary(s)
        #expect(t.phone.inFlightUploads == 0, "control: old task identity was removed")
        #expect(t.phone.rate == nil && t.phone.deliveredAudioBytes == 0,
                "the new address must not inherit old-address progress or completed-byte evidence")
        #expect(t.phone.state != .sending && t.problemLine(now: now) != nil,
                "new address has no task/progress/ACK; status failure must not disappear")
    }
    @Test func aPhoneOnlyETAIsScopedWhenTheWatchReportIsStale() throws {
        var t = try #require(TransferSummary.debugFixture("watch-stale", now: now))
        t.server.reachable = true
        #expect(!t.watch.reportFresh && t.watch.waitingParts != nil)
        #expect(t.watchLine(now: now) == "等待手表报告")
        let line = try #require(t.cardLine(now: now))
        #expect(line.attention || line.text.contains("iPhone"),
                "unknown Watch backlog cannot become an unqualified all-transfer completion estimate: \(line.text)")
    }
}
