import Foundation
import OmiCapture
import OmiProtocol

/// The owner's "this is me talking / a conversation / background" (capture-format-v1.md, "Recording class").
/// Online only: the server deduplicates by request id and the later choice wins. The row keeps showing the class
/// the note was made for; the server's answer marks it `updating` (with the `requested` kind) until its worker
/// writes the new summary, which a later refresh shows.
extension AppModel {
    public var supportsRecordingClass: Bool { serverStatus?.supportsRecordingClass == true }

    /// The freshest view of a conversation's class: the list's (a loaded note also refreshes its row, and a list
    /// refresh is newer than a note opened earlier), else the open note's.
    public func recordingClass(of c: ConversationSummary) -> RecordingClassView? {
        recent.first { $0.id == c.id }?.recordingClass ?? details[c.id]?.entry.recordingClass ?? c.recordingClass
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

    /// The server's answer: still the applied class. The cached note takes it only when it describes the summary
    /// that note shows; otherwise (the server applied another choice meanwhile) the note is loaded again.
    func applyRecordingClass(_ view: RecordingClassView, to conversationId: String) {
        updateRow(conversationId) { $0.recordingClass = view }
        guard let shown = details[conversationId]?.entry.recordingClass else { return }
        if shown.sameTreatment(as: view) {
            details[conversationId]?.entry.recordingClass = view
        } else {
            Task { _ = try? await conversation(conversationId) }
        }
    }
}
