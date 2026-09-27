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

    @State private var error: String?
    @State private var loadingMore = false
    @State private var showTranscript = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var detail: ConversationDetail? { model.details[summary.id] }
    private var entry: ConversationSummary { detail?.entry ?? summary }

    var body: some View {
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
                if detail.entry.status == "failed", model.canRetry, model.detailSavedAt[summary.id] == nil {
                    Section {
                        RetryControl(model: model, conversationId: detail.id)
                    } footer: {
                        Text("Redoes the step that failed. If a service's key or account is the problem, fix that on the server first.")
                    }
                }
                caveats(detail)
                summarySection(detail)
                if let s = detail.summary { details(s) }
                myNotes(detail)
                speakersSection(detail)
                transcriptSection(detail)
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
        .navigationTitle(entry.title == nil ? "Conversation" : "")
        .navigationBarTitleDisplayMode(.inline)
        // Also after coming back from the speakers screen: names may have changed.
        .onAppear { Task { await load() } }
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
        case "not_applicable": return d.discardReason.map { "Skipped: \($0)" } ?? "This conversation was skipped."
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

    @ViewBuilder private func speakersSection(_ d: ConversationDetail) -> some View {
        if !d.speakers.isEmpty || d.entry.canReviewSpeakers {
            Section {
                if !d.speakers.isEmpty {
                    Text(d.speakers.map { $0.name ?? ConversationDetail.anonymous($0.label) }.joined(separator: ", "))
                }
                if d.entry.canReviewSpeakers {
                    NavigationLink("Fix speaker names") {
                        ConversationSpeakersView(model: model, conversationId: d.id, title: d.entry.title ?? "Speakers")
                    }
                }
            } header: {
                Text("Speakers")
            } footer: {
                if d.speakers.contains(where: { $0.name == nil }) {
                    Text("Naming a speaker teaches the server their voice for future conversations.")
                }
            }
        }
    }

    @ViewBuilder private func transcriptSection(_ d: ConversationDetail) -> some View {
        Section {
            if let t = d.transcript {
                DisclosureGroup(isExpanded: $showTranscript) {
                    ForEach(Array(t.segments.enumerated()), id: \.offset) { _, seg in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(seg.name ?? ConversationDetail.anonymous(seg.speaker)).font(.caption.weight(.semibold))
                                Spacer()
                                Text(Fmt.time(ISO8601UTC.parse(seg.start))).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(seg.text).font(.subheadline).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
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
    }

    private func transcriptMessage(_ d: ConversationDetail) -> String {
        switch d.transcriptState {
        case "pending": return d.entry.status == "open" ? "The transcript is made once the conversation ends." : "Transcribing…"
        case "updating": return "The server is reprocessing this conversation. Pull to refresh in a minute."
        default: return "The transcript isn't available right now."
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
