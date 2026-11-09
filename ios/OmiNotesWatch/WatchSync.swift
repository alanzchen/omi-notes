import Foundation
import OmiWatchKit
import WatchConnectivity
import WatchKit

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

    /// Audio kept without a usable manifest (`WatchOutbox.orphans`): never sent or deleted, reported so
    /// it can be recovered by hand.
    private(set) var orphans = 0
    /// Of the waiting parts, re-checks of audio an older iPhone build already converted (sent after new audio).
    private(set) var recheckParts = 0
    private(set) var recheckSeconds = 0

    /// When each waiting part was last handed over (this launch), for the receipt latency.
    private var handedAt: [String: Date] = [:]
    private var ackLatency = WatchAckLatency()
    private var lastSyncPing: Date?
    /// WatchConnectivity background wakes this launch, and audio parts handed over during them.
    private var backgroundWakes = 0
    private var backgroundWakeParts = 0
    /// Which outstanding transfers are moving, stalled (no progress for minutes) or queued.
    private var stalls = WatchTransferStalls()
    private var transferCounts = WatchTransferStalls.Counts()
    /// Delegate callbacks whose main-actor work hasn't run yet (a background wake waits for them).
    nonisolated private let callbackWork = WatchCallbackWork()

    /// Runs a delegate callback's work on the main actor, counted until it finishes.
    nonisolated private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        callbackWork.begin()
        Task { @MainActor in
            work()
            self.callbackWork.end()
        }
    }

    /// The link and app state for the status report and performance samples (memo checks D1/D3).
    private var linkStats: [String: Int] {
        var s: [String: Int] = ["recheck_parts": recheckParts, "recheck_s": recheckSeconds,
                                "bg_wakes": backgroundWakes, "bg_wake_parts": backgroundWakeParts]
        guard activated else { return s }
        let session = WCSession.default
        let transfers = session.outstandingFileTransfers
        let now = Date()
        let ages = transfers.compactMap { ($0.file.metadata?["id"] as? String).flatMap { handedAt[$0] } }.map { Int(now.timeIntervalSince($0)) }
        s["reachable"] = session.isReachable ? 1 : 0
        s["app_state"] = Self.appState
        // as of the last pump: moving (progress within `stallAfter`), stalled (transferring, no progress), queued
        s["outstanding_active"] = transferCounts.moving
        s["outstanding_stalled"] = transferCounts.stalled
        s["outstanding_queued"] = transferCounts.queued
        if let oldest = ages.max() { s["outstanding_oldest_s"] = oldest }
        if let p50 = ackLatency.quantile(0.5) { s["ack_latency_p50_s"] = p50 }
        if let p90 = ackLatency.quantile(0.9) { s["ack_latency_p90_s"] = p90 }
        return s
    }

    /// 0 foreground, 1 inactive, 2 background (`WKApplication.applicationState`).
    private static var appState: Int {
        switch WKApplication.shared().applicationState {
        case .active: return 0
        case .inactive: return 1
        default: return 2
        }
    }

    func refreshCounts() {
        let segments = outbox.segments(), ends = outbox.ends()
        orphans = outbox.orphans.count
        let waiting = Set(segments.map(\.segment.id) + ends.map(\.id) + perf.ids())
        if resend.entries.keys.contains(where: { !waiting.contains($0) }) { resend.keep(only: waiting) }
        // audio parts only (a recording's end marker isn't audio, but is sent the same way)
        held = segments.filter { $0.segment.binding != binding }.count
        pending = segments.count - held + (segments.isEmpty ? ends.filter { $0.binding == binding }.count : 0)
        pendingSeconds = WaitingAudio.seconds(segments.filter { $0.segment.binding == binding }.map(\.segment))
        let rechecks = segments.filter { $0.segment.binding == binding && resend.isRecheck($0.segment.id) }.map(\.segment)
        recheckParts = rechecks.count
        recheckSeconds = WaitingAudio.seconds(rechecks)
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
                            deviceId: WatchRecorder.deviceId,
                            stats: counters.merging(captureStats) { a, _ in a }.merging(["awaiting_ack": resend.awaitingAck]) { a, _ in a }
                                .merging(["orphan_parts": orphans]) { a, _ in a }  // 0 too: an absent count is unknown
                                .merging(linkStats) { a, _ in a })
        if let l = lastReport, l.state == r.state, l.since == r.since, l.waitingParts == r.waitingParts, l.recheckParts == r.recheckParts, l.keptParts == r.keptParts,
           now.timeIntervalSince(l.at) < 300 { return }
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
                "last_transfer_error": lastTransferError, "oldest_waiting_s": oldest].merging(linkStats) { a, _ in a }
    }

    private func markSent(_ id: String, now: Date) {
        count(resend.entries[id] == nil ? "transfers" : "resends")
        if resend.isRecheck(id) { count("recheck_sent") }
        resend.handedOver(id, now: now)
        handedAt[id] = now
        if inBackgroundWake { backgroundWakeParts += 1 }
    }

    /// Files handed to WatchConnectivity at once, at most: after a day away from the iPhone, the
    /// backlog goes over a few at a time, oldest first, instead of queueing every file at once.
    static let maxInFlight = 4
    /// Delivered parts asked about per inventory question (oldest first).
    static let inventoryBatch = 300

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
        // only moving transfers hold a slot: queued ones waiting for app runtime, or "transferring" ones with no
        // progress for minutes, pinned the window at 4; never cancelled (their parts stay until a receipt)
        let outstanding = session.outstandingFileTransfers
        transferCounts = stalls.observe(outstanding.map { t in
            WatchTransferStalls.Observation(id: t.file.metadata?["id"] as? String ?? t.file.fileURL.lastPathComponent,
                                            transferring: t.isTransferring, completedBytes: t.progress.completedUnitCount)
        }, now: now)
        var room = WatchTransferWindow.room(maxInFlight: Self.maxInFlight, transferring: transferCounts.moving, outstanding: outstanding.count)
        // new audio first; re-checks of parts an older iPhone build already converted after it
        let waiting = resend.sendOrder(outbox.segments(), now: now) { $0.segment.id }
        for (segment, file) in waiting where segment.binding == binding && !inFlight.contains(segment.id) && resend.due(segment.id, now: now) {
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
        // delivered parts waiting for an acknowledgement: ask which ones the iPhone already has
        // (durable user info, answered even while Omi Notes isn't open on the iPhone)
        if resend.inventoryDue(now: now) {
            // audio only (ends and telemetry are small), each with its checksum: an ack must be for these bytes
            let checksums = Dictionary(outbox.segments().map { ($0.segment.id, $0.segment.sha256) }, uniquingKeysWith: { a, _ in a })
            let items = resend.inventory(limit: .max).compactMap { id in checksums[id].map { WatchInventoryItem(id: id, sha256: $0) } }
                .prefix(Self.inventoryBatch)
            if !items.isEmpty {
                // one question at a time: an older unanswered one still queued is withdrawn first
                for t in session.outstandingUserInfoTransfers where t.userInfo[WatchWire.kind] as? String == WatchWire.inventory { t.cancel() }
                let question = UUID().uuidString.lowercased()
                // checksummed items only: no id-only list an older phone could answer by filename
                session.transferUserInfo(WatchWire.inventoryQuestion(id: question, items: Array(items), binding: binding))
                resend.askInventory(id: question, ids: items.map(\.id), now: now)
                count("inventory_asked", items.count)
                watchLog.info("asked the iPhone about \(items.count) delivered part(s)")
            }
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
        syncPing(now: now)
        scheduleRecheck()
    }

    /// While parts wait: asks the iPhone (a message with a reply, which wakes its app) for receipts about the
    /// oldest waiting parts, delivered or not, at most once per `WatchSyncPing.interval`; the iPhone answers
    /// only with receipts it can verify. Unreachable: nothing (the usual transfers and inventory still run).
    private func syncPing(now: Date) {
        let session = WCSession.default
        guard let binding, WatchSyncPing.due(now: now, last: lastSyncPing, reachable: session.isReachable, waitingParts: pending) else { return }
        let items = outbox.segments().filter { $0.segment.binding == binding }.prefix(WatchSyncPing.batch)
            .map { WatchInventoryItem(id: $0.segment.id, sha256: $0.segment.sha256) }
        guard !items.isEmpty else { return }
        lastSyncPing = now
        count("sync_pings")
        session.sendMessage(WatchWire.syncPing(items: Array(items), binding: binding), replyHandler: { reply in
            let r = Received(reply)
            self.onMain {
                self.count("sync_replies")
                self.handle(r)
            }
        }, errorHandler: { error in
            let code = (error as NSError).code
            self.onMain {
                self.count("sync_ping_errors")
                self.lastTransferError = code
            }
        })
    }

    /// A WatchConnectivity background wake (`.backgroundTask(.watchConnectivity)`): stay until the session is
    /// active, everything pending has been received (`hasContentPending`) and handled on the main actor
    /// (`callbackWork`), and the send loop ran after it, so one wake moves the acknowledgements and the next
    /// parts instead of a single part. Returns at once when the task is cancelled (its time expired).
    private(set) var inBackgroundWake = false
    func backgroundWake() async {
        backgroundWakes += 1
        inBackgroundWake = true
        defer { inBackgroundWake = false }
        let session = WCSession.default
        let deadline = Date().addingTimeInterval(25)
        var settled: Bool { activated && !session.hasContentPending && callbackWork.isIdle }
        while !settled && Date() < deadline {
            // delegate callbacks run on the main actor meanwhile; a cancelled sleep throws: stop now
            guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { return }
        }
        guard !Task.isCancelled else { return }
        pump()
        // give the receipts for what this pump handed over a moment to come back, then send again
        while Date() < deadline, transferCounts.moving > 0 || !settled {
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            pump()
        }
        // the last pump's own callbacks (replies to what it sent) before the wake ends
        while !callbackWork.isIdle && Date() < deadline {
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
        }
        sendReport()
        watchLog.info("background wake: \(self.backgroundWakeParts) part(s) handed over in \(self.backgroundWakes) wake(s) so far")
    }

    /// What the iPhone told the Watch (a plain value, safe to pass to the main actor).
    struct Received: Sendable {
        var binding: String?
        var acks: [String]
        /// Parts the iPhone said it doesn't hold (an inventory answer), and which question it answers.
        var missing: [String]
        var inventoryId: String?
        /// Checksum receipts for audio parts: after a part arrived (`receipts`) or in an inventory answer
        /// (`inventory_acks`). Only these delete audio.
        var receipts: [WatchInventoryItem]
        init(_ m: [String: Any]) {
            binding = m[WatchWire.binding] as? String
            acks = m[WatchWire.acks] as? [String] ?? []
            missing = m[WatchWire.missing] as? [String] ?? []
            inventoryId = m[WatchWire.inventoryId] as? String
            receipts = WatchWire.inventoryItems(from: m[WatchWire.receipts]) + WatchWire.inventoryItems(from: m[WatchWire.inventoryAcks])
        }
    }

    /// No binding yet (fresh install): ask the iPhone directly when it is reachable.
    private func askForBinding() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["hello": 1], replyHandler: { reply in
            let r = Received(reply)
            // the iPhone can't read its identity yet (not unlocked since it restarted): asking again at
            // once would loop; it announces itself after unlocking, and the recheck asks again
            guard r.binding != nil || !r.acks.isEmpty || r.inventoryId != nil else { return }  // (hello reply)
            self.onMain { self.handle(r) }
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
        // audio goes only on a receipt matching the part's own manifest (the storage layer checks it);
        // plain acks reach recording ends and telemetry only, never anything under segments/
        let retired = outbox.retire(receipts: r.receipts)
        let now = Date()
        for id in retired {
            if let at = handedAt.removeValue(forKey: id) { ackLatency.add(now.timeIntervalSince(at)) }
        }
        let ends = outbox.acknowledgeEnds(r.acks)
        perf.acknowledge(r.acks)
        // done: what was removed, and plain acks for anything that holds no audio (telemetry batches);
        // an audio part a plain ack named stays due for its normal resend
        let done = retired + ends + r.acks.filter { !ends.contains($0) && !retired.contains($0) && !outbox.holdsAudio($0) }
        if !done.isEmpty {
            watchLog.info("iPhone acknowledged \(done.count) item(s)")
            resend.acknowledged(done)
            count("acks", done.count)
            lastAckAt = Date()
            UserDefaults.standard.set(lastAckAt, forKey: "omi.lastAckAt")
        }
        if let question = r.inventoryId, r.binding == binding {
            // counted once, for its own question; parts handed over since then are left alone
            let due = resend.answeredInventory(id: question, missing: r.missing)
            if !due.isEmpty {
                watchLog.info("iPhone is missing \(due.count) part(s): sending them again")
                count("inventory_missing", due.count)
            }
        }
        pump()
    }

    // MARK: WCSessionDelegate (called off the main thread)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let r = Received(session.receivedApplicationContext)
        let ok = state == .activated
        onMain {
            self.activated = ok
            self.handle(r)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let r = Received(context)
        onMain { self.handle(r) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let r = Received(userInfo)
        onMain { self.handle(r) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let r = Received(message)
        onMain { self.handle(r) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // delivered or not, the file stays until the iPhone acknowledges it; failures are resent later
        let failed = error.map { "\($0.localizedDescription) (\(($0 as NSError).code))" }
        let failedCode = error.map { ($0 as NSError).code } ?? 0
        let transferId = fileTransfer.file.metadata?["id"] as? String
        onMain {
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
        onMain {
            guard let id else { return }
            if failed { self.resend.failed(id); self.count("transfer_failures") } else { self.resend.delivered(id, now: Date()) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        onMain { self.pump() }
    }
}
