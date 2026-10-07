"""X13: codex acceptForSession (real app-server). Thread A: cmd1 -> acceptForSession; cmd1 again (expect no
approval); cmd2 (expect approval) -> accept. Thread B (same process): cmd1 (expect approval) -> decline."""
import json, os, time
from probelib import Codex, WORK

for f in ("s1.txt", "s2.txt"):
    try: os.remove(os.path.join(WORK, f))
    except OSError: pass
c = Codex("X13", quiet=True)
c.init()

def thread():
    return c.thread_start(approvalPolicy="untrusted", sandbox="read-only")["result"]["thread"]["id"]

def turn(tid, cmd, decision):
    n = c.n()
    rid, _ = c.turn_start(tid, "Run exactly this shell command and nothing else: `%s` Then reply done." % cmd)
    reqs = []
    while True:
        i, m = c.wait_for(lambda m: (m.get("method") == "turn/completed") or ("id" in m and "method" in m), 120, n)
        if m is None: raise SystemExit("timeout")
        n = i + 1
        if m.get("method") == "turn/completed":
            cmds = [e[2]["params"]["item"] for e in c.events[:i] if e[1] == "out" and isinstance(e[2], dict)
                    and e[2].get("method") == "item/completed" and e[2]["params"]["item"]["type"] == "commandExecution"
                    and e[2]["params"].get("threadId") == tid]
            return reqs, m["params"]["turn"]["status"], [(x["command"], x["status"]) for x in cmds][-2:]
        reqs.append(m)
        c.respond(m["id"], {"decision": decision})

A = thread()
for cmd, dec in (("echo hi > s1.txt", "acceptForSession"), ("echo hi > s1.txt", "accept"), ("echo hi > s2.txt", "accept")):
    reqs, st, cmds = turn(A, cmd, dec)
    print("A", cmd, "| approvals:", [(r["method"], r["params"].get("command"), json.dumps(r["params"].get("availableDecisions"))) for r in reqs], "|", st, cmds)
B = thread()
reqs, st, cmds = turn(B, "echo hi > s1.txt", "decline")
print("B", "| approvals:", [(r["method"], r["params"].get("command")) for r in reqs], "|", st, cmds)
c.close_stdin(); print("exit", c.wait_exit())
