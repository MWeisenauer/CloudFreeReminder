import Foundation

// A reminder is a note with an optional follow-up date ("Wiedervorlagetermin").
nonisolated struct Reminder: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String = ""
    var body: String = ""
    var dueDate: Date? = nil
    var isCompleted: Bool = false
    var modifiedDate: Date = Date()
    var remoteFilename: String = ""

    var displayTitle: String { title.isEmpty ? "Neue Erinnerung" : title }

    // Due and not yet handled.
    var isDue: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate <= Date()
    }

    // Due in the past while still open.
    var isOverdue: Bool { isDue }

    var hasFutureDueDate: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate > Date()
    }
}
