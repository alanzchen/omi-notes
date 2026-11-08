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
            snap.transfer.meter.progress(id: "a", audio: true, sent: 0, expected: 1_000, atMono: at - s)
            snap.transfer.meter.progress(id: "a", audio: true, sent: 500, expected: 1_000, atMono: at)
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

    // UX-LT-ASTRA-05/07 (astra-review/EngineHarness.swift)

    @Test func retainedWorkIsNeverAllSent() {
        var kept = snapshot(pending: 0)
        kept.outbox.quarantineCount = 1
        #expect(state(kept, at: 5 * s) == .keptAside(1))
        var preparing = snapshot(pending: 0)
        preparing.watchPending = 2
        #expect(state(preparing, at: 5 * s) == .preparing(2))
        var unreadable = snapshot(pending: 0)
        unreadable.outbox.inventoryReadable = false
        #expect(state(unreadable, at: 5 * s) == .queueUnreadable, "a queue that couldn't be read isn't empty")
    }

    @Test func anUnknownWatchInstallIsNotNotInUse() {
        let w = TransferSummary.evaluate(snapshot: snapshot(), server: reachable(), status: nil, statusAt: nil, watchInstalled: nil, nowMono: s, now: now).watch
        #expect(w.inUse == nil)
        let no = TransferSummary.evaluate(snapshot: snapshot(), server: reachable(), status: nil, statusAt: nil, watchInstalled: false, nowMono: s, now: now).watch
        #expect(no.inUse == false)
    }

    @Test func theReceiptTimeIsAReceiptNotAConversion() {
        var snap = snapshot()
        snap.watchReceived = 3
        snap.watchLastReceivedAt = now  // a conversion marker written now (after a relaunch)
        let w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(w.lastReceivedAt == nil, "no receipt in this run: unknown, not the marker's time")
    }

    @Test func ratesReadInTheirUnits() {
        #expect(TransferSummary.rateText(820) == "820 B/s")
        #expect(TransferSummary.rateText(48_200) == "48.2 KB/s")
        #expect(TransferSummary.rateText(1_300_000) == "1.3 MB/s")
    }

    // OMI-THROUGHPUT-UI-20261108: the redesigned screen's hero and bars

    @Test func timeLeftOnlyWhileBytesMove() throws {
        let backlog = try #require(TransferSummary.debugFixture("backlog", now: now))
        let left = try #require(backlog.phoneTimeLeft)
        #expect(abs(left / 3600 - 13.4) < 0.1, "5.39 GB at 111.7 KB/s is about 13.4 h")
        let waiting = try #require(TransferSummary.debugFixture("waiting", now: now))
        #expect(waiting.phoneTimeLeft == nil, "no speed, no estimate")
    }

    @Test func barsCoverOnlyWhatIsKnown() throws {
        let backlog = try #require(TransferSummary.debugFixture("backlog", now: now))
        let f = try #require(backlog.phoneFraction)
        #expect(abs(f - 46.6 / (46.6 + 5_390)) < 0.0001)
        #expect(try #require(TransferSummary.debugFixture("all-sent", now: now)).phoneFraction == 1)
        let watch = try #require(backlog.watchFraction)
        #expect(abs(watch - 266.0 / 270) < 0.0001, "received parts of received plus still on the Watch")
        #expect(try #require(TransferSummary.debugFixture("unknown-watch", now: now)).watchFraction == nil)
        var notCounting = backlog
        notCounting.phone.since = nil
        #expect(notCounting.phoneFraction == nil, "in the background nothing is counted, so no bar")
    }

    // ASTRA-IT1-05/06: nothing on Transfers may claim completion it can't know.

    @Test func aStaleOrFutureWatchReportIsNoCompletion() throws {
        for age: TimeInterval in [-86_400, 86_400] {
            var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
            t.watch.reportAt = now.addingTimeInterval(age)
            t.watch.reportFresh = false
            #expect(t.watchFraction == nil, "no 100% from a report of yesterday or tomorrow")
            #expect(!t.everythingSent, "and no \"All sent\" either")
        }
    }

    @Test func allSentNeedsTheWatchToo() throws {
        var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
        #expect(t.everythingSent, "phone empty, fresh Watch report with nothing waiting")
        t.watch.waitingParts = 3
        #expect(!t.everythingSent, "the Watch still has parts")
        t.watch.waitingParts = nil
        #expect(!t.everythingSent, "unknown is not nothing")
        t.watch.inUse = false
        #expect(t.everythingSent, "no Watch in use: the iPhone is everything")
    }

    @Test func theServerHasWorkWhileConversationsAreQueued() throws {
        var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
        t.server.chunksPending = 0
        t.server.conversationsPending = 3
        #expect(t.serverWorkLeft == 3)
        t.server.conversationsPending = 0
        #expect(t.serverWorkLeft == 0)
        t.server.chunksPending = nil
        t.server.conversationsPending = nil
        #expect(t.serverWorkLeft == nil, "unknown when the server didn't say")
    }

    /// ASTRA-IT3-03: one count present as 0 and the other absent became "nothing to process".
    /// Done only when both are explicitly 0; a known count above 0 is an "at least".
    @Test func aMissingServerCountIsNeverZero() throws {
        var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
        t.server.chunksPending = 0; t.server.conversationsPending = nil
        #expect(t.serverWorkLeft == nil && t.serverWork == nil)
        t.server.chunksPending = nil; t.server.conversationsPending = 0
        #expect(t.serverWorkLeft == nil && t.serverWork == nil)
        t.server.chunksPending = 4; t.server.conversationsPending = nil
        #expect(t.serverWork?.left == 4 && t.serverWork?.atLeast == true && t.serverWorkLeft == nil)
        t.server.chunksPending = 0; t.server.conversationsPending = 0
        #expect(t.serverWork?.left == 0 && t.serverWork?.atLeast == false && t.serverWorkLeft == 0)
    }
}
