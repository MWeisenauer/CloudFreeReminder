import SwiftUI

struct ReminderListView: View {
    @EnvironmentObject private var store: ReminderStore
    @State private var searchText = ""
    @State private var showNewReminder = false

    private var filtered: [Reminder] {
        guard !searchText.isEmpty else { return store.reminders }
        return store.reminders.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.body.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading {
                    ProgressView("Lade Erinnerungen…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.reminders.isEmpty {
                    ContentUnavailableView(
                        "Keine Erinnerungen",
                        systemImage: "bell.badge",
                        description: Text("Tippe auf das Plus-Symbol, um eine neue Erinnerung anzulegen.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filtered) { reminder in
                            NavigationLink(destination: ReminderEditorView(reminder: reminder)) {
                                ReminderRowView(reminder: reminder)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await store.toggleCompleted(reminder) }
                                } label: {
                                    Label(
                                        reminder.isCompleted ? "Offen" : "Erledigt",
                                        systemImage: reminder.isCompleted ? "arrow.uturn.backward" : "checkmark"
                                    )
                                }
                                .tint(reminder.isCompleted ? .gray : .green)
                            }
                        }
                        .onDelete(perform: deleteReminders)
                    }
                    .refreshable { await store.loadReminders() }
                }
            }
            .navigationTitle("Erinnerungen")
            .searchable(text: $searchText, prompt: "Erinnerungen durchsuchen")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewReminder = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await store.loadReminders() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .sheet(isPresented: $showNewReminder) {
                NavigationStack {
                    ReminderEditorView(reminder: nil)
                }
            }
            .alert("Fehler", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .task {
                if store.reminders.isEmpty && store.errorMessage == nil {
                    await store.loadReminders()
                }
            }
        }
    }

    private func deleteReminders(at offsets: IndexSet) {
        let toDelete = offsets.map { filtered[$0] }
        Task {
            for reminder in toDelete {
                do {
                    try await store.deleteReminder(reminder)
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct ReminderRowView: View {
    let reminder: Reminder

    private var dueText: String? {
        guard let due = reminder.dueDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: due)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill"
                  : (reminder.isOverdue ? "exclamationmark.circle.fill" : "circle"))
                .font(.title3)
                .foregroundStyle(reminder.isCompleted ? .green
                                 : (reminder.isOverdue ? .red : .secondary))

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.displayTitle)
                    .font(.headline)
                    .strikethrough(reminder.isCompleted, color: .secondary)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .lineLimit(1)

                if let dueText {
                    Label(dueText, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                } else if !reminder.body.isEmpty {
                    Text(reminder.body)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    let store = ReminderStore()
    store.reminders = [
        Reminder(title: "Arzt Termin", body: "Dr. Müller anrufen", dueDate: Date().addingTimeInterval(3600)),
        Reminder(title: "Einkauf", body: "Milch, Brot, Käse", isCompleted: true),
        Reminder(title: "Rechnung bezahlen", dueDate: Date().addingTimeInterval(-86400))
    ]
    return ReminderListView()
        .environmentObject(store)
        .preferredColorScheme(.dark)
}
