"""Phase-3 probes (agent sessions redone): headless <-> live handoffs and hooks.

X16shared: a private `codex app-server --listen unix://SOCK`; Tern-like client A talks to it through
  `codex app-server proxy --sock SOCK`. A turn runs; then Codex's own TUI attaches with
  `codex resume THREAD --remote unix://SOCK` in a pty. A starts another turn while the TUI is
  attached (does the TUI show it?), then the TUI's user types a prompt (does A see that turn?),
  then the TUI exits (does the server keep the thread for A?).
C14handoff: `claude -p` stream-json turn with --session-id; then the TUI `claude --resume ID` in a pty
  with a probe plugin (--plugin-dir) whose hooks append their stdin to a file; a prompt is typed;
  the TUI is ended with SIGTERM while idle; then `claude -p --resume ID` continues with context.
Usage: python3 probe_phase3.py X16shared|C14handoff"""
import json
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

from probelib import Claude, Codex, LOGS, Proc

BASE = "/tmp/tern-probe"
WORK3 = os.environ.get("PROBE_WORK") or os.path.join(BASE, "work")
os.makedirs(WORK3, exist_ok=True)

ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]")


class Pty(object):
    """A program in a pseudo-terminal; everything it prints is kept (raw and without escapes)."""

    def __init__(self, argv, name, cwd, env=None, rows=40, cols=140):
        self.name = name
        self.raw = bytearray()
        self.lock = threading.Lock()
        self.t0 = time.time()
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            import fcntl, termios, struct
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            os.execvpe(argv[0], argv, env or os.environ)
        self.pid, self.fd = pid, fd
        import fcntl, termios, struct
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.log = open(os.path.join(LOGS, name + ".pty"), "wb")
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            try:
                r, _, _ = select.select([self.fd], [], [], 0.5)
                if not r:
                    if self.exited():
                        return
                    continue
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            with self.lock:
                self.raw += data
            # Answer cursor-position and device-attribute queries like a terminal would.
            if b"\x1b[6n" in data:
                os.write(self.fd, b"\x1b[1;1R")
            if b"\x1b[c" in data or b"\x1b[0c" in data:
                os.write(self.fd, b"\x1b[?62;22c")
            if b"\x1b]10;?" in data:
                os.write(self.fd, b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
            if b"\x1b]11;?" in data:
                os.write(self.fd, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
            self.log.write(data)
            self.log.flush()

    def text(self):
        with self.lock:
            return ANSI.sub(b"", bytes(self.raw)).decode("utf-8", "replace")

    def type(self, s, enter=True):
        os.write(self.fd, s.encode())
        if enter:
            time.sleep(0.3)
            os.write(self.fd, b"\r")

    def wait_text(self, needle, timeout=60, after=0):
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.text()[after:]:
                return True
            time.sleep(0.3)
        return False

    def exited(self):
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            return pid != 0
        except ChildProcessError:
            return True

    def kill(self, sig=signal.SIGTERM):
        try:
            os.kill(self.pid, sig)
        except ProcessLookupError:
            pass


class WSCodex(Codex):
    """Codex app-server client over a WebSocket on a unix socket (what `--listen unix://` speaks)."""

    def __init__(self, name, sock):
        import socket as _s, base64
        self.nid = 0
        self.auto_decision = None
        self.name = name
        self.t0 = time.time()
        self.events = []
        self.cond = threading.Condition()
        self.quiet = False
        self.filt = None
        self.log = open(os.path.join(LOGS, name + ".jsonl"), "w")
        from probelib import codex_filter
        self.filt = codex_filter
        self.s = _s.socket(_s.AF_UNIX)
        self.s.connect(sock)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        self.buf = buf.split(b"\r\n\r\n", 1)[1]
        self._rec("meta", {"ws": buf.split(b"\r\n")[0].decode()})
        threading.Thread(target=self._rd, daemon=True).start()

    def _need(self, n):
        while len(self.buf) < n:
            d = self.s.recv(65536)
            if not d:
                raise EOFError
            self.buf += d
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _rd(self):
        import struct
        msg = b""
        try:
            while True:
                h = self._need(2)
                fin, op, ln = h[0] & 0x80, h[0] & 0x0F, h[1] & 0x7F
                if ln == 126:
                    ln = struct.unpack(">H", self._need(2))[0]
                elif ln == 127:
                    ln = struct.unpack(">Q", self._need(8))[0]
                data = self._need(ln)
                if op == 9:
                    self._frame(10, data)
                    continue
                if op == 8:
                    self._rec("eof", "ws close")
                    return
                msg += data
                if fin:
                    try:
                        self._rec("out", json.loads(msg.decode()))
                    except Exception:
                        self._rec("raw", msg[:300].decode(errors="replace"))
                    msg = b""
        except EOFError:
            self._rec("eof", "socket closed")

    def _frame(self, op, data):
        import struct
        mask = os.urandom(4)
        h = bytes([0x80 | op])
        n = len(data)
        if n < 126:
            h += bytes([0x80 | n])
        elif n < 65536:
            h += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            h += bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.s.sendall(h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _write(self, data):
        self._frame(1, data.rstrip("\n").encode())

    def close_stdin(self):
        self.s.close()

    def wait_exit(self, timeout=30):
        return 0


def X16shared():
    sock = os.path.join(BASE, "cx.sock")
    if os.path.exists(sock):
        os.unlink(sock)
    server = Proc(["codex", "app-server", "--listen", "unix://" + sock], "X16server", cwd=WORK3)
    for _ in range(50):
        if os.path.exists(sock):
            break
        time.sleep(0.1)
    print("socket exists:", os.path.exists(sock))
    a = WSCodex("X16clientA", sock)
    print("init:", a.init())
    r = a.thread_start(cwd=WORK3, sandbox="danger-full-access")
    tid = r["result"]["thread"]["id"]
    print("THREAD", tid)
    a.turn_start(tid, "Reply with exactly the word: APRICOT")
    i, done = a.wait_note("turn/completed", 120)
    print("turn 1:", done and done["params"]["turn"]["status"])

    env = dict(os.environ, TERM="xterm-256color")
    tui = Pty(["codex", "resume", tid, "--remote", "unix://" + sock], "X16tui", WORK3, env=env)
    seen = tui.wait_text("APRICOT", 30)
    print("TUI shows history (APRICOT):", seen)
    time.sleep(3)

    n = a.n()
    a.turn_start(tid, "Reply with exactly the word: PINEAPPLE")
    i, done = a.wait_note("turn/completed", 120, start=n)
    print("turn 2 from A:", done and done["params"]["turn"]["status"])
    print("TUI shows A's turn (PINEAPPLE):", tui.wait_text("PINEAPPLE", 15))

    n = a.n()
    tui.type("Reply with exactly the word: MANGO")
    i, st = a.wait_note("turn/started", 60, start=n)
    print("A sees the TUI's turn start:", bool(st))
    i, done = a.wait_note("turn/completed", 120, start=n)
    print("A sees the TUI's turn complete:", done and done["params"]["turn"]["status"])
    msgs = [m["params"]["item"].get("text") for t, k, m in a.events[n:] if k == "out" and isinstance(m, dict)
            and m.get("method") == "item/completed" and m["params"]["item"].get("type") == "agentMessage"]
    print("A got agent messages:", msgs)
    users = [m["params"]["item"] for t, k, m in a.events[n:] if k == "out" and isinstance(m, dict)
             and m.get("method") == "item/completed" and m["params"]["item"].get("type") == "userMessage"]
    print("A got user messages:", json.dumps(users)[:400])

    # A steers a turn started by the TUI.
    n = a.n()
    tui.type("Run the shell command `sleep 6` and then reply with exactly the word: DONE1")
    i, st = a.wait_note("turn/started", 60, start=n)
    turn_id = st["params"]["turn"]["id"] if st else None
    time.sleep(2)
    rid = a.req("turn/steer", {"threadId": tid, "expectedTurnId": turn_id, "clientUserMessageId": str(uuid.uuid4()),
                               "input": [{"type": "text", "text": "Also include the word KIWI in your reply.",
                                          "text_elements": []}]})
    i, resp = a.wait_for(lambda m: m.get("id") == rid and "method" not in m, 30, start=n)
    print("steer response:", resp)
    i, done = a.wait_note("turn/completed", 120, start=n)
    msgs = [m["params"]["item"].get("text") for t, k, m in a.events[n:] if k == "out" and isinstance(m, dict)
            and m.get("method") == "item/completed" and m["params"]["item"].get("type") == "agentMessage"]
    print("steered turn messages:", msgs)
    print("TUI shows KIWI:", tui.wait_text("KIWI", 10))

    # TUI exits; A keeps the thread.
    tui.kill(signal.SIGTERM)
    time.sleep(2)
    print("TUI exited:", tui.exited())
    n = a.n()
    a.turn_start(tid, "Reply with exactly the word: LYCHEE")
    i, done = a.wait_note("turn/completed", 120, start=n)
    print("turn after TUI exit:", done and done["params"]["turn"]["status"])
    a.close_stdin()
    a.wait_exit(10)
    server.kill()
    with open(os.path.join(LOGS, "X16tui.txt"), "w") as f:
        f.write(tui.text())


HOOK_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "PermissionRequest",
               "Stop", "StopFailure", "SessionEnd", "SubagentStop", "PreCompact"]


def make_probe_plugin(dest, log):
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.join(dest, ".claude-plugin"))
    os.makedirs(os.path.join(dest, "hooks"))
    with open(os.path.join(dest, ".claude-plugin", "plugin.json"), "w") as f:
        json.dump({"name": "ternprobe", "version": "0.0.1", "description": "probe"}, f)
    script = os.path.join(dest, "hook.sh")
    with open(script, "w") as f:
        f.write('#!/bin/bash\nin=$(cat)\nprintf \'{"ev":"%s","t":"%s","tty":"%s","env_pane":"%s","ppid":"%s","in":%s}\\n\' "$1" '
                '"$(date +%s)" "$(tty 2>/dev/null)" "$TERN_PROBE_PANE" "$PPID" "$in" >> ' + log + '\nexit 0\n')
    os.chmod(script, 0o755)
    hooks = {"hooks": {ev: [{"hooks": [{"type": "command", "command": script + " " + ev}]}] for ev in HOOK_EVENTS}}
    with open(os.path.join(dest, "hooks", "hooks.json"), "w") as f:
        json.dump(hooks, f)


def read_hooks(log):
    out = []
    if os.path.exists(log):
        for line in open(log):
            try:
                out.append(json.loads(line))
            except Exception:
                out.append({"bad": line[:200]})
    return out


def C14handoff():
    plugin = os.path.join(BASE, "plugin")
    log = os.path.join(BASE, "hooks.jsonl")
    if os.path.exists(log):
        os.unlink(log)
    make_probe_plugin(plugin, log)
    sid = str(uuid.uuid4())
    c = Claude("C14headless", extra=["--session-id", sid, "--plugin-dir", plugin, "--dangerously-skip-permissions"],
               cwd=WORK3)
    c.init()
    c.user("Remember the codeword QUINCE. Reply with exactly: noted")
    i, res = c.wait_result(120)
    print("headless turn:", res and res.get("result"))
    # Steer: a long tool call, and a second message sent during it.
    n = c.n()
    u1 = c.user("Run the shell command `sleep 6` with Bash, then reply with exactly: slept")
    time.sleep(3)
    u2 = c.user("Also say the word FIG in your reply.")
    i, res = c.wait_result(120, start=n)
    print("steered result:", res and res.get("result"), res and res.get("user_message_uuids"), [u1, u2])
    c.close_stdin()
    print("headless exit:", c.wait_exit(30))
    hooks = read_hooks(log)
    print("hooks in -p mode:", [h.get("ev") for h in hooks])
    stops = [h for h in hooks if h.get("ev") == "Stop"]
    print("Stop input keys:", sorted(stops[-1]["in"].keys()) if stops else None)

    env = dict(os.environ, TERM="xterm-256color", TERN_PROBE_PANE="pane-42")
    env.pop("CLAUDECODE", None)
    tui = Pty(["claude", "--resume", sid, "--plugin-dir", plugin, "--dangerously-skip-permissions", "--model", "haiku"],
              "C14tui", WORK3, env=env)
    if tui.wait_text("Itrustthisfolder", 8) or tui.wait_text("I trust this folder", 1):
        print("trust dialog shown; answering yes")
        os.write(tui.fd, b"\x1b[B")
        time.sleep(0.5)
        os.write(tui.fd, b"\r")
    time.sleep(8)
    before = len(read_hooks(log))
    tui.type("What was the codeword? Reply with just the word.")
    ok = tui.wait_text("QUINCE", 60)
    print("TUI recalls QUINCE:", ok)
    time.sleep(4)
    hooks = read_hooks(log)
    print("hooks in TUI:", [(h.get("ev"), h.get("tty"), h.get("env_pane")) for h in hooks[before:]])
    tui.kill(signal.SIGTERM)
    time.sleep(3)
    print("TUI exited after SIGTERM:", tui.exited())
    hooks = read_hooks(log)
    print("hooks after SIGTERM:", [h.get("ev") for h in hooks[before:]])

    c2 = Claude("C14resume", extra=["--resume", sid, "--plugin-dir", plugin, "--dangerously-skip-permissions"],
                cwd=WORK3)
    c2.init()
    c2.user("What words did the user ask about so far (the codeword and the last question)? Reply briefly.")
    i, res = c2.wait_result(120)
    print("headless after TUI:", res and res.get("result"))
    c2.close_stdin()
    c2.wait_exit(30)
    with open(os.path.join(LOGS, "C14tui.txt"), "w") as f:
        f.write(tui.text())
    with open(os.path.join(LOGS, "C14hooks.jsonl"), "w") as f:
        for h in read_hooks(log):
            f.write(json.dumps(h) + "\n")



def C15cancelq():
    """Steer M2 during a long Bash call, then interrupt with cancel_queued:true: is M2 dropped, and listed?"""
    c = Claude("C15cancelq", extra=["--dangerously-skip-permissions"], cwd=WORK3)
    c.init()
    u1 = c.user("Run the shell command `sleep 15` with Bash, then reply with exactly: slept")
    time.sleep(5)
    u2 = c.user("Reply with exactly: BANANA")
    time.sleep(1)
    n = c.n()
    c.control("interrupt", rid="int1", cancel_queued=True)
    i, resp = c.wait_for(lambda m: m.get("type") == "control_response"
                         and m.get("response", {}).get("request_id") == "int1", 20, start=n)
    print("interrupt response:", resp)
    i, res = c.wait_result(60, start=n)
    print("result 1:", res and (res.get("subtype"), res.get("user_message_uuids")))
    i, res2 = c.wait_result(20, start=(i or n) + 1)
    print("a second result (M2 ran?):", res2 and (res2.get("result"), res2.get("user_message_uuids")), [u1, u2])
    lc = [(m.get("command_uuid") == u2, m.get("state")) for t, k, m in c.events if k == "out" and isinstance(m, dict)
          and m.get("type") == "command_lifecycle" and m.get("command_uuid") == u2]
    print("M2 lifecycle:", lc)
    c.close_stdin()
    c.wait_exit(30)



def X17steerint():
    """Steer a message into a running turn, interrupt before the next tool boundary: does the
    steered input ever reach the thread (in this turn's items, a later turn, or the history)?"""
    sock = os.path.join(BASE, "cx17.sock")
    if os.path.exists(sock):
        os.unlink(sock)
    server = Proc(["codex", "app-server", "--listen", "unix://" + sock], "X17server", cwd=WORK3)
    for _ in range(100):
        if os.path.exists(sock):
            break
        time.sleep(0.1)
    a = WSCodex("X17clientA", sock)
    a.init()
    r = a.thread_start(cwd=WORK3, sandbox="danger-full-access")
    tid = r["result"]["thread"]["id"]
    n = a.n()
    a.turn_start(tid, "Run the shell command `sleep 12` and then reply with exactly: SLEPT")
    i, st = a.wait_note("turn/started", 60, start=n)
    turn_id = st["params"]["turn"]["id"]
    time.sleep(4)
    steer_id = str(uuid.uuid4())
    rid = a.req("turn/steer", {"threadId": tid, "expectedTurnId": turn_id, "clientUserMessageId": steer_id,
                               "input": [{"type": "text", "text": "Also say the word PLUM.", "text_elements": []}]})
    i, resp = a.wait_for(lambda m: m.get("id") == rid and "method" not in m, 30, start=n)
    print("steer response:", resp)
    time.sleep(1)
    a.call("turn/interrupt", {"threadId": tid, "turnId": turn_id})
    i, done = a.wait_note("turn/completed", 60, start=n)
    print("turn 1:", done["params"]["turn"]["status"])
    users = [m["params"]["item"].get("clientId") for t, k, m in a.events[n:] if k == "out" and isinstance(m, dict)
             and m.get("method") == "item/completed" and m["params"]["item"].get("type") == "userMessage"]
    print("userMessage clientIds in turn 1:", users, "steer id:", steer_id)
    time.sleep(5)
    n2 = a.n()
    a.turn_start(tid, "Reply with exactly: NEXT")
    i, done = a.wait_note("turn/completed", 120, start=n2)
    users2 = [m["params"]["item"] for t, k, m in a.events[n2:] if k == "out" and isinstance(m, dict)
              and m.get("method") == "item/completed" and m["params"]["item"].get("type") == "userMessage"]
    print("turn 2 user messages:", [(u.get("clientId"), json.dumps(u.get("content"))[:80]) for u in users2])
    msgs = [m["params"]["item"].get("text") for t, k, m in a.events[n2:] if k == "out" and isinstance(m, dict)
            and m.get("method") == "item/completed" and m["params"]["item"].get("type") == "agentMessage"]
    print("turn 2 replies:", msgs)
    r = a.call("thread/read", {"threadId": tid, "includeTurns": True})
    text = json.dumps(r)
    print("PLUM in history:", "PLUM" in text, "steer id in history:", steer_id in text)
    a.close_stdin()
    server.kill()


if __name__ == "__main__":
    globals()[sys.argv[1]]()
