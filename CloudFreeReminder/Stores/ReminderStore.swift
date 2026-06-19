import Foundation
import Combine

@MainActor
class ReminderStore: ObservableObject {
    @Published var reminders: [Reminder] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadReminders() async {
        let settings = FTPSSettings.load()
        guard settings.isConfigured else {
            errorMessage = "Bitte zuerst die FTPS-Einstellungen konfigurieren."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            reminders = try await ReminderService(settings: settings).fetchAllReminders()
            await NotificationManager.sync(reminders: reminders)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func saveReminder(_ reminder: Reminder) async throws {
        var mutable = reminder
        if mutable.remoteFilename.isEmpty {
            mutable.remoteFilename = "\(mutable.id.uuidString).txt"
        }
        mutable.modifiedDate = Date()
        let settings = FTPSSettings.load()
        try await ReminderService(settings: settings).uploadReminder(mutable)
        if let idx = reminders.firstIndex(where: { $0.remoteFilename == mutable.remoteFilename }) {
            reminders[idx] = mutable
        } else {
            reminders.insert(mutable, at: 0)
        }
        sort()
        await NotificationManager.sync(reminders: reminders)
    }

    func deleteReminder(_ reminder: Reminder) async throws {
        guard !reminder.remoteFilename.isEmpty else {
            reminders.removeAll { $0.id == reminder.id }
            await NotificationManager.sync(reminders: reminders)
            return
        }
        let settings = FTPSSettings.load()
        try await ReminderService(settings: settings).deleteReminder(filename: reminder.remoteFilename)
        reminders.removeAll { $0.remoteFilename == reminder.remoteFilename }
        await NotificationManager.sync(reminders: reminders)
    }

    // Toggles "erledigt" and writes the change back to the Fritz!Box.
    func toggleCompleted(_ reminder: Reminder) async {
        var updated = reminder
        updated.isCompleted.toggle()
        do {
            try await saveReminder(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sort() {
        reminders.sort { lhs, rhs in
            sortKey(lhs) < sortKey(rhs)
        }
    }

    private func sortKey(_ r: Reminder) -> Date {
        if r.isCompleted { return Date.distantFuture }
        return r.dueDate ?? Date.distantFuture
    }
}
