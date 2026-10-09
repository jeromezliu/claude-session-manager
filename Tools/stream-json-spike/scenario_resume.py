# S6: resume in a fresh process; same transcript file?
user("What were the two words you were asked to reply with most recently? Answer with just those words.")
r = run_until(is_result, timeout=120)
print("resume result:", (r or {}).get("result"), "| session:", (r or {}).get("session_id"))
