import OmiWatchKit
import SwiftUI

/// One screen: what is happening, one button, and what is still on the Watch.
struct RecordView: View {
    let recorder: WatchRecorder
    let sync: WatchSync

    var body: some View {
        // fills the screen when it fits; scrolls (below the clock) when a message makes it taller
        GeometryReader { g in
            ScrollView {
                VStack(spacing: 10) {
                    hero
                    Spacer(minLength: 0)
                    primary
                    Spacer(minLength: 0)
                    syncRow
                }
                .frame(minHeight: g.size.height)
                .padding(.horizontal, 8)  // capsules clear the screen's rounded edge
                details.padding(.top, 8).padding(.horizontal, 6)
            }
        }
        .navigationTitle("Omi Notes")
    }

    // MARK: Status

    private var mark: ComplicationDisplay.Main {
        switch recorder.state {
        case .recording: return .recording
        case .interrupted: return recorder.isActive ? .paused : .error
        case .failed: return .error
        case .idle: return .idle
        }
    }

    @ViewBuilder private var hero: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                RecorderMark(main: mark, scale: 0.75).frame(height: 13)
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(titleColor)
            }
            .accessibilityElement(children: .combine)
            switch recorder.state {
            case .recording(let since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(elapsed(since, context.date)).font(.system(size: 40, weight: .medium, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
                .accessibilityLabel("Recording time")
            case .interrupted(let why), .failed(let why):
                Text(Self.reason(why)).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
        }
    }

    private var title: String {
        switch recorder.state {
        case .recording: return "Recording"
        case .interrupted: return recorder.isActive ? "Paused" : "Recording stopped"
        case .failed: return "Can't record"
        case .idle: return "Ready to record"
        }
    }

    private var titleColor: Color {
        switch mark {
        case .recording: return Color(red: 1, green: 0.35, blue: 0.3)
        case .paused: return .orange
        case .error: return .yellow
        default: return .secondary
        }
    }

    /// The recorder's message without what the buttons already say.
    static func reason(_ text: String) -> String {
        var t = text
        for prefix in ["Paused: ", "Paused. "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        for suffix in [" Tap Resume to try again.", " Tap Resume to continue."] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        if t == "Tap Resume to continue." || t.isEmpty { return "Tap Resume when you're ready." }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: Action

    @ViewBuilder private var primary: some View {
        if recorder.isRecording {
            Button { recorder.stop() } label: {
                Label("Stop", systemImage: "stop.fill").font(.system(size: 17, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Color.white.opacity(0.14), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        } else if case .interrupted = recorder.state, recorder.isActive {
            VStack(spacing: 6) {
                Button { recorder.resume() } label: {
                    Label("Resume", systemImage: "play.fill").font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 46)
                        .background(Color.orange, in: .capsule)
                }
                .buttonStyle(.plain)
                Button("Stop recording") { recorder.stop() }.buttonStyle(.plain).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Button { recorder.start() } label: {
                ZStack {
                    Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 3).frame(width: 76, height: 76)
                    Circle().fill(Color(red: 1, green: 0.23, blue: 0.19)).frame(width: 60, height: 60)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")
        }
    }

    // MARK: Sync

    @ViewBuilder private var syncRow: some View {
        HStack(spacing: 5) {
            if sync.binding == nil {
                Image(systemName: "iphone.slash")
                Text("Open Omi Notes on iPhone to connect")
            } else if sync.pending > 0 {
                Image(systemName: "iphone")
                Text(sync.pendingSeconds > 0 ? "\(WaitingAudio.text(sync.pendingSeconds).capitalizedFirst) waiting for iPhone"
                                             : "Finishing sending to iPhone")
            } else if sync.lastAckAt != nil || recorder.isActive {
                Image(systemName: "checkmark")
                Text("All audio on iPhone")
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// Below the main view: what helps, and the details.
    @ViewBuilder private var details: some View {
        VStack(spacing: 4) {
            if sync.pending > 0, sync.lastAckAt.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
                Text("Keep your iPhone nearby with Omi Notes open.").foregroundStyle(.orange)
            }
            if recorder.isRecording { Text("Keeps recording with your wrist down until you stop it.") }
            if let at = sync.lastAckAt { Text("iPhone confirmed \(at.formatted(date: .omitted, time: .shortened))") }
            if sync.held > 0 { Text("Some audio is kept for another iPhone.").foregroundStyle(.orange) }
        }
        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func elapsed(_ since: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension String {
    /// "less than a minute" → "Less than a minute"
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
