import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

/// Is it working, does anything need me, and what did I get.
struct HomeView: View {
    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void
    var openPeople: () -> Void

    private var s: EngineSnapshot { model.snapshot }
    @State private var debugOpened: ConversationSummary?
    @State private var query = HomeView.debugSearch
    @State private var naming: ConversationSpeakersView.NamingRun?

    /// Simulator automation only (debug builds): `-OmiNotesDebugOpenConversation YES` opens the
    /// newest conversation once it has loaded (a headless simulator can't tap).
    private static var debugOpenFirst: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "OmiNotesDebugOpenConversation")
        #else
        return false
        #endif
    }

    /// Simulator automation only (debug builds): `-OmiNotesDebugSearch <text>` starts with that search.
    private static var debugSearch: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "OmiNotesDebugSearch") ?? ""
        #else
        return ""
        #endif
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        HealthCard(health: model.health(now: context.date), onFix: onFix)
                    }
                }
                needsYouSection
                WorthRevisitingSection(model: model)
                conversationSections
            } else {
                SearchResults(model: model, query: query)
            }
        }
        .searchable(text: $query, prompt: "Search conversations")
        .navigationTitle("Omi Notes")
        .refreshable { await model.refreshServer() }
        .task { await model.speakers.refresh() }
        .onChange(of: model.recent.first?.id) { _, id in
            if Self.debugOpenFirst, debugOpened == nil, id != nil { debugOpened = model.recent.first }
        }
        .navigationDestination(item: $debugOpened) { c in ConversationDetailView(model: model, summary: c) }
        .fullScreenCover(item: $naming, onDismiss: { Task { await model.speakers.refresh() } }) { r in
            NameVoiceView(model: model, items: r.items)
        }
    }

    // MARK: Needs you

    // Server processing failures are not listed here: the health card and the Server tab show them,
    // and this section is for what the phone's owner can act on.

    private var newVoices: Int { model.speakers.suggestions.count }

    @ViewBuilder private var needsYouSection: some View {
        if !s.attention.isEmpty || newVoices > 0 {
            Section("Needs you") {
                ForEach(s.attention, id: \.self) { msg in
                    Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
                }
                if !s.attention.isEmpty {
                    Button("Dismiss phone messages") { model.engine.clearAttention() }.font(.subheadline)
                }
                if newVoices > 0 {
                    if model.speakers.serverSupportsNameVoice {
                        Button { naming = .init(items: model.speakers.suggestions.map(VoiceItem.init(suggestion:))) } label: {
                            VoicesCard(count: newVoices, names: model.speakers.suggestions.map { s in
                                model.speakers.people.first { $0.id == s.personId }?.name })
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: openPeople) {
                            Label("Improve speaker names: \(newVoices) recurring voice\(newVoices == 1 ? "" : "s") to name",
                                  systemImage: "person.wave.2")
                        }
                    }
                }
            }
        }
    }

    // MARK: Conversations

    private var days: [(day: String, rows: [ConversationSummary])] {
        var out: [(String, [ConversationSummary])] = []
        for c in model.recent {
            let day = c.startedDate.map(Fmt.day) ?? "Earlier"
            if out.last?.0 == day { out[out.count - 1].1.append(c) } else { out.append((day, [c])) }
        }
        return out
    }

    @ViewBuilder private var conversationSections: some View {
        if model.recent.isEmpty {
            Section("Conversations") {
                if let error = model.recentError {
                    Label("Couldn't load conversations: \(error)", systemImage: "wifi.exclamationmark")
                        .font(.subheadline).foregroundStyle(.secondary)
                    NavigationLink("Notes saved on this phone") { SavedConversationsView(model: model) }
                } else if model.serverURL == nil {
                    Text("Connect your server to see your conversations here.").font(.subheadline).foregroundStyle(.secondary)
                } else if model.recentLoadedAt == nil, model.recentSavedAt == nil {
                    HStack { ProgressView(); Text("Loading conversations…").foregroundStyle(.secondary).padding(.leading, 6) }
                } else {
                    Text("No conversations yet. A note appears here a few minutes after a conversation ends.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else {
            ForEach(days, id: \.day) { group in
                Section(group.day) {
                    // only the owner's explicit "less useful" moves a row (into a collapsed group)
                    let demoted = group.rows.filter { model.priorityState(of: $0).state == "less_useful" }
                    ForEach(group.rows.filter { model.priorityState(of: $0).state != "less_useful" }) { c in
                        ConversationLink(model: model, conversation: c)
                    }
                    if !demoted.isEmpty { LessUsefulGroup(model: model, rows: demoted) }
                }
            }
            Section {
                if model.recentCursor != nil {
                    Button {
                        Task { await model.loadMoreConversations() }
                    } label: {
                        HStack {
                            Text("Show older conversations")
                            if model.loadingMore { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.loadingMore)
                }
                if model.recentSavedAt != nil || model.recentError != nil {
                    NavigationLink("Notes saved on this phone") { SavedConversationsView(model: model) }
                }
            } footer: {
                if let saved = model.recentSavedAt {
                    Text("The server can't be reached. Showing the list saved \(Fmt.relative(saved)).")
                } else if let error = model.recentError {
                    Text("Couldn't refresh (\(error)). Showing what was loaded before.")
                }
            }
        }
    }
}

/// A conversation row that opens its note (or, on an older server, its speakers).
struct ConversationLink: View {
    let model: AppModel
    let conversation: ConversationSummary
    /// Lists without day headers (search) show the day in each row.
    var showsDay = false

    private var row: ConversationRow {
        ConversationRow(conversation: conversation, priority: model.priorityState(of: conversation), showsDay: showsDay,
                        priorityMessage: model.priorityMessages[conversation.id])
    }

    var body: some View {
        // A saved copy can be read even before (or without) the server saying what it supports.
        if model.serverStatus?.supportsConversationDetail == true || model.recentSavedAt != nil
            || model.details[conversation.id] != nil {
            NavigationLink { ConversationDetailView(model: model, summary: conversation) } label: { row }
                .modifier(PriorityActions(model: model, conversation: conversation))
        } else if conversation.canReviewSpeakers {
            NavigationLink {
                ConversationSpeakersView(model: model, conversationId: conversation.id, title: conversation.title ?? "Speakers", startedAt: conversation.startedAt)
            } label: { row }
        } else {
            row
        }
    }
}

struct ConversationRow: View {
    let conversation: ConversationSummary
    /// The owner's choice (and whether it is still being saved).
    var priority: (state: String, pending: Bool) = ("auto", false)
    /// The day before the time (lists without day headers).
    var showsDay = false
    /// Why the owner's last importance choice didn't save, if it didn't.
    var priorityMessage: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var c: ConversationSummary { conversation }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveStack(vertical: typeSize.isAccessibilitySize) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if priority.state == "important" {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(ValueStyle.important)
                            .accessibilityLabel("Marked important")
                    }
                    Text(title).font(.body.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    if priority.pending {
                        Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Saving your choice")
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if c.displayState.code != "ready" { StateChip(state: c.displayState) }
            }
            Text(meta).font(.caption).foregroundStyle(.secondary)
            if c.isRecommended, priority.state != "less_useful" { WorthRevisitingLine(highlight: c.value?.highlight) }
            if let preview = c.preview {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else if c.displayState.code != "ready" {
                Text(c.displayState.message).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if let issue = c.issues?.first {
                Label(issue.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            if let priorityMessage {
                Label(priorityMessage, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if let t = c.title { return [c.emoji, t].compactMap { $0 }.joined(separator: " ") }
        return c.displayState.code == "listening" ? "Conversation in progress" : "Conversation"
    }

    private var meta: String {
        var parts = [showsDay ? c.startedDate.map { "\(Fmt.day($0)), \(Fmt.time($0))" } ?? Fmt.time(nil) : Fmt.time(c.startedDate)]
        if let d = Fmt.duration(c.duration) { parts.append(d) }
        if let names = c.speakerNames, !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if c.provisional == true { parts.append("may be incomplete") }
        return parts.joined(separator: " · ")
    }
}

/// Search results under Home's search field: the server's, or the saved copies when offline.
struct SearchResults: View {
    let model: AppModel
    let query: String
    @State private var personId: String?
    @State private var range: AppModel.SearchRange = .any
    @State private var result: AppModel.SearchResult?
    @State private var error: String?
    @State private var loading = false
    /// Bumped when the search changes: an answer (or "Show more") for an earlier one is dropped.
    @State private var generation = 0

    var body: some View {
        Section {
            Picker("When", selection: $range) {
                ForEach(AppModel.SearchRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if !model.speakers.people.isEmpty {
                Picker("Person", selection: $personId) {
                    Text("Anyone").tag(String?.none)
                    ForEach(model.speakers.people) { p in Text(p.name).tag(Optional(p.id)) }
                }
            }
        }
        Section {
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if let result {
                if result.conversations.isEmpty {
                    Text(loading ? "Searching…" : "No matching conversations.").foregroundStyle(.secondary)
                }
                ForEach(result.conversations) { c in ConversationLink(model: model, conversation: c, showsDay: true) }
                if result.nextCursor != nil {
                    Button("Show more") { Task { await load(more: true) } }.disabled(loading)
                }
            } else {
                HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary).padding(.leading, 6) }
            }
        } footer: {
            if result?.serverLacksSearch == true {
                Text("This server doesn't support search yet, so only notes saved on this phone were searched (their transcripts may be partial).")
            } else if result?.offline == true {
                Text("The server can't be reached, so only notes saved on this phone were searched (their transcripts may be partial).")
            } else if let pending = result?.pending, pending > 0 {
                Text("\(pending) conversation\(pending == 1 ? " isn't" : "s aren't") searchable yet; the server is still indexing.")
            }
        }
        .task(id: "\(key)|\(model.serverIdentity)") {
            generation += 1
            result = nil
            error = nil
            try? await Task.sleep(for: .milliseconds(300))  // wait for typing to pause
            guard !Task.isCancelled else { return }
            await load(more: false)
        }
    }

    private var key: String { "\(query)|\(personId ?? "")|\(range.rawValue)" }

    private func load(more: Bool) async {
        let asked = generation
        loading = true
        defer { loading = false }
        let answer = await model.search(query, personId: personId, range: range, before: more ? result?.nextCursor : nil)
        guard asked == generation else { return }  // the search changed meanwhile: this answer is for another one
        switch answer {
        case .failure(is CancellationError):
            return
        case .success(let r):
            if more, var current = result {
                let ids = Set(current.conversations.map(\.id))
                current.conversations += r.conversations.filter { !ids.contains($0.id) }
                current.nextCursor = r.nextCursor
                result = current
            } else {
                result = r
            }
            error = nil
        case .failure(let e):
            result = nil  // never leave results that don't match the chosen search
            error = (e as? LocalizedError)?.errorDescription ?? "Couldn't search: \(AppModel.describe(e))"
        }
    }
}

/// Conversations kept on this phone for reading without a connection.
struct SavedConversationsView: View {
    let model: AppModel

    var body: some View {
        let saved = model.savedConversations()
        List {
            if saved.isEmpty {
                Text("Nothing saved yet. Conversations you open are kept here for reading offline.").foregroundStyle(.secondary)
            }
            ForEach(saved) { d in
                NavigationLink {
                    ConversationDetailView(model: model, summary: d.entry)
                        .onAppear { model.openSaved(d) }
                } label: {
                    ConversationRow(conversation: d.entry, priority: model.priorityState(of: d.entry), showsDay: true,
                                    priorityMessage: model.priorityMessages[d.entry.id])
                }
                .modifier(PriorityActions(model: model, conversation: d.entry))
            }
        }
        .navigationTitle("Saved on this phone")
    }
}

/// "3 voices to name · About a minute": one calm entry to the naming flow.
struct VoicesCard: View {
    let count: Int
    /// The guessed person of each voice, if any.
    let names: [String?]

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -10) {
                ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, name in
                    if let name {
                        Avatar(name: name, size: 30)
                    } else {
                        Text("?").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 30, height: 30).background(Color(.tertiarySystemFill), in: .circle)
                    }
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) voice\(count == 1 ? "" : "s") to name").font(.body.weight(.medium))
                Text(count <= 3 ? "About a minute" : "A few minutes").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
