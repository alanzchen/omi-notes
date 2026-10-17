import OmiBLE
import SwiftUI

/// Words for the transfer screens (one place, so the card and the page say the same thing).
enum TransferText {
    /// "45 s", "3 min 50 s", "1 h 2 min".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// The live summary (or, debug builds, the `-OmiNotesDebugTransferState` synthetic fixture).
    @MainActor static func summary(_ model: AppModel, watchInstalled: Bool?, now: Date) -> TransferSummary {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugTransferState"),
           let fixture = TransferSummary.debugFixture(name, now: now) { return fixture }
        #endif
        return model.transfers(watchInstalled: watchInstalled, now: now)
    }

    static var synthetic: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "OmiNotesDebugTransferState") != nil
        #else
        return false
        #endif
    }

    static func phoneState(_ p: TransferSummary.Phone) -> (title: String, symbol: String, attention: Bool) {
        switch p.state {
        case .sending: return ("Sending · \(TransferSummary.rateText(p.rate ?? 0))", "arrow.up.circle.fill", false)
        case .waiting: return (p.queuedFiles > 0 ? "\(plural(p.queuedFiles, "file", "files")) waiting to send" : "Waiting to send", "clock", false)
        case .retrying: return ("\(plural(p.retryingFiles, "file", "files")) will be tried again automatically", "arrow.clockwise", true)
        case .offline(let why): return ("Can't reach the server (\(why))", "wifi.exclamationmark", true)
        case .paused(let why): return ("Uploads paused: \(why)", "pause.circle", true)
        case .preparing(let n): return ("Preparing \(plural(n, "Watch part", "Watch parts")) for upload", "gearshape", false)
        case .keptAside(let n): return ("\(plural(n, "file", "files")) kept aside on this iPhone (not uploaded)", "tray.full", true)
        case .queueUnreadable: return ("Couldn't read the upload queue", "questionmark.folder", true)
        case .allSent: return ("Everything queued has reached the server", "checkmark.circle", false)
        case .notConfigured: return ("No server connected", "server.rack", true)
        case .unknown: return ("Not measured right now", "questionmark.circle", false)
        }
    }

    static func watchLine(_ w: TransferSummary.Watch, now: Date) -> String? {
        guard w.inUse != false else { return nil }
        guard w.inUse == true else { return "Checking for Apple Watch" }
        guard let at = w.reportAt else { return "No report from the Watch yet" }
        let when = w.reportFresh ? "reported \(Fmt.relative(at))" : "last report \(Fmt.relative(at))"
        if let seconds = w.waitingSeconds, seconds > 0 { return "\(duration(Double(seconds))) on the Watch · \(when)" }
        if let parts = w.waitingParts, parts > 0 { return "\(plural(parts, "part", "parts")) on the Watch · \(when)" }
        return "Nothing waiting on the Watch · \(when)"
    }
}

/// Devices: one quiet card with where audio is right now; tap for the details.
struct TransferCardView: View {
    let model: AppModel
    let watchInstalled: Bool?
    var open: () -> Void

    var body: some View {
        // re-evaluated every second: a rate stops showing as soon as bytes stop
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let t = TransferText.summary(model, watchInstalled: watchInstalled, now: context.date)
            let phone = TransferText.phoneState(t.phone)
            Card {
                Button(action: open) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pendant.iconForeground)
                            .frame(width: 30, height: 30).background(Pendant.iconBackground, in: .rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transfers").font(.headline)
                            Text("To server: \(phone.title)").font(.subheadline)
                                .foregroundStyle(phone.attention ? Pendant.warnForeground : Pendant.ink).fixedSize(horizontal: false, vertical: true)
                            if let watch = TransferText.watchLine(t.watch, now: context.date) {
                                Text("From Watch: \(watch)").font(.footnote).foregroundStyle(Pendant.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Pendant.chevron)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens transfer details")
            }
        }
    }
}

/// Where audio is, stage by stage, with each stage's own source and time. Live only while open.
struct TransferDetailView: View {
    let model: AppModel
    let watchInstalled: Bool?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let t = TransferText.summary(model, watchInstalled: watchInstalled, now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if TransferText.synthetic {
                        Text("SYNTHETIC PREVIEW · DEBUG").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(Pendant.synthetic).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Pendant.syntheticBackground, in: .rect(cornerRadius: 6)).frame(maxWidth: .infinity)
                    }
                    Text("Live while this screen is open. In the background, iOS decides when uploads run, so nothing here claims to be live then.")
                        .font(.footnote).foregroundStyle(Pendant.secondary).padding(.horizontal, 4)
                    watchSection(t.watch, now: context.date)
                    phoneSection(t.phone)
                    serverSection(t.server)
                    Text("Updated \(context.date.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(Pendant.secondary).padding(.horizontal, 4)
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Pendant.background.ignoresSafeArea())
            .foregroundStyle(Pendant.ink)
        }
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Pendant.secondary).textCase(.uppercase).tracking(0.4)
            .padding(.horizontal, 4).padding(.top, 10)
    }

    private func row(_ title: String, _ value: String?, attention: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            Text(value ?? "Unknown").font(.subheadline).multilineTextAlignment(.trailing)
                .foregroundStyle(attention ? Pendant.warnForeground : value == nil ? Pendant.secondary : Pendant.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Pendant.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Watch → iPhone

    @ViewBuilder private func watchSection(_ w: TransferSummary.Watch, now: Date) -> some View {
        header("Apple Watch → this iPhone")
        if w.inUse == false {
            Card { row("Apple Watch", "Not in use") }
        } else if w.inUse == nil {
            Card { row("Apple Watch", "Checking…") }
            note("This iPhone hasn't heard from WatchConnectivity yet, so whether a Watch is set up isn't known.")
        } else {
            Card {
                row("On the Watch", w.reportAt == nil ? nil : waitingOnWatch(w))
                Divider().padding(.leading, 16)
                row("Watch report", w.reportAt.map { (w.reportFresh ? "" : "Old · ") + Fmt.relative($0) })
                Divider().padding(.leading, 16)
                row("Received by this iPhone", TransferText.plural(w.receivedOnPhone, "part", "parts"))
                Divider().padding(.leading, 16)
                row("Last received", w.lastReceivedAt.map { Fmt.relative($0) } ?? "None since the app started")
                if w.converting > 0 {
                    Divider().padding(.leading, 16)
                    row("Preparing for upload", TransferText.plural(w.converting, "part", "parts"))
                }
                Divider().padding(.leading, 16)
                row("Watch audio waiting for the server", TransferText.plural(w.waitingForServer, "file", "files"))
            }
            note("Received means stored safely on this iPhone, not yet on your server. iOS doesn't tell the iPhone how far along a part from the Watch is, so this step has no live speed; it updates when the Watch reports (every few minutes while recording) and when a part arrives.")
        }
    }

    private func waitingOnWatch(_ w: TransferSummary.Watch) -> String? {
        let parts = w.waitingParts.map { TransferText.plural($0, "part", "parts") }
        let audio = w.waitingSeconds.map { TransferText.duration(Double($0)) }
        if w.waitingParts == 0 { return "Nothing waiting" }
        return [audio, parts].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    // MARK: iPhone → server

    @ViewBuilder private func phoneSection(_ p: TransferSummary.Phone) -> some View {
        let state = TransferText.phoneState(p)
        header("This iPhone → your server")
        Card {
            HStack(spacing: 10) {
                Image(systemName: state.symbol).foregroundStyle(state.attention ? Pendant.warnForeground : Pendant.iconForeground)
                    .accessibilityHidden(true)
                Text(state.title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.attention ? Pendant.warnForeground : Pendant.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().padding(.leading, 16)
            row("Speed now", p.rate.map(TransferSummary.rateText) ?? (p.since == nil ? nil : "No data moving"))
            Divider().padding(.leading, 16)
            row("Handed to iOS", inFlight(p))
            Divider().padding(.leading, 16)
            row("Queued on this iPhone", queued(p))
            Divider().padding(.leading, 16)
            row(p.since.map { "Sent since \($0.formatted(date: .omitted, time: .shortened))" } ?? "Sent", p.since == nil ? nil : Fmt.bytes(p.networkBytes))
            if p.since != nil {
                Text("Counted since the app was last opened.").font(.caption).foregroundStyle(Pendant.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider().padding(.leading, 16)
            row("Confirmed by the server", p.since == nil ? nil : confirmed(p))
            if p.retryingAttempts > 0 {
                Divider().padding(.leading, 16)
                row("Failed attempts", "\(p.retryingAttempts) · tried again automatically", attention: true)
            }
            if p.heldAttempts > 0 {
                Divider().padding(.leading, 16)
                row("Stopped attempts", "\(p.heldAttempts) · file kept on this iPhone, not retried", attention: true)
            }
            if p.keptAside > 0 {
                Divider().padding(.leading, 16)
                row("Kept aside", "\(TransferText.plural(p.keptAside, "file", "files")) · see Server › Diagnostics", attention: true)
            }
        }
        note("Speed and sent bytes come from the uploads' own progress reports while the app is open (sent bytes include retries and small metadata files; an upload that continued in the background counts only from its next report). Handed to iOS are uploads iOS may still be waiting to run. Confirmed counts each file once, when your server says it stored it. Queued audio is summed from each file's recorded length; recording continues, so there is no fixed total or finish time.")
    }

    private func inFlight(_ p: TransferSummary.Phone) -> String? {
        guard p.since != nil else { return nil }
        guard p.inFlightUploads > 0 else { return "None" }
        var text = TransferText.plural(p.inFlightUploads, "upload", "uploads")
        if p.inFlightTotal > 0 {
            let known = p.inFlightUploads - p.inFlightUnknownTotals
            text += " · \(Fmt.bytes(p.inFlightSent)) of \(Fmt.bytes(p.inFlightTotal))"
            if p.inFlightUnknownTotals > 0 { text += " (\(known) of known size)" }
        }
        return text
    }

    private func queued(_ p: TransferSummary.Phone) -> String {
        guard p.queuedFiles > 0 else { return "Nothing" }
        var parts = [TransferText.plural(p.queuedFiles, "file", "files"), Fmt.bytes(p.queuedBytes)]
        if p.queuedAudioFiles > 0 {
            let known = p.queuedAudioFiles - p.queuedAudioUnknown
            if known > 0 { parts.append("\(TransferText.duration(p.queuedAudioSeconds)) of audio") }
            if p.queuedAudioUnknown > 0 { parts.append("\(p.queuedAudioUnknown) of unknown length") }
        }
        return parts.joined(separator: " · ")
    }

    private func confirmed(_ p: TransferSummary.Phone) -> String {
        var text = TransferText.plural(p.deliveredAudioFiles, "audio file", "audio files")
        if p.deliveredAudioFiles > 0 { text += " (\(Fmt.bytes(p.deliveredAudioBytes)))" }
        if p.deliveredOtherFiles > 0 { text += " · \(TransferText.plural(p.deliveredOtherFiles, "other file", "other files"))" }
        return text
    }

    // MARK: server

    @ViewBuilder private func serverSection(_ s: TransferSummary.Server) -> some View {
        header("Your server")
        Card {
            row("Last checked", s.checkedAt.map { Fmt.relative($0) + (s.reachable == false ? " · not reachable" : "") })
            Divider().padding(.leading, 16)
            row("Waiting to be processed", processing(s))
            Divider().padding(.leading, 16)
            row("Last note written", s.lastNoteAt.map { Fmt.relative($0) })
        }
        note("This is what the server said when last checked. Audio reaching the server isn't a finished note yet: notes appear after the server has transcribed and summarized it.")
    }

    private func processing(_ s: TransferSummary.Server) -> String? {
        guard s.chunksPending != nil || s.conversationsPending != nil else { return nil }
        return [s.chunksPending.map { TransferText.plural($0, "audio file", "audio files") },
                s.conversationsPending.map { TransferText.plural($0, "conversation", "conversations") }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
