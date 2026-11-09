import OmiBLE
import OmiProtocol
import SwiftUI

// Value-aware Notes: what the summary recommends (sparkles, indigo) is shown apart from what the
// owner chose ("Important": a yellow star; "Less useful": moved into a collapsed group). Nothing is
// hidden or reordered by the recommendation alone.

extension ConversationSummary {
    var isRecommended: Bool { value?.recommended == true }
}

extension AppModel {
    /// The owner's choice, or "auto" on servers without value notes.
    func priorityState(of c: ConversationSummary) -> (state: String, pending: Bool) {
        supportsValueNotes ? priority(of: c) : ("auto", false)
    }
}

enum ValueStyle {
    static let recommended = Color.indigo
    static let important = Color.yellow

    static func interaction(_ code: String?) -> String? {
        switch code {
        case "conversation": return "Conversation"
        case "dictation": return "Dictation"
        case "reflection": return "Thinking aloud"
        case "call": return "Phone call"
        case "media": return "Media playing"
        case "mixed": return "Mixed recording"
        default: return nil
        }
    }
}

/// "✦ Worth revisiting · The weekend plan": the summary's recommendation on a row.
struct WorthRevisitingLine: View {
    let highlight: String?

    var body: some View {
        Label {
            Text(highlight.map { "Worth revisiting · \($0)" } ?? "Worth revisiting").lineLimit(1)
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(ValueStyle.recommended)
    }
}

/// Swipe and long-press actions for the owner's choice.
struct PriorityActions: ViewModifier {
    let model: AppModel
    let conversation: ConversationSummary

    func body(content: Content) -> some View {
        let values = model.supportsValueNotes
        let kinds = RecordingClassMenu.offered(model: model, conversation: conversation)
        if values || kinds, conversation.status != "open" {
            let state = model.priority(of: conversation).state
            content
                .swipeActions(edge: .leading) {
                    if values, state == "important" {
                        Button { set("auto") } label: { Label("Not Important", systemImage: "star.slash") }.tint(.gray)
                    } else if values {
                        Button { set("important") } label: { Label("Important", systemImage: "star.fill") }.tint(.yellow)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if values, state == "less_useful" {
                        Button { set("auto") } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.blue)
                    } else if values {
                        Button { set("less_useful") } label: { Label("Less Useful", systemImage: "arrow.down.to.line") }.tint(.gray)
                    }
                }
                .contextMenu {
                    if values { PriorityMenuItems(model: model, conversation: conversation) }
                    if kinds { RecordingClassMenu(model: model, conversation: conversation) }
                }
        } else {
            content
        }
    }

    private func set(_ state: String) { Task { await model.setPriority(conversation.id, state) } }
}

/// "Important", "Less Useful", "Restore Automatic" (only what changes something).
struct PriorityMenuItems: View {
    let model: AppModel
    let conversation: ConversationSummary

    var body: some View {
        let state = model.priority(of: conversation).state
        if state != "important" {
            Button { set("important") } label: { Label("Mark Important", systemImage: "star") }
        }
        if state != "less_useful" {
            Button { set("less_useful") } label: { Label("Mark Less Useful", systemImage: "arrow.down.to.line") }
        }
        if state != "auto" {
            Button { set("auto") } label: { Label("Restore Automatic", systemImage: "arrow.uturn.backward") }
        }
    }

    private func set(_ state: String) { Task { await model.setPriority(conversation.id, state) } }
}

/// "Recording Kind ▸ Me talking / Conversation / Background / Automatic": the owner's correction. The current
/// kind is the one the note was made for; a requested one shows as "Changing to …" until the server applies it.
struct RecordingClassMenu: View {
    let model: AppModel
    let conversation: ConversationSummary

    /// Only for summarized notes on servers with recording classes.
    static func offered(model: AppModel, conversation: ConversationSummary) -> Bool {
        model.supportsRecordingClass && conversation.status != "open" && model.recordingClass(of: conversation)?.kind != nil
    }

    var body: some View {
        let view = model.recordingClass(of: conversation)
        // the owner's standing choice (pending, or applied); the automatic kind can still be pinned
        let chosen = view?.isUpdating == true ? view?.requested : (view?.overridden == true ? view?.kind : nil)
        Menu {
            ForEach(RecordingClassView.kinds, id: \.self) { kind in
                Button { set(kind) } label: {
                    Label(RecordingClassStyle.name(kind), systemImage: view?.kind == kind ? "checkmark" : RecordingClassStyle.icon(kind))
                }
                .disabled(chosen == kind)
            }
            if chosen != nil && chosen != "auto" {
                Button { set("auto") } label: {
                    Label("Automatic (\(RecordingClassStyle.name(view?.auto)))", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label("Recording Kind", systemImage: "waveform")
        }
    }

    private func set(_ kind: String) { Task { await model.setRecordingClass(conversation.id, kind) } }
}

enum RecordingClassStyle {
    static func name(_ kind: String?) -> String {
        switch kind {
        case "monologue": "Me talking"
        case "dialogue": "Conversation"
        case "passive": "Background"
        case "auto": "Automatic"
        default: "Not known yet"
        }
    }

    static func icon(_ kind: String?) -> String {
        switch kind {
        case "monologue": "person.wave.2"
        case "passive": "speaker.wave.2"
        default: "person.2"
        }
    }
}

/// "Me" / "Background" on a row (a conversation is the default and has no badge), and "Changing to …" while
/// the owner's choice waits for its new summary.
struct RecordingClassBadge: View {
    let view: RecordingClassView?

    var body: some View {
        if let view {
            HStack(spacing: 6) {
                if view.kind == "monologue" || view.kind == "passive" {
                    Label(RecordingClassView.title(view.kind) ?? "", systemImage: RecordingClassStyle.icon(view.kind))
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                }
                if view.isUpdating, view.updateFailed != nil {
                    Label("Couldn't change the kind yet", systemImage: "exclamationmark.circle")
                        .font(.caption2).foregroundStyle(.orange)
                } else if view.isUpdating {
                    Label(view.requested == "auto" ? "Going back to automatic…"
                          : "Changing to \(RecordingClassStyle.name(view.requested).lowercased())…", systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Home's top: up to four conversations worth revisiting (marked important, then recommended).
struct WorthRevisitingSection: View {
    let model: AppModel

    /// The owner's "Important" first (their marks win), then recommendations; newest first in each.
    private var picks: [ConversationSummary] {
        let shown = model.recent.filter { model.priority(of: $0).state != "less_useful" }
        let important = shown.filter { model.priority(of: $0).state == "important" }
        let recommended = shown.filter { $0.isRecommended && model.priority(of: $0).state != "important" }
        return Array((important + recommended).prefix(4))
    }

    var body: some View {
        if model.supportsValueNotes, !picks.isEmpty {
            Section {
                ForEach(picks) { c in
                    NavigationLink {
                        ConversationDetailView(model: model, summary: c, focusHighlight: c.isRecommended ? 0 : nil)
                    } label: {
                        pickRow(c)
                    }
                    .modifier(PriorityActions(model: model, conversation: c))
                }
            } header: {
                Text("Worth revisiting")
            } footer: {
                Text("Suggested from each note's own content. Your marks always win.")
            }
        }
    }

    private func pickRow(_ c: ConversationSummary) -> some View {
        let important = model.priority(of: c).state == "important"
        let pending = model.priorityState(of: c).pending
        let failed = model.priorityMessages[c.id]
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: important ? "star.fill" : "sparkles")
                .font(.title3).foregroundStyle(important ? ValueStyle.important : ValueStyle.recommended)
                .frame(width: 28, height: 28)
                .background((important ? ValueStyle.important : ValueStyle.recommended).opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text([c.emoji, c.title ?? "Conversation"].compactMap { $0 }.joined(separator: " "))
                    .font(.body.weight(.medium)).lineLimit(2)
                if let h = c.value?.highlight, c.isRecommended {
                    Text(h).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(meta(c, important: important)).font(.caption).foregroundStyle(.secondary)
                PriorityFeedback(pending: pending, message: failed)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([ "\(important ? "Important" : "Worth revisiting"): \(c.title ?? "Conversation")" ]
                             + [c.isRecommended ? c.value?.highlight : nil, meta(c, important: important),
                                PriorityFeedback.spoken(pending: pending, message: failed)].compactMap { $0 })
                            .joined(separator: ". "))
    }

    private func meta(_ c: ConversationSummary, important: Bool) -> String {
        let when = c.startedDate.map { "\(Fmt.day($0)), \(Fmt.time($0))" } ?? ""
        let mark = c.value?.user?.source == "pendant" ? "Starred from the pendant" : "Marked important"
        return [when, important ? mark : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Where an importance choice stands, on whichever row it was made: still saving, or why it didn't
/// save. Shared by the day rows, search, saved notes and the Worth revisiting cards.
struct PriorityFeedback: View {
    let pending: Bool
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(2)
        } else if pending {
            Label("Saving your choice…", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func spoken(pending: Bool, message: String?) -> String? {
        message ?? (pending ? "Saving your choice" : nil)
    }
}

/// A day's rows the owner marked less useful, collapsed at the end of that day.
struct LessUsefulGroup: View {
    let model: AppModel
    let rows: [ConversationSummary]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(rows) { c in ConversationLink(model: model, conversation: c) }
        } label: {
            Label("Marked less useful (\(rows.count))", systemImage: "arrow.down.to.line")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// A day's short (under 30 s) and skipped recordings, folded into one row; they open to the same rows.
struct ShortClipsGroup: View {
    let model: AppModel
    let rows: [ConversationSummary]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(rows) { c in ConversationLink(model: model, conversation: c) }
        } label: {
            Label("Short clips (\(rows.count))", systemImage: "waveform.path")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// The detail's "Worth revisiting": the kind of recording, why, and the parts to revisit.
struct ValueDetailSection: View {
    let detail: ConversationDetail
    let canPlay: Bool
    var onPlay: (ConversationHighlight) -> Void
    var onShow: (ConversationHighlight) -> Void

    private var highlights: [ConversationHighlight] { detail.highlights ?? [] }
    private var reasons: [String] { detail.valueReasons ?? [] }

    var body: some View {
        if detail.entry.isRecommended || !highlights.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if detail.entry.isRecommended {
                        Label("Worth revisiting", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                            .foregroundStyle(ValueStyle.recommended)
                    }
                    let kind = ValueStyle.interaction(detail.entry.value?.interaction)
                    let why = ([kind] + reasons.map { Optional($0) }).compactMap { $0 }
                    if !why.isEmpty { Text(why.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                }
                ForEach(Array(highlights.enumerated()), id: \.offset) { _, h in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(h.title).font(.body.weight(.medium))
                        if let why = h.why, !why.isEmpty { Text(why).font(.subheadline).foregroundStyle(.secondary) }
                        HStack(spacing: 10) {
                            if let target = h.target {
                                if canPlay {
                                    Button { onPlay(h) } label: {
                                        Label(playLabel(target), systemImage: "play.circle.fill")
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                }
                                Button("Show in transcript") { onShow(h) }.buttonStyle(.borderless).font(.subheadline)
                            } else {
                                Button("Open the transcript") { onShow(h) }.buttonStyle(.borderless).font(.subheadline)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(highlights.isEmpty ? "Why it matters" : "Highlights")
            }
        }
    }

    private func playLabel(_ t: ConversationHighlight.Target) -> String {
        guard let at = t.startAt.flatMap(ISO8601UTC.parse) else { return "Play this part" }
        let clock = at.formatted(date: .omitted, time: .shortened)
        return t.timing == "coarse" ? "Play from around \(clock)" : "Play from \(clock)"
    }
}
