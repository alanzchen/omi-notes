import Foundation
import Testing
@testable import OmiCapture

/// ASTRA-20261121-IT3-04: server A's 507 (its disk full) survived a change to server B, so B would read as full.
@Suite(.serialized) struct UploadDiskScopeTests {
    @Test func aServerChangeForgetsTheOldServersLastResult() throws {
        let h = UploaderHarness()
        let item = try h.writeChunk(seq: 0)
        h.reconcile()
        h.complete(item.name, status: 507, body: #"{"error":"storage_full"}"#)
        #expect(h.uploader.status.lastResult?.status == 507)
        h.changeServer(token: "another")
        #expect(h.uploader.status.lastResult == nil, "the last result belonged to the previous server")
        #expect(h.t.outbox.pending().map(\.name) == [item.name], "the part itself stays")
    }
}
