import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture

/// Settings → Server showed the last answer's "Needs attention", "Now" and "Running / Failed 0" as current.
extension RetryFlowTests {
@MainActor @Suite(.serialized) struct ServerAnswerCurrencyTests {
    @Test func anAnswerIsCurrentOnlyWhileTheLatestRequestWorkedAndIsRecent() async throws {
        let (m, root) = try RetryFlowTests().model()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!m.serverAnswerIsCurrent(now: Date()), "no answer yet")
        await m.refreshServer()
        let at = try #require(m.serverStatusAt)
        #expect(m.serverAnswerIsCurrent(now: at))
        #expect(!m.serverAnswerIsCurrent(now: at.addingTimeInterval(SystemHealth.staleAfter + 1)), "an old answer")
        AppServerStub.offline = true
        await m.refreshServer()
        #expect(!m.serverAnswerIsCurrent(now: at), "the latest request failed")
    }
}
}
