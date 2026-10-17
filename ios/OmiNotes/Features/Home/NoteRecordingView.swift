import AVFoundation
import Observation
import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

/// The note's recording, inline in its detail: play/pause, seek, ±15 s, current/total time. Nothing
/// is fetched or played until play is tapped; then the audio streams in byte ranges (the token
/// stays in a request header), so a long note starts quickly and seeks without a full download.
struct NoteRecordingSection: View {
    let model: AppModel
    let entry: ConversationSummary
    /// Owned by the note's detail, so a highlight can cue it.
    let player: NoteRecordingController
    @State private var scrubbing: Double?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    playButton
                    VStack(spacing: 2) {
                        slider
                        HStack {
                            Text(Self.clock(scrubbing ?? player.current)).monospacedDigit()
                            Spacer()
                            Text(totalLabel).monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 28) {
                    Spacer()
                    Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title3) }
                        .accessibilityLabel("Back 15 seconds")
                    Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.title3) }
                        .accessibilityLabel("Forward 15 seconds")
                    Spacer()
                }
                .buttonStyle(.borderless).disabled(player.state != .ready)
                status
            }
            .padding(.vertical, 4)
        } header: {
            Text("Recording")
        }
    }

    private var playButton: some View {
        Button { Task { await player.toggle() } } label: {
            ZStack {
                Circle().fill(playable ? Color.accentColor : Color(.systemGray4)).frame(width: 46, height: 46)
                if player.state == .loading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!playable || player.state == .loading)
        .accessibilityLabel(player.state == .loading ? "Loading the recording" : player.isPlaying ? "Pause the recording" : "Play the recording")
    }

    private var playable: Bool {
        if case .unavailable = player.state { return false }
        return true
    }

    private var slider: some View {
        ZStack(alignment: .leading) {
            Slider(value: .init(get: { scrubbing ?? player.current }, set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 0.1)) { editing in
                if !editing, let to = scrubbing {
                    player.seek(to: to)
                    scrubbing = nil
                }
            }
            .disabled(player.state != .ready)
            .accessibilityLabel("Position in the recording")
            .accessibilityValue(Self.clock(player.current))
            // where time wasn't recorded, so the jump in the clock is visible
            GeometryReader { geo in
                ForEach(Array(player.gapMarks.enumerated()), id: \.offset) { _, mark in
                    Rectangle().fill(Color.orange).frame(width: 2, height: 10)
                        .offset(x: mark * geo.size.width - 1, y: geo.size.height / 2 - 5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var totalLabel: String {
        player.duration > 0 ? Self.clock(player.duration) : (Fmt.duration(entry.duration).map { "~\($0)" } ?? "—:—")
    }

    @ViewBuilder private var status: some View {
        switch player.state {
        case .idle:
            if let cue = player.cueNote {
                Label(cue, systemImage: "sparkles").font(.caption).foregroundStyle(ValueStyle.recommended)
            } else {
                Text("Tap play to listen. The audio stays on your server and streams as you play.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .loading:
            Text("Loading the recording…").font(.caption).foregroundStyle(.secondary)
        case .ready:
            if let cue = player.cueNote { Text(cue).font(.caption).foregroundStyle(.secondary) }
            if let line = player.detailLine { Text(line).font(.caption).foregroundStyle(.secondary) }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry") { Task { await player.toggle() } }.font(.caption.weight(.semibold))
            }
        case .unavailable(let message):
            Label(message, systemImage: "waveform.slash").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// AVPlayer behind a note's recording (`RecordingEngine`): streams through `RecordingLoader`, and
/// reports a failed range, a failed item or a stall as a failure instead of looking "playing".
@MainActor
final class AVRecordingEngine: RecordingEngine {
    var onFailure: ((String) -> Void)?
    var onTime: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onPausedBySystem: (() -> Void)?
    static let stallLimit: Duration = .seconds(15)

    private let player: AVPlayer
    private let item: AVPlayerItem
    private let loader: RecordingLoader
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private var playing = false
    private var session = AudioSessionOwnership()

    init(api: APIClient, conversationId: String) {
        loader = RecordingLoader(api: api, conversationId: conversationId)
        let asset = AVURLAsset(url: URL(string: "omi-recording://note/\(conversationId).wav")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        loader.onError = { [weak self] message in
            Task { @MainActor in self?.fail("couldn't get the audio from the server: \(message)") }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail("the audio stopped arriving") }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playing = false
                self.apply(.end)
                self.onEnd?()
            }
        })
        // A call, another app's audio, or the headphones going away pause AVPlayer by itself: say so.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated { if began { self?.pausedBySystem(.interrupted) } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let lost = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable
            MainActor.assumeIsolated { if lost { self?.pausedBySystem(.outputLost) } }
        })
        // posted before any in-app player starts (this note's own controller included, before play())
        observers.append(center.addObserver(forName: .omiAudioWillPlay, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relinquishSession() }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.onTime?(time.seconds) }
        }
    }

    func waitUntilReady() async throws {
        while true {  // bounded and cancelled by the controller
            switch item.status {
            case .readyToPlay: return
            case .failed: throw item.error ?? URLError(.cannotDecodeContentData)
            default: try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        apply(.play)
        player.play()
        playing = true
        watch()
    }

    func pause() {
        player.pause()
        playing = false
        watchdog?.cancel()
        apply(.pause)
    }

    /// Also from the controller before it pauses for another player (independent of observer order).
    func relinquishSession() { apply(.otherAudioStarting) }

    private func pausedBySystem(_ why: AudioSessionOwnership.Event) {
        guard playing else { return }
        player.pause()
        playing = false
        watchdog?.cancel()
        apply(why)
        onPausedBySystem?()
    }

    /// Deactivates the session only when this player activated it and still holds it, letting other
    /// audio (music, podcasts) resume.
    private func apply(_ event: AudioSessionOwnership.Event) {
        if session.handle(event) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        apply(.teardown)
        playing = false
        watchdog?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player.replaceCurrentItem(with: nil)
        loader.onError = nil
        loader.cancelAll()
    }

    /// While it should be playing: a failed item, or waiting for data longer than the limit, is a failure.
    private func watch() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var waiting: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.playing else { return }
                if self.item.status == .failed {
                    self.fail(self.item.error.map { "\($0.localizedDescription)" } ?? "the player failed")
                    return
                }
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    let since = waiting ?? ContinuousClock.now
                    waiting = since
                    if ContinuousClock.now - since > Self.stallLimit {
                        self.fail("no audio arrived for \(Self.stallLimit.components.seconds) s")
                        return
                    }
                } else {
                    waiting = nil
                }
            }
        }
    }

    private func fail(_ reason: String) {
        onFailure?(reason)
    }
}

/// Feeds AVPlayer the recording's WAV in byte ranges through the authenticated API client.
final class RecordingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "omi.recording.loader")
    private let api: APIClient
    private let conversationId: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static let piece = 256 * 1024
    /// A range that failed while the player needed it (not a cancelled one).
    var onError: ((String) -> Void)?

    init(api: APIClient, conversationId: String) {
        self.api = api
        self.conversationId = conversationId
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let box = RequestBox(request)
        let key = ObjectIdentifier(request)
        let api = api, id = conversationId
        tasks[key] = Task { [weak self] in
            do {
                if let info = box.request.contentInformationRequest {
                    let (_, total) = try await api.recordingBytes(id, offset: 0, length: 2)
                    info.contentType = "com.microsoft.waveform-audio"
                    info.contentLength = total ?? 0
                    info.isByteRangeAccessSupported = true
                }
                if let data = box.request.dataRequest {
                    var offset = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
                    let end: Int64? = data.requestsAllDataToEndOfResource ? nil : data.requestedOffset + Int64(data.requestedLength)
                    while !Task.isCancelled {
                        let want = end.map { Int(min(Int64(Self.piece), $0 - offset)) } ?? Self.piece
                        if want <= 0 { break }
                        let (bytes, total) = try await api.recordingBytes(id, offset: offset, length: want)
                        if bytes.isEmpty { break }
                        data.respond(with: bytes)
                        offset += Int64(bytes.count)
                        if let total, offset >= total { break }
                    }
                }
                if !Task.isCancelled { box.request.finishLoading() }
            } catch {
                if !Task.isCancelled {
                    box.request.finishLoading(with: error)
                    if !(error is CancellationError) { self?.onError?("\(error)") }
                }
            }
            if let owner = self { owner.queue.async { owner.tasks[key] = nil } }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    /// The note was left: no range keeps loading for it.
    func cancelAll() {
        queue.async { [self] in
            tasks.values.forEach { $0.cancel() }
            tasks = [:]
        }
    }
}

/// AVAssetResourceLoadingRequest isn't Sendable; it is only touched from the loader's work.
private final class RequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}
