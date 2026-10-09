import Foundation
import Observation
import OmiProtocol

/// The audio engine behind a note's recording (AVPlayer in the app; a fake in tests).
@MainActor
public protocol RecordingEngine: AnyObject {
    /// Playback stopped on its own (a range that failed, a stall): the reason, for the screen.
    var onFailure: ((String) -> Void)? { get set }
    /// The playhead moved / playback reached the end.
    var onTime: ((Double) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    func waitUntilReady() async throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func teardown()
}

/// Play/pause/seek state for one note's recording (the app's Recording card).
///
/// Every load is one generation: leaving the note (`stop`) or a failure starts a new one and
/// cancels the old one's work, and every step after an await checks it is still current, so a late
/// reply can neither create or start a player for a note that was left nor touch a newer load. The
/// whole initial load (the recording's info and the player getting ready) has one deadline.
@MainActor
@Observable
public final class NoteRecordingController {
    public enum State: Equatable {
        case idle, loading, ready
        case failed(String)
        case unavailable(String)
    }

    public let conversationId: String
    public private(set) var state: State = .idle
    public private(set) var current: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isPlaying = false
    public private(set) var gapMarks: [Double] = []
    public private(set) var detailLine: String?

    private let fetchInfo: @MainActor () async throws -> RecordingInfo
    private let makeEngine: @MainActor (RecordingInfo) throws -> RecordingEngine
    private var engine: RecordingEngine?
    private var generation = 0
    private var work: Task<Void, Never>?
    /// Bounds the whole initial load: the info request and the player getting ready.
    public var loadTimeout: Duration = .seconds(30)

    public init(conversationId: String, fetchInfo: @escaping @MainActor () async throws -> RecordingInfo,
                makeEngine: @escaping @MainActor (RecordingInfo) throws -> RecordingEngine) {
        self.conversationId = conversationId
        self.fetchInfo = fetchInfo
        self.makeEngine = makeEngine
        focus = NotificationCenter.default.addObserver(forName: .omiAudioWillPlay, object: nil, queue: .main) { [weak self] note in
            let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self), self.isPlaying else { return }
                self.pause()  // another sound started: one at a time
            }
        }
    }

    private var focus: NSObjectProtocol?

    public func toggle() async {
        switch state {
        case .ready:
            isPlaying ? pause() : play()
        case .idle, .failed:
            if await prepare() { play() }
        case .loading, .unavailable:
            break
        }
    }

    /// True when this load (still the current one) is ready to play.
    private func prepare() async -> Bool {
        generation += 1
        let gen = generation
        defer { cancelHandlers[gen] = nil }
        let deadline = ContinuousClock.now + loadTimeout
        state = .loading
        do {
            let info = try await bounded(until: deadline, gen: gen) { [fetchInfo] in try await fetchInfo() }
            guard gen == generation else { return false }  // the note was left (or reloaded) meanwhile
            guard info.available, let total = info.durationS, total > 0 else {
                state = .unavailable(Self.unavailableMessage(info.reason))
                return false
            }
            duration = total
            gapMarks = RecordingTimeline(info).gapMarks
            let engine = try makeEngine(info)
            engine.onFailure = { [weak self, weak engine] reason in
                guard let self, let engine, self.engine === engine else { return }  // only the current player
                self.engineFailed(reason)
            }
            engine.onTime = { [weak self, weak engine] t in
                guard let self, let engine, self.engine === engine else { return }
                self.tick(t)
            }
            engine.onEnd = { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine else { return }
                self.reachedEnd()
            }
            self.engine = engine
            try await bounded(until: deadline, gen: gen) { try await engine.waitUntilReady() }
            guard gen == generation else {
                engine.teardown()  // made for a load that was abandoned
                return false
            }
            state = .ready
            return true
        } catch {
            guard gen == generation else { return false }  // a stale load's error belongs to nobody
            teardown()
            let timedOut = (error as? URLError)?.code == .timedOut
            state = .failed(timedOut ? "Loading the recording timed out." : "Couldn't load the recording (\(error)).")
            return false
        }
    }

    /// Runs `op` until it answers, the deadline passes, or this load is abandoned (then its work is
    /// cancelled and the caller sees CancellationError), whichever comes first.
    private func bounded<T: Sendable>(until deadline: ContinuousClock.Instant, gen: Int,
                                      _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            let task = Task { @MainActor in
                do { once.resume(.success(try await op())) } catch { once.resume(.failure(error)) }
            }
            work = Task { @MainActor in
                try? await Task.sleep(until: deadline)
                guard !Task.isCancelled else { return }
                task.cancel()
                once.resume(.failure(URLError(.timedOut)))
            }
            cancelHandlers[gen, default: []].append {
                task.cancel()
                once.resume(.failure(CancellationError()))
            }
        }
    }

    private var cancelHandlers: [Int: [() -> Void]] = [:]

    /// Abandons the current load: its awaits answer CancellationError now, its work is cancelled.
    private func abandon() {
        generation += 1
        work?.cancel()
        work = nil
        let handlers = cancelHandlers.values.flatMap { $0 }
        cancelHandlers = [:]
        handlers.forEach { $0() }
    }

    private func play() {
        guard let engine else { return }
        if current >= duration - 0.3 { seek(to: 0) }
        NotificationCenter.default.post(name: .omiAudioWillPlay, object: self)
        engine.play()
        isPlaying = true
    }

    public func pause() {
        engine?.pause()
        isPlaying = false
    }

    public func seek(to seconds: Double) {
        guard let engine else { return }
        let to = min(max(seconds, 0), duration)
        current = to
        engine.seek(to: to)
    }

    public func skip(by seconds: Double) { seek(to: current + seconds) }

    /// The player stopped on its own (a failed range, a stall): stop, and offer Retry (`toggle`).
    public func engineFailed(_ reason: String) {
        guard engine != nil else { return }
        abandon()
        engine?.pause()
        isPlaying = false
        teardown()
        state = .failed("Playback stopped (\(reason)). Tap Retry to try again.")
    }

    /// The engine's clock moved (periodic observer).
    public func tick(_ seconds: Double) { current = min(max(seconds, 0), duration) }

    /// The engine played to the end.
    public func reachedEnd() {
        isPlaying = false
        current = duration
    }

    /// The note was left: nothing of this load may play or change state afterwards.
    public func stop() {
        abandon()
        pause()
        teardown()
        if state == .ready || state == .loading { state = .idle }
        current = 0
    }

    private func teardown() {
        engine?.teardown()
        engine = nil
    }

    public static func unavailableMessage(_ reason: String?) -> String {
        switch reason {
        case "expired": return "This recording's audio has expired on the server, so it can't be played."
        case "no_audio": return "No audio was kept for this conversation."
        case "too_long": return "This recording is too long to play here (over 4 hours)."
        case "in_progress": return "Still recording; you can listen once it ends."
        default: return "This recording can't be played."
        }
    }
}

/// Resumes a continuation exactly once (an answer, a deadline, or an abandonment, whichever first).
@MainActor
private final class Once<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
