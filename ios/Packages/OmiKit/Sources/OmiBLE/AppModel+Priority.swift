import Foundation
import OmiCapture
import OmiProtocol

/// The owner's "Important" / "Less useful" / "Restore automatic" (capture-format-v1.md,
/// "PUT /v1/conversations/{id}/priority"). Shown at once (optimistic), saved on the phone until the
/// server confirms, retried on refreshes, and never undone by an older request.
extension AppModel {
    public var supportsValueNotes: Bool { serverStatus?.supportsValueNotes == true && retryServerKey != nil }

    /// The choice to show: an unconfirmed one first, else the server's. `pending`: not confirmed yet.
    public func priority(of conversation: ConversationSummary) -> (state: String, pending: Bool) {
        _ = priorityRevision  // observed: a new choice redraws
        if let key = retryServerKey, let entry = priorityStore.pending(conversation.id, server: key) {
            return (entry.state, true)
        }
        let id = conversation.id
        let latest = recent.first { $0.id == id }?.value?.user ?? details[id]?.entry.value?.user ?? conversation.value?.user
        return (latest?.state ?? "auto", false)
    }

    public func setPriority(_ conversationId: String, _ state: String) async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, let key = retryServerKey else { return }
        let entry: PriorityStore.Entry
        do {
            entry = try priorityStore.choose(conversationId, state: state, server: key)
        } catch {
            priorityMessages[conversationId] = "Couldn't save your choice on this phone: \(Self.describe(error))"
            return
        }
        priorityMessages[conversationId] = nil
        priorityLatest[conversationId] = entry.requestId
        priorityRevision += 1  // the optimistic state shows at once
        await sendPriority(entry, api: APIClient(endpoint: endpoint, session: session), data: dataEpoch)
    }

    /// On every refresh: send what's still unconfirmed for this server (only the latest per conversation).
    func settlePriorities(api: APIClient, data: Int) async {
        guard supportsValueNotes, let key = retryServerKey else { return }
        for entry in priorityStore.entries(server: key) where data == dataEpoch {
            await sendPriority(entry, api: api, data: data)
        }
    }

    func sendPriority(_ entry: PriorityStore.Entry, api: APIClient, data: Int) async {
        do {
            let answer = try await api.putPriority(entry.conversationId, state: entry.state, requestId: entry.requestId, setAt: entry.setAt)
            guard data == dataEpoch else { return }
            priorityStore.settle(entry.requestId)
            // only the latest choice's answer is shown: a newer one (pending, or answered first) stands
            let latest = priorityLatest[entry.conversationId]
            if priorityStore.pending(entry.conversationId, server: entry.server) == nil, latest == nil || latest == entry.requestId {
                applyPriority(entry.conversationId, ConversationValue.Choice(state: answer.state, revision: answer.revision, setAt: answer.setAt))
            }
        } catch APIError.http(let code, let detail) where (400..<500).contains(code) {
            guard data == dataEpoch else { return }
            priorityStore.settle(entry.requestId)
            priorityMessages[entry.conversationId] = "The server didn't take that choice (\(detail))."
        } catch {
            guard data == dataEpoch else { return }
            if priorityStore.failed(entry.requestId) {
                priorityMessages[entry.conversationId] = "Couldn't save your choice; the server stayed unreachable."
            }
        }
        priorityRevision += 1
    }

    /// The confirmed choice, into the list and the note already loaded.
    func applyPriority(_ id: String, _ choice: ConversationValue.Choice) {
        if let i = recent.firstIndex(where: { $0.id == id }) {
            var value = recent[i].value ?? ConversationValue()
            value.user = choice
            recent[i].value = value
        }
        if var detail = details[id] {
            var value = detail.entry.value ?? ConversationValue()
            value.user = choice
            detail.entry.value = value
            details[id] = detail
        }
    }
}
