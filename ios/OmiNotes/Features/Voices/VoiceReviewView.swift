import OmiBLE
import OmiProtocol
import SwiftUI

/// The review queue: one 3–6 s clip at a time, "是 X" / "不是" / "跳过" (or swipe right / left),
/// batches of ten with suspicious samples first, and a few seconds to undo each answer. A clip the
/// server can't cut shows "无法试听" with its caption only. Nothing plays until play is tapped.
struct VoiceReviewView: View {
    @Bindable var model: AppModel
    @State private var queue: VoiceReviewQueue
    @State private var player = VoicePlayer()
    @State private var drag: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, queue: VoiceReviewQueue? = nil) {
        self.model = model
        _queue = State(initialValue: queue ?? VoiceReviewQueue(speakers: model.speakers))
    }

    private var speakers: SpeakersModel { model.speakers }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                switch queue.phase {
                case .loading where queue.current == nil:
                    Spacer(); ProgressView(); Spacer()
                case .failed(let why):
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                        Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("重试") { Task { await queue.load() } }.buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 32)
                    Spacer()
                default:
                    if let item = queue.current {
                        card(item).id(item.id)
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                    } else {
                        finished
                    }
                }
            }
            .animation(.snappy, value: queue.current?.id)
        }
        .task { if queue.items.isEmpty, queue.phase == .loading { await queue.load() } }
        .task(id: queue.current?.id) {
            player.stop()
            if let item = queue.current, item.canPlay, let clip = item.clip {
                await player.load(clip.id, version: VoiceReviewQueue.clipVersion(item), speakers: speakers)
            }
        }
        // a fetched queue may name the same clip id after a re-transcription: no old audio is reused
        .onChange(of: queue.generation) { player.invalidate() }
        .onDisappear { player.stop() }
        .personConsent(model, personId: queue.consentNeeded) { queue.clearConsentNeeded() }
    }

    // MARK: Top

    private var topBar: some View {
        HStack {
            Button { player.stop(); dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Color.secondary)
                    .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: .circle)
            }
            .buttonStyle(.plain).accessibilityLabel("关闭")
            Spacer()
            let total = queue.items.count
            if total > 0 {
                HStack(spacing: 5) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule().fill(i < queue.index ? Color.accentColor.opacity(0.45) : i == queue.index ? Color.accentColor : Color(.systemGray4))
                            .frame(width: i == queue.index ? 20 : 7, height: 7)
                    }
                }
                .accessibilityElement().accessibilityLabel("第 \(min(queue.index + 1, total)) 个，共 \(total) 个")
            }
            Spacer()
            Text(total > 0 ? "\(min(queue.index + 1, total))/\(total)" : "").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    // MARK: One clip

    private func name(_ item: ReviewItem) -> String {
        item.personId.flatMap { pid in speakers.people.first { $0.id == pid }?.name } ?? "TA"
    }

    private func card(_ item: ReviewItem) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text("是 \(name(item)) 吗？").font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
            listenCard(item)
                .offset(x: drag.width)
                .rotationEffect(.degrees(Double(drag.width) / 22))
                .overlay { stamp }
                .gesture(DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { g in
                        if g.translation.width > 110 { answer(.confirm) } else if g.translation.width < -110 { answer(.reject) }
                        withAnimation(.snappy) { drag = .zero }
                    })
            if let error = queue.error {
                Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            answers(item)
            bottomLine.frame(height: 50).padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
    }

    private func listenCard(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                contextLine(item.conversation)
                Spacer(minLength: 0)
                ReasonPills(reasons: item.reasons ?? [])
            }
            if item.canPlay, let clip = item.clip {
                HStack(spacing: 14) {
                    Button { player.toggle(clip.id, version: VoiceReviewQueue.clipVersion(item), speakers: speakers) } label: {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 64, height: 64)
                                .shadow(color: .accentColor.opacity(0.35), radius: 10, y: 4)
                            if player.loading { ProgressView().tint(.white) } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                    VStack(spacing: 6) {
                        WaveformView(bars: player.bars, progress: player.progress) { player.seek(to: $0) }.frame(height: 72)
                        HStack {
                            Text(VoiceClock.text(player.elapsed)); Spacer(); Text(VoiceClock.text(player.duration ?? clip.seconds ?? 0))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let unavailable = player.unavailable {
                    Text(unavailable).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                // the server can't cut this clip any more: the words only, never made-up audio
                Label("无法试听", systemImage: "speaker.slash.fill")
                    .font(.headline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16))
            }
            caption(item.text)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
    }

    private func contextLine(_ c: ConversationContext?) -> some View {
        HStack(spacing: 4) {
            Text(c?.title ?? "对话").fontWeight(.semibold).lineLimit(1)
            if let when = VoicesHub.shortTime(c?.startedAt) { Text("· \(when)").foregroundStyle(.secondary).lineLimit(1).fixedSize() }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    /// The phrase the clip overlaps; the transcript has no word timing, so nothing is highlighted.
    @ViewBuilder private func caption(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            Text("“\(text)”").font(.title3).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var stamp: some View {
        if abs(drag.width) > 30 {
            let yes = drag.width > 0
            Text(yes ? "是" : "不是").font(.largeTitle.weight(.heavy))
                .foregroundStyle(yes ? .green : .red)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(yes ? .green : .red, lineWidth: 4))
                .rotationEffect(.degrees(yes ? -12 : 12))
                .opacity(min(1, abs(drag.width) / 110))
        }
    }

    private func answers(_ item: ReviewItem) -> some View {
        let others = speakers.people.filter { $0.id != item.personId }
        return HStack(spacing: 12) {
            bigButton("不是", symbol: "xmark", color: .red) { answer(.reject) }
                // someone else's voice: move it to them (press and hold)
                .contextMenu {
                    ForEach(others) { p in
                        Button("是 \(p.name)", systemImage: "arrow.right.circle") { answer(.move, personId: p.id) }
                    }
                }
            Button { withAnimation(.snappy) { queue.skip() } } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.forward").font(.title3.weight(.semibold))
                    Text("跳过").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 76)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            bigButton("是 \(name(item))", symbol: "checkmark", color: .green) { answer(.confirm) }
        }
        .disabled(queue.busy)
    }

    private func bigButton(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2.weight(.bold))
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(color.gradient, in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private func answer(_ d: VoiceReviewQueue.Decision, personId: String? = nil) {
        player.stop()
        Task { await queue.decide(d, personId: personId) }
    }

    // MARK: Undo and notices (in the hint's place, so they never cover an answer)

    @ViewBuilder private var bottomLine: some View {
        if let done = queue.undoable {
            undoToast(done)
        } else if let notice = queue.notice {
            noticeToast(notice)
        } else {
            Label("左滑 不是 · 右滑 是", systemImage: "hand.draw").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func undoToast(_ d: VoiceReviewQueue.Done) -> some View {
        let who = d.personId.flatMap { pid in speakers.people.first { $0.id == pid }?.name } ?? name(d.item)
        let (symbol, tint, text): (String, Color, String) = switch d.decision {
        case .confirm: ("checkmark.circle.fill", .green, "已确认是 \(who)")
        case .reject: ("xmark.circle.fill", .orange, "已标记不是 \(who)")
        case .move: ("arrow.right.circle.fill", .indigo, "已移给 \(who)")
        }
        return VoiceToast(symbol: symbol, tint: tint, text: text, action: "撤销") { Task { await queue.undo() } }
    }

    private func noticeToast(_ n: VoiceReviewQueue.Notice) -> some View {
        let (symbol, tint, text): (String, Color, String) = switch n {
        case .refreshed: ("arrow.clockwise.circle.fill", .blue, "刚刚有变化，已重新载入")
        case .undone: ("arrow.uturn.backward.circle.fill", .green, "已撤销")
        case .undoFailed: ("exclamationmark.circle.fill", .orange, "之后又改过，没能撤销")
        }
        return VoiceToast(symbol: symbol, tint: tint, text: text)
            .task { try? await Task.sleep(for: .seconds(3)); queue.clearNotice() }
    }

    // MARK: Done

    private var doneTitle: String {
        switch queue.phase {
        case .batchDone: return "这批完成了"
        case .onlySkipped: return "剩下的都跳过了"
        default: return "没有待确认的了"
        }
    }

    private var finished: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text(doneTitle).font(.title.bold())
            Spacer()
            if queue.phase == .batchDone {
                Button { Task { await queue.load() } } label: {
                    Text("下一批").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 16))
            }
            Button("完成") { dismiss() }.font(.headline)
            bottomLine.frame(height: 50).padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
    }
}
