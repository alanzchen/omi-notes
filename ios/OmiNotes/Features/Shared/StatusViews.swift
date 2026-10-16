import OmiBLE
import OmiProtocol
import SwiftUI

extension SystemHealth.Level {
    var color: Color {
        switch self {
        case .normal: return .green
        case .working: return .blue
        case .unknown: return .gray
        case .delayed: return .orange
        case .needsAction: return .red
        }
    }

    /// Icons carry the meaning too, so color is never the only signal.
    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .working: return "arrow.triangle.2.circlepath.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .delayed: return "clock.badge.exclamationmark.fill"
        case .needsAction: return "exclamationmark.triangle.fill"
        }
    }

    var accessibilityName: String {
        switch self {
        case .normal: return "OK"
        case .working: return "Working"
        case .unknown: return "Unknown"
        case .delayed: return "Delayed"
        case .needsAction: return "Needs action"
        }
    }
}

extension SystemHealth.Area {
    var title: String {
        switch self {
        case .pendant: return "Pendant"
        case .watch: return "Apple Watch"
        case .phone: return "Phone"
        case .server: return "Server"
        case .notes: return "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .pendant: return "waveform.circle"
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .server: return "server.rack"
        case .notes: return "doc.text"
        }
    }
}

extension SystemHealth.Fix {
    var title: String {
        switch self {
        case .pairDevice: return "Pair pendant"
        case .reconnectDevice: return "Reconnect"
        case .openBluetoothSettings: return "Open Settings"
        case .retryUploads: return "Retry now"
        case .openServer: return "Open Server"
        case .openDiagnostics: return "Show details"
        case .resumeRecording: return "Resume"
        case .collectPendantAudio: return "Collect"
        case .openDevices: return "Set up a device"
        }
    }
}

/// The one-sentence answer to "is it working?"; tap to see each step and its fix.
struct HealthCard: View {
    let health: SystemHealth
    var onFix: (SystemHealth.Fix) -> Void
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation { expanded.toggle() } } label: {
                AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 12) {
                    Image(systemName: health.level.symbol).font(.title2).foregroundStyle(health.level.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(health.headline).font(.headline).foregroundStyle(.primary)
                        if let detail = health.detail, detail != health.headline {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !typeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(health.level.accessibilityName). \(health.headline)")
            .accessibilityHint(expanded ? "Hides the details" : "Shows each step")

            if expanded {
                ForEach(health.steps) { step in StepRow(step: step, onFix: onFix) }
            } else if let fix = health.steps.first(where: { $0.level == health.level })?.fix, health.level >= .delayed {
                Button(fix.title) { onFix(fix) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StepRow: View {
    let step: SystemHealth.Step
    var onFix: (SystemHealth.Fix) -> Void
    /// A fix not to offer here (e.g. "Open Server" on the Server page itself).
    var hiding: SystemHealth.Fix?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric private var iconWidth: CGFloat = 22

    var body: some View {
        AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 10) {
            Image(systemName: step.level.symbol).foregroundStyle(step.level.color)
                .frame(width: typeSize.isAccessibilitySize ? nil : iconWidth).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.area.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(step.title).font(.subheadline)
                if let detail = step.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if let fix = step.fix, fix != hiding, step.level >= .delayed {
                    Button(fix.title) { onFix(fix) }.buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.area.title): \(step.level.accessibilityName). \(step.title). \(step.detail ?? "")")
    }
}

/// The server's display state for a conversation, shown only when it isn't simply "ready".
struct StateChip: View {
    let state: ConversationFlag

    var body: some View {
        Text(label).font(.caption2.weight(.semibold)).lineLimit(1).fixedSize().padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color).background(color.opacity(0.14), in: .capsule)
            .accessibilityLabel(state.message)
    }

    private var label: String {
        switch state.code {
        case "listening": return "In progress"
        case "processing": return "Processing"
        case "retrying": return "Retrying"
        case "transcript_only": return "Transcript only"
        case "failed": return "Failed"
        case "discarded": return "Skipped"
        case "kept_speaker_unknown": return "Transcript only"
        case "ready": return "Ready"
        default: return state.code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var color: Color {
        switch state.code {
        case "listening", "processing": return .blue
        case "retrying", "transcript_only": return .orange
        case "failed": return .red
        case "discarded", "kept_speaker_unknown": return .gray
        default: return .green
        }
    }
}

extension Fmt {
    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds >= 1 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
        f.unitsStyle = .short
        return f.string(from: seconds)
    }

    static func time(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .shortened) ?? "—"
    }

    /// "Today", "Yesterday", or the date.
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// A row that becomes a column at accessibility text sizes (so text isn't squeezed beside icons).
struct AdaptiveStack<Content: View>: View {
    var vertical: Bool
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
                              : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        layout(content)
    }
}
