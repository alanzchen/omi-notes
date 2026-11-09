import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
@testable import OmiProtocol
@testable import OmiWatchKit

/// The Watch → phone → upload relay: durable before acknowledged, idempotent on resend, converted to
/// `watch_mic` PCM envelopes, sealed after the last segment, and never sent to another phone.
@Suite struct WatchRelayTests {
    /// A real AAC segment like the Watch records (16 kHz mono), `seconds` long.
    static func segmentFile(seconds: Double, in dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let n = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 220 / format.sampleRate) * 0.3) }
        try file.write(from: buffer)
        return url
    }

    static func sha(_ url: URL) -> String { SHA256.hash(data: try! Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    func manifest(_ url: URL, recording: String, index: Int, binding: String, start: Int64) -> WatchSegment {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return WatchSegment(recordingId: recording, index: index, deviceId: "watch-1", deviceName: "Apple Watch", binding: binding,
                            recordingStartedAt: Date(timeIntervalSince1970: 1_790_500_000), startOffsetUs: start, endOffsetUs: start + 2_000_000,
                            bytes: bytes, sha256: Self.sha(url))
    }

    @Test func segmentsAreKeptUntilDurableThenQueuedOnceAndSealed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-watch-\(UUID().uuidString)")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        let outbox = Outbox(dirs: dirs)
        let inbox = PhoneWatchInbox(root: root.appendingPathComponent("watch"), binding: "phone-A")
        let relay = WatchRelayProcessor(inbox: inbox, outbox: outbox, appVersion: "t", timezone: "UTC")
        let tmp = root.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let rec = UUID().uuidString.lowercased()

        let s0 = try Self.segmentFile(seconds: 2, in: tmp, name: "s0"), s1 = try Self.segmentFile(seconds: 1.5, in: tmp, name: "s1")
        let m0 = manifest(s0, recording: rec, index: 0, binding: "phone-A", start: 0)
        let m1 = manifest(s1, recording: rec, index: 1, binding: "phone-A", start: 2_000_500)

        // another phone's recording, or a damaged copy, is refused (the Watch keeps it)
        #expect(throws: WatchRelayError.wrongPhone) { try inbox.accept(file: s0, segment: self.manifest(s0, recording: rec, index: 0, binding: "phone-B", start: 0)) }
        var bad = m0; bad.sha256 = String(repeating: "0", count: 64)
        #expect(throws: WatchRelayError.damaged("SHA-256")) { try inbox.accept(file: s0, segment: bad) }

        try inbox.accept(file: s0, segment: m0)
        try inbox.accept(file: s0, segment: m0)  // a resend: acknowledged again, nothing new
        try inbox.accept(end: WatchRecordingEnd(recordingId: rec, deviceId: "watch-1", binding: "phone-A", lastIndex: 1,
                                                endOffsetUs: 3_500_500, endedAt: Date(timeIntervalSince1970: 1_790_500_004), reason: .userStopped))
        #expect(relay.process() == 1, "segment 0 queued; not sealed while segment 1 is missing")
        #expect(outbox.pending().filter { if case .seal = $0.kind { return true } else { return false } }.isEmpty)

        try inbox.accept(file: s1, segment: m1)
        #expect(relay.process() == 2, "segment 1 and then the seal")
        try inbox.accept(file: s0, segment: m0)  // a late resend after conversion: still nothing new
        #expect(relay.process() == 0)

        let chunks = outbox.pending().filter(\.kind.isChunk)
        #expect(chunks.count == 2)
        let parsed = try Envelope.parse(Data(contentsOf: try #require(chunks.first { $0.kind == .chunk(captureId: rec, sequence: 1) }).url))
        #expect(parsed.header.source == .watchMic && parsed.header.payloadFormat == .pcm16leV1 && parsed.header.deviceId == "watch-1")
        #expect(abs(parsed.header.recordCount - 24_000) < 1_200, "about 1.5 s at 16 kHz: \(parsed.header.recordCount)")
        #expect(parsed.header.chunkStartOffsetUs == 2_000_500)
        let sealItem = try #require(outbox.pending().first { $0.kind == .seal(captureId: rec) })
        let seal = try JSONDecoder().decode(SealBody.self, from: Data(contentsOf: sealItem.url))
        #expect(seal.lastChunkSequence == 1 && seal.source == .watchMic && seal.reason == .userStopped && seal.endOffsetUs == parsed.header.chunkEndOffsetUs)
    }

    /// Servers with `watch_aac`: the Watch's AAC goes up unchanged (no decode, no re-encode), sized by
    /// the file's own frame count; a recording already started as PCM stays PCM; others get PCM.
    @Test func theWatchsAACIsRelayedUnchangedWhenTheServerTakesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-waac-\(UUID().uuidString)")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        let outbox = Outbox(dirs: dirs)
        let inbox = PhoneWatchInbox(root: root.appendingPathComponent("watch"), binding: "phone-A")
        var takesAAC = true
        let relay = WatchRelayProcessor(inbox: inbox, outbox: outbox, appVersion: "t", timezone: "UTC", serverTakesAAC: { takesAAC })
        let tmp = root.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let rec = UUID().uuidString.lowercased()
        let f0 = try Self.segmentFile(seconds: 2.5, in: tmp, name: "a0")
        let original = try Data(contentsOf: f0)
        let frames = try AVAudioFile(forReading: f0).length
        try inbox.accept(file: f0, segment: manifest(f0, recording: rec, index: 0, binding: "phone-A", start: 0))
        #expect(relay.process() == 1)
        let chunk = try #require(outbox.pending().first { $0.kind == .chunk(captureId: rec, sequence: 0) })
        let parsed = try Envelope.parse(Data(contentsOf: chunk.url))
        #expect(parsed.header.payloadFormat == .aacM4aV1 && parsed.payload == original, "the original file, byte for byte")
        #expect(parsed.header.recordCount == Int(frames) && parsed.header.chunkEndOffsetUs == Int64(frames) * 1_000_000 / 16_000)
        #expect(original.count < Int(frames) * 2, "smaller than PCM: \(original.count) vs \(Int(frames) * 2) bytes")

        // the server stops taking AAC: this recording keeps its format (all parts alike)…
        takesAAC = false
        let f1 = try Self.segmentFile(seconds: 1, in: tmp, name: "a1")
        try inbox.accept(file: f1, segment: manifest(f1, recording: rec, index: 1, binding: "phone-A", start: 2_500_000))
        #expect(relay.process() == 1)
        let second = try Envelope.parse(Data(contentsOf: try #require(outbox.pending().first { $0.kind == .chunk(captureId: rec, sequence: 1) }).url))
        #expect(second.header.payloadFormat == .aacM4aV1)
        // …and a new recording is converted to PCM
        let other = UUID().uuidString.lowercased()
        let f2 = try Self.segmentFile(seconds: 1, in: tmp, name: "b0")
        try inbox.accept(file: f2, segment: manifest(f2, recording: other, index: 0, binding: "phone-A", start: 0))
        #expect(relay.process() == 1)
        let pcm = try Envelope.parse(Data(contentsOf: try #require(outbox.pending().first { $0.kind == .chunk(captureId: other, sequence: 0) }).url))
        #expect(pcm.header.payloadFormat == .pcm16leV1 && pcm.payload.count == pcm.header.recordCount * 2)
    }

    @Test func aRecordingAnOlderVersionStartedAsPCMStaysPCM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-wmix-\(UUID().uuidString)")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        let outbox = Outbox(dirs: dirs)
        let inbox = PhoneWatchInbox(root: root.appendingPathComponent("watch"), binding: "phone-A")
        let tmp = root.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let rec = UUID().uuidString.lowercased()
        // part 0 converted by an earlier version (PCM, no format recorded)
        let old = WatchRelayProcessor(inbox: inbox, outbox: outbox, appVersion: "old", timezone: "UTC")
        let f0 = try Self.segmentFile(seconds: 1, in: tmp, name: "p0")
        try inbox.accept(file: f0, segment: manifest(f0, recording: rec, index: 0, binding: "phone-A", start: 0))
        _ = old.process()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("watch/formats"))  // as before this version
        let new = WatchRelayProcessor(inbox: inbox, outbox: outbox, appVersion: "new", timezone: "UTC", serverTakesAAC: { true })
        let f1 = try Self.segmentFile(seconds: 1, in: tmp, name: "p1")
        try inbox.accept(file: f1, segment: manifest(f1, recording: rec, index: 1, binding: "phone-A", start: 1_000_000))
        #expect(new.process() == 1)
        let part1 = try Envelope.parse(Data(contentsOf: try #require(outbox.pending().first { $0.kind == .chunk(captureId: rec, sequence: 1) }).url))
        #expect(part1.header.payloadFormat == .pcm16leV1, "queued PCM chunks are never rewritten; the recording stays PCM")
    }

    @Test func theWatchDeletesOnlyWhatThePhoneAcknowledged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-wout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let out = WatchOutbox(root: root.appendingPathComponent("outbox"))
        let a = try Self.segmentFile(seconds: 1, in: root, name: "a"), b = try Self.segmentFile(seconds: 1, in: root, name: "b")
        let ma = manifest(a, recording: "r", index: 0, binding: "p", start: 0), mb = manifest(b, recording: "r", index: 1, binding: "p", start: 1_000_000)
        try out.add(segmentFile: a, segment: ma)
        try out.add(segmentFile: b, segment: mb)
        try out.add(end: WatchRecordingEnd(recordingId: "r", deviceId: "watch-1", binding: "p", lastIndex: 1, endOffsetUs: 2_000_000, endedAt: Date(), reason: .userStopped))
        #expect(out.pendingCount == 3)
        #expect(out.retire(receipts: [.init(id: ma.id, sha256: ma.sha256)]) == [ma.id])
        #expect(out.segments().map(\.segment.id) == [mb.id] && out.ends().count == 1, "only the acknowledged one is gone")
        // a relaunch sees the same pending state
        let again = WatchOutbox(root: root.appendingPathComponent("outbox"))
        #expect(again.pendingCount == 2)
        // the sync loop asks again and again: manifests are read from disk once per launch
        for _ in 0..<20 { _ = again.segments(); _ = again.ends(); _ = again.waitingBytes }
        #expect(again.manifestReads == 2)
        let c = try Self.segmentFile(seconds: 1, in: root, name: "c")
        let mc = manifest(c, recording: "r", index: 2, binding: "p", start: 2_000_000)
        try again.add(segmentFile: c, segment: mc)
        #expect(again.segments().map(\.segment.id) == [mb.id, mc.id] && again.manifestReads == 2, "kept current without rereading")
        _ = again.retire(receipts: [.init(id: mb.id, sha256: mb.sha256)])
        #expect(again.segments().map(\.segment.id) == [mc.id] && WatchOutbox(root: root.appendingPathComponent("outbox")).segments().map(\.segment.id) == [mc.id])
    }
}

/// ASTRA-IT8-01 (blocker): an audio part whose manifest is missing or unreadable wasn't in the readable
/// index, so it looked like "not audio" and a plain ack (a build-42 phone's, say) unlinked its only copy.
/// Plain acks now reach recording ends only; audio goes only on a receipt matching its own readable
/// manifest's checksum; unknown or unreadable metadata keeps the audio.
@Suite struct WatchStorageRetirementTests {
    func outbox() throws -> (WatchOutbox, URL, WatchSegment, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-wret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let out = WatchOutbox(root: root.appendingPathComponent("outbox"))
        let f = try WatchRelayTests.segmentFile(seconds: 1, in: root, name: "a")
        let m = WatchRelayTests().manifest(f, recording: "r", index: 0, binding: "p", start: 0)
        try out.add(segmentFile: f, segment: m)
        return (out, root.appendingPathComponent("outbox/segments"), m, root)
    }

    @Test(arguments: ["missing", "broken"])
    func aPlainAckNeverUnlinksAudioWhoseManifestIsGone(variant: String) throws {
        let (_, dir, m, root) = try outbox()
        let manifest = dir.appendingPathComponent("\(m.id).json"), audio = dir.appendingPathComponent("\(m.id).m4a")
        if variant == "missing" { try FileManager.default.removeItem(at: manifest) } else { try Data("broken-json".utf8).write(to: manifest) }
        let relaunched = WatchOutbox(root: root.appendingPathComponent("outbox"))  // reads the index again: the part isn't in it
        #expect(relaunched.segments().isEmpty)
        relaunched.acknowledgeEnds([m.id])                                       // a build-42 phone's plain ack
        #expect(relaunched.retire(receipts: [.init(id: m.id, sha256: m.sha256)]).isEmpty, "no readable manifest: no proof")
        #expect(FileManager.default.fileExists(atPath: audio.path), "the only copy stays")
    }

    @Test func onlyAMatchingReceiptRetiresAudioAndPlainAcksStillRetireEnds() throws {
        let (out, dir, m, _) = try outbox()
        let audio = dir.appendingPathComponent("\(m.id).m4a")
        try out.add(end: WatchRecordingEnd(recordingId: "r", deviceId: "watch-1", binding: "p", lastIndex: 0, endOffsetUs: 1_000_000, endedAt: Date(), reason: .userStopped))
        out.acknowledgeEnds([m.id])  // a plain ack for the audio part: nothing
        #expect(out.retire(receipts: [.init(id: m.id, sha256: String(repeating: "0", count: 64))]).isEmpty, "other bytes: kept")
        #expect(out.retire(receipts: [.init(id: "r-9", sha256: m.sha256)]).isEmpty, "other id: kept")
        #expect(FileManager.default.fileExists(atPath: audio.path) && out.segments().count == 1)
        #expect(out.retire(receipts: [.init(id: m.id, sha256: m.sha256)]) == [m.id])
        #expect(!FileManager.default.fileExists(atPath: audio.path) && out.segments().isEmpty)
        out.acknowledgeEnds(["r-end"])
        #expect(out.ends().isEmpty, "recording ends still go on their plain ack")
    }
}

/// ASTRA-IT9-01: a finished part moved into segments/ before its manifest was published (a failed write,
/// or the app ending in between) was invisible: not queued, not counted, never sent, never recovered.
/// The manifest's content is now written first as an intent; a later load publishes it again from that
/// intent when the audio matches, and keeps (and counts) any audio it can't identify.
@Suite struct WatchPublicationRecoveryTests {
    func setUp() throws -> (URL, WatchSegment, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-wpub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = try WatchRelayTests.segmentFile(seconds: 1, in: root, name: "finished")
        let m = WatchRelayTests().manifest(f, recording: "r", index: 0, binding: "p", start: 0)
        return (root, m, f, root.appendingPathComponent("watch/segments"))
    }

    @Test func aFailedManifestPublicationIsRecoveredOnTheNextLoad() throws {
        let (root, m, source, dir) = try setUp()
        let out = WatchOutbox(root: root.appendingPathComponent("watch"))
        let audio = dir.appendingPathComponent("\(m.id).m4a")
        let bytes = try Data(contentsOf: source)
        // only the manifest's publication fails, after the payload was moved in (Astra's obstruction)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".\(m.id).json.tmp"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try out.add(segmentFile: source, segment: m) }
        #expect(try Data(contentsOf: audio) == bytes && !FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".\(m.id).json.tmp"))
        // the same state as the app ending between the two steps: a cold load recovers it
        let cold = WatchOutbox(root: root.appendingPathComponent("watch"))
        #expect(cold.segments().map(\.segment.id) == [m.id] && cold.pendingCount == 1 && cold.waitingBytes == Int64(m.bytes))
        #expect(cold.orphans.isEmpty)
        #expect(cold.retire(receipts: [.init(id: m.id, sha256: m.sha256)]) == [m.id], "and a receipt retires it as usual")
    }

    @Test(arguments: ["no intent", "intent for other bytes"])
    func audioThatCantBeIdentifiedIsKeptAndCounted(variant: String) throws {
        let (root, m, source, dir) = try setUp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("\(m.id).m4a")
        try FileManager.default.copyItem(at: source, to: audio)  // an older build's orphan: audio, no manifest
        if variant != "no intent" {
            var other = m; other.sha256 = String(repeating: "0", count: 64)
            try WatchWire.encode(other).write(to: dir.appendingPathComponent("\(m.id).intent"))
        }
        let out = WatchOutbox(root: root.appendingPathComponent("watch"))
        #expect(out.segments().isEmpty, "never sent without a manifest that matches its bytes")
        #expect(out.orphans == [m.id: m.bytes] && out.waitingBytes == Int64(m.bytes), "counted where storage is counted")
        out.acknowledgeEnds([m.id])
        #expect(out.retire(receipts: [.init(id: m.id, sha256: m.sha256)]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: audio.path), "kept")
    }
}

/// OMI-NIGHTLY-2026-11-08: the Watch's backlog sat at ~820 parts "delivered, awaiting
/// acknowledgement" (Watch gauges: outstanding_files 4, awaiting_ack ≈ outbox_parts), each resent only
/// after 30 min–4 h and then acknowledged at once (phone log: acks == resends). The Watch now asks
/// which of its waiting parts the iPhone already has; the answer acknowledges those (no audio sent
/// again) and names the missing ones, which go again at once. Nothing is deleted without an ack.
@Suite struct WatchInventoryTests {
    func inbox() throws -> (PhoneWatchInbox, WatchRelayProcessor, Outbox, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-inv-\(UUID().uuidString)")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        let outbox = Outbox(dirs: dirs)
        let inbox = PhoneWatchInbox(root: root.appendingPathComponent("watch"), binding: "phone-A")
        return (inbox, WatchRelayProcessor(inbox: inbox, outbox: outbox, appVersion: "t", timezone: "UTC"), outbox, root)
    }

    func part(_ inbox: PhoneWatchInbox, _ root: URL, index: Int, recording: String, seconds: Double = 1) throws -> (WatchSegment, URL) {
        let tmp = root.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = try WatchRelayTests.segmentFile(seconds: seconds + Double(index) * 0.1, in: tmp, name: "s\(index)-\(UUID().uuidString)")
        return (WatchRelayTests().manifest(file, recording: recording, index: index, binding: "phone-A", start: Int64(index) * 1_000_000), file)
    }

    @Test func thePhoneAcknowledgesOnlyAudioItHoldsWithTheSameChecksum() throws {
        let (inbox, relay, _, root) = try inbox()
        let rec = UUID().uuidString.lowercased()
        let (m0, f0) = try part(inbox, root, index: 0, recording: rec)
        let (m1, f1) = try part(inbox, root, index: 1, recording: rec)
        try inbox.accept(file: f0, segment: m0)
        _ = relay.process()                      // converted: a receipt with its checksum remains
        try inbox.accept(file: f1, segment: m1)  // received, not converted yet
        let answer = try inbox.answer(items: [.init(id: m0.id, sha256: m0.sha256), .init(id: m1.id, sha256: m1.sha256),
                                              .init(id: "\(rec)-2", sha256: String(repeating: "a", count: 64))], binding: "phone-A")
        #expect(Set(answer.acks) == [m0.id, m1.id] && answer.missing == ["\(rec)-2"])
        let other = String(repeating: "b", count: 64)
        let conflict = try inbox.answer(items: [.init(id: m0.id, sha256: other), .init(id: m1.id, sha256: other)], binding: "phone-A")
        #expect(conflict.acks.isEmpty && Set(conflict.missing) == [m0.id, m1.id], "same id, other bytes: never acknowledged")
        #expect(throws: WatchRelayError.wrongPhone) { try inbox.answer(items: [.init(id: m0.id, sha256: m0.sha256)], binding: "phone-B") }
        #expect(WatchWire.inventory == "inventory" && WatchWire.missing == "missing", "wire keys both builds read")
    }

    @Test func syncPingReceiptsAreVerifiedPairsAndAConflictingDuplicateGetsNone() throws {
        let (inbox, relay, _, root) = try inbox()
        let rec = UUID().uuidString.lowercased()
        let (m0, f0) = try part(inbox, root, index: 0, recording: rec)
        let (m1, f1) = try part(inbox, root, index: 1, recording: rec)
        try inbox.accept(file: f0, segment: m0)
        try inbox.accept(file: f1, segment: m1)
        _ = relay.process()
        let other = String(repeating: "b", count: 64)
        let receipts = try inbox.receipts(items: [.init(id: m0.id, sha256: m0.sha256), .init(id: m0.id, sha256: m0.sha256),
                                                  .init(id: m1.id, sha256: m1.sha256), .init(id: m1.id, sha256: other)], binding: "phone-A")
        #expect(receipts == [WatchInventoryItem(id: m0.id, sha256: m0.sha256)], "one id with two checksums: no receipt for either")
        #expect(throws: WatchRelayError.wrongPhone) { try inbox.receipts(items: [.init(id: m0.id, sha256: m0.sha256)], binding: "phone-B") }
    }

    /// ASTRA-IT2-01 (blocker): a filename was taken as proof of audio, and the Watch deleted its only
    /// copy. Unreadable, absent, quarantined-without-audio and legacy receipts are "missing" now.
    @Test func noAcknowledgementWithoutMatchingAudio() throws {
        let (inbox, relay, outbox, root) = try inbox()
        let rec = UUID().uuidString.lowercased()
        let phone = root.appendingPathComponent("watch")
        func ask(_ m: WatchSegment) throws -> (acks: [String], missing: [String]) {
            try inbox.answer(items: [.init(id: m.id, sha256: m.sha256)], binding: "phone-A")
        }
        // an unreadable manifest with no audio
        let (m0, _) = try part(inbox, root, index: 0, recording: rec)
        try Data("broken-json".utf8).write(to: phone.appendingPathComponent("inbox/\(m0.id).json"))
        #expect(try ask(m0) == ([], [m0.id]))
        // a manifest whose audio is gone
        let (m1, _) = try part(inbox, root, index: 1, recording: rec)
        try WatchWire.encode(m1).write(to: phone.appendingPathComponent("inbox/\(m1.id).json"))
        #expect(try ask(m1) == ([], [m1.id]))
        // the converter failed on it: an empty done marker, no output, no audio kept
        #expect(relay.process() == 0 && outbox.pending().isEmpty)
        #expect(try ask(m1) == ([], [m1.id]))
        // a legacy done marker (converted before receipts existed): ambiguous, so missing …
        let (m2, f2) = try part(inbox, root, index: 2, recording: rec)
        try Data("123".utf8).write(to: phone.appendingPathComponent("done/\(m2.id)"))
        #expect(try ask(m2) == ([], [m2.id]))
        // … and its resend is stored again (acknowledged only once it is durably here), not waved through
        try inbox.accept(file: f2, segment: m2)
        #expect(inbox.pending().map(\.segment.id).contains(m2.id))
        #expect(try ask(m2) == ([m2.id], []))
        // a resend whose bytes differ from what is already here is refused, not acknowledged
        let (m3, f3) = try part(inbox, root, index: 3, recording: rec)
        try inbox.accept(file: f3, segment: m3)
        var other = m3; other.sha256 = String(repeating: "c", count: 64)
        #expect(throws: (any Error).self) { try inbox.accept(file: f3, segment: other) }
    }

    @Test func aKeptAsideCopyCountsOnlyIfItsAudioMatches() throws {
        let (inbox, _, _, root) = try inbox()
        let rec = UUID().uuidString.lowercased()
        let (m, f) = try part(inbox, root, index: 0, recording: rec)
        try inbox.accept(file: f, segment: m)
        inbox.quarantine(m, reason: "synthetic")   // kept aside with its audio
        #expect(try inbox.answer(items: [.init(id: m.id, sha256: m.sha256)], binding: "phone-A").acks == [m.id])
        try FileManager.default.removeItem(at: root.appendingPathComponent("watch/quarantine/\(m.id).m4a"))
        #expect(try inbox.answer(items: [.init(id: m.id, sha256: m.sha256)], binding: "phone-A").missing == [m.id])
    }

    @Test func theWatchAsksAboutDeliveredPartsAndResendsTheMissingAtOnce() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        var p = WatchResendPolicy()
        for (i, id) in ["a", "b", "c"].enumerated() {
            p.handedOver(id, now: t0.addingTimeInterval(Double(i)))
            p.delivered(id, now: t0.addingTimeInterval(Double(i) + 1))
        }
        p.handedOver("in-flight", now: t0)  // not delivered yet: not asked about
        #expect(p.inventory(limit: 2) == ["a", "b"], "delivered ones, oldest first, bounded")
        #expect(p.inventoryDue(now: t0.addingTimeInterval(10)), "never asked: due")
        p.askInventory(id: "q1", ids: ["a", "b", "c"], now: t0.addingTimeInterval(10))
        #expect(!p.due("b", now: t0.addingTimeInterval(60)))
        #expect(p.answeredInventory(id: "q1", missing: ["b"]) == ["b"])
        #expect(p.due("b", now: t0.addingTimeInterval(60)), "the iPhone doesn't have it: due at once")
        #expect(!p.inventoryDue(now: t0.addingTimeInterval(10 + 60)), "not again within the interval")
        #expect(p.inventoryDue(now: t0.addingTimeInterval(10 + WatchResendPolicy.inventoryInterval)))
        p.acknowledged(["a", "c"])
        #expect(p.inventory(limit: 10).isEmpty)
        var none = WatchResendPolicy()
        none.handedOver("x", now: t0)
        #expect(!none.inventoryDue(now: t0.addingTimeInterval(9_999)), "nothing delivered and unacknowledged: nothing to ask")
        // the saved state of an older build (no inventory fields) still decodes
        let old = try JSONSerialization.data(withJSONObject: ["entries": [:] as [String: Any]])
        #expect((try? JSONDecoder().decode(WatchResendPolicy.self, from: old)) != nil)
    }

    /// ASTRA-IT2-02: the phone answers twice (message and durable user info). A late copy of an old
    /// "missing" answer resent a part that had just been delivered again. An answer now counts once,
    /// for its own question, and only for parts not handed over since.
    @Test func anInventoryAnswerCountsOnceAndOnlyForItsQuestion() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        var p = WatchResendPolicy()
        p.handedOver("x", now: t0); p.delivered("x", now: t0)
        p.handedOver("y", now: t0); p.delivered("y", now: t0)
        p.askInventory(id: "q1", ids: ["x", "y"], now: t0)
        #expect(p.answeredInventory(id: "other", missing: ["x"]).isEmpty, "not this question's answer")
        p.handedOver("y", now: t0.addingTimeInterval(5))   // y went again meanwhile (another path)
        p.delivered("y", now: t0.addingTimeInterval(6))
        #expect(p.answeredInventory(id: "q1", missing: ["x", "y"]) == ["x"], "y was handed over since the question")
        p.handedOver("x", now: t0.addingTimeInterval(10))  // the resend of x …
        p.delivered("x", now: t0.addingTimeInterval(11))   // … is delivered
        #expect(p.answeredInventory(id: "q1", missing: ["x"]).isEmpty, "the duplicate copy of the answer changes nothing")
        #expect(!p.due("x", now: t0.addingTimeInterval(60)), "no second resend")
    }

    /// ASTRA-IT2-03: unanswered questions piled up while the iPhone was away. One is outstanding at a
    /// time (saved across relaunches); it is replaced only after `inventoryRetire`.
    @Test func oneInventoryQuestionIsOutstandingAtATime() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        var p = WatchResendPolicy()
        p.handedOver("x", now: t0); p.delivered("x", now: t0)
        p.askInventory(id: "q1", ids: ["x"], now: t0)
        for hours in 1..<6 {
            let relaunched = try JSONDecoder().decode(WatchResendPolicy.self, from: JSONEncoder().encode(p))
            #expect(!relaunched.inventoryDue(now: t0.addingTimeInterval(Double(hours) * 3600)), "still waiting for q1 (\(hours) h)")
        }
        #expect(p.inventoryDue(now: t0.addingTimeInterval(WatchResendPolicy.inventoryRetire)), "replaced after the retire time")
        #expect(p.pendingInventory?.id == "q1")
    }

    /// ASTRA-IT4-01 (blocker): the question also carried the legacy id-only list, which an older
    /// inventory-capable phone answered by filename with plain acks, and the Watch deleted its only
    /// copy. The question now carries checksummed items only, and an inventory answer retires audio
    /// only for parts whose echoed checksum matches the Watch's own copy; plain acks in it count for nothing.
    @Test func onlyAChecksumMatchedInventoryAnswerRetiresAudio() throws {
        let item = WatchInventoryItem(id: "rec-0", sha256: String(repeating: "a", count: 64))
        let question = WatchWire.inventoryQuestion(id: "q1", items: [item], binding: "phone-A")
        #expect(question[WatchWire.inventory] == nil, "no id-only list an older phone could answer by filename")
        #expect(WatchWire.inventoryItems(from: question[WatchWire.inventoryItems]) == [item] && question[WatchWire.inventoryId] as? String == "q1")
        // what deletes audio, and what doesn't, is the storage layer's rule (WatchStorageRetirementTests)
    }

    /// ASTRA-IT4-02: a failed resend dropped its entry, the retry reused the same handover count, and a
    /// late "missing" for an older question matched the newer delivery and sent it again.
    @Test func aLateAnswerNeverMatchesANewerAttemptEvenAfterAFailure() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        var p = WatchResendPolicy()
        p.handedOver("x", now: t0); p.delivered("x", now: t0)
        p.askInventory(id: "q", ids: ["x"], now: t0.addingTimeInterval(1))
        p.handedOver("x", now: t0.addingTimeInterval(1_800)); p.failed("x")    // the 30-min resend fails
        p.handedOver("x", now: t0.addingTimeInterval(1_810)); p.delivered("x", now: t0.addingTimeInterval(1_811))  // retry delivered
        var relaunched = try JSONDecoder().decode(WatchResendPolicy.self, from: JSONEncoder().encode(p))
        #expect(relaunched.answeredInventory(id: "q", missing: ["x"]).isEmpty, "q asked about an older attempt")
        #expect(!relaunched.due("x", now: t0.addingTimeInterval(1_900)), "no further submission")
    }


    /// ASTRA-IT6-01 (blocker): any message without a question id retired audio on plain acks. A build-42
    /// phone acks a resend on an empty done marker, an unreadable manifest or a manifest for other bytes,
    /// and an older inventory answer is plain acks too: the Watch deleted its only correct copy. Segment
    /// audio now goes only on a receipt naming its checksum; plain acks still retire ends and telemetry.
    @Test func plainAcksNeverRetireSegmentAudio() throws {
        let sha = String(repeating: "a", count: 64)
        // (what deletes audio is the storage layer's rule: WatchStorageRetirementTests)
        // what a current phone sends after storing a part: the unchanged acks (an older Watch reads them)
        // plus a receipt with the part's checksum
        let fields = WatchWire.acknowledgement(ids: ["rec-0", "end-1"], receipts: [.init(id: "rec-0", sha256: sha)])
        #expect(fields[WatchWire.acks] as? [String] == ["rec-0", "end-1"])
        #expect(WatchWire.inventoryItems(from: fields[WatchWire.receipts]) == [.init(id: "rec-0", sha256: sha)])
    }

    /// ASTRA-IT6-02: entries saved by build 42 have no attempt number, so a new question's "missing"
    /// answer matched nothing and the part waited 30 min–4 h. A question numbers them first.
    @Test func olderSavedEntriesGetAttemptNumbersWhenAsked() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        let legacy = #"{"entries":{"x":{"at":\#(t0.timeIntervalSinceReferenceDate),"times":2,"delivered":true}}}"#
        var p = try JSONDecoder().decode(WatchResendPolicy.self, from: Data(legacy.utf8))
        #expect(p.entries["x"]?.attempt == nil && !p.due("x", now: t0.addingTimeInterval(60)))
        p.askInventory(id: "q", ids: ["x"], now: t0.addingTimeInterval(10))
        #expect(p.entries["x"]?.attempt != nil && p.entries["x"]?.times == 2 && p.entries["x"]?.at == t0, "numbered; wait and count kept")
        var relaunched = try JSONDecoder().decode(WatchResendPolicy.self, from: JSONEncoder().encode(p))
        #expect(relaunched.answeredInventory(id: "q", missing: ["x"]) == ["x"])
        #expect(relaunched.due("x", now: t0.addingTimeInterval(60)), "sent again at once, within the window")
    }

}
