import AVFoundation
import Foundation
import OmiWatchKit
import WatchKit
import os

let watchLog = Logger(subsystem: "dev.omi-notes.watch", category: "recording")

/// Records what the wearer starts, in 60 s segments, into the Watch's outbox. It keeps recording
/// with the wrist down or the screen off (background audio mode, user-started only); a call or Siri
/// interrupts it, and it resumes when the system allows or when the wearer taps Resume.
@MainActor
@Observable
final class WatchRecorder: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case interrupted(String)
        case failed(String)
    }

    static var segmentSeconds: TimeInterval {
        #if DEBUG
        // Simulator automation only: `-OmiWatchDebugSegmentSeconds 5` rotates segments faster.
        let v = UserDefaults.standard.double(forKey: "OmiWatchDebugSegmentSeconds")
        if v > 0 { return v }
        #endif
        return 60
    }

    private(set) var state: State = .idle
    let outbox: WatchOutbox
    let sync: WatchSync
    private let defaults = UserDefaults.standard
    private var recorder: AVAudioRecorder?
    private var rotation: Timer?
    private var current: Active?

    /// What is being recorded (kept so a terminated app can close it at the next launch).
    struct Active: Codable {
        var recordingId: String
        var binding: String
        var startedAt: Date
        var startUptime: TimeInterval
        var bootTime: Date
        var index: Int
        var segmentStartUptime: TimeInterval
        var lastAddedIndex: Int
    }

    static var deviceId: String {
        let key = "omi.watchDeviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "watch-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    init(outbox: WatchOutbox, sync: WatchSync) {
        self.outbox = outbox
        self.sync = sync
        super.init()
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.interrupted(type, resume: options.contains(.shouldResume)) }
        }
        recoverAfterTermination()
    }

    var isRecording: Bool { if case .recording = state { return true } else { return false } }
    var isActive: Bool { current != nil }

    // MARK: Start / stop

    func start() {
        watchLog.info("start requested (active: \(self.current != nil), bound: \(self.sync.binding != nil))")
        guard current == nil else { return }
        guard let binding = sync.binding else {
            state = .failed("Open Omi Notes on your iPhone once, then try again.")
            return
        }
        AVAudioApplication.requestRecordPermission { granted in
            watchLog.info("microphone permission: \(granted)")
            Task { @MainActor in
                guard granted else {
                    self.state = .failed("Microphone access is off. Allow it in Settings ▸ Privacy ▸ Microphone.")
                    return
                }
                self.begin(binding: binding)
            }
        }
    }

    private func begin(binding: String) {
        Task {
            // activating the audio session can block: not on the main thread
            let failure: String? = await Task.detached {
                do {
                    try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
                    try AVAudioSession.sharedInstance().setActive(true)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            watchLog.info("audio session active: \(failure == nil)")
            if let failure { self.state = .failed("The microphone couldn't start: \(failure)"); return }
            self.beginRecording(binding: binding)
        }
    }

    private func beginRecording(binding: String) {
        guard current == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        current = Active(recordingId: UUID().uuidString.lowercased(), binding: binding, startedAt: Date(), startUptime: now,
                         bootTime: Date().addingTimeInterval(-now), index: 0, segmentStartUptime: now, lastAddedIndex: -1)
        startSegment()
    }

    func stop() {
        guard var active = current else { state = .idle; return }
        finishSegment()
        active = current ?? active
        let end = ProcessInfo.processInfo.systemUptime
        try? outbox.add(end: WatchRecordingEnd(recordingId: active.recordingId, deviceId: Self.deviceId, binding: active.binding,
                                               lastIndex: active.lastAddedIndex, endOffsetUs: Int64((end - active.startUptime) * 1_000_000),
                                               endedAt: Date(), reason: .userStopped))
        current = nil
        persist()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        WKInterfaceDevice.current().play(.stop)
        sync.pump()
    }

    /// After an interruption the system didn't resume.
    func resume() {
        guard current != nil else { return }
        do { try AVAudioSession.sharedInstance().setActive(true) } catch {
            state = .interrupted("The microphone is still in use. Try again in a moment.")
            return
        }
        current?.index += 1
        startSegment()
    }

    // MARK: Segments

    private var segmentURL: URL? {
        guard let a = current else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(a.recordingId)-\(a.index).m4a")
    }

    #if DEBUG
    /// Simulator automation only (`-OmiWatchDebugSyntheticAudio YES`): the simulator has no working
    /// microphone here, so segments are synthesized speech-like audio; everything after the
    /// microphone (segments, outbox, transfer, relay) is the real path.
    static var syntheticAudio: Bool { UserDefaults.standard.bool(forKey: "OmiWatchDebugSyntheticAudio") }
    private var syntheticSeed = 1
    #endif

    private func startSegment() {
        guard let url = segmentURL else { return }
        #if DEBUG
        if Self.syntheticAudio {
            current?.segmentStartUptime = ProcessInfo.processInfo.systemUptime
            persist()
            state = .recording(since: current?.startedAt ?? Date())
            rotation?.invalidate()
            rotation = Timer.scheduledTimer(withTimeInterval: Self.segmentSeconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.rotate() }
            }
            return
        }
        #endif
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 32_000]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
            current?.segmentStartUptime = ProcessInfo.processInfo.systemUptime
            persist()
            state = .recording(since: current?.startedAt ?? Date())
            rotation?.invalidate()
            rotation = Timer.scheduledTimer(withTimeInterval: Self.segmentSeconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.rotate() }
            }
            if current?.index == 0 { WKInterfaceDevice.current().play(.start) }
        } catch {
            state = .failed("Recording couldn't start: \(error.localizedDescription)")
        }
    }

    private func rotate() {
        #if DEBUG
        let synthetic = Self.syntheticAudio
        #else
        let synthetic = false
        #endif
        guard current != nil, recorder != nil || synthetic else { return }
        finishSegment()
        current?.index += 1
        startSegment()
    }

    /// Closes the current file and hands it to the outbox with its timing and hash.
    private func finishSegment() {
        rotation?.invalidate()
        rotation = nil
        #if DEBUG
        if Self.syntheticAudio, let a = current, let url = segmentURL {
            let end = ProcessInfo.processInfo.systemUptime
            syntheticSeed += 1
            Self.writeSynthetic(seconds: end - a.segmentStartUptime, seed: syntheticSeed, to: url)
            add(file: url, active: a, startUptime: a.segmentStartUptime, endUptime: end)
            return
        }
        #endif
        guard let r = recorder, let a = current else { return }
        let url = r.url
        r.stop()
        recorder = nil
        let end = ProcessInfo.processInfo.systemUptime
        add(file: url, active: a, startUptime: a.segmentStartUptime, endUptime: end)
    }

    private func add(file url: URL, active a: Active, startUptime: TimeInterval, endUptime: TimeInterval) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let segment = WatchSegment(recordingId: a.recordingId, index: a.index, deviceId: Self.deviceId, deviceName: WKInterfaceDevice.current().name,
                                   binding: a.binding, recordingStartedAt: a.startedAt,
                                   startOffsetUs: Int64((startUptime - a.startUptime) * 1_000_000),
                                   endOffsetUs: Int64((endUptime - a.startUptime) * 1_000_000),
                                   bytes: data.count, sha256: WatchHash.sha256(data))
        watchLog.info("segment \(segment.index) ready: \(segment.bytes) bytes")
        do {
            try outbox.add(segmentFile: url, segment: segment)
            current?.lastAddedIndex = a.index
            persist()
            sync.pump()
        } catch {
            state = .failed("A recording segment couldn't be saved: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    private static func writeSynthetic(seconds: Double, seed: Int, to url: URL) {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(seconds, 0.1) * 16_000)) else { return }
        buffer.frameLength = buffer.frameCapacity
        var rng = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        var i = 0
        let n = Int(buffer.frameLength)
        while i < n {  // words and pauses of irregular length
            let word = Int((0.2 + next()) * 16_000), pause = Int((0.15 + 0.75 * next()) * 16_000)
            for k in 0..<min(word, n - i) {
                let t = Double(i + k) / 16_000
                buffer.floatChannelData![0][i + k] = Float(0.25 * sin(2 * .pi * (140 + 30 * sin(4.4 * t)) * t) * abs(sin(2 * .pi * 4 * t)))
            }
            i += word + pause
        }
        try? file.write(from: buffer)
    }
    #endif

    // MARK: Interruptions and termination

    private func interrupted(_ type: AVAudioSession.InterruptionType?, resume shouldResume: Bool) {
        guard current != nil else { return }
        switch type {
        case .began?:
            finishSegment()
            state = .interrupted("Paused by another app or a call.")
        case .ended?:
            if shouldResume { resume() } else { state = .interrupted("Paused. Tap Resume to continue.") }
        default:
            break
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.state = .failed("Recording stopped: \(error?.localizedDescription ?? "encoder error")") }
    }

    private func persist() {
        if let current, let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: "omi.activeRecording") } else { defaults.removeObject(forKey: "omi.activeRecording") }
    }

    /// The app was terminated while recording: keep what was written and close the recording.
    private func recoverAfterTermination() {
        guard let data = defaults.data(forKey: "omi.activeRecording"), var a = try? JSONDecoder().decode(Active.self, from: data) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(a.recordingId)-\(a.index).m4a")
        let sameBoot = abs(Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime).timeIntervalSince(a.bootTime)) < 5
        if FileManager.default.fileExists(atPath: url.path) {
            if sameBoot, let file = try? AVAudioFile(forReading: url), file.length > 0 {
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                add(file: url, active: a, startUptime: a.segmentStartUptime, endUptime: a.segmentStartUptime + seconds)
                a.lastAddedIndex = a.index
            } else {
                // unreadable (cut off mid-write) or its timing is lost: set aside, never deleted
                let kept = outbox.root.appendingPathComponent("unrecovered", isDirectory: true)
                try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: url, to: kept.appendingPathComponent(url.lastPathComponent))
            }
        }
        let last = max(a.lastAddedIndex, current?.lastAddedIndex ?? -1)
        try? outbox.add(end: WatchRecordingEnd(recordingId: a.recordingId, deviceId: Self.deviceId, binding: a.binding, lastIndex: last,
                                               endOffsetUs: Int64((a.segmentStartUptime - a.startUptime) * 1_000_000), endedAt: Date(),
                                               reason: .appRecovered))
        current = nil
        persist()
        state = .interrupted("The last recording was cut short when the app closed. It was kept.")
    }
}
