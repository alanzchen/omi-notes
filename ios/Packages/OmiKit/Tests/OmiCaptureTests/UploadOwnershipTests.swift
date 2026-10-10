import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

/// A background session relaunched for a task that finished while the app wasn't running lists it
/// as completed before delivering its completion (seen on the iOS Simulator with a real session:
/// `build/deployment/upload-ack-repair/`). Until then the file is still that task's.
@Suite struct UploadOwnershipTests {
    func relaunch(_ h: UploaderHarness) {
        h.uploader = Uploader(
            outbox: h.t.outbox, state: UploadStateStore(url: h.t.dirs.state.appendingPathComponent("upload-state.json")),
            transport: h.transport, queue: h.queue, config: { [unowned h] in h.cfg })
        h.uploader.now = { [unowned h] in h.now }
        h.uploader.random = { 0.5 }
    }

    @Test func aChunkTheServerStoredIsNotSentAgainAfterARelaunchAndDeliveryFreesItsRetry() throws {
        let h = UploaderHarness()
        h.transport.systemListing = UploadTaskOwnership()
        let a = try h.writeChunk(seq: 0)
        let b = try h.writeChunk(seq: 1)
        h.reconcile()
        let ta = try #require(h.task(for: a.name)), tb = try #require(h.task(for: b.name))
        ta.done = true; tb.done = true          // both finished in the system; the app was gone before delivery
        relaunch(h)
        h.reconcile()                           // launch reconcile runs before the queued completions
        #expect(h.started.filter { $0.name == a.name }.count == 1, "no second PUT of a stored chunk")
        #expect(h.started.filter { $0.name == b.name }.count == 1)

        h.complete(task: ta, status: 201)       // the late 201 acknowledges
        h.transport.unlisted.insert(ta.id)
        #expect(h.t.outbox.pendingItem(named: a.name) == nil)

        // b's response was lost: once delivered, a retry is scheduled with backoff, even while a
        // stale listing still shows the finished task
        h.complete(task: tb, status: nil, error: URLError(.networkConnectionLost))
        let retry = h.started.filter { $0.name == b.name }
        #expect(retry.count == 2 && (retry.last?.earliest ?? .distantPast) > h.now, "retried, after the backoff")
    }

    @Test func listedTasksOwnTheirFileUntilDeliveredOrForAtMostTheGrace() {
        var o = UploadTaskOwnership()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let listed = [UploadTaskOwnership.Listed(id: 1, description: "1.0|running", completed: false),
                      UploadTaskOwnership.Listed(id: 2, description: "1.0|finished", completed: true),
                      UploadTaskOwnership.Listed(id: 3, description: "1.0|delivered", completed: true)]
        o.delivered(3)
        #expect(o.owners(listed, now: t0) == ["1.0|running", "1.0|finished"])
        #expect(o.owners(listed, now: t0 + o.grace - 1) == ["1.0|running", "1.0|finished"])
        #expect(o.owners(listed, now: t0 + o.grace + 1) == ["1.0|running"], "never delivered: no longer blocks a retry")
    }
}
