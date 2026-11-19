// ASTRA-20261118-IT4 review checks (reused unchanged).
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite(.serialized) struct AstraR4Checks {
    func restrict(_ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions:0o300],ofItemAtPath:dir.path)
        let fd=open(dir.path,O_RDONLY), code=errno
        if fd >= 0 { close(fd) }
        try #require(fd < 0 && code == EACCES)
    }
    func allow(_ dir: URL) { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dir.path) }

    @Test func frozenHeaderIsUsedEvenIfManifestCommitWasLost() throws {
        var t=TestEnv();let faults=FaultInjector();t.env.faults=faults
        var recorder:LiveCaptureRecorder?=try LiveCaptureTests().recorder(t).0
        let id=try #require(recorder?.captureId)
        defer { allow(t.dirs.outboxPending) }
        #expect(recorder?.append(notification(seq:0)) == true)
        faults.manifestSave = { throw InjectedFault(what:"manifest checkpoint") }
        try restrict(t.dirs.outboxPending)
        t.clock.advance(61);recorder?.tick()
        let dir=t.dirs.journalLive.appendingPathComponent(id)
        let header=dir.appendingPathComponent("chunk-000000.header")
        let originalHeader=try Data(contentsOf:header)
        let output=t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
        let original=try Data(contentsOf:output)
        let manifest=try JSONDecoder().decode(CaptureManifest.self,from:Data(contentsOf:dir.appendingPathComponent("capture.json")))
        try #require(manifest.openChunkSequence == 0)
        recorder=nil
        try FileManager.default.removeItem(at:output) // only the unconfirmed publication is lost in this synthetic crash
        allow(t.dirs.outboxPending)
        _ = CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
        let rebuilt=try Data(contentsOf:output)
        let old=try Envelope.parse(original), new=try Envelope.parse(rebuilt)
        print("ASTRA MANIFEST LAG: oldEnd=\(old.header.chunkEndOffsetUs), newEnd=\(new.header.chunkEndOffsetUs), samePayload=\(old.payload == new.payload), frozenHeaderBytes=\(originalHeader.count)")
        #expect(rebuilt == original,"a valid frozen header must win over a stale manifest when republishing an identity")
    }

    @Test func existingSealInUnconfirmedQuarantineKeepsItsSourceFolder() throws {
        let t=TestEnv();defer {allow(t.dirs.outboxPending);allow(t.dirs.outboxQuarantine)}
        let (recorder,id)=try LiveCaptureTests().recorder(t)
        #expect(recorder.append(notification(seq:0)))
        try restrict(t.dirs.outboxPending);t.clock.advance(5)
        try #require(recorder.finish(reason:.bleDisconnected) != nil)
        let dir=t.dirs.journalLive.appendingPathComponent(id)
        allow(t.dirs.outboxPending)
        // markSent represents the existing 2xx upload outcome; audio itself is safely acknowledged.
        try t.outbox.markSent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
        try restrict(t.dirs.outboxQuarantine)
        try t.outbox.quarantine(OutboxKind.seal(captureId:id).fileName,reason:"422: synthetic seal rejection")
        _ = CaptureRecovery.run(env:t.env,codecFallback:{_ in 21})
        #expect(FileIO.exists(dir),"existing-seal recovery should account for the seal before retiring its source")
    }

    @Test(arguments:["missing","invalid-json","wrong-length"])
    func olderOrUnreadableHeadersKeepTheOriginal(variant:String) throws {
        let t=TestEnv();defer {allow(t.dirs.outboxPending)}
        var recorder:LiveCaptureRecorder?=try LiveCaptureTests().recorder(t).0
        let id=try #require(recorder?.captureId)
        #expect(recorder?.append(notification(seq:0)) == true)
        try restrict(t.dirs.outboxPending);t.clock.advance(61);recorder?.tick();recorder=nil
        let dir=t.dirs.journalLive.appendingPathComponent(id), journal=dir.appendingPathComponent("chunk-000000.journal"), header=dir.appendingPathComponent("chunk-000000.header")
        let original=try Data(contentsOf:journal)
        let output=t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
        try FileManager.default.removeItem(at:output)
        if variant == "missing" { try FileManager.default.removeItem(at:header) }
        else if variant == "invalid-json" {try Data("{".utf8).write(to:header)}
        else { var h=try JSONDecoder().decode(EnvelopeHeader.self,from:Data(contentsOf:header));h.payloadBytes += 1;try Envelope.headerJSON(h).write(to:header) }
        allow(t.dirs.outboxPending)
        _ = CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
        #expect(try Data(contentsOf:journal) == original)
        #expect(!FileIO.exists(output))
    }

    @Test func ringRebuildIsByteIdenticalAndCleansHeaders() throws {
        let h=RingHarness(recordsPerChunk:1);defer {allow(h.t.dirs.outboxPending)}
        h.startThroughInfoRequest(unread:2)
        h.feed([RingWire.info(read:100,write:102),RingWire.readBegin(100,2)])
        try restrict(h.t.dirs.outboxPending)
        h.feed(RingWire.data([ringRecord(seq:100),ringRecord(seq:101)]));h.feed([RingWire.done(0,102)])
        let dir=try #require(FileIO.contents(of:h.t.dirs.journalRing).first)
        let outputs=(0...1).map {h.t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:dir.lastPathComponent,sequence:$0).fileName)}
        let originals=try outputs.map {try Data(contentsOf:$0)}
        for output in outputs {try FileManager.default.removeItem(at:output)}
        allow(h.t.dirs.outboxPending)
        _ = CaptureRecovery.run(env:TestEnv(root:h.t.dirs.root).env,codecFallback:{_ in 21})
        #expect(try outputs.map {try Data(contentsOf:$0)} == originals)
        #expect(!FileIO.exists(dir))
    }
}
