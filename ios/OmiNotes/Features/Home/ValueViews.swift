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
        if model.supportsValueNotes, conversation.status != "open" {
            let state = model.priority(of: conversation).state
            content
                .swipeActions(edge: .leading) {
                    if state == "important" {
                        Button { set("auto") } label: { Label("Not Important", systemImage: "star.slash") }.tint(.gray)
                    } else {
                        Button { set("important") } label: { Label("Important", systemImage: "star.fill") }.tint(.yellow)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if state == "less_useful" {
                        Button { set("auto") } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.blue)
                    } else {
                        Button { set("less_useful") } label: { Label("Less Useful", systemImage: "arrow.down.to.line") }.tint(.gray)
                    }
                }
                .contextMenu { PriorityMenuItems(model: model, conversation: conversation) }
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
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(important ? "Important" : "Worth revisiting"): \(c.title ?? "Conversation")")
    }

    private func meta(_ c: ConversationSummary, important: Bool) -> String {
        let when = c.startedDate.map { "\(Fmt.day($0)), \(Fmt.time($0))" } ?? ""
        return [when, important ? "Marked important" : nil].compactMap { $0 }.joined(separator: " · ")
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
