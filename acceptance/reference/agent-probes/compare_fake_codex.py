"""Compare fake_codex sequences with real X1/X2accept/X2decline/X3/X10/X12 logs (after thread/start)."""
import json, os, sys, time, tempfile, uuid
from probelib import Codex, LOGS, ROOT
os.environ["FAKE_AGENT_DIR"] = tempfile.mkdtemp()
FAKE = [sys.executable, os.path.join(ROOT, "fake_codex.py"), "app-server", "--listen", "stdio://"]
SKIP = {"item/agentMessage/delta", "thread/tokenUsage/updated", "account/rateLimits/updated", "mcpServer/startupStatus/updated",
        "remoteControl/status/changed", "account/updated", "item/commandExecution/outputDelta", "thread/started",
        "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded", "thread/settings/updated"}

def seq_of(events, start_after_thread=True):
    out, started = [], not start_after_thread
    for t, k, m in events:
        if k != "out" or not isinstance(m, dict): continue
        meth = m.get("method")
        if not started:
            if meth == "thread/started": started = True
            continue
        if meth in SKIP: continue
        if meth in ("item/started", "item/completed"):
            it = m["params"]["item"]
            if it["type"] == "reasoning" or it.get("phase") == "commentary": continue
            out.append("%s:%s%s" % (meth.split("/")[1], it["type"], (":" + it["status"]) if meth == "item/completed" and it.get("status") else ""))
        elif meth == "thread/status/changed":
            st = m["params"]["status"]; out.append("status:%s%s" % (st["type"], st.get("activeFlags", "")))
        elif meth == "turn/completed": out.append("turn/completed:" + m["params"]["turn"]["status"])
        elif meth and "id" in m: out.append("SERVER_REQ:" + meth)
        elif meth: out.append(meth)
        else: out.append("RESP:" + ("error" if "error" in m else ",".join(sorted(m["result"].keys())) or "{}"))
    return out

def real(name):
    return seq_of([(e["t"], e["k"], e["m"]) for e in map(json.loads, open(os.path.join(LOGS, name + ".jsonl")))])

def started(kind): return lambda m: m.get("method") == "item/started" and m["params"]["item"]["type"] == kind
def tc(m): return m.get("method") == "turn/completed"
def sreq(m): return "id" in m and "method" in m

def mk(name, **kw):
    c = Codex(name, cmd=FAKE, quiet=True); c.init()
    p = {"model": "gpt-6-luna", "cwd": os.getcwd(), "approvalPolicy": "never", "sandbox": "workspace-write"}; p.update(kw)
    tid = c.call("thread/start", p)["result"]["thread"]["id"]; return c, tid

def f_x1():
    c, tid = mk("fx1"); rid, _ = c.turn_start(tid, "SLEEP 20"); i, r = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
    c.wait_for(started("commandExecution")); n = c.n(); c.call("turn/interrupt", {"threadId": tid, "turnId": r["result"]["turn"]["id"]})
    c.wait_for(tc, start=n); n = c.n(); c.turn_start(tid, "banana"); c.wait_for(tc, start=n)
    c.call("turn/interrupt", {"threadId": tid, "turnId": r["result"]["turn"]["id"]}); c.close_stdin(); c.wait_exit(); return seq_of(c.events)

def f_x2(dec):
    c, tid = mk("fx2" + dec, approvalPolicy="untrusted", sandbox="read-only"); c.turn_start(tid, "ASK_APPROVAL")
    i, req = c.wait_for(sreq); c.respond(req["id"], {"decision": dec}); c.wait_for(tc); c.close_stdin(); c.wait_exit(); return seq_of(c.events)

def f_x3():
    c, tid = mk("fx3", approvalPolicy="untrusted", sandbox="read-only"); rid, _ = c.turn_start(tid, "ASK_APPROVAL")
    i, r = c.wait_for(lambda m: m.get("id") == rid and "method" not in m); i, req = c.wait_for(sreq)
    c.call("turn/interrupt", {"threadId": tid, "turnId": r["result"]["turn"]["id"]}); c.wait_for(tc); time.sleep(0.3)
    c.respond(req["id"], {"decision": "accept"}); time.sleep(0.3); c.close_stdin(); c.wait_exit(); return seq_of(c.events)

def f_x10():
    c, tid = mk("fx10"); rid, _ = c.turn_start(tid, "SLEEP 1"); i, r = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
    c.wait_for(started("commandExecution")); t = r["result"]["turn"]["id"]
    c.call("turn/steer", {"threadId": tid, "expectedTurnId": "01a10e2a-0000-7000-8000-000000000000", "input": []})
    c.call("turn/steer", {"threadId": tid, "expectedTurnId": t, "clientUserMessageId": str(uuid.uuid4()), "input": [{"type": "text", "text": "kiwi", "text_elements": []}]})
    c.wait_for(tc); c.close_stdin(); c.wait_exit(); return seq_of(c.events)

def f_x12():
    c, tid = mk("fx12", approvalPolicy="untrusted", sandbox="read-only"); c.turn_start(tid, "ASK_APPROVAL")
    i, req = c.wait_for(sreq); c.respond(req["id"], {"decision": "cancel"}); c.wait_for(tc); c.close_stdin(); c.wait_exit(); return seq_of(c.events)

import difflib
for name, fn in (("X1", f_x1), ("X2accept", lambda: f_x2("accept")), ("X2decline", lambda: f_x2("decline")), ("X3", f_x3), ("X10", f_x10), ("X12", f_x12)):
    r, f = real(name), fn()
    print("=== %s  %s" % (name, "IDENTICAL" if r == f else "DIFFERENT"))
    if r != f:
        for l in difflib.unified_diff(r, f, "real", "fake", lineterm="", n=1): print("   ", l)
