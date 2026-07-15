import SwiftUI

struct SessionRow: View {
    let session: SessionSummary
    var activity: TerminalActivity? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let activity {
                    ActivityDot(activity: activity)
                }
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }

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

/// Per-session terminal indicator: a solid green dot while a terminal runs,
/// pulsing while Claude is actively producing output.
struct ActivityDot: View {
    @ObservedObject var activity: TerminalActivity
    @State private var animate = false

    var body: some View {
        Group {
            if activity.isRunning {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .scaleEffect(activity.isWorking && animate ? 1.35 : 1.0)
                    .opacity(activity.isWorking && animate ? 0.4 : 1.0)
                    .animation(activity.isWorking
                               ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                               : .easeOut(duration: 0.2),
                               value: animate)
                    .animation(.easeInOut(duration: 0.2), value: activity.isWorking)
                    .onAppear { animate = true }
                    .help(activity.isWorking ? "Claude is working" : "Terminal running")
            }
        }
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
