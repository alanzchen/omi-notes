import Foundation
import OmiWatchKit
import WatchConnectivity

/// Sends the Watch's segments to the paired iPhone and removes them only when the iPhone says it
/// has them (stored and checked). Segments made for another iPhone install are held, never sent.
@MainActor
@Observable
final class WatchSync: NSObject, WCSessionDelegate {
    private(set) var binding: String? = UserDefaults.standard.string(forKey: "omi.phoneBinding")
    private(set) var pending = 0
    private(set) var held = 0
    private(set) var lastAckAt: Date? = UserDefaults.standard.object(forKey: "omi.lastAckAt") as? Date
    private(set) var activated = false
    let outbox: WatchOutbox

    init(outbox: WatchOutbox) {
        self.outbox = outbox
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        refreshCounts()
    }

    func refreshCounts() {
        let segments = outbox.segments(), ends = outbox.ends()
        // audio parts only (a recording's end marker isn't audio, but is sent the same way)
        held = segments.filter { $0.segment.binding != binding }.count
        pending = segments.count - held + (segments.isEmpty ? ends.filter { $0.binding == binding }.count : 0)
        sendReport()
    }

    /// What the recorder is doing, for the iPhone's Devices screen.
    var recorderState: (state: WatchReport.State, since: Date?) = (.idle, nil) {
        didSet { sendReport() }
    }
    private var lastReport: WatchReport?

    /// Tells the iPhone (application context: only the latest counts) what this Watch is doing, with
    /// the time it said so. Sent when something changes, or at most every 5 min while it doesn't.
    private func sendReport() {
        guard activated, binding != nil, WCSession.default.activationState == .activated else { return }
        let now = Date()
        let r = WatchReport(state: recorderState.state, since: recorderState.since, waitingParts: pending, at: now)
        if let l = lastReport, l.state == r.state, l.since == r.since, l.waitingParts == r.waitingParts, now.timeIntervalSince(l.at) < 300 { return }
        do {
            try WCSession.default.updateApplicationContext([WatchWire.report: WatchWire.encode(r)])
            lastReport = r
        } catch {
            watchLog.error("status report not sent: \(error.localizedDescription)")
        }
    }

    /// After a failed transfer, wait before sending again (5 s, doubling to 5 min): a failing link
    /// must not keep the radio busy.
    private var retryAt: Date?
    private var failures = 0
    private var retryScheduled = false
    /// When each item was last handed over, and how often: a delivered item is not sent again
    /// until no acknowledgement has come for a while (1 min, doubling to 10 min).
    private var sent: [String: (at: Date, times: Int)] = [:]

    private func due(_ id: String, now: Date) -> Bool {
        guard let s = sent[id] else { return true }
        return now.timeIntervalSince(s.at) >= min(600, 60 * pow(2, Double(min(s.times - 1, 4))))
    }

    private func markSent(_ id: String, now: Date) {
        sent[id] = (now, (sent[id]?.times ?? 0) + 1)
    }

    /// Files handed to WatchConnectivity at once, at most: after a day away from the iPhone, the
    /// backlog goes over a few at a time, oldest first, instead of queueing every file at once.
    static let maxInFlight = 4

    /// Hands what is waiting (for this iPhone) to WatchConnectivity, skipping what is in flight.
    func pump() {
        refreshCounts()
        guard activated else { return }
        guard let binding else { askForBinding(); return }
        if let at = retryAt, at > Date() {
            if !retryScheduled {
                retryScheduled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow)))
                    self.retryScheduled = false
                    self.pump()
                }
            }
            return
        }
        let session = WCSession.default
        let inFlight = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["id"] as? String })
            .union(session.outstandingUserInfoTransfers.compactMap { $0.userInfo["id"] as? String })
        let now = Date()
        var room = Self.maxInFlight - session.outstandingFileTransfers.count
        for (segment, file) in outbox.segments() where segment.binding == binding && !inFlight.contains(segment.id) && due(segment.id, now: now) {
            guard room > 0 else { break }
            room -= 1
            watchLog.info("sending segment \(segment.id)")
            markSent(segment.id, now: now)
            session.transferFile(file, metadata: [WatchWire.kind: WatchWire.segment, "id": segment.id, WatchWire.manifest: WatchWire.encode(segment)])
        }
        for end in outbox.ends() where end.binding == binding && !inFlight.contains(end.id) && due(end.id, now: now) {
            markSent(end.id, now: now)
            session.transferUserInfo([WatchWire.kind: WatchWire.end, "id": end.id, WatchWire.manifest: WatchWire.encode(end)])
        }
        scheduleRecheck()
    }

    /// What the iPhone told the Watch (a plain value, safe to pass to the main actor).
    struct Received: Sendable {
        var binding: String?
        var acks: [String]
        init(_ m: [String: Any]) {
            binding = m[WatchWire.binding] as? String
            acks = m[WatchWire.acks] as? [String] ?? []
        }
    }

    /// No binding yet (fresh install): ask the iPhone directly when it is reachable.
    private func askForBinding() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["hello": 1], replyHandler: { reply in
            let r = Received(reply)
            Task { @MainActor in self.handle(r) }
        }, errorHandler: nil)
    }

    /// Looks again later for items whose acknowledgement is overdue.
    private var recheckScheduled = false
    private func scheduleRecheck() {
        guard !recheckScheduled, pending > 0 else { return }
        recheckScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            self.recheckScheduled = false
            self.pump()
        }
    }

    private func handle(_ r: Received) {
        if let b = r.binding, b != binding {
            binding = b
            UserDefaults.standard.set(b, forKey: "omi.phoneBinding")
        }
        if !r.acks.isEmpty {
            watchLog.info("iPhone acknowledged \(r.acks.count) item(s)")
            outbox.acknowledge(r.acks)
            for id in r.acks { sent[id] = nil }
            lastAckAt = Date()
            UserDefaults.standard.set(lastAckAt, forKey: "omi.lastAckAt")
        }
        pump()
    }

    // MARK: WCSessionDelegate (called off the main thread)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let r = Received(session.receivedApplicationContext)
        let ok = state == .activated
        Task { @MainActor in
            self.activated = ok
            self.handle(r)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let r = Received(context)
        Task { @MainActor in self.handle(r) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let r = Received(userInfo)
        Task { @MainActor in self.handle(r) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let r = Received(message)
        Task { @MainActor in self.handle(r) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // delivered or not, the file stays until the iPhone acknowledges it; failures are resent later
        let failed = error.map { "\($0.localizedDescription) (\(($0 as NSError).code))" }
        let transferId = fileTransfer.file.metadata?["id"] as? String
        Task { @MainActor in
            if let failed {
                self.failures += 1
                self.retryAt = Date().addingTimeInterval(min(300, 5 * pow(2, Double(min(self.failures - 1, 6)))))
                watchLog.error("transfer failed: \(failed); retrying after \(self.failures) failure(s)")
                // a failed item is due again after the backoff
                if let transferId { self.sent[transferId] = nil }
            } else {
                self.failures = 0
                self.retryAt = nil
            }
            self.pump()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pump() }
    }
}
