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
        _ = p.answeredInventory(id: "q", missing: ids)
        return p
    }

    @Test func partsAnInventoryCalledMissingGoAfterNewAudio() {
        let p = askedAndAnsweredMissing(["old-1", "old-2"])
        #expect(p.recheckCount == 2 && p.isRecheck("old-1"))
        let order = p.sendOrder(["old-1", "new-1", "old-2", "new-2"]) { $0 }
        #expect(order == ["new-1", "new-2", "old-1", "old-2"])
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
        #expect(back.recheckCount == 0 && back.sendOrder(["a"]) { $0 } == ["a"])
    }

    @Test func onlyMovingTransfersCountAgainstTheWindowWithinABound() {
        // four queued transfers that never move no longer pin the window at zero
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 0, outstanding: 4) == 4)
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 4, outstanding: 4) == 0)
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 1, outstanding: 7) == 1, "at most twice the window outstanding")
        #expect(WatchTransferWindow.room(maxInFlight: 4, transferring: 0, outstanding: 9) == 0)
    }

    @Test func theSyncPingGoesOnlyWhileRecordingReachableAndWaitingAtMostOncePerInterval() {
        #expect(WatchSyncPing.due(now: t0, last: nil, recording: true, reachable: true, unacknowledged: 3))
        #expect(!WatchSyncPing.due(now: t0, last: nil, recording: false, reachable: true, unacknowledged: 3))
        #expect(!WatchSyncPing.due(now: t0, last: nil, recording: true, reachable: false, unacknowledged: 3))
        #expect(!WatchSyncPing.due(now: t0, last: nil, recording: true, reachable: true, unacknowledged: 0))
        #expect(!WatchSyncPing.due(now: t0.addingTimeInterval(30), last: t0, recording: true, reachable: true, unacknowledged: 3))
        #expect(WatchSyncPing.due(now: t0.addingTimeInterval(56), last: t0, recording: true, reachable: true, unacknowledged: 3))
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
