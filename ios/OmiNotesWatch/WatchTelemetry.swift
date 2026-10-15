import Foundation
import OmiProtocol
import OmiWatchKit
import WatchKit

/// Battery and work counters while a recording is active, kept in `WatchPerfQueue` and sent to the
/// iPhone (then the server) like audio, with acknowledgements. Samples are taken at recording
/// events and, while recording, at most every `interval` when a part finishes (no timer of its
/// own). Battery monitoring is on only while a recording is active. An unknown level is left out,
/// never reported as 0.
@MainActor
final class WatchTelemetry {
    static let interval: TimeInterval = 5 * 60

    let queue: WatchPerfQueue
    /// One per app launch: counters are cumulative within it, so deltas never cross a relaunch.
    let launchId = UUID().uuidString.lowercased()
    private var lastSampleUptime: TimeInterval?

    init(queue: WatchPerfQueue) {
        self.queue = queue
    }

    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// A random id for this boot, kept until the Watch reboots: lets the server tell a reboot from
    /// continuous time without receiving the boot time (which never leaves the Watch).
    static var bootId: String {
        let uptime = ProcessInfo.processInfo.systemUptime
        let boot = Date().timeIntervalSince1970 - uptime
        let d = UserDefaults.standard
        if let id = d.string(forKey: "omi.bootId"), abs(d.double(forKey: "omi.bootRef") - boot) < 5 { return id }
        let id = UUID().uuidString.lowercased()
        d.set(id, forKey: "omi.bootId")
        d.set(boot, forKey: "omi.bootRef")
        return id
    }

    func monitorBattery(_ on: Bool) {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = on
    }

    /// `periodic` samples are skipped until `interval` has passed since the last sample.
    /// `mono`: seconds since the recording started (monotonic), nil if it started before a reboot.
    func sample(_ event: String, state: String, recordingId: String?, mono: TimeInterval?, counters: [String: Int], gauges: [String: Int],
                binding: String?, seal: Bool = false) {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        if event == "periodic", let last = lastSampleUptime, uptime - last < Self.interval { return }
        guard let binding else { return }  // not paired with an iPhone yet: nothing could receive it
        lastSampleUptime = uptime
        let device = WKInterfaceDevice.current()
        let level = device.batteryLevel
        let batteryState: String
        switch device.batteryState {
        case .unplugged: batteryState = "unplugged"
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        default: batteryState = "unknown"
        }
        let s = WatchPerfSample(
            id: UUID().uuidString.lowercased(), at: ISO8601UTC.format(now), monoS: mono.map { ($0 * 1000).rounded() / 1000 },
            bootId: Self.bootId, launchId: launchId, recordingId: recordingId, event: event,
            state: state, battery: level >= 0 && level <= 1 ? (Double(level) * 1000).rounded() / 1000 : nil, batteryState: batteryState,
            counters: counters, gauges: gauges, app: Self.appVersion, os: device.systemVersion, model: Self.hardwareModel)
        queue.append(s, deviceId: WatchRecorder.deviceId, binding: binding, seal: seal)
    }
}
