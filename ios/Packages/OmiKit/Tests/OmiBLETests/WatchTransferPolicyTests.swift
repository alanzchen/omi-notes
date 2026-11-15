import Foundation
import Testing
@testable import OmiWatchKit

/// Watch → iPhone transfer policy (watch-transfer-keepalive-20261109): new audio before re-checks, an
/// honest window, a sync ping only while recording, and acknowledgement latency for telemetry.
@Suite struct WatchTransferPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func askedAndAnsweredMissing(_ ids: [String]) -> WatchResendPolicy {
        var p = WatchResendPolicy()
        for id in ids {
            p.handedOver(id, now: t0)
            p.delivered(id, now: t0)
        }
        p.askInventory(id: "q", ids: ids, now: t0)
        _ = p.answeredInventory(id: "q", missing: ids, now: t0)
        return p
    }

    @Test func partsAnInventoryCalledMissingGoAfterNewAudio() {
        let p = askedAndAnsweredMissing(["old-1", "old-2"])
        #expect(p.recheckCount == 2 && p.isRecheck("old-1"))
        let order = p.sendOrder(["old-1", "new-1", "old-2", "new-2"], now: t0.addingTimeInterval(60)) { $0 }
        #expect(order == ["new-1", "new-2", "old-1", "old-2"])
    }

    @Test func newAudioCanNotStarveARecheck() {
        let p = askedAndAnsweredMissing(["old-1"])
        let later = t0.addingTimeInterval(WatchResendPolicy.recheckDefer + 1)
        #expect(p.sendOrder(["old-1", "new-1"], now: later) { $0 } == ["old-1", "new-1"], "waited long enough: recording order")
        #expect(p.isRecheck("old-1"), "still reported as a re-check (and still unacknowledged audio)")
    }

    @Test func aReceiptOrADroppedPartLeavesTheRecheckLane() {
        var p = askedAndAnsweredMissing(["old-1", "old-2", "old-3"])
        p.acknowledged(["old-1"])
        p.keep(only: ["old-2"])
        #expect(p.recheckCount == 1 && p.isRecheck("old-2") && !p.isRecheck("old-1"))
    }

    @Test func olderSavedStateWithoutTheLaneStillDecodes() throws {
        var p = WatchResendPolicy()
        p.handedOver("a", now: t0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "recheck")
        let back = try JSONDecoder().decode(WatchResendPolicy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.recheckCount == 0 && back.sendOrder(["a"], now: t0) { $0 } == ["a"])
    }

    @Test func onlyMovingTransfersCountAgainstTheWindowWithinABound() {
        // four queued transfers that never move no longer pin the window at zero
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 0, outstanding: 4) == 4)
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 4, outstanding: 4) == 0)
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 1, outstanding: 7) == 1, "at most twice the window outstanding")
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 0, outstanding: 9) == 0)
    }

    @Test func theSyncPingGoesWhilePartsWaitAndTheiPhoneIsReachableAtMostOncePerInterval() {
        #expect(WatchSyncPing.due(now: t0, last: nil, reachable: true, waitingParts: 3), "waiting parts, none delivered yet: still asks")
        #expect(!WatchSyncPing.due(now: t0, last: nil, reachable: false, waitingParts: 3))
        #expect(!WatchSyncPing.due(now: t0, last: nil, reachable: true, waitingParts: 0))
        #expect(!WatchSyncPing.due(now: t0.addingTimeInterval(30), last: t0, reachable: true, waitingParts: 3))
        #expect(WatchSyncPing.due(now: t0.addingTimeInterval(56), last: t0, reachable: true, waitingParts: 3))
    }

    @Test func aTransferWithoutProgressStopsHoldingASlotAndIsNeverDropped() {
        var stalls = WatchTransferStalls()
        typealias O = WatchTransferStalls.Observation
        let start = [O(id: "a", transferring: true, completedBytes: 0), O(id: "b", transferring: true, completedBytes: 0),
                     O(id: "c", transferring: false, completedBytes: 0)]
        #expect(stalls.observe(start, now: t0) == .init(moving: 2, stalled: 0, queued: 1))
        // "a" keeps moving, "b" reports transferring with no byte sent for longer than the stall time
        let later = t0.addingTimeInterval(WatchTransferStalls.stallAfter + 1)
        let next = [O(id: "a", transferring: true, completedBytes: 4096), O(id: "b", transferring: true, completedBytes: 0),
                    O(id: "c", transferring: false, completedBytes: 0)]
        #expect(stalls.observe(next, now: later) == .init(moving: 1, stalled: 1, queued: 1))
        // the window counts only "a"; everything outstanding (3) still counts against the bound
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 1, outstanding: 3) == 3)
        // progress again: moving again
        #expect(stalls.observe([O(id: "b", transferring: true, completedBytes: 10)], now: later.addingTimeInterval(1)) == .init(moving: 1))
    }

    @Test func aTransferStalledForHalfAnHourIsHandedBackToBeSentAgain() {
        // 2026-11-15: three Watch transfers reported "transferring" without a byte for four days; never cancelled,
        // they were never sent again. Stalled for `cancelAfter`, a transfer is overdue (the Watch cancels and resends
        // it; the part stays in its outbox until a receipt). Moving, queued or briefly stalled ones are not.
        var stalls = WatchTransferStalls()
        typealias O = WatchTransferStalls.Observation
        let stuck = O(id: "stuck", transferring: true, completedBytes: 512)
        let moving = { (bytes: Int64) in O(id: "moving", transferring: true, completedBytes: bytes) }
        let queued = O(id: "queued", transferring: false, completedBytes: 0)
        _ = stalls.observe([stuck, moving(0), queued], now: t0)
        _ = stalls.observe([stuck, moving(1), queued], now: t0.addingTimeInterval(WatchTransferStalls.stallAfter + 1))
        #expect(stalls.overdue(now: t0.addingTimeInterval(WatchTransferStalls.stallAfter + 1)).isEmpty, "stalled, not yet for long")
        let late = t0.addingTimeInterval(WatchTransferStalls.cancelAfter + 1)
        _ = stalls.observe([stuck, moving(2), queued], now: late)
        #expect(stalls.overdue(now: late) == ["stuck"])
        // gone (cancelled), then sent again: a new transfer starts its own clock
        _ = stalls.observe([moving(3), queued], now: late.addingTimeInterval(1))
        #expect(stalls.overdue(now: late.addingTimeInterval(1)).isEmpty)
        _ = stalls.observe([O(id: "stuck", transferring: true, completedBytes: 0)], now: late.addingTimeInterval(2))
        #expect(stalls.overdue(now: late.addingTimeInterval(2)).isEmpty)
    }

    @Test func aReplacementAttemptStartsItsOwnClockWithoutAGapBetweenObservations() {
        // ASTRA-20261115-IT1-02: keyed by part id, the replacement (seen at the very next pump, zero bytes) inherited
        // the cancelled attempt's 30 minutes and was cancelled again at once
        var stalls = WatchTransferStalls()
        typealias O = WatchTransferStalls.Observation
        _ = stalls.observe([O(id: "part-1#1", transferring: true, completedBytes: 0)], now: t0)
        let late = t0.addingTimeInterval(WatchTransferStalls.cancelAfter + 1)
        _ = stalls.observe([O(id: "part-1#1", transferring: true, completedBytes: 0)], now: late)
        #expect(stalls.overdue(now: late) == ["part-1#1"])
        _ = stalls.observe([O(id: "part-1#2", transferring: true, completedBytes: 0)], now: late.addingTimeInterval(1))
        #expect(stalls.overdue(now: late.addingTimeInterval(1)).isEmpty, "attempt 2 has its own clock")
    }

    @Test func aRelaunchKeepsAStalledAttemptsAgeAndAFutureClockWaitsAgain() {
        // ASTRA-20261115-IT1-04: each launch started an empty tracker, so a Watch app relaunched every 20 min never
        // reached 30 min of no progress
        typealias O = WatchTransferStalls.Observation
        var first = WatchTransferStalls()
        _ = first.observe([O(id: "part-1#1", transferring: true, completedBytes: 0)], now: t0)
        var later = WatchTransferStalls(restoring: first.saved, now: t0.addingTimeInterval(20 * 60))
        _ = later.observe([O(id: "part-1#1", transferring: true, completedBytes: 0)], now: t0.addingTimeInterval(20 * 60))
        var again = WatchTransferStalls(restoring: later.saved, now: t0.addingTimeInterval(40 * 60))
        _ = again.observe([O(id: "part-1#1", transferring: true, completedBytes: 0)], now: t0.addingTimeInterval(40 * 60))
        #expect(again.overdue(now: t0.addingTimeInterval(40 * 60)) == ["part-1#1"], "40 min since its last byte, across two launches")
        // saved by a clock ahead of this one: counted from now, never cancelled early
        var ahead = WatchTransferStalls()
        _ = ahead.observe([O(id: "part-2#3", transferring: true, completedBytes: 0)], now: t0.addingTimeInterval(3600))
        var restored = WatchTransferStalls(restoring: ahead.saved, now: t0)
        _ = restored.observe([O(id: "part-2#3", transferring: true, completedBytes: 0)], now: t0.addingTimeInterval(WatchTransferStalls.cancelAfter - 60))
        #expect(restored.overdue(now: t0.addingTimeInterval(WatchTransferStalls.cancelAfter - 60)).isEmpty)
        #expect(WatchTransferStalls(restoring: Data("not json".utf8), now: t0).saved != nil, "unreadable: a new tracker")
    }

    @Test func callbackWorkIsIdleOnlyWhenEveryQueuedCallbackFinished() {
        let work = WatchCallbackWork()
        #expect(work.isIdle)
        work.begin(); work.begin(); work.end()
        #expect(!work.isIdle)
        work.end()
        #expect(work.isIdle)
    }

    @Test func theSyncPingCarriesChecksummedItemsAndNoQuestion() {
        let m = WatchWire.syncPing(items: [WatchInventoryItem(id: "r-1", sha256: "ab")], binding: "phone")
        #expect(m[WatchWire.kind] as? String == WatchWire.sync && m[WatchWire.inventoryId] == nil)
        #expect(WatchWire.inventoryItems(from: m[WatchWire.inventoryItems]) == [WatchInventoryItem(id: "r-1", sha256: "ab")])
    }

    @Test func ackLatencyKeepsTheRecentValues() {
        var l = WatchAckLatency(capacity: 3)
        #expect(l.quantile(0.5) == nil)
        for s in [100.0, 2, 4, 6] { l.add(s) }
        #expect(l.values == [2, 4, 6] && l.quantile(0.5) == 4 && l.quantile(0.9) == 6)
    }

    @Test func theReportNamesRecheckedPartsApart() {
        let r = WatchReport(state: .idle, since: nil, waitingParts: 10, waitingSeconds: 600, at: t0, stats: ["recheck_parts": 7, "recheck_s": 420])
        #expect(r.recheckParts == 7 && r.recheckSeconds == 420)
        #expect(WatchReport(state: .idle, since: nil, waitingParts: 1, at: t0).recheckParts == 0)
    }
}
