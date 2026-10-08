"""Run C1/C3int/C9-equivalent scenarios against fake_claude and print type sequences next to the real ones.
Also C11wake (WAKE: a turn the CLI starts by itself; task frames and shapes too), C12missing (--resume of an
unknown id) and C12othercwd-1/-2 (resume from another folder)."""
import json, os, sys, time, tempfile, uuid
from probelib import Claude, LOGS, ROOT
os.environ["FAKE_AGENT_DIR"] = tempfile.mkdtemp()
FAKE = [sys.executable, os.path.join(ROOT, "fake_claude.py")] + Claude.BASE[1:]

def seq_of(events, tasks=False):
    skip = ("thinking_tokens",) if tasks else ("thinking_tokens", "task_started", "task_notification")
    out = []
    for t, k, m in events:
        if k != "out" or not isinstance(m, dict): continue
        ty = m.get("type")
        if ty in ("rate_limit_event",) or (ty == "system" and m.get("subtype") in skip): continue
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

def real_events(name):
    return [(e["t"], e["k"], e["m"]) for e in map(json.loads, open(os.path.join(LOGS, name + ".jsonl")))]

def real(name, tasks=False):
    return seq_of(real_events(name), tasks)

def shapes(events):
    """Key sets of the frames WAKE adds (C11wake), plus the self-started result's origin."""
    out = {}
    for t, k, m in events:
        if k != "out" or not isinstance(m, dict): continue
        if m.get("type") == "system" and m.get("subtype") in ("task_started", "task_notification", "task_updated", "background_tasks_changed"):
            out.setdefault(m["subtype"], sorted(m))
            if m.get("tasks"): out["background_tasks_changed.tasks[0]"] = sorted(m["tasks"][0])
        elif m.get("type") == "user" and isinstance(m.get("tool_use_result"), dict) and "backgroundTaskId" in m["tool_use_result"]:
            out["tool_use_result"] = sorted(m["tool_use_result"])
            out["tool_result.text"] = m["message"]["content"][0]["content"].split(":")[0]
        elif m.get("type") == "result" and "origin" in m:
            out["result.origin"] = sorted(m["origin"])
            out["result.origin.kind"] = [m["origin"]["kind"], m["origin"]["producer"]]
            out["result.has_user_message_uuid"] = ["user_message_uuid" in m]
        elif m.get("type") == "system" and m.get("subtype") == "init" and m.get("mcp_servers"):
            out["init.mcp_servers[0]"] = sorted(m["mcp_servers"][0])
    return out

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

def fake_c11wake():
    os.environ["FAKE_MCP"] = "claude.ai Gmail:connected"
    try:
        c = Claude("fake_C11wake", cmd=FAKE + ["--dangerously-skip-permissions"], quiet=True)
    finally:
        del os.environ["FAKE_MCP"]
    c.init(); c.user("WAKE 2 done-xyz"); i, _ = c.wait_result(10); c.wait_result(10, start=i + 1)
    time.sleep(0.3); c.close_stdin(); c.wait_exit(10)
    return c.events

def fake_c12missing():
    c = Claude("fake_C12missing", cmd=FAKE + ["--resume", str(uuid.uuid4())], quiet=True)
    c.init(timeout=2); c.wait_result(5); rc = c.wait_exit(10)
    return seq_of(c.events), rc, [m for t, k, m in c.events if k == "err"]

def fake_c12othercwd():
    a, b = tempfile.mkdtemp(), tempfile.mkdtemp()
    c = Claude("fake_C12othercwd-1", cmd=FAKE, cwd=a, quiet=True); c.init(); c.user("remember kumquat")
    i, res = c.wait_result(10); c.close_stdin(); c.wait_exit(10)
    c2 = Claude("fake_C12othercwd-2", cmd=FAKE + ["--resume", res["session_id"]], cwd=b, quiet=True); c2.init(); c2.user("RECALL")
    i, res2 = c2.wait_result(10); c2.close_stdin(); c2.wait_exit(10)
    assert "kumquat" in res2["result"] and res2["session_id"] == res["session_id"], res2
    return seq_of(c.events), seq_of(c2.events)

def report(name, r, f):
    print("=== %s  %s" % (name, "IDENTICAL" if r == f else "DIFFERENT"))
    if r != f:
        import difflib
        for l in difflib.unified_diff(r, f, "real", "fake", lineterm="", n=1): print("   ", l)

for name, fn in (("C1", fake_c1), ("C2", fake_c2), ("C3int", fake_c3int), ("C9", fake_c9)):
    report(name, real(name), fn())

ev = fake_c11wake()
report("C11wake", real("C11wake"), seq_of(ev))
report("C11wake (with task_started/task_notification)", real("C11wake", tasks=True), seq_of(ev, tasks=True))
rs, fs = shapes(real_events("C11wake")), shapes(ev)
for key in sorted(set(rs) | set(fs)):
    if rs.get(key) != fs.get(key):
        print("    shape %-36s real=%s fake=%s" % (key, rs.get(key), fs.get(key)))
print("    shapes compared: %d keys, %d differ" % (len(set(rs) | set(fs)), sum(rs.get(k) != fs.get(k) for k in set(rs) | set(fs))))

seq, rc, err = fake_c12missing()
report("C12missing", real("C12missing"), seq)
real_err = [m for t, k, m in real_events("C12missing") if k == "err"]
print("    exit real=1 fake=%s; stderr real=%r fake=%r" % (rc, [e.split(":")[0] for e in real_err], [e.split(":")[0] for e in err]))

s1, s2 = fake_c12othercwd()
report("C12othercwd-1", real("C12othercwd-1"), s1)
report("C12othercwd-2", real("C12othercwd-2"), s2)
