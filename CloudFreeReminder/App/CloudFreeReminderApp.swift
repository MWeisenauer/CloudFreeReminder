import SwiftUI

@main
struct CloudFreeReminderApp: App {
    @StateObject private var store = ReminderStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    // Ask for notification permission once at launch.
                    await NotificationManager.requestAuthorization()
                }
        }
    }
}
