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
        case .allSent: (stage, title) = (.allSent, "Everything has reached your server")
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
            watchWaitingSeconds: watchWaiting, watchReportAt: watchWaiting == nil ? nil : t.watch.reportAt,
            serverPending: t.server.conversationsPending, asOf: now)
    }
}

/// The system side of the sync Live Activity (ActivityKit in the app; a fake in tests).
@MainActor
public protocol SyncActivityHost: AnyObject {
    /// Live Activities are allowed for this app (Settings).
    var enabled: Bool { get }
    /// Activities that already exist (e.g. after a relaunch), oldest first.
    func existing() -> [String]
    func start(_ state: SyncActivityState, staleDate: Date) throws -> String
    func update(_ id: String, _ state: SyncActivityState, staleDate: Date)
    /// `final`: shown after it ends (nil: removed at once).
    func end(_ id: String, final: SyncActivityState?)
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

    private let host: SyncActivityHost
    public private(set) var activityId: String?
    /// The user removed it from the Lock Screen: not recreated until this sync is over.
    public private(set) var dismissedThisSync = false
    private var lastPushed: SyncActivityState?
    private var lastPushAt: Date?

    public init(host: SyncActivityHost) { self.host = host }

    /// After a relaunch: keep the first existing activity, end any extras (never two).
    public func adopt() {
        let all = host.existing()
        activityId = all.first
        for extra in all.dropFirst() { host.end(extra, final: nil) }
    }

    /// The system ended it: by the user (dismissed) or for its own reasons (time limit).
    public func ended(_ id: String, byUser: Bool) {
        guard id == activityId else { return }
        activityId = nil
        lastPushed = nil
        if byUser { dismissedThisSync = true }
    }

    public static func staleDate(_ s: SyncActivityState, now: Date) -> Date {
        now.addingTimeInterval(s.rate != nil ? liveStale : queueStale)
    }

    /// `foreground`: the app is active (the only time a new activity is started). `optedOut`: the
    /// owner turned it off in the app.
    public func refresh(_ s: SyncActivityState, foreground: Bool, optedOut: Bool, now: Date) {
        guard host.enabled, !optedOut else {
            if let id = activityId { host.end(id, final: nil) }
            activityId = nil
            lastPushed = nil
            return
        }
        guard let id = activityId else {
            if !s.hasWork {
                dismissedThisSync = false  // this sync is over: a later one may show again
                return
            }
            guard foreground, !dismissedThisSync, s.stage != .unknown else { return }
            if let started = try? host.start(s, staleDate: Self.staleDate(s, now: now)) {
                activityId = started
                lastPushed = s
                lastPushAt = now
            }
            return
        }
        guard s.stage != .unknown else { return }  // not measured now: leave the last state to go stale
        if !s.hasWork {
            host.end(id, final: s)  // everything reached the server (processing continues there)
            activityId = nil
            lastPushed = nil
            dismissedThisSync = false
            return
        }
        let stageChanged = lastPushed.map { $0.stage != s.stage || $0.title != s.title || $0.detail != s.detail } ?? true
        let due = lastPushAt.map { now.timeIntervalSince($0) >= Self.minInterval } ?? true
        guard stageChanged || (due && Self.differs(lastPushed, s)) else { return }
        host.update(id, s, staleDate: Self.staleDate(s, now: now))
        lastPushed = s
        lastPushAt = now
    }

    private static func differs(_ a: SyncActivityState?, _ b: SyncActivityState) -> Bool {
        guard var a else { return true }
        a.asOf = b.asOf
        return a != b
    }
}
