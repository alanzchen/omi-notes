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
    /// Their recorded length in seconds (from each part's own start and end); absent if unknown.
    public var waitingSeconds: Int?
    /// Paired with an iPhone (has its binding).
    public var bound: Bool

    public init(at: Date, recorder: Recorder, waitingParts: Int, waitingSeconds: Int? = nil, bound: Bool) {
        schema = Self.schema
        self.at = at
        self.recorder = recorder
        self.waitingParts = waitingParts
        self.waitingSeconds = waitingSeconds
        self.bound = bound
    }
}

/// How the complication shows a snapshot at a given time. A snapshot that is too old says nothing
/// about now: an old "recording" (the app may have been terminated) turns into "unknown" rather
/// than staying on the face as if live.
public struct ComplicationDisplay: Equatable, Sendable {
    public enum Main: Equatable, Sendable { case recording, paused, error, idle, unknown }
    /// `waiting`: seconds of recorded audio not yet on the iPhone (nil: something is waiting but its
    /// length isn't known, e.g. only a recording's end marker).
    public enum Sync: Equatable, Sendable { case waiting(seconds: Int?), onIPhone, notConnected, unknown }

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
        let seconds = s.waitingSeconds.flatMap { $0 > 0 ? $0 : nil }
        let sync: Sync = !s.bound ? .notConnected : s.waitingParts > 0 ? .waiting(seconds: seconds) : .onIPhone
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
        case .waiting(let seconds?): second = "\(WaitingAudio.spoken(seconds)) of audio waiting to go to the iPhone"
        case .waiting(nil): second = "something waiting to go to the iPhone"
        case .onIPhone: second = "everything recorded is on the iPhone"
        case .notConnected: second = "not connected to an iPhone yet"
        case .unknown: second = ""
        }
        return second.isEmpty ? first : "\(first). \(second)."
    }
}

/// How long the audio waiting for the iPhone is, for people: from the parts' own lengths (a
/// partial part counts for what it holds), never parts × 60 s.
public enum WaitingAudio {
    /// Total length in seconds of these parts (each from its start and end offsets).
    public static func seconds(_ segments: [WatchSegment]) -> Int {
        Int(segments.reduce(0.0) { $0 + max(0, Double($1.endOffsetUs - $1.startOffsetUs)) / 1_000_000 }.rounded())
    }

    /// For the complication: "<1m", "12m", "3h".
    public static func short(_ seconds: Int) -> String {
        if seconds <= 0 { return "" }
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        return minutes < 100 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    /// In a sentence: "less than a minute", "12 min", "1 h 5 min".
    public static func text(_ seconds: Int) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// For VoiceOver: "less than a minute", "12 minutes", "1 hour 5 minutes".
    public static func spoken(_ seconds: Int) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = seconds / 60, h = minutes / 60, m = minutes % 60
        func unit(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        return h == 0 ? unit(m, "minute") : m == 0 ? unit(h, "hour") : "\(unit(h, "hour")) \(unit(m, "minute"))"
    }
}

/// When the app writes a new snapshot (and asks WidgetKit to reload): when what the face shows
/// changes (recorder state, pairing, waiting vs none), while recording at least every
/// `refreshWhileRecording` so the face doesn't go stale, and for a change of the length shown
/// ("12m" → "13m") at most every `countInterval`. Everything else waits: reloads are budgeted by the system.
public enum ComplicationPublishPolicy {
    public static let refreshWhileRecording: TimeInterval = 15 * 60
    public static let countInterval: TimeInterval = 5 * 60

    public static func shouldWrite(last: ComplicationSnapshot?, next: ComplicationSnapshot) -> Bool {
        guard let last else { return true }
        let age = next.at.timeIntervalSince(last.at)
        let sameShown = last.recorder == next.recorder && last.bound == next.bound && (last.waitingParts == 0) == (next.waitingParts == 0)
        if !sameShown { return true }
        if next.recorder == .recording && age >= refreshWhileRecording { return true }
        // what the face shows is the length ("12m"), not the number of parts
        let shownChanged = WaitingAudio.short(last.waitingSeconds ?? 0) != WaitingAudio.short(next.waitingSeconds ?? 0)
        return shownChanged && age >= countInterval
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
