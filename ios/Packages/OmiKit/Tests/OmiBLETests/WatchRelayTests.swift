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
        out.acknowledge([ma.id])
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
        again.acknowledge([mb.id])
        #expect(again.segments().map(\.segment.id) == [mc.id] && WatchOutbox(root: root.appendingPathComponent("outbox")).segments().map(\.segment.id) == [mc.id])
    }
}
