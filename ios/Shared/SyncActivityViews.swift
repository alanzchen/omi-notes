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
            if let q = SyncWords.queued(state) { Text("iPhone → server: \(q)").font(.caption).lineLimit(1).minimumScaleFactor(0.75) }
            if !stale, let r = state.rate { Text("Sending now at \(SyncWords.rate(r))").font(.caption).foregroundStyle(SyncPalette.secondary) }
            if !stale, let batch = SyncWords.batch(state) {
                if let f = batch.fraction {
                    ProgressView(value: f) { Text(batch.text).font(.caption2) }.tint(SyncPalette.ink).frame(maxWidth: .infinity)
                } else {
                    Text(batch.text).font(.caption2).foregroundStyle(SyncPalette.secondary).lineLimit(2)
                }
            }
            if let w = state.watchWaitingSeconds, w > 0 {
                Text("Watch: \(SyncWords.duration(Double(w))) waiting\(state.watchReportAt.map { " · reported \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
                    .font(.caption).foregroundStyle(SyncPalette.secondary).lineLimit(1).minimumScaleFactor(0.75)
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
