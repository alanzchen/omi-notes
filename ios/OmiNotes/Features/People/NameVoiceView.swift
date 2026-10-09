import AVFoundation
import Observation
import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

/// "Name this voice": one voice at a time — listen, answer, next (docs/speaker-learning.md,
/// "Naming from the phone"). Nothing plays until the play button is tapped.
struct NameVoiceView: View {
    @Bindable var model: AppModel
    @State private var flow: NameVoiceFlow
    @State private var player = VoicePlayer()
    @State private var clip: SpeakerClip?
    @State private var searching = false
    @State private var confirming: Pending?
    @State private var addingMe = false
    @State private var myName = ""
    @State private var showConsent = false
    @State private var localError: String?
    @Environment(\.dismiss) private var dismiss

    /// An answer waiting for the owner to confirm its scope or consent.
    enum Pending: Identifiable {
        case name(Person)
        case add(String)
        case keepUnknown
        var id: String {
            switch self {
            case .name(let p): return "n:\(p.id)"
            case .add(let n): return "a:\(n)"
            case .keepUnknown: return "k"
            }
        }
    }

    init(model: AppModel, items: [VoiceItem]) {
        self.model = model
        _flow = State(initialValue: NameVoiceFlow(speakers: model.speakers, items: items))
    }

    private var speakers: SpeakersModel { model.speakers }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if let item = flow.current {
                    voice(item).id(item.id).transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                } else {
                    finished
                }
            }
            .animation(.snappy, value: flow.current?.id)
            if let last = flow.undoable { toast(last).padding(.bottom, 64) }
        }
        .onChange(of: flow.current?.id) { _, _ in
            player.stop()
            clip = flow.current?.clips.first
        }
        .onAppear { clip = flow.current?.clips.first }
        .onDisappear { player.stop() }
        .task(id: clip?.id) { if let clip { await player.load(clip.id, speakers: speakers) } }
        .sheet(isPresented: $searching) {
            PersonSearchView(model: model, player: player, clip: clip) { choice in
                searching = false
                switch choice {
                case .person(let p): choose(p)
                case .add(let name):
                    if speakers.settings?.acknowledged == true { confirming = .add(name) } else { showConsent = true }
                }
            }
        }
        .sheet(isPresented: $showConsent) { RecognitionConsentView(model: model) }
        .alert(confirmTitle, isPresented: .init(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { pending in
            Button("Cancel", role: .cancel) {}
            Button(confirmAction(pending)) { Task { await perform(pending) } }
        } message: { pending in
            Text(confirmMessage(pending))
        }
        .alert("This is you", isPresented: $addingMe) {
            TextField("Your name", text: $myName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = myName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await addMeAndName(name) }
            }
        } message: {
            Text("Your voice is kept on your server so notes can label you.")
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack {
            Button { player.stop(); dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Color.secondary)
                    .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer()
            progress
            Spacer()
            if flow.current != nil {
                Button("Skip") { flow.skip() }.disabled(flow.busy)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
    }

    @ViewBuilder private var progress: some View {
        let total = flow.items.count
        if total <= 8 {
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule().fill(i == flow.index ? Color.accentColor : Color(.systemGray4))
                        .frame(width: i == flow.index ? 22 : 7, height: 7)
                }
            }
            .accessibilityElement().accessibilityLabel("Voice \(min(flow.index + 1, total)) of \(total)")
        } else {
            Text("\(min(flow.index + 1, total)) of \(total)").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: One voice

    private func voice(_ item: VoiceItem) -> some View {
        VStack(spacing: 18) {
            contextLine(clip?.conversation ?? item.context)
            listenCard(item)
            VStack(spacing: 6) {
                Text(question(item)).font(.largeTitle.bold()).multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(2)
                Text(scopeLine(item)).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            answers(item)
            if let error = localError ?? flow.error {
                Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button("Keep unknown") { confirming = .keepUnknown }
                .font(.body).foregroundStyle(.secondary).disabled(flow.busy).padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
    }

    private func contextLine(_ c: ConversationContext?) -> some View {
        let when = c?.startedAt.flatMap(ISO8601UTC.parse).map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }
        // the title gives way; the date and time always show
        return HStack(spacing: 4) {
            Text(c?.title ?? "Conversation").fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
            if let when { Text("· \(when)").foregroundStyle(.secondary).lineLimit(1).fixedSize() }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func listenCard(_ item: VoiceItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button { if let clip { player.toggle(clip.id, speakers: speakers) } } label: {
                    ZStack {
                        Circle().fill(Color.accentColor).frame(width: 64, height: 64)
                            .shadow(color: .accentColor.opacity(0.35), radius: 10, y: 4)
                        if player.loading { ProgressView().tint(.white) } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain).disabled(clip == nil)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play this voice")
                VStack(alignment: .leading, spacing: 6) {
                    WaveformView(bars: player.bars, progress: player.progress) { player.seek(to: $0) }
                        .frame(height: 44)
                    HStack {
                        Text(Self.clock(player.elapsed)); Spacer(); Text(Self.clock(player.duration ?? clip?.seconds ?? 0))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let unavailable = player.unavailable {
                Text(unavailable).font(.footnote).foregroundStyle(.secondary)
            } else if let text = clip?.text, !text.isEmpty {
                // phrase level: the transcript has no word timing, so nothing is highlighted
                Text("“\(text)”").font(.body).foregroundStyle(.primary).lineLimit(4)
                    .accessibilityLabel("Said around this clip: \(text)")
            } else if clip != nil {
                // never another moment's sentence in its place
                Text("No transcript text lines up with this clip.").font(.footnote).foregroundStyle(.secondary)
            }
            clipChoices(item)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    @ViewBuilder private func clipChoices(_ item: VoiceItem) -> some View {
        if item.clips.count > 1 || item.otherDay != nil {
            HStack(spacing: 8) {
                if item.clips.count > 1 {
                    ForEach(Array(item.clips.prefix(3).enumerated()), id: \.element.id) { i, c in
                        chip("Clip \(i + 1)", on: clip?.id == c.id) { clip = c }
                    }
                }
                Spacer(minLength: 0)
                if let other = item.otherDay {
                    chip("Other day", system: "arrow.triangle.2.circlepath", on: clip?.id == other.id) { clip = other }
                }
            }
        }
    }

    private func chip(_ title: String, system: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { if let system { Image(systemName: system) } }
                .font(.subheadline.weight(on ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(on ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func answers(_ item: VoiceItem) -> some View {
        VStack(spacing: 16) {
            if let guess = guessButtonTitle(item) {
                Button {
                    switch item.question {
                    case .isThis(let pid): if let p = speakers.people.first(where: { $0.id == pid }) { choose(p) }
                    case .isThisYou: chooseMe()
                    case .whoIsThis: break
                    }
                } label: {
                    Text(guess).font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).disabled(flow.busy)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(shortcuts(item)) { p in
                    avatarButton(p.isMe ? "Me" : p.name, initial: p.name, person: p) { p.isMe ? chooseMe() : choose(p) }
                }
                if speakers.me == nil, !isAskingAboutYou(item) {
                    avatarButton("Me", initial: "Me", person: nil) { chooseMe() }
                }
                VStack(spacing: 6) {
                    Button { searching = true } label: {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(Color.accentColor)
                            .frame(width: 58, height: 58).background(Color(.tertiarySystemFill), in: .circle)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Someone else")
                    Text("Other…").font(.footnote).foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(flow.busy)
        }
    }

    private func avatarButton(_ title: String, initial: String, person: Person?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) { Avatar(name: initial, size: 58) }.buttonStyle(.plain).accessibilityLabel(title)
            Text(title).font(.footnote).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// Me first, then up to three others (the guessed person is the big button, not repeated).
    private func shortcuts(_ item: VoiceItem) -> [Person] {
        var guessed: String?
        if case .isThis(let pid) = item.question { guessed = pid }
        let me = speakers.me.map { [$0] } ?? []
        let mine = isAskingAboutYou(item) ? [] : me.filter { $0.id != guessed }
        return mine + speakers.others.filter { $0.id != guessed }.prefix(4 - mine.count)
    }

    private func isAskingAboutYou(_ item: VoiceItem) -> Bool { item.question == .isThisYou }

    private func question(_ item: VoiceItem) -> String {
        switch item.question {
        case .isThis(let pid): return "Is this \(name(pid))?"
        case .isThisYou: return "Is this you?"
        case .whoIsThis: return "Who is this?"
        }
    }

    private func guessButtonTitle(_ item: VoiceItem) -> String? {
        switch item.question {
        case .isThis(let pid): return speakers.people.contains { $0.id == pid } ? "Yes, \(name(pid))" : nil
        case .isThisYou: return "Yes, it's me"
        case .whoIsThis: return nil
        }
    }

    private func scopeLine(_ item: VoiceItem) -> String {
        item.spansConversations ? "Same voice in \(item.scope.count) conversations" : "In this conversation"
    }

    private func name(_ pid: String) -> String { speakers.people.first { $0.id == pid }?.name ?? "someone you know" }

    // MARK: Answering

    private func choose(_ p: Person) {
        guard p.isMe || speakers.settings?.acknowledged == true else {
            showConsent = true  // recognizing anyone but the wearer needs the one-time acknowledgment
            return
        }
        if flow.current?.spansConversations == true {
            confirming = .name(p)
        } else {
            Task { await perform(.name(p)) }
        }
    }

    private func chooseMe() {
        if let me = speakers.me { choose(me) } else { myName = ""; addingMe = true }
    }

    private func addMeAndName(_ name: String) async {
        do {
            let me = try await speakers.addPerson(name: name, me: true, attestKnows: false)
            choose(me)
        } catch {
            flowError("Couldn't add you: \(error)")
        }
    }

    private func perform(_ pending: Pending) async {
        localError = nil
        switch pending {
        case .name(let p):
            await flow.name(p)
        case .add(let name):
            do {
                // the add confirmation already named the scope: one confirmation, not two
                let p = try await speakers.addPerson(name: name, me: false, attestKnows: true)
                await flow.name(p)
            } catch {
                flowError("Couldn't add \(name): \(error)")
            }
        case .keepUnknown:
            await flow.keepUnknown()
        }
    }

    private func flowError(_ message: String) { localError = message }

    private var confirmTitle: String {
        switch confirming {
        case .name(let p): return "Label this voice as \(p.name)?"
        case .add(let n): return "Add \(n)?"
        case .keepUnknown: return "Keep this voice unknown?"
        case nil: return ""
        }
    }

    private func confirmAction(_ pending: Pending) -> String {
        let n = flow.current?.scope.count ?? 1
        switch pending {
        case .name: return n > 1 ? "Name in \(n) conversations" : "Name"
        case .add: return "Yes, add"
        case .keepUnknown: return "Keep unknown"
        }
    }

    private func confirmMessage(_ pending: Pending) -> String {
        let scope = flow.current?.scope ?? []
        let list = scope.prefix(4).map { c in
            [c.title ?? "Conversation", c.startedAt.flatMap(ISO8601UTC.parse).map { Fmt.day($0) }].compactMap { $0 }.joined(separator: ", ")
        }.joined(separator: "\n") + (scope.count > 4 ? "\nand \(scope.count - 4) more" : "")
        switch pending {
        case .name:
            return "This changes the speaker in \(scope.count) conversation\(scope.count == 1 ? "" : "s"):\n\(list)\nYou can undo it right after."
        case .add(let n):
            return "\(n) knows Omi Notes learns their voice from your recordings."
                + (scope.count > 1 ? "\n\nThis names the voice in \(scope.count) conversations:\n\(list)" : "")
        case .keepUnknown:
            return scope.count > 1
                ? "It stays unknown in these \(scope.count) conversations and won't be suggested again:\n\(list)"
                : "It stays unknown and won't be asked about again. You can still name it from the conversation."
        }
    }

    // MARK: Saved, and the end

    private func toast(_ last: NameVoiceFlow.Saved) -> some View {
        let n = last.item.scope.count
        let what = last.person.map { $0.isMe ? "You" : $0.name } ?? "Kept unknown"
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("\(what) · \(n) conversation\(n == 1 ? "" : "s")").foregroundStyle(.white)
            Spacer()
            Button("Undo") { Task { await flow.undo() } }.fontWeight(.semibold).disabled(flow.busy)
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(white: 0.17).opacity(0.96), in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark").font(.system(size: 36, weight: .semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 84, height: 84).background(Color.accentColor.opacity(0.14), in: .circle)
            Text(flow.saved.isEmpty ? "Nothing changed" : "All caught up").font(.title.bold())
            let named = flow.saved.compactMap(\.person)
            if !named.isEmpty {
                Text("Notes now show these names.").foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                ForEach(Array(named.enumerated()), id: \.offset) { _, p in
                    VStack(spacing: 6) { Avatar(name: p.name, size: 50); Text(p.isMe ? "You" : p.name).font(.footnote) }
                }
                if !flow.skipped.isEmpty {
                    VStack(spacing: 6) {
                        Text("?").font(.title3).foregroundStyle(.secondary).frame(width: 50, height: 50)
                            .background(Color(.tertiarySystemFill), in: .circle)
                        Text("Skipped").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !named.isEmpty {
                Text("Summaries keep their wording until a conversation is re-summarized.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Spacer()
            Button { dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18))
                .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .task { await speakers.refresh() }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// A person's initials on a color derived from the name (stable across launches).
struct Avatar: View {
    let name: String
    var size: CGFloat = 58

    private static let palette: [(Color, Color)] = [
        (.init(red: 0.39, green: 0.66, blue: 1.0), .init(red: 0.31, green: 0.45, blue: 0.98)),
        (.init(red: 0.42, green: 0.85, blue: 0.62), .init(red: 0.2, green: 0.68, blue: 0.47)),
        (.init(red: 0.78, green: 0.56, blue: 1.0), .init(red: 0.6, green: 0.39, blue: 0.96)),
        (.init(red: 1.0, green: 0.55, blue: 0.47), .init(red: 0.96, green: 0.36, blue: 0.4)),
        (.init(red: 1.0, green: 0.7, blue: 0.34), .init(red: 0.96, green: 0.52, blue: 0.2)),
        (.init(red: 0.5, green: 0.5, blue: 0.54), .init(red: 0.33, green: 0.33, blue: 0.36)),
    ]

    var body: some View {
        let hash = name.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fffffff }
        let (a, b) = Self.palette[hash % Self.palette.count]
        Text(name == "Me" ? "Me" : String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom), in: .circle)
            .accessibilityHidden(true)
    }
}

/// Bars from the clip's own samples; played part in the accent color. Tap to seek.
struct WaveformView: View {
    let bars: [Float]?
    let progress: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let values = bars ?? []
            let count = max(values.count, 1)
            let gap: CGFloat = 2.5
            let width = max(1.5, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                if values.isEmpty {
                    Capsule().fill(Color(.systemGray4)).frame(height: 2)  // not loaded: no invented shape
                } else {
                    ForEach(values.indices, id: \.self) { i in
                        Capsule()
                            .fill(Double(i) / Double(count) < progress ? Color.accentColor : Color(.systemGray3))
                            .frame(width: width, height: max(3, CGFloat(values[i]) * geo.size.height))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture { location in onSeek(min(max(location.x / geo.size.width, 0), 1)) }
        }
        .accessibilityHidden(true)
    }
}

/// Plays one clip at a time with progress; loads its samples (for the waveform) without playing.
@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var bars: [Float]?
    private(set) var duration: Double?
    private(set) var elapsed: Double = 0
    private(set) var isPlaying = false
    private(set) var loading = false
    private(set) var unavailable: String?
    private var loadedId: String?
    private var cache: [String: Data] = [:]
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    var progress: Double { duration.map { $0 > 0 ? elapsed / $0 : 0 } ?? 0 }

    func load(_ clipId: String, speakers: SpeakersModel) async {
        guard loadedId != clipId else { return }
        stop()
        loadedId = clipId
        bars = nil
        duration = nil
        unavailable = nil
        loading = true
        defer { if loadedId == clipId { loading = false } }
        do {
            let data: Data
            if let cached = cache[clipId] { data = cached } else { data = try await speakers.clip(clipId) }
            guard loadedId == clipId else { return }
            cache[clipId] = data
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
            bars = Waveform.bars(wav: data, count: 46)
        } catch APIError.http(410, _) {
            unavailable = "This audio has expired on the server, so it can't be played."
        } catch {
            guard loadedId == clipId else { return }
            if Task.isCancelled {
                loadedId = nil  // superseded, not failed: the next load asks again
                return
            }
            loadedId = nil  // a tap on play tries again
            unavailable = "Couldn't load the audio (\(error)). Tap play to try again."
        }
    }

    func toggle(_ clipId: String, speakers: SpeakersModel) {
        guard loadedId == clipId, let player else {
            Task {
                await load(clipId, speakers: speakers)
                if loadedId == clipId, self.player != nil, !isPlaying { toggle(clipId, speakers: speakers) }
            }
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            isPlaying = true
            tick()
        }
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = fraction * player.duration
        elapsed = player.currentTime
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        elapsed = 0
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let p = self.player else { return }
                self.elapsed = p.currentTime
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.ticker?.cancel()
            self.isPlaying = false
            self.elapsed = self.duration ?? 0
        }
    }
}

/// Someone not in the shortcuts: search people, or add a new one (consent is confirmed next).
struct PersonSearchView: View {
    enum Choice { case person(Person), add(String) }

    @Bindable var model: AppModel
    let player: VoicePlayer
    let clip: SpeakerClip?
    let onChoose: (Choice) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var matches: [Person] {
        let people = model.speakers.people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return trimmed.isEmpty ? people : people.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let clip {
                    Section {
                        HStack(spacing: 12) {
                            Button { player.toggle(clip.id, speakers: model.speakers) } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
                            }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .accessibilityLabel(player.isPlaying ? "Pause the voice" : "Play the voice again")
                            WaveformView(bars: player.bars, progress: player.progress) { player.seek(to: $0) }.frame(height: 30)
                        }
                    }
                }
                Section {
                    ForEach(matches) { p in
                        Button { onChoose(.person(p)) } label: {
                            HStack(spacing: 12) {
                                Avatar(name: p.name, size: 34)
                                Text(p.isMe ? "\(p.name) (you)" : p.name).foregroundStyle(.primary)
                            }
                        }
                    }
                    if !trimmed.isEmpty, !model.speakers.people.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                        Button { onChoose(.add(trimmed)) } label: { Label("Add “\(trimmed)”", systemImage: "plus.circle.fill") }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name")
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
