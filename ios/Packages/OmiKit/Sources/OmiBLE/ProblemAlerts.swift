import Foundation

/// Opt-in alerts for problems the phone itself observes and that need the user (never content,
/// never a guess about the server): recording stopped for lack of storage, audio kept because it
/// couldn't be uploaded, uploads paused (e.g. the server rejected this phone). Each alert is sent
/// once while its condition lasts (remembered across launches) and withdrawn when it clears.
/// Ordinary waiting — a disconnected pendant, queued uploads — never alerts.
public enum PhoneProblem: String, CaseIterable, Sendable {
    case recordingStopped, audioKept, uploadsPaused

    public var title: String {
        switch self {
        case .recordingStopped: return "Recording stopped"
        case .audioKept: return "Some audio couldn't be uploaded"
        case .uploadsPaused: return "Uploads are paused"
        }
    }

    public var body: String {
        switch self {
        case .recordingStopped: return "This iPhone is almost out of storage. Free up space so Omi Notes can record again."
        case .audioKept: return "It's kept on this phone. Open Omi Notes to see what happened."
        case .uploadsPaused: return "Open Omi Notes to see why; you may need to pair with your server again."
        }
    }

    public var identifier: String { "omi.problem.\(rawValue)" }

    public static func current(_ s: EngineSnapshot) -> Set<PhoneProblem> {
        var out: Set<PhoneProblem> = []
        if s.storageTripped { out.insert(.recordingStopped) }
        if s.outbox.quarantineCount > 0 { out.insert(.audioKept) }
        if s.upload.pausedReason != nil { out.insert(.uploadsPaused) }
        return out
    }
}

public protocol ProblemAlertSink: AnyObject, Sendable {
    func post(_ problem: PhoneProblem)
    func withdraw(_ problem: PhoneProblem)
}

public final class ProblemAlerts: @unchecked Sendable {
    public static let enabledKey = "omi.problemAlerts"
    private static let sentKey = "omi.problemAlertsSent"
    private let defaults: UserDefaults
    public weak var sink: ProblemAlertSink?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { withdrawAll() }
        }
    }

    private var sent: Set<PhoneProblem> {
        get { Set((defaults.stringArray(forKey: Self.sentKey) ?? []).compactMap(PhoneProblem.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.sentKey) }
    }

    /// Call with every engine snapshot (also in the background).
    public func update(_ snapshot: EngineSnapshot) {
        let now = PhoneProblem.current(snapshot)
        let before = sent
        for gone in before.subtracting(now) { sink?.withdraw(gone) }
        if enabled { for new in now.subtracting(before) { sink?.post(new) } }
        sent = enabled ? now : before.intersection(now)
    }

    private func withdrawAll() {
        for p in sent { sink?.withdraw(p) }
        sent = []
    }
}
