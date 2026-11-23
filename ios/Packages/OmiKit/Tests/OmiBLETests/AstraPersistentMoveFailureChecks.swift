import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraPersistentMoveFailureChecks {
        @Test func persistentPointerFailureMustNotDeleteAlreadyMovedNotes() async throws {
            let (m, root) = try RetryFlowTests().model()
            let pointer = root.appendingPathComponent("cache/scope.json")
            defer {
                try? FileManager.default.setAttributes([.immutable:false],ofItemAtPath:pointer.path)
                try? FileManager.default.removeItem(at:root)
            }
            await m.refreshServer()
            let old = try #require(m.cacheScope(m.engine.settings.serverConfig()))
            let row = ConversationSummary(id:"saved", status:"done", startedAt:"2026-11-19T00:00:00.000Z", title:"Saved")
            m.noteCache.saveRecent([row], scope:old)
            let destination = URL(string:"https://next.example")!
            try m.engine.configureServer(url:destination, token:"tok")
            let next = NoteCache.Scope(serverURL:destination.absoluteString,generation:m.engine.settings.serverConfig().generation,vaultId:old.vaultId)
            try FileManager.default.setAttributes([.immutable:true],ofItemAtPath:pointer.path)
            #expect(!m.noteCache.move(to:next))
            #expect(m.noteCache.lastScope == old)
            #expect(m.noteCache.recent(scope:next)?.value.map(\.id) == ["saved"])
            AppServerStub.offline=true
            await m.refreshServer() // the same pointer-write failure is still active
            #expect(m.noteCache.recent(scope:next)?.value.map(\.id) == ["saved"], "A retry failure must not clear already-moved notes")
            try FileManager.default.setAttributes([.immutable:false],ofItemAtPath:pointer.path)
            await m.refreshServer()
            #expect(m.recent.map(\.id) == ["saved"], "Once the write recovers, refresh must complete the move even if the previous adopt ran")
        }
    }
}
