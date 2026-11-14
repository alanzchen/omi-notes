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
    @State private var newPerson: ConversationSpeakersView.NamingRun?
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
                case .preparing:
                    preparing
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
        .task {
            if queue.items.isEmpty, queue.phase == .loading { await queue.load() }
            #if DEBUG
            // simulator automation: `-OmiNotesDebugVoicesSkip <n>` skips n cards, `-OmiNotesDebugVoicesAnswer
            // confirm|reject` answers the next one and keeps its undo toast up
            let defaults = UserDefaults.standard
            for _ in 0..<defaults.integer(forKey: "OmiNotesDebugVoicesSkip") { queue.skip() }
            if let raw = defaults.string(forKey: "OmiNotesDebugVoicesAnswer") {
                queue.undoWindow = .seconds(600)
                await queue.decide(raw == "reject" ? .reject : .confirm)
            }
            #endif
        }
        .task(id: queue.current?.id) {
            player.stop()
            if let item = queue.current, item.canPlay, let clip = item.clip {
                await player.load(clip.id, version: VoiceReviewQueue.clipVersion(item), speakers: speakers)
            }
        }
        // a fetched queue may name the same clip id after a re-transcription: no old audio is reused
        .onChange(of: queue.generation) { player.invalidate() }
        .onAppear { queue.setVisible(true) }
        .onDisappear { player.stop(); queue.setVisible(false) }
        .personConsent(model, personId: queue.consentNeeded) { queue.clearConsentNeeded() }
        .fullScreenCover(item: $newPerson, onDismiss: { Task { await speakers.refresh(); await queue.load() } }) { r in
            NameVoiceView(model: model, items: r.items)
        }
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

    /// The item's own name first, then the people list; nobody to name is "这是谁？", never a placeholder.
    private func question(_ item: ReviewItem) -> VoicesHub.ReviewQuestion {
        VoicesHub.reviewQuestion(item, people: speakers.people)
    }

    private func card(_ item: ReviewItem) -> some View {
        let q = question(item)
        return VStack(spacing: 18) {
            Spacer(minLength: 0)
            Group {
                switch q {
                case .isThis(_, let name): Text("是 \(name) 吗？")
                case .whoIsThis: Text("这是谁？")
                }
            }
            .font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
            if case .isThis = q {
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
            } else {
                listenCard(item)
            }
            errorLine
            Spacer(minLength: 0)
            switch q {
            case .isThis(_, let name): answers(item, name: name)
            case .whoIsThis: whoAnswers(item)
            }
            bottomLine.frame(height: 50).padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
    }

    /// "这是谁？": someone you know (picked), a new person (the naming flow, which asks consent), or
    /// 不认识 (skipped here; the voice stays unnamed).
    private func whoAnswers(_ item: ReviewItem) -> some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(VoicesHub.cards(speakers.people)) { p in
                    Button(p.name) { player.stop(); Task { await queue.choose(p.id) } }
                }
            } label: {
                bigLabel("选择", symbol: "person.crop.circle", color: .accentColor)
            }
            .disabled(speakers.people.isEmpty)
            if let naming = Self.namingItem(item) {
                Button { player.stop(); newPerson = .init(items: [naming]) } label: {
                    bigLabel("新的人", symbol: "person.badge.plus", color: .indigo)
                }
                .buttonStyle(.plain)
            }
            Button { withAnimation(.snappy) { queue.skip() } } label: {
                bigLabel("不认识", symbol: "questionmark", color: .gray)
            }
            .buttonStyle(.plain)
        }
        .disabled(queue.busy)
    }

    /// A conversation's speaker, for the naming flow (it adds a person and asks consent). It carries
    /// the revision the item was reviewed against, so a reprocessed S1 is never named from the old
    /// audition; without one there is nothing to protect it with, so no 新的人.
    static func namingItem(_ item: ReviewItem) -> VoiceItem? {
        guard item.kind == "label", let label = item.label, let conv = item.conversation,
              let reviewed = item.reviewedRevision else { return nil }
        let clip = item.clip.map { SpeakerClip(id: $0.id, seconds: $0.seconds, startedAt: $0.startedAt, text: item.text, conversationId: conv.id) }
        var naming = VoiceItem(target: .label(conversationId: conv.id, label: label), question: .whoIsThis, context: conv,
                               clips: clip.map { [$0] } ?? [], scope: [conv])
        naming.reviewedRevision = reviewed
        naming.reviewedTranscript = item.transcriptSha
        return naming
    }

    private func listenCard(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                contextLine(item.conversation)
                Spacer(minLength: 0)
                ReasonPills(reasons: item.reasons ?? [])
            }
            let clipState = ReviewClipState.of(item, loading: player.loading, failure: player.failure)
            if clipState != .noAudio, let clip = item.clip {
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
                if case .retry(let why) = clipState {  // a network failure loading a clip the server has
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                // the server can't cut this clip (or no longer has it): the words only, never made-up audio or "try again"
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

    /// When, then the conversation's title small and grey on its own line: the person question stays primary.
    private func contextLine(_ c: ConversationContext?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(VoicesHub.shortTime(c?.startedAt) ?? "对话").font(.subheadline.weight(.semibold)).lineLimit(1)
            if let title = c?.title, !title.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
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

    private func answers(_ item: ReviewItem, name: String) -> some View {
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
            bigButton("是 \(name)", symbol: "checkmark", color: .green) { answer(.confirm) }
        }
        .disabled(queue.busy)
    }

    private func bigButton(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { bigLabel(title, symbol: symbol, color: color) }
            .buttonStyle(.plain)
    }

    private func bigLabel(_ title: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title2.weight(.bold))
            Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity).frame(height: 76)
        .background(color.gradient, in: .rect(cornerRadius: 20))
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
        // the person it went to (a move), else the one asked about; without a name, no name
        let moved = d.personId.flatMap { pid in speakers.people.first { $0.id == pid }?.name }
        let asked: String? = if case .isThis(_, let name) = question(d.item) { name } else { nil }
        let who = (d.decision == .move ? moved : asked).map { " \($0)" } ?? ""
        let (symbol, tint, text): (String, Color, String) = switch d.decision {
        case .confirm: ("checkmark.circle.fill", .green, who.isEmpty ? "已确认" : "已确认是\(who)")
        case .reject: ("xmark.circle.fill", .orange, who.isEmpty ? "已标记不是" : "已标记不是\(who)")
        case .move: ("arrow.right.circle.fill", .indigo, who.isEmpty ? "已移走" : "已移给\(who)")
        }
        return VoiceToast(symbol: symbol, tint: tint, text: text, action: "撤销") { Task { await queue.undo() } }
    }

    private func noticeToast(_ n: VoiceReviewQueue.Notice) -> some View {
        let (symbol, tint, text): (String, Color, String) = switch n {
        case .refreshed: ("arrow.clockwise.circle.fill", .blue, "刚刚有变化，已重新载入")
        case .undone: ("arrow.uturn.backward.circle.fill", .green, "已撤销")
        case .undoFailed: ("exclamationmark.circle.fill", .orange, "没能撤销")
        }
        return VoiceToast(symbol: symbol, tint: tint, text: text)
            .task { try? await Task.sleep(for: .seconds(3)); queue.clearNotice() }
    }

    /// The queue's own error (with an undo's reasons), or the speakers model's (a failed attestation).
    @ViewBuilder private var errorLine: some View {
        if let error = queue.error {
            if queue.canRetry {
                Button { Task { await queue.retry() } } label: { RetryLine(text: error) }.buttonStyle(.plain)
            } else {
                Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        } else if let error = speakers.error {
            Button { Task { await speakers.refresh() } } label: { RetryLine(text: error) }.buttonStyle(.plain)
        }
    }

    // MARK: Done

    private var doneTitle: String {
        switch queue.phase {
        case .batchDone: return "这批完成了"
        case .onlySkipped: return "剩下的都跳过了"
        default: return "没有待确认的了"
        }
    }

    /// The server is still building its queue (just after it starts): not "nothing to confirm".
    private var preparing: some View {
        VStack(spacing: 14) {
            Spacer()
            if queue.preparingGaveUp {
                Image(systemName: "hourglass").font(.system(size: 44)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
            }
            Text("正在准备…").font(.title3.bold())
            Text(queue.preparingGaveUp ? "服务器还在整理待确认的录音，稍后再看" : "服务器刚启动，正在整理待确认的录音")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if queue.preparingGaveUp {
                Button("刷新") { Task { await queue.refreshPreparing() } }.buttonStyle(.bordered)
            }
            Spacer()
            Button("完成") { dismiss() }.font(.headline)
            Color.clear.frame(height: 50).padding(.bottom, 8)  // no card: no swipe hint (keeps the layout of the others)
        }
        .padding(.horizontal, 32)
    }

    private var finished: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text(doneTitle).font(.title.bold())
            // an undo of the last answer that failed says why here too
            errorLine
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
