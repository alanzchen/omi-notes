import Foundation
import OmiCapture
import OmiProtocol

/// The owner's "this is me talking / a conversation / background" (capture-format-v1.md, "Recording class").
/// Online only: the server deduplicates by request id and the later choice wins; the row shows the server's answer.
extension AppModel {
    public var supportsRecordingClass: Bool { serverStatus?.supportsRecordingClass == true }

    public func setRecordingClass(_ conversationId: String, _ kind: String) async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, supportsRecordingClass else { return }
        do {
            let view = try await APIClient(endpoint: endpoint, session: session)
                .putRecordingClass(conversationId, kind: kind, requestId: UUID().uuidString, setAt: Date())
            classMessages[conversationId] = nil
            if let i = recent.firstIndex(where: { $0.id == conversationId }) { recent[i].recordingClass = view }
        } catch {
            classMessages[conversationId] = "Couldn't change it: \(Self.describe(error))"
        }
    }
}
