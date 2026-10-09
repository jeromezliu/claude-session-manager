# P0 — Driving Claude Code headless for the remote host

Spike results for the phone remote (plan B: ClaudeSessionManager hosts, an iOS
app connects over LAN/VPN). Verified against **Claude Code 2.1.231** on
2026-10-10 with `claude-haiku-4-5`. Recorded, sanitized sessions live in
`Tests/ClaudeSessionManagerTests/Fixtures/StreamJSON/` and are pinned by
`StreamJSONContractTests`; the driver that recorded them is in
`Tools/stream-json-spike/`.

## Decision

One long-lived process per active session:

```sh
claude -p --input-format stream-json --output-format stream-json --verbose \
       --include-partial-messages --permission-prompt-tool stdio \
       [--resume <session-id>] [--permission-mode default|acceptEdits|plan] [--model …]
```

Permissions, `AskUserQuestion` and `ExitPlanMode` all arrive as **stdio control
requests** — the same channel the official Agent SDK uses for `canUseTool`. So:

- no MCP permission server (cui's approach) and no PreToolUse-hook detour;
- no Node/Python sidecar: the host speaks the protocol directly from Swift;
- no TUI scraping, no process-per-turn.

Run the child with the inherited `CLAUDECODE` / `CLAUDE_*` / `ANTHROPIC_*`
variables removed (as the embedded terminal already does), or it behaves as a
nested session.

## What was verified

| # | Question | Result |
|---|---|---|
| S1 | Several turns in one process, token streaming | ✅ Same `session_id` across turns; text arrives as `stream_event` → `content_block_delta` / `text_delta` |
| S2 | Tool approval over stdio | ✅ `control_request` / `can_use_tool`; allow runs the tool, deny's `message` reaches Claude and shows in `result.permission_denials` |
| S3 | `AskUserQuestion` to the client and back | ✅ Arrives as `can_use_tool` with `requires_user_interaction: true`; answered by allow + `updatedInput.answers` |
| S4 | `ExitPlanMode` (plan mode) | ✅ Arrives with `input.plan` (Markdown) and `planFilePath`; deny's message reaches Claude |
| S5 | Interrupt mid-turn | ✅ `control_request` / `interrupt` ends the turn at once (`result` `error_during_execution`); the process keeps serving the next message |
| S5 | Message sent while busy | ✅ Queued and processed in order (the interrupt ack even reports `still_queued`) |
| S6 | `--resume` in a new process | ✅ Remembers the conversation; appends to the **same** `~/.claude/projects/<folder>/<id>.jsonl` |
| S7 | Interrupt while a `can_use_tool` is unanswered | ✅ The CLI sends `control_cancel_request` `{"request_id": <the open request>}`, records the tool as rejected and ends the turn |
| S7 | Change permission mode mid-session | ✅ `control_request` / `set_permission_mode` `{"mode":"acceptEdits"}` → ack `{"mode":"acceptEdits"}`; the next Write ran without a prompt |

## Wire format

Every line is one JSON object.

**Host → claude (stdin)**

```jsonc
// a user turn (text and/or image blocks)
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}

// answer a can_use_tool request
{"type":"control_response","response":{"subtype":"success","request_id":"<from request>",
  "response":{"behavior":"allow","updatedInput":{…}}}}
{"type":"control_response","response":{"subtype":"success","request_id":"<from request>",
  "response":{"behavior":"deny","message":"why — Claude reads this"}}}

// interrupt the running turn (host-chosen request_id)
{"type":"control_request","request_id":"req_…","request":{"subtype":"interrupt"}}

// switch permission mode for the following tool calls
{"type":"control_request","request_id":"req_…","request":{"subtype":"set_permission_mode","mode":"acceptEdits"}}
```

**claude → host (stdout)** — types seen across the fixtures:

| type / subtype | Use on the host |
|---|---|
| `system/init` | Once per turn. `session_id`, `claude_code_version` (version check), `model`, `permissionMode`, `tools`, `slash_commands` (offer on the phone) |
| `system/status` | `status: "requesting"` etc. → "working…" indicator |
| `system/thinking_tokens` | Frequent; ignore or show a thinking indicator |
| `stream_event` | Raw API stream: `message_start`, `content_block_start/stop`, `content_block_delta` with `text_delta` (live text), `thinking_delta`, `input_json_delta` (a tool call's input as it's written), `message_delta/stop` |
| `assistant` | The complete message per content block (`thinking`, `text`, `tool_use`) — authoritative over the deltas |
| `user` | Tool results (`tool_result`); `"[Request interrupted by user]"` after an interrupt |
| `control_request/can_use_tool` | Approval / question — see below |
| `control_response` | Ack of a host request (interrupt → `{"still_queued":[…]}`) |
| `control_cancel_request` | `{"request_id": …}` — the CLI withdrew an open `can_use_tool` (e.g. after an interrupt); drop it from every client |
| `rate_limit_event` | `rate_limit_info.status`, `rateLimitType` (`five_hour`), `resetsAt` → quota badge on the phone |
| `result` | End of a turn: `subtype` (`success`, `error_during_execution`), `result` text, `num_turns`, `total_cost_usd`, `permission_denials`, `session_id` |

**`can_use_tool` request**

```jsonc
{"type":"control_request","request_id":"129a8edc-…","request":{
  "subtype":"can_use_tool",
  "tool_name":"Bash", "display_name":"Bash",
  "input":{"command":"echo hi > allowed.txt","description":"Write \"hi\" to allowed.txt"},
  "description":"Write \"hi\" to allowed.txt",     // ready-made sentence for the sheet
  "tool_use_id":"toolu_…",                          // idempotency key (with the session id)
  "permission_suggestions":[                        // "always allow" rules the CLI proposes
    {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo hi *"}],
     "behavior":"allow","destination":"localSettings"},
    {"type":"addDirectories","directories":["…"], …}],
  "blocked_path":"…",                               // when a path is outside allowed dirs
  "requires_user_interaction":true                  // AskUserQuestion / ExitPlanMode only
}}
```

- **AskUserQuestion**: `input.questions[]` = `{question, header, options[{label, description}], multiSelect}`.
  Answer: allow with `updatedInput` = the original input plus `"answers": {"<question text>": "<label>"}`.
- **ExitPlanMode**: `input.plan` (Markdown) and `input.planFilePath`. Allow = approve the plan; deny with a
  message = keep planning with that feedback.

## How this shapes P1

- **Session actor** (one per running session) owns the process, stdin and a sequenced event log; the phone and
  the Mac UI are both just subscribers. The JSONL file stays the source of truth; live events are an overlay.
- **Pending requests table** keyed by `session_id + tool_use_id`: survives client reconnects, resolved exactly
  once, cancelled on `control_cancel_request` (S7) — and, defensively, when its turn's `result` arrives or the
  process exits. "Always allow" uses `permission_suggestions` as-is.
- **Mode / model switches from the phone** go through control requests on the live process, not a restart.
- **User input while a request is pending** is queued by the host (not written to stdin) until the request is
  answered — so a message never silently overrides an approval.
- **Startup check**: read `claude_code_version` from `system/init`; re-record fixtures after an upgrade.
- **Busy detection** for sessions the host doesn't own: `~/.claude/sessions/<pid>.json` + pid liveness → the
  phone shows those read-only.

## Open items (not verified yet)

- What happens to a pending `can_use_tool` if the host never answers — does the CLI time out? (Design: the host
  never lets it hang silently; it stays visible on every client until answered or the turn is interrupted.)
- Images in a user turn (`{"type":"image","source":{…}}` blocks) — expected to work as in the API, untested.
- Changing the **model** mid-session (`set_model` control request in the SDK) — permission mode is verified, model isn't.
- Two writers: a session resumed by the host while also open in a terminal / the desktop app. P1 avoids it by
  refusing to drive a session that's busy elsewhere.
