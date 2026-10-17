import Foundation
import Observation
import OmiCapture

/// One clip's sound (the app wraps AVAudioPlayer).
@MainActor
public protocol ClipAudio: AnyObject {
    var duration: Double { get }
    var currentTime: Double { get set }
    var isPlaying: Bool { get }
    var onFinish: (() -> Void)? { get set }
    func play()
    func pause()
    func stop()
}

/// Voice clips from the server, one at a time (People, Conversation speakers, Name this voice).
@MainActor
@Observable
public final class ClipPlayback {
    /// What tapping the playing clip does: stop it (list rows) or pause it (the naming card).
    public enum Tap: Sendable { case stop, pause }

    public private(set) var playing: String?
    public private(set) var loading: String?
    public private(set) var loadedId: String?
    public private(set) var message: String?
    /// The prepared clip's bytes (for a waveform).
    public private(set) var data: Data?
    public private(set) var audio: ClipAudio?
    /// The prepared clip played to its end.
    @ObservationIgnored public var onFinished: (() -> Void)?

    private let tap: Tap
    private let makeAudio: @MainActor (Data) throws -> ClipAudio
    private let activate: @MainActor () -> Void
    /// Where "another sound is starting" is announced (`.default` in the app; tests use their own).
    private let center: NotificationCenter
    private var cache: [String: Data] = [:]
    /// One request per clip, shared by every caller waiting for it.
    private var inflight: [String: Task<Data, Error>] = [:]
    /// The current intent. Stop, Close, another clip or another sound move it on; work that awaited
    /// across a change must not start audio or report anything afterwards.
    private var generation = 0
    @ObservationIgnored private var focus: NSObjectProtocol?

    public init(tap: Tap, makeAudio: @escaping @MainActor (Data) throws -> ClipAudio, activate: @escaping @MainActor () -> Void = {},
                center: NotificationCenter = .default) {
        self.tap = tap
        self.makeAudio = makeAudio
        self.activate = activate
        self.center = center
        focus = center.addObserver(forName: .omiAudioWillPlay, object: nil, queue: .main) { [weak self] note in
            let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.generation += 1  // a clip still downloading won't start over it
                self.audio?.pause()  // another sound started: one at a time
                self.playing = nil
                self.loading = nil
            }
        }
    }

    /// Prepares a clip without playing it.
    public func load(_ id: String, fetch: @escaping (String) async throws -> Data) async {
        if loadedId == id, audio != nil { return }
        if loading == id { return }  // already on its way
        let intent = begin(id)  // a different clip: the old one's intent ends here
        await prepare(id, fetch, intent: intent)
    }

    /// A new intent for `id`, taken synchronously (before any task runs): earlier work is void.
    private func begin(_ id: String) -> Int {
        stop()
        loading = id
        return generation
    }

    /// Downloads and prepares `id` for exactly `intent`; true if that intent is still current and ready.
    @discardableResult
    private func prepare(_ id: String, _ fetch: @escaping (String) async throws -> Data, intent: Int) async -> Bool {
        defer { if generation == intent, loading == id { loading = nil } }
        do {
            let bytes = try await data(id, fetch)
            guard generation == intent, !Task.isCancelled else { return false }
            try prepare(id, bytes)
            return true
        } catch {
            guard generation == intent, !Task.isCancelled else { return false }  // a closed screen's error isn't reported
            fail(error)
            return false
        }
    }

    public func toggle(_ id: String, fetch: @escaping (String) async throws -> Data) {
        if playing == id {
            if tap == .stop { stop() } else { pause() }
            return
        }
        if loadedId == id, audio != nil {
            generation += 1  // back to the prepared clip: whatever else was on its way is void
            loading = nil
            start()
            return
        }
        if loading == id { return }  // a second tap while it downloads: one request, one play
        let intent = begin(id)
        Task {
            guard await self.prepare(id, fetch, intent: intent), self.generation == intent else { return }
            self.start()
        }
    }

    public func pause() {
        audio?.pause()
        playing = nil
    }

    public func stop() {
        generation += 1
        loading = nil
        audio?.stop()
        audio?.currentTime = 0
        playing = nil
    }

    public func seek(to fraction: Double) {
        guard let audio else { return }
        audio.currentTime = fraction * audio.duration
    }

    private func data(_ id: String, _ fetch: @escaping (String) async throws -> Data) async throws -> Data {
        if let cached = cache[id] { return cached }
        if let shared = inflight[id] { return try await shared.value }
        let task = Task { try await fetch(id) }
        inflight[id] = task
        defer { inflight[id] = nil }
        let bytes = try await task.value
        cache[id] = bytes
        return bytes
    }

    private func prepare(_ id: String, _ bytes: Data) throws {
        let a = try makeAudio(bytes)
        audio?.onFinish = nil  // the retired player's late end must not touch the new one
        a.onFinish = { [weak self, weak a] in
            guard let self, let a, self.audio === a else { return }
            self.playing = nil
            self.onFinished?()
        }
        audio = a
        data = bytes
        loadedId = id
        message = nil
    }

    private func start() {
        guard let audio, let id = loadedId else { return }
        activate()
        if audio.currentTime >= audio.duration - 0.05 { audio.currentTime = 0 }
        center.post(name: .omiAudioWillPlay, object: self)
        audio.play()
        playing = id
    }

    private func fail(_ error: Error) {
        loadedId = nil  // a tap on play tries again
        audio = nil
        data = nil
        if case APIError.http(410, _) = error {
            message = "This audio has expired on the server, so it can't be played."
        } else {
            message = "Couldn't load the audio (\(error)). Tap play to try again."
        }
    }
}
