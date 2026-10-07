"""Run C1/C3int/C9-equivalent scenarios against fake_claude and print type sequences next to the real ones."""
import json, os, sys, time, tempfile
from probelib import Claude, LOGS, ROOT
os.environ["FAKE_AGENT_DIR"] = tempfile.mkdtemp()
FAKE = [sys.executable, os.path.join(ROOT, "fake_claude.py")] + Claude.BASE[1:]

def seq_of(events):
    out = []
    for t, k, m in events:
        if k != "out" or not isinstance(m, dict): continue
        ty = m.get("type")
        if ty in ("rate_limit_event",) or (ty == "system" and m.get("subtype") in ("thinking_tokens", "task_started", "task_notification")): continue
        if ty == "assistant":
            c = m["message"]["content"][0]["type"]
            if c == "thinking": continue
            out.append("assistant:" + c)
        elif ty == "user":
            c = m["message"]["content"]
            out.append("user:" + ("replay" if m.get("isReplay") else (c[0]["type"] if isinstance(c, list) else "text")))
        elif ty == "system": out.append("sys:" + (m.get("state") or m["subtype"]))
        elif ty == "command_lifecycle": out.append("lc:" + m["state"])
        elif ty == "control_response": out.append("ctl_resp")
        elif ty == "control_request": out.append("ctl_req:" + m["request"]["subtype"])
        elif ty == "result": out.append("result:" + m["subtype"])
        else: out.append(ty)
    return out

def real(name):
    ev = []
    for l in open(os.path.join(LOGS, name + ".jsonl")):
        e = json.loads(l); ev.append((e["t"], e["k"], e["m"]))
    return seq_of(ev)

def is_tool(m): return m.get("type") == "assistant" and m["message"]["content"][0]["type"] == "tool_use"

def fake_c1():
    c = Claude("fake_C1", cmd=FAKE, auto_allow=True, quiet=True); c.init(); c.user("SLEEP 20")
    c.wait_for(is_tool, 10); time.sleep(0.5); c.control("interrupt", rid="int1"); c.wait_result(10)
    n = c.n(); c.user("banana"); c.wait_result(10, start=n); c.close_stdin(); c.wait_exit(10); return seq_of(c.events)

def fake_c3int():
    c = Claude("fake_C3int", cmd=FAKE, quiet=True); c.init(); c.user("ASK_PERMISSION")
    i, req = c.wait_for(lambda m: m.get("type") == "control_request", 10); c.control("interrupt", rid="int1")
    c.wait_result(10); time.sleep(0.3); c.reply_perm(req, True); time.sleep(0.3); c.close_stdin(); c.wait_exit(10); return seq_of(c.events)

def fake_c9():
    c = Claude("fake_C9", cmd=FAKE, auto_allow=True, quiet=True); c.init(); c.user("SLEEP 1")
    c.wait_for(is_tool, 10); c.user("also banana"); c.wait_result(10); c.close_stdin(); c.wait_exit(10); return seq_of(c.events)

def fake_c2():
    c = Claude("fake_C2", cmd=FAKE, auto_allow=True, quiet=True); c.init(); c.user("SLEEP 20")
    c.wait_for(is_tool, 10); c.user("banana"); time.sleep(0.3); c.control("interrupt", rid="int1"); c.wait_result(10)
    i, _ = c.wait_result(10); n = c.n(); c.wait_result(10, start=i + 1); c.close_stdin(); c.wait_exit(10); return seq_of(c.events)

for name, fn in (("C1", fake_c1), ("C2", fake_c2), ("C3int", fake_c3int), ("C9", fake_c9)):
    r, f = real(name), fn()
    print("=== %s  %s" % (name, "IDENTICAL" if r == f else "DIFFERENT"))
    if r != f:
        import difflib
        for l in difflib.unified_diff(r, f, "real", "fake", lineterm="", n=1): print("   ", l)
