import OmiProtocol
import SwiftUI

/// The sync Live Activity's views (the Lock Screen extension, and a debug preview in the app).
/// The approved warm palette (light and dark), as in the app.
enum SyncPalette {
    static let background = Color(syncLight: 0xf4f2ee, dark: 0x161513)
    static let ink = Color(syncLight: 0x1c1c1e, dark: 0xf2efe9)
    static let secondary = Color(syncLight: 0x8a8578, dark: 0x9d988c)
    static let warn = Color(syncLight: 0xb4520e, dark: 0xf2a466)
    static let track = Color(syncLight: 0xe4dfd6, dark: 0x34312c)
}

extension Color {
    init(syncLight light: UInt32, dark: UInt32) {
        func rgb(_ v: UInt32) -> Color {
            Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
        }
        self = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb(dark)) : UIColor(rgb(light)) })
    }
}

enum SyncWords {
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    static func rate(_ bps: Double) -> String {
        if bps < 1_000 { return "\(Int(bps.rounded())) B/s" }
        if bps < 1_000_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.1f MB/s", bps / 1_000_000)
    }

    static func shortStage(_ s: SyncActivityState) -> String {
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
    static func queued(_ s: SyncActivityState) -> String? {
        guard let seconds = s.queuedAudioSeconds else { return s.queuedFiles == nil ? "Queue unknown" : nil }
        if seconds == 0 { return s.queuedFiles == 0 ? nil : "Audio length unknown" }
        return "\(s.queuedAudioPartial ? "At least " : "")\(duration(seconds)) of audio to send"
    }

    static func trailing(_ s: SyncActivityState, stale: Bool) -> String {
        if !stale, let r = s.rate { return rate(r) }
        if let q = s.queuedAudioSeconds, q > 0 { return duration(q) }
        return ""
    }

    static func compact(_ s: SyncActivityState, stale: Bool) -> String {
        if !stale, let r = s.rate { return rate(r) }
        if let q = s.queuedAudioSeconds, q > 0 { return duration(q) }
        return shortStage(s)
    }
}

struct SyncStageIcon: View {
    let stage: SyncActivityState.Stage
    var body: some View {
        Image(systemName: symbol).foregroundStyle(attention ? SyncPalette.warn : SyncPalette.ink)
    }
    private var attention: Bool { [.retrying, .offline, .paused, .keptAside, .queueUnreadable, .notConfigured].contains(stage) }
    private var symbol: String {
        switch stage {
        case .sending: return "arrow.up.circle.fill"
        case .waiting: return "clock"
        case .retrying: return "arrow.clockwise"
        case .offline: return "wifi.exclamationmark"
        case .paused: return "pause.circle"
        case .preparing: return "gearshape"
        case .keptAside: return "tray.full"
        case .queueUnreadable: return "questionmark.folder"
        case .allSent: return "checkmark.circle"
        case .notConfigured: return "server.rack"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// The stages, each from its own source; nothing shown that wasn't known.
struct SyncLines: View {
    let state: SyncActivityState
    let stale: Bool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let q = SyncWords.queued(state) { Text("iPhone → server: \(q)").font(.caption).lineLimit(1) }
            if !stale, let r = state.rate { Text("Sending now at \(SyncWords.rate(r))").font(.caption).foregroundStyle(SyncPalette.secondary) }
            if let sent = state.batchSent, let total = state.batchTotal, total > 0, !stale {
                ProgressView(value: Double(sent), total: Double(total)) { Text("Current batch").font(.caption2) }
                    .tint(SyncPalette.ink).frame(maxWidth: .infinity)
            }
            if let w = state.watchWaitingSeconds, w > 0 {
                Text("Watch: \(SyncWords.duration(Double(w))) waiting\(state.watchReportAt.map { " · reported \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
                    .font(.caption).foregroundStyle(SyncPalette.secondary).lineLimit(1)
            }
            if let d = state.detail { Text(d).font(.caption).foregroundStyle(SyncPalette.secondary).lineLimit(2) }
            if stale {
                Text("As of \(state.asOf.formatted(date: .omitted, time: .shortened)) · open Omi Notes to update")
                    .font(.caption2).foregroundStyle(SyncPalette.secondary)
            }
        }
    }
}

struct SyncLockScreenView: View {
    let state: SyncActivityState
    let stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SyncStageIcon(stage: state.stage).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(stale && state.stage == .sending ? "Was sending to your server" : state.title).font(.headline).foregroundStyle(SyncPalette.ink)
                SyncLines(state: state, stale: stale)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        // a Live Activity has a fixed height: past this size its lines would be cut off
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
