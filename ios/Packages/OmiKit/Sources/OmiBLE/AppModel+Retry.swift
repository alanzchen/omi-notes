import Foundation
import OmiCapture
import OmiProtocol

/// Retrying failed work from the phone (capture-format-v1.md, "POST /v1/conversations/{id}/retry").
extension AppModel {
    /// The retry store's key for the current server, once its vault is known.
    var retryServerKey: String? {
        guard let url = engine.settings.serverURL, let vault = serverStatus?.vaultId else { return nil }
        return RetryStore.serverKey(baseURL: url, vaultId: vault)
    }

    public var canRetry: Bool { serverStatus?.supportsRetry == true && retryServerKey != nil }

    /// Ask the server to redo a failed conversation's failed stage. The request id is saved before
    /// sending and reused until the server answers, so tapping again after a timeout never starts
    /// a second retry.
    public func retry(conversationId: String) async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, config == answeredForConfig, let key = retryServerKey else { return }
        let entry: RetryStore.Entry
        do {
            entry = try retryStore.begin(conversationId: conversationId, server: key)
        } catch {
            retryMessages[conversationId] = (error as? LocalizedError)?.errorDescription ?? "Couldn't save the request on this phone: \(Self.describe(error))"
            return
        }
        retryMessages[conversationId] = nil
        await send(entry, api: APIClient(endpoint: endpoint, session: session), config: config, data: dataEpoch)
    }

    /// `data`: the data epoch the request belongs to; an answer after a server or vault change is dropped.
    func send(_ entry: RetryStore.Entry, api: APIClient, config: UploadConfig, data: Int) async {
        func current() -> Bool { isCurrent(config) && data == dataEpoch }
        guard current() else { return }  // never send a retry meant for a previous server or vault
        do {
            let op = try await api.retry(conversationId: entry.conversationId, requestId: entry.requestId)
            guard current() else { return }
            retryStore.record(op, for: entry.requestId)
            retries[entry.conversationId] = op
        } catch APIError.http(409, let detail) where detail.hasPrefix("busy") {
            // Not an answer: the server is mid-way (or other work is queued). Same id next time.
            guard current() else { return }
            retryMessages[entry.conversationId] = Self.retryRefusal(detail) + " The app asks again automatically."
        } catch APIError.http(let code, let detail) where (400..<500).contains(code) {
            guard current() else { return }
            retryStore.settle(entry.requestId)  // answered: repeating this id can't help
            retries[entry.conversationId] = nil
            retryMessages[entry.conversationId] = Self.retryRefusal(detail)
        } catch {
            // No answer, or the server failed: keep the id and ask again on the next refresh.
            guard current() else { return }
            retryMessages[entry.conversationId] = "Couldn't confirm the retry yet (\(Self.describe(error))). The app asks again automatically."
        }
    }

    /// On every refresh: follow unsettled retries of this server, re-sending those with no answer.
    func settleRetries(api: APIClient, config: UploadConfig, data: Int) async {
        func current() -> Bool { isCurrent(config) && data == dataEpoch }
        guard let key = retryServerKey, serverStatus?.supportsRetry == true else { return }
        for entry in retryStore.entries(server: key) {
            guard current() else { return }
            if let op = entry.operation {
                do {
                    let fresh = try await api.operation(op.id)
                    guard current() else { return }
                    retryStore.record(fresh, for: entry.requestId)
                    retries[entry.conversationId] = fresh
                } catch APIError.http(404, _) {
                    await send(entry, api: api, config: config, data: data)  // accepted state was lost: the same id again
                } catch {
                    guard current() else { return }
                    retries[entry.conversationId] = op  // keep showing the last known state
                }
            } else {
                await send(entry, api: api, config: config, data: data)
            }
        }
    }

    /// Queue failed audio files again. A user action only: never repeated automatically.
    public func retryFailedAudio() async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, config == answeredForConfig else { return }
        do {
            let n = try await APIClient(endpoint: endpoint, session: session).retryFailedChunks()
            guard isCurrent(config) else { return }
            retryMessages["chunks"] = n == 0 ? "Nothing to retry." : "Queued \(n) file\(n == 1 ? "" : "s") again."
            await refreshServer()
        } catch {
            if isCurrent(config) { retryMessages["chunks"] = "Couldn't retry: \(Self.describe(error))" }
        }
    }

    nonisolated static func retryRefusal(_ detail: String) -> String {
        let code = detail.split(separator: ":", maxSplits: 1).first.map(String.init) ?? detail
        switch code {
        case "not_failed": return "This conversation isn't failed anymore."
        case "retry_in_progress": return "A retry is already queued on the server."
        case "note_frozen": return "The note is frozen on the server, so it can't be updated."
        case "note_conflict": return "The note was edited outside My Notes. Resolve that on the server first."
        case "busy": return "The server is working on this conversation right now. Try again in a moment."
        default: return "The server refused the retry (\(detail))."
        }
    }
}
