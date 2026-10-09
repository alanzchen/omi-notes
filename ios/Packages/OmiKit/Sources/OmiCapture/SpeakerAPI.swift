import Foundation
import OmiProtocol

/// Speaker-learning endpoints (docs/speaker-learning.md, "API").
extension APIClient {
    public func people() async throws -> [Person] {
        let r: PeopleResponse = try await json("GET", "/v1/people")
        return r.people
    }

    /// Creates or updates a person. The id is client-minted, so retries are idempotent.
    @discardableResult
    public func putPerson(id: String, _ body: PutPersonRequest) async throws -> Person {
        try await json("PUT", "/v1/people/\(id)", body: body)
    }

    /// Forgets the person's voice data (and, optionally, their People note).
    public func deletePerson(id: String, deleteNote: Bool = false) async throws {
        _ = try await raw("DELETE", "/v1/people/\(id)", query: deleteNote ? "delete_note=true" : nil)
    }

    public func conversationSpeakers(_ conversationId: String) async throws -> ConversationSpeakers {
        try await json("GET", "/v1/conversations/\(conversationId)/speakers")
    }

    /// Assigns (or, with a nil person, unassigns) a speaker label. A stale revision → `APIError.http(409, …)`.
    public func assignSpeaker(conversationId: String, label: String, _ body: AssignSpeakerRequest) async throws -> ConversationSpeakers {
        try await json("PUT", "/v1/conversations/\(conversationId)/speakers/\(label)", body: body)
    }

    public func resummarize(_ conversationId: String) async throws {
        _ = try await raw("POST", "/v1/conversations/\(conversationId)/resummarize")
    }

    public func speakerSuggestions(limit: Int = 5) async throws -> [SpeakerSuggestion] {
        let r: SuggestionsResponse = try await json("GET", "/v1/speakers/suggestions", query: "limit=\(limit)")
        return r.suggestions
    }

    /// Names every speaker in a reviewed suggestion cluster.
    public func assignSuggestion(_ id: String, personId: String, requestId: String = UUID().uuidString.lowercased()) async throws {
        struct Body: Encodable { var personId: String; var requestId: String }
        _ = try await raw("POST", "/v1/speakers/suggestions/\(id)/assign",
                          body: try Self.snakeEncoder.encode(Body(personId: personId, requestId: requestId)))
    }

    /// Keeps the suggested voice unknown in every conversation it covers, for good.
    public func keepUnknownSuggestion(_ id: String, requestId: String) async throws -> [String] {
        struct Body: Encodable { var requestId: String }
        struct Answer: Decodable { var conversations: [String] }
        let r: Answer = try await json("POST", "/v1/speakers/suggestions/\(id)/keep-unknown", body: Body(requestId: requestId))
        return r.conversations
    }

    /// Puts back what one naming request changed, where it still stands.
    public func undoNaming(requestId: String, undoRequestId: String) async throws -> UndoNamingResponse {
        struct Body: Encodable { var requestId: String; var undoRequestId: String }
        return try await json("POST", "/v1/speakers/undo", body: Body(requestId: requestId, undoRequestId: undoRequestId))
    }

    public func dismissSuggestion(_ id: String) async throws {
        _ = try await raw("POST", "/v1/speakers/suggestions/\(id)/dismiss")
    }

    public func speakerSettings() async throws -> SpeakerSettings { try await json("GET", "/v1/speakers/settings") }

    @discardableResult
    public func putSpeakerSettings(_ settings: SpeakerSettings) async throws -> SpeakerSettings {
        try await json("PUT", "/v1/speakers/settings", body: settings)
    }

    public func enrollmentStatus(_ enrollmentId: String) async throws -> EnrollmentStatus {
        try await json("GET", "/v1/speakers/enrollments/\(enrollmentId)")
    }

    /// WAV bytes (16 kHz mono PCM16, ≤ 10 s). `APIError.http(410, …)` once the raw audio has expired.
    public func clip(_ clipId: String) async throws -> Data {
        try await raw("GET", "/v1/clips/\(clipId)", accept: "audio/wav")
    }

    // MARK: Plumbing

    static let snakeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let snakeEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private func json<T: Decodable>(_ method: String, _ path: String, query: String? = nil) async throws -> T {
        try decode(try await raw(method, path, query: query))
    }

    private func json<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: String? = nil, body: B) async throws -> T {
        let data: Data
        do { data = try Self.snakeEncoder.encode(body) } catch { throw APIError.decoding("encoding request: \(error)") }
        return try decode(try await raw(method, path, query: query, body: data))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try Self.snakeDecoder.decode(T.self, from: data) } catch { throw APIError.decoding("\(error)") }
    }

    private func raw(_ method: String, _ path: String, query: String? = nil, body: Data? = nil, accept: String = "application/json") async throws -> Data {
        guard let url = endpoint.url(path, query: query) else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.transport((error as NSError).localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else {
            throw APIError.http(code, Uploader.detail(body: data, error: nil, status: code))
        }
        return data
    }
}
