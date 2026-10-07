import SwiftUI

struct ReminderLabel: View {
    let isReminded: Bool

    var body: some View {
        Label(isReminded ? "Reminder Set" : "Remind Me", systemImage: isReminded ? "bell.fill" : "bell")
    }
}

/// Feature owners provide persistence; hosts provide sizing and focus styling.
struct ReminderButton<Content: View>: View {
    let isReminded: Bool
    let action: () -> Void
    @ViewBuilder let label: (ReminderLabel) -> Content

    var body: some View {
        Button(action: action) { label(ReminderLabel(isReminded: isReminded)) }
    }
}
