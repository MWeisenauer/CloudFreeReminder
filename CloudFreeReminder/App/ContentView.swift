import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ReminderStore

    var body: some View {
        TabView {
            ReminderListView()
                .tabItem { Label("Erinnerungen", systemImage: "bell") }
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gear") }
        }
    }
}
