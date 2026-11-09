import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

/// Chunks quarantined for a 409 go back to the upload queue once, for a server that takes the same audio
/// sent again (`same_audio_resend`); nothing is deleted and a real conflict isn't retried forever.
@Suite struct RequeueConflictsTests {
    func quarantined(_ t: TestEnv, seq: Int, reason: String) throws -> String {
        let item = try t.outbox.write(Data("chunk \(seq)".utf8), kind: .chunk(captureId: "cap", sequence: seq))
        try t.outbox.quarantine(item.name, reason: reason)
        return item.name
    }

    @Test func conflictsGoBackToPendingOnceAndOtherReasonsStay() throws {
        let t = TestEnv()
        let conflict = try quarantined(t, seq: 1, reason: "409: different content already stored under this identity — chunk_conflict")
        let invalid = try quarantined(t, seq: 2, reason: "422: server rejected the envelope")
        #expect(try t.outbox.requeueConflicts() == [conflict])
        #expect(t.outbox.pending().map(\.name) == [conflict])
        #expect(t.outbox.quarantined().map(\.name) == [invalid])
        #expect(try Data(contentsOf: t.dirs.outboxPending.appendingPathComponent(conflict)) == Data("chunk 1".utf8), "the same bytes")
        // a real conflict: quarantined again by the uploader, and not moved back a second time
        try t.outbox.quarantine(conflict, reason: "409: different content already stored under this identity")
        #expect(try t.outbox.requeueConflicts() == [])
        #expect(Set(t.outbox.quarantined().map(\.name)) == [conflict, invalid])
    }

    @Test func keptAsideFilesAreCountedByTheirDevice() throws {
        let t = TestEnv()
        func chunk(_ capture: String, _ source: CaptureSource) throws {
            let payload = Data(repeating: 0, count: 64)
            let h = EnvelopeHeader(
                captureId: capture, chunkSequence: 0, deviceId: "dev", deviceName: nil, modelNumber: nil, firmwareRevision: nil,
                hardwareRevision: nil, source: source, payloadFormat: .pcm16leV1, codecId: 0,
                captureStartedAt: "2026-11-08T19:32:05.123Z", chunkStartOffsetUs: 0, chunkEndOffsetUs: 2000, clockQuality: .unknown,
                timezone: nil, recordCount: 32, payloadBytes: payload.count, offlineStorage: nil, ring: nil, appVersion: nil)
            let item = try t.outbox.write(try Envelope.build(header: h, payload: payload), kind: .chunk(captureId: capture, sequence: 0))
            try t.outbox.quarantine(item.name, reason: "409: x")
        }
        try chunk("watch-rec", .watchMic)
        try chunk("pendant-cap", .liveBLE)
        let seal = SealBody(lastChunkSequence: 0, reason: .userStopped, endedAt: "2026-11-08T19:33:00Z", endOffsetUs: 2000,
                            deviceId: "watch-1", source: .watchMic)
        let sealItem = try t.outbox.write(try ContractJSON.encode(seal), kind: .seal(captureId: "watch-rec"))
        try t.outbox.quarantine(sealItem.name, reason: "422: x")
        let event = try t.outbox.write(Data("{}".utf8), kind: .event(eventId: "e1"))
        try t.outbox.quarantine(event.name, reason: "422: x")
        let s = t.outbox.stats()
        #expect(s.quarantineCount == 4 && s.quarantineWatchCount == 2, "the Watch's chunk and seal; the pendant's chunk and an event aren't")
    }

    @Test func theReasonIsKeptInTheLedger() throws {
        let t = TestEnv()
        let name = try quarantined(t, seq: 3, reason: "409: x")
        try t.outbox.requeueConflicts()
        #expect(try t.outbox.readRequeueLedger() == [name: .init(state: .done, reason: "409: x")])
    }

    @Test func aCrashAfterTheIntentIsRedoneNotLeftOutForever() throws {
        let t = TestEnv()
        let name = try quarantined(t, seq: 4, reason: "409: x")
        // the intent was saved, then the app died before the move
        let intent = [name: Outbox.RequeueEntry(state: .intent, reason: "409: x")]
        try FileIO.atomicWrite(try JSONEncoder().encode(intent), to: t.outbox.requeuedLedger)
        #expect(try t.outbox.requeueConflicts() == [name])
        #expect(t.outbox.pending().map(\.name) == [name] && t.outbox.quarantined().isEmpty)
        #expect(try t.outbox.readRequeueLedger()[name]?.state == .done)
    }

    @Test func aCrashAfterTheMoveIsCompleted() throws {
        let t = TestEnv()
        let item = try t.outbox.write(Data("chunk 5".utf8), kind: .chunk(captureId: "cap", sequence: 5))
        let intent = [item.name: Outbox.RequeueEntry(state: .intent, reason: "409: x")]
        try FileIO.atomicWrite(try JSONEncoder().encode(intent), to: t.outbox.requeuedLedger)
        #expect(try t.outbox.requeueConflicts() == [], "already pending: nothing moves")
        #expect(try t.outbox.readRequeueLedger()[item.name]?.state == .done)
        #expect(t.outbox.pending().map(\.name) == [item.name])
    }

    @Test func anUnreadableLedgerMovesNothingAndIsNotTakenAsEmpty() throws {
        let t = TestEnv()
        let name = try quarantined(t, seq: 6, reason: "409: x")
        try FileIO.atomicWrite(Data("{not json".utf8), to: t.outbox.requeuedLedger)
        #expect(throws: Outbox.RequeueError.self) { try t.outbox.requeueConflicts() }
        #expect(t.outbox.quarantined().map(\.name) == [name] && t.outbox.pending().isEmpty)
        #expect(try Data(contentsOf: t.outbox.requeuedLedger) == Data("{not json".utf8), "left for a person to look at")
    }
}
