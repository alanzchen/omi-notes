import OmiBLE
import UserNotifications

/// Posts `ProblemAlerts` as local notifications. Generic text only: nothing from a conversation.
final class LocalAlerts: ProblemAlertSink, @unchecked Sendable {
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

    /// Asks for permission; false if the user declined (now or earlier, in Settings).
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
