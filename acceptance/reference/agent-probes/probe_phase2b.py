"""Phase-2 probes, round 2 (Tern phase 2): does Codex start a turn by itself?

X15wake: a Codex app-server thread (full access) is asked to start a background command that keeps
running after the turn ends. Then nothing is sent for 60 s, and every frame is recorded. A
`turn/started` that answers no `turn/start` would be a turn the harness started by itself.
X15wakeb: same, but asking explicitly for a background terminal that it should check later.
Usage: python3 probe_phase2b.py X15wake|X15wakeb"""
import sys
import time

from probelib import Codex, WORK


def run(name, prompt, idle=60):
    c = Codex(name)
    c.init()
    r = c.thread_start(approvalPolicy="never", sandbox="danger-full-access")
    tid = r["result"]["thread"]["id"]
    rid, cmid = c.turn_start(tid, prompt)
    i, done = c.wait_note("turn/completed", 240)
    print("FIRST TURN DONE at", i, done["params"]["turn"]["status"])
    started_before = sum(1 for _, k, m in c.events if k == "out" and isinstance(m, dict)
                         and m.get("method") == "turn/started")
    t_end = time.time() + idle
    while time.time() < t_end:
        time.sleep(1)
    started_after = sum(1 for _, k, m in c.events if k == "out" and isinstance(m, dict)
                        and m.get("method") == "turn/started")
    print("turn/started before idle:", started_before, "after idle:", started_after)
    print("SELF-STARTED TURNS:", started_after - started_before)
    others = [m.get("method") for _, k, m in c.events[i + 1:] if k == "out" and isinstance(m, dict)]
    print("FRAMES DURING IDLE:", others)
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


def X15wake():
    run("X15wake", "Start the shell command `sleep 15; echo bg-done-42 > bg-done.txt` in the background so it "
                   "keeps running after you reply (for example with `&` or as a background terminal). Do not "
                   "wait for it. Then end your turn right away by replying exactly: started")


def X15wakeb():
    run("X15wakeb", "Use your background terminal support: start `sleep 20; echo bg-done-43` as a long-running "
                    "command, and if your tools let you be notified or resume when it finishes, ask for that. "
                    "Do not wait for it now. Reply exactly: started", idle=75)


if __name__ == "__main__":
    globals()[sys.argv[1]]()
