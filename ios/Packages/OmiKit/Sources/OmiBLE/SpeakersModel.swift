import Foundation
import Observation
import OmiCapture
import OmiProtocol

/// People, recognition settings, suggestions and the voice-enrollment flow
/// (docs/speaker-learning.md). All permanent state lives on the server's vault; this is a view model.
@MainActor
@Observable
public final class SpeakersModel {
    public enum Enrollment: Equatable {
        case idle
        /// Asking the server whether it supports voice enrollment (nothing started yet).
        case checking
        /// Reading prompts; the window is open on the live capture.
        case reading(id: String, prompt: Int)
        /// Window closed; the server is waiting for / processing the audio.
        case waiting(id: String, status: EnrollmentStatus?)
        case finished(EnrollmentStatus)
        case failed(String)
    }

    public static let prompts = [
        "I'm wearing my Omi so it can learn what my voice sounds like.",
        "Yesterday I spent most of the afternoon catching up on messages and planning the week ahead.",
        "My favorite way to relax is a long walk, some music, and maybe a good cup of coffee.",
        "When I describe a busy day, I usually talk a little faster than I expect to.",
        "The quick brown fox jumps over the lazy dog, and then everyone takes a short break.",
        "That's everything for now; thanks for listening to me read these sentences out loud.",
    ]

    public private(set) var people: [Person] = []
    public private(set) var settings: SpeakerSettings?
    public private(set) var suggestions: [SpeakerSuggestion] = []
    public private(set) var error: String?
    public private(set) var loading = false
    /// nil until the server's status was read.
    public private(set) var serverSupportsEnrollment: Bool?
    public var enrollment: Enrollment = .idle

    private let engine: OmiEngine
    private var pollTask: Task<Void, Never>?

    public init(engine: OmiEngine) { self.engine = engine }

    public var me: Person? { people.first { $0.isMe } }
    public var others: [Person] { people.filter { !$0.isMe } }

    /// Injectable for tests (no network).
    public var session: URLSession = APIClient.defaultSession

    private func api() throws -> APIClient {
        guard let endpoint = engine.settings.endpoint else { throw APIError.notConfigured }
        return APIClient(endpoint: endpoint, session: session)
    }

    // MARK: Loading

    public func refresh() async {
        loading = true
        defer { loading = false }
        // First and on its own: an older server fails the calls below, and must not keep the
        // capability of the server that answered last time.
        serverSupportsEnrollment = nil
        serverSupportsEnrollment = try? await api().status().supportsVoiceEnrollment
        do {
            let api = try api()
            async let p = api.people()
            async let s = api.speakerSettings()
            people = try await p
            settings = try await s
            suggestions = settings?.unknownVoicesEnabled == true ? (try await api.speakerSuggestions()) : []
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Settings

    public func acknowledgeRecognition() async {
        await updateSettings { $0.acknowledgedAt = ISO8601UTC.format(Date()) }
    }

    public func setUnknownVoices(_ on: Bool) async { await updateSettings { $0.unknownVoicesEnabled = on } }
    public func setAutoAssign(_ on: Bool) async { await updateSettings { $0.autoAssign = on } }

    private func updateSettings(_ change: (inout SpeakerSettings) -> Void) async {
        var next = settings ?? SpeakerSettings()
        change(&next)
        do {
            settings = try await api().putSpeakerSettings(next)
            await refresh()
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: People

    /// Creates a person (client-minted id, so a retry can't create two).
    @discardableResult
    public func createPerson(name: String, me: Bool = false, attestKnows: Bool = false) async -> Person? {
        let id = UUID().uuidString.lowercased()
        do {
            let person = try await api().putPerson(id: id, PutPersonRequest(name: name, me: me, attestKnows: attestKnows))
            await refresh()
            return person
        } catch {
            self.error = Self.describe(error)
            return nil
        }
    }

    public func forgetVoice(_ person: Person, deleteNote: Bool = false) async {
        do {
            try await api().deletePerson(id: person.id, deleteNote: deleteNote)
            await refresh()
        } catch {
            self.error = Self.describe(error)
        }
    }

    public func assign(_ suggestion: SpeakerSuggestion, to person: Person) async {
        do {
            try await api().assignSuggestion(suggestion.id, personId: person.id)
            suggestions.removeAll { $0.id == suggestion.id }
            await refresh()
        } catch {
            self.error = Self.describe(error)
        }
    }

    public func dismiss(_ suggestion: SpeakerSuggestion) async {
        do {
            try await api().dismissSuggestion(suggestion.id)
            suggestions.removeAll { $0.id == suggestion.id }
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Conversation speakers

    public func speakers(conversationId: String) async throws -> ConversationSpeakers {
        try await api().conversationSpeakers(conversationId)
    }

    public func assign(conversationId: String, label: String, personId: String?, notPersonId: String? = nil, revision: Int) async throws -> ConversationSpeakers {
        let result = try await api().assignSpeaker(
            conversationId: conversationId, label: label,
            AssignSpeakerRequest(personId: personId, notPersonId: notPersonId, expectedRevision: revision))
        Task { await refresh() }
        return result
    }

    public func resummarize(conversationId: String) async throws {
        try await api().resummarize(conversationId)
    }

    public func clip(_ clipId: String) async throws -> Data { try await api().clip(clipId) }

    // MARK: Enrollment

    public var canStartEnrollment: Bool {
        engine.settings.endpoint != nil && engine.snapshotNow().connection == .streaming && serverSupportsEnrollment == true
    }

    public static let serverTooOld = "Update the Omi Notes server first: this one doesn't support voice enrollment, so your reading would be transcribed as a conversation."

    private var startAttempt: UUID?

    /// Asks the server it is about to talk to (not a remembered answer): only one that knows the
    /// enrollment events keeps the reading out of transcripts. The answer only counts for this
    /// attempt, if it wasn't cancelled meanwhile, and for the server that is still configured.
    public func startEnrollment() async {
        switch enrollment {
        case .idle, .failed, .finished: break
        case .checking, .reading, .waiting: return  // one attempt at a time
        }
        let attempt = UUID()
        startAttempt = attempt
        enrollment = .checking
        let endpoint = engine.settings.endpoint
        var supported: Bool?
        var failure: String?
        do {
            guard let endpoint else { throw APIError.notConfigured }
            supported = try await APIClient(endpoint: endpoint, session: session).status().supportsVoiceEnrollment
        } catch {
            failure = "Couldn't reach the server to check it supports voice enrollment (\(Self.describe(error)))."
        }
        guard startAttempt == attempt else { return }  // cancelled (or superseded) while asking
        startAttempt = nil
        guard engine.settings.endpoint == endpoint else {
            enrollment = .failed("The server changed while it was being checked; try again.")
            return
        }
        serverSupportsEnrollment = supported
        guard supported == true else {
            enrollment = .failed(failure ?? Self.serverTooOld)
            return
        }
        do {
            let id = try engine.startVoiceEnrollment()
            enrollment = .reading(id: id, prompt: 0)
        } catch {
            enrollment = .failed(Self.describe(error))
        }
    }

    public func nextPrompt() {
        guard case .reading(let id, let prompt) = enrollment else { return }
        if prompt + 1 < Self.prompts.count {
            enrollment = .reading(id: id, prompt: prompt + 1)
        } else {
            finishEnrollment()
        }
    }

    public func finishEnrollment() {
        guard case .reading(let id, _) = enrollment else { return }
        engine.finishVoiceEnrollment(outcome: .completed)
        enrollment = .waiting(id: id, status: nil)
        poll(id)
    }

    /// The enrollment screen went away: an attempt it was showing (checking the server, or the
    /// reading) must not continue unseen — the window would swallow ordinary speech.
    public func enrollmentScreenClosed() {
        switch enrollment {
        case .checking, .reading: cancelEnrollment()
        case .idle, .waiting, .finished, .failed: break
        }
    }

    public func cancelEnrollment() {
        startAttempt = nil
        pollTask?.cancel()
        if case .reading = enrollment { engine.finishVoiceEnrollment(outcome: .cancelled) }
        enrollment = .idle
    }

    /// Polls until the server reports a final state. Success is only ever what the server says
    /// ("accepted" = enrolled, not yet calibrated), never inferred from elapsed time.
    private func poll(_ id: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                do {
                    let status = try await self.api().enrollmentStatus(id)
                    if status.isFinal {
                        self.enrollment = .finished(status)
                        await self.refresh()
                        return
                    }
                    self.enrollment = .waiting(id: id, status: status)
                } catch APIError.http(404, _) {
                    continue  // the start event may not have been processed yet
                } catch {
                    self.error = Self.describe(error)
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
