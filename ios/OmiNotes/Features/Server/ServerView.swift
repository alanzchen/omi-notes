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
                    // the problems themselves are listed right below: the line doesn't repeat or point to them
                    let server = Self.headline(model.health(now: context.date).steps.first { $0.area == .server }!, listed: !model.issues.isEmpty)
                    StepRow(step: server, onFix: onFix, hiding: .openServer)  // already on the Server page
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

    /// The Server page's own status line: with the problems listed below it, no detail pointing to them.
    static func headline(_ step: SystemHealth.Step, listed: Bool) -> SystemHealth.Step {
        var step = step
        if listed { step.detail = nil }
        return step
    }

    @ViewBuilder private var issuesSection: some View {
        if !model.issues.isEmpty {
            Section("Needs attention") {
                ForEach(model.issues) { issue in IssueRow(model: model, issue: issue) }
            }
        }
    }

    @ViewBuilder private var activitySection: some View {
        if let a = status?.activity {
            Section {
                if let running = a.running?.first {
                    Label("\(running.stage == "summarizing" ? "Writing the summary of" : "Transcribing") a conversation"
                          + (startedPhrase(running.startedAt).map { " that started \($0)" } ?? ""),
                          systemImage: "gearshape.2")
                }
                if let waiting = a.waiting, waiting > 0 {
                    LabeledContent("Conversations waiting", value: "\(waiting)")
                }
                if let backing = a.backingOff, backing > 0 {
                    LabeledContent("Waiting to try again") { Text("\(backing)").foregroundStyle(.orange) }
                }
                ServiceCallsRow(title: "Transcription", calls: a.stt)
                if status?.llm?.provider != "none" { ServiceCallsRow(title: "Summaries", calls: a.llm) }
                DisclosureGroup("Details") {
                    if let oldest = a.oldestWaitingEndedAt.flatMap(ISO8601UTC.parse), (a.waiting ?? 0) > 0 {
                        LabeledContent("Oldest waiting ended", value: Fmt.relative(oldest))
                    }
                    ServiceCallsDetail(title: "Transcription", calls: a.stt)
                    if status?.llm?.provider != "none" { ServiceCallsDetail(title: "Summaries", calls: a.llm) }
                    Text("Conversations waiting are recorded but not yet transcribed and summarized; the server works through them oldest first. A service answering means the request worked; the note still has to be written. Times reset when the server rebuilds its index.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            } header: {
                Text("Now")
            }
        }
    }

    /// "3:04 PM", "yesterday 3:04 PM" or "Thursday, Oct 15 3:04 PM" (mid-sentence), nil without a time.
    private func startedPhrase(_ iso: String?) -> String? {
        guard let d = iso.flatMap(ISO8601UTC.parse) else { return nil }
        if Calendar.current.isDateInToday(d) { return Fmt.time(d) }
        return "\(Calendar.current.isDateInYesterday(d) ? "yesterday" : Fmt.day(d)) \(Fmt.time(d))"
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
        let stt = st.transcriptionLabel, llm = st.summariesLabel
        return Section {
            ServiceRow(title: "Transcription", label: stt)
            ServiceRow(title: "Summaries", label: llm)
            if let dir = st.notesDir { LabeledContent("Notes folder", value: dir).font(.footnote).lineLimit(1).truncationMode(.head) }
            LabeledContent("Server version", value: st.serverVersion ?? "—")
            if let started = st.serverStartedAt.flatMap(ISO8601UTC.parse) {
                LabeledContent("Running since", value: started.formatted(date: .abbreviated, time: .shortened))
            }
            if !stt.details.isEmpty || !llm.details.isEmpty {
                DisclosureGroup("Details") {
                    ServiceDetails(title: "Transcription", details: stt.details)
                    ServiceDetails(title: "Summaries", details: llm.details)
                }
                .font(.subheadline)
            }
        } header: {
            Text("Configuration")
        } footer: {
            Text("Set on the server, which decides where your audio and transcripts go. A green dot means configured or answering, not that a transcript worked.")
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
}

/// One server problem: what happened, what to do, and the conversation it concerns.
struct IssueRow: View {
    let model: AppModel
    let issue: ServerIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(issue.message).foregroundStyle(.primary)
            } icon: {
                Image(systemName: issue.needsAction ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark").foregroundStyle(.orange)
            }
            .font(.subheadline)
            if issue.detail != nil || issue.phoneStep != nil {
                DisclosureGroup("What to do") {
                    if let detail = issue.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if let step = issue.phoneStep { Text(step).font(.caption).foregroundStyle(.secondary) }
                    Text("The server keeps the audio either way.").font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if issue.code == "conversation_failed", let id = issue.conversationId {
                if model.canKeep, issue.canKeepFromPhone {
                    RetryControl(model: model, conversationId: id, action: .keep)
                } else if model.canRetry, issue.canRetryFromPhone {
                    RetryControl(model: model, conversationId: id)
                }
                if model.canDismiss, issue.canDismissFromPhone { DismissControl(model: model, conversationId: id) }
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

    /// One line: how the most recent request went (an older failure is history, under Details).
    var body: some View {
        LabeledContent(title) {
            Text(summary).lineLimit(1).foregroundStyle(calls?.lastFailed == true ? .orange : .secondary)
        }
    }

    private var summary: String {
        guard let calls else { return "No requests yet" }
        if calls.lastFailed, let failed = calls.lastErrorAt.flatMap(ISO8601UTC.parse) { return "Failed \(Fmt.relative(failed))" }
        if let ok = calls.lastOkAt.flatMap(ISO8601UTC.parse) { return "Answered \(Fmt.relative(ok))" }
        return "No requests yet"
    }
}

/// A service's last success and last failure, for Details.
struct ServiceCallsDetail: View {
    let title: String
    let calls: ServerStatus.Activity.ProviderCalls?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let calls {
                if let ok = calls.lastOkAt.flatMap(ISO8601UTC.parse) {
                    Text("Last answered \(Fmt.relative(ok))").font(.caption).foregroundStyle(.secondary)
                }
                if let failed = calls.lastErrorAt.flatMap(ISO8601UTC.parse) {
                    Text("Last failure \(Fmt.relative(failed))\(calls.lastErrorKind.map { " (\($0))" } ?? "")")
                        .font(.caption).foregroundStyle(calls.lastFailed ? .orange : .secondary)
                }
            } else {
                Text("No requests since the server started keeping track").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Retry a failed conversation (or keep a no-speaker result as it is), and follow the request
/// until the server says how it ended.
struct RetryControl: View {
    enum Action { case retry, keep }

    let model: AppModel
    let conversationId: String
    var action: Action = .retry
    @State private var sending = false
    @State private var confirming = false

    private var op: RetryOperation? { model.retries[conversationId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let op, !op.isFinished {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(op.displayMessage).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(title) {
                    if action == .keep { confirming = true } else { send() }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(sending)
                if let op, op.isFinished { Text(op.displayMessage).font(.caption).foregroundStyle(op.state == "done" ? .green : .orange) }
            }
            if let msg = model.retryMessages[conversationId] { Text(msg).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Keep as a transcript?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Keep as transcript") { send() }
        } message: {
            Text("The automated text becomes a note with the speaker unknown, and this leaves the server's list of problems. Nothing is deleted.")
        }
    }

    private var title: String {
        switch action {
        case .retry: return sending ? "Retrying…" : "Retry"
        case .keep: return sending ? "Keeping…" : "Keep as transcript"
        }
    }

    private func send() {
        sending = true
        Task {
            if action == .keep { await model.keep(conversationId: conversationId) } else { await model.retry(conversationId: conversationId) }
            sending = false
        }
    }
}

/// Sets a failed conversation aside: it leaves the list of problems; the audio stays on the server
/// and the conversation can still be retried from its page.
struct DismissControl: View {
    let model: AppModel
    let conversationId: String
    @State private var confirming = false
    @State private var sending = false

    var body: some View {
        Button(sending ? "Dismissing…" : "Dismiss", role: .destructive) { confirming = true }
            .buttonStyle(.borderless).controlSize(.small).disabled(sending)
            .confirmationDialog("Dismiss this problem?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Dismiss") {
                    sending = true
                    Task {
                        await model.dismiss(conversationId: conversationId)
                        sending = false
                    }
                }
            } message: {
                Text("It leaves the server's list of problems. Nothing is deleted: the audio stays on your server, and you can still retry it from the conversation.")
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
                            .accessibilityValue("\(Fmt.duration(day.conversationS) ?? "none"), \(day.conversations) conversation\(day.conversations == 1 ? "" : "s")")
                    }
                    .chartYAxisLabel("minutes")
                    .frame(height: 140)
                    HStack {
                        Tile(value: "\(stats.totals.conversations)", label: stats.totals.conversations == 1 ? "conversation" : "conversations")
                        Tile(value: Fmt.duration(stats.totals.conversationS) ?? "0 min", label: "conversation time")
                        Tile(value: "\(stats.totals.people)", label: stats.totals.people == 1 ? "person" : "people")
                    }
                } header: {
                    Text("Past 7 days")
                } footer: {
                    Text("Kept conversations only, start to end (\(Fmt.duration(stats.totals.speechS) ?? "no") of detected speech). People counts those you've named.")
                }
            }
        }
        // A new server or vault starts empty; a failed fetch shows nothing rather than older numbers.
        .task(id: "\(model.serverIdentity)|\(model.serverStatusAt?.timeIntervalSince1970 ?? 0)") {
            let identity = model.serverIdentity
            let fresh = await model.weekStats()
            if identity == model.serverIdentity { stats = fresh }
        }
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
