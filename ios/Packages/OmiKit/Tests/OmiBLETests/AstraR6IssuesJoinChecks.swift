import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraR6IssuesJoinChecks {
        @Test func aFinishedIssuesFailureDoesNotWaitForTheRecentPage() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[{"code":"worker_absent","severity":"action","message":"The processing worker is not running"}]}"#)]
            await m.refreshServer()
            #expect(m.issues.count == 1 && m.issuesAreCurrent())
            AppServerStub.holdNext = ["/v1/issues", "/v1/conversations/recent"]
            let refresh = Task { await m.refreshServer() }
            try await AppServerStub.waitUntilHeld("/v1/issues")
            try await AppServerStub.waitUntilHeld("/v1/conversations/recent")
            AppServerStub.release("/v1/issues", offline: true)
            // Deliver the URLSession failure while the unrelated page is deliberately still pending.
            try await Task.sleep(for: .milliseconds(50))
            let currentAfterIssuesFailed = m.issuesAreCurrent()
            #expect(m.serverAnswerIsCurrent())
            AppServerStub.release("/v1/conversations/recent", offline: false)
            await refresh.value
            #expect(!currentAfterIssuesFailed, "a completed /issues failure must mark old issues last-known immediately, not after /recent answers")
            #expect(!m.issuesAreCurrent())
        }
    }
}
