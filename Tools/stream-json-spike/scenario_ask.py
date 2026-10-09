# S3: AskUserQuestion — does it reach the client, and how is an answer returned?
def handler(m):
    req = m["request"]
    print("   >> request:", json.dumps(req, ensure_ascii=False)[:900])
    if req.get("tool_name") == "AskUserQuestion":
        inp = dict(req["input"])
        q = inp["questions"][0]
        # Agent SDK convention: allow with updatedInput carrying `answers` {question text: chosen label}.
        inp["answers"] = {q["question"]: q["options"][1]["label"]}
        respond(m["request_id"], {"behavior": "allow", "updatedInput": inp})
    else:
        respond(m["request_id"], {"behavior": "allow", "updatedInput": req.get("input")})
HANDLER = handler
user("Use the AskUserQuestion tool to ask me which fruit I prefer, with exactly two options: Apple and Banana. After I answer, reply with only the fruit I picked, in capitals.")
r = run_until(is_result, timeout=180)
print("result:", (r or {}).get("result"))
