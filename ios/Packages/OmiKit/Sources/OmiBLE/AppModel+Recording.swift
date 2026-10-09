import Foundation
import OmiCapture
import OmiProtocol

/// Listening to a note's recording (capture-format-v1.md, "GET /v1/conversations/{id}/recording").
extension AppModel {
    public var canPlayRecordings: Bool { serverStatus?.supportsRecording == true }

    /// A client for this server, with this app's session (authenticated; nothing in URLs).
    public func recordingClient() throws -> APIClient {
        guard let endpoint = engine.settings.serverConfig().endpoint else { throw APIError.notConfigured }
        return APIClient(endpoint: endpoint, session: session)
    }
}

extension Notification.Name {
    /// Posted by whichever player starts: every other player pauses (one sound at a time).
    public static let omiAudioWillPlay = Notification.Name("omiAudioWillPlay")
}
