import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// Pausing recording from the phone, and leaving the pendant's stored audio until asked.
@Suite struct PendantRecordingChoicesTests {
    @Test func pausingTurnsAudioOffSealsTheCaptureAndNeverDropsWhatArrives() throws {
        let h = SessionHarness()
        h.connectFully()
        h.transport.audio(Data([0, 0, 0, 1, 2, 3]))
        let first = try #require(h.session.recorder.captureId)
        h.session.setAudioPaused(true)
        #expect(h.transport.calls.last == "notify audioData false")
        #expect(!h.session.recorder.isActive && h.session.info.audioPaused)
        let seal = h.outbox.pending().first { if case .seal(let id) = $0.kind { return id == first } else { return false } }
        let body = try #require(seal.flatMap { try? JSONDecoder().decode(SealBody.self, from: Data(contentsOf: $0.url)) })
        #expect(body.reason == .userStopped, "the gap is the user's, not a fault")
        // the firmware reports notifications off: nothing is re-subscribed while paused
        h.transport.delegate?.transport(h.transport, didUpdateNotificationStateFor: .audioData, enabled: false, error: nil)
        h.session.tick()
        #expect(!h.transport.calls.suffix(2).contains("notify audioData true"))
        // a packet already on its way is still journaled, never thrown away
        h.transport.audio(Data([0, 1, 0, 9, 9, 9]))
        #expect(h.session.recorder.isActive)

        h.session.setAudioPaused(false)
        #expect(h.transport.calls.last == "notify audioData true" && !h.session.info.audioPaused)
    }

    @Test func aPausedPhoneConnectsWithoutAudioButStillSyncsThePendant() {
        let h = SessionHarness()
        h.session.startPaused(true)
        h.connectFully()
        #expect(!h.transport.calls.contains("notify audioData true"), "not subscribed: the pendant drops audio while connected")
        #expect(h.session.phase == .streaming && !h.session.recorder.isActive)
        #expect(h.transport.calls.contains("read storageStatus"), "offline sync still runs")
        h.session.setAudioPaused(false)
        #expect(h.transport.calls.last == "notify audioData true")
    }

    @Test func withAutomaticCollectionOffTheStoredAudioWaitsUntilAsked() {
        var status = Data()
        for v: UInt32 in [444 * 3, 3, 1_000_000, 1] { status.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        let h = SessionHarness(values: FakeDeviceTransport.cv1Values(status: status))
        h.session.autoCollect = false
        h.connectFully()
        #expect(h.session.info.offlineHeld && h.session.info.offlineUnread == 3, "what's waiting is shown (a status read writes nothing)")
        #expect(!h.transport.calls.contains { $0.hasPrefix("write storageControl") }, "nothing collected or advanced")
        h.session.collectOfflineAudio()
        #expect(!h.session.info.offlineHeld && h.transport.calls.contains("write storageControl 10"))
    }
}
