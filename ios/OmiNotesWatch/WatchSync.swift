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
    /// Recorded length (seconds) of the audio parts waiting for this iPhone, from their own offsets.
    private(set) var pendingSeconds = 0
    private(set) var held = 0
    private(set) var lastAckAt: Date? = UserDefaults.standard.object(forKey: "omi.lastAckAt") as? Date
    private(set) var activated = false
    let outbox: WatchOutbox
    /// Performance samples for the server, sent after audio and acknowledged like it.
    let perf: WatchPerfQueue

    init(outbox: WatchOutbox, perf: WatchPerfQueue) {
        self.outbox = outbox
        self.perf = perf
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        refreshCounts()
    }

    func refreshCounts() {
        let segments = outbox.segments(), ends = outbox.ends()
        let waiting = Set(segments.map(\.segment.id) + ends.map(\.id) + perf.ids())
        if resend.entries.keys.contains(where: { !waiting.contains($0) }) { resend.keep(only: waiting) }
        // audio parts only (a recording's end marker isn't audio, but is sent the same way)
        held = segments.filter { $0.segment.binding != binding }.count
        pending = segments.count - held + (segments.isEmpty ? ends.filter { $0.binding == binding }.count : 0)
        pendingSeconds = WaitingAudio.seconds(segments.filter { $0.segment.binding == binding }.map(\.segment))
        sendReport()
        complication.update(recorder: complicationRecorder, waitingParts: pending, waitingSeconds: pendingSeconds, bound: binding != nil)
    }

    /// The watch-face complication's view of the recorder (set by the recorder).
    var complicationRecorder: ComplicationSnapshot.Recorder = .idle {
        didSet {
            if complicationRecorder != oldValue {
                complication.update(recorder: complicationRecorder, waitingParts: pending, waitingSeconds: pendingSeconds, bound: binding != nil)
            }
        }
    }
    private let complication = ComplicationPublisher()

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
        let r = WatchReport(state: recorderState.state, since: recorderState.since, waitingParts: pending, waitingSeconds: pendingSeconds, at: now,
                            stats: counters.merging(captureStats) { a, _ in a }.merging(["awaiting_ack": resend.awaitingAck]) { a, _ in a })
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
    /// When an item goes again (`WatchResendPolicy`): a delivered one waits long for the iPhone's
    /// acknowledgement instead of being resent every few minutes. Saved, so a restart doesn't
    /// resend everything delivered at once.
    private var resend: WatchResendPolicy = UserDefaults.standard.data(forKey: "omi.resendPolicy")
        .flatMap { try? JSONDecoder().decode(WatchResendPolicy.self, from: $0) } ?? WatchResendPolicy() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(resend), forKey: "omi.resendPolicy") }
    }

    /// Since launch, to compare builds (sent with the status report; nothing is sent for them alone).
    private(set) var counters: [String: Int] = [:]
    /// The recorder's capture counters, set by the recorder.
    var captureStats: [String: Int] = [:]

    private func count(_ key: String, _ n: Int = 1) { counters[key, default: 0] += n }

    var awaitingAck: Int { resend.awaitingAck }

    /// The last WatchConnectivity transfer error's code (0: none since launch), for telemetry.
    private(set) var lastTransferError = 0

    /// Relay health for a performance sample (cheap: counts already in memory).
    var relayGauges: [String: Int] {
        let oldest = outbox.segments().first.map { Int(Date().timeIntervalSince($0.segment.recordingStartedAt)) } ?? 0
        return ["outbox_parts": pending, "waiting_s": pendingSeconds, "awaiting_ack": awaitingAck, "outstanding_files": activated ? WCSession.default.outstandingFileTransfers.count : -1,
                "last_transfer_error": lastTransferError, "oldest_waiting_s": oldest]
    }

    private func markSent(_ id: String, now: Date) {
        count(resend.entries[id] == nil ? "transfers" : "resends")
        resend.handedOver(id, now: now)
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
        for (segment, file) in outbox.segments() where segment.binding == binding && !inFlight.contains(segment.id) && resend.due(segment.id, now: now) {
            guard room > 0 else { break }
            room -= 1
            watchLog.info("sending segment \(segment.id)")
            markSent(segment.id, now: now)
            session.transferFile(file, metadata: [WatchWire.kind: WatchWire.segment, "id": segment.id, WatchWire.manifest: WatchWire.encode(segment)])
        }
        for end in outbox.ends() where end.binding == binding && !inFlight.contains(end.id) && resend.due(end.id, now: now) {
            markSent(end.id, now: now)
            session.transferUserInfo([WatchWire.kind: WatchWire.end, "id": end.id, WatchWire.manifest: WatchWire.encode(end)])
        }
        // telemetry last, two batches at a time (small user-info transfers, after the audio)
        var perfRoom = 2 - session.outstandingUserInfoTransfers.filter { $0.userInfo[WatchWire.kind] as? String == WatchWire.perf }.count
        for id in perf.ids() where !inFlight.contains(id) && resend.due(id, now: now) {
            guard perfRoom > 0 else { break }
            guard let batch = perf.batch(id), batch.binding == binding else { continue }
            perfRoom -= 1
            markSent(batch.id, now: now)
            count("perf_batches_sent")
            session.transferUserInfo([WatchWire.kind: WatchWire.perf, "id": batch.id, WatchWire.manifest: WatchWire.encode(batch)])
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
        guard !recheckScheduled, pending > 0 || !perf.ids().isEmpty else { return }
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
            perf.acknowledge(r.acks)
            resend.acknowledged(r.acks)
            count("acks", r.acks.count)
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
        let failedCode = error.map { ($0 as NSError).code } ?? 0
        let transferId = fileTransfer.file.metadata?["id"] as? String
        Task { @MainActor in
            if let failed {
                self.failures += 1
                self.retryAt = Date().addingTimeInterval(min(300, 5 * pow(2, Double(min(self.failures - 1, 6)))))
                watchLog.error("transfer failed: \(failed); retrying after \(self.failures) failure(s)")
                // a failed item is due again after the backoff
                if let transferId { self.resend.failed(transferId) }
                self.count("transfer_failures")
                self.lastTransferError = failedCode
            } else {
                self.failures = 0
                self.retryAt = nil
                // delivered, not acknowledged: kept, and sent again only after a long wait
                if let transferId { self.resend.delivered(transferId, now: Date()) }
            }
            self.pump()
        }
    }

    /// A recording end (sent as user info) was delivered or failed, like a file.
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let id = userInfoTransfer.userInfo["id"] as? String
        let failed = error != nil
        Task { @MainActor in
            guard let id else { return }
            if failed { self.resend.failed(id); self.count("transfer_failures") } else { self.resend.delivered(id, now: Date()) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pump() }
    }
}
