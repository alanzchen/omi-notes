import OmiBLE
import OmiProtocol
import OmiWatchKit
import SwiftUI

/// The Apple Watch's page: its state as far as it is known, where its audio is (on the Watch, on
/// this iPhone, uploading), how to record all day and what to expect. Recording is started and
/// stopped on the Watch only.
struct WatchDetailView: View {
    let model: AppModel
    /// The server's recording summaries (nil: not loaded, unsupported or unreachable).
    @State private var performance: WatchPerformance?

    /// Where the Watch's audio is; each place separately (they are different queues).
    struct Flow {
        var report: WatchReport?
        var receivedTotal = 0
        var lastReceivedAt: Date?
        var preparing = 0
        var waitingUpload = 0
        var othersWaiting = 0
        var lastUploadedAt: Date?
    }

    private func current(_ now: Date) -> (WatchSummary, Flow) {
        let (summary, report, _) = DevicesView.watch(model, now)
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugWatchState"), let f = WatchSummary.debugFixture(name, now: now) {
            let some = f.lastReceivedAt != nil
            return (summary, Flow(report: f.report, receivedTotal: some ? 214 : 0, lastReceivedAt: f.lastReceivedAt, preparing: 0,
                                  waitingUpload: some ? 3 : 0, othersWaiting: name == "stale" ? 1_960 : 0,
                                  lastUploadedAt: some ? now.addingTimeInterval(-4 * 60) : nil))
        }
        #endif
        let s = model.snapshot
        return (summary, Flow(report: report, receivedTotal: s.watchReceived, lastReceivedAt: s.watchLastReceivedAt, preparing: s.watchPending,
                              waitingUpload: s.watchWaitingUpload, othersWaiting: max(0, s.outbox.pendingChunks - s.watchWaitingUpload),
                              lastUploadedAt: s.watchLastUploadedAt))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let (summary, flow) = current(context.date)
            ScrollView {
                VStack(spacing: 0) {
                    MiniWatch(recording: summary.tone == .recording, scale: 2).frame(width: 112, height: 112).padding(.top, 12)
                        .accessibilityHidden(true)
                    VStack(spacing: 3) {
                        Text("Apple Watch").font(.title2.weight(.bold)).tracking(-0.5)
                        Text(summary.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(summary.tone == .attention ? Pendant.warnForeground : Pendant.ink)
                        if let detail = summary.detail {
                            Text(detail).font(.subheadline).foregroundStyle(Pendant.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 14)
                    .accessibilityElement(children: .combine)

                    if summary.configured {
                        heading("Where its audio is")
                        Card { places(flow, context.date) }
                        note("Your server makes a note about two minutes after a conversation ends, once its audio has uploaded.")
                    }

                    if summary.configured, let performance {
                        heading("Battery while recording")
                        Card {
                            if performance.sessions.isEmpty {
                                place("battery.75percent", "No recordings measured yet", "Recordings made with this version appear here.")
                            }
                            ForEach(Array(performance.sessions.prefix(3).enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Divider().padding(.leading, 50) }
                                place("battery.75percent", Self.when(session), Self.battery(session))
                            }
                        }
                        note("The whole Watch's battery, other apps included. Charging time and gaps are left out.")
                    }

                    if summary.configured {
                        heading("Alerts")
                        Card { WatchAlertToggle(model: model) }
                        note("If a call, an error or the app closing stops a Watch recording you didn't stop. It reaches this iPhone only when the Watch can send it, so it may be late.")
                    }

                    heading("Record all day")
                    Card {
                        step(1, "Install", "In the iPhone's Watch app, find Omi Notes under Available Apps and tap Install. It may already be there.")
                        Divider().padding(.leading, 50)
                        step(2, "Start on the Watch", "Open Omi Notes on the Watch and tap the red microphone. Allow microphone access the first time.")
                        Divider().padding(.leading, 50)
                        step(3, "Wear it", "It keeps recording with your wrist down or the screen dark, in one-minute parts, until you tap Stop.")
                        Divider().padding(.leading, 50)
                        step(4, "Keep the iPhone near", "Parts come to this iPhone when it's nearby and upload with the pendant's.")
                    }

                    heading("Good to know")
                    Card {
                        fact("pause.circle", "A call or Siri pauses recording. If it doesn't continue by itself, the Watch shows Paused: tap Resume.")
                        Divider().padding(.leading, 50)
                        fact("arrow.clockwise", "It doesn't start again by itself after the Watch restarts, its battery runs out, or the app is closed. Open it and tap the microphone; what was recorded is kept.")
                        Divider().padding(.leading, 50)
                        fact("battery.75percent", "Recording all day uses the Watch's battery. Charge it overnight.")
                        Divider().padding(.leading, 50)
                        fact("externaldrive", "Away from this iPhone, the Watch keeps about 40 hours of audio, then pauses until it can send.")
                        Divider().padding(.leading, 50)
                        fact("rectangle.on.rectangle", "If the pendant recorded the same conversation, your server compares the two and may keep the Watch audio as an alternate recording instead of a second note.")
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Pendant.background.ignoresSafeArea())
            .foregroundStyle(Pendant.ink)
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        // again once the server's status (and so its features) is known
        .task(id: model.serverStatus?.supportsWatchPerformance) {
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugWatchState"), WatchSummary.debugFixture(name) != nil {
                performance = Self.debugPerformance
                return
            }
            #endif
            performance = await model.watchPerformance()
        }
    }

    static func when(_ s: WatchPerformance.Session) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let start = s.startedAt.flatMap(iso.date(from:)) else { return "A recording" }
        let end = s.lastAt.flatMap(iso.date(from:))
        let day = Calendar.current.isDateInToday(start) ? "Today" : start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let range = "\(start.formatted(date: .omitted, time: .shortened))–\(end?.formatted(date: .omitted, time: .shortened) ?? "?")"
        return "\(day), \(range)\(s.complete ? "" : " · not finished yet")"
    }

    static func battery(_ s: WatchPerformance.Session) -> String {
        let span = Duration.seconds(s.measuredS).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        var parts: [String] = []
        if let a = s.batteryStart, let b = s.batteryEnd { parts.append("\(Int((a * 100).rounded()))% → \(Int((b * 100).rounded()))%") }
        switch (s.rateQuality, s.ratePerHour) {
        case ("ok", let r?): parts.append(String(format: "%.1f points an hour over %@ on battery", r, span))
        case ("coarse", _): parts.append("too small a change over \(span) to give a rate")
        default: parts.append("not enough time on battery to estimate (\(span))")
        }
        if s.gaps > 0 { parts.append("\(s.gaps) gap\(s.gaps == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    #if DEBUG
    /// Simulator screenshots only (with `-OmiNotesDebugWatchState`): SYNTHETIC summaries.
    static var debugPerformance: WatchPerformance {
        let json = #"{"sessions":[{"recording_id":"a","started_at":"2026-10-15T14:02:00.000Z","last_at":"2026-10-15T16:10:00.000Z","complete":false,"battery_start":0.84,"battery_end":0.71,"measured_s":7680,"rate_pp_per_hour":6.1,"rate_quality":"ok","gaps":0,"charging_s":0,"builds":["0.1.0 (24)"]},{"recording_id":"b","started_at":"2026-10-14T13:00:00.000Z","last_at":"2026-10-14T13:25:00.000Z","complete":true,"battery_start":0.9,"battery_end":0.89,"measured_s":1500,"rate_pp_per_hour":null,"rate_quality":"insufficient","gaps":1,"charging_s":0,"builds":["0.1.0 (24)"]}]}"#
        return try! JSONDecoder().decode(WatchPerformance.self, from: Data(json.utf8))
    }
    #endif

    @ViewBuilder private func places(_ f: Flow, _ now: Date) -> some View {
        place("applewatch", "On the Watch", f.report.map { r in
            // the recorded length (from the Watch's own parts), never a count of parts
            let parts = r.waitingParts == 0 ? "Everything sent to this iPhone"
                : (r.waitingSeconds ?? 0) > 0 ? "\(WaitingAudio.text(r.waitingSeconds!).capitalizedFirst) of audio not on this iPhone yet"
                : "Some audio not on this iPhone yet"
            // waiting, and nothing has arrived for a while: what helps
            let stuck = r.waitingParts > 0 && (f.lastReceivedAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? true)
            return "\(parts) · reported \(SystemHealth.relative(r.at, now))" + (stuck ? ". They move when both are nearby with Omi Notes open." : "")
        } ?? "Unknown until the Watch app reports")
        Divider().padding(.leading, 50)
        place("iphone", "On this iPhone", {
            guard let at = f.lastReceivedAt else { return "Nothing received yet" }
            var s = "Last audio received \(SystemHealth.relative(at, now))"
            if f.preparing > 0 { s += " · some being prepared for upload" }
            return s
        }())
        Divider().padding(.leading, 50)
        place("arrow.up", "Upload to your server", {
            if f.waitingUpload > 0 {
                return f.othersWaiting > 50 ? "Watch audio waiting, in turn after other recordings on this iPhone" : "Watch audio waiting to upload"
            }
            if let at = f.lastUploadedAt { return "Nothing waiting · last uploaded \(SystemHealth.relative(at, now))" }
            return f.receivedTotal > 0 ? "Nothing waiting" : "Nothing to upload yet"
        }())
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Pendant.secondary).textCase(.uppercase).tracking(0.4)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 22).padding(.bottom, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Pendant.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 6)
    }

    private func place(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pendant.iconForeground)
                .frame(width: 26, height: 26).background(Pendant.iconBackground, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(Pendant.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.footnote.weight(.bold)).foregroundStyle(Pendant.iconForeground)
                .frame(width: 26, height: 26).background(Pendant.iconBackground, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(Pendant.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Pendant.iconForeground).frame(width: 26, height: 22)
            Text(text).font(.footnote).foregroundStyle(Pendant.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

/// The same opt-in as Settings ▸ Alerts, here where Watch recording is explained.
private struct WatchAlertToggle: View {
    let model: AppModel
    @State private var on = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Alert me if Watch recording stops", isOn: Binding(get: { on }, set: { value in
                Task {
                    if value, !(await LocalAlerts.requestPermission()) {
                        message = "Notifications are off for Omi Notes in the iPhone Settings app."
                        on = false
                        return
                    }
                    model.problemAlerts.enabled = value
                    on = value
                    message = nil
                }
            }))
            .font(.subheadline.weight(.semibold))
            Text("The same switch as Settings › Alerts: it also covers full storage and uploads that stop.")
                .font(.footnote).foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote).foregroundStyle(Pendant.warnForeground) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .onAppear { on = model.problemAlerts.enabled }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
