import SwiftUI

struct SkillRow: View {
    let skill: SkillInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: skill.isSymlink ? "link" : "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(skill.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .help(skill.symlinkTarget.map { "→ \($0)" } ?? skill.entryURL.path)
    }
}

/// Detail pane for a selected skill: header + full SKILL.md, with actions.
struct SkillDetailView: View {
    let skill: SkillInfo
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var content = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name).font(.title3.weight(.semibold)).lineLimit(2)
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                            .help("Open SKILL.md in your editor")
                        Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
                    }
                }
                FlowChips(chips: chips)
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(content.isEmpty ? "(empty)" : content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .task(id: skill.id) { await load() }
    }

    private var chips: [String] {
        var c = [skill.folderName]
        if skill.isSymlink { c.append("symlink") }
        if let t = skill.symlinkTarget { c.append(t) }
        return c
    }

    private func load() async {
        let url = skill.skillFileURL
        content = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
    }
}

struct NewSkillSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Skill").font(.headline)
            Text("Creates ~/.claude/skills/<name>/SKILL.md with a template you can edit.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Skill name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}
