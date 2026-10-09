# S5b: interrupt mid-stream (deterministic), then the session keeps working.
user("Write a 1500-word essay about the history of maps. Plain prose, no headings.")
chars = [0]
def streaming(m):
    d = m.get("event", {}).get("delta", {}) if m.get("type") == "stream_event" else {}
    if d.get("type") == "text_delta": chars[0] += len(d.get("text", ""))
    return chars[0] > 400
run_until(streaming, timeout=120)
print("streamed chars before interrupt:", chars[0])
t_int = time.time(); control("interrupt")
r = run_until(is_result, timeout=60)
print(f"result {time.time()-t_int:.1f}s after interrupt: subtype={(r or {}).get('subtype')} is_error={(r or {}).get('is_error')} text_len={len((r or {}).get('result') or '')}")
user("Reply with exactly: STILL HERE")
r2 = run_until(is_result, timeout=120); print("after interrupt:", (r2 or {}).get("result"))
