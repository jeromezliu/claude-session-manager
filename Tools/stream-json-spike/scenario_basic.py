# S1: two turns in one long-lived process, token streaming, session id.
user("Reply with exactly: ALPHA")
n_deltas = [0]
def count(m):
    if m.get("type") == "stream_event" and m.get("event", {}).get("delta", {}).get("type") == "text_delta": n_deltas[0] += 1
    return is_result(m)
r1 = run_until(count)
print("turn1 text_deltas:", n_deltas[0], "| result:", (r1 or {}).get("result"), "| session:", (r1 or {}).get("session_id"))
user("Now reply with exactly: BETA")
r2 = run_until(is_result)
print("turn2 result:", (r2 or {}).get("result"), "| same session:", (r1 or {}).get("session_id") == (r2 or {}).get("session_id"))
open(os.path.join(os.path.dirname(__file__), "last_session"), "w").write((r2 or {}).get("session_id", ""))
