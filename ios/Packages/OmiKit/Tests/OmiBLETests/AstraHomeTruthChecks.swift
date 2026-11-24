import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture

@Suite struct AstraHomeTruthChecks {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func currentProgressAndAcknowledgementMustNotBeCalledWaiting() {
        var s = EngineSnapshot()
        s.ready = true; s.serverConfigured = true
        s.outbox.pendingCount = 2; s.outbox.pendingChunks = 2
        s.transfer.meter.start(atMono: 0, wall: now)
        s.transfer.meter.began(id: "2.1|chunk-a", audio: true, expected: 1000)
        s.transfer.meter.progress(id: "2.1|chunk-a", audio: true, sent: 1000, expected: 1000, atMono: 2_000_000_000)
        s.transfer.meter.finished(id: "2.1|chunk-a", audio: true, bytes: 1000, outcome: .delivered, atMono: 2_000_000_000)
        let transfer = TransferSummary.evaluate(snapshot: s, server: .checking, status: nil, statusAt: nil, watchInstalled: false, nowMono: 2_000_000_000, now: now)
        #expect(transfer.phone.state == .sending && transfer.phone.deliveredAudioFiles == 1)
        let home = SystemHealth.phone(s, server: .checking, now: now)
        #expect(home.title != "Audio is waiting to upload", "Fresh current-configuration progress and ACK are already observed: \(home)")
    }
    // (her carried unreadable-queue check is left out: not one of the four findings of this round)
}
