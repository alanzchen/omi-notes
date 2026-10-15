import OmiBLE
import OmiCapture
import UserNotifications

/// Posts `ProblemAlerts` and Apple Watch stop alerts as local notifications. Generic text only:
/// nothing from a conversation.
final class LocalAlerts: ProblemAlertSink, WatchStopAlertSink, @unchecked Sendable {
    /// `userInfo["route"]` of an alert that opens the Apple Watch page when tapped.
    static let watchRoute = "watch"
    private let center = UNUserNotificationCenter.current()

    func post(_ problem: PhoneProblem) {
        let content = UNMutableNotificationContent()
        content.title = problem.title
        content.body = problem.body
        center.add(UNNotificationRequest(identifier: problem.identifier, content: content, trigger: nil))
    }

    func withdraw(_ problem: PhoneProblem) {
        center.removePendingNotificationRequests(withIdentifiers: [problem.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [problem.identifier])
    }

    /// After its grace time (for an interruption the system may still resume); the same identifier
    /// replaces an earlier one for that recording, so there is never more than one.
    func schedule(_ alert: WatchStopAlerts.Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.userInfo = ["route": Self.watchRoute]
        let delay = alert.fireAt.timeIntervalSinceNow
        let trigger = delay > 1 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger))
        OmiLog.shared.log(.info, "alerts", "Watch stop alert \(alert.identifier) in \(Int(max(0, delay))) s: \(alert.title)")
    }

    func withdraw(identifier: String) {
        OmiLog.shared.log(.info, "alerts", "Watch stop alert \(identifier) withdrawn")
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Asks for permission; false if the user declined (now or earlier, in Settings).
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
