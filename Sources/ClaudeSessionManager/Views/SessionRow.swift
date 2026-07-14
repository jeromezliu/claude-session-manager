import SwiftUI

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.body.weight(.medium))
                .lineLimit(2)

            if let prompt = session.firstPrompt, prompt != session.title {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Label("\(session.messageCount)", systemImage: "bubble.left.and.bubble.right")
                if let branch = session.gitBranch, branch != "HEAD" {
                    Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                }
                if session.totalOutputTokens > 0 {
                    Label(Fmt.tokens(session.totalOutputTokens), systemImage: "cpu")
                }
                Spacer()
                Text(Fmt.relative(session.modifiedAt))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 3)
        .help("Last modified \(Fmt.full(session.modifiedAt))")
    }
}

struct TrashRow: View {
    let entry: TrashEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.summary.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            Text(entry.originalFolder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 8) {
                Label("\(entry.summary.messageCount)", systemImage: "bubble.left.and.bubble.right")
                Spacer()
                Label("deleted \(Fmt.relative(entry.deletedAt))", systemImage: "trash")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 3)
        .help("Original: \(entry.originalPath)")
    }
}

/// Minimal stand-in for `ContentUnavailableView` so the app also builds on macOS 13.
struct ContentUnavailableView_Compat: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
