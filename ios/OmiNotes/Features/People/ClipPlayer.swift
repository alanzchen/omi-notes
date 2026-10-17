import AVFoundation
import Observation
import OmiBLE
import OmiCapture
import SwiftUI

/// AVAudioPlayer behind `ClipPlayback` (OmiKit holds the play/stop/close logic and its tests).
@MainActor
final class AVClipAudio: NSObject, ClipAudio, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?
    init(_ data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }
    var duration: Double { player.duration }
    var currentTime: Double { get { player.currentTime } set { player.currentTime = newValue } }
    var isPlaying: Bool { player.isPlaying }
    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }

    /// Before a clip starts (then it announces `omiAudioWillPlay`, so a playing note gives up the session).
    static func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

/// Plays short WAV clips fetched from the server. The phone never decodes Opus: the server renders
/// clips as 16 kHz PCM WAV, downloaded with an authenticated request and played from memory.
@MainActor
@Observable
final class ClipPlayer {
    private let core = ClipPlayback(tap: .stop, makeAudio: { try AVClipAudio($0) }, activate: AVClipAudio.activateSession)
    var playing: String? { core.playing }
    var loading: String? { core.loading }
    var message: String? { core.message }

    func toggle(_ clipId: String, speakers: SpeakersModel) {
        core.toggle(clipId) { try await speakers.clip($0) }
    }

    /// Back / Close: also cancels a clip that is still downloading.
    func stop() { core.stop() }
}

struct PlayButton: View {
    let clipId: String?
    let player: ClipPlayer
    let speakers: SpeakersModel

    var body: some View {
        if let clipId {
            Button {
                player.toggle(clipId, speakers: speakers)
            } label: {
                if player.loading == clipId {
                    ProgressView()
                } else {
                    Image(systemName: player.playing == clipId ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.playing == clipId ? "Stop clip" : "Play clip")
        } else {
            Image(systemName: "speaker.slash").foregroundStyle(.tertiary)
                .accessibilityLabel("No audio available")
        }
    }
}
