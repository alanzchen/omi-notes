import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

struct HomeView: View {
    let model: AppModel

    private var s: EngineSnapshot { model.snapshot }

    /// Simulator automation only (debug builds): `-OmiNotesDebugHomeBottom YES` scrolls Home to the
    /// upload/server/notes sections after launch (a headless simulator can't scroll).
    private static var debugScrollToBottom: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "OmiNotesDebugHomeBottom")
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                statusSection
                if !s.attention.isEmpty { attentionSection }
                deviceSection
                liveSection
                offlineSection
                uploadSection
                serverSection
                conversationsSection.id("conversations")
            }
            .task {
                guard Self.debugScrollToBottom else { return }
                try? await Task.sleep(for: .seconds(3))
                proxy.scrollTo("conversations", anchor: .bottom)
            }
        }
        .navigationTitle("Omi Notes")
        .refreshable { await model.refreshServer() }
        .task {
            while !Task.isCancelled {
                await model.refreshServer()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                StatusDot(color: connectionColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.connection.title).font(.headline)
                    if let detail = connectionDetail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                if s.simulated { Text("SIMULATED").font(.caption2.bold()).padding(4).background(.yellow.opacity(0.3), in: .rect(cornerRadius: 4)) }
            }
            if let name = s.rememberedDeviceName ?? s.device?.name {
                LabeledContent("Device", value: name)
            }
            if s.storageTripped, let free = s.freeBytes {
                Label("Phone storage low: \(Fmt.bytes(free)) free", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
            }
        }
    }

    private var attentionSection: some View {
        Section("Needs attention") {
            ForEach(s.attention, id: \.self) { msg in
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
            }
            Button("Dismiss") { model.engine.clearAttention() }
        }
    }

    @ViewBuilder private var deviceSection: some View {
        if let d = s.device {
            Section("Device") {
                LabeledContent("Model", value: d.modelNumber ?? "—")
                LabeledContent("Firmware", value: d.firmwareRevision ?? "—")
                LabeledContent("Battery", value: d.battery.map { "\($0)%\(d.charging == true ? " · charging" : "")" } ?? "—")
                LabeledContent("Codec", value: d.codec.map { "\($0.rawValue) · \($0.label)" } ?? "reading…")
                LabeledContent("Device clock") {
                    Text(rtcText(d)).foregroundStyle(d.rtcValid == false ? .red : .primary)
                }
                if d.mtu > 0 {
                    LabeledContent("MTU payload") {
                        Text("\(d.mtu) B\(d.mtu < DeviceSession.lowMTUWarningThreshold ? " (low: frames may drop)" : "")")
                            .foregroundStyle(d.mtu < DeviceSession.lowMTUWarningThreshold ? .orange : .primary)
                    }
                }
                if d.noAudioYet {
                    Label("No audio yet — the device mic sleeps in silence; speak near it.", systemImage: "mic.slash").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var liveSection: some View {
        if let l = s.live {
            Section("Live capture") {
                LabeledContent("Notifications/s", value: String(format: "%.1f", l.notificationsPerSecond))
                LabeledContent("Loss (seq gaps)", value: String(format: "%.2f %% (%d lost)", l.lossPercent, l.lost))
                LabeledContent("Capture", value: "\(Fmt.shortId(l.captureId)) · chunk \(l.chunkSequence) · \(l.chunkRecords) rec")
                LabeledContent("Journaled", value: "\(l.totalRecords) notifications")
                LabeledContent("Last audio", value: Fmt.relative(l.lastNotificationAt))
            }
        }
    }

    private var offlineSection: some View {
        Section("Offline storage sync") {
            switch s.device?.offlineSupport {
            case .unsupported(let why)?: LabeledContent("Support", value: "Unsupported (\(why))")
            case .supported?: LabeledContent("Support", value: "Supported")
            default: LabeledContent("Support", value: "Unknown")
            }
            switch s.offline {
            case .idle: LabeledContent("State", value: "Idle")
            case .detecting, .requestingInfo, .starting: LabeledContent("State", value: "Starting…")
            case .receiving(let received, let total):
                VStack(alignment: .leading) {
                    Text("Downloading \(received) / \(total) records")
                    ProgressView(value: Double(received), total: Double(max(total, 1)))
                }
            case .complete(let n): LabeledContent("State", value: n == 0 ? "Up to date (nothing buffered)" : "Synced \(n) records")
            case .interrupted(let why): LabeledContent("State", value: "Interrupted: \(why)")
            case .failed(let why): LabeledContent("State", value: "Failed: \(why)")
            case .unsupported(let why): LabeledContent("State", value: "Unsupported: \(why)")
            }
            if let unread = s.device?.offlineUnread { LabeledContent("Buffered on device", value: "\(unread) records") }
        }
    }

    private var uploadSection: some View {
        Section("Upload queue") {
            LabeledContent("Waiting", value: "\(s.outbox.pendingCount) files · \(Fmt.bytes(s.outbox.pendingBytes))")
            LabeledContent("Uploading", value: "\(s.upload.inFlight)")
            LabeledContent("Acknowledged (kept)", value: "\(s.outbox.sentCount) · \(Fmt.bytes(s.outbox.sentBytes))")
            if s.outbox.quarantineCount > 0 {
                LabeledContent("Kept, not uploaded") { Text("\(s.outbox.quarantineCount)").foregroundStyle(.red) }
            }
            if let r = s.upload.lastResult {
                LabeledContent("Last result") {
                    Text("\(r.status.map(String.init) ?? "error") \(r.message) · \(Fmt.relative(r.date))")
                        .foregroundStyle(r.success ? Color.primary : Color.orange)
                        .font(.footnote)
                }
            }
            if let paused = s.upload.pausedReason { Label(paused, systemImage: "pause.circle").foregroundStyle(.red) }
            if !s.serverConfigured { Label("Configure the server in Settings", systemImage: "server.rack").foregroundStyle(.secondary) }
            Button("Retry now") { model.engine.retryUploads() }
        }
    }

    private var serverSection: some View {
        Section("Server") {
            LabeledContent("Status") {
                Text(model.server.label).foregroundStyle(serverColor)
            }
            if case .reachable(_, let detail) = model.server {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            if let host = model.serverURL?.host() { LabeledContent("Host", value: host) }
        }
    }

    private var conversationsSection: some View {
        Section("Recent conversations") {
            if model.recent.isEmpty {
                Text(model.recentError ?? "None yet").foregroundStyle(.secondary).font(.subheadline)
            }
            ForEach(model.recent) { c in
                if c.canReviewSpeakers {
                    NavigationLink {
                        ConversationSpeakersView(model: model, conversationId: c.id, title: c.title ?? "Speakers")
                    } label: {
                        conversationRow(c)
                    }
                } else {
                    conversationRow(c)
                }
            }
        }
    }

    private func conversationRow(_ c: ConversationSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(c.title ?? "Untitled").font(.body.weight(.medium))
                Spacer()
                Text(c.status).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor(c.status).opacity(0.15), in: .capsule)
            }
            Text("\(Fmt.iso(c.startedAt))\(c.provisional == true ? " · provisional" : "")\(c.lateAudio == true ? " · late audio" : "")")
                .font(.caption).foregroundStyle(.secondary)
            if let path = c.notePath { Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            if !c.canReviewSpeakers {
                Text("Speaker details will be available after transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private var connectionColor: Color {
        switch s.connection {
        case .streaming: return .green
        case .settingUp, .waitingForDevice: return .yellow
        case .noDevice: return .gray
        default: return .red
        }
    }

    private var connectionDetail: String? {
        switch s.connection {
        case .bluetoothUnavailable: return nil
        case .waitingForDevice: return "Pending connection — the device buffers to its own storage while away."
        case .refused(let why), .paused(let why): return why
        case .streaming: return s.live?.lastNotificationAt == nil ? "Connected; waiting for sound" : nil
        default: return nil
        }
    }

    private var serverColor: Color {
        switch model.server {
        case .reachable: return .green
        case .unauthorized, .unreachable: return .red
        default: return .secondary
        }
    }

    private func rtcText(_ d: DeviceSession.Info) -> String {
        switch d.rtcValid {
        case true?: return "Valid\(d.clockDriftSeconds.map { " (drift \($0) s)" } ?? "")"
        case false?: return "Invalid — offline recording disabled"
        case nil: return d.clockDriftSeconds.map { "Synced (drift \($0) s)" } ?? "—"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "failed": return .red
        case "discarded": return .gray
        default: return .blue
        }
    }
}
