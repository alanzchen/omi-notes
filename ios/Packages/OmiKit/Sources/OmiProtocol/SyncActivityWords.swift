import Foundation

/// The sync Live Activity's words (Lock Screen, Dynamic Island and the app's preview): unknown stays
/// unknown and a lower bound says so.
public enum SyncWords {
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    public static func rate(_ bps: Double) -> String {
        if bps < 1_000 { return "\(Int(bps.rounded())) B/s" }
        if bps < 1_000_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.1f MB/s", bps / 1_000_000)
    }

    public static func shortStage(_ s: SyncActivityState) -> String {
        switch s.stage {
        case .sending: return "Sending"
        case .waiting: return "Waiting"
        case .retrying: return "Retrying"
        case .offline: return "Offline"
        case .paused: return "Paused"
        case .preparing: return "Preparing"
        case .keptAside: return "Kept aside"
        case .queueUnreadable: return "Unknown"
        case .allSent: return "Sent"
        case .notConfigured: return "No server"
        case .unknown: return "Unknown"
        }
    }

    /// The audio still to send, honestly: unknown stays unknown, a lower bound says so.
    public static func queued(_ s: SyncActivityState) -> String? {
        guard let files = s.queuedFiles else { return "Queue unknown" }
        guard let seconds = s.queuedAudioSeconds else { return files > 0 ? "audio of unknown length to send" : nil }
        if seconds == 0 { return files == 0 ? nil : "\(files) file\(files == 1 ? "" : "s") to send" }
        return "\(s.queuedAudioPartial ? "at least " : "")\(duration(seconds)) of audio to send"
    }

    /// The queued audio in a few characters; "≥" when some lengths are unknown.
    public static func queuedShort(_ s: SyncActivityState) -> String? {
        guard let q = s.queuedAudioSeconds, q > 0 else { return nil }
        return "\(s.queuedAudioPartial ? "≥" : "")\(duration(q))"
    }

    public static func trailing(_ s: SyncActivityState, stale: Bool) -> String {
        if !stale, let r = s.rate { return rate(r) }
        return queuedShort(s) ?? ""
    }

    public static func compact(_ s: SyncActivityState, stale: Bool) -> String {
        if !stale, let r = s.rate { return rate(r) }
        if let q = queuedShort(s) { return q }
        if s.stage == .allSent, let w = s.watchWaitingSeconds, w > 0 { return "Watch \(duration(Double(w)))" }  // not "Sent"
        return shortStage(s)
    }

    /// The batch in flight: a bar only when every upload's size is known.
    public static func batch(_ s: SyncActivityState) -> (fraction: Double?, text: String)? {
        guard let sent = s.batchSent, let total = s.batchTotal, total > 0 else { return nil }
        let unknown = s.batchUnknownUploads ?? 0
        if unknown == 0 { return (Double(sent) / Double(total), "Current batch") }
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return (nil, "Batch: \(bytes(sent)) of \(bytes(total)) sent, plus \(unknown) of unknown size")
    }
}
