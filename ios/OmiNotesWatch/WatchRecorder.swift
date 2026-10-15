import AVFoundation
import Foundation
import OmiWatchKit
import WatchKit
import os

let watchLog = Logger(subsystem: "dev.omi-notes.watch", category: "recording")

/// Records what the wearer starts, in 60 s segments, into the Watch's outbox, until they stop it.
/// It keeps recording with the wrist down or the screen off (background audio mode, user-started
/// only). Segments are cut inside the audio stream (`WatchCapture`), so there is no gap between
/// them. A call or Siri interrupts it; it resumes when the system allows, otherwise the wearer taps
/// Resume. A Watch that fills up pauses instead of deleting anything.
@MainActor
@Observable
final class WatchRecorder: NSObject {
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

    private(set) var state: State = .idle {
        didSet {
            switch state {
            case .recording(let since): sync.recorderState = (.recording, since)
            case .interrupted, .failed: sync.recorderState = current.map { (.paused, $0.startedAt) } ?? (.idle, nil)
            case .idle: sync.recorderState = (.idle, nil)
            }
        }
    }
    let outbox: WatchOutbox
    let sync: WatchSync
    private let defaults = UserDefaults.standard
    private var capture: WatchCapture?
    private var current: Active?
    /// The recording just stopped (a segment finished right before Stop may still arrive).
    private var lastClosed: Active?

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

    let telemetry: WatchTelemetry

    init(outbox: WatchOutbox, sync: WatchSync, telemetry: WatchTelemetry) {
        self.outbox = outbox
        self.sync = sync
        self.telemetry = telemetry
        super.init()
        if let binding = sync.binding { telemetry.queue.seal(deviceId: Self.deviceId, binding: binding) }  // a previous launch's samples
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.interrupted(type, resume: options.contains(.shouldResume)) }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesReset() }
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
            sync.pump()  // asks the iPhone if it is reachable
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

    /// Activating the audio session can block: not on the main thread.
    nonisolated private static func activateSession() async -> String? {
        await Task.detached {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .default)
                // notifications and alarms don't stop the recording (calls and Siri still do)
                try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
                try session.setActive(true)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    private func begin(binding: String) {
        Task {
            let failure = await Self.activateSession()
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
        telemetry.monitorBattery(true)
        startSegment()
        perfSample("start")
    }

    func stop() {
        guard var active = current else { state = .idle; return }
        finishSegment()
        active = current ?? active
        let end = ProcessInfo.processInfo.systemUptime
        // every segment made so far, including any whose hand-over is still on its way here
        let last = max(active.lastAddedIndex, active.index - 1)
        try? outbox.add(end: WatchRecordingEnd(recordingId: active.recordingId, deviceId: Self.deviceId, binding: active.binding,
                                               lastIndex: last, endOffsetUs: Int64((end - active.startUptime) * 1_000_000),
                                               endedAt: Date(), reason: .userStopped))
        lastClosed = active
        perfSample("stopped", recordingId: active.recordingId, state: "idle", seal: true, active: active)
        telemetry.monitorBattery(false)
        current = nil
        persist()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        WKInterfaceDevice.current().play(.stop)
        sync.pump()
    }

    /// After an interruption (or a pause for storage) the system didn't end by itself.
    func resume() {
        guard current != nil, capture == nil else { return }
        Task {
            if let failure = await Self.activateSession() {
                watchLog.error("resume failed: \(failure)")
                self.state = .interrupted("The microphone is still in use. Try again in a moment.")
                return
            }
            guard self.current != nil, self.capture == nil else { return }
            self.startSegment()
            self.perfSample("resumed")
        }
    }

    // MARK: Segments

    #if DEBUG
    /// Simulator automation only (`OmiWatchDebugSyntheticAudio YES`): see `WatchCapture.synthetic`.
    static var syntheticAudio: Bool { UserDefaults.standard.bool(forKey: "OmiWatchDebugSyntheticAudio") }
    #endif

    /// Starts a run of the microphone at the current segment index.
    private func startSegment() {
        guard let a = current else { return }
        if let reason = storagePauseReason() { state = .interrupted(reason); return }
        let recordingId = a.recordingId
        let c = WatchCapture(
            firstIndex: a.index, segmentSeconds: Self.segmentSeconds, recordingStartUptime: a.startUptime,
            makeURL: { FileManager.default.temporaryDirectory.appendingPathComponent("\(recordingId)-\($0).m4a") },
            finished: { [weak self] done in Task { @MainActor in self?.captured(done, recordingId: recordingId) } },
            failed: { [weak self] why in Task { @MainActor in self?.captureFailed(why) } },
            changed: { [weak self] in Task { @MainActor in self?.inputChanged() } })
        #if DEBUG
        c.synthetic = Self.syntheticAudio
        #endif
        do {
            try c.start()
            capture = c
            current?.segmentStartUptime = ProcessInfo.processInfo.systemUptime
            persist()
            state = .recording(since: a.startedAt)
            if a.index == 0 { WKInterfaceDevice.current().play(.start) }
            watchLog.info("capture started at segment \(a.index)")
        } catch {
            watchLog.error("capture didn't start: \(error.localizedDescription)")
            state = .interrupted("Paused: the microphone couldn't start (\(error.localizedDescription)). Tap Resume to try again.")
        }
    }

    /// A segment the capture finished (rotation, interruption or stop).
    private func captured(_ done: WatchCapture.Finished, recordingId: String) {
        // a rotation just before Stop can arrive after it: the recording is closed, the audio still kept
        guard let a = current?.recordingId == recordingId ? current : lastClosed, a.recordingId == recordingId else { return }
        add(file: done.url, active: a, index: done.index, start: done.start, seconds: done.seconds)
        sync.captureStats = captureCounters()
        guard current?.recordingId == recordingId else { return }
        current?.index = max(a.index, done.index + 1)
        current?.segmentStartUptime = a.startUptime + done.start + done.seconds
        persist()
        perfSample("periodic")
        if capture != nil, let reason = storagePauseReason() {
            watchLog.error("pausing: \(reason)")
            finishSegment()
            state = .interrupted(reason)
            perfSample("paused")
        }
    }

    /// The audio input was reconfigured (the engine stopped itself): keep what was recorded and
    /// start a new run right away; if that isn't allowed, it shows as paused.
    private func inputChanged() {
        guard capture != nil else { return }
        watchLog.info("audio input changed: restarting")
        finishSegment()
        startSegment()
    }

    private func captureFailed(_ why: String) {
        guard capture != nil else { return }
        watchLog.error("capture failed: \(why)")
        finishSegment()
        state = .interrupted("Paused: \(why). Tap Resume to try again.")
        perfSample("failed")
    }

    private func storagePauseReason() -> String? {
        let free = (try? outbox.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
        return WatchStorage.pauseReason(freeBytes: free.map(Int64.init), waitingBytes: outbox.waitingBytes)
    }

    /// Ends the current run and hands its open segment to the outbox.
    private func finishSegment() {
        guard let c = capture, let a = current else { return }
        capture = nil
        let last = c.stop()
        captureTotals.add(c.stats)
        if let last { add(file: last.url, active: a, index: last.index, start: last.start, seconds: last.seconds) }
        current?.index = c.currentIndex
        current?.segmentStartUptime = ProcessInfo.processInfo.systemUptime
        persist()
    }

    private func add(file url: URL, active a: Active, index: Int, start: Double, seconds: Double) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let segment = WatchSegment(recordingId: a.recordingId, index: index, deviceId: Self.deviceId, deviceName: WKInterfaceDevice.current().name,
                                   binding: a.binding, recordingStartedAt: a.startedAt,
                                   startOffsetUs: Int64(start * 1_000_000), endOffsetUs: Int64((start + seconds) * 1_000_000),
                                   bytes: data.count, sha256: WatchHash.sha256(data))
        watchLog.info("segment \(segment.index) ready: \(segment.bytes) bytes, \(seconds, format: .fixed(precision: 3)) s from \(start, format: .fixed(precision: 3)) s")
        encodedBytes += data.count
        do {
            try outbox.add(segmentFile: url, segment: segment)
            if let c = current, c.recordingId == a.recordingId { current?.lastAddedIndex = max(c.lastAddedIndex, index) }
            persist()
            sync.pump()
        } catch {
            state = .failed("A recording segment couldn't be saved: \(error.localizedDescription)")
        }
    }

    // MARK: Performance samples

    /// Capture work so far in this app launch (finished runs plus the running one).
    private var captureTotals = SegmentWriter.Stats()
    private var encodedBytes = 0

    private func captureCounters() -> [String: Int] {
        var s = captureTotals
        if let c = capture?.stats { s.add(c) }
        return ["callbacks": s.callbacks, "buffer_allocations": s.bufferAllocations, "boundary_copies": s.boundaryCopies,
                "segments": s.segments, "captured_ms": Int(s.frames / 16), "append_ms": Int(s.appendMicros / 1_000),
                "encoded_bytes": encodedBytes]
    }

    /// One sample now (periodic ones at most every 5 min); `state` defaults to what the recorder shows.
    /// `active`: the recording (defaults to the current one), for its monotonic start.
    private func perfSample(_ event: String, recordingId: String? = nil, state: String? = nil, seal: Bool = false, active: Active? = nil) {
        let a = active ?? current
        let now = ProcessInfo.processInfo.systemUptime
        let sameBoot = a.map { abs(Date().addingTimeInterval(-now).timeIntervalSince($0.bootTime)) < 5 } ?? false
        let mono = sameBoot ? a.map { now - $0.startUptime } : nil
        let shown: String
        switch self.state {
        case .recording: shown = "recording"
        case .interrupted, .failed: shown = current == nil ? "idle" : "paused"
        case .idle: shown = "idle"
        }
        telemetry.sample(event, state: state ?? shown, recordingId: recordingId ?? a?.recordingId, mono: mono,
                         counters: sync.counters.merging(captureCounters()) { a, _ in a },
                         gauges: ["outbox_parts": sync.pending, "awaiting_ack": sync.awaitingAck], binding: sync.binding,
                         seal: seal || event == "paused" || event == "failed" || event == "interrupted")
    }

    // MARK: Interruptions and termination

    private func interrupted(_ type: AVAudioSession.InterruptionType?, resume shouldResume: Bool) {
        guard current != nil else { return }
        switch type {
        case .began?:
            guard capture != nil else { return }  // already paused
            finishSegment()
            perfSample("interrupted")
            state = .interrupted("Paused by another app or a call.")
        case .ended?:
            if shouldResume { resume() } else { state = .interrupted("Paused. Tap Resume to continue.") }
        default:
            break
        }
    }

    /// The system's audio service restarted: the microphone is gone until set up again, which only
    /// the wearer may ask for.
    private func mediaServicesReset() {
        guard current != nil else { return }
        watchLog.error("media services were reset")
        finishSegment()
        perfSample("interrupted")
        state = .interrupted("Paused: the Watch's audio restarted. Tap Resume to continue.")
    }

    private func persist() {
        if let current, let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: "omi.activeRecording") } else { defaults.removeObject(forKey: "omi.activeRecording") }
    }

    /// The app was terminated while recording: keep what was written and close the recording.
    private func recoverAfterTermination() {
        guard let data = defaults.data(forKey: "omi.activeRecording"), var a = try? JSONDecoder().decode(Active.self, from: data) else { return }
        let sameBoot = abs(Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime).timeIntervalSince(a.bootTime)) < 5
        // the open segment, and the next one if a rotation hadn't been recorded yet
        var start = a.segmentStartUptime - a.startUptime, setAside = false
        for index in a.index...(a.index + 1) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(a.recordingId)-\(index).m4a")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // after a segment set aside, a later one is set aside too (the phone seals only a recording without holes)
            if !setAside, sameBoot, let file = try? AVAudioFile(forReading: url), file.length > 0 {
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                add(file: url, active: a, index: index, start: start, seconds: seconds)
                a.lastAddedIndex = index
                start += seconds
            } else {
                // unreadable (cut off mid-write) or its timing is lost: set aside, never deleted
                setAside = true
                let kept = outbox.root.appendingPathComponent("unrecovered", isDirectory: true)
                try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: url, to: kept.appendingPathComponent(url.lastPathComponent))
            }
        }
        let last = max(a.lastAddedIndex, current?.lastAddedIndex ?? -1)
        try? outbox.add(end: WatchRecordingEnd(recordingId: a.recordingId, deviceId: Self.deviceId, binding: a.binding, lastIndex: last,
                                               endOffsetUs: Int64((a.segmentStartUptime - a.startUptime) * 1_000_000), endedAt: Date(),
                                               reason: .appRecovered))
        perfSample("recovered", recordingId: a.recordingId, state: "idle", seal: true, active: a)
        current = nil
        persist()
        state = .interrupted("The app closed during a recording. What was recorded is kept.")
    }
}
