"""fake_common.py - pieces shared by fake_claude.py and fake_codex.py (Python 3.9, stdlib only).

* Hooks: plugin hooks (`DIR/hooks/hooks.json`) run the way Claude Code and Codex run them.
* Session claims: one live fake process per Claude session / Codex thread; a second one appends a line
  to $FAKE_AGENT_DIR/violations.log.
* LineUI: the line-oriented "TUI" both fakes show in a terminal (prompt line at the bottom, output
  printed above it, a tiny line editor).

README.md documents the behaviour; this module only implements it.
"""
import codecs
import json
import os
import re
import select
import signal
import subprocess
import sys
import tempfile
import threading

HOOK_TIMEOUT = 60.0      # seconds; a hooks.json entry may set "timeout" (seconds) instead


def agent_root():
    return os.environ.get("FAKE_AGENT_DIR") or os.path.join(tempfile.gettempdir(), "fake-agent")


def append_line(path, text):
    """One O_APPEND write (lines from several processes never interleave)."""
    data = text.encode("utf-8")
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        while data:
            data = data[os.write(fd, data):]
    finally:
        os.close(fd)


# ------------------------------------------------------------------ one process per session

def live_fake(pid):
    """True if `pid` is a running (not zombie) process of this same fake script."""
    if not pid or pid == os.getpid():
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False          # another user's process: not one of ours
    try:
        out = subprocess.run(["ps", "-o", "stat=", "-o", "command=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True, timeout=5).stdout.strip()
    except Exception:
        return True
    if not out or out.split()[0].startswith("Z"):
        return False          # gone, or a zombie nobody reaped yet: not running
    return os.path.basename(os.path.abspath(sys.argv[0])) in out


def log_violation(harness, session, other_pid):
    append_line(os.path.join(agent_root(), "violations.log"),
                "two processes on %s session %s: pids %d and %d\n" % (harness, session, other_pid, os.getpid()))


def read_pid(path):
    try:
        with open(path) as f:
            return int(f.read().strip() or "0")
    except (IOError, ValueError):
        return 0


def claim_session(path, harness, session):
    """Record this process as the one running `session` (a pid file). If another live fake process is
    recorded there, log a violation and carry on (the caller decides whether to refuse)."""
    other = read_pid(path)
    if live_fake(other):
        log_violation(harness, session, other)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        f.write(str(os.getpid()))
    os.replace(tmp, path)
    return other if live_fake(other) else 0


def release_session(path):
    if read_pid(path) == os.getpid():
        try:
            os.remove(path)
        except OSError:
            pass


# ------------------------------------------------------------------ hooks

def plugin_dirs(env_var, extra=()):
    dirs = list(extra)
    dirs += [d for d in (os.environ.get(env_var) or "").split(":") if d.strip()]
    return dirs


def matcher_matches(matcher, value):
    if matcher in (None, "", "*") or value is None:
        return True
    try:
        return re.fullmatch(matcher, value) is not None
    except re.error:
        return matcher == value


class Hooks(object):
    """Hooks from plugin directories. harness "claude": ${CLAUDE_PLUGIN_ROOT}, hooks share the fake's
    session (they can open the terminal). harness "codex": ${PLUGIN_ROOT} (and ${CLAUDE_PLUGIN_ROOT}),
    hooks run detached (setsid), as Codex >= 0.155 does. Either way the hook's parent is this process,
    stdin is one JSON object, stdout/stderr are captured, and the fake waits for the hook (timeout)."""

    def __init__(self, harness, dirs):
        self.harness = harness
        self.entries = []        # (event, matcher, command, timeout, root)
        self.plugins = []        # {"name", "path", "version"}
        seen = set()
        for d in dirs:
            root = os.path.abspath(os.path.expanduser(d.strip()))
            key = os.path.realpath(root)
            if key in seen or not os.path.isdir(root):
                continue
            seen.add(key)
            self.plugins.append(self.manifest(root))
            try:
                with open(os.path.join(root, "hooks", "hooks.json")) as f:
                    data = json.load(f)
            except (IOError, ValueError):
                continue
            for event, groups in ((data or {}).get("hooks") or {}).items():
                for g in groups if isinstance(groups, list) else []:
                    if not isinstance(g, dict):
                        continue
                    for h in g.get("hooks") or []:
                        if isinstance(h, dict) and h.get("type", "command") == "command" and h.get("command"):
                            try:
                                timeout = float(h.get("timeout") or HOOK_TIMEOUT)
                            except (TypeError, ValueError):
                                timeout = HOOK_TIMEOUT
                            self.entries.append((event, g.get("matcher"), h["command"], timeout, root))

    def manifest(self, root):
        names = [".claude-plugin", ".codex-plugin"] if self.harness == "claude" else [".codex-plugin", ".claude-plugin"]
        for sub in names:
            try:
                with open(os.path.join(root, sub, "plugin.json")) as f:
                    m = json.load(f)
                return {"name": m.get("name") or os.path.basename(root), "path": root, "version": m.get("version")}
            except (IOError, ValueError, AttributeError):
                continue
        return {"name": os.path.basename(root), "path": root, "version": None}

    def has(self, event):
        return any(e[0] == event for e in self.entries)

    def selected(self, event, match=None):
        return [e for e in self.entries if e[0] == event and matcher_matches(e[1], match)]

    def expand(self, command, root):
        command = command.replace("${CLAUDE_PLUGIN_ROOT}", root)
        if self.harness == "codex":
            command = command.replace("${PLUGIN_ROOT}", root)
        return command

    def run(self, event, payload, cwd, match=None, on_start=None, on_done=None):
        """Run every matching hook for `event` (in parallel) and wait for all of them.
        on_start(index, entry) / on_done(index, entry, result) let -p mode report SessionStart hooks."""
        chosen = self.selected(event, match)
        if not chosen:
            return []
        data = (json.dumps(payload) + "\n").encode("utf-8")
        results = [None] * len(chosen)

        def one(i, entry):
            _, _, command, timeout, root = entry
            env = dict(os.environ)
            env["CLAUDE_PLUGIN_ROOT"] = root
            if self.harness == "codex":
                env["PLUGIN_ROOT"] = root
            else:
                env["CLAUDE_PROJECT_DIR"] = cwd
            res = {"exit_code": None, "stdout": "", "stderr": "", "timed_out": False}
            try:
                p = subprocess.Popen(["/bin/sh", "-c", self.expand(command, root)],
                                     cwd=cwd if os.path.isdir(cwd) else None, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=self.harness == "codex")
            except OSError as e:
                res["stderr"] = str(e)
                results[i] = res
                return
            try:
                out, err = p.communicate(data, timeout=timeout)
            except subprocess.TimeoutExpired:
                res["timed_out"] = True
                try:
                    if self.harness == "codex":
                        os.killpg(p.pid, signal.SIGKILL)
                    else:
                        p.kill()
                except OSError:
                    pass
                try:
                    out, err = p.communicate(timeout=1)
                except Exception:
                    out, err = b"", b""
            res["exit_code"] = p.returncode
            res["stdout"] = (out or b"").decode("utf-8", "replace")
            res["stderr"] = (err or b"").decode("utf-8", "replace")
            results[i] = res

        threads = []
        for i, entry in enumerate(chosen):
            if on_start is not None:
                on_start(i, entry)
            t = threading.Thread(target=one, args=(i, entry), daemon=True)
            t.start()
            threads.append(t)
        for i, t in enumerate(threads):
            t.join()
            if on_done is not None:
                on_done(i, chosen[i], results[i])
        return results


# ------------------------------------------------------------------ line-oriented terminal UI

ACTIVE_UIS = []


def restore_terminals():
    """Put every terminal a LineUI switched to raw-ish mode back (also on CRASH)."""
    for ui in list(ACTIVE_UIS):
        ui.restore()

class LineUI(object):
    """A minimal terminal front end: everything printed goes above a prompt line that always stays at
    the bottom; typed characters are edited on that line (backspace, Ctrl-U); Enter submits; Ctrl-D on
    an empty line is EOF; Esc alone calls on_escape. Ctrl-C stays a signal (ISIG is kept on).
    Without a terminal it reads plain lines from stdin and prints plain lines."""

    def __init__(self, prompt):
        self.prompt = prompt
        self.buf = ""
        self.lock = threading.RLock()
        self.tty = os.isatty(0) and os.isatty(1)
        self.saved = None
        self.on_escape = None
        self.dead = False             # the terminal went away (EIO / EPIPE)
        self.hangup = False           # read_line() returned None because the terminal is gone, not Ctrl-D
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = ""
        self.last_cr = False

    def start(self):
        if not self.tty:
            return
        import termios
        try:
            self.saved = termios.tcgetattr(0)
            new = termios.tcgetattr(0)
            new[3] &= ~(termios.ICANON | termios.ECHO | termios.IEXTEN)
            new[6][termios.VMIN] = 1
            new[6][termios.VTIME] = 0
            termios.tcsetattr(0, termios.TCSANOW, new)
            ACTIVE_UIS.append(self)
        except Exception:
            self.saved = None

    def restore(self):
        if self.saved is not None:
            import termios
            try:
                termios.tcsetattr(0, termios.TCSANOW, self.saved)
            except Exception:
                pass
            self.saved = None

    def _write(self, text):
        if self.dead:
            return
        data = text.encode("utf-8", "replace")
        try:
            while data:
                data = data[os.write(1, data):]
        except OSError:
            self.dead = True

    def raw(self, text):
        with self.lock:
            self._write(text)

    def title(self, text):
        if self.tty:
            self.raw("\x1b]2;%s\x07" % text)

    def show_prompt(self):
        with self.lock:
            if self.tty:
                self._write("\r\x1b[K" + self.prompt + self.buf)

    def say(self, *lines):
        """Print lines above the prompt line."""
        out = []
        for line in lines:
            out.extend(str(line).split("\n"))
        with self.lock:
            if self.tty:
                self._write("\r\x1b[K" + "\n".join(out) + "\n" + self.prompt + self.buf)
            else:
                self._write("\n".join(out) + "\n")

    def read_line(self):
        """The next submitted line, or None at EOF."""
        if not self.tty:
            try:
                line = sys.stdin.buffer.readline()
            except (OSError, ValueError):
                return None
            if not line:
                return None
            return line.decode("utf-8", "replace").rstrip("\r\n")
        while True:
            while self.pending:
                ch, self.pending = self.pending[0], self.pending[1:]
                if ch in "\r\n":
                    if ch == "\n" and self.last_cr:
                        self.last_cr = False
                        continue
                    self.last_cr = ch == "\r"
                    with self.lock:
                        line, self.buf = self.buf, ""
                        self._write("\r\x1b[K" + self.prompt)
                    return line
                self.last_cr = False
                if ch in "\x7f\x08":
                    with self.lock:
                        if self.buf:
                            self.buf = self.buf[:-1]
                            self._write("\b \b")
                elif ch == "\x15":
                    with self.lock:
                        self.buf = ""
                        self._write("\r\x1b[K" + self.prompt)
                elif ch == "\x04":
                    if not self.buf:
                        return None
                elif ch == "\x1b":
                    self._escape()
                elif ch == "\t":
                    with self.lock:
                        self.buf += " "
                        self._write(" ")
                elif ord(ch) >= 0x20:
                    with self.lock:
                        self.buf += ch
                        self._write(ch)
            try:
                data = os.read(0, 4096)
            except InterruptedError:
                continue
            except OSError:
                self.hangup = True
                return None
            if not data:
                self.hangup = True
                return None
            self.pending += self.decoder.decode(data)

    def _escape(self):
        """An escape sequence (arrow keys, ...) is swallowed; a lone Esc calls on_escape."""
        if not self.pending:
            try:
                r, _, _ = select.select([0], [], [], 0.05)
                if r:
                    data = os.read(0, 4096)
                    self.pending += self.decoder.decode(data)
            except OSError:
                pass
        if self.pending[:1] == "[":
            i = 1
            while i < len(self.pending) and not ("\x40" <= self.pending[i] <= "\x7e"):
                i += 1
            self.pending = self.pending[i + 1:]
        elif self.pending[:1] == "O":
            self.pending = self.pending[2:]
        elif self.pending[:1] == "]":
            end = re.search(r"\x07|\x1b\\", self.pending)
            self.pending = self.pending[end.end():] if end else ""
        elif self.on_escape is not None:
            self.on_escape()


def short(text, n):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[:n]
