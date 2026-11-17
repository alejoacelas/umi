"""Headless tests for umi-next-daemon / -attach / -ctl.

Each test gets its own UMI_NEXT_STATE_DIR (a temp dir) and a minimal
environment, so nothing touches the user's Umi or its state. Attach clients
run on ptys driven from here; their output is rendered by feeding it into a
fresh libghostty-vt terminal (`umi-next-ctl render`) and, independently, pyte.
"""
import json
import os
import pty  # noqa: F401  (documents that clients run on ptys)
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import fcntl
import threading
import time
from pathlib import Path

import pyte
import pytest

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "bin"
CTL = str(BIN / "umi-next-ctl")
ATTACH = str(BIN / "umi-next-attach")


# ---------- helpers ----------

def wait_for(cond, timeout=10.0, interval=0.05, what="condition"):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        v = cond()
        if v:
            return v
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {what}")


class Env:
    def __init__(self):
        # Short path: unix socket paths are limited to 103 bytes.
        self.root = Path(tempfile.mkdtemp(prefix="unx"))
        self.state = self.root / "state"
        self.env = {
            "HOME": os.environ["HOME"],
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "USER": os.environ.get("USER", ""),
            "LOGNAME": os.environ.get("LOGNAME", ""),
            "SHELL": "/bin/sh",
            "LANG": "en_US.UTF-8",
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "UMI_NEXT_STATE_DIR": str(self.state),
        }

    def ctl(self, *args, check=True, input=None):
        r = subprocess.run([CTL, *args], env=self.env, capture_output=True, input=input, timeout=30)
        if check and r.returncode != 0:
            raise AssertionError(f"ctl {args} failed ({r.returncode}): {r.stderr.decode()}")
        return r

    def new(self, cmd=None, cols=80, rows=24, cwd=None, name=None):
        a = ["new", "--cols", str(cols), "--rows", str(rows), "--cwd", str(cwd or self.root)]
        if cmd:
            a += ["--cmd", cmd]
        if name:
            a += ["--name", name]
        return self.ctl(*a).stdout.decode().strip()

    def screen(self, sid):
        return json.loads(self.ctl("screen", sid, "--json").stdout)

    def session(self, sid):
        return next(s for s in json.loads(self.ctl("ls").stdout) if s["id"] == sid)

    def daemon_pid(self):
        return json.loads(self.ctl("ping").stdout)["pid"]

    def render(self, data, cols, rows):
        return json.loads(self.ctl("render", "--cols", str(cols), "--rows", str(rows), "--json", input=data).stdout)

    def cleanup(self):
        self.ctl("daemon-stop", "--force", check=False)
        shutil.rmtree(self.root, ignore_errors=True)


def set_winsize(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class Client:
    """umi-next-attach running on a pty that this test drives."""

    def __init__(self, env, sid, cols=80, rows=24, reader=True):
        self.cols, self.rows = cols, rows
        self.master, slave = os.openpty()
        set_winsize(slave, cols, rows)
        self.proc = subprocess.Popen(
            [ATTACH, sid], stdin=slave, stdout=slave, stderr=slave, env=env.env,
            start_new_session=True, preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        self.buf = bytearray()
        self.last = time.monotonic()
        self.lock = threading.Lock()
        self.thread = None
        if reader:
            self.thread = threading.Thread(target=self._read, daemon=True)
            self.thread.start()

    def _read(self):
        while True:
            try:
                r, _, _ = select.select([self.master], [], [], 0.2)
                if not r:
                    if self.proc.poll() is not None and not r:
                        # drain whatever is left
                        pass
                    continue
                d = os.read(self.master, 65536)
            except OSError:
                return
            if not d:
                return
            with self.lock:
                self.buf += d
                self.last = time.monotonic()

    def output(self):
        with self.lock:
            return bytes(self.buf)

    def quiet(self, secs=0.4, timeout=15):
        wait_for(lambda: len(self.buf) > 0 and time.monotonic() - self.last > secs, timeout, what="client output to settle")

    def write(self, b):
        os.write(self.master, b)

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        set_winsize(self.master, cols, rows)
        os.killpg(self.proc.pid, signal.SIGWINCH)

    def render(self, env):
        return env.render(self.output(), self.cols, self.rows)

    def kill9(self):
        self.proc.kill()
        self.proc.wait()
        try:
            os.close(self.master)
        except OSError:
            pass


@pytest.fixture
def env():
    if not Path(CTL).exists():
        pytest.fail("binaries missing: run next/daemon/build.sh")
    e = Env()
    yield e
    e.cleanup()


def pyte_lines(data, cols, rows):
    s = pyte.Screen(cols, rows)
    st = pyte.ByteStream(s)
    st.feed(data)
    return [l.rstrip() for l in s.display], (s.cursor.x, s.cursor.y)


def lines(text):
    return text.split("\n")[:-1]


def style_diffs(client_styles, daemon_styles, allow_blank_bleed=False):
    """Cells whose style differs. With allow_blank_bleed, skip the one known
    libghostty-vt formatter bug: never-written cells between two styled runs
    on a row are replayed as spaces still carrying the earlier run's
    background (formatter.zig writes the pending blanks before it switches
    style). Only blank cells whose daemon style is default and whose replayed
    background equals the background of the nearest styled cell to their left
    are skipped."""
    diffs = []
    for y, (a, b) in enumerate(zip(client_styles.split("\n"), daemon_styles.split("\n"))):
        ca_row, cb_row = a.split(" "), b.split(" ")
        for x, (ca, cb) in enumerate(zip(ca_row, cb_row)):
            if ca == cb:
                continue
            if allow_blank_bleed and cb == "." and ca.startswith("_/"):
                bg = ca.split("/")[1]
                left = next((c for c in reversed(cb_row[:x]) if c != "."), "")
                if left.count("/") >= 2 and left.split("/")[1] == bg:
                    continue
            diffs.append(f"({x},{y}) client {ca} daemon {cb}")
    return diffs


def assert_same_screen(client_render, daemon, what="", allow_blank_bleed=False):
    assert client_render["text"] == daemon["text"], f"{what}: text differs\nclient:\n{client_render['text']}\ndaemon:\n{daemon['text']}"
    diffs = style_diffs(client_render["styles"], daemon["styles"], allow_blank_bleed)
    assert not diffs, f"{what}: styles differ in {len(diffs)} cells: " + "; ".join(diffs[:12])
    for k in ("cursor", "alternate", "kitty_flags", "mouse_tracking", "bracketed_paste", "app_cursor_keys"):
        assert client_render[k] == daemon[k], f"{what}: {k} differs: client {client_render[k]} daemon {daemon[k]}"


def test_known_formatter_blank_bleed(env):
    """Documents the formatter bug that allow_blank_bleed skips. If this
    starts failing, the bug is fixed: drop allow_blank_bleed."""
    r = env.ctl("render", "--cols", "12", "--rows", "1", "--replay",
                input=b"\x1b[48;2;0;0;0mAB\x1b[0m\x1b[3C\x1b[1mX")
    d = json.loads(r.stdout)
    assert style_diffs(d["replayed"]["styles"], d["original"]["styles"])  # the bug
    assert not style_diffs(d["replayed"]["styles"], d["original"]["styles"], allow_blank_bleed=True)


# ---------- the TUI ----------

TUI = r'''
import curses, json, os, sys
out = sys.argv[1]
def main(scr):
    curses.start_color(); curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
    curses.init_pair(2, curses.COLOR_RED, -1)
    curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_YELLOW)
    n = 0
    def draw():
        scr.erase()
        h, w = scr.getmaxyx()
        scr.addstr(0, 0, (" umi tui test %d " % n).ljust(w), curses.color_pair(1) | curses.A_BOLD)
        for i in range(2, h - 2):
            attr = curses.color_pair(2) if i % 2 else curses.A_UNDERLINE
            scr.addstr(i, 2 + i % 5, "row %02d %s" % (i, "x" * (i % 11)), attr)
        scr.addstr(h - 1, 0, "status: ready (%dx%d)" % (w, h), curses.color_pair(3))
        scr.move(5, 10)
        scr.refresh()
        y, x = scr.getyx()
        rows = [scr.instr(r, 0).decode().rstrip() for r in range(h)]
        scr.move(y, x)  # instr moved the cursor; getch() refreshes
        tmp = out + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"lines": rows, "cursor": [x, y], "n": n, "size": [w, h]}, f)
        os.replace(tmp, out)
    draw()
    while True:
        c = scr.getch()
        if c == ord("q"):
            break
        if c != curses.KEY_RESIZE:
            n += 1
        draw()
curses.wrapper(main)
'''


def test_tui_reattach_after_kill9(env):
    tui = env.root / "tui.py"
    tui.write_text(TUI)
    drawn = env.root / "drawn.json"
    sid = env.new(f"printf 'before the tui\\n'; exec python3 {tui} {drawn}", cols=80, rows=24)
    wait_for(drawn.exists, what="the TUI's first frame")

    c1 = Client(env, sid, 80, 24)
    c1.quiet()
    c1.write(b"k")  # one keystroke: TUI redraws with n=1
    wait_for(lambda: json.loads(drawn.read_text())["n"] == 1, what="redraw after a key")
    c1.quiet()
    first = c1.render(env)
    c1.kill9()

    pid = env.daemon_pid()
    assert env.session(sid)["alive"], "session died with its client"
    assert env.session(sid)["clients"] == 0

    c2 = Client(env, sid, 80, 24)
    c2.quiet()
    daemon = env.screen(sid)
    again = c2.render(env)
    prog = json.loads(drawn.read_text())

    assert_same_screen(again, daemon, "reattach vs daemon")
    assert_same_screen(first, daemon, "first client vs daemon")
    assert daemon["alternate"] is True
    # What the program drew (curses' own copy of its screen).
    assert [l.rstrip() for l in lines(daemon["text"])] == prog["lines"]
    assert [daemon["cursor"]["x"], daemon["cursor"]["y"]] == prog["cursor"] == [10, 5]
    assert daemon["cursor"]["visible"] is True
    assert "p4" in daemon["styles"] and "p1" in daemon["styles"], "colours missing"
    # An independent emulator agrees on the text and cursor.
    pl, pc = pyte_lines(c2.output(), 80, 24)
    assert pl == lines(daemon["text"])
    assert pc == (10, 5)

    # The reattached client is live: input reaches the TUI and output comes back.
    c2.write(b"k")
    wait_for(lambda: json.loads(drawn.read_text())["n"] == 2, what="input through the reattached client")
    c2.quiet()
    assert_same_screen(c2.render(env), env.screen(sid), "after typing")

    # Leaving the TUI shows the primary screen the reattach restored.
    c2.write(b"q")
    wait_for(lambda: c2.proc.poll() is not None, what="attach to exit with the session")
    assert c2.proc.returncode == 0
    assert env.session(sid)["exit_status"] == 0
    final = env.screen(sid)
    assert final["alternate"] is False and "before the tui" in final["text"]
    r = c2.render(env)
    assert r["text"] == final["text"], f"primary screen after reattach:\n{r['text']}\nvs daemon:\n{final['text']}"
    assert env.daemon_pid() == pid


def test_resize_on_attach_and_sigwinch(env):
    sid = env.new("trap 'stty size' WINCH; stty size; while :; do sleep 0.05; done", cols=80, rows=24)
    wait_for(lambda: "24 80" in env.screen(sid)["text"], what="initial size")
    c = Client(env, sid, 50, 20)
    wait_for(lambda: "20 50" in env.screen(sid)["text"], what="size from attach")
    c.resize(70, 15)
    wait_for(lambda: "15 70" in env.screen(sid)["text"], what="size after SIGWINCH")
    s = env.screen(sid)
    assert (s["cols"], s["rows"]) == (70, 15)
    c.quiet()
    assert c.render(env)["text"] == env.screen(sid)["text"]
    c.kill9()


def test_modes_replayed(env):
    # hidden cursor, bracketed paste, SGR mouse, app cursor keys, kitty flags 5
    seq = r"\033[?25l\033[?2004h\033[?1000h\033[?1006h\033[?1h\033[>5u\033[1;32mgreen\033[0m"
    sid = env.new(f"printf '{seq}'; sleep 1000", cols=40, rows=10)
    wait_for(lambda: "green" in env.screen(sid)["text"], what="output")
    d = env.screen(sid)
    assert d["cursor"]["visible"] is False and d["bracketed_paste"] and d["mouse_tracking"]
    assert d["app_cursor_keys"] and d["kitty_flags"] == 5
    c = Client(env, sid, 40, 10)
    c.quiet()
    assert_same_screen(c.render(env), d, "modes")
    c.kill9()


def test_producer_keeps_running_detached(env):
    sid = env.new("i=0; while :; do echo $i; i=$((i+1)); sleep 0.1; done", cols=40, rows=10)

    def last():
        nums = [int(l) for l in lines(env.screen(sid)["text"]) if l.strip().isdigit()]
        return nums[-1] if nums else -1

    wait_for(lambda: last() >= 3, what="counter")
    c = Client(env, sid, 40, 10)
    c.quiet(0.05)
    c.kill9()
    a = last()
    time.sleep(1.5)
    b = last()
    assert b - a >= 8, f"counter went {a} → {b} in 1.5 s with no client"
    assert env.session(sid)["alive"]
    # A reattached client sees the current count.
    c2 = Client(env, sid, 40, 10)
    time.sleep(0.5)
    r = c2.render(env)
    nums = [int(l) for l in lines(r["text"]) if l.strip().isdigit()]
    assert nums and nums[-1] >= b
    c2.kill9()


def test_daemon_survives_its_starter_and_clients(env):
    # Start the daemon from a process on its own pty, then kill -9 that
    # process's whole group and hang up its terminal.
    master, slave = os.openpty()
    starter = subprocess.Popen(
        ["/bin/sh", "-c", f"'{CTL}' new --cmd 'sleep 1000' --name survivor; sleep 1000"],
        stdin=slave, stdout=slave, stderr=slave, env=env.env, start_new_session=True,
        preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    wait_for(lambda: env.ctl("ping", check=False).returncode == 0, what="daemon start")
    sid = wait_for(lambda: next((s["id"] for s in json.loads(env.ctl("ls").stdout) if s["name"] == "survivor"), None), what="session")
    pid = env.daemon_pid()
    os.killpg(starter.pid, signal.SIGKILL)
    # Hang up the starter's terminal. (Close before wait: on macOS a process
    # exiting with unread tty output waits for its terminal to drain.)
    os.close(master)
    starter.wait()
    clients = [Client(env, sid, 80, 24) for _ in range(3)]
    wait_for(lambda: env.session(sid)["clients"] == 3, what="3 clients")
    for c in clients:
        c.kill9()
    time.sleep(0.5)
    assert env.daemon_pid() == pid
    s = env.session(sid)
    assert s["alive"] and s["clients"] == 0
    assert os.getpgid(pid) != starter.pid


def test_exit_status_and_lifecycle(env):
    sid = env.new("printf 'bye'; sleep 0.5; exit 7", cols=40, rows=5)
    c = Client(env, sid, 40, 5)
    wait_for(lambda: c.proc.poll() is not None, what="attach exit")
    assert c.proc.returncode == 7
    s = env.session(sid)
    assert s["alive"] is False and s["exit_status"] == 7
    # Attaching to an exited session shows its last screen and exits with its status.
    c2 = Client(env, sid, 40, 5)
    wait_for(lambda: c2.proc.poll() is not None, what="attach to exited")
    assert c2.proc.returncode == 7
    time.sleep(0.2)
    assert "bye" in c2.render(env)["text"]
    # rm, kill, daemon-stop refusal
    live = env.new("sleep 1000")
    assert env.ctl("daemon-stop", check=False).returncode != 0
    assert env.ctl("rm", live, check=False).returncode != 0
    env.ctl("kill", live)
    wait_for(lambda: not env.session(live)["alive"], what="kill")
    assert env.session(live)["exit_signal"] == signal.SIGTERM
    env.ctl("rm", live)
    env.ctl("rm", sid)
    assert json.loads(env.ctl("ls").stdout) == []
    env.ctl("daemon-stop")
    assert env.ctl("ping", check=False).returncode != 0


def test_send_and_single_daemon(env):
    sid = env.new("exec cat", cols=40, rows=5)
    env.ctl("send", sid, "hello\r")
    wait_for(lambda: "hello" in env.screen(sid)["text"], what="send")
    pid = env.daemon_pid()
    # A second daemon on the same state dir exits at once (lock file).
    r = subprocess.run([str(BIN / "umi-next-daemon"), "--foreground"], env=env.env, timeout=10)
    assert r.returncode == 0
    assert env.daemon_pid() == pid
    assert "another daemon holds" in (env.state / "daemon.log").read_text()


# ---------- latency ----------

ECHO = "stty raw -echo; exec cat"


def measure_echo(master, n=500):
    lat = []
    for i in range(n):
        ch = bytes([97 + i % 26])
        t0 = time.perf_counter_ns()
        os.write(master, ch)
        got = b""
        while ch not in got:
            r, _, _ = select.select([master], [], [], 2)
            assert r, "echo timed out"
            got += os.read(master, 4096)
        lat.append((time.perf_counter_ns() - t0) / 1000)
    lat.sort()
    return lat[len(lat) // 2], lat[int(len(lat) * 0.99)]


def test_keystroke_latency(env, capsys):
    # Baseline: the same echo program on a plain pty.
    master, slave = os.openpty()
    tty_attrs = termios.tcgetattr(slave)
    p = subprocess.Popen(["/bin/sh", "-c", ECHO], stdin=slave, stdout=slave, stderr=slave,
                         start_new_session=True, preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    time.sleep(0.3)
    measure_echo(master, 50)
    base = measure_echo(master)
    p.kill(); os.close(master)

    sid = env.new(ECHO, cols=80, rows=24)
    time.sleep(0.3)
    c = Client(env, sid, 80, 24, reader=False)
    time.sleep(0.5)
    while select.select([c.master], [], [], 0.2)[0]:
        os.read(c.master, 65536)  # the replay
    measure_echo(c.master, 50)
    relay = measure_echo(c.master)
    c.kill9()
    report = (f"keystroke echo over 500 keys: plain pty median {base[0]:.0f} µs p99 {base[1]:.0f} µs; "
              f"through daemon+attach median {relay[0]:.0f} µs p99 {relay[1]:.0f} µs; "
              f"added median {relay[0]-base[0]:.0f} µs p99 {relay[1]-base[1]:.0f} µs")
    (HERE / "latency.txt").write_text(report + "\n")
    with capsys.disabled():
        print("\n" + report)
    assert relay[0] < 5000, "relay adds more than 5 ms median"


# ---------- real claude ----------

@pytest.mark.skipif(shutil.which("claude") is None, reason="claude not on PATH")
def test_claude_reattach(env):
    # In a fresh temp repo claude stops at its folder-trust dialog; this
    # checkout is already trusted, so claude opens straight to its input box.
    # Nothing is submitted, so it does no work here.
    repo = HERE.parent
    sid = env.new("claude --model haiku", cols=100, rows=30, cwd=repo)
    c1 = Client(env, sid, 100, 30)

    def input_box():
        t = env.screen(sid)["text"]
        return "❯" in t and "trust" not in t.lower()

    wait_for(input_box, timeout=90, interval=0.5, what="claude's input box")
    c1.quiet(1.5, timeout=60)
    # Type into the box through the client (not submitted).
    c1.write(b"say hi")
    wait_for(lambda: "say hi" in env.screen(sid)["text"], timeout=20, what="typed text in the box")
    c1.quiet(1.5, timeout=60)
    before = env.screen(sid)
    assert_same_screen(c1.render(env), before, "claude first attach", allow_blank_bleed=True)
    c1.kill9()
    time.sleep(1)
    assert env.session(sid)["alive"]
    c2 = Client(env, sid, 100, 30)
    c2.quiet(1.5, timeout=60)
    after = env.screen(sid)
    assert_same_screen(c2.render(env), after, "claude reattach", allow_blank_bleed=True)
    assert after["text"] == before["text"], f"claude's screen changed across reattach:\n{before['text']}\n---\n{after['text']}"
    assert "say hi" in after["text"]
    (HERE / "claude-screen.txt").write_text(after["text"])
    c2.kill9()
    env.ctl("kill", sid)
