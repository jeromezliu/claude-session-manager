#!/usr/bin/env python3
"""Make recorded stream-json fixtures safe to commit (the repo is public):
replace local paths with placeholders and reduce account/environment details
(installed plugins, MCP servers, skills, org settings) to counts."""
import json, os, re, sys

HOME = os.path.expanduser("~")
WORK = os.path.realpath(sys.argv[1])          # the spike's working directory
SECRET_LISTS = ("agents", "mcp_servers", "plugins", "skills", "slash_commands",
                "terminal_slash_commands", "tools", "memory_paths")

def scrub(s: str) -> str:
    s = s.replace(WORK, "/tmp/csm-spike/work").replace(WORK.replace("/private", "", 1), "/tmp/csm-spike/work")
    s = s.replace(HOME, "/Users/me")
    return re.sub(r"/private/tmp/claude-\d+/[^\s\"']*", "/tmp/scratch", s)

def walk(o):
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            if k in SECRET_LISTS and isinstance(v, (list, dict)):
                out[k] = f"<{len(v)} redacted>"
            elif k in ("messaging_socket_path", "apiKeySource", "overageDisabledReason", "signature"):
                out[k] = "<redacted>"
            # Streamed fragments can split a path across chunks, so string
            # scrubbing can't catch them; the complete input/thinking is in the
            # (scrubbed) assistant message anyway.
            elif k == "partial_json" and isinstance(v, str):
                out[k] = "<json chunk>"
            elif k == "thinking" and isinstance(v, str):
                out[k] = "<thinking>"
            else:
                out[k] = walk(v)
        return out
    if isinstance(o, list): return [walk(v) for v in o]
    if isinstance(o, str): return scrub(o)
    return o

for path in sys.argv[2:]:
    rows = [walk(json.loads(l)) for l in open(path)]
    dest = os.path.join(sys.argv[-1] if os.path.isdir(sys.argv[-1]) else ".", os.path.basename(path))
    with open(path, "w") as f:
        for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
