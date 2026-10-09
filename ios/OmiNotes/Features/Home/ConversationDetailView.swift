import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

/// One conversation's note: summary, action items, speakers and transcript. Read-only; speaker
/// names are corrected on the speakers screen. A copy loaded earlier stays visible (marked stale)
/// when the server can't be reached.
struct ConversationDetailView: View {
    let model: AppModel
    let summary: ConversationSummary
    /// Opened from a highlight: cue the player there (nothing plays until play is tapped).
    var focusHighlight: Int?
    @State private var recording: NoteRecordingController
    @State private var cued = false

    init(model: AppModel, summary: ConversationSummary, focusHighlight: Int? = nil) {
        self.model = model
        self.summary = summary
        self.focusHighlight = focusHighlight
        let id = summary.id
        _recording = State(initialValue: NoteRecordingController(
            conversationId: id,
            fetchInfo: { try await model.recordingClient().recordingInfo(id) },
            makeEngine: { _ in AVRecordingEngine(api: try model.recordingClient(), conversationId: id) }))
    }

    @State private var error: String?
    @State private var loadingMore = false
    @State private var showTranscript = false
    @State private var obsidianMessage: String?
    @State private var naming: ConversationSpeakersView.NamingRun?
    @State private var namingMessage: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var detail: ConversationDetail? { model.details[summary.id] }
    private var entry: ConversationSummary { detail?.entry ?? summary }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            header
            if let saved = model.detailSavedAt[summary.id] {
                Section {
                    Label("Saved copy from \(Fmt.relative(saved)). The server can't be reached right now.", systemImage: "tray.full")
                        .font(.footnote).foregroundStyle(.secondary)
                    if detail?.transcriptComplete == false {
                        Text("Only part of the transcript was saved on this phone.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let detail {
                if detail.entry.status == "failed", model.detailSavedAt[summary.id] == nil { fixSection(detail) }
                caveats(detail)
                if model.canPlayRecordings, detail.entry.status != "open", model.detailSavedAt[summary.id] == nil {
                    NoteRecordingSection(model: model, entry: detail.entry, player: recording).id("recording")
                }
                ValueDetailSection(detail: detail, canPlay: model.canPlayRecordings && model.detailSavedAt[summary.id] == nil,
                                   onPlay: { h in play(h, proxy: proxy) }, onShow: { h in show(h, proxy: proxy) })
                summarySection(detail)
                if let s = detail.summary { details(s) }
                myNotes(detail)
                obsidianSection(detail)
                speakersSection(detail)
                transcriptSection(detail)
                historySection(detail)
            } else if error == nil {
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary).padding(.leading, 6) } }
            }
            if let error, model.detailSavedAt[summary.id] == nil {
                Section {
                    Label(detail == nil ? "Couldn't load this conversation: \(error)" : "Couldn't refresh (\(error)); showing what was loaded before.",
                          systemImage: "wifi.exclamationmark")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: detail?.highlights) { _, _ in cueFocus() }
        }
        .navigationTitle(entry.title == nil ? "Conversation" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.supportsValueNotes, entry.status != "open" {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        PriorityMenuItems(model: model, conversation: entry)
                    } label: {
                        let state = model.priority(of: entry).state
                        Image(systemName: state == "important" ? "star.fill" : state == "less_useful" ? "arrow.down.to.line" : "star")
                            .foregroundStyle(state == "important" ? ValueStyle.important : Color.accentColor)
                    }
                    .accessibilityLabel("Importance")
                }
            }
        }
        // Also after coming back from the speakers screen: names may have changed.
        .onAppear { Task { await load() } }
        .fullScreenCover(item: $naming, onDismiss: { Task { await load() } }) { run in
            NameVoiceView(model: model, items: run.items)
        }
        .refreshable { await load() }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if let title = entry.title {
                    Text([entry.emoji, title].compactMap { $0 }.joined(separator: " ")).font(.title3.weight(.semibold))
                }
                Text(when).font(.subheadline).foregroundStyle(.secondary)
                if entry.displayState.code != "ready" {
                    AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 8) {
                        StateChip(state: entry.displayState)
                        Text(entry.displayState.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// What the phone can do about a failure: keep a no-speaker result, or retry (never a retry the
    /// server says can't help).
    @ViewBuilder private func fixSection(_ d: ConversationDetail) -> some View {
        let issue = model.issues.first { $0.code == "conversation_failed" && $0.conversationId == d.id }
        if model.canKeep, issue?.canKeepFromPhone == true {
            Section {
                if let issue { Text(issue.message).font(.subheadline) }
                RetryControl(model: model, conversationId: d.id, action: .keep)
            } footer: {
                Text([speechLine(d), "Keeping it makes a transcript note with the speaker unknown; the audio stays on the server."]
                    .compactMap { $0 }.joined(separator: " "))
            }
        } else if model.canRetry, issue?.canRetryFromPhone != false {
            Section {
                RetryControl(model: model, conversationId: d.id)
            } footer: {
                Text("Redoes the step that failed. If a service's key or account is the problem, fix that on the server first.")
            }
        }
    }

    /// Detected speech and the recording's length are different figures: say both.
    private func speechLine(_ d: ConversationDetail) -> String? {
        guard let speech = d.speechS, let length = d.entry.duration else { return nil }
        func secs(_ v: Double) -> String { v < 10 ? String(format: "%.1f s", v) : (Fmt.duration(v) ?? "\(Int(v)) s") }
        return "Detected speech: \(secs(speech)) in a \(secs(length)) recording."
    }

    /// How it was resolved from the phone, and what it was before (kept for good on the server).
    @ViewBuilder private func historySection(_ d: ConversationDetail) -> some View {
        if let r = d.resolution {
            Section("History") {
                VStack(alignment: .leading, spacing: 4) {
                    Label(r.message ?? "Resolved from the phone.", systemImage: "checkmark.circle")
                    if let at = r.resolvedAt.flatMap(ISO8601UTC.parse) {
                        Text("\(Fmt.day(at)), \(Fmt.time(at))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if let original = r.original?.message {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(original).font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let line = speechLine(d) { Text(line).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Highlights

    /// A highlight tapped: play from its moment (when the recording has audio there), else its text.
    private func play(_ h: ConversationHighlight, proxy: ScrollViewProxy) {
        guard let t = h.target, let at = t.startAt.flatMap(ISO8601UTC.parse) else { return show(h, proxy: proxy) }
        withAnimation { proxy.scrollTo("recording", anchor: .top) }
        Task {
            if await recording.play(from: at, approximate: t.timing == "coarse") == false { show(h, proxy: proxy) }
        }
    }

    private func show(_ h: ConversationHighlight, proxy: ScrollViewProxy) {
        withAnimation { showTranscript = true }
        let first = h.target?.firstSegment
        Task {
            while let first, detail?.transcript.map({ $0.segments.count <= first && $0.nextFrom != nil }) == true {
                await loadMoreTranscript()
            }
            try? await Task.sleep(for: .milliseconds(350))  // the transcript opens first, then scroll to it
            withAnimation { proxy.scrollTo(first.map { "seg-\($0)" } ?? "transcript", anchor: .top) }
        }
    }

    /// Opened from Home's "Worth revisiting": cue the player at the highlight (no autoplay).
    private func cueFocus() {
        guard !cued, let i = focusHighlight, let hs = detail?.highlights, hs.indices.contains(i),
              let t = hs[i].target, let at = t.startAt.flatMap(ISO8601UTC.parse) else { return }
        cued = true
        recording.cue(at: at, approximate: t.timing == "coarse")
    }

    private var when: String {
        guard let start = entry.startedDate else { return "" }
        var s = "\(Fmt.day(start)), \(Fmt.time(start))"
        if let d = Fmt.duration(entry.duration) { s += " · \(d)" }
        return s
    }

    @ViewBuilder private func caveats(_ d: ConversationDetail) -> some View {
        let notes = caveatLines(d)
        if !notes.isEmpty {
            Section {
                ForEach(notes, id: \.text) { line in
                    Label(line.text, systemImage: line.symbol).font(.footnote).foregroundStyle(line.warning ? .orange : .secondary)
                }
            }
        }
    }

    private struct Line { var text: String; var symbol: String; var warning = false }

    private func caveatLines(_ d: ConversationDetail) -> [Line] {
        var out: [Line] = (d.entry.issues ?? []).map { Line(text: $0.message, symbol: "exclamationmark.circle", warning: true) }
        switch d.noteState {
        case "differs":
            out.append(Line(text: "The saved note was changed outside Omi Notes. This shows what the server generated.", symbol: "pencil.circle"))
        case "missing":
            out.append(Line(text: "The note file isn't in the vault where the server put it.", symbol: "doc.questionmark", warning: true))
        default: break
        }
        if d.noteFrozen == true {
            out.append(Line(text: "This note is frozen: the server no longer updates it, so it may differ from this view.", symbol: "snowflake"))
        }
        if d.entry.provisional == true {
            out.append(Line(text: "Closed before the phone could confirm the conversation had ended. Audio that arrives later becomes a separate note.",
                            symbol: "hourglass"))
        }
        if d.entry.lateAudio == true {
            out.append(Line(text: "Made from audio that arrived after the conversation's note was written.", symbol: "clock.arrow.circlepath"))
        }
        if let lost = d.lostS, lost >= 1 {
            out.append(Line(text: "About \(Fmt.duration(lost) ?? "\(Int(lost)) s") of audio was lost.", symbol: "waveform.slash", warning: true))
        }
        return out
    }

    @ViewBuilder private func summarySection(_ d: ConversationDetail) -> some View {
        Section("Summary") {
            if let s = d.summary {
                Text(s.overview).textSelection(.enabled)
            } else {
                Text(summaryMessage(d)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        if let items = d.summary?.actionItems, !items.isEmpty {
            Section("Action items") {
                ForEach(items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.description, systemImage: "arrow.forward.circle").textSelection(.enabled)
                        let owner = owner(item)
                        if owner != nil || item.dueDate != nil {
                            Text([owner, item.dueDate.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }

    private func owner(_ item: ConversationDetail.Summary.ActionItem) -> String? {
        if let name = item.ownerName { return name }
        return item.owner == "me" ? "You" : nil
    }

    private func summaryMessage(_ d: ConversationDetail) -> String {
        switch d.summaryState {
        case "pending": return d.entry.status == "open" ? "The conversation is still going. The summary comes a few minutes after it ends." : "The summary is being written."
        case "disabled": return "Summaries are turned off on your server. The transcript is below."
        case "failed": return (d.summaryError ?? "The summary couldn't be written.") + " The transcript is below."
        case "not_applicable":
            if d.resolution != nil { return "No summary: it was kept as a transcript because no speaker could be separated." }
            return d.discardReason.map { "Skipped: \($0)" } ?? "This conversation was skipped."
        case "updating": return "The server is reprocessing this conversation. Pull to refresh in a minute."
        default: return "The summary isn't available right now."
        }
    }

    @ViewBuilder private func details(_ s: ConversationDetail.Summary) -> some View {
        ForEach(s.sections, id: \.self) { section in
            Section(section.heading) {
                ForEach(section.bullets, id: \.self) { Text($0).textSelection(.enabled) }
            }
        }
        if !s.decisions.isEmpty {
            Section("Decisions") { ForEach(s.decisions, id: \.self) { Text($0).textSelection(.enabled) } }
        }
        if !s.openQuestions.isEmpty {
            Section("Open questions") { ForEach(s.openQuestions, id: \.self) { Text($0).textSelection(.enabled) } }
        }
    }

    @ViewBuilder private func myNotes(_ d: ConversationDetail) -> some View {
        if let mine = d.myNotes {
            Section("My Notes") { Text(mine).textSelection(.enabled) }
        } else if d.myNotesUnreadable == true {
            Section("My Notes") {
                Label("Your My Notes section couldn't be read because its markers are ambiguous. Fix it in the note file.",
                      systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func obsidianSection(_ d: ConversationDetail) -> some View {
        if let path = d.entry.notePath, let vaultId = model.currentVaultId {
            Section {
                if let name = ObsidianLink.vaultName(for: vaultId), let url = ObsidianLink.url(vault: name, notePath: path) {
                    Button {
                        if UIApplication.shared.canOpenURL(url) {
                            UIApplication.shared.open(url)
                            obsidianMessage = nil
                        } else {
                            obsidianMessage = "Obsidian isn't installed on this phone."
                        }
                    } label: {
                        Label("Open in Obsidian", systemImage: "arrow.up.forward.app")
                    }
                } else {
                    Text("To open notes in Obsidian, enter your vault's name in Settings.").font(.footnote).foregroundStyle(.secondary)
                }
                if let obsidianMessage { Text(obsidianMessage).font(.footnote).foregroundStyle(.orange) }
            } footer: {
                Text("Obsidian Sync may take a moment to bring a new note to this phone.")
            }
        }
    }

    @ViewBuilder private func speakersSection(_ d: ConversationDetail) -> some View {
        if !d.speakers.isEmpty || d.entry.canReviewSpeakers {
            Section {
                if !d.speakers.isEmpty {
                    Text(d.speakers.map { $0.name ?? ConversationDetail.anonymous($0.label) }.joined(separator: ", "))
                }
                if d.entry.canReviewSpeakers, model.speakers.serverSupportsNameVoice,
                   d.speakers.contains(where: { $0.name == nil && $0.label != "unknown" }) {
                    Button { Task { await startNaming(d) } } label: { Label("Name voices", systemImage: "person.wave.2") }
                    if let namingMessage { Text(namingMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                if d.entry.canReviewSpeakers {
                    NavigationLink("Fix speaker names") {
                        ConversationSpeakersView(model: model, conversationId: d.id, title: d.entry.title ?? "Speakers", startedAt: d.entry.startedAt)
                    }
                }
            } header: {
                Text("Speakers")
            } footer: {
                if d.entry.canReviewSpeakers, d.speakers.contains(where: { $0.name == nil && $0.label != "unknown" }) {
                    Text("Naming a speaker teaches the server their voice for future conversations.")
                }
            }
        }
    }

    @ViewBuilder private func transcriptSection(_ d: ConversationDetail) -> some View {
        Section {
            if let t = d.transcript {
                DisclosureGroup(isExpanded: $showTranscript) {
                    ForEach(Array(t.segments.enumerated()), id: \.offset) { index, seg in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(seg.name ?? ConversationDetail.anonymous(seg.speaker)).font(.caption.weight(.semibold))
                                Spacer()
                                Text(Fmt.time(ISO8601UTC.parse(seg.start))).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(seg.text).font(.subheadline).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .id("seg-\(index)")
                    }
                    if t.nextFrom != nil {
                        Button {
                            Task { await loadMoreTranscript() }
                        } label: {
                            HStack {
                                Text("Show more (\(t.segments.count) of \(t.total))")
                                if loadingMore { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(loadingMore)
                    }
                } label: {
                    Text("Transcript · \(t.total) part\(t.total == 1 ? "" : "s")")
                }
            } else {
                Text(transcriptMessage(d)).font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            if d.transcript == nil { Text("Transcript") }
        }
        .id("transcript")
    }

    private func transcriptMessage(_ d: ConversationDetail) -> String {
        switch d.transcriptState {
        case "pending": return d.entry.status == "open" ? "The transcript is made once the conversation ends." : "Transcribing…"
        case "updating": return "The server is reprocessing this conversation. Pull to refresh in a minute."
        default: return "The transcript isn't available right now."
        }
    }

    /// The unnamed voices of this conversation, one at a time.
    private func startNaming(_ d: ConversationDetail) async {
        if model.speakers.settings == nil || model.speakers.people.isEmpty { await model.speakers.refresh() }
        do {
            let speakers = try await model.speakers.speakers(conversationId: d.id)
            let items = VoiceItem.unnamed(speakers, in: ConversationContext(id: d.id, startedAt: d.entry.startedAt, title: d.entry.title))
            namingMessage = items.isEmpty ? "Every voice here has a name or was kept unknown." : nil
            if !items.isEmpty { naming = .init(items: items) }
        } catch {
            namingMessage = "Couldn't load the speakers: \(AppModel.describe(error))"
        }
    }

    // MARK: Loading

    private func load() async {
        do {
            _ = try await model.conversation(summary.id)
            error = nil
        } catch {
            self.error = AppModel.describe(error)
        }
    }

    private func loadMoreTranscript() async {
        loadingMore = true
        defer { loadingMore = false }
        do {
            try await model.loadMoreTranscript(summary.id)
        } catch {
            self.error = AppModel.describe(error)
        }
    }
}
