import AVFoundation
import Observation
import OmiBLE
import OmiCapture
import SwiftUI

/// Plays short WAV clips fetched from the server. The phone never decodes Opus: the server renders
/// clips as 16 kHz PCM WAV, downloaded with an authenticated request and played from memory.
@MainActor
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: String?
    private(set) var loading: String?
    private(set) var message: String?
    private var player: AVAudioPlayer?

    func toggle(_ clipId: String, speakers: SpeakersModel) {
        if playing == clipId {
            stop()
            return
        }
        Task { await play(clipId, speakers: speakers) }
    }

    func play(_ clipId: String, speakers: SpeakersModel) async {
        stop()
        loading = clipId
        defer { if loading == clipId { loading = nil } }
        do {
            let data = try await speakers.clip(clipId)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.play()
            player = p
            playing = clipId
            message = nil
        } catch APIError.http(410, _) {
            message = "That audio has expired on the server."
        } catch {
            message = "Couldn't play the clip: \(error)"
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
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
