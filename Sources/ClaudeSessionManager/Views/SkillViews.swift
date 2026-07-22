import SwiftUI

struct SkillRow: View {
    let skill: SkillInfo

    private var icon: String {
        if skill.isRemote { return "network" }
        if skill.isManaged { return "puzzlepiece.extension.fill" }
        return skill.isSymlink ? "link" : "wand.and.stars"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(skill.isManaged ? Color.accentColor : .secondary)
                Text(skill.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let plugin = skill.pluginName {
                    Text(plugin)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if let host = skill.hostName {
                    Label(host, systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
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

/// Detail pane for a selected skill: header + SKILL.md body, with actions.
struct SkillDetailView: View {
    let skill: SkillInfo
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var bodyText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(skill.name).font(.title3.weight(.semibold))
                    Spacer()
                    if skill.isReadOnly {
                        Button(action: onReveal) { Label("Reveal", systemImage: "folder") }
                    } else {
                        Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                Divider().padding(.vertical, 4)

                Text(bodyText.isEmpty ? "(no content)" : bodyText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .task(id: skill.id) { await load() }
    }

    private var sourceLabel: String {
        switch skill.source {
        case .personal:
            if skill.isSymlink { return "\(skill.folderName)  ·  symlink → \(skill.symlinkTarget ?? "?")" }
            return skill.folderName
        case .plugin(let p):
            return "plugin: \(p)  ·  read-only"
        case .remote(let h):
            return "remote: \(h)  ·  synced mirror, read-only — edit it on the host"
        }
    }

    private func load() async {
        let url = skill.skillFileURL
        let raw = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
        bodyText = Self.stripFrontmatter(raw)
    }

    /// Drop the leading `--- ... ---` block (already shown as name/description).
    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        var idx = 1
        while idx < lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" { idx += 1; break }
            idx += 1
        }
        return lines[idx...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
