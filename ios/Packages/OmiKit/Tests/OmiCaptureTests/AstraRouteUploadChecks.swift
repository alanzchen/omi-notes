import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

/// Astra's IT2 probes (omi-notes-reviews/nightly-2026-11-22-it2/swift), adopted; the one "observation" (IT2-02: the old
/// route's backoff survived a relaunch before the queued reset) now asserts the required outcome; the controls are unchanged.
@Suite(.serialized) struct AstraRouteUploadChecks {
    @Test func aRelaunchBeforeTheQueuedResetStillClearsTheOldRoutesBackoff() throws {
        let old = UploaderHarness()
        let item = try old.writeChunk(seq: 0)
        old.sync {
            old.uploader.state.update(item.name) {
                $0.attempts = 12
                $0.nextAttemptAt = old.now.addingTimeInterval(1800)
            }
        }
        old.reconcile()
        let oldTask = try #require(old.task(for: item.name))
        let fresh = UploaderHarness(reusing: old)
        fresh.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: URL(string: "https://new.example")!, token: "same"), generation: 2)
        fresh.transport.preexisting(oldTask.description)
        fresh.reconcile()
        let newTask = try #require(fresh.task(for: item.name))
        #expect(newTask.request.url?.host == "new.example")
        #expect(newTask.earliest == nil, "(adapted) the old route's backoff is cleared once for the new generation, even after a relaunch")
        #expect(fresh.t.outbox.pending().map(\.name) == [item.name])
        fresh.sync { fresh.uploader.serverConfigurationChanged() }
        #expect(fresh.task(for: item.name)?.earliest == nil, "control: receiving the change callback clears it")
    }

    @Test func control_manyFilesStayInsideWindowAndReconcileDoesNotDuplicate() throws {
        let h = UploaderHarness()
        for i in 0..<405 { _ = try h.writeChunk(seq: i) }
        h.reconcile()
        #expect(h.transport.active.count == 400)
        h.sync { h.uploader.serverConfigurationChanged() }
        let generationTasks = h.transport.active.count
        #expect(generationTasks == 400)
        for _ in 0..<10 { h.reconcile() }
        #expect(h.transport.active.count == generationTasks)
        #expect(h.t.outbox.pending().count == 405)
    }

    @Test func control_lateOldHostSuccessCannotAcknowledgeAfterRelaunch() throws {
        let old = UploaderHarness()
        let item = try old.writeChunk(seq: 0)
        old.reconcile()
        let oldID = try #require(old.task(for: item.name)).description
        let fresh = UploaderHarness(reusing: old)
        fresh.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: URL(string: "https://new.example")!, token: "same"), generation: 2)
        fresh.reconcile()
        fresh.sync { fresh.uploader.handleCompletion(identifier: oldID, statusCode: 201, body: nil, error: nil) }
        #expect(fresh.t.outbox.pending().map(\.name) == [item.name])
        #expect(fresh.t.outbox.sent().isEmpty)
        #expect(fresh.uploader.status.lastSuccessAt == nil)
        fresh.complete(item.name, status: 200)
        #expect(fresh.t.outbox.pending().isEmpty)
        #expect(fresh.t.outbox.sent().map(\.name) == [item.name])
    }
}
