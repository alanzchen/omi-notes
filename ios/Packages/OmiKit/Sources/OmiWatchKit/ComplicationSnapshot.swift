import Foundation
import Security

/// What the Watch app tells its watch-face complication: the recorder's state and the Watch's own
/// audio queue, written by the app (the only authority on both) with the time it was written.
/// "On iPhone" means the iPhone acknowledged storing the parts, never that the server has them.
public struct ComplicationSnapshot: Codable, Equatable, Sendable {
    public static let schema = 1
    public enum Recorder: String, Codable, Sendable { case recording, paused, failed, idle }

    public var schema: Int
    /// When the app wrote it (Watch clock).
    public var at: Date
    public var recorder: Recorder
    /// Audio parts on the Watch the iPhone hasn't acknowledged yet (for this iPhone).
    public var waitingParts: Int
    /// Paired with an iPhone (has its binding).
    public var bound: Bool

    public init(at: Date, recorder: Recorder, waitingParts: Int, bound: Bool) {
        schema = Self.schema
        self.at = at
        self.recorder = recorder
        self.waitingParts = waitingParts
        self.bound = bound
    }
}

/// How the complication shows a snapshot at a given time. A snapshot that is too old says nothing
/// about now: an old "recording" (the app may have been terminated) turns into "unknown" rather
/// than staying on the face as if live.
public struct ComplicationDisplay: Equatable, Sendable {
    public enum Main: Equatable, Sendable { case recording, paused, error, idle, unknown }
    public enum Sync: Equatable, Sendable { case waiting(Int), onIPhone, notConnected, unknown }

    public var main: Main
    public var sync: Sync

    public init(main: Main, sync: Sync) {
        self.main = main
        self.sync = sync
    }

    /// While recording the app refreshes the snapshot about every 15 min (the system decides when
    /// the face actually updates); past this, a recording state is no longer claimed.
    public static let recordingFresh: TimeInterval = 35 * 60
    /// Other states (and the queue count) are kept this long.
    public static let otherFresh: TimeInterval = 6 * 3600

    public static func lifetime(_ s: ComplicationSnapshot) -> TimeInterval {
        s.recorder == .recording ? recordingFresh : otherFresh
    }

    /// When this snapshot stops being shown as current (for the timeline's second entry).
    public static func staleAt(_ s: ComplicationSnapshot?) -> Date? {
        guard let s, s.schema == ComplicationSnapshot.schema else { return nil }
        return s.at.addingTimeInterval(lifetime(s))
    }

    public static func evaluate(_ s: ComplicationSnapshot?, now: Date) -> ComplicationDisplay {
        guard let s, s.schema == ComplicationSnapshot.schema,
              now.timeIntervalSince(s.at) < lifetime(s), now.timeIntervalSince(s.at) > -300 else {
            return ComplicationDisplay(main: .unknown, sync: .unknown)
        }
        let main: Main
        switch s.recorder {
        case .recording: main = .recording
        case .paused: main = .paused
        case .failed: main = .error
        case .idle: main = .idle
        }
        let sync: Sync = !s.bound ? .notConnected : s.waitingParts > 0 ? .waiting(s.waitingParts) : .onIPhone
        return ComplicationDisplay(main: main, sync: sync)
    }

    /// Spoken by VoiceOver; says where the audio is, never more.
    public var accessibilityLabel: String {
        let first: String
        switch main {
        case .recording: first = "Omi Notes is recording"
        case .paused: first = "Recording paused"
        case .error: first = "Recording stopped by an error"
        case .idle: first = "Not recording"
        case .unknown: first = "Omi Notes status unknown. Open the app"
        }
        let second: String
        switch sync {
        case .waiting(let n): second = "\(n) part\(n == 1 ? "" : "s") waiting to go to the iPhone"
        case .onIPhone: second = "everything recorded is on the iPhone"
        case .notConnected: second = "not connected to an iPhone yet"
        case .unknown: second = ""
        }
        return second.isEmpty ? first : "\(first). \(second)."
    }
}

/// When the app writes a new snapshot (and asks WidgetKit to reload): when what the face shows
/// changes (recorder state, pairing, waiting vs none), while recording at least every
/// `refreshWhileRecording` so the face doesn't go stale, and for a count-only change (3 → 4 parts)
/// at most every `countInterval`. Everything else waits: reloads are budgeted by the system.
public enum ComplicationPublishPolicy {
    public static let refreshWhileRecording: TimeInterval = 15 * 60
    public static let countInterval: TimeInterval = 5 * 60

    public static func shouldWrite(last: ComplicationSnapshot?, next: ComplicationSnapshot) -> Bool {
        guard let last else { return true }
        let age = next.at.timeIntervalSince(last.at)
        let sameShown = last.recorder == next.recorder && last.bound == next.bound && (last.waitingParts == 0) == (next.waitingParts == 0)
        if !sameShown { return true }
        if next.recorder == .recording && age >= refreshWhileRecording { return true }
        return last.waitingParts != next.waitingParts && age >= countInterval
    }
}

/// The snapshot, shared between the Watch app and its complication extension through a keychain
/// access group both are signed for (no App Group needed). Small; written only on changes.
public struct ComplicationStore: Sendable {
    public let accessGroup: String?
    static let service = "dev.omi-notes.complication", account = "snapshot"

    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: Self.account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    @discardableResult
    public func save(_ snapshot: ComplicationSnapshot) -> OSStatus {
        let data = WatchWire.encode(snapshot)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    public func load() -> ComplicationSnapshot? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return WatchWire.decode(ComplicationSnapshot.self, data)
    }
}
