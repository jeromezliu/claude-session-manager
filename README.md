# Claude Session Manager

A native macOS (SwiftUI) app to browse and manage your local Claude Code
sessions — the `.jsonl` transcripts stored under `~/.claude/projects`.

Inspired by [universal-session-viewer](https://github.com/tad-hq/universal-session-viewer),
but a genuinely native Mac app rather than a web viewer.

![Claude Session Manager](docs/screenshot.png)

> The screenshot uses mock data. Regenerate it with `swift docs/make-screenshot.swift docs/screenshot.png`.

## Install

### Homebrew (recommended)

```sh
brew tap jeromezliu/tap
brew install --cask claude-session-manager
```

Homebrew verifies the download's checksum and strips the quarantine flag, so the
app launches without a Gatekeeper prompt. If Homebrew asks you to trust the tap
on first use, run `brew trust jeromezliu/tap`.

Update or remove later:

```sh
brew upgrade --cask claude-session-manager
brew uninstall --cask claude-session-manager
```

### Manual download

Grab the latest `.zip` from the
[Releases](https://github.com/jeromezliu/claude-session-manager/releases) page,
unzip it, and move `ClaudeSessionManager.app` to `/Applications`. The app is
ad-hoc signed (not notarized), so on first launch **right-click → Open** (or run
`xattr -dr com.apple.quarantine /Applications/ClaudeSessionManager.app`).

### Build from source

```sh
git clone https://github.com/jeromezliu/claude-session-manager
cd claude-session-manager
./build.sh run      # build (release), package the .app, and launch
```

`./build.sh` alone builds and packages to `build/ClaudeSessionManager.app`;
`./build.sh debug` makes a debug build.

## Requirements

- macOS 13 (Ventura) or later
- The `claude` CLI on your `PATH` — required for the **Continue** feature
- To build from source: the Swift toolchain (Xcode or Command Line Tools)

## Features

- **Browse & search** — sessions grouped by project, ordered by most recent
  conversation. Live search across titles, prompts, paths, and branches.
- **Multi-select** — ⌘/⇧-click to select several sessions and move them to the
  Trash in one go.
- **Transcript viewer** — newest turns first, with attachments / tool calls /
  system events hidden by default (toggle the eye icon to show them). Each turn
  shows text, thinking, and collapsible tool calls/results.
- **Token usage** — a header chip shows context usage vs the model's window
  (e.g. `context 89.1k/1M · 45%`), read from Claude's own per-turn usage.
  Window is configurable (Auto / 200K / 1M) in the ⋯ menu.
- **Continue in an embedded terminal** — resumes the session in an in-app
  terminal (via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)): a
  PTY-backed login shell opens in the session's `cwd` and runs
  `claude --resume <id>`. It sits in a split below the transcript; **pop it out**
  to a floating window or **expand** it full-height, and dock it back.
  "Open in Terminal.app" is also available from the context menu.
- **New session** — start a fresh `claude` session in any folder right from the
  app (➕ toolbar button, with a remembered default directory).
- **Activity indicator** — a pulsing dot marks sessions whose terminal is
  actively producing output.
- **App-managed Trash** — deleting moves the `.jsonl` to an in-app trash
  (`~/Library/Application Support/ClaudeSessionManager/Trash`). Recover it to its
  original location, delete permanently, or empty the trash — from the Trash tab.
- **Rename** — set a session title safely by appending an `ai-title` event
  (exactly what Claude Code does); the message history is never rewritten, so
  the session still resumes correctly.
- **Auto-refresh** — the list and open transcript update live as sessions change
  on disk; no need to relaunch.
- **Hides temp sessions** — throwaway sessions tools spawn in `$TMPDIR` (e.g.
  Claude's `claude-analysis-<uuid>` logs) are hidden by default, with a
  *Show temporary sessions* toggle and a "N hidden" note in the footer.
- **Configurable scan folder** — defaults to `~/.claude/projects`; point it at
  any folder and it finds every `.jsonl` beneath it. Remembered across launches.

## Project layout

```
Sources/ClaudeSessionManager/
  App/       @main entry, window, menus
  Models/    SessionSummary, TranscriptEvent, TrashEntry (Sendable value types)
  Store/     SessionParser  – JSONL → summaries / transcript
             SessionStore   – scans root, holds state, mutations, auto-refresh
             SummaryCache    – mtime/size-keyed parse cache
             TrashManager    – app-managed trash (move / recover / purge)
  Terminal/  TerminalSession, TerminalManager, TerminalActivity (SwiftTerm)
  Util/      SessionActions, Formatters, FileWatcher, DirectoryWatcher
  Views/     ContentView (2-pane split), SessionRow, TranscriptView,
             TerminalViews, RenameSheet
Icon/        GenerateIcon.swift (CoreGraphics app-icon generator)
docs/        make-screenshot.swift (README screenshot renderer)
```

## Notes on the session format

Each session is a JSONL file; every line is a typed event. The app reads
`user`, `assistant`, `attachment`, and `system` events, plus metadata lines
(`ai-title`, `last-prompt`, `mode`, `permission-mode`). The real working
directory and git branch come from `cwd` / `gitBranch` on message lines — the
encoded folder name is ambiguous because path segments can contain `-`.

One important detail the app relies on: the embedded terminal strips inherited
`CLAUDECODE` / `CLAUDE_CODE_*` / `ANTHROPIC_*` environment variables before
launching `claude`, so the resumed session runs as a normal top-level session
and persists its transcript (a nested/child session would not).
