import Foundation
import Testing
@testable import OmiBLE
import OmiProtocol

@Suite struct AstraR6FreshnessSurfaceChecks {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func liveActivityDoesNotRenewAnOldOrFutureServerCount() throws {
        for age in [-3600.0, 3600.0] {
            var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
            t.server.checkedAt = now.addingTimeInterval(-age)
            t.server.conversationsPending = 7
            #expect(t.serverLine(now: now) == nil)
            let card = SyncActivityState(t, now: now)
            #expect(card.detail != "Your server is processing 7",
                "a newly updated card must not renew a stale/future server queue count")
            #expect(card.serverPending == nil,
                "unknown server count must not be republished with this card's new asOf time")
        }
    }

    @Test func liveActivityKeepsACurrentServerCount() throws {
        var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
        t.server.checkedAt = now
        t.server.conversationsPending = 7
        let card = SyncActivityState(t, now: now)
        #expect(card.detail == "Your server is processing 7")
        #expect(card.serverPending == 7)
    }
}
