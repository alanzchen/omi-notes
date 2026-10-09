import Foundation
import Observation
import OmiCapture
import OmiProtocol

/// One voice to name: a recurring voice the server suggests, or one speaker of one conversation.
public struct VoiceItem: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case suggestion(SpeakerSuggestion)
        case label(conversationId: String, label: String)
    }

    public enum Question: Equatable, Sendable {
        /// "Is this Priya?" — the server's guess, or the name the speaker has now.
        case isThis(personId: String)
        case isThisYou
        case whoIsThis
    }

    public var target: Target
    public var question: Question
    /// Where the clips were heard.
    public var context: ConversationContext?
    public var clips: [SpeakerClip]
    /// The same voice on another day, when there is one.
    public var otherDay: SpeakerClip?
    /// Every conversation naming this voice changes (one for a single speaker).
    public var scope: [ConversationContext]

    public var id: String {
        switch target {
        case .suggestion(let s): return "s:\(s.id)"
        case .label(let c, let l): return "l:\(c):\(l)"
        }
    }

    public var spansConversations: Bool { scope.count > 1 }

    public init(target: Target, question: Question, context: ConversationContext?, clips: [SpeakerClip],
                otherDay: SpeakerClip? = nil, scope: [ConversationContext]) {
        self.target = target
        self.question = question
        self.context = context
        self.clips = clips
        self.otherDay = otherDay
        self.scope = scope
    }

    public init(suggestion s: SpeakerSuggestion) {
        let question: Question
        switch s.kind {
        case "is_this_person": question = s.personId.map { .isThis(personId: $0) } ?? .whoIsThis
        case "is_this_you": question = .isThisYou
        default: question = .whoIsThis
        }
        let clips = s.clips ?? s.clipId.map { [SpeakerClip(id: $0, text: s.excerpt)] } ?? []
        self.init(target: .suggestion(s), question: question, context: s.conversation, clips: clips,
                  otherDay: s.otherDay, scope: s.scope ?? (s.conversation.map { [$0] } ?? []))
    }

    /// A speaker of one conversation: asks about its current name if it has one.
    public init(label l: SpeakerLabel, in conversation: ConversationContext) {
        let clips = l.clips ?? l.clipId.map { [SpeakerClip(id: $0, text: l.excerpt)] } ?? []
        self.init(target: .label(conversationId: conversation.id, label: l.label),
                  question: l.personId.map { .isThis(personId: $0) } ?? .whoIsThis,
                  context: conversation, clips: clips, scope: [conversation])
    }

    /// The speakers of a conversation still to name: no name and not kept unknown.
    public static func unnamed(_ speakers: ConversationSpeakers, in conversation: ConversationContext) -> [VoiceItem] {
        speakers.labels.filter { $0.personId == nil && $0.keptUnknown != true && $0.label != "unknown" }
            .map { VoiceItem(label: $0, in: conversation) }
    }
}

/// Listen → answer → next, over a list of voices. Every answer goes to the server at once (and
/// can be undone for a few seconds); "Skip" only moves on for this session, while "Keep unknown"
/// is the server's permanent decision. Nothing here assumes consent: the screen asks first.
@MainActor
@Observable
public final class NameVoiceFlow {
    public struct Saved: Equatable, Sendable {
        public var item: VoiceItem
        /// nil when kept unknown.
        public var person: Person?
        public var requestId: String
    }

    public private(set) var items: [VoiceItem]
    public private(set) var index = 0
    public private(set) var saved: [Saved] = []
    public private(set) var skipped: [VoiceItem] = []
    /// The last answer, while it can still be undone.
    public private(set) var undoable: Saved?
    public private(set) var busy = false
    public private(set) var error: String?
    public var undoWindow: Duration = .seconds(6)

    private let speakers: SpeakersModel
    private var revisions: [String: Int]
    private var undoTimer: Task<Void, Never>?

    public init(speakers: SpeakersModel, items: [VoiceItem], revisions: [String: Int] = [:]) {
        self.speakers = speakers
        self.items = items
        self.revisions = revisions
    }

    public var current: VoiceItem? { items.indices.contains(index) ? items[index] : nil }
    public var isFinished: Bool { index >= items.count }

    /// Names the current voice (after the screen confirmed consent and, if needed, the scope).
    @discardableResult
    public func name(_ person: Person) async -> Bool { await answer(person: person, keepUnknown: false) }

    /// The owner's permanent "this voice stays unknown" (after the screen confirmed the scope).
    @discardableResult
    public func keepUnknown() async -> Bool { await answer(person: nil, keepUnknown: true) }

    /// Not sure: on to the next voice; it is asked again another time.
    public func skip() {
        guard let item = current else { return }
        skipped.append(item)
        index += 1
        error = nil
    }

    public func undo() async {
        guard let last = undoable, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await speakers.undoNaming(requestId: last.requestId)
            if case .label(let conv, _) = last.item.target { revisions[conv] = nil }
            undoTimer?.cancel()
            undoable = nil
            saved.removeAll { $0.requestId == last.requestId }
            if r.undone.isEmpty && !r.skipped.isEmpty {
                error = "It was changed again since, so that later choice was kept."
                return
            }
            // ask about the same voice again, right here
            if let at = items.firstIndex(where: { $0.id == last.item.id }), at < index {
                items.remove(at: at)
                index -= 1
            }
            items.insert(last.item, at: index)
            error = nil
        } catch {
            self.error = "Couldn't undo: \(SpeakersModel.describe(error))"
        }
    }

    private func answer(person: Person?, keepUnknown: Bool) async -> Bool {
        guard let item = current, !busy else { return false }
        busy = true
        defer { busy = false }
        let requestId = UUID().uuidString.lowercased()
        do {
            switch item.target {
            case .suggestion(let s):
                if let person {
                    try await speakers.assignSuggestion(s, personId: person.id, requestId: requestId)
                } else {
                    try await speakers.keepUnknown(s, requestId: requestId)
                }
            case .label(let conv, let label):
                let revision = try await revision(of: conv)
                let result = try await speakers.assignLabel(conversationId: conv, label: label, personId: person?.id,
                                                            keepUnknown: keepUnknown, revision: revision, requestId: requestId)
                revisions[conv] = result.revision
            }
        } catch APIError.http(409, _) {
            if case .label(let conv, _) = item.target { revisions[conv] = nil }
            error = "The speakers changed on the server meanwhile. Check and try again."
            return false
        } catch {
            self.error = "Couldn't save: \(SpeakersModel.describe(error))"
            return false
        }
        let done = Saved(item: item, person: person, requestId: requestId)
        saved.append(done)
        undoable = done
        error = nil
        index += 1
        undoTimer?.cancel()
        let window = undoWindow
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            if self?.undoable?.requestId == done.requestId { self?.undoable = nil }
        }
        return true
    }

    private func revision(of conv: String) async throws -> Int {
        if let r = revisions[conv] { return r }
        let fresh = try await speakers.speakers(conversationId: conv).revision
        revisions[conv] = fresh
        return fresh
    }
}

/// Bar heights for a clip's waveform, from its own samples (16-bit PCM WAV): nothing is drawn
/// that isn't in the audio.
public enum Waveform {
    public static func bars(wav: Data, count: Int) -> [Float]? {
        guard count > 0, let pcm = samples(wav), !pcm.isEmpty else { return nil }
        let per = max(1, pcm.count / count)
        var out: [Float] = []
        for i in 0..<count {
            let lo = i * per
            guard lo < pcm.count else { out.append(0); continue }
            let slice = pcm[lo..<min(pcm.count, lo + per)]
            let rms = (slice.reduce(Float(0)) { $0 + Float($1) * Float($1) } / Float(slice.count)).squareRoot()
            out.append(rms)
        }
        let peak = out.max() ?? 0
        return peak > 0 ? out.map { $0 / peak } : out
    }

    /// The `data` chunk of a PCM16 WAV file.
    static func samples(_ wav: Data) -> [Int16]? {
        let bytes = [UInt8](wav)
        guard bytes.count > 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF" else { return nil }
        var at = 12
        while at + 8 <= bytes.count {
            let id = String(bytes: bytes[at..<at + 4], encoding: .ascii)
            let size = Int(bytes[at + 4]) | Int(bytes[at + 5]) << 8 | Int(bytes[at + 6]) << 16 | Int(bytes[at + 7]) << 24
            let body = at + 8
            if id == "data" {
                let end = min(bytes.count, body + size)
                return stride(from: body, to: end - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
            }
            at = body + size + (size % 2)
        }
        return nil
    }
}
