import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

/// Is the server working, what needs attention and how to fix it, and how it is set up.
/// Configuration is view-only: it is changed on the server, not from the phone.
struct ServerView: View {
    enum Page: Hashable { case diagnostics, connection, developer }

    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void

    private var status: ServerStatus? { model.serverStatus }
    private var s: EngineSnapshot { model.snapshot }

    var body: some View {
        List {
            statusSection
            issuesSection
            processingSection
            if let status { configurationSection(status) }
            connectionSection
            Section {
                NavigationLink("Diagnostics", value: Page.diagnostics)
                #if DEBUG
                NavigationLink("Developer tools", value: Page.developer)
                #endif
            } footer: {
                Text("Diagnostics shows the pendant, Bluetooth and upload details used for troubleshooting.")
            }
        }
        .navigationTitle("Server")
        .refreshable { await model.refreshServer() }
        .navigationDestination(for: Page.self) { page in
            switch page {
            case .diagnostics: DiagnosticsView(model: model)
            case .connection: ServerConnectionView(model: model)
            case .developer:
                #if DEBUG
                DebugView(model: model)
                #else
                EmptyView()
                #endif
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    let server = model.health(now: context.date).steps.first { $0.area == .server }!
                    StepRow(step: server) { fix in
                        if fix != .openServer { onFix(fix) }  // already here
                    }
                    if let at = model.serverStatusAt {
                        Text("Last answered \(SystemHealth.relative(at, context.date))").font(.caption).foregroundStyle(.secondary)
                    }
                    if case .unreachable(let why) = model.server {
                        Text("Last attempt failed: \(why)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var issuesSection: some View {
        if !model.issues.isEmpty {
            Section {
                ForEach(model.issues) { issue in IssueRow(model: model, issue: issue) }
            } header: {
                Text("Needs attention")
            } footer: {
                Text("Commands run in Terminal on the computer that runs your server.")
            }
        }
    }

    private var processingSection: some View {
        Section {
            LabeledContent("Files waiting to upload", value: "\(s.outbox.pendingCount)")
            if s.upload.inFlight > 0 { LabeledContent("Uploading now", value: "\(s.upload.inFlight)") }
            LabeledContent("Last upload", value: Fmt.relative(s.upload.lastSuccessAt))
            if let q = status?.queue {
                LabeledContent("In progress", value: "\(q.conversationsOpen ?? 0)")
                LabeledContent("Being processed", value: "\(q.conversationsPending ?? 0)")
                if let retrying = q.conversationsRetrying, retrying > 0 { LabeledContent("Retrying", value: "\(retrying)") }
                let failed = q.conversationsFailed.map { $0 + (q.chunksFailed ?? 0) } ?? q.failed ?? 0
                LabeledContent("Failed") { Text("\(failed)").foregroundStyle(failed > 0 ? .red : .primary) }
                if let conflicts = q.notesConflicted, conflicts > 0 {
                    LabeledContent("Notes edited elsewhere") { Text("\(conflicts)").foregroundStyle(.orange) }
                }
            }
            if let present = status?.worker?.present {
                LabeledContent("Processing service", value: present ? "Running" : "Stopped")
            }
            if let last = status?.lastNoteAt.flatMap(ISO8601UTC.parse) {
                LabeledContent("Last note", value: Fmt.relative(last))
            }
        } header: {
            Text("Processing")
        } footer: {
            Text("Recordings stay on this phone until the server confirms it has saved them.")
        }
    }

    private func configurationSection(_ st: ServerStatus) -> some View {
        Section {
            LabeledContent("Transcription", value: providerLabel(st.stt))
            if let d = st.stt?.diarization { LabeledContent("Speaker separation", value: diarizationLabel(d)) }
            LabeledContent("Summaries", value: st.llm?.provider == "none" ? "Turned off" : providerLabel(st.llm))
            if let dir = st.notesDir { LabeledContent("Notes folder", value: dir).font(.footnote) }
            LabeledContent("Server version", value: st.serverVersion ?? "—")
            if let started = st.serverStartedAt.flatMap(ISO8601UTC.parse) {
                LabeledContent("Running since", value: started.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("Configuration")
        } footer: {
            Text("Set on the server. Your server decides which services receive your audio and transcripts. “Ready” means configured; it isn't a test that the service works.")
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            if let host = model.serverURL?.host() {
                LabeledContent("Server", value: host)
            }
            NavigationLink(model.serverURL == nil ? "Connect a server" : "Change server", value: Page.connection)
        }
    }

    private func providerLabel(_ p: ServerStatus.Provider?) -> String {
        guard let p else { return "—" }
        let name = [p.provider, p.model].compactMap { $0 }.joined(separator: " · ")
        let ready = p.ready == false ? " (not set up)" : ""
        return (name.isEmpty ? "—" : name) + ready
    }

    private func diarizationLabel(_ mode: String) -> String {
        switch mode {
        case "local": return "On the server"
        case "provider": return "By the transcription service"
        case "off": return "Off"
        default: return "Automatic"
        }
    }
}

/// One server problem: what happened, what to do, and the conversation it concerns.
struct IssueRow: View {
    let model: AppModel
    let issue: ServerIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.message, systemImage: issue.needsAction ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                .foregroundStyle(issue.needsAction ? .red : .orange).font(.subheadline.weight(.medium))
            if let detail = issue.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if let step = issue.nextStep {
                Text(LocalizedStringKey(step)).font(.caption).textSelection(.enabled)
            }
            if let id = issue.conversationId {
                NavigationLink {
                    ConversationDetailView(model: model, summary: placeholder(id))
                } label: {
                    Text(conversationLabel).font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var conversationLabel: String {
        let when = issue.startedAt.flatMap(ISO8601UTC.parse).map { "\(Fmt.day($0)), \(Fmt.time($0))" }
        return [issue.title ?? "Conversation", when].compactMap { $0 }.joined(separator: " · ")
    }

    private func placeholder(_ id: String) -> ConversationSummary {
        model.recent.first { $0.id == id }
            ?? ConversationSummary(id: id, status: "failed", startedAt: issue.startedAt, title: issue.title)
    }
}

/// Server URL and token (pairing), reached from the Server tab.
struct ServerConnectionView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Text("On the computer that runs your server, run `omi-notes pair` and scan the QR code with the iPhone Camera app. The link opens this app and asks you to confirm.")
                    .font(.subheadline)
            }
            ServerSettingsSection(model: model)
        }
        .navigationTitle("Server connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}
