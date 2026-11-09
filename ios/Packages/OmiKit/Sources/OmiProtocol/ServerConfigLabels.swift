import Foundation

/// A configured service (transcription or summaries) as the Server page shows it: one short line
/// that fits a row, a health, and the full names for the details. Model labels are non-secret.
public struct ServiceLabel: Equatable, Sendable {
    public enum Health: Equatable, Sendable {
        /// Configured; for the local engine, its health check answered (not proof of a transcript).
        case ok
        /// The local engine isn't answering.
        case down
        case notSetUp
        case unknown
        /// From an answer that isn't current (the latest request failed, or it is older than
        /// `currentFor`): the names still hold, the health may not.
        case lastKnown
    }
    /// A status answer, and the local engine's last check, count as current this long (the app's
    /// `SystemHealth.staleAfter`: an older server answer is unknown).
    public static let currentFor: TimeInterval = 5 * 60
    public struct Detail: Equatable, Sendable, Hashable {
        public var title: String
        public var value: String
    }
    public var text: String
    public var health: Health
    public var details: [Detail]
}

/// Short names for providers and models: "Local", "Qwen" from `mlx-community/Qwen3-ASR-1.7B-bf16`.
public enum ServiceNames {
    /// A row's model part stays under this many characters.
    static let shortLimit = 18

    /// The display name of a provider; nil for an OpenAI-compatible API (its model says more).
    public static func provider(_ p: String) -> String? {
        switch p {
        case "local": return "Local"
        case "openai": return nil
        case "deepgram": return "Deepgram"
        case "anthropic": return "Anthropic"
        case "fake": return "Fake"
        default: return p
        }
    }

    /// The model's family: the first word of its name without a trailing version ("Qwen3" → "Qwen").
    public static func family(_ id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        let first = name.split(separator: "-").first.map(String.init) ?? name
        let trimmed = String(first.reversed().drop { $0.isNumber || $0 == "." }.reversed())
        return trimmed.isEmpty ? first : trimmed
    }

    /// A short model label: a combined "A (role) · B (role)" label becomes its families ("MOSS + Qwen");
    /// a long name keeps its leading words.
    public static func shortModel(_ model: String) -> String {
        let pieces = pieces(model)
        if pieces.count > 1 { return families(pieces.map(\.model)) }
        let name = model.split(separator: "/").last.map(String.init) ?? model
        if name.count <= shortLimit { return name }
        var out = ""
        for word in name.split(separator: "-") {
            let next = out.isEmpty ? String(word) : out + "-" + word
            if !out.isEmpty, next.count > shortLimit { break }
            out = next
        }
        return out
    }

    static func families(_ ids: [String]) -> String {
        var seen: [String] = []
        for f in ids.map(family) where !seen.contains(f) { seen.append(f) }
        return seen.joined(separator: " + ")
    }

    /// "MOSS-Transcribe-Diarize (speakers) · Qwen3-ASR (text)" → [(model, role)].
    static func pieces(_ model: String) -> [(model: String, role: String?)] {
        model.components(separatedBy: " · ").map { piece in
            let p = piece.trimmingCharacters(in: .whitespaces)
            if p.hasSuffix(")"), let open = p.lastIndex(of: "(") {
                return (p[..<open].trimmingCharacters(in: .whitespaces), String(p[p.index(after: open)..<p.index(before: p.endIndex)]))
            }
            return (p, nil)
        }
    }

    static func roleTitle(_ role: String) -> String {
        switch role {
        case "diarization", "speakers": return "Speakers"
        case "text": return "Text"
        case "aligner", "timing": return "Timing"
        default: return role.prefix(1).uppercased() + role.dropFirst()
        }
    }

    /// Where speakers are separated (STT `diarization`).
    public static func diarization(_ mode: String) -> String {
        switch mode {
        case "local": return "On the server"
        case "provider": return "By the transcription service"
        case "off": return "Off"
        default: return "Automatic"
        }
    }
}

extension ServerStatus {
    /// The rows as of the answer itself (the engine check's age by the server's clock only).
    public var transcriptionLabel: ServiceLabel {
        Self.label(stt, local: localTranscription, checkAge: engineCheckAge(answeredAt: nil, now: nil), current: true)
    }
    public var summariesLabel: ServiceLabel { Self.label(llm, local: nil, checkAge: nil, current: true) }

    /// The rows as of `now`, for this answer received at `answeredAt`. The names always come from it, but
    /// a health only while it is current: the latest request got an answer, no more than `currentFor`
    /// ago (and not dated ahead of this phone); otherwise any health is `lastKnown`. The local engine's
    /// last check (`local_transcription.checked_at`) counts only while it is that recent too.
    public func serviceLabels(answeredAt: Date?, latestRequestFailed: Bool, now: Date) -> (transcription: ServiceLabel, summaries: ServiceLabel) {
        let age = answeredAt.map { now.timeIntervalSince($0) }
        let current = !latestRequestFailed && age.map { $0 <= ServiceLabel.currentFor && $0 >= -60 } == true
        return (Self.label(stt, local: localTranscription, checkAge: engineCheckAge(answeredAt: answeredAt, now: now), current: current),
                Self.label(llm, local: nil, checkAge: nil, current: current))
    }

    /// Seconds since the server last checked the local engine: by the server's clock at the answer
    /// (this phone's when the server didn't say), plus the answer's own age. nil when it can't be told.
    func engineCheckAge(answeredAt: Date?, now: Date?) -> TimeInterval? {
        guard let checked = localTranscription?.checkedAt.flatMap(ISO8601UTC.parse),
              let answer = serverTime.flatMap(ISO8601UTC.parse) ?? answeredAt else { return nil }
        let since = answeredAt.flatMap { a in now.map { max(0, $0.timeIntervalSince(a)) } } ?? 0
        return max(0, answer.timeIntervalSince(checked)) + since
    }

    static func label(_ p: Provider?, local: LocalTranscription?, checkAge: TimeInterval?, current: Bool) -> ServiceLabel {
        guard let p, let provider = p.provider else { return ServiceLabel(text: "—", health: .unknown, details: []) }
        if provider == "none" { return ServiceLabel(text: "Turned off", health: .unknown, details: []) }
        let engine = p.engine
        var health: ServiceLabel.Health
        if provider == "local" || engine != nil {
            // answering needs a health check (the engine's own, or the worker's recent one); configured isn't enough
            let available = (checkAge.map { $0 <= ServiceLabel.currentFor } ?? true) ? local?.available : nil
            health = engine?.healthy == false || available == false || p.ready == false ? .down
                : engine?.healthy == true || available == true ? .ok : .unknown
        } else {
            health = p.ready == false ? .notSetUp : p.ready == true ? .ok : .unknown
        }
        if !current, health != .unknown { health = .lastKnown }
        let name = ServiceNames.provider(provider)
        let roleOrder = ["diarization", "text", "aligner"]
        let engineModels = (engine?.models ?? [:]).sorted {
            (roleOrder.firstIndex(of: $0.key) ?? roleOrder.count, $0.key) < (roleOrder.firstIndex(of: $1.key) ?? roleOrder.count, $1.key)
        }
        let model = !engineModels.isEmpty ? ServiceNames.families(engineModels.map(\.value)) : p.model.map(ServiceNames.shortModel)

        let text: String
        switch health {
        case .down: text = "\(name ?? "OpenAI-compatible") · not responding"
        case .notSetUp: text = "\(name ?? "OpenAI-compatible") · not set up"
        case .ok, .unknown, .lastKnown:
            let parts = [name, model].compactMap { $0 }.filter { !$0.isEmpty }
            text = parts.isEmpty ? "OpenAI-compatible" : parts.joined(separator: " · ")
        }

        var details: [ServiceLabel.Detail] = []
        if !engineModels.isEmpty {
            details += engineModels.map { .init(title: ServiceNames.roleTitle($0.key), value: $0.value) }
        } else if let m = p.model {
            let pieces = ServiceNames.pieces(m)
            if pieces.count > 1 {
                details += pieces.map { .init(title: $0.role.map(ServiceNames.roleTitle) ?? "Model", value: $0.model) }
            } else {
                details.append(.init(title: "Model", value: m))
            }
        }
        if let engine {
            let line = [engine.name, engine.selfTest.map { "self-test \($0)" }].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty { details.append(.init(title: "Engine", value: line)) }
        }
        if let since = local?.downSince.flatMap(ISO8601UTC.parse) {
            details.append(.init(title: "Not responding since", value: since.formatted(date: .abbreviated, time: .shortened)))
        }
        if let d = p.diarization { details.append(.init(title: "Speaker separation", value: ServiceNames.diarization(d))) }
        return ServiceLabel(text: text, health: health, details: details)
    }
}
