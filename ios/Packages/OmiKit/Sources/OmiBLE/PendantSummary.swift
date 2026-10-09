import Foundation
import OmiCapture
import OmiProtocol

/// What the Pendant tab shows: the pendant's connection and battery, the most urgent pendant or
/// phone problem (from `SystemHealth`, so it never disagrees with Home), where audio is between the
/// pendant, this phone and the server, and the server's global note activity.
///
/// Only observed facts: a packet arriving is not "sound", a past upload is not "everything
/// uploaded", an old server answer is shown with its age, and a missing battery reading is unknown.
public struct PendantSummary: Equatable, Sendable {
    public enum Battery: Equatable, Sendable {
        /// `low` is the `SystemHealth` rule: 15% or less and not charging.
        case level(percent: Int, charging: Bool, low: Bool)
        /// No reading: `reason` says why ("Not connected", "Not reported yet").
        case unknown(reason: String)
    }

    /// One observation along pendant → phone → server.
    public struct Flow: Equatable, Sendable, Identifiable {
        public enum Place: String, Sendable { case pendant, phone, server }
        public var place: Place
        public var level: SystemHealth.Level
        public var title: String
        public var detail: String?
        public var id: Place { place }
    }

    /// Server-wide activity: not about any one recording.
    public struct Notes: Equatable, Sendable {
        public var processing: Int?
        public var lastNoteAt: Date?
        /// The answer these figures come from, and whether it is too old to be current.
        public var asOf: Date
        public var stale: Bool
    }

    public var connected: Bool
    public var connectionTitle: String
    public var battery: Battery
    /// The most urgent of the pendant and phone health steps.
    public var headline: SystemHealth.Step
    /// The other of the two, when it also needs attention or is delayed.
    public var also: [SystemHealth.Step]
    public var flow: [Flow]
    public var notes: Notes?
    /// Collecting audio the pendant stored while disconnected (records received, total).
    public var collecting: (received: Int, total: Int)?

    public static func == (a: PendantSummary, b: PendantSummary) -> Bool {
        a.connected == b.connected && a.connectionTitle == b.connectionTitle && a.battery == b.battery
            && a.headline == b.headline && a.also == b.also && a.flow == b.flow && a.notes == b.notes
            && a.collecting?.received == b.collecting?.received && a.collecting?.total == b.collecting?.total
    }

    public static func evaluate(
        snapshot s: EngineSnapshot, server: ServerReachability, status: ServerStatus?, statusAt: Date?, now: Date
    ) -> PendantSummary {
        let health = SystemHealth.evaluate(snapshot: s, server: server, status: status, statusAt: statusAt, now: now)
        let pendant = health.steps.first { $0.area == .pendant }!
        let phone = health.steps.first { $0.area == .phone }!
        // Both merely delayed: the phone leads (audio not reaching the server matters more than, say, a
        // low battery). Both needing action: the pendant leads (pairing or Bluetooth comes first).
        let lead = phone.level > pendant.level || (phone.level == .delayed && pendant.level == .delayed) ? phone : pendant
        let other = lead.area == .pendant ? phone : pendant
        let headline = lead.level == .normal && s.connection == .streaming
            ? SystemHealth.Step(area: .pendant, level: .normal, title: "Connected and recording", detail: nil, fix: nil)
            : lead

        var collecting: (Int, Int)?
        if case .receiving(let received, let total) = s.offline { collecting = (received, total) }

        // `SystemHealth` mentions a low battery only when nothing else is going on with the pendant
        // (pendant sync, for one, comes first); here it is always said, once.
        let charge = battery(s)
        var also = other.level >= .delayed ? [other] : []
        if case .level(let percent, _, true) = charge, !([headline] + also).contains(where: { $0.title.contains("battery is low") }) {
            let low = SystemHealth.Step(area: .pendant, level: .delayed, title: "Pendant battery is low (\(percent)%)",
                                        detail: "Charge it soon to keep recording.", fix: nil)
            also.removeAll { $0.area == .pendant }
            also.append(low)
        }

        return PendantSummary(
            connected: s.connection == .streaming, connectionTitle: connectionTitle(s), battery: charge,
            headline: headline, also: also,
            flow: [pendantFlow(s, now: now), phoneFlow(s), serverFlow(s, server: server, statusAt: statusAt, now: now)],
            notes: notes(status, statusAt: statusAt, now: now), collecting: collecting)
    }

    // MARK: Parts

    static func connectionTitle(_ s: EngineSnapshot) -> String {
        switch s.connection {
        case .noDevice: return "No pendant paired"
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .waitingForDevice: return "Not connected"
        case .settingUp: return "Connecting…"
        case .streaming: return "Connected · recording"
        case .refused: return "Can't use this pendant"
        case .paused: return "Recording paused"
        }
    }

    static func battery(_ s: EngineSnapshot) -> Battery {
        guard s.connection == .streaming || s.connection == .settingUp, let d = s.device else {
            return .unknown(reason: s.rememberedDeviceId == nil ? "No pendant" : "Not connected")
        }
        guard let percent = d.battery else { return .unknown(reason: "Not reported yet") }
        let charging = d.charging == true
        return .level(percent: percent, charging: charging, low: percent <= 15 && !charging)
    }

    static func pendantFlow(_ s: EngineSnapshot, now: Date) -> Flow {
        func flow(_ level: SystemHealth.Level, _ title: String, _ detail: String? = nil) -> Flow {
            Flow(place: .pendant, level: level, title: title, detail: detail)
        }
        switch s.connection {
        case .streaming:
            if s.device?.noAudioYet == true { return flow(.normal, "Connected", "No audio yet") }
            if let at = s.live?.lastNotificationAt {
                return flow(.normal, "Receiving audio", "Last packet \(SystemHealth.relative(at, now))")
            }
            return flow(.normal, "Connected")
        case .settingUp: return flow(.working, "Connecting…")
        case .waitingForDevice: return flow(.unknown, "Not connected")
        case .noDevice: return flow(.needsAction, "Not paired")
        case .bluetoothUnavailable: return flow(.needsAction, "Bluetooth off")
        case .refused: return flow(.needsAction, "Can't be used")
        case .paused: return flow(.needsAction, "Paused")
        }
    }

    static func phoneFlow(_ s: EngineSnapshot) -> Flow {
        func flow(_ level: SystemHealth.Level, _ title: String, _ detail: String? = nil) -> Flow {
            Flow(place: .phone, level: level, title: title, detail: detail)
        }
        if s.storageTripped { return flow(.needsAction, "Storage full", "Recording stopped") }
        let n = s.outbox.pendingCount
        let files = "\(n) file\(n == 1 ? "" : "s")"
        if s.outbox.quarantineCount > 0 {
            return flow(.needsAction, "\(s.outbox.quarantineCount) couldn't upload", n > 0 ? "\(files) waiting; all kept" : "Kept on this phone")
        }
        if s.upload.pausedReason != nil { return flow(.needsAction, "Uploads paused", n > 0 ? "\(files) kept here" : nil) }
        if n > 0 { return flow(.working, "\(files) waiting", "Stored here, not uploaded yet") }
        return flow(.normal, "No files waiting")
    }

    static func serverFlow(_ s: EngineSnapshot, server: ServerReachability, statusAt: Date?, now: Date) -> Flow {
        func flow(_ level: SystemHealth.Level, _ title: String, _ detail: String? = nil) -> Flow {
            Flow(place: .server, level: level, title: title, detail: detail)
        }
        let last = s.upload.lastSuccessAt.map { "Last successful upload \(SystemHealth.relative($0, now))" } ?? "No upload yet"
        switch server {
        case .notConfigured: return flow(.needsAction, "Not connected", "Pair a server to upload")
        case .unauthorized: return flow(.needsAction, "Rejected this phone", last)
        case .unreachable: return flow(.delayed, "Can't reach", last)
        case .unknown, .checking: return flow(.unknown, "Checking…", last)
        case .reachable:
            guard let statusAt, now.timeIntervalSince(statusAt) <= SystemHealth.staleAfter else {
                return flow(.unknown, "Last checked \(statusAt.map { SystemHealth.relative($0, now) } ?? "never")", last)
            }
            return flow(.normal, "Reachable", last)
        }
    }

    static func notes(_ status: ServerStatus?, statusAt: Date?, now: Date) -> Notes? {
        guard let status, let statusAt else { return nil }
        return Notes(processing: status.queue?.conversationsPending, lastNoteAt: status.lastNoteAt.flatMap(ISO8601UTC.parse),
                     asOf: statusAt, stale: now.timeIntervalSince(statusAt) > SystemHealth.staleAfter)
    }
}

#if DEBUG
extension PendantSummary {
    /// Simulator screenshots only (debug builds): synthetic states run through the real `evaluate`.
    /// `normal`, `disconnected`, `unpaired`, `blocked` (uploads blocked + low battery + pendant sync).
    public static func debugFixture(_ name: String, now: Date = Date()) -> PendantSummary? {
        var s = EngineSnapshot()
        s.serverConfigured = true
        s.rememberedDeviceId = "5eed0000-fixture"
        s.rememberedDeviceName = "Omi"
        s.simulated = true
        var d = DeviceSession.Info()
        d.battery = 82
        d.charging = false
        var live = LiveSnapshot()
        live.lastNotificationAt = now.addingTimeInterval(-12)
        s.upload.lastSuccessAt = now.addingTimeInterval(-60)
        let status = try? JSONDecoder().decode(ServerStatus.self, from: Data(#"{"queue":{"conversations_pending":1,"conversations_open":0,"failed":0,"conversations_failed":0,"chunks_failed":0},"worker":{"present":true},"last_note_at":null,"features":["issues"]}"#.utf8))
        var server = ServerReachability.reachable(version: "fixture", detail: "")
        var statusAt: Date? = now.addingTimeInterval(-20)
        switch name {
        case "normal":
            s.connection = .streaming
            s.device = d
            s.live = live
        case "disconnected":
            s.connection = .waitingForDevice
            s.upload.lastSuccessAt = now.addingTimeInterval(-24 * 60)
        case "unpaired":
            s = EngineSnapshot()
            server = .notConfigured
            statusAt = nil
        case "blocked":
            s.connection = .streaming
            d.battery = 12
            s.device = d
            s.live = live
            s.outbox.pendingCount = 38
            s.outbox.pendingBytes = 12_000_000
            s.offline = .receiving(received: 68, total: 241)
            s.upload.lastSuccessAt = now.addingTimeInterval(-88 * 60)
            server = .unreachable("Could not connect to the server.")
            statusAt = now.addingTimeInterval(-88 * 60)
        default:
            return nil
        }
        return evaluate(snapshot: s, server: server, status: name == "unpaired" ? nil : status, statusAt: statusAt, now: now)
    }
}
#endif
