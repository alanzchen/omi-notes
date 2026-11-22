import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    /// 2026-11-22: the same server (same token, same vault) at a new address. Decisions the owner made while the old
    /// address couldn't be reached (a retry, a keep, a priority) are saved on the phone before sending; they belong
    /// to the vault, so they must reach the new address too, with their original request ids.
    @MainActor @Suite(.serialized) struct RouteMigrationModelTests {
        static let status = #"{"ok":true,"vault_id":"vault-a","features":["issues","retry","keep","value_notes","search","conversation_detail"],"queue":{"failed":1},"worker":{"present":true}}"#

        @Test func decisionsSavedForTheOldAddressReachTheSameVaultAtTheNewOne() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/status"] = [(200, Self.status)]
            AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(202, RetryFlowTests.opJSON("op-1", "queued"))]
            AppServerStub.routes["/v1/conversations/conv-2/priority"] = [(200, #"{"state":"important","revision":2,"set_at":"2026-11-20T10:00:00.000Z"}"#)]
            let old = try #require(m.engine.settings.serverURL)
            let oldKey = RetryStore.serverKey(baseURL: old, vaultId: "vault-a")
            // saved while the old address was unreachable: never sent
            let retry = try m.retryStore.begin(conversationId: "conv-1", server: oldKey)
            let choice = try m.priorityStore.choose("conv-2", state: "important", server: oldKey)

            try m.engine.configureServer(url: URL(string: "https://oracle.tailcd4f.ts.net:8446")!, token: "tok")
            await m.refreshServer()

            let retried = AppServerStub.requests.filter { $0.path == "/v1/conversations/conv-1/retry" }
                .compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
            #expect(retried.map { $0["request_id"] as? String } == [retry.requestId], "the saved retry goes to the new address, once, with its id")
            let prioritized = AppServerStub.requests.filter { $0.path == "/v1/conversations/conv-2/priority" }
                .compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
            #expect(prioritized.map { $0["request_id"] as? String } == [choice.requestId], "the saved priority choice too")
            #expect(m.priorityStore.pending("conv-2", server: oldKey) == nil)
        }

        /// Another vault behind the new address: nothing saved for vault-a is sent to it.
        @Test func decisionsForOneVaultNeverGoToAnother() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/status"] = [(200, Self.status.replacingOccurrences(of: "vault-a", with: "vault-b"))]
            AppServerStub.routes["/v1/conversations/conv-1/retry"] = [(202, RetryFlowTests.opJSON("op-1", "queued"))]
            let old = try #require(m.engine.settings.serverURL)
            let oldKey = RetryStore.serverKey(baseURL: old, vaultId: "vault-a")
            _ = try m.retryStore.begin(conversationId: "conv-1", server: oldKey)
            try m.engine.configureServer(url: URL(string: "https://elsewhere.example:8446")!, token: "tok")
            await m.refreshServer()
            #expect(AppServerStub.requests.filter { $0.path == "/v1/conversations/conv-1/retry" }.isEmpty)
            #expect(m.retryStore.entry(conversationId: "conv-1", server: oldKey) != nil, "kept for its own vault, not deleted")
        }
    }
}
