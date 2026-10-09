# S7: interrupt while a can_use_tool is unanswered; then change mode mid-session.
pending = []
HANDLER = lambda m: pending.append(m) if m["request"].get("subtype") == "can_use_tool" else None
user("Use the Bash tool to run exactly: echo pending > pending.txt")
run_until(lambda m: m.get("type") == "control_request", timeout=90)
print("got can_use_tool, leaving it unanswered for 3s")
time.sleep(3)
control("interrupt")
r = run_until(lambda m: is_result(m) or m.get("type") in ("control_cancel_request",), timeout=60)
print("first message after interrupt:", (r or {}).get("type"), (r or {}).get("subtype"))
if r and r.get("type") != "result":
    r = run_until(is_result, timeout=60); print("then result:", (r or {}).get("subtype"))
# Mid-session mode change.
rid = control("set_permission_mode", mode="acceptEdits")
ack = run_until(lambda m: m.get("type") == "control_response", timeout=30)
print("set_permission_mode ack:", json.dumps((ack or {}).get("response"))[:200])
HANDLER = lambda m: (print("   >> unexpected prompt for", m["request"].get("tool_name")), respond(m["request_id"], {"behavior":"allow","updatedInput":m["request"].get("input")}))
user("Use the Write tool to create notes.txt containing exactly: accept-edits-ok")
r2 = run_until(is_result, timeout=120)
print("after mode change:", (r2 or {}).get("subtype"), "| notes.txt exists:", os.path.exists(os.path.join(WORK, "notes.txt")))
