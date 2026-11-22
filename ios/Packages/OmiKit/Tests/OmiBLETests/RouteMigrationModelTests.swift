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

extension RetryFlowTests {
    /// The Change-server test says whether the new address answers as the server connected now (same vault).
    @MainActor @Suite(.serialized) struct ConnectionCheckTests {
        @Test func theTestSaysWhetherTheNewAddressIsTheSameServer() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()  // the connected server's vault: vault-a
            let new = URL(string: "https://oracle.tailcd4f.ts.net:8446")!
            let same = await m.checkConnection(url: new, token: "tok")
            #expect(same.ok && same.sameServer == true)
            #expect(same.message.hasSuffix("Same server as now."))
            AppServerStub.routes["/v1/status"] = [(200, RetryFlowTests.status.replacingOccurrences(of: "vault-a", with: "vault-b"))]
            let other = await m.checkConnection(url: new, token: "tok")
            #expect(other.ok && other.sameServer == false)
            #expect(other.message.hasSuffix("A different server from the one connected now."))
            AppServerStub.routes["/v1/status"] = [(401, #"{"error":"unauthorized"}"#)]
            let refused = await m.checkConnection(url: new, token: "bad")
            #expect(!refused.ok && refused.sameServer == nil)
            AppServerStub.offline = true
            let down = await m.checkConnection(url: new, token: "tok")
            #expect(!down.ok && down.sameServer == nil && down.message.hasPrefix("Couldn't connect"))
        }

        /// Nothing connected yet (or the connected server never answered): no same/different claim.
        @Test func noClaimWithoutAKnownServer() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            let r = await m.checkConnection(url: URL(string: "https://oracle.tailcd4f.ts.net:8446")!, token: "tok")
            #expect(r.ok && r.sameServer == nil)
            #expect(!r.message.contains("server as now") && !r.message.contains("different server"))
        }
    }
}

extension RetryFlowTests {
    /// R2 2026-11-22: moving the same server (proven by a passing same-vault test) keeps the notes saved for offline
    /// reading, so a new address that doesn't answer yet still shows them. Anything unproven clears them as before.
    @MainActor @Suite(.serialized) struct OfflineNotesMoveTests {
        static let new = URL(string: "https://oracle.tailcd4f.ts.net:8446")!

        func savedRow(_ m: AppModel) throws {
            let scope = try #require(m.cacheScope(m.engine.settings.serverConfig()))
            m.noteCache.saveRecent([ConversationSummary(id: "conv-saved", status: "done", startedAt: "2026-11-19T15:00:00.000Z", title: "Saved")], scope: scope)
        }

        @Test func aProvenSameServerMoveKeepsTheSavedNotes() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            try savedRow(m)
            let check = await m.checkConnection(url: Self.new, token: "tok")
            #expect(check.sameServer == true)
            AppServerStub.offline = true  // the new address stops answering right after the test
            try m.saveServer(url: Self.new, token: "tok")
            await m.saveRefresh?.value
            #expect(m.recent.map(\.id) == ["conv-saved"], "the same vault's saved notes still show at the new address")
            #expect(m.currentVaultId == "vault-a")
            #expect(m.noteCache.lastScope?.serverURL == Self.new.absoluteString)
        }

        @Test func anUnprovenMoveClearsThemAsBefore() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            try savedRow(m)
            AppServerStub.offline = true
            try m.saveServer(url: Self.new, token: "tok")  // no test
            await m.saveRefresh?.value
            #expect(m.recent.isEmpty)
            #expect(m.noteCache.lastScope == nil)
        }

        @Test func aTestOfAnotherAddressProvesNothingForThisOne() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            try savedRow(m)
            _ = await m.checkConnection(url: URL(string: "https://other.tailcd4f.ts.net:8446")!, token: "tok")
            AppServerStub.offline = true
            try m.saveServer(url: Self.new, token: "tok")
            await m.saveRefresh?.value
            #expect(m.recent.isEmpty && m.noteCache.lastScope == nil)
        }

        @Test func aDifferentServerClearsThem() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            try savedRow(m)
            AppServerStub.routes["/v1/status"] = [(200, RetryFlowTests.status.replacingOccurrences(of: "vault-a", with: "vault-b"))]
            let check = await m.checkConnection(url: Self.new, token: "tok")
            #expect(check.sameServer == false)
            AppServerStub.offline = true
            try m.saveServer(url: Self.new, token: "tok")
            await m.saveRefresh?.value
            #expect(m.recent.isEmpty && m.noteCache.lastScope == nil, "never one vault's notes under another")
        }

        /// Proven at test time, but the new address then answers with another vault: vault-a's notes go.
        @Test func aVaultThatChangesAfterTheTestStillClearsThem() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            try savedRow(m)
            _ = await m.checkConnection(url: Self.new, token: "tok")
            AppServerStub.routes["/v1/status"] = [(200, RetryFlowTests.status.replacingOccurrences(of: "vault-a", with: "vault-b"))]
            try m.saveServer(url: Self.new, token: "tok")
            await m.saveRefresh?.value
            #expect(!m.recent.contains { $0.id == "conv-saved" })
            #expect(m.noteCache.lastScope?.vaultId != "vault-a")
            let scope = NoteCache.Scope(serverURL: Self.new.absoluteString, generation: m.engine.settings.serverConfig().generation, vaultId: "vault-a")
            #expect(m.noteCache.recent(scope: scope) == nil, "vault-a's copies are gone, not hidden")
        }
    }
}
