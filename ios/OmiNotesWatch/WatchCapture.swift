import AVFoundation
import Foundation
import OmiWatchKit

/// The microphone, as 16 kHz mono AAC files of a fixed length. Files are rotated inside the audio
/// stream (`SegmentClock`): the microphone never stops between segments, so no audio falls between
/// two of them. One instance per run; an interruption ends the run and a new one starts after it.
///
/// Conversion and file writing are `SegmentWriter` (buffers reused across callbacks). The input
/// tap is called on an audio thread; everything it touches is behind `lock`.
final class WatchCapture: @unchecked Sendable {
    typealias Finished = SegmentWriter.Finished

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let writer: SegmentWriter
    private let finished: @Sendable (Finished) -> Void
    private let failed: @Sendable (String) -> Void
    private let changed: @Sendable () -> Void
    private var observer: (any NSObjectProtocol)?
    private let recordingStartUptime: TimeInterval
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
        writer = SegmentWriter(firstIndex: firstIndex, segmentSeconds: segmentSeconds, makeURL: makeURL)
        self.recordingStartUptime = recordingStartUptime
        self.finished = finished
        self.failed = failed
        self.changed = changed
    }

    /// The index of the segment being written (the next to be finished).
    var currentIndex: Int { lock.lock(); defer { lock.unlock() }; return writer.index }

    /// What the writer has done so far (allocations, boundary copies), for the Watch's report.
    var stats: SegmentWriter.Stats { lock.lock(); defer { lock.unlock() }; return writer.stats }

    func start() throws {
        #if DEBUG
        if synthetic { startFeed(); return }
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, AVAudioConverter(from: format, to: writer.output) != nil else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "no microphone input is available"])
        }
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
        return writer.close()
    }

    /// Synchronous: the buffer is used only until this returns.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        do {
            for done in try writer.append(buffer, endedAt: ProcessInfo.processInfo.systemUptime - recordingStartUptime) { finished(done) }
        } catch {
            failed("a recording segment couldn't be written (\(error.localizedDescription))")
        }
    }

    #if DEBUG
    private func startFeed() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
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
