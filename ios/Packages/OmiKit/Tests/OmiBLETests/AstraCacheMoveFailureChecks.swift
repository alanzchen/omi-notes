import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

// Astra's IT3-02 harness (omi-notes-reviews/nightly-2026-11-22-it3/swift), adapted: her two "observation" tests pinned the
// limitation (the interrupted move's notes were deleted); the same setups now assert the required outcome: the next
// adopt completes the interrupted move instead of deleting it, and a failed move says so.

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraCacheMoveFailureChecks {
        static let nextURL = URL(string:"https://new.example")!
        static var row: ConversationSummary {
            ConversationSummary(id:"saved",status:"done",startedAt:"2026-11-19T00:00:00.000Z",title:"Saved")
        }

        /// No production fault seam: make only the real scope-pointer file immutable. The sibling directory
        /// rename can complete; replacing the pointer cannot. These assertions pin the observed limitation.
        @Test func aPointerWriteFailureIsReportedAndTheMoveCompletedLater() throws {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("astra-cache-move-"+UUID().uuidString)
            let pointer=root.appendingPathComponent("scope.json")
            defer {
                try? FileManager.default.setAttributes([.immutable:false],ofItemAtPath:pointer.path)
                try? FileManager.default.removeItem(at:root)
            }
            let cache=NoteCache(root:root)
            let old=NoteCache.Scope(serverURL:"https://old.example",generation:1,vaultId:"vault-a")
            let next=NoteCache.Scope(serverURL:Self.nextURL.absoluteString,generation:2,vaultId:"vault-a")
            cache.saveRecent([Self.row],scope:old)
            try FileManager.default.setAttributes([.immutable:true],ofItemAtPath:pointer.path)
            #expect(!cache.move(to:next))
            #expect(cache.lastScope == old)
            #expect(cache.recent(scope:old) == nil)
            #expect(cache.recent(scope:next)?.value.map(\.id) == ["saved"])
            try FileManager.default.setAttributes([.immutable:false],ofItemAtPath:pointer.path)
            // (adapted) what adopt does next: the renamed copy is this exact scope's, so the move is completed
            #expect(cache.completeMove(to:next))
            #expect(cache.lastScope == next)
            #expect(cache.recent(scope:next)?.value.map(\.id) == ["saved"])
        }

        /// Models the exact on-disk interruption boundary between directory rename and pointer write.
        /// App config has already changed. First normal refresh must currently clear the renamed data.
        @Test func aRefreshAfterAnInterruptedMoveCompletesIt() async throws {
            let (m,root)=try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at:root) }
            await m.refreshServer()
            let old=try #require(m.cacheScope(m.engine.settings.serverConfig()))
            m.noteCache.saveRecent([Self.row],scope:old)
            try m.engine.configureServer(url:Self.nextURL,token:"tok")
            let next=NoteCache.Scope(serverURL:Self.nextURL.absoluteString,generation:m.engine.settings.serverConfig().generation,vaultId:"vault-a")
            let cacheRoot=root.appendingPathComponent("cache")
            try FileManager.default.moveItem(at:cacheRoot.appendingPathComponent(old.folder),to:cacheRoot.appendingPathComponent(next.folder))
            #expect(m.noteCache.lastScope == old)
            #expect(m.noteCache.recent(scope:next)?.value.map(\.id) == ["saved"])
            AppServerStub.offline=true
            await m.refreshServer()
            // (adapted from the observation) adopt completes the interrupted move: the same vault's notes stay readable
            #expect(m.recent.map(\.id) == ["saved"])
            #expect(m.noteCache.lastScope == next)
            #expect(m.noteCache.recent(scope:next)?.value.map(\.id) == ["saved"])
        }
    }
}
