import SwiftUI

struct RenameSheet: View {
    let session: SessionSummary
    let onSave: (String) -> Void

    var body: some View {
        NameSheet(title: "Rename Session",
                  message: "Sets a new title by appending an ai-title entry. The transcript itself is left untouched, so the session can still be resumed.",
                  placeholder: "Title", initial: session.title, onSave: onSave)
    }
}

/// A one-field sheet for naming something (a session title, a group).
struct NameSheet: View {
    let title: String
    var message: String? = nil
    var placeholder = "Name"
    var actionTitle = "Save"
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(title: String, message: String? = nil, placeholder: String = "Name", initial: String = "",
         actionTitle: String = "Save", onSave: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.actionTitle = actionTitle
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
