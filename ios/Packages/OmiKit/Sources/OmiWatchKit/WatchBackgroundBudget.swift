import Foundation

/// WatchConnectivity kills a Watch app that uses more than 2 s of CPU while handling a background wake
/// ("watchdog transgression … CSLHandleBackgroundWCSessionAction"); builds 38 and 42 were killed in the send
/// loop. While the app isn't active, sending stops once this background period has used `cpuSeconds` (counted
/// from process start for a launch into the background); the parts wait, durable, for the next wake or launch.
public struct WatchBackgroundBudget: Sendable {
    public static let cpuSeconds = 1.0
    /// CPU time at the start of the current background period; 0: launched into it.
    private var periodStart: Double? = 0

    public init() {}

    public mutating func mayWork(active: Bool, cpu: Double) -> Bool {
        if active {
            periodStart = nil
            return true
        }
        let start = periodStart ?? cpu
        periodStart = start
        return cpu - start < Self.cpuSeconds
    }

    /// User plus system CPU time of this process, in seconds.
    public static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
