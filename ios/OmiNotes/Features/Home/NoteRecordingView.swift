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
    @State private var player: NoteRecordingPlayer
    @State private var scrubbing: Double?

    init(model: AppModel, entry: ConversationSummary) {
        self.model = model
        self.entry = entry
        _player = State(initialValue: NoteRecordingPlayer(conversationId: entry.id))
    }

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
        .onDisappear { player.stop() }
    }

    private var playButton: some View {
        Button { Task { await player.toggle(model: model) } } label: {
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
        .accessibilityLabel(player.isPlaying ? "Pause the recording" : "Play the recording")
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
            Text("Tap play to listen. The audio stays on your server and streams as you play.")
                .font(.caption).foregroundStyle(.secondary)
        case .loading:
            Text("Loading the recording…").font(.caption).foregroundStyle(.secondary)
        case .ready:
            if let line = player.detailLine { Text(line).font(.caption).foregroundStyle(.secondary) }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Retry") { Task { await player.toggle(model: model) } }.font(.caption.weight(.semibold))
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

@MainActor
@Observable
final class NoteRecordingPlayer {
    enum State: Equatable {
        case idle, loading, ready
        case failed(String)
        case unavailable(String)
    }

    let conversationId: String
    private(set) var state: State = .idle
    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var gapMarks: [Double] = []
    private(set) var detailLine: String?
    private var timeline: RecordingTimeline?
    private var player: AVPlayer?
    private var loader: RecordingLoader?
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    static let loadTimeout: Duration = .seconds(25)

    init(conversationId: String) {
        self.conversationId = conversationId
        observers.append(NotificationCenter.default.addObserver(forName: .omiAudioWillPlay, object: nil, queue: .main) { [weak self] note in
            let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.pause()  // another sound started: one at a time
            }
        })
    }

    func toggle(model: AppModel) async {
        switch state {
        case .ready:
            isPlaying ? pause() : play()
        case .idle, .failed:
            await prepare(model: model)
            if state == .ready { play() }
        case .loading, .unavailable:
            break
        }
    }

    private func prepare(model: AppModel) async {
        state = .loading
        do {
            let api = try model.recordingClient()
            let info = try await api.recordingInfo(conversationId)
            guard info.available, let total = info.durationS, total > 0 else {
                state = .unavailable(Self.unavailableMessage(info.reason))
                return
            }
            let timeline = RecordingTimeline(info)
            self.timeline = timeline
            duration = total
            gapMarks = timeline.gapMarks
            let gaps = info.gaps ?? []
            if let span = info.span, !gaps.isEmpty {
                let missing = gaps.reduce(0) { $0 + $1.seconds }
                let secs = Int(missing.rounded())
                detailLine = "Playable \(NoteRecordingSection.clock(total)) of \(NoteRecordingSection.clock(span.seconds)): "
                    + (gaps.count == 1 ? "a gap of \(secs) s wasn't recorded." : "\(gaps.count) gaps (\(secs) s in all) weren't recorded.")
            }
            let loader = RecordingLoader(api: api, conversationId: conversationId)
            self.loader = loader
            let asset = AVURLAsset(url: URL(string: "omi-recording://note/\(conversationId).wav")!)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            try await waitUntilReady(item)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.current = min(max(time.seconds, 0), self.duration)
                    if let p = self.player, p.timeControlStatus == .paused, self.isPlaying, self.current >= self.duration - 0.3 {
                        self.isPlaying = false  // reached the end
                    }
                }
            }
            state = .ready
        } catch is CancellationError {
            state = .idle
        } catch APIError.http(404, _) {
            state = .unavailable("This conversation isn't on the server anymore.")
        } catch {
            teardown()
            state = .failed("Couldn't load the recording (\(Self.describe(error))).")
        }
    }

    /// Bounded: a player that never becomes ready is a failure with Retry, not a spinner forever.
    private func waitUntilReady(_ item: AVPlayerItem) async throws {
        let deadline = ContinuousClock.now + Self.loadTimeout
        while ContinuousClock.now < deadline {
            switch item.status {
            case .readyToPlay: return
            case .failed: throw item.error ?? URLError(.cannotDecodeContentData)
            default: try await Task.sleep(for: .milliseconds(150))
            }
        }
        throw URLError(.timedOut)
    }

    private func play() {
        guard let player else { return }
        NotificationCenter.default.post(name: .omiAudioWillPlay, object: self)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        if current >= duration - 0.3 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let to = min(max(seconds, 0), duration)
        current = to
        player.seek(to: CMTime(seconds: to, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: current + seconds) }

    func stop() {
        pause()
        teardown()
        if state == .ready || state == .loading { state = .idle }
        current = 0
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader = nil
    }

    static func unavailableMessage(_ reason: String?) -> String {
        switch reason {
        case "expired": return "This recording's audio has expired on the server, so it can't be played."
        case "no_audio": return "No audio was kept for this conversation."
        case "too_long": return "This recording is too long to play here (over 4 hours)."
        case "in_progress": return "Still recording; you can listen once it ends."
        default: return "This recording can't be played."
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError, e.code == .timedOut { return "timed out" }
        return "\(error)"
    }
}

/// Feeds AVPlayer the recording's WAV in byte ranges through the authenticated API client.
final class RecordingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "omi.recording.loader")
    private let api: APIClient
    private let conversationId: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static let piece = 256 * 1024

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
                if !Task.isCancelled { box.request.finishLoading(with: error) }
            }
            if let owner = self { owner.queue.async { owner.tasks[key] = nil } }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
}

/// AVAssetResourceLoadingRequest isn't Sendable; it is only touched from the loader's work.
private final class RequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}
