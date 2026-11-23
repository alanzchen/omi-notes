import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite(.serialized) struct AstraLegacyBackoffChecks {
    @Test func aLegacyBackoffMustNotFollowTheFirstObservedNewAddress() throws {
        // A build62 state file has records/epoch but no backoffGeneration. Do not
        // reconcile this object on new code: that would upgrade it before the race.
        let legacy = UploaderHarness()
        let item = try legacy.writeChunk(seq: 0)
        legacy.sync {
            legacy.uploader.state.update(item.name) {
                $0.attempts = 12
                $0.nextAttemptAt = legacy.now.addingTimeInterval(1800)
            }
        }
        #expect(legacy.uploader.state.backoffGeneration == nil)
        // New address persisted; termination before queued serverConfigurationChanged.
        let fresh = UploaderHarness(reusing: legacy)
        fresh.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: URL(string: "https://new.example")!, token: "same"), generation: 2)
        fresh.reconcile()
        let task = try #require(fresh.task(for: item.name))
        #expect(task.request.url?.host == "new.example")
        #expect(task.earliest == nil, "Legacy old-host delay must not follow a new address on first observed generation")
        #expect(fresh.t.outbox.pending().map(\.name) == [item.name])
        #expect(fresh.t.outbox.sent().isEmpty)
    }
}
