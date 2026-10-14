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

    /// A report older than this says what the Watch was doing then, not now.
    public static let fresh: TimeInterval = 10 * 60

    /// - Parameter installed: the Watch app is installed on a paired Watch; nil while unknown.
    public static func evaluate(installed: Bool?, report: WatchReport?, lastReceivedAt: Date?, now: Date) -> WatchSummary {
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

    static func time(_ date: Date, _ now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    #if DEBUG
    /// Simulator screenshots only: `-OmiNotesDebugWatchState recording|paused|stale|received|installed|none`.
    public static func debugFixture(_ name: String, now: Date = Date()) -> (summary: WatchSummary, report: WatchReport?, lastReceivedAt: Date?)? {
        let report: WatchReport?, received: Date?, installed: Bool
        switch name {
        case "recording": (report, received, installed) = (WatchReport(state: .recording, since: now.addingTimeInterval(-3 * 3600), waitingParts: 2, at: now.addingTimeInterval(-60)), now.addingTimeInterval(-90), true)
        case "paused": (report, received, installed) = (WatchReport(state: .paused, since: now.addingTimeInterval(-3600), waitingParts: 0, at: now.addingTimeInterval(-120)), now.addingTimeInterval(-150), true)
        case "stale": (report, received, installed) = (WatchReport(state: .recording, since: now.addingTimeInterval(-6 * 3600), waitingParts: 5, at: now.addingTimeInterval(-2 * 3600)), now.addingTimeInterval(-2 * 3600), true)
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
