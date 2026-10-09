import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

/// Pendant, Bluetooth and upload details for troubleshooting (what Home used to show).
/// Read-only apart from retrying: nothing here deletes audio.
struct DiagnosticsView: View {
    let model: AppModel

    private var s: EngineSnapshot { model.snapshot }

    var body: some View {
        List {
            connectionSection
            PendantDeviceSection(snapshot: s)
            LiveRecordingSection(snapshot: s)
            PendantSyncSection(snapshot: s)
            UploadsSection(model: model, showQuarantined: true)
            if !model.issues.isEmpty {
                Section {
                    ForEach(model.issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.message).font(.subheadline)
                            if let id = issue.conversationId { Text("Conversation \(id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                            if let step = issue.technicalStep {
                                Text(LocalizedStringKey(step)).font(.caption).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Server processing")
                } footer: {
                    Text("For whoever runs the server: commands run in Terminal on that computer.")
                }
            }
            Section {
                NavigationLink("Recent log") { LogView(model: model) }
            } footer: {
                Text("The log never contains your server token.")
            }
        }
        .navigationTitle("Diagnostics")
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Pendant", value: s.connection.title)
            if let name = s.rememberedDeviceName ?? s.device?.name { LabeledContent("Paired with", value: name) }
            LabeledContent("Server", value: model.server.label)
            if let free = s.freeBytes {
                LabeledContent("Free space on phone") {
                    Text(Fmt.bytes(free)).foregroundStyle(s.storageTripped ? .red : .primary)
                }
            }
            if s.simulated { Label("Simulated pendant", systemImage: "testtube.2").foregroundStyle(.orange) }
        }
    }

}

/// The app's recent log (tokens redacted), for troubleshooting.
struct LogView: View {
    let model: AppModel
    @State private var filter = ""

    var body: some View {
        List {
            TextField("Filter", text: $filter).textInputAutocapitalization(.never).autocorrectionDisabled()
            ForEach(model.logs.filter { filter.isEmpty || $0.message.localizedCaseInsensitiveContains(filter) || $0.category == filter }) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(line.date.formatted(date: .omitted, time: .standard)) · \(line.category) · \(line.level.rawValue)")
                        .font(.caption2).foregroundStyle(color(line.level))
                    Text(line.message).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Recent log")
        .toolbar { Button("Refresh") { model.refreshLogs() } }
        .onAppear { model.refreshLogs() }
    }

    private func color(_ l: LogLine.Level) -> Color {
        switch l {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        case .debug: return .gray
        }
    }
}

// MARK: - Pendant and upload sections (Diagnostics and the Pendant tab)

/// Model, firmware, battery, audio format, clock and Bluetooth packet size of the connected pendant.
struct PendantDeviceSection: View {
    let snapshot: EngineSnapshot
    private var s: EngineSnapshot { snapshot }

    var body: some View {
        if let d = s.device {
            Section("Pendant") {
                LabeledContent("Model", value: d.modelNumber ?? "—")
                LabeledContent("Firmware", value: d.firmwareRevision ?? "—")
                LabeledContent("Battery", value: d.battery.map { "\($0)%\(d.charging == true ? " · charging" : "")" } ?? "—")
                LabeledContent("Audio format", value: d.codec.map { "\($0.label) (\($0.rawValue))" } ?? "reading…")
                LabeledContent("Clock") {
                    Text(rtcText(d)).foregroundStyle(d.rtcValid == false ? .red : .primary)
                }
                if d.mtu > 0 {
                    LabeledContent("Bluetooth packet size") {
                        Text("\(d.mtu) bytes\(d.mtu < DeviceSession.lowMTUWarningThreshold ? " (small: audio may drop)" : "")")
                            .foregroundStyle(d.mtu < DeviceSession.lowMTUWarningThreshold ? .orange : .primary)
                    }
                }
                if d.noAudioYet {
                    Label("No audio yet. The pendant's microphone sleeps in silence; speak near it.", systemImage: "mic.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rtcText(_ d: DeviceSession.Info) -> String {
        switch d.rtcValid {
        case true?: return "Set\(d.clockDriftSeconds.map { " (off by \($0) s)" } ?? "")"
        case false?: return "Not set: offline recording is off"
        case nil: return d.clockDriftSeconds.map { "Synced (off by \($0) s)" } ?? "—"
        }
    }
}

/// The recording this phone is receiving right now.
struct LiveRecordingSection: View {
    let snapshot: EngineSnapshot
    private var s: EngineSnapshot { snapshot }

    var body: some View {
        if let l = s.live {
            Section("Live recording") {
                LabeledContent("Audio packets per second", value: String(format: "%.1f", l.notificationsPerSecond))
                LabeledContent("Packets lost", value: String(format: "%.2f %% (%d)", l.lossPercent, l.lost))
                LabeledContent("Recording", value: "\(Fmt.shortId(l.captureId)) · part \(l.chunkSequence + 1)")
                LabeledContent("Saved on phone", value: "\(l.totalRecords) packets")
                LabeledContent("Last audio", value: Fmt.relative(l.lastNotificationAt))
            }
        }
    }
}

/// Audio the pendant recorded while disconnected, and collecting it.
struct PendantSyncSection: View {
    let snapshot: EngineSnapshot
    private var s: EngineSnapshot { snapshot }

    var body: some View {
        Section("Audio saved on the pendant") {
            switch s.device?.offlineSupport {
            case .unsupported(let why)?: LabeledContent("Offline recording", value: "Not supported (\(why))")
            case .supported?: LabeledContent("Offline recording", value: "Supported")
            default: LabeledContent("Offline recording", value: "Unknown")
            }
            switch s.offline {
            case .idle: LabeledContent("Sync", value: "Idle")
            case .detecting, .requestingInfo, .starting: LabeledContent("Sync", value: "Starting…")
            case .receiving(let received, let total):
                VStack(alignment: .leading) {
                    Text("Collecting \(received) of \(total)")
                    ProgressView(value: Double(received), total: Double(max(total, 1)))
                }
            case .complete(let n): LabeledContent("Sync", value: n == 0 ? "Up to date" : "Collected \(n) records")
            case .interrupted(let why): LabeledContent("Sync", value: "Interrupted: \(why)")
            case .failed(let why): LabeledContent("Sync", value: "Failed: \(why)")
            case .unsupported(let why): LabeledContent("Sync", value: "Unsupported: \(why)")
            }
            if let unread = s.device?.offlineUnread { LabeledContent("Waiting on the pendant", value: "\(unread) records") }
        }
    }
}

/// Files waiting on this phone, upload progress and the last result; retrying is the only action.
struct UploadsSection: View {
    let model: AppModel
    /// File names of quarantined uploads (Diagnostics only).
    var showQuarantined = false
    private var s: EngineSnapshot { model.snapshot }

    var body: some View {
        Section {
            LabeledContent("Waiting", value: "\(s.outbox.pendingCount) files · \(Fmt.bytes(s.outbox.pendingBytes))")
            LabeledContent("Uploading now", value: "\(s.upload.inFlight)")
            LabeledContent("Uploaded (kept until cleanup)", value: "\(s.outbox.sentCount) · \(Fmt.bytes(s.outbox.sentBytes))")
            if s.outbox.quarantineCount > 0 {
                LabeledContent("Couldn't upload (kept)") { Text("\(s.outbox.quarantineCount)").foregroundStyle(.red) }
                if showQuarantined { ForEach(s.quarantined, id: \.self) { Text($0).font(.caption.monospaced()) } }
            }
            if let r = s.upload.lastResult {
                LabeledContent("Last result") {
                    Text("\(r.status.map(String.init) ?? "error") \(r.message) · \(Fmt.relative(r.date))")
                        .foregroundStyle(r.success ? Color.primary : Color.orange)
                        .font(.footnote)
                }
            }
            if let paused = s.upload.pausedReason { Label(paused, systemImage: "pause.circle").foregroundStyle(.red) }
            Button("Retry uploads now") { model.engine.retryUploads() }
        } header: {
            Text("Uploads")
        } footer: {
            Text("Files are deleted from this phone only after the server confirms it saved them. Files that couldn't be uploaded are kept, never deleted automatically.")
        }
    }
}
