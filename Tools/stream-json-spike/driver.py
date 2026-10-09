#!/usr/bin/env python3
"""P0 spike driver: run one long-lived `claude -p` in stream-json mode, log every
line in/out to a JSONL fixture, and follow a scripted scenario."""
import json, os, subprocess, sys, threading, time, queue, uuid

SCENARIO = sys.argv[1]
OUT = sys.argv[2]                    # fixture path
EXTRA = sys.argv[3:]                 # extra CLI args
WORK = os.path.join(os.path.dirname(__file__), "work")

env = {k: v for k, v in os.environ.items()
       if not (k in ("CLAUDECODE", "AI_AGENT", "BAGGAGE") or k.startswith("CLAUDE_") or k.startswith("ANTHROPIC_"))}
args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--include-partial-messages", "--model", "claude-haiku-4-5-20251001"] + EXTRA
proc = subprocess.Popen(args, cwd=WORK, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, bufsize=1)
log = open(OUT, "w")
lines = queue.Queue()
t0 = time.time()

def reader():
    for line in proc.stdout:
        line = line.strip()
        if not line: continue
        log.write(json.dumps({"t": round(time.time()-t0, 2), "dir": "out", "msg": json.loads(line)}) + "\n"); log.flush()
        lines.put(json.loads(line))
    lines.put(None)
threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=lambda: [sys.stderr.write("STDERR: " + l) for l in proc.stderr], daemon=True).start()

def send(obj):
    log.write(json.dumps({"t": round(time.time()-t0, 2), "dir": "in", "msg": obj}) + "\n"); log.flush()
    proc.stdin.write(json.dumps(obj) + "\n"); proc.stdin.flush()

def user(text):
    send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}})

def control(subtype, **kw):
    rid = "req_" + uuid.uuid4().hex[:8]
    send({"type": "control_request", "request_id": rid, "request": {"subtype": subtype, **kw}})
    return rid

def respond(req_id, response):
    send({"type": "control_response", "response": {"subtype": "success", "request_id": req_id, "response": response}})

def summarize(m):
    t = m.get("type")
    if t == "stream_event":
        e = m.get("event", {}); d = e.get("delta", {})
        return f"stream_event {e.get('type')} {d.get('type','')} {repr(d.get('text',''))[:40] if d.get('text') else ''}"
    if t == "system": return f"system/{m.get('subtype')} session={m.get('session_id')}"
    if t == "assistant":
        return "assistant " + ", ".join(b.get("type") + (":" + b.get("name","") if b.get("type")=="tool_use" else "") for b in m["message"]["content"])
    if t == "user": return "user " + ", ".join(b.get("type") for b in m["message"]["content"] if isinstance(b, dict))
    if t == "result": return f"result {m.get('subtype')} is_error={m.get('is_error')} turns={m.get('num_turns')} cost={m.get('total_cost_usd')}"
    if t == "control_request": return "control_request " + json.dumps(m)[:300]
    if t == "control_response": return "control_response " + json.dumps(m)[:300]
    return t

def run_until(pred, timeout=120):
    """Consume output until pred(msg) is truthy; auto-answers via HANDLER."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try: m = lines.get(timeout=1)
        except queue.Empty: continue
        if m is None: print("<<EOF>>"); return None
        if m.get("type") != "stream_event" or VERBOSE_STREAM: print("  ", summarize(m))
        if m.get("type") == "control_request" and HANDLER: HANDLER(m)
        if pred(m): return m
    print("<<TIMEOUT>>"); return None

VERBOSE_STREAM = False
HANDLER = None
deltas = []
is_result = lambda m: m.get("type") == "result"

exec(open(os.path.join(os.path.dirname(__file__), f"scenario_{SCENARIO}.py")).read())

proc.stdin.close()
try: proc.wait(timeout=20)
except subprocess.TimeoutExpired: proc.kill()
print("exit", proc.returncode)
