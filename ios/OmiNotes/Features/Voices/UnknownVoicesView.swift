import OmiBLE
import OmiProtocol
import SwiftUI

/// Voices that keep appearing and nobody named (the server's suggestions, opt-in). 命名 opens the
/// existing "Name this voice" flow (assign, keep unknown, undo); 忽略 hides one for 7 days.
struct UnknownVoicesView: View {
    @Bindable var model: AppModel
    @State private var player = VoicePlayer()
    @State private var run: ConversationSpeakersView.NamingRun?
    @State private var picking: SpeakerSuggestion?

    private var speakers: SpeakersModel { model.speakers }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(speakers.suggestions) { card($0) }
                if speakers.suggestions.isEmpty {
                    Text("没有反复出现的陌生声音").font(.subheadline).foregroundStyle(.secondary).padding(.top, 40)
                } else {
                    Text("忽略的声音 7 天内不再询问。").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = speakers.error ?? player.unavailable {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("陌生声音")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .fullScreenCover(item: $run, onDismiss: { Task { await speakers.refresh() } }) { r in
            NameVoiceView(model: model, items: r.items)
        }
        .sheet(item: $picking) { s in SuggestionPickerView(model: model, suggestion: s) }
    }

    private func card(_ s: SpeakerSuggestion) -> some View {
        let clip = s.clips?.first ?? s.clipId.map { SpeakerClip(id: $0) }
        let when = VoicesHub.shortTime(s.conversation?.startedAt)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                UnknownAvatar(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.conversations.map { "出现在 \($0) 段对话里" } ?? "反复出现的声音").font(.headline)
                    if let when { Text("最近 \(when)").font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            if let clip {
                HStack(spacing: 12) {
                    Button { player.toggle(clip.id, speakers: speakers) } label: {
                        if player.loadingId == clip.id {
                            ProgressView().frame(width: 40, height: 40)
                        } else {
                            Image(systemName: player.playingId == clip.id ? "pause.circle.fill" : "play.circle.fill")
                                .font(.largeTitle).foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.playingId == clip.id ? "暂停" : "播放")
                    VStack(alignment: .leading, spacing: 4) {
                        WaveformView(bars: player.currentId == clip.id ? player.bars : nil,
                                     progress: player.currentId == clip.id ? player.progress : 0) { f in
                            if player.currentId == clip.id { player.seek(to: f) }
                        }
                        .frame(height: 26)
                        // the clip's own words only (an older server's excerpt is another moment's sentence)
                        if let text = clip.text, !text.isEmpty {
                            Text("“\(text)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button { name(s) } label: { Text("命名").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                    .buttonStyle(.borderedProminent)
                Button { Task { await speakers.dismiss(s) } } label: {
                    Text("忽略").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.bordered).tint(.secondary)
            }
            .buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    /// This voice first, then the rest, in the existing flow (it also offers "keep unknown").
    private func name(_ s: SpeakerSuggestion) {
        player.stop()
        guard speakers.serverSupportsNameVoice else { picking = s; return }
        run = .init(items: ([s] + speakers.suggestions.filter { $0.id != s.id }).map(VoiceItem.init(suggestion:)))
    }
}
