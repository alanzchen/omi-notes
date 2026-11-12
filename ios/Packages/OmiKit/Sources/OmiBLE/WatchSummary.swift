import Foundation
import OmiWatchKit

/// The Apple Watch as the Devices screen shows it. It states only what the app knows: the Watch's
/// own report (as of its timestamp), what this iPhone received, and what is waiting to upload. A
/// recent receipt or a reachable Watch is not taken to mean it is recording now.
public struct WatchSummary: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case recording, attention, quiet }

    /// Shown as a device (a card) rather than a setup row.
    public var configured: Bool
    public var title: String
    public var detail: String?
    public var tone: Tone
    /// A problem shown on the Watch's card (one short line), and what fixes it.
    public var issue: String?
    public var issueFix: SystemHealth.Fix?

    /// A report older than this says what the Watch was doing then, not now.
    public static let fresh: TimeInterval = 10 * 60

    /// - Parameter installed: the Watch app is installed on a paired Watch; nil while unknown.
    /// - Parameter quarantined: the Watch's files this iPhone kept aside because they couldn't upload.
    public static func evaluate(installed: Bool?, report: WatchReport?, lastReceivedAt: Date?, now: Date,
                                quarantined: Int = 0) -> WatchSummary {
        var summary = state(installed: installed, report: report, lastReceivedAt: lastReceivedAt, now: now)
        if quarantined > 0 {
            summary.configured = true
            summary.issue = "\(quarantined) file\(quarantined == 1 ? "" : "s") couldn't upload"
            summary.issueFix = .openDiagnostics
        }
        return summary
    }

    static func state(installed: Bool?, report: WatchReport?, lastReceivedAt: Date?, now: Date) -> WatchSummary {
        let configured = installed == true || report != nil || lastReceivedAt != nil
        if let r = report {
            let age = now.timeIntervalSince(r.at)
            let asOf = "reported \(SystemHealth.relative(r.at, now))"
            if age <= fresh {
                switch r.state {
                case .recording:
                    let since = r.since.map { "since \(Self.time($0, now)) · " } ?? ""
                    return WatchSummary(configured: true, title: "Recording", detail: since + asOf, tone: .recording)
                case .paused:
                    return WatchSummary(configured: true, title: "Paused on the Watch", detail: "Tap Resume on the Watch · \(asOf)", tone: .attention)
                case .idle:
                    return WatchSummary(configured: true, title: "Not recording", detail: asOf, tone: .quiet)
                }
            }
            let was = r.state == .recording ? "recording" : r.state == .paused ? "paused" : "not recording"
            return WatchSummary(configured: true, title: "Current state unknown",
                                detail: "Last report \(SystemHealth.relative(r.at, now)): \(was)", tone: .quiet)
        }
        if let at = lastReceivedAt {
            return WatchSummary(configured: true, title: "Current state unknown",
                                detail: "Last audio received \(SystemHealth.relative(at, now))", tone: .quiet)
        }
        if configured {
            return WatchSummary(configured: true, title: "Not used yet", detail: "Open Omi Notes on the Watch and tap the microphone", tone: .quiet)
        }
        return WatchSummary(configured: false, title: "Set up Apple Watch", detail: nil, tone: .quiet)
    }

    /// The Watch detail's "On the Watch" line, as of its report: the recorded length waiting (from the
    /// Watch's own parts, never a count × 60 s), parts kept that can't be sent, and, when waiting audio
    /// hasn't arrived for a while, what helps (about the sendable audio only). Re-checks are named but
    /// still unacknowledged; unknown kept parts (older Watch apps) never allow "everything sent".
    public static func onWatchLine(_ r: WatchReport, lastReceivedAt: Date?, now: Date) -> String {
        let kept = r.keptParts ?? 0
        let newParts = max(0, r.waitingParts - r.recheckParts)
        let waiting: String? = r.waitingParts == 0 ? nil
            : newParts == 0 ? "Re-checking \(r.recheckParts) older part\(r.recheckParts == 1 ? "" : "s") with this iPhone"
            : (r.waitingSeconds ?? 0) > 0 ? "\(Self.capitalizedFirst(WaitingAudio.text(r.waitingSeconds!))) of audio not on this iPhone yet"
            : "Some audio not on this iPhone yet"
        let keptText = kept > 0 ? "\(kept) part\(kept == 1 ? "" : "s") kept on the Watch, can't be sent" : nil
        let parts = [waiting, keptText].compactMap { $0 }.joined(separator: " · ")
        let what = !parts.isEmpty ? parts
            : r.keptParts == nil ? "Nothing waiting; kept parts not reported"
            : "Everything sent to this iPhone"
        // waiting, and nothing has arrived for a while: what helps
        let stuck = r.waitingParts > 0 && (lastReceivedAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? true)
        let advice = !stuck ? "" : kept > 0 ? ". The waiting audio moves when both are nearby with Omi Notes open."
            : ". They move when both are nearby with Omi Notes open."
        return "\(what) · reported \(SystemHealth.relative(r.at, now))" + advice
    }

    static func capitalizedFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func time(_ date: Date, _ now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    #if DEBUG
    /// Simulator screenshots only: `-OmiNotesDebugWatchState recording|paused|stale|idle|received|installed|none`.
    public static func debugFixture(_ name: String, now: Date = Date()) -> (summary: WatchSummary, report: WatchReport?, lastReceivedAt: Date?)? {
        let report: WatchReport?, received: Date?, installed: Bool
        switch name {
        case "recording": (report, received, installed) = (WatchReport(state: .recording, since: now.addingTimeInterval(-3 * 3600), waitingParts: 2, waitingSeconds: 95, at: now.addingTimeInterval(-60)), now.addingTimeInterval(-90), true)
        case "paused": (report, received, installed) = (WatchReport(state: .paused, since: now.addingTimeInterval(-3600), waitingParts: 0, at: now.addingTimeInterval(-120)), now.addingTimeInterval(-150), true)
        case "stale": (report, received, installed) = (WatchReport(state: .recording, since: now.addingTimeInterval(-6 * 3600), waitingParts: 5, waitingSeconds: 290, at: now.addingTimeInterval(-2 * 3600)), now.addingTimeInterval(-2 * 3600), true)
        case "idle": (report, received, installed) = (WatchReport(state: .idle, since: now.addingTimeInterval(-5 * 3600), waitingParts: 3, waitingSeconds: 140, at: now.addingTimeInterval(-90)), now.addingTimeInterval(-4 * 3600), true)
        case "received": (report, received, installed) = (nil, now.addingTimeInterval(-40 * 60), true)
        case "installed": (report, received, installed) = (nil, nil, true)
        case "none": (report, received, installed) = (nil, nil, false)
        default: return nil
        }
        return (evaluate(installed: installed, report: report, lastReceivedAt: received, now: now), report, received)
    }
    #endif
}

/// Which devices get a card and which a quiet setup row, in a fixed order (pendant, then Watch).
/// Both may record at the same time; there is no choice between them.
public enum DeviceLayout {
    public enum Device: String, Equatable, Sendable { case pendant, watch }

    public static func arrange(pendantPaired: Bool, watchConfigured: Bool) -> (cards: [Device], setup: [Device]) {
        let all: [(Device, Bool)] = [(.pendant, pendantPaired), (.watch, watchConfigured)]
        return (all.filter(\.1).map(\.0), all.filter { !$0.1 }.map(\.0))
    }
}
