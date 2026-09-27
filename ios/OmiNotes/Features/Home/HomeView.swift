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

    /// Simulator automation only (debug builds): `-OmiNotesDebugOpenConversation YES` opens the
    /// newest conversation once it has loaded (a headless simulator can't tap).
    private static var debugOpenFirst: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "OmiNotesDebugOpenConversation")
        #else
        return false
        #endif
    }

    var body: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HealthCard(health: model.health(now: context.date), onFix: onFix)
                }
            }
            needsYouSection
            conversationSections
        }
        .navigationTitle("Omi Notes")
        .refreshable { await model.refreshServer() }
        .task { await model.speakers.refresh() }
        .onChange(of: model.recent.first?.id) { _, id in
            if Self.debugOpenFirst, debugOpened == nil, id != nil { debugOpened = model.recent.first }
        }
        .navigationDestination(item: $debugOpened) { c in ConversationDetailView(model: model, summary: c) }
    }

    // MARK: Needs you

    private var serverProblems: [ServerIssue] { model.issues.filter(\.needsAction) }
    private var newVoices: Int { model.speakers.suggestions.count }

    @ViewBuilder private var needsYouSection: some View {
        if !s.attention.isEmpty || !serverProblems.isEmpty || newVoices > 0 {
            Section("Needs you") {
                ForEach(s.attention, id: \.self) { msg in
                    Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
                }
                if !s.attention.isEmpty {
                    Button("Dismiss phone messages") { model.engine.clearAttention() }.font(.subheadline)
                }
                if !serverProblems.isEmpty {
                    Button { onFix(.openServer) } label: {
                        Label(serverProblems.count == 1 ? serverProblems[0].message : "\(serverProblems.count) problems on the server",
                              systemImage: "server.rack")
                    }
                }
                if newVoices > 0 {
                    Button(action: openPeople) {
                        Label("Improve speaker names: \(newVoices) recurring voice\(newVoices == 1 ? "" : "s") to name",
                              systemImage: "person.wave.2")
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
                } else if model.serverURL == nil {
                    Text("Connect your server to see your conversations here.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("No conversations yet. A note appears here a few minutes after a conversation ends.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else {
            ForEach(days, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.rows) { c in ConversationLink(model: model, conversation: c) }
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
            } footer: {
                if let error = model.recentError {
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

    var body: some View {
        if model.serverStatus?.supportsConversationDetail == true {
            NavigationLink { ConversationDetailView(model: model, summary: conversation) } label: { ConversationRow(conversation: conversation) }
        } else if conversation.canReviewSpeakers {
            NavigationLink {
                ConversationSpeakersView(model: model, conversationId: conversation.id, title: conversation.title ?? "Speakers")
            } label: { ConversationRow(conversation: conversation) }
        } else {
            ConversationRow(conversation: conversation)
        }
    }
}

struct ConversationRow: View {
    let conversation: ConversationSummary

    private var c: ConversationSummary { conversation }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 8)
                if c.displayState.code != "ready" { StateChip(state: c.displayState) }
            }
            Text(meta).font(.caption).foregroundStyle(.secondary)
            if let preview = c.preview {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else if c.displayState.code != "ready" {
                Text(c.displayState.message).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if let issue = c.issues?.first {
                Label(issue.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(2)
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
        var parts = [Fmt.time(c.startedDate)]
        if let d = Fmt.duration(c.duration) { parts.append(d) }
        if let names = c.speakerNames, !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if c.provisional == true { parts.append("may be incomplete") }
        return parts.joined(separator: " · ")
    }
}
