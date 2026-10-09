# S4: plan mode — ExitPlanMode reaches the client for approval.
def handler(m):
    req = m["request"]
    print("   >> request:", json.dumps(req, ensure_ascii=False)[:500])
    respond(m["request_id"], {"behavior": "deny", "message": "Plan rejected from the phone: keep it to one step."})
HANDLER = handler
user("Plan how to create a file named plan.txt containing 'ok'. Keep the plan to two bullet points and present it with ExitPlanMode.")
r = run_until(is_result, timeout=180)
print("result:", ((r or {}).get("result") or "")[:300])
