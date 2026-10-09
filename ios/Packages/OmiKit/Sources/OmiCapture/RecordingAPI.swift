import Foundation
import OmiProtocol

/// A note's recording (capture-format-v1.md, "GET /v1/conversations/{id}/recording").
extension APIClient {
    public func recordingInfo(_ conversationId: String) async throws -> RecordingInfo {
        let (data, _) = try await recordingRequest(conversationId, path: "recording", range: nil)
        do { return try Self.snakeDecoder.decode(RecordingInfo.self, from: data) } catch { throw APIError.decoding("\(error)") }
    }

    /// Bytes `offset ..< offset + length` of the recording's WAV, and the file's total size. The
    /// token goes in the Authorization header, never in a URL a player could log.
    public func recordingBytes(_ conversationId: String, offset: Int64, length: Int) async throws -> (data: Data, total: Int64?) {
        let (data, resp) = try await recordingRequest(conversationId, path: "recording.wav",
                                                      range: "bytes=\(offset)-\(offset + Int64(max(length, 1)) - 1)")
        let total = (resp.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int64($0) }
        return (data, total ?? (resp.statusCode == 200 ? Int64(data.count) : nil))
    }

    private func recordingRequest(_ conversationId: String, path: String, range: String?) async throws -> (Data, HTTPURLResponse) {
        guard let url = endpoint.url("/v1/conversations/\(Self.queryValue(conversationId))/\(path)") else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw APIError.transport((error as NSError).localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.transport("no HTTP response") }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, Uploader.detail(body: data, error: nil, status: http.statusCode))
        }
        return (data, http)
    }
}
