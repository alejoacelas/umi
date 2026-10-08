"""Phase-2 probes: turns Claude starts by itself, resuming conversations that are gone or were made
in another folder, and project MCP servers in a never-opened folder.
Usage: python3 probe_phase2.py C11wake|C12missing|C12othercwd|C13projectmcp|X14missing"""
import os
import sys
import time
import uuid

from probelib import Claude, Codex, WORK


def finish(c, wait=30):
    c.close_stdin()
    print("EXIT CODE", c.wait_exit(wait))


def C11wake():
    c = Claude("C11wake", extra=["--dangerously-skip-permissions"])
    c.init()
    c.user("Start the shell command `sleep 8; echo done-xyz` as a BACKGROUND command (run_in_background: true). "
           "Do not wait for it. End your turn right away by replying exactly: started")
    i, first = c.wait_result(90)
    print("FIRST RESULT at", i)
    c.wait_result(60, start=i + 1)
    print("SECOND RESULT (a turn nobody sent)")
    time.sleep(2)
    finish(c)


def C12missing():
    c = Claude("C12missing", extra=["--resume", str(uuid.uuid4())])
    try:
        c.init(timeout=20)
        c.user("Reply with exactly: ok")
        c.wait_result(30)
    except Exception as e:  # noqa: BLE001
        print("NO RESULT:", e)
    finish(c)


def C12othercwd():
    a = os.path.join(WORK, "cwd-a")
    b = os.path.join(WORK, "cwd-b")
    os.makedirs(a, exist_ok=True)
    os.makedirs(b, exist_ok=True)
    c = Claude("C12othercwd-1", cwd=a)
    i, init = c.init()
    c.user("Remember the codeword kumquat. Reply with exactly: ok")
    i, res = c.wait_result(60)
    sid = res["session_id"]
    finish(c)
    c2 = Claude("C12othercwd-2", extra=["--resume", sid], cwd=b)
    try:
        c2.init(timeout=20)
        c2.user("What was the codeword? Reply with one word.")
        c2.wait_result(60)
    except Exception as e:  # noqa: BLE001
        print("NO RESULT:", e)
    finish(c2)


def C13projectmcp():
    """A project .mcp.json in a fresh git folder: does headless claude start it without asking?"""
    import json
    import subprocess
    import tempfile
    d = tempfile.mkdtemp(prefix="c13-", dir=WORK)
    subprocess.run(["git", "init", "-q", d])
    with open(os.path.join(d, ".mcp.json"), "w") as f:
        json.dump({"mcpServers": {"probe-srv": {"command": "/usr/bin/true"}}}, f)
    c = Claude("C13projectmcp", extra=["--dangerously-skip-permissions"], cwd=d)
    c.init()
    c.user("Reply with exactly: ok")
    i, init = c.wait_for(lambda m: m.get("type") == "system" and m.get("subtype") == "init", 60)
    print("PROJECT MCP IN INIT:", [s for s in init.get("mcp_servers", []) if not s["name"].startswith("claude.ai")])
    c.wait_result(60)
    finish(c)


def X14missing():
    c = Codex("X14missing")
    c.init()
    print("RESUME MISSING:", c.call("thread/resume", {"threadId": str(uuid.uuid4())}))
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


if __name__ == "__main__":
    globals()[sys.argv[1]]()
