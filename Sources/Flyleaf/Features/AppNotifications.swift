import Foundation
import UserNotifications

// Opt-in chapter briefings. Nothing else ever notifies.
enum AppNotifications {
    static func requestAuthorization() async -> Bool {
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            log(.app, "Notification permission: \(granted ? "granted" : "denied")")
            return granted
        } catch {
            log(.app, .warn, "Notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    static func sendChapterBriefing(chapter: Int, title: String, briefing: String) {
        let content = UNMutableNotificationContent()
        content.title = "Chapter \(chapter): \(title)"
        content.body = briefing
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "chapter-briefing-\(chapter)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log(.app, .warn, "Notification failed: \(error.localizedDescription)")
            }
        }
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
