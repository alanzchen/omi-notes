import AVFoundation
import Foundation
import OmiWatchKit

/// The microphone, as 16 kHz mono AAC files of a fixed length. Files are rotated inside the audio
/// stream (`SegmentClock`): the microphone never stops between segments, so no audio falls between
/// two of them. One instance per run; an interruption ends the run and a new one starts after it.
///
/// The input tap is called on an audio thread; everything it touches is behind `lock`.
final class WatchCapture: @unchecked Sendable {
    struct Finished: Sendable {
        var url: URL
        var index: Int
        /// Seconds from the recording's start (Watch uptime) to the segment's first sample, and its length.
        var start: Double
        var seconds: Double
    }

    static let rate = 16_000.0
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let makeURL: @Sendable (Int) -> URL
    private let finished: @Sendable (Finished) -> Void
    private let failed: @Sendable (String) -> Void
    private let changed: @Sendable () -> Void
    private var observer: (any NSObjectProtocol)?
    private let recordingStartUptime: TimeInterval
    private var clock: SegmentClock
    private var index: Int
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var output: AVAudioFormat?
    /// Seconds from the recording's start to this run's first sample; frames of the run so far, and
    /// at which of them the open segment began.
    private var runStart: Double?
    private var runFrames: Int64 = 0
    private var segmentStartFrame: Int64 = 0
    private var stopped = false
    #if DEBUG
    /// Simulator automation only (`OmiWatchDebugSyntheticAudio`): the simulator has no microphone
    /// input, so a speech-like signal is fed in real time instead; conversion, rotation and file
    /// writing are the real path.
    var synthetic = false
    private var feed: DispatchSourceTimer?
    private var fedFrames = 0, feedStart = 0.0, wordLeft = 0, pauseLeft = 0, rng: UInt64 = 0x9e3779b97f4a7c15
    #endif

    init(firstIndex: Int, segmentSeconds: TimeInterval, recordingStartUptime: TimeInterval,
         makeURL: @escaping @Sendable (Int) -> URL, finished: @escaping @Sendable (Finished) -> Void,
         failed: @escaping @Sendable (String) -> Void, changed: @escaping @Sendable () -> Void) {
        index = firstIndex
        clock = SegmentClock(framesPerSegment: Int(segmentSeconds * Self.rate))
        self.recordingStartUptime = recordingStartUptime
        self.makeURL = makeURL
        self.finished = finished
        self.failed = failed
        self.changed = changed
    }

    /// The index of the segment being written (the next to be finished).
    var currentIndex: Int { lock.lock(); defer { lock.unlock() }; return index }

    func start() throws {
        #if DEBUG
        if synthetic { startFeed(); return }
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "no microphone input is available"])
        }
        self.converter = converter
        output = target
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.changed()
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Ends the run. Returns the open segment, closed, if it has audio (segments finished earlier
    /// went to `finished`); the next segment index is `currentIndex`.
    func stop() -> Finished? {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        #if DEBUG
        feed?.cancel()
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        stopped = true
        return closeSegment()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let converter, let output else { return }
        if runStart == nil {
            // the first buffer ended about now
            runStart = ProcessInfo.processInfo.systemUptime - recordingStartUptime - Double(buffer.frameLength) / buffer.format.sampleRate
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            failed("audio conversion failed (\(error?.localizedDescription ?? "unknown error"))")
            return
        }
        var offset = 0
        for run in clock.split(Int(converted.frameLength)) {
            write(converted, from: offset, count: run.frames)
            offset += run.frames
            runFrames += Int64(run.frames)
            if run.closesSegment, let done = closeSegment() { finished(done) }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, from offset: Int, count: Int) {
        guard count > 0, let output else { return }
        do {
            if file == nil {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
                                               AVEncoderBitRateKey: 32_000]
                file = try AVAudioFile(forWriting: makeURL(index), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                segmentStartFrame = runFrames
            }
            guard let part = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(count)) else { return }
            part.frameLength = AVAudioFrameCount(count)
            part.floatChannelData![0].update(from: buffer.floatChannelData![0] + offset, count: count)
            try file?.write(from: part)
        } catch {
            failed("a recording segment couldn't be written (\(error.localizedDescription))")
        }
    }

    /// Closes the open file (which finalizes it). Called with `lock` held.
    private func closeSegment() -> Finished? {
        guard let f = file else { return nil }
        let url = f.url
        if #available(watchOS 11.0, *) { f.close() }
        file = nil
        let frames = runFrames - segmentStartFrame
        let done = Finished(url: url, index: index, start: (runStart ?? 0) + Double(segmentStartFrame) / Self.rate,
                            seconds: Double(frames) / Self.rate)
        index += 1
        return frames > 0 ? done : nil
    }

    #if DEBUG
    private func startFeed() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)
        converter = output.flatMap { AVAudioConverter(from: format, to: $0) }
        feedStart = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.omi-notes.watch.synthetic-mic"))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.feedTick(format) }
        feed = timer
        timer.resume()
    }

    /// Words and pauses of irregular length, delivered at the real rate in uneven buffers.
    private func feedTick(_ format: AVAudioFormat) {
        let due = Int((ProcessInfo.processInfo.systemUptime - feedStart) * format.sampleRate) - fedFrames
        guard due > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(due)) else { return }
        func next() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        buffer.frameLength = AVAudioFrameCount(due)
        let out = buffer.floatChannelData![0]
        for k in 0..<due {
            if wordLeft == 0 && pauseLeft == 0 {
                wordLeft = Int((0.2 + next()) * format.sampleRate)
                pauseLeft = Int((0.15 + 0.75 * next()) * format.sampleRate)
            }
            let t = Double(fedFrames + k) / format.sampleRate
            if wordLeft > 0 {
                out[k] = Float(0.25 * sin(2 * .pi * (140 + 30 * sin(4.4 * t)) * t) * abs(sin(2 * .pi * 4 * t)))
                wordLeft -= 1
            } else {
                out[k] = 0
                pauseLeft -= 1
            }
        }
        fedFrames += due
        consume(buffer)
    }
    #endif
}
