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

    /// The coordinator's acceptance gate for 0.1.0 (15): once the listing stops counting a task that
    /// was never delivered, the uploader must let go of the file too (at its next reconcile).
    @Test func expiredUndeliveredOwnershipActuallyRetriesInUploader() throws {
        let h = UploaderHarness()
        h.transport.systemListing = UploadTaskOwnership()
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        let task = try #require(h.task(for: a.name))
        task.done = true
        relaunch(h)
        h.reconcile()
        #expect(h.started.filter { $0.name == a.name }.count == 1)
        #expect(h.uploader.status.inFlight == 1)
        h.transport.now = h.transport.now.addingTimeInterval(121)
        h.now = h.now.addingTimeInterval(121)
        h.reconcile()
        #expect(h.started.filter { $0.name == a.name }.count == 2, "expired undelivered ownership must release Uploader.started and retry without a user tap or another relaunch")

        // the old task's 201 arrives after all: it acknowledges, and the retry's answer is ignored
        h.complete(task: task, status: 201)
        #expect(h.t.outbox.pendingItem(named: a.name) == nil)
        let retry = try #require(h.transport.active.last { $0.name == a.name })
        h.complete(task: retry, status: 200)
        #expect(h.started.filter { $0.name == a.name }.count == 2 && h.uploader.status.inFlight == 0)
    }

    /// A task this uploader just started may be missing from a listing taken before it began; it is
    /// still never started twice.
    @Test func aTaskStartedHereIsNotRestartedByAListingThatDoesNotShowItYet() throws {
        let h = UploaderHarness()
        h.transport.systemListing = UploadTaskOwnership()
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        let task = try #require(h.task(for: a.name))
        h.transport.unlisted.insert(task.id)    // not visible to getAllTasks yet
        h.transport.now += 3600
        h.reconcile()
        #expect(h.started.filter { $0.name == a.name }.count == 1 && h.uploader.status.inFlight == 1)
        h.complete(task: task, status: nil, error: URLError(.networkConnectionLost))  // its response was lost
        #expect(h.started.filter { $0.name == a.name }.count == 2, "a lost response still retries")
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
