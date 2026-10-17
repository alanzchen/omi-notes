import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiWatchKit

/// Each transfer stage says only what its source knows, as of its time; "sending" needs bytes that
/// actually moved, and a Watch report is fresh only within the Watch's own window.
@Suite struct TransferSummaryTests {
    let s: UInt64 = 1_000_000_000
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func reachable() -> ServerReachability { .reachable(version: "0.1.0", detail: "") }

    func snapshot(pending: Int = 0, counting: Bool = true, bytesAt: UInt64? = nil) -> EngineSnapshot {
        var snap = EngineSnapshot()
        snap.ready = true
        snap.serverConfigured = true
        snap.outbox.pendingCount = pending
        if counting { snap.transfer.meter.start(atMono: 0, wall: now) }
        if let at = bytesAt {
            snap.transfer.meter.progress(name: "a", audio: true, sent: 0, expected: 1_000, atMono: at - s)
            snap.transfer.meter.progress(name: "a", audio: true, sent: 500, expected: 1_000, atMono: at)
        }
        return snap
    }

    func state(_ snap: EngineSnapshot, _ server: ServerReachability? = nil, at mono: UInt64) -> TransferSummary.UploadState {
        TransferSummary.evaluate(snapshot: snap, server: server ?? reachable(), status: nil, statusAt: nil, watchInstalled: nil, nowMono: mono, now: now).phone.state
    }

    @Test func sendingOnlyWhileBytesAreActuallyMoving() {
        let snap = snapshot(pending: 3, bytesAt: 5 * s)
        #expect(state(snap, at: 5 * s) == .sending)
        #expect(state(snap, at: 20 * s) == .waiting, "bytes stopped: waiting, not still 'sending'")
        let summary = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: nil, nowMono: 20 * s, now: now)
        #expect(summary.phone.rate == nil)
    }

    @Test func theOtherStatesFollowWhatIsKnown() {
        #expect(state(snapshot(pending: 0), at: 5 * s) == .allSent)
        #expect(state(snapshot(pending: 4), .unreachable("timed out"), at: 5 * s) == .offline("timed out"))
        var backoff = snapshot(pending: 4)
        backoff.upload.backingOff = 2
        #expect(state(backoff, at: 5 * s) == .retrying)
        var paused = snapshot(pending: 4)
        paused.upload.pausedReason = "storage"
        #expect(state(paused, at: 5 * s) == .paused("storage"))
        #expect(state(snapshot(pending: 4, counting: false), at: 5 * s) == .unknown, "not counting: nothing is live")
        var none = snapshot()
        none.serverConfigured = false
        #expect(state(none, at: 5 * s) == .notConfigured)
    }

    @Test func aWatchReportIsFreshOnlyWithinTheWatchsWindow() {
        var snap = snapshot()
        snap.watchReport = WatchReport(state: .recording, since: nil, waitingParts: 4, waitingSeconds: 230, at: now.addingTimeInterval(-60))
        var w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(w.reportFresh && w.waitingSeconds == 230 && w.waitingParts == 4)
        snap.watchReport?.at = now.addingTimeInterval(-3600)
        w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(!w.reportFresh, "an hour-old report is what the Watch had then")
        snap.watchReport?.at = now.addingTimeInterval(3600)
        w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(!w.reportFresh, "a report from the future isn't current either")
    }

    @Test func ratesReadInTheirUnits() {
        #expect(TransferSummary.rateText(820) == "820 B/s")
        #expect(TransferSummary.rateText(48_200) == "48.2 KB/s")
        #expect(TransferSummary.rateText(1_300_000) == "1.3 MB/s")
    }
}
