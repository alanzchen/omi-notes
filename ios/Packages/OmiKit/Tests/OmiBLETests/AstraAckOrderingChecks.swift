import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
@Suite struct AstraAckOrderingChecks {
    @Test func aNewerFailureMustNotBeHiddenByAnOlderACK() {
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        var s = EngineSnapshot(); s.ready = true; s.serverConfigured = true
        s.outbox.pendingCount = 2; s.outbox.pendingChunks = 2; s.outbox.pendingBytes = 10_000
        s.transfer.meter.start(atMono: 0, wall: wall)
        s.transfer.meter.began(id: "1.1|chunk-a", audio: true, expected: 1000)
        s.transfer.meter.finished(id: "1.1|chunk-a", audio: true, bytes: 1000, outcome: .delivered, atMono: 2_000_000_000)
        // Another request moves bytes at t=8; a status check has just failed after the t=2 ACK.
        s.transfer.meter.began(id: "1.1|chunk-b", audio: true, expected: 1000)
        s.transfer.meter.progress(id: "1.1|chunk-b", audio: true, sent: 500, expected: 1000, atMono: 8_000_000_000)
        let t = TransferSummary.evaluate(snapshot: s, server: .unreachable("new failure"), status: nil,
                                         statusAt: wall.addingTimeInterval(8), watchInstalled: false,
                                         nowMono: 8_000_000_000, now: wall.addingTimeInterval(8))
        #expect(t.phone.state == .sending && t.phone.ackedRecently)
        #expect(t.problemLine(now: wall.addingTimeInterval(8)) != nil)
    }
}
