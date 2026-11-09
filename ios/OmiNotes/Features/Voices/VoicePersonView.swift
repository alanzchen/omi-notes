import OmiBLE
import OmiProtocol
import SwiftUI

/// One person's voice: what the server says about it, and their samples by state (在用 / 可疑 /
/// 已移除). Listen, remove (kept and restorable), move to someone else, or confirm a flagged one;
/// the last change can be undone. Your own page also teaches your voice.
struct VoicePersonView: View {
    @Bindable var model: AppModel
    let personId: String
    @State private var samples: VoiceSamplesModel
    @State private var player = VoicePlayer()
    @State private var moving: VoiceSample?
    @State private var forgetting = false
    @State private var showEnrollment = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, personId: String, samples: VoiceSamplesModel? = nil) {
        self.model = model
        self.personId = personId
        // doubtful samples first, when there are any
        let flagged = (model.speakers.people.first { $0.id == personId }?.samplesFlagged ?? 0) > 0
        _samples = State(initialValue: samples ?? VoiceSamplesModel(speakers: model.speakers, personId: personId,
                                                                    tab: flagged ? .flagged : .active))
    }

    private var speakers: SpeakersModel { model.speakers }
    private var person: Person? { speakers.people.first { $0.id == personId } }

    var body: some View {
        List {
            if let person {
                Section { header(person) }.listRowBackground(Color.clear).listRowInsets(.init())
                if speakers.serverSupportsVoiceReview {
                    Section {
                        Picker("", selection: $samples.tab) {
                            Text(tabTitle("在用", person.samplesActive ?? person.samples)).tag(VoiceSamplesModel.Tab.active)
                            Text(tabTitle("可疑", person.samplesFlagged)).tag(VoiceSamplesModel.Tab.flagged)
                            Text(tabTitle("已移除", person.samplesRemoved)).tag(VoiceSamplesModel.Tab.removed)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear).listRowInsets(.init())
                    }
                    Section {
                        ForEach(samples.samples) { row($0, person: person) }
                        if samples.loaded, samples.samples.isEmpty {
                            Text("没有").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    } footer: {
                        if samples.tab == .removed { Text("移除的样本可以恢复。") }
                    }
                }
                if let error = samples.error ?? player.unavailable {
                    Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .listSectionSpacing(12)
        .navigationTitle(person?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("忘记声音", systemImage: "trash", role: .destructive) { forgetting = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("更多")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let done = samples.undoable {
                undoToast(done).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .animation(.snappy, value: samples.undoable)
        .task(id: samples.tab) {
            player.stop()
            if speakers.serverSupportsVoiceReview { await samples.load() }
        }
        .onChange(of: samples.undoable) { Task { await speakers.refresh() } }
        .onDisappear { player.stop() }
        .confirmationDialog("移给谁？", isPresented: .init(get: { moving != nil }, set: { if !$0 { moving = nil } }),
                            titleVisibility: .visible, presenting: moving) { s in
            ForEach(speakers.people.filter { $0.id != personId }) { p in
                Button(p.name) { Task { await samples.move(s, to: p.id) } }
            }
        }
        .confirmationDialog(person?.isMe == true ? "忘记你的声音？" : "忘记 \(person?.name ?? "") 的声音？",
                            isPresented: $forgetting, titleVisibility: .visible) {
            if let person {
                Button("忘记声音", role: .destructive) { Task { await speakers.forgetVoice(person); dismiss() } }
                Button("忘记声音并删除笔记", role: .destructive) { Task { await speakers.forgetVoice(person, deleteNote: true); dismiss() } }
            }
        } message: {
            Text("声纹从服务器删除，过去的笔记回到“Speaker N”。不能撤销。")
        }
        .sheet(isPresented: $showEnrollment) { EnrollmentView(model: model) }
    }

    private func tabTitle(_ title: String, _ count: Int?) -> String {
        count.map { $0 > 0 ? "\(title) \($0)" : title } ?? title
    }

    private func header(_ p: Person) -> some View {
        let health = VoiceHealth(p)
        let calibrated = speakers.serverSupportsVoiceCalibration ? VoicesHub.shortTime(p.calibratedAt) : nil
        let measured = VoicesHub.measuredLine(p, calibrationSupported: speakers.serverSupportsVoiceCalibration)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Avatar(name: p.name, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Label(p.statusLine ?? VoiceHealth.fallbackLine(p), systemImage: health.symbol)
                        .font(.headline).foregroundStyle(health == .active ? Color.primary : health.color)
                    HStack(spacing: 12) {
                        Label("\(p.samples ?? 0)", systemImage: "waveform")
                        if let calibrated { Label(calibrated, systemImage: "clock") }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).labelStyle(TightLabel())
                    if let measured { Text(measured).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            if p.isMe {
                Button { showEnrollment = true } label: {
                    Label(p.voiceReady == true ? "再录一段" : "录入我的声音", systemImage: "person.wave.2")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(model.settings.endpoint == nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ s: VoiceSample, person: Person) -> some View {
        HStack(spacing: 12) {
            playButton(s)
            VStack(alignment: .leading, spacing: 5) {
                if let text = s.text, !text.isEmpty {
                    Text("“\(text)”").font(.subheadline).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(meta(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    if !s.flagReasons.isEmpty { ReasonPills(reasons: s.flagReasons) }
                }
            }
            Spacer(minLength: 0)
            Menu { actions(s, person: person) } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 36).contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
        }
        .swipeActions(edge: .trailing) {
            if s.sampleState == .removed {
                Button("恢复", systemImage: "arrow.uturn.backward") { Task { await samples.restore(s) } }.tint(.blue)
            } else {
                Button("移除", systemImage: "trash", role: .destructive) { Task { await samples.remove(s) } }
                Button("移给…", systemImage: "arrow.right.circle") { moving = s }.tint(.indigo)
            }
        }
        .swipeActions(edge: .leading) {
            if s.isFlagged, s.reviewId != nil {
                Button("是 \(person.name)", systemImage: "checkmark") { Task { await samples.confirm(s) } }.tint(.green)
            }
        }
    }

    @ViewBuilder private func actions(_ s: VoiceSample, person: Person) -> some View {
        if s.sampleState == .removed {
            Button("恢复", systemImage: "arrow.uturn.backward") { Task { await samples.restore(s) } }
        } else {
            if s.isFlagged, s.reviewId != nil {
                Button("是 \(person.name)", systemImage: "checkmark.circle") { Task { await samples.confirm(s) } }
            }
            Button("移给…", systemImage: "arrow.right.circle") { moving = s }
            Button("移除", systemImage: "trash", role: .destructive) { Task { await samples.remove(s) } }
        }
    }

    @ViewBuilder private func playButton(_ s: VoiceSample) -> some View {
        if s.canPlay, let clip = s.clip {
            Button { player.toggle(clip.id, speakers: speakers) } label: {
                if player.loadingId == clip.id {
                    ProgressView().frame(width: 30, height: 30)
                } else {
                    Image(systemName: player.playingId == clip.id ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title).foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.playingId == clip.id ? "暂停" : "播放")
        } else {
            Image(systemName: "speaker.slash.circle").font(.title).foregroundStyle(.tertiary)
                .accessibilityLabel("无法试听")
        }
    }

    /// "5s · 10-09"
    private func meta(_ s: VoiceSample) -> String {
        let seconds = (s.clip?.seconds ?? s.seconds).map { "\(Int($0.rounded()))s" }
        let when = VoicesHub.shortTime(s.clip?.startedAt ?? s.conversation?.startedAt ?? s.createdAt)
        return [seconds, when].compactMap { $0 }.joined(separator: " · ")
    }

    private func undoToast(_ d: VoiceSamplesModel.Done) -> some View {
        let text: String = switch d.action {
        case .remove: "已移除"
        case .restore: "已恢复"
        case .move: "已移走"
        case .confirm: "已确认"
        }
        return VoiceToast(symbol: "checkmark.circle.fill", tint: .green, text: text, action: "撤销") { Task { await samples.undo() } }
    }
}
