import SwiftUI

struct SessionRow: View {
    let session: SessionSummary
    // Observe the manager directly so the indicator appears/disappears even when
    // the AppKit-backed sidebar List reuses this (otherwise unchanged) row.
    @ObservedObject private var terminals = TerminalManager.shared

    private var activity: TerminalActivity? {
        terminals.session(for: session.id)?.activity
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Fixed-width gutter so every row's text aligns, dot or not.
            ZStack {
                if let activity {
                    ActivityDot(activity: activity)
                }
            }
            .frame(width: 8)
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                if let prompt = (session.lastPrompt ?? session.firstPrompt), prompt != session.title {
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Label("\(session.messageCount)", systemImage: "bubble.left.and.bubble.right")
                    if let branch = session.gitBranch, branch != "HEAD" {
                        Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                    }
                    if session.totalOutputTokens > 0 {
                        Label(Fmt.tokens(session.totalOutputTokens), systemImage: "cpu")
                    }
                    if let host = session.remoteDisplayName {
                        Label(host, systemImage: "network").lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.relative(session.modifiedAt))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
        .help("Last modified \(Fmt.full(session.modifiedAt))")
    }
}

/// Per-session terminal indicator: a solid green dot while a terminal runs,
/// pulsing while Claude is actively producing output.
struct ActivityDot: View {
    @ObservedObject var activity: TerminalActivity
    @State private var pulse = false

    var body: some View {
        Group {
            if activity.isRunning {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.25 : 1.0)
                    .opacity(pulse ? 0.3 : 1.0)
                    .shadow(color: .green.opacity(pulse ? 0.9 : 0.0), radius: pulse ? 3.5 : 0)
                    .help(activity.isWorking ? "Claude is working" : "Terminal running")
            }
        }
        .onAppear { updatePulse(activity.isWorking) }
        .onChange(of: activity.isWorking) { updatePulse($0) }
        .onChange(of: activity.isRunning) { _ in updatePulse(activity.isWorking) }
    }

    private func updatePulse(_ working: Bool) {
        if working {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
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
                if let host = entry.remoteDisplayName {
                    Label(host, systemImage: "network").lineLimit(1)
                }
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
