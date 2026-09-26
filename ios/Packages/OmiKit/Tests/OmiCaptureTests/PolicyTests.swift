import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite struct RetentionTests {
    let policy = RetentionPolicy()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    func chunk(_ cid: String, _ seq: Int, ageHours: Double, size: Int64 = 100_000) -> RetentionPolicy.SentFile {
        let k = OutboxKind.chunk(captureId: cid, sequence: seq)
        return .init(name: k.fileName, kind: k, size: size, sentAt: now.addingTimeInterval(-ageHours * hour))
    }

    @Test func processedPlusGraceIsDeleted() {
        let files = [chunk("a", 0, ageHours: 25), chunk("a", 1, ageHours: 25), chunk("a", 2, ageHours: 23), chunk("b", 0, ageHours: 48)]
        let del = policy.filesToDelete(sent: files, processedThrough: ["a": 1], now: now)
        #expect(del == [files[0].name, files[1].name])  // a/2 too young; b unknown → kept until 7 d
    }

    @Test func notProcessedIsKeptUntilHardCap() {
        let files = [chunk("a", 5, ageHours: 100), chunk("a", 6, ageHours: 7 * 24)]
        let del = policy.filesToDelete(sent: files, processedThrough: ["a": 4], now: now)
        #expect(del == [files[1].name])
    }

    @Test func sizeCapDeletesOldestAcknowledged() {
        let gb: Int64 = 1 << 30
        let files = [chunk("a", 0, ageHours: 3, size: gb / 2), chunk("a", 1, ageHours: 2, size: gb / 2), chunk("a", 2, ageHours: 1, size: gb / 2)]
        let del = policy.filesToDelete(sent: files, processedThrough: [:], now: now)
        #expect(del == [files[0].name])
    }

    @Test func sealsAndEventsAfterGrace() {
        let s = RetentionPolicy.SentFile(name: "seal_a.json", kind: .seal(captureId: "a"), size: 200, sentAt: now.addingTimeInterval(-25 * hour))
        let e = RetentionPolicy.SentFile(name: "event_x.json", kind: .event(eventId: "x"), size: 200, sentAt: now.addingTimeInterval(-hour))
        #expect(policy.filesToDelete(sent: [s, e], processedThrough: [:], now: now) == [s.name])
    }

    @Test func capturesNeedingStatus() {
        let files = [chunk("a", 0, ageHours: 30), chunk("b", 3, ageHours: 30), chunk("c", 0, ageHours: 2)]
        #expect(policy.capturesNeedingStatus(sent: files, known: ["b": 5], now: now) == ["a"])
    }
}

@Suite struct StorageGuardTests {
    let p = StorageGuardPolicy()
    let mb: Int64 = 1024 * 1024

    @Test func tripAndHysteresis() {
        #expect(p.evaluate(freeBytes: 500 * mb, tripped: false) == .ok)
        #expect(p.evaluate(freeBytes: 199 * mb, tripped: false) == .trip)
        #expect(p.evaluate(freeBytes: 250 * mb, tripped: true) == .stayTripped)  // not yet recovered
        #expect(p.evaluate(freeBytes: 300 * mb, tripped: true) == .recover)
        #expect(p.evaluate(freeBytes: nil, tripped: true) == .stayTripped)
        #expect(p.evaluate(freeBytes: nil, tripped: false) == .ok)
    }
}

@Suite struct RingCursorTests {
    @Test func generationBumpsWhenSequencesGoBackwards() {
        var c = RingCursor()
        #expect(c.generation == 1)
        let first = c.observe(info: .init(readSeq: 100, writeSeq: 200, capacity: 1000, dropped: 0, recordSize: 444))
        #expect(!first)
        c.notePersisted(199)
        #expect(c.isDuplicate(150))
        #expect(!c.isDuplicate(200))
        let second = c.observe(info: .init(readSeq: 200, writeSeq: 260, capacity: 1000, dropped: 0, recordSize: 444))
        #expect(!second)
        let reflash = c.observe(info: .init(readSeq: 0, writeSeq: 40, capacity: 1000, dropped: 0, recordSize: 444))
        #expect(reflash)
        #expect(c.generation == 2)
        #expect(c.lastPersistedSeq == nil)
        #expect(!c.isDuplicate(10))
    }

    @Test func persistedNeverMovesBackwards() {
        var c = RingCursor()
        c.notePersisted(10)
        c.notePersisted(5)
        #expect(c.lastPersistedSeq == 10)
    }

    @Test func storeRoundTrip() throws {
        let t = TestEnv()
        let store = RingCursorStore(stateDir: t.dirs.state)
        var c = store.load("dev")
        c.notePersisted(42)
        try store.save(c, deviceId: "dev")
        #expect(store.load("dev").lastPersistedSeq == 42)
    }
}

@Suite struct EventWriterTests {
    @Test func writesButtonAndHeartbeat() throws {
        let t = TestEnv()
        let ids = SequentialIDs(prefix: "00000000-0000-4000-9000-")
        let w = EventWriter(outbox: t.outbox, clock: t.clock, idGenerator: { ids.next() })
        let b = try w.button(code: 2, deviceId: "dev", captureId: "cap", offsetUs: 1_500_000)
        #expect(b.name == "event_00000000-0000-4000-9000-000000000001.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: b.url)) as! [String: Any]
        #expect(json["type"] as? String == "button")
        #expect((json["data"] as? [String: Any])?["code"] as? Int == 2)
        #expect(json["capture_id"] as? String == "cap")
        #expect(json["offset_us"] as? Int == 1_500_000)
        #expect(json["at"] as? String == "2026-09-26T19:32:05.123Z")
        let hb = try w.heartbeat(deviceId: "dev", data: HeartbeatData(battery: 50, coverage: CoverageWatermark(captureId: "cap", throughOffsetUs: 10, throughChunkSequence: 0)))
        let hj = try JSONSerialization.jsonObject(with: Data(contentsOf: hb.url)) as! [String: Any]
        #expect(hj["type"] as? String == "heartbeat")
        #expect(((hj["data"] as? [String: Any])?["coverage"] as? [String: Any])?["through_chunk_sequence"] as? Int == 0)
    }
}

@Suite struct RedactionTests {
    @Test func tokensNeverReachLogs() {
        #expect(OmiLog.redact("omi-notes://configure?url=https://x&token=abcdef123") == "omi-notes://configure?url=https://x&token=‹redacted›")
        #expect(OmiLog.redact("Authorization: Bearer abc.def-ghi") == "Authorization: Bearer ‹redacted›")
        let log = OmiLog()
        log.registerSecret("s3cr3t-value")
        log.log(.info, "t", "sending s3cr3t-value now")
        #expect(log.recent().last?.message == "sending ‹redacted› now")
    }
}
