"""C10: Claude session-scoped permission updates via updatedPermissions (real CLI, haiku).
Turn1 touch p1 -> allow + addRules(session); Turn2 same command (expect no prompt);
Turn3 touch p2 -> allow + setMode acceptEdits(session); Turn4 touch p3 (expect no prompt);
then a new process with --resume: touch p1 again (expect a prompt: session rules are not persisted)."""
import json, os, sys, time, uuid
from probelib import Claude, WORK

def ask(c, text, perms_fn):
    n = c.n()
    c.user(text)
    prompts = []
    end = time.time() + 120
    while time.time() < end:
        i, m = c.wait_for(lambda m: m.get("type") in ("result", "control_request"), 120, n)
        if m is None:
            break
        n = i + 1
        if m["type"] == "result":
            return prompts, m
        req = m
        prompts.append(req)
        upd = perms_fn(req)
        resp = {"behavior": "allow", "updatedInput": req["request"]["input"]}
        if upd is not None:
            resp["updatedPermissions"] = upd
        c.send({"type": "control_response", "response": {"subtype": "success", "request_id": req["request_id"], "response": resp}})
    raise SystemExit("no result")

for f in ("p1.txt", "p2.txt", "p3.txt"):
    try: os.remove(os.path.join(WORK, f))
    except OSError: pass
sid = str(uuid.uuid4())
c = Claude("C10", extra=["--session-id", sid, "--permission-mode", "default"], quiet=True)
c.init()
rule = lambda req: [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": req["request"]["input"]["command"]}], "behavior": "allow", "destination": "session"}]
mode = lambda req: [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]
out = {}
for name, text, fn in (("t1", "Use the Bash tool to run exactly `touch p1.txt` and then reply done.", rule),
                       ("t2", "Use the Bash tool to run exactly `touch p1.txt` again and then reply done.", lambda r: None),
                       ("t3", "Use the Bash tool to run exactly `touch p2.txt` and then reply done.", mode),
                       ("t4", "Use the Bash tool to run exactly `touch p3.txt` and then reply done.", lambda r: None)):
    prompts, res = ask(c, text, fn)
    out[name] = [(p["request"]["tool_name"], p["request"]["input"].get("command"), p["request"].get("permission_suggestions")) for p in prompts]
    print(name, "prompts:", json.dumps(out[name])[:600], "| result:", str(res.get("result"))[:60])
inits = [m for t, k, m in c.events if k == "out" and isinstance(m, dict) and m.get("subtype") == "init"]
print("permissionMode per turn:", [m["permissionMode"] for m in inits])
c.close_stdin(); print("exit", c.wait_exit(60))
c2 = Claude("C10resume", extra=["--resume", sid, "--permission-mode", "default"], quiet=True)
c2.init()
prompts, res = ask(c2, "Use the Bash tool to run exactly `touch p1.txt` once more and then reply done.", lambda r: None)
print("resume prompts:", json.dumps([(p["request"]["tool_name"], p["request"]["input"].get("command")) for p in prompts]), "| result:", str(res.get("result"))[:60])
c2.close_stdin(); print("exit", c2.wait_exit(60))
