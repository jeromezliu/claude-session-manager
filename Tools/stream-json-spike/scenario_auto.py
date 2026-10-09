# S8: auto mode — which tool calls still reach the client?
asked = []
def handler(m):
    req = m["request"]
    asked.append(req.get("tool_name"))
    print("   >> can_use_tool:", req.get("tool_name"), json.dumps(req.get("input"), ensure_ascii=False)[:120])
    if req.get("tool_name") == "AskUserQuestion":
        inp = dict(req["input"]); q = inp["questions"][0]
        inp["answers"] = {q["question"]: q["options"][0]["label"]}
        respond(m["request_id"], {"behavior": "allow", "updatedInput": inp})
    else:
        respond(m["request_id"], {"behavior": "allow", "updatedInput": req.get("input")})
HANDLER = handler
user("Do these in order: 1) Use the Write tool to create auto.txt containing 'hi'. 2) Use the Bash tool to run exactly: rm -rf ./work-nonexistent-dir-xyz  3) Use the AskUserQuestion tool to ask me Apple or Banana (two options). Then reply with only my choice.")
r = run_until(is_result, timeout=240)
print("result:", (r or {}).get("result"), "| reached client:", asked)
