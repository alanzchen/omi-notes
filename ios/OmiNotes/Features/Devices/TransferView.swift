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

    /// Simulator screenshots only (debug builds): `-OmiNotesDebugTransferExpanded YES` opens the folds.
    static var debugExpanded: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "OmiNotesDebugTransferExpanded")
        #else
        return false
        #endif
    }

    static var synthetic: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "OmiNotesDebugTransferState") != nil
        #else
        return false
        #endif
    }

    /// The screen's one status line and the short line under it.
    static func hero(_ t: TransferSummary) -> (title: String, line: String?, symbol: String, attention: Bool) {
        let p = t.phone
        let left = p.queuedFiles > 0 ? "\(p.queuedFiles.formatted()) left" : nil
        let eta = t.phoneTimeLeft.map { "~" + approximate($0) }
        switch p.state {
        case .sending: return ("Uploading", [left, eta].compactMap { $0 }.joined(separator: " · "), "arrow.up.circle.fill", false)
        case .waiting: return ("Waiting to upload", left, "clock", false)
        case .retrying: return ("Retrying soon", [plural(p.retryingFiles, "file", "files") + " failed", left].compactMap { $0 }.joined(separator: " · "), "arrow.clockwise", true)
        case .offline(let why): return ("Can't reach the server", [why, left].compactMap { $0 }.joined(separator: " · "), "wifi.exclamationmark", true)
        case .paused(let why): return ("Uploads paused", why, "pause.circle", true)
        case .preparing(let n): return ("Preparing Watch audio", plural(n, "part", "parts"), "gearshape", false)
        case .keptAside(let n): return ("Kept aside", plural(n, "file", "files") + " not uploaded", "tray.full", true)
        case .queueUnreadable: return ("Queue unreadable", nil, "questionmark.folder", true)
        case .allSent:
            if t.everythingSent { return ("All sent", "Everything queued reached the server", "checkmark.circle", false) }
            return ("iPhone sent everything", t.watch.reportFresh ? "The Watch still has audio to send" : "Waiting for a Watch report",
                    "checkmark.circle", false)
        case .notConfigured: return ("No server connected", nil, "server.rack", true)
        case .unknown: return ("Not measured right now", left, "questionmark.circle", false)
        }
    }

    /// "13 h", "25 min", "< 1 min": a round figure for an estimate.
    static func approximate(_ seconds: Double) -> String {
        if seconds < 60 { return "< 1 min" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        if seconds < 48 * 3600 { return "\(Int((seconds / 3600).rounded())) h" }
        return "\(Int((seconds / 86_400).rounded())) days"
    }

    static let explanations = [
        "Watch → iPhone counts parts this iPhone has stored safely, of those plus the parts the Watch last reported. iOS doesn't report a part's progress while it travels, so this bar moves when the Watch reports (every few minutes while recording) and when a part arrives.",
        "iPhone → Server counts audio your server confirmed since the app was opened, of that plus what is still queued here. Speed comes from the uploads' own progress reports while this screen is open. Time left is the queue at the current speed; recording continues and the speed changes, so it is a rough guide.",
        "In the background iOS decides when uploads run, so nothing here is live then. Handed to iOS are uploads iOS may still be waiting to run. Each file is confirmed once, when your server says it stored it; files stay on this iPhone until then.",
        "Audio on the server isn't a note yet: notes appear after the server has transcribed and summarized it.",
    ]
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
            let hero = TransferText.hero(t)
            Card {
                Button(action: open) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pendant.iconForeground)
                            .frame(width: 30, height: 30).background(Pendant.iconBackground, in: .rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transfers").font(.headline)
                            Text([hero.title, hero.line].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                                .foregroundStyle(hero.attention ? Pendant.warnForeground : Pendant.secondary).lineLimit(1).minimumScaleFactor(0.8)
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

/// One status line, one bar per hop, then the counters and explanations folded away. Live only
/// while open; every number comes from its own source (the Watch's report, this iPhone's uploads,
/// the server's last status).
struct TransferDetailView: View {
    let model: AppModel
    let watchInstalled: Bool?
    @AppStorage(SyncActivityCoordinator.optOutKey) private var lockScreenOff = false
    @State private var showDetails = TransferText.debugExpanded
    @State private var showHow = TransferText.debugExpanded

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let t = TransferText.summary(model, watchInstalled: watchInstalled, now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if TransferText.synthetic {
                        Text("SYNTHETIC PREVIEW · DEBUG").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(Pendant.synthetic).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Pendant.syntheticBackground, in: .rect(cornerRadius: 6)).frame(maxWidth: .infinity)
                    }
                    hero(t)
                    if t.watch.inUse != false { watchHop(t, now: context.date) }
                    phoneHop(t)
                    serverLine(t.server, summary: t)
                    fold("Details", isOn: $showDetails) { details(t, now: context.date) }
                    fold("How this works", isOn: $showHow) { explanations }
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

    // MARK: status

    private func hero(_ t: TransferSummary) -> some View {
        let h = TransferText.hero(t)
        return Card {
            VStack(alignment: .leading, spacing: 4) {
                Label(h.title, systemImage: h.symbol).font(.title3.weight(.semibold))
                    .foregroundStyle(h.attention ? Pendant.warnForeground : Pendant.ink).lineLimit(1).minimumScaleFactor(0.8)
                if let line = h.line {
                    Text(line).font(.subheadline.monospacedDigit()).foregroundStyle(Pendant.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        }
    }

    private func hop(_ title: String, symbol: String, fraction: Double?, line: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let fraction { Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.subheadline.monospacedDigit()).foregroundStyle(Pendant.secondary) }
                }
                bar(fraction)
                Text(line).font(.footnote.monospacedDigit()).foregroundStyle(Pendant.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
    }

    /// A plain track; empty (no fill) when the fraction isn't known.
    private func bar(_ fraction: Double?) -> some View {
        Capsule().fill(Pendant.track).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(Pendant.ink).frame(width: max(fraction.map { $0 > 0 ? 6 : 0 } ?? 0, g.size.width * min(max(fraction ?? 0, 0), 1)))
                }
            }
            .accessibilityHidden(true)
    }

    private func watchHop(_ t: TransferSummary, now: Date) -> some View {
        hop("Watch → iPhone", symbol: "applewatch", fraction: t.watchFraction, line: t.watchLine(now: now))
    }

    private func phoneHop(_ t: TransferSummary) -> some View {
        let p = t.phone
        var parts: [String] = []
        if p.since != nil, p.deliveredAudioBytes > 0 {
            parts.append("\(Fmt.bytes(p.deliveredAudioBytes)) of \(Fmt.bytes(p.deliveredAudioBytes + p.queuedBytes))")
        } else if p.queuedBytes > 0 {
            parts.append("\(Fmt.bytes(p.queuedBytes)) queued")
        }
        if let rate = p.rate { parts.append(TransferSummary.rateText(rate)) }
        let line = parts.isEmpty ? (p.state == .allSent ? "Nothing queued" : "Not measured right now") : parts.joined(separator: " · ")
        return hop("iPhone → Server", symbol: "arrow.up", fraction: t.phoneFraction, line: line)
    }

    private func serverLine(_ s: TransferSummary.Server, summary: TransferSummary) -> some View {
        var text = "Server"
        if s.reachable == false { text += " · not reachable" }
        if let work = summary.serverWork {
            text += work.left == 0 ? " · nothing to process" : " · \(work.atLeast ? "at least " : "")\(work.left.formatted()) to process"
        }
        if let at = s.checkedAt { text += " · checked \(Fmt.relative(at))" }
        return Text(text).font(.footnote).foregroundStyle(Pendant.secondary).lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 4)
    }

    // MARK: folded

    private func fold(_ title: String, isOn: Binding<Bool>, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { isOn.wrappedValue.toggle() } } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Pendant.chevron)
                        .rotationEffect(.degrees(isOn.wrappedValue ? 90 : 0))
                }
                .padding(.horizontal, 4).padding(.top, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOn.wrappedValue ? "Expanded" : "Collapsed")
            if isOn.wrappedValue { content() }
        }
    }

    /// One line per fact: the label on the left, a short value on the right, never wrapped.
    private func row(_ title: String, _ value: String?, attention: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Pendant.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value ?? "Unknown").monospacedDigit().lineLimit(1).layoutPriority(1)
                .foregroundStyle(attention ? Pendant.warnForeground : value == nil ? Pendant.secondary : Pendant.ink)
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func details(_ t: TransferSummary, now: Date) -> some View {
        let p = t.phone, w = t.watch, s = t.server
        let counting = p.since != nil
        Card {
            VStack(spacing: 0) {
                row("Speed", p.rate.map(TransferSummary.rateText) ?? (counting ? "None" : nil))
                row("Queued files", p.queuedFiles.formatted())
                row("Queued size", Fmt.bytes(p.queuedBytes))
                if p.queuedAudioFiles > 0 { row("Queued audio", TransferText.duration(p.queuedAudioSeconds)) }
                if p.queuedAudioUnknown > 0 { row("Audio of unknown length", TransferText.plural(p.queuedAudioUnknown, "file", "files")) }
                row("Handed to iOS", counting ? TransferText.plural(p.inFlightUploads, "upload", "uploads") : nil)
                if counting, p.inFlightTotal > 0 { row("In those uploads", "\(Fmt.bytes(p.inFlightSent)) of \(Fmt.bytes(p.inFlightTotal))") }
                row(p.since.map { "Sent since \($0.formatted(date: .omitted, time: .shortened))" } ?? "Sent", counting ? Fmt.bytes(p.networkBytes) : nil)
                row("Confirmed audio", counting ? "\(p.deliveredAudioFiles.formatted()) · \(Fmt.bytes(p.deliveredAudioBytes))" : nil)
                if p.deliveredOtherFiles > 0 { row("Confirmed other", p.deliveredOtherFiles.formatted()) }
                if p.retryingAttempts > 0 { row("Failed, will retry", p.retryingAttempts.formatted(), attention: true) }
                if p.heldAttempts > 0 { row("Stopped attempts", p.heldAttempts.formatted(), attention: true) }
                if p.keptAside > 0 { row("Kept aside", TransferText.plural(p.keptAside, "file", "files"), attention: true) }
            }
            .padding(.vertical, 4)
        }
        if w.inUse == true {
            Card {
                VStack(spacing: 0) {
                    row("Watch report", w.reportAt.map { (w.reportFresh ? "" : "Old · ") + Fmt.relative($0) })
                    if let seconds = w.waitingSeconds, w.reportAt != nil { row("Audio on the Watch", TransferText.duration(Double(seconds))) }
                    if w.recheckParts > 0, w.reportAt != nil { row("Of it, re-checking", TransferText.plural(w.recheckParts, "older part", "older parts")) }
                    row("Received from Watch", TransferText.plural(w.receivedOnPhone, "part", "parts"))
                    row("Last received", w.lastReceivedAt.map { Fmt.relative($0) } ?? "Not since launch")
                    if w.converting > 0 { row("Preparing", TransferText.plural(w.converting, "part", "parts")) }
                    row("Watch audio queued", TransferText.plural(w.waitingForServer, "file", "files"))
                }
                .padding(.vertical, 4)
            }
        }
        Card {
            VStack(spacing: 0) {
                row("Server checked", s.checkedAt.map { Fmt.relative($0) })
                row("Audio to process", s.chunksPending.map { $0.formatted() })
                row("Conversations to process", s.conversationsPending.map { $0.formatted() })
                row("Last note", s.lastNoteAt.map { Fmt.relative($0) })
            }
            .padding(.vertical, 4)
        }
        if SyncActivityCoordinator.available {
            Card {
                Toggle("Show sync on the Lock Screen", isOn: Binding(get: { !lockScreenOff }, set: { lockScreenOff = !$0 }))
                    .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private var explanations: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(TransferText.explanations, id: \.self) { text in
                Text(text).font(.footnote).foregroundStyle(Pendant.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
