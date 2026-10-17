import Foundation
import OmiCapture
import OmiProtocol
import OmiWatchKit

/// "Is it working?" in one sentence, expandable into pendant → phone → server → notes.
///
/// Only claims what the app observed: a disconnected pendant is *unknown* (it may be recording to
/// its own storage), an old server answer is *unknown* rather than healthy, and a missing field from
/// an older server means unknown, never zero. Levels are ordered by urgency; the overall level is the
/// most urgent step, so a stale server answer never hides a current phone problem.
public struct SystemHealth: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        /// Nothing is blocked (silence and an empty queue are normal).
        case normal
        /// Uploading, waiting for a conversation to end, transcribing: no one needs to act.
        case working
        /// Never checked, or the last observation is too old to trust.
        case unknown
        /// Held up, but recordings are safe and it recovers on its own.
        case delayed
        /// Someone must do something.
        case needsAction

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Area: String, Sendable, CaseIterable {
        case pendant, watch, phone, server, notes
    }

    /// What the step's button does (the view maps these to navigation).
    public enum Fix: Equatable, Sendable {
        case pairDevice, reconnectDevice, openBluetoothSettings, retryUploads, openServer, openDiagnostics
        case resumeRecording, collectPendantAudio
        /// Devices, to add a pendant or set up the Apple Watch.
        case openDevices
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public var area: Area
        public var level: Level
        public var title: String
        public var detail: String?
        public var fix: Fix?
        public var id: Area { area }
    }

    public var level: Level
    public var headline: String
    public var detail: String?
    public var steps: [Step]

    /// A server answer older than this is shown as unknown.
    public static let staleAfter: TimeInterval = 5 * 60

    /// `issues`: the server's issue list, which tells a no-speaker result the phone can keep apart
    /// from a failure someone must fix.
    public static func evaluate(
        snapshot s: EngineSnapshot, server: ServerReachability, status: ServerStatus?, statusAt: Date?, now: Date,
        issues: [ServerIssue] = [], watchAppInstalled: Bool? = nil
    ) -> SystemHealth {
        let steps = [pendant(s, watchAppInstalled: watchAppInstalled)] + [watch(s, now: now)].compactMap { $0 } + [phone(s, server: server),
                     self.server(server, status: status, statusAt: statusAt, now: now, issues: issues),
                     notes(status, statusAt: statusAt, now: now)]
        let worst = steps.map(\.level).max() ?? .unknown
        let lead = steps.first { $0.level == worst }!
        switch worst {
        case .normal:
            return SystemHealth(level: .normal, headline: "Connected; no reported problems", detail: steps.last?.title, steps: steps)
        case .working:
            return SystemHealth(level: .working, headline: s.connection == .streaming ? "Recording; notes are catching up" : lead.title,
                                detail: lead.title, steps: steps)
        default:
            return SystemHealth(level: worst, headline: lead.title, detail: lead.detail, steps: steps)
        }
    }

    // MARK: Steps

    /// `watchAppInstalled`: Omi Notes is installed on a paired Apple Watch; nil while unknown
    /// (WatchConnectivity not activated yet, or failed), which is not the same as no Watch.
    static func pendant(_ s: EngineSnapshot, watchAppInstalled: Bool? = nil) -> Step {
        func step(_ level: Level, _ title: String, _ detail: String? = nil, _ fix: Fix? = nil) -> Step {
            Step(area: .pendant, level: level, title: title, detail: detail, fix: fix)
        }
        // the app's placeholder before the engine's first snapshot: nothing is known yet
        guard s.ready else { return step(.unknown, "Checking your devices") }
        switch s.connection {
        case .noDevice:
            // the Apple Watch records too: without a pendant, that's a choice, not a problem
            if s.watchReport != nil || s.watchLastReceivedAt != nil {
                return step(.normal, "Using Apple Watch, no pendant", "Its state is in Devices. You can add a pendant there too.")
            }
            if watchAppInstalled == true {
                return step(.normal, "Apple Watch app installed, no pendant", "Start a recording on the Watch; its state appears in Devices.")
            }
            guard watchAppInstalled == false else {
                return step(.unknown, "No pendant paired", "Checking for Apple Watch. Devices sets up either.", .openDevices)
            }
            return step(.needsAction, "No recording device set up", "Pair an Omi pendant, or set up Apple Watch in Devices.", .openDevices)
        case .bluetoothUnavailable(let why):
            return step(.needsAction, "Bluetooth is \(why)", "Turn Bluetooth on and allow Omi Notes to use it.", .openBluetoothSettings)
        case .refused(let why):
            return step(.needsAction, "This pendant can't be used", why, .pairDevice)
        case .paused(let why):
            if s.connection.isUserDisconnect {
                return step(.needsAction, "Pendant disconnected",
                            "You disconnected it. It may keep recording to its own storage; reconnect to collect that audio.", .reconnectDevice)
            }
            return step(.needsAction, "Recording is paused", why, s.storageTripped ? nil : .reconnectDevice)
        case .settingUp:
            return step(.working, "Connecting to the pendant")
        case .waitingForDevice:
            let name = s.rememberedDeviceName ?? "The pendant"
            return step(.unknown, "\(name) isn't connected",
                        "If its firmware supports offline recording, it keeps audio and the phone collects it when it's back in range.")
        case .streaming:
            let d = s.device
            if d?.rtcValid == false {
                return step(.delayed, "The pendant's clock isn't set", "It can't record while disconnected until the phone sets its clock.")
            }
            if case .receiving(let received, let total) = s.offline {
                return step(.working, "Collecting audio saved on the pendant", "\(received) of \(total)")
            }
            if let battery = d?.battery, battery <= 15, d?.charging != true {
                return step(.delayed, "Pendant battery is low (\(battery)%)", "Charge it soon to keep recording.")
            }
            let battery = d?.battery.map { "Battery \($0)%\(d?.charging == true ? ", charging" : "")" }
            return step(.normal, "Pendant connected", battery)
        }
    }

    /// Only a fresh report from the Watch says anything about it now; otherwise no step.
    static func watch(_ s: EngineSnapshot, now: Date) -> Step? {
        guard let r = s.watchReport, now.timeIntervalSince(r.at) <= WatchSummary.fresh else { return nil }
        switch r.state {
        case .recording: return Step(area: .watch, level: .normal, title: "Apple Watch recording", detail: "Reported \(relative(r.at, now))")
        case .paused: return Step(area: .watch, level: .needsAction, title: "Apple Watch recording is paused", detail: "Tap Resume on the Watch.")
        case .idle: return Step(area: .watch, level: .normal, title: "Apple Watch not recording", detail: "Reported \(relative(r.at, now))")
        }
    }

    static func phone(_ s: EngineSnapshot, server: ServerReachability) -> Step {
        func step(_ level: Level, _ title: String, _ detail: String? = nil, _ fix: Fix? = nil) -> Step {
            Step(area: .phone, level: level, title: title, detail: detail, fix: fix)
        }
        let waiting = s.outbox.pendingCount
        guard s.ready else { return step(.unknown, "Checking this iPhone") }  // placeholder: nothing known yet
        if s.storageTripped {
            return step(.needsAction, "Phone storage is full; recording stopped",
                        "Free up space on this iPhone. Audio already saved here is kept.")
        }
        if s.outbox.quarantineCount > 0 {
            let n = s.outbox.quarantineCount
            return step(.needsAction, "\(n) audio file\(n == 1 ? "" : "s") couldn't be uploaded",
                        "They're kept on this phone. Details are in Server → Diagnostics.", .openDiagnostics)
        }
        if !s.serverConfigured {
            return step(.needsAction, "No server connected", "Recordings stay on this phone until you connect your server.", .openServer)
        }
        if let paused = s.upload.pausedReason {
            return step(.needsAction, "Uploads are paused", paused, .openServer)
        }
        if waiting > 0 {
            let files = "\(waiting) file\(waiting == 1 ? "" : "s")"
            switch server {
            case .unreachable, .unauthorized:
                return step(.delayed, "Audio is waiting to upload", "\(files) stored safely on this phone; they upload when the server is reachable.", .retryUploads)
            default:
                return step(.working, "Uploading audio", "\(files) to go")
            }
        }
        if !s.attention.isEmpty {
            return step(.delayed, s.attention[0], s.attention.count > 1 ? "and \(s.attention.count - 1) more" : nil)
        }
        return step(.normal, "No files waiting to upload")
    }

    static func server(_ reach: ServerReachability, status: ServerStatus?, statusAt: Date?, now: Date,
                       issues: [ServerIssue] = []) -> Step {
        func step(_ level: Level, _ title: String, _ detail: String? = nil, _ fix: Fix? = nil) -> Step {
            Step(area: .server, level: level, title: title, detail: detail, fix: fix)
        }
        switch reach {
        case .notConfigured:
            return step(.needsAction, "No server connected", "Pair with your server to get notes.", .openServer)
        case .unauthorized:
            return step(.needsAction, "The server rejected this phone", "Pair again with a fresh code from your server.", .openServer)
        case .unreachable:
            return step(.delayed, "Can't reach your server", "Recordings wait on this phone. If you use Tailscale, check it's connected.", .openServer)
        case .unknown, .checking, .reachable:
            break
        }
        guard let status, let statusAt else { return step(.unknown, "Checking the server…") }
        if now.timeIntervalSince(statusAt) > staleAfter {
            return step(.unknown, "Server last checked \(relative(statusAt, now))", nil, .openServer)
        }
        let q = status.queue
        if let reason = status.readOnly {
            return step(.needsAction, "The server stopped saving notes", reason, .openServer)
        }
        if status.worker?.present == false {
            return step(.needsAction, "Processing is stopped on the server", "Restart the Omi Notes service on your server.", .openServer)
        }
        if status.stt?.ready == false {
            return step(.needsAction, "Transcription isn't set up on the server", nil, .openServer)
        }
        if status.llm?.ready == false {
            return step(.needsAction, "Summaries aren't set up on the server", "Transcripts are still saved.", .openServer)
        }
        let failed = (q?.conversationsFailed).map { $0 + (q?.chunksFailed ?? 0) } ?? q?.failed ?? 0
        let conflicts = q?.notesConflicted ?? 0
        // a no-speaker result is incomplete, not broken: the phone can keep it as a transcript
        let keepable = min(failed, issues.filter { $0.code == "conversation_failed" && $0.canKeepFromPhone }.count)
        if failed + conflicts - keepable > 0 {
            let n = failed + conflicts - keepable
            return step(.needsAction, "\(n) item\(n == 1 ? "" : "s") couldn't be finished on the server",
                        "The server keeps the audio. See Server for what happened.", .openServer)
        }
        if keepable > 0 {
            return step(.delayed, "\(keepable) recording\(keepable == 1 ? " has" : "s have") no separable speaker",
                        "You can keep \(keepable == 1 ? "it" : "them") as a transcript on the Server page.", .openServer)
        }
        if let retrying = q?.conversationsRetrying, retrying > 0 {
            let a = status.activity
            let failing = a?.stt?.lastFailed == true ? ("transcription", a?.stt) : a?.llm?.lastFailed == true ? ("summary", a?.llm) : nil
            if let (service, calls) = failing, let at = calls?.lastErrorAt.flatMap(ISO8601UTC.parse) {
                return step(.delayed, "The \(service) service is having trouble",
                            "Last attempt failed \(relative(at, now)). The server keeps trying on its own.", .openServer)
            }
            return step(.delayed, "The server is retrying \(retrying) conversation\(retrying == 1 ? "" : "s")",
                        "A service it uses is having trouble; it keeps trying on its own.", .openServer)
        }
        guard let q else {
            return step(.unknown, "Server reachable; processing status unavailable", "This server version doesn't report its queue.")
        }
        let processing = q.conversationsPending ?? 0
        let queued = q.chunksPending ?? 0
        if processing > 0 {
            let running = status.activity?.running?.first
            let doing = running.map { $0.stage == "summarizing" ? "Writing a summary" : "Transcribing a conversation" }
            return step(.working, doing ?? "Processing \(processing) conversation\(processing == 1 ? "" : "s")",
                        processing > 1 ? "\(processing) conversations to go" : nil)
        }
        if queued > 0 {
            return step(.working, "Reading new audio")
        }
        guard status.worker?.present == true else {
            return step(.unknown, "Server reachable; processing status unavailable",
                        "This server version doesn't report whether processing is running.")
        }
        let open = q.conversationsOpen ?? 0
        return step(.normal, "Server is running", open > 0 ? "\(open) conversation\(open == 1 ? "" : "s") in progress" : nil)
    }

    static func notes(_ status: ServerStatus?, statusAt: Date?, now: Date) -> Step {
        guard let status, statusAt != nil else { return Step(area: .notes, level: .unknown, title: "Notes not checked yet") }
        guard let last = status.lastNoteAt.flatMap(ISO8601UTC.parse) else {
            if status.lastNoteAt == nil, status.features?.contains("issues") != true {
                return Step(area: .notes, level: .normal, title: "Notes are written on your server")  // older server: unknown date
            }
            return Step(area: .notes, level: .unknown, title: "No notes yet",
                        detail: "A note appears a few minutes after a conversation ends.")
        }
        return Step(area: .notes, level: .normal, title: "Last note \(relative(last, now))")
    }

    public static func relative(_ date: Date, _ now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
