import AVFoundation
import Foundation
import Testing
@testable import OmiWatchKit

/// The Watch's capture path reuses its buffers without changing a sample, and an item the iPhone
/// hasn't acknowledged is resent rarely once delivered, never forgotten.
@Suite struct WatchPowerTests {
    static var pcm: [String: Any] { [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
                                     AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true] }

    func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("omi-segw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func read(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    @Test func reusedBuffersKeepEverySampleAcrossBoundariesAndLargerInputs() throws {
        let d = try dir()
        let w = SegmentWriter(firstIndex: 3, segmentSeconds: 0.5, fileSettings: Self.pcm) { d.appendingPathComponent("s\($0).caf") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var sent: [Float] = [], finished: [SegmentWriter.Finished] = []
        // irregular sizes; 9000 is larger than the first buffers (capacity grows once), 8000 = a whole segment
        for (k, n) in [1_000, 4_096, 9_000, 512, 9_000, 8_000, 37, 3_000].enumerated() {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { b.floatChannelData![0][i] = Float(sent.count + i) / 65_536 }  // a ramp: any reorder or reuse error shows
            sent += Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: n))
            finished += try w.append(b, endedAt: Double(sent.count) / 16_000 + Double(k) * 0)
        }
        if let last = w.close() { finished.append(last) }
        let written = try finished.flatMap { try read($0.url) }
        #expect(written == sent, "every sample once, in order")
        #expect(finished.map(\.index) == Array(3..<(3 + finished.count)))
        #expect(finished.dropLast().allSatisfy { abs($0.seconds - 0.5) < 1e-9 }, "\(finished.map(\.seconds))")
        for (a, b) in zip(finished, finished.dropFirst()) { #expect(abs(a.start + a.seconds - b.start) < 1e-9, "contiguous") }
        #expect(w.stats.bufferAllocations <= 4, "conversion buffer grown once or twice, boundary buffer once or twice: \(w.stats)")
        #expect(w.stats.boundaryCopies <= finished.count, "a copy only where a buffer crosses a boundary: \(w.stats)")
        #expect(w.stats.callbacks == 8 && w.stats.frames == Int64(sent.count))
    }

    @Test func aMicrophoneRateBecomesSixteenKilohertzAAC() throws {
        let d = try dir()
        let w = SegmentWriter(firstIndex: 0, segmentSeconds: 1) { d.appendingPathComponent("a\($0).m4a") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        var finished: [SegmentWriter.Finished] = []
        for k in 0..<30 {  // 2.56 s of 48 kHz in 4096-frame buffers
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
            b.frameLength = 4_096
            for i in 0..<4_096 { b.floatChannelData![0][i] = Float(sin(Double(k * 4_096 + i) * 2 * .pi * 300 / 48_000) * 0.3) }
            finished += try w.append(b, endedAt: Double((k + 1) * 4_096) / 48_000)
        }
        if let last = w.close() { finished.append(last) }
        #expect(finished.count == 3 && finished.prefix(2).allSatisfy { $0.seconds == 1 })
        #expect(abs(Double(w.stats.frames) - 30 * 4_096 / 3) < 64, "resampled, not dropped: \(w.stats.frames)")
        #expect(w.stats.bufferAllocations <= 2, "\(w.stats)")
        for f in finished { #expect(try AVAudioFile(forReading: f.url).length > 0) }
    }

    @Test func aDeliveredButUnacknowledgedItemIsResentRarelyAndNeverDropped() throws {
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        var p = WatchResendPolicy()
        #expect(p.due("s-0", now: t0))
        p.handedOver("s-0", now: t0)
        #expect(!p.due("s-0", now: t0.addingTimeInterval(30)))
        #expect(p.due("s-0", now: t0.addingTimeInterval(61)), "no outcome seen (e.g. a restart lost it): soon again")
        p.delivered("s-0", now: t0.addingTimeInterval(5))
        #expect(!p.due("s-0", now: t0.addingTimeInterval(10 * 60)), "delivered: no whole-file resend every few minutes")
        #expect(p.due("s-0", now: t0.addingTimeInterval(5 + 30 * 60)), "the acknowledgement was lost: recovered after 30 min")
        p.handedOver("s-0", now: t0.addingTimeInterval(1_900))
        p.delivered("s-0", now: t0.addingTimeInterval(1_905))
        #expect(!p.due("s-0", now: t0.addingTimeInterval(1_905 + 59 * 60)) && p.due("s-0", now: t0.addingTimeInterval(1_905 + 60 * 60)), "doubles")
        for _ in 0..<10 { p.handedOver("s-0", now: t0); p.delivered("s-0", now: t0) }
        #expect(p.due("s-0", now: t0.addingTimeInterval(4 * 3600)), "capped at 4 h: never stranded")

        p.handedOver("s-1", now: t0)
        p.failed("s-1")
        #expect(p.due("s-1", now: t0), "a failure is not an acknowledgement wait: due after the caller's backoff")

        // a restart keeps the waits (no burst of everything delivered) …
        let saved = try JSONEncoder().encode(p)
        var restored = try JSONDecoder().decode(WatchResendPolicy.self, from: saved)
        #expect(restored == p && !restored.due("s-0", now: t0.addingTimeInterval(60)))
        // … and acknowledged items leave it
        restored.acknowledged(["s-0"])
        restored.handedOver("gone", now: t0)
        restored.keep(only: ["s-1"])
        #expect(restored.entries.isEmpty || restored.entries.keys.allSatisfy { $0 == "s-1" })
        #expect(restored.due("s-0", now: t0), "an acknowledged id has no wait (and is no longer in the outbox to send)")
    }
}
