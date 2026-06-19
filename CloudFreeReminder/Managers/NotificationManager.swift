import Foundation
import UserNotifications

// Schedules one local notification per reminder due date. These fire at the exact
// time even when the app is closed or terminated – this is the reliable mechanism
// for "a reminder is due", independent of any background polling.
nonisolated enum NotificationManager {

    // Ask the user once for permission to show notifications.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // Re-creates all pending notifications from the current set of reminders.
    // Call this after every load / save / delete so the scheduled notifications
    // always match the data on the Fritz!Box.
    static func sync(reminders: [Reminder]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let now = Date()
        for reminder in reminders {
            guard !reminder.isCompleted, let due = reminder.dueDate, due > now else { continue }
            scheduleRequest(for: reminder, at: due, on: center)
        }
    }

    private static func scheduleRequest(for reminder: Reminder, at due: Date, on center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = reminder.displayTitle
        if !reminder.body.isEmpty {
            content.body = String(reminder.body.prefix(200))
        }
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.id.uuidString,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }
}
