import Foundation
import OmiCapture
import OmiProtocol

/// The owner's "this is me talking / a conversation / background" (capture-format-v1.md, "Recording class").
/// Online only: the server deduplicates by request id and the later choice wins. The row keeps showing the class
/// the note was made for; the server's answer marks it `updating` (with the `requested` kind) until its worker
/// writes the new summary, which a later refresh shows.
extension AppModel {
    public var supportsRecordingClass: Bool { serverStatus?.supportsRecordingClass == true }

    /// The freshest view of a conversation's class: the open note's, else the list's.
    public func recordingClass(of c: ConversationSummary) -> RecordingClassView? {
        details[c.id]?.entry.recordingClass ?? recent.first { $0.id == c.id }?.recordingClass ?? c.recordingClass
    }

    public func setRecordingClass(_ conversationId: String, _ kind: String) async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, supportsRecordingClass else { return }
        do {
            let view = try await APIClient(endpoint: endpoint, session: session)
                .putRecordingClass(conversationId, kind: kind, requestId: UUID().uuidString, setAt: Date())
            guard isCurrent(config) else { return }
            classMessages[conversationId] = nil
            applyRecordingClass(view, to: conversationId)
        } catch {
            guard isCurrent(config) else { return }
            classMessages[conversationId] = "Couldn't change the recording kind: \(Self.describe(error))"
        }
    }

    func applyRecordingClass(_ view: RecordingClassView, to conversationId: String) {
        if let i = recent.firstIndex(where: { $0.id == conversationId }) { recent[i].recordingClass = view }
        details[conversationId]?.entry.recordingClass = view
    }
}
