import SwiftUI

/// One screen: what is happening, one button, and what is still on the Watch.
struct RecordView: View {
    let recorder: WatchRecorder
    let sync: WatchSync

    var body: some View {
        VStack(spacing: 10) {
            status
            Spacer(minLength: 0)
            button
            Spacer(minLength: 0)
            syncLine
        }
        .padding(.horizontal, 6)
        .navigationTitle("Omi Notes")
    }

    @ViewBuilder private var status: some View {
        switch recorder.state {
        case .idle:
            Label("Not recording", systemImage: "mic.slash").foregroundStyle(.secondary).font(.footnote)
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Recording · \(elapsed(since, context.date))").font(.footnote.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        case .interrupted(let why):
            Text(why).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let why):
            Text(why).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var button: some View {
        if recorder.isRecording {
            Button { recorder.stop() } label: {
                Image(systemName: "stop.fill").font(.title2)
                    .frame(width: 74, height: 74).background(Color.white.opacity(0.18), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        } else if case .interrupted = recorder.state, recorder.isActive {
            HStack(spacing: 14) {
                Button("Resume") { recorder.resume() }.tint(.red)
                Button("Stop") { recorder.stop() }
            }
        } else {
            Button { recorder.start() } label: {
                Image(systemName: "mic.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 74, height: 74).background(Color.red, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")
        }
    }

    private var syncLine: some View {
        Group {
            if sync.binding == nil {
                Text("Open Omi Notes on your iPhone to connect.")
            } else if sync.pending > 0 {
                Text("\(sync.pending) part\(sync.pending == 1 ? "" : "s") waiting for iPhone")
            } else {
                Label("All sent to iPhone", systemImage: "checkmark")
            }
            if sync.held > 0 { Text("\(sync.held) kept for another iPhone").foregroundStyle(.orange) }
        }
        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    private func elapsed(_ since: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
