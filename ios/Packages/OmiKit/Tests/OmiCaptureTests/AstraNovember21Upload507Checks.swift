// Astra's IT1 check (omi-notes-reviews/nightly-2026-11-21-it1/swift/AstraNovember21Upload507Checks.swift), adopted unchanged.
import Foundation
import Testing
@testable import OmiCapture

@Suite(.serialized) struct AstraNovember21Upload507Checks {
    @Test func diskFullKeepsBytesBacksOffAndOnlyAcksAfterRecovery() throws {
        let h=UploaderHarness()
        let item=try h.writeChunk(seq:0)
        let bytes=try Data(contentsOf:item.url)
        h.reconcile()
        h.complete(item.name,status:507,body:#"{"error":"storage_full","detail":"server disk is nearly full"}"#)
        #expect(h.t.outbox.pending().map(\.name)==[item.name])
        #expect(h.t.outbox.quarantined().isEmpty && h.t.outbox.sent().isEmpty)
        #expect(try Data(contentsOf:item.url)==bytes)
        #expect(h.task(for:item.name)?.earliest==h.now.addingTimeInterval(30))
        #expect(h.uploader.status.lastResult?.message=="storage_full: server disk is nearly full")
        let firstRetryCount=h.started.count
        for _ in 0..<10 { h.reconcile() }
        #expect(h.started.count==firstRetryCount)
        h.complete(item.name,status:507)
        #expect(h.task(for:item.name)?.earliest==h.now.addingTimeInterval(60))
        let reloaded=UploaderHarness(reusing:h)
        reloaded.reconcile()
        #expect(reloaded.t.outbox.pending().map(\.name)==[item.name])
        #expect(reloaded.task(for:item.name)?.earliest==h.now.addingTimeInterval(60))
        #expect(try Data(contentsOf:item.url)==bytes)
        reloaded.complete(item.name,status:201)
        #expect(reloaded.t.outbox.pending().isEmpty && reloaded.t.outbox.sent().count==1)
        #expect(try Data(contentsOf:reloaded.t.outbox.sent()[0].url)==bytes)
    }
}
