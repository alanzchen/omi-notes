import Foundation
import Testing
@testable import OmiBLE
import OmiCapture

@Suite struct AstraR6WatchWaitingChecks {
    @Test func movingWatchBytesMustNotBeCalledWaiting() {
        let h = TransferSummaryTests()
        // All three pending chunks are Watch chunks; the upload meter has moving audio bytes.
        // Production pending inventory retains in-flight files until the server ACK.
        var s = h.snapshot(pending: 3, bytesAt: 5_000_000_000)
        s.outbox.pendingChunks = 3
        s.watchWaitingUpload = 3
        let p = TransferSummary.evaluate(snapshot: s, server: h.reachable(), status: nil,
            statusAt: nil, watchInstalled: true, nowMono: 5_000_000_000, now: h.now).phone
        #expect(p.state == .sending)
        let line = WatchSummary.uploadLine(waiting: s.watchWaitingUpload,
            othersWaiting: s.outbox.pendingChunks - s.watchWaitingUpload, setAside: 0,
            inventoryReadable: true, lastUploadedAt: nil, received: 3, now: h.now,
            upload: p.state, serverFull: p.serverFull)
        #expect(!line.lowercased().contains("waiting"),
            "pending includes actively sending Watch audio; use an unconfirmed/completion-neutral description")
    }
}
