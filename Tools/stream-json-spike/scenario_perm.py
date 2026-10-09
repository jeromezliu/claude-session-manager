# S2: tool permissions over the stdio control protocol (what the Agent SDK uses).
seen = []
def handler(m):
    req = m["request"]
    seen.append(req)
    print("   >> can_use_tool request keys:", sorted(req.keys()))
    print("   >> request:", json.dumps(req, ensure_ascii=False)[:600])
    if req.get("subtype") == "can_use_tool":
        if "allowed.txt" in json.dumps(req.get("input")):
            respond(m["request_id"], {"behavior": "allow", "updatedInput": req.get("input")})
        else:
            respond(m["request_id"], {"behavior": "deny", "message": "The user declined this from their phone: not that file."})
HANDLER = handler
user("Use the Bash tool to run exactly: echo hi > allowed.txt   Then use the Bash tool to run exactly: echo no > denied.txt   Then tell me what happened to each command in one short sentence.")
r = run_until(is_result, timeout=180)
print("result:", (r or {}).get("result"))
print("permission_denials:", json.dumps((r or {}).get("permission_denials"))[:400])
print("files:", sorted(os.listdir(WORK)))
