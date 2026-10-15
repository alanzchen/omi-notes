import AVFoundation
import Foundation

/// Microphone buffers → 16 kHz mono → segment files of a fixed length (`SegmentClock`), with no
/// sample lost or repeated at a boundary. Called once per input buffer, it reuses its conversion
/// buffer (grown only if a larger input arrives) and writes it straight to the file; it copies only
/// the part of a buffer that crosses into the next segment.
///
/// Not thread-safe: the caller serializes every call (`WatchCapture` holds a lock).
public final class SegmentWriter {
    public struct Finished: Sendable, Equatable {
        public var url: URL
        public var index: Int
        /// Seconds from the recording's start to the segment's first sample, and its length.
        public var start: Double
        public var seconds: Double
    }

    /// What it did, to compare builds (allocations should stay flat after the first callbacks).
    public struct Stats: Sendable, Equatable {
        public var callbacks = 0
        public var frames: Int64 = 0
        public var bufferAllocations = 0
        public var boundaryCopies = 0
        public var segments = 0
    }

    public static let rate = 16_000.0

    public static var aac: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
    }

    public let output: AVAudioFormat
    public private(set) var index: Int
    public private(set) var stats = Stats()
    private let fileSettings: [String: Any]
    private let makeURL: (Int) -> URL
    private var clock: SegmentClock
    private var converter: AVAudioConverter?
    private var converted: AVAudioPCMBuffer?
    private var part: AVAudioPCMBuffer?
    private var file: AVAudioFile?
    private var runStart: Double?
    private var runFrames: Int64 = 0
    private var segmentStartFrame: Int64 = 0

    public init(firstIndex: Int, segmentSeconds: TimeInterval, fileSettings: [String: Any] = SegmentWriter.aac, makeURL: @escaping (Int) -> URL) {
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        index = firstIndex
        clock = SegmentClock(framesPerSegment: Int(segmentSeconds * Self.rate))
        self.fileSettings = fileSettings
        self.makeURL = makeURL
    }

    /// Converts and writes one input buffer. `endedAt`: seconds from the recording's start to the end
    /// of this buffer (the first one fixes where this run starts). Returns the segments it completed.
    public func append(_ buffer: AVAudioPCMBuffer, endedAt: Double) throws -> [Finished] {
        stats.callbacks += 1
        let inRate = buffer.format.sampleRate
        if runStart == nil { runStart = endedAt - Double(buffer.frameLength) / inRate }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { throw CocoaError(.featureUnsupported) }
        let needed = AVAudioFrameCount((Double(buffer.frameLength) * Self.rate / inRate).rounded(.up)) + 64
        if converted.map({ $0.frameCapacity < needed }) ?? true {
            converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: needed)
            stats.bufferAllocations += 1
        }
        guard let converted else { throw CocoaError(.featureUnsupported) }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? CocoaError(.featureUnsupported) }

        var done: [Finished] = []
        var offset = 0
        let total = Int(converted.frameLength)
        for run in clock.split(total) {
            try write(converted, from: offset, count: run.frames, whole: offset == 0 && run.frames == total)
            offset += run.frames
            runFrames += Int64(run.frames)
            if run.closesSegment, let f = close() { done.append(f) }
        }
        stats.frames += Int64(total)
        return done
    }

    private func write(_ buffer: AVAudioPCMBuffer, from offset: Int, count: Int, whole: Bool) throws {
        guard count > 0 else { return }
        if file == nil {
            file = try AVAudioFile(forWriting: makeURL(index), settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            segmentStartFrame = runFrames
        }
        if whole {
            try file?.write(from: buffer)
            return
        }
        if offset == 0 {
            // the start of a buffer that crosses a boundary: written as a prefix, no copy
            let length = buffer.frameLength
            buffer.frameLength = AVAudioFrameCount(count)
            defer { buffer.frameLength = length }
            try file?.write(from: buffer)
            return
        }
        // the rest of a buffer that crossed a boundary is copied (once per boundary)
        if part.map({ $0.frameCapacity < AVAudioFrameCount(count) }) ?? true {
            part = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: max(AVAudioFrameCount(count), buffer.frameCapacity))
            stats.bufferAllocations += 1
        }
        guard let part else { return }
        part.frameLength = AVAudioFrameCount(count)
        part.floatChannelData![0].update(from: buffer.floatChannelData![0] + offset, count: count)
        stats.boundaryCopies += 1
        try file?.write(from: part)
    }

    /// Closes the open segment file (which finalizes it), if it has audio.
    public func close() -> Finished? {
        guard let f = file else { return nil }
        let url = f.url
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) { f.close() }
        file = nil
        let frames = runFrames - segmentStartFrame
        let done = Finished(url: url, index: index, start: (runStart ?? 0) + Double(segmentStartFrame) / Self.rate, seconds: Double(frames) / Self.rate)
        index += 1
        guard frames > 0 else { return nil }
        stats.segments += 1
        return done
    }
}
