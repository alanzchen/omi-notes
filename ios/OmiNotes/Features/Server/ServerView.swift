import OmiBLE
import OmiCapture
import OmiProtocol
import Charts
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
            WeekSection(model: model)
            activitySection
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

    @ViewBuilder private var activitySection: some View {
        if let a = status?.activity {
            Section {
                if let running = a.running?.first {
                    Label("\(running.stage == "summarizing" ? "Writing the summary of" : "Transcribing") the \(when(running.startedAt)) conversation",
                          systemImage: "gearshape.2")
                }
                if let waiting = a.waiting, waiting > 0 {
                    LabeledContent("Waiting", value: "\(waiting)\(a.oldestWaitingEndedAt.flatMap(ISO8601UTC.parse).map { " · oldest ended \(Fmt.relative($0))" } ?? "")")
                }
                if let backing = a.backingOff, backing > 0 {
                    LabeledContent("Waiting to try again") { Text("\(backing)").foregroundStyle(.orange) }
                }
                ServiceCallsRow(title: "Transcription service", calls: a.stt)
                if status?.llm?.provider != "none" { ServiceCallsRow(title: "Summary service", calls: a.llm) }
            } header: {
                Text("Now")
            } footer: {
                Text("A successful request to a service means it answered; the note still has to be written. Times reset when the server rebuilds its index.")
            }
        }
    }

    private func when(_ iso: String?) -> String {
        guard let d = iso.flatMap(ISO8601UTC.parse) else { return "" }
        return Calendar.current.isDateInToday(d) ? Fmt.time(d) : "\(Fmt.day(d)) \(Fmt.time(d))"
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
            if issue.code == "conversation_failed", let id = issue.conversationId, model.canRetry {
                RetryControl(model: model, conversationId: id)
            }
            if issue.code == "chunks_failed", model.canRetry {
                Button("Try these audio files again") { Task { await model.retryFailedAudio() } }
                    .buttonStyle(.bordered).controlSize(.small)
                if let msg = model.retryMessages["chunks"] { Text(msg).font(.caption).foregroundStyle(.secondary) }
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

/// When a service last answered, and whether the latest request failed.
struct ServiceCallsRow: View {
    let title: String
    let calls: ServerStatus.Activity.ProviderCalls?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let calls {
                if let ok = calls.lastOkAt.flatMap(ISO8601UTC.parse) {
                    Text("Last successful request \(Fmt.relative(ok))").font(.caption).foregroundStyle(.secondary)
                }
                if let failed = calls.lastErrorAt.flatMap(ISO8601UTC.parse) {
                    Text("Last attempt failed \(Fmt.relative(failed))\(calls.lastErrorKind.map { " (\($0))" } ?? "")")
                        .font(.caption).foregroundStyle(calls.lastFailed ? .orange : .secondary)
                }
            } else {
                Text("No requests since the server started keeping track").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Retry a failed conversation, and follow the retry until the server says how it ended.
struct RetryControl: View {
    let model: AppModel
    let conversationId: String
    @State private var sending = false

    private var op: RetryOperation? { model.retries[conversationId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let op, !op.isFinished {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(op.message ?? op.state).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(sending ? "Retrying…" : "Retry") {
                    sending = true
                    Task {
                        await model.retry(conversationId: conversationId)
                        sending = false
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(sending)
                if let op, op.isFinished { Text(op.message ?? op.state).font(.caption).foregroundStyle(op.state == "done" ? .green : .orange) }
            }
            if let msg = model.retryMessages[conversationId] { Text(msg).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// The last seven days on the server: conversation time per day, and totals.
struct WeekSection: View {
    let model: AppModel
    @State private var stats: ServerStats?

    var body: some View {
        Group {
            if let stats {
                Section {
                    Chart(stats.days) { day in
                        BarMark(x: .value("Day", Self.weekday(day.date)), y: .value("Minutes", day.conversationS / 60))
                            .foregroundStyle(.tint)
                            .accessibilityLabel(Self.weekday(day.date))
                            .accessibilityValue("\(Fmt.duration(day.conversationS) ?? "none"), \(day.conversations) conversations")
                    }
                    .chartYAxisLabel("minutes")
                    .frame(height: 140)
                    HStack {
                        Tile(value: "\(stats.totals.conversations)", label: "conversations")
                        Tile(value: Fmt.duration(stats.totals.conversationS) ?? "0 min", label: "talking")
                        Tile(value: "\(stats.totals.people)", label: stats.totals.people == 1 ? "person" : "people")
                    }
                } header: {
                    Text("Past 7 days")
                } footer: {
                    Text("Kept conversations only, start to end (\(Fmt.duration(stats.totals.speechS) ?? "no") of detected speech). People counts those you've named.")
                }
            }
        }
        .task(id: model.serverStatusAt) { if let s = await model.weekStats() { stats = s } }
    }

    static func weekday(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    struct Tile: View {
        let value: String
        let label: String
        var body: some View {
            VStack(spacing: 2) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}
