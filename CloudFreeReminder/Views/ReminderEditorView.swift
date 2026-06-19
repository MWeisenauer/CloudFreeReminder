import SwiftUI

struct ReminderEditorView: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss

    private let existing: Reminder?
    @State private var title: String
    @State private var bodyText: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var isCompleted: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(reminder: Reminder?) {
        self.existing = reminder
        _title       = State(initialValue: reminder?.title ?? "")
        _bodyText    = State(initialValue: reminder?.body ?? "")
        _hasDueDate  = State(initialValue: reminder?.dueDate != nil)
        _dueDate     = State(initialValue: reminder?.dueDate ?? Self.defaultDueDate())
        _isCompleted = State(initialValue: reminder?.isCompleted ?? false)
    }

    // Default suggestion: one hour from now, rounded to the minute.
    private static func defaultDueDate() -> Date {
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        return cal.date(from: comps) ?? next
    }

    var body: some View {
        Form {
            Section("Titel") {
                TextField("Titel", text: $title)
            }

            Section("Notiz") {
                TextField("Text", text: $bodyText, axis: .vertical)
                    .lineLimit(3...10)
            }

            Section("Wiedervorlage") {
                Toggle("Termin festlegen", isOn: $hasDueDate.animation())
                if hasDueDate {
                    DatePicker(
                        "Fällig am",
                        selection: $dueDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }

            if existing != nil {
                Section {
                    Toggle("Erledigt", isOn: $isCompleted)
                }
            }
        }
        .navigationTitle(existing == nil ? "Neue Erinnerung" : "Erinnerung")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if existing == nil {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Speichern").fontWeight(.semibold)
                    }
                }
                .disabled(isSaving || (title.isEmpty && bodyText.isEmpty))
            }
        }
        .alert("Fehler", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        isSaving = true
        var reminder = existing ?? Reminder()
        reminder.title       = title
        reminder.body        = bodyText
        reminder.dueDate     = hasDueDate ? dueDate : nil
        reminder.isCompleted = isCompleted
        do {
            try await store.saveReminder(reminder)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
