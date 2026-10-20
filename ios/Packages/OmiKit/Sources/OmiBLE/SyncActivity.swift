import Foundation
import OmiProtocol

extension SyncActivityState {
    /// From the accepted transfer summary (the same source as Devices → Transfers).
    public init(_ t: TransferSummary, now: Date) {
        let p = t.phone
        let stage: Stage
        let title: String
        switch p.state {
        case .sending: (stage, title) = (.sending, "Sending to your server")
        case .waiting: (stage, title) = (.waiting, "Waiting to send")
        case .retrying: (stage, title) = (.retrying, "Will try again automatically")
        case .offline: (stage, title) = (.offline, "Can't reach your server")
        case .paused: (stage, title) = (.paused, "Uploads paused")
        case .preparing: (stage, title) = (.preparing, "Preparing Watch audio")
        case .keptAside: (stage, title) = (.keptAside, "Files kept aside on this iPhone")
        case .queueUnreadable: (stage, title) = (.queueUnreadable, "Upload queue can't be read")
        // the iPhone's own queue: the Watch may still have audio on its way (shown on its own line)
        case .allSent: (stage, title) = (.allSent, "This iPhone has sent everything")
        case .notConfigured: (stage, title) = (.notConfigured, "No server connected")
        case .unknown: (stage, title) = (.unknown, "Not measured right now")
        }
        let knownAudio = p.queuedAudioFiles - p.queuedAudioUnknown
        let queuedAudio: Double?
        if p.queuedAudioFiles == 0 { queuedAudio = stage == .queueUnreadable ? nil : 0 }
        else { queuedAudio = knownAudio > 0 ? p.queuedAudioSeconds : nil }
        let watchWaiting = t.watch.inUse == true ? t.watch.waitingSeconds : nil
        var detail: String?
        switch p.state {
        case .offline(let why), .paused(let why): detail = why
        case .keptAside(let n): detail = "\(n) not uploaded; see Devices"
        case .preparing(let n): detail = "\(n) Watch part\(n == 1 ? "" : "s") being prepared"
        case .allSent: detail = t.server.conversationsPending.map { $0 > 0 ? "Your server is processing \($0)" : "Notes appear once your server processes them" }
            ?? "Notes appear once your server processes them"
        default: detail = nil
        }
        self.init(
            stage: stage, title: title, detail: detail, rate: stage == .sending ? p.rate : nil,
            queuedAudioSeconds: queuedAudio, queuedAudioPartial: p.queuedAudioUnknown > 0 && knownAudio > 0,
            queuedFiles: stage == .queueUnreadable ? nil : p.queuedFiles,
            batchSent: p.inFlightTotal > 0 ? p.inFlightSent : nil, batchTotal: p.inFlightTotal > 0 ? p.inFlightTotal : nil,
            batchUnknownUploads: p.inFlightTotal > 0 ? p.inFlightUnknownTotals : nil,
            watchWaitingSeconds: watchWaiting, watchReportAt: watchWaiting == nil ? nil : t.watch.reportAt,
            serverPending: t.server.conversationsPending, asOf: now)
    }
}

/// How an ended activity leaves the Lock Screen.
public enum SyncActivityEnding: Equatable, Sendable {
    case immediate
    case after(Date)
}

/// The system side of the sync Live Activity (ActivityKit in the app; doubles in tests).
@MainActor
public protocol SyncActivityHost: AnyObject {
    /// Live Activities are allowed for this app (Settings).
    var enabled: Bool { get }
    /// This feature's activities that still exist (e.g. after a relaunch), oldest first: running ones
    /// and ended ones still shown.
    func existing() -> [(id: String, running: Bool)]
    func start(_ state: SyncActivityState, staleDate: Date) throws -> String
    func update(_ id: String, _ state: SyncActivityState, staleDate: Date)
    /// `final`: what an ended card shows until `ending` removes it (nil: removed at once).
    func end(_ id: String, final: SyncActivityState?, ending: SyncActivityEnding)
}

/// What survives a relaunch: the activity was dismissed, so it isn't shown again until a sync is
/// confirmed finished (UserDefaults in the app).
@MainActor
public protocol SyncActivityMemory: AnyObject {
    var dismissed: Bool { get set }
}

/// One sync Live Activity, driven by the transfer state while the app runs. Presentation only: it
/// never starts, stops or keeps alive any upload, and the app doesn't run to update it.
@MainActor
public final class SyncActivityController {
    /// Numeric-only changes (rate, seconds) are pushed at most this often; a stage change at once.
    public static let minInterval: TimeInterval = 15
    /// A state with a live rate goes stale soon (the rate means nothing once the app stops running);
    /// other states describe a queue, which stays true longer.
    public static let liveStale: TimeInterval = 90
    public static let queueStale: TimeInterval = 15 * 60
    /// An unchanged state, measured again while the app runs, is pushed again this often (fresh
    /// "as of" and stale date).
    public static let renewAfter: TimeInterval = 5 * 60
    /// While a rate is shown, it is checked this soon again (it disappears once bytes stop).
    public static let rateRecheck: TimeInterval = 4
    /// A finished card stays this long (then the system removes it); a new sync or turning it off
    /// removes it at once.
    public static let finishedCardFor: TimeInterval = 10 * 60

    private let host: SyncActivityHost
    private let memory: SyncActivityMemory
    public private(set) var activityId: String?
    /// The finished card still on screen (ours to remove).
    public private(set) var finishedId: String?
    private var lastPushed: SyncActivityState?
    private var lastPushAt: Date?

    public init(host: SyncActivityHost, memory: SyncActivityMemory) {
        self.host = host
        self.memory = memory
    }

    public var dismissed: Bool { memory.dismissed }

    /// After a relaunch: keep one running activity and one finished card, end any others.
    public func adopt() {
        let all = host.existing()
        let running = all.filter(\.running).map(\.id), finished = all.filter { !$0.running }.map(\.id)
        activityId = running.last
        finishedId = finished.last
        for extra in running.dropLast() + finished.dropLast() { host.end(extra, final: nil, ending: .immediate) }
        lastPushed = nil
        lastPushAt = nil
    }

    /// The system reports the activity gone. `dismissed`: ActivityKit's `.dismissed` (by the person or
    /// by the system; it doesn't say which), so it isn't shown again until this sync is confirmed done.
    /// Otherwise it ended (e.g. its time limit) and may show again on the next foreground.
    public func ended(_ id: String, dismissed: Bool) {
        if id == finishedId { finishedId = nil }
        guard id == activityId else { return }
        activityId = nil
        lastPushed = nil
        if dismissed { memory.dismissed = true }
    }

    public static func staleDate(_ s: SyncActivityState, now: Date) -> Date {
        now.addingTimeInterval(s.rate != nil ? liveStale : queueStale)
    }

    /// `state`: nil while nothing is known (the engine's first snapshot hasn't come, or the app isn't
    /// measuring): nothing is decided then. `foreground`: the app is active (the only time a new
    /// activity starts). `optedOut`: turned off in the app.
    public func refresh(_ state: SyncActivityState?, foreground: Bool, optedOut: Bool, now: Date) {
        guard host.enabled, !optedOut else {
            removeAll()
            return
        }
        guard let s = state, s.stage != .unknown else { return }
        let finished = s.stage == .allSent && !s.hasWork  // confirmed: measured, read, nothing left
        if let id = activityId {
            if finished {
                if let old = finishedId { host.end(old, final: nil, ending: .immediate) }
                host.end(id, final: s, ending: .after(now.addingTimeInterval(Self.finishedCardFor)))
                finishedId = id
                activityId = nil
                lastPushed = nil
                memory.dismissed = false
            } else if !s.hasWork {
                host.end(id, final: nil, ending: .immediate)  // e.g. no server: nothing to follow
                activityId = nil
                lastPushed = nil
            } else {
                push(id, s, foreground: foreground, now: now)
            }
            return
        }
        if finished {
            memory.dismissed = false  // this sync is over: a later one may show again
            return
        }
        guard s.hasWork, foreground, !memory.dismissed else { return }
        if let old = finishedId {  // never two cards
            host.end(old, final: nil, ending: .immediate)
            finishedId = nil
        }
        if let started = try? host.start(s, staleDate: Self.staleDate(s, now: now)) {
            activityId = started
            lastPushed = s
            lastPushAt = now
        }
    }

    /// When the running app should look again (a shown rate may have stopped; an unchanged state is
    /// renewed); nil when there's nothing to look after.
    public func nextCheck(now: Date) -> Date? {
        guard activityId != nil, let at = lastPushAt else { return nil }
        let renew = at.addingTimeInterval(Self.renewAfter)
        guard lastPushed?.rate != nil else { return renew }
        return min(renew, now.addingTimeInterval(Self.rateRecheck))
    }

    private func push(_ id: String, _ s: SyncActivityState, foreground: Bool, now: Date) {
        let changed = lastPushed.map { $0.stage != s.stage || $0.title != s.title || $0.detail != s.detail } ?? true
        let since = lastPushAt.map { now.timeIntervalSince($0) } ?? .infinity
        // the same state, measured again now; only while the app runs in front (in the background
        // nothing is being watched, so nothing is renewed)
        let renew = foreground && since >= Self.renewAfter
        guard changed || (since >= Self.minInterval && Self.differs(lastPushed, s)) || renew else { return }
        host.update(id, s, staleDate: Self.staleDate(s, now: now))
        lastPushed = s
        lastPushAt = now
    }

    private func removeAll() {
        for id in [activityId, finishedId].compactMap({ $0 }) { host.end(id, final: nil, ending: .immediate) }
        activityId = nil
        finishedId = nil
        lastPushed = nil
    }

    private static func differs(_ a: SyncActivityState?, _ b: SyncActivityState) -> Bool {
        guard var a else { return true }
        a.asOf = b.asOf
        return a != b
    }
}

/// The ActivityKit calls, in order. Each update or end runs only after the previous one finished,
/// so an update delayed at the SDK can't land after a newer one or after the end; an update that
/// has been superseded (or whose activity ended) before its turn is skipped.
@MainActor
public final class OrderedActivityOperations {
    public typealias Send = @Sendable (String, SyncActivityState, Date) async -> Void
    public typealias Finish = @Sendable (String, SyncActivityState?, SyncActivityEnding) async -> Void

    private let send: Send
    private let finish: Finish
    private var tail: Task<Void, Never>?
    private var revision = 0
    private var newest: [String: Int] = [:]
    private var retired: Set<String> = []

    public init(send: @escaping Send, finish: @escaping Finish) {
        self.send = send
        self.finish = finish
    }

    public func update(_ id: String, _ state: SyncActivityState, staleDate: Date) {
        guard !retired.contains(id) else { return }
        revision += 1
        let r = revision
        newest[id] = r
        let send = send
        chain { [weak self] in
            guard let self, self.newest[id] == r, !self.retired.contains(id) else { return }  // superseded or ended
            await send(id, state, staleDate)
        }
    }

    public func end(_ id: String, final: SyncActivityState?, ending: SyncActivityEnding) {
        retired.insert(id)
        newest[id] = nil
        let finish = finish
        chain { await finish(id, final, ending) }
    }

    /// Everything queued so far has run (tests).
    public func drain() async { await tail?.value }

    private func chain(_ op: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await op()
        }
    }
}
