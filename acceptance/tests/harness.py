"""Black-box harness: isolated instances of the product, its CLI, processes, fakes and UI.

Nothing here knows how the product is built. It knows:
- what TEST_INTERFACE.md says a build provides (through the target file);
- the CLI contract (CLI.md);
- OS facts: processes, files, the accessibility tree.
"""

import json
import os
import plistlib
import pwd
import shutil
import signal
import subprocess
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FAKES = os.path.join(ROOT, "fakes")
FAKE_CLAUDE = os.path.join(FAKES, "fake_claude.py")
FAKE_CODEX = os.path.join(FAKES, "fake_codex.py")

# Keep the environment of whoever runs the tests (often an agent, or a terminal of some
# product) out of the product under test. The app's own environment reaches its panes' shells,
# so an agent the tests run in a pane would otherwise inherit, say, the outer Claude Code's
# CLAUDE_EFFORT or CLAUDE_CONFIG_DIR.
_SCRUB_PREFIXES = ("CLAUDE_", "CODEX_", "SHADE_", "WRAITH_", "GHOSTTY_", "FAKE_", "UMI_")
_SCRUB_KEYS = {"CLAUDECODE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "AI_AGENT"}


def clean_env():
    env = {}
    for key, value in os.environ.items():
        if key in _SCRUB_KEYS or key.startswith(_SCRUB_PREFIXES):
            continue
        env[key] = value
    return env


def wait_until(predicate, timeout=10, interval=0.1, message="condition"):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"timed out after {timeout}s waiting for {message}")


# ---------------------------------------------------------------------------------------------
# Target


class Target:
    def __init__(self, path, data=None):
        if data is None:
            with open(path) as f:
                data = json.load(f)
        self.data = data
        base = os.path.dirname(os.path.abspath(path))

        def resolve(p, rel_to=None):
            if p is None:
                return None
            p = os.path.expanduser(p)
            if os.path.isabs(p):
                return p
            return os.path.normpath(os.path.join(rel_to or base, p))

        self.path = path
        self.name = data["name"]
        self.app = resolve(data["app"])
        self.executable = resolve(data["executable"], self.app)
        self.cli_path = resolve(data["cli"], self.app)
        self.launch_args = data.get("launch_args", [])
        self.env_names = data["env"]
        self.installer = data.get("installer")
        self.build_cli = data.get("build_cli")
        self.release = data.get("release")
        self.restoration_safe = bool(data.get("restoration_safe", False))
        # Arguments for restart tests that need window restoration (restoration-safe builds only).
        self.restore_launch_args = data.get("restore_launch_args", [])
        self.other_products = data.get("other_products", [])
        self.other_names = data.get("other_names", [])
        # Command words that are relative paths ("./x", "../x") are relative to the target file.
        for spec in (self.release, self.installer):
            if spec and spec.get("command"):
                spec["command"] = [resolve(w) if w.startswith(("./", "../")) else w for w in spec["command"]]
        if self.build_cli and self.build_cli.get("source"):
            self.build_cli = dict(self.build_cli, source=resolve(self.build_cli["source"]))
        info_path = os.path.join(self.app, "Contents", "Info.plist")
        with open(info_path, "rb") as f:
            self.info = plistlib.load(f)
        self.bundle_id = self.info.get("CFBundleIdentifier")
        self.cli_name = os.path.basename(self.cli_path)

    @classmethod
    def from_installed(cls, target, app_path):
        """The same build, installed at another path."""
        data = dict(target.data, app=app_path)
        for key in ("executable", "cli"):
            if os.path.isabs(data[key]):
                data[key] = os.path.relpath(data[key], target.app)
        return cls(target.path, data)

    def subst(self, items, **values):
        out = []
        for item in items:
            for key, value in values.items():
                item = item.replace("{" + key + "}", value)
            out.append(item)
        return out


# ---------------------------------------------------------------------------------------------
# Processes


def ps_rows():
    """[(pid, ppid, stat, command line)] for every process."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,stat=,args="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 3:
            continue
        pid, ppid, stat = int(parts[0]), int(parts[1]), parts[2]
        rows.append((pid, ppid, stat, parts[3] if len(parts) > 3 else ""))
    return rows


def alive(pid):
    """True if the process exists and isn't a zombie."""
    for p, _, stat, _ in ps_rows():
        if p == pid:
            return not stat.startswith("Z")
    return False


def zombies():
    return [(p, pp) for p, pp, stat, _ in ps_rows() if stat.startswith("Z")]


def descendants(root):
    rows = ps_rows()
    children = {}
    for pid, ppid, _, _ in rows:
        children.setdefault(ppid, []).append(pid)
    out, queue = [], [root]
    while queue:
        pid = queue.pop()
        for child in children.get(pid, []):
            out.append(child)
            queue.append(child)
    return out


def processes_of_bundle(app_path):
    """Processes whose executable lives inside the app bundle."""
    prefix = os.path.realpath(app_path).rstrip("/") + "/"
    alt = app_path.rstrip("/") + "/"
    return [pid for pid, _, stat, args in ps_rows()
            if (args.startswith(prefix) or args.startswith(alt)) and not stat.startswith("Z")]


_LOGIN_ENV = None


def login_env():
    """The environment a new terminal window gives: the user's login shell, interactive, started
    from a clean slate (not from whatever environment runs the tests)."""
    global _LOGIN_ENV
    if _LOGIN_ENV is None:
        user = pwd.getpwuid(os.getuid())
        base = {"HOME": user.pw_dir, "USER": user.pw_name, "LOGNAME": user.pw_name, "SHELL": user.pw_shell,
                "TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
        out = subprocess.run([user.pw_shell, "-l", "-i", "-c", "printf '\\n__ENV__\\n'; env -0"], env=base,
                             capture_output=True, timeout=60, stdin=subprocess.DEVNULL).stdout
        body = out.split(b"\n__ENV__\n", 1)[-1]
        _LOGIN_ENV = dict(item.decode(errors="replace").split("=", 1) for item in body.split(b"\0") if b"=" in item)
    return _LOGIN_ENV


def login_which(name):
    import shutil
    return shutil.which(name, path=login_env().get("PATH", ""))


def holding_files_under(directory):
    """Pids of processes with a file (or their cwd) open under a directory."""
    out = subprocess.run(["lsof", "-t", "+D", directory], capture_output=True, text=True, timeout=60).stdout
    return {int(x) for x in out.split()}


def frontmost_pid():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    out = subprocess.run(["lsappinfo", "info", "-only", "pid", asn], capture_output=True, text=True).stdout
    digits = "".join(ch for ch in out.split("=")[-1] if ch.isdigit())
    return int(digits) if digits else None


# ---------------------------------------------------------------------------------------------
# Instances


class CLIError(AssertionError):
    pass


class Instance:
    """An isolated copy of the product: its own state directory, fake agent harnesses, and
    (optionally) its own running app."""

    def __init__(self, target, prefix="acc-", fakes=True, state_dir=None, env=None, restore=False):
        self.target = target
        self.restore = restore
        self.dir = state_dir or os.path.realpath(tempfile.mkdtemp(prefix=prefix))
        os.makedirs(self.dir, exist_ok=True)
        self.fake_dir = os.path.join(self.dir, "fake-agent")
        os.makedirs(self.fake_dir, exist_ok=True)
        self.env = clean_env()
        self.env[target.env_names["state_dir"]] = self.dir
        # Where the fake Claude writes its transcript (fakes/README.md); `start_agent` passes it on.
        self.claude_config = os.path.join(self.fake_dir, "claude-config")
        if fakes:
            self.env[target.env_names["claude_bin"]] = FAKE_CLAUDE
            self.env[target.env_names["codex_bin"]] = FAKE_CODEX
            # The agents' configuration folders, for the app and every pane's shell: nothing an
            # instance running fakes does (`agent plugins`, an agent typed in a pane) may reach the
            # user's own ~/.claude or ~/.codex. (Real-agent instances need the user's logins, so
            # their tests set these only on instances that never call a model.)
            self.env["CLAUDE_CONFIG_DIR"] = self.claude_config
            self.env["CODEX_HOME"] = os.path.join(self.fake_dir, "codex-home")
        if env:
            self.env.update(env)
        self.app_proc = None
        self.work = os.path.join(self.dir, "work")
        os.makedirs(self.work, exist_ok=True)

    # -- app

    def start_app(self, wait=True):
        env = dict(self.env)
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"   # like an app launched from the Dock
        log = open(os.path.join(self.dir, "app.log"), "ab")
        args = self.target.restore_launch_args if self.restore else self.target.launch_args
        self.app_proc = subprocess.Popen([self.target.executable, *args], env=env,
                                         stdout=log, stderr=subprocess.STDOUT, cwd=self.dir,
                                         start_new_session=True)
        if wait:
            wait_until(lambda: self.app_proc.poll() is None and self.cli("ls", check=False, timeout=10).returncode == 0,
                       45, interval=0.3, message="the app to answer `ls`")
        return self.app_proc

    @property
    def app_pid(self):
        return self.app_proc.pid if self.app_proc else None

    def app_running(self):
        return self.app_proc is not None and self.app_proc.poll() is None

    def quit_gracefully(self, timeout=30):
        """Ask the app to quit the way ⌘Q or a logout does (a quit Apple event), not with a signal."""
        if not self.app_running():
            return
        from AppKit import NSRunningApplication
        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(self.app_pid)
        if app is not None:
            app.terminate()
        try:
            self.app_proc.wait(timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError("the app didn't quit when asked to (a confirmation dialog?)") from None

    def quit_app(self, timeout=20):
        """Quit the app the way the system asks apps to (SIGTERM)."""
        if not self.app_running():
            return
        self.app_proc.send_signal(signal.SIGTERM)
        try:
            self.app_proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.app_proc.kill()
            self.app_proc.wait(5)

    def product_processes(self):
        """This instance's product processes: ones running from the app bundle that are the app, its
        descendants, or hold files in this instance's state directory."""
        mine = set(holding_files_under(self.dir))
        if self.app_pid:
            mine |= {self.app_pid, *descendants(self.app_pid)}
        return [pid for pid in processes_of_bundle(self.target.app) if pid in mine]

    def kill_everything(self):
        """kill -9 every process of this instance of the product."""
        victims = self.product_processes()
        for pid in victims:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.app_proc:
            try:
                self.app_proc.wait(10)
            except subprocess.TimeoutExpired:
                pass
        wait_until(lambda: not any(alive(p) for p in victims), 10, message="product processes gone")

    def cleanup(self):
        # Stop sessions first so nothing outlives the test.
        if self.app_running():
            try:
                for s in self.agents():
                    if s.get("running") or s.get("live") or s.get("location") == "live" \
                            or s.get("status") not in ("stopped", "error"):
                        self.cli("agent", "stop", s["id"], check=False, timeout=30)
            except Exception:  # noqa: BLE001
                pass
        self.quit_app()
        shutil.rmtree(self.dir, ignore_errors=True)

    # -- raw control requests (Umi's internal debug.* methods)

    def rpc(self, method, **params):
        """A raw control request to the app (for internal `debug.*` methods that the CLI doesn't
        expose). Raises AssertionError with the app's error."""
        import socket
        with open(os.path.join(self.dir, "instance.json")) as f:
            path = json.load(f)["socket"]
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(60)
        s.connect(path)
        s.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        reply = json.loads(data)
        if reply.get("error"):
            raise AssertionError(f"{method}: {reply['error']}")
        return reply.get("result", reply)

    # -- CLI

    def cli(self, *args, check=True, timeout=180, stdin=None, cwd=None, env=None):
        full_env = dict(self.env)
        if env:
            full_env.update(env)
        kwargs = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
        proc = subprocess.run([self.target.cli_path, *args], capture_output=True, text=True, timeout=timeout,
                              env=full_env, cwd=cwd or self.work, **kwargs)
        if check and proc.returncode != 0:
            raise CLIError(f"{self.target.cli_name} {' '.join(args)} exited {proc.returncode}\n"
                           f"stdout: {proc.stdout}\nstderr: {proc.stderr}")
        return proc

    def json(self, *args, **kwargs):
        proc = self.cli("--json", *args, **kwargs)
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as e:
            raise CLIError(f"not JSON from `{' '.join(args)}`: {proc.stdout!r}") from e

    # -- layout helpers

    def tree(self):
        return self.json("ls")

    def find_pane(self, pane_id):
        for window in self.tree()["windows"]:
            for tab in window["tabs"]:
                for pane in tab["panes"]:
                    if pane["id"] == pane_id or pane["id"].startswith(pane_id):
                        return window, tab, pane
        return None

    def find_agent_pane(self, session):
        for window in self.tree()["windows"]:
            for tab in window["tabs"]:
                for pane in tab["panes"]:
                    if pane.get("agent") == session:
                        return window, tab, pane
        return None

    # -- agent helpers

    def start_agent(self, kind, prompt=None, *options, name=None, chaos=None, background=True, env=None, cwd=None):
        args = ["agent", "start", kind, "--cwd", cwd or self.work, "--env", "FAKE_AGENT_DIR=" + self.fake_dir,
                "--env", "CLAUDE_CONFIG_DIR=" + self.claude_config]
        if chaos is not None:
            args += ["--env", f"FAKE_CHAOS={chaos}"]
        for key, value in (env or {}).items():
            args += ["--env", f"{key}={value}"]
        if name:
            args += ["--name", name]
        if background:
            args.append("--background")
        args += list(options)
        if prompt is not None:
            args.append(prompt)
        return self.json(*args)["session"]["id"]

    def send(self, session, text):
        return self.json("agent", "send", session, text)["message"]["id"]

    def wait(self, session, *options, timeout=60):
        proc = self.cli("--json", "agent", "wait", session, "--timeout", str(timeout), *options, check=False,
                        timeout=timeout + 60)
        try:
            return proc.returncode, json.loads(proc.stdout)
        except json.JSONDecodeError:
            raise AssertionError(f"`agent wait {session} {' '.join(options)}` exited {proc.returncode} without "
                                 f"a JSON answer: {(proc.stdout + proc.stderr).strip()[:500]!r}") from None

    def info(self, session):
        return self.json("agent", "info", session)

    def read_reply(self, session, message):
        return self.json("agent", "read", session, "--message", message)["reply"]

    def agents(self):
        return self.json("agent", "ls", timeout=30)["sessions"]

    def transcript(self, session):
        return self.json("agent", "read", session, "--transcript")["items"]

    def receipts(self):
        return read_jsonl(os.path.join(self.fake_dir, "receipts.jsonl"))

    def self_turns(self):
        """Turns the fake Claude started by itself (WAKE), from fakes/README.md's self_turns.jsonl."""
        return read_jsonl(os.path.join(self.fake_dir, "self_turns.jsonl"))

    def violations(self):
        """Lines of the fakes' violations.log: two processes ran one conversation at once."""
        path = os.path.join(self.fake_dir, "violations.log")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    # -- sessions shown in panes

    def screen(self, pane, scrollback=False):
        """What a pane's terminal shows (its text), or "" if the pane can't be read."""
        args = ["read", "--pane", pane] + (["--scrollback"] if scrollback else [])
        return self.cli(*args, check=False, timeout=30).stdout

    def type_line(self, pane, text):
        """Type a line into a pane's terminal (and press Enter), as a person would."""
        self.cli("send", "--pane", pane, "--enter", text, timeout=30)

    def session_view(self, pane):
        """What a pane shows of a session (Umi's internal `debug.agent.pane`): {"showing":
        "agent" (the read-only view) | "live" | "terminal", "session"?, "transcript"?, "texts"?,
        "buttons"?}."""
        return self.rpc("debug.agent.pane", pane=pane)

    def press(self, pane, title, field_text=None):
        """Press a button of a pane's read-only session view (Umi's internal `debug.agent.press`)."""
        params = {"pane": pane, "title": title}
        if field_text is not None:
            params["field_text"] = field_text
        return self.rpc("debug.agent.press", **params)

    def session_panes(self, session):
        """Every pane of the layout that shows the session (read-only or live)."""
        return [p for w in self.tree()["windows"] for t in w["tabs"] for p in t["panes"]
                if p.get("agent") == session]


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            if line.strip():
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass   # a line being written right now
    return out


# ---------------------------------------------------------------------------------------------
# UI through accessibility


class UI:
    """The app as a screen reader sees it: read the tree, press buttons, type."""

    def __init__(self, pid):
        import ApplicationServices as AX  # noqa: N812
        self.AX = AX
        self.pid = pid
        self.app = AX.AXUIElementCreateApplication(pid)

    @staticmethod
    def available():
        try:
            import ApplicationServices as AX  # noqa: N812
            return bool(AX.AXIsProcessTrusted())
        except Exception:  # noqa: BLE001
            return False

    def attr(self, element, name):
        err, value = self.AX.AXUIElementCopyAttributeValue(element, name, None)
        return value if err == 0 else None

    def role(self, e):
        return self.attr(e, "AXRole")

    def label(self, e):
        return self.attr(e, "AXTitle") or self.attr(e, "AXDescription") or ""

    def value(self, e):
        v = self.attr(e, "AXValue")
        return v if isinstance(v, str) else ""

    def windows(self):
        return list(self.attr(self.app, "AXWindows") or [])

    def walk(self, root=None, depth=0, max_depth=40):
        roots = [root] if root is not None else self.windows()
        for r in roots:
            yield r, depth
            if depth < max_depth:
                for child in self.attr(r, "AXChildren") or []:
                    yield from self.walk(child, depth + 1, max_depth)

    def find_all(self, pred, root=None):
        return [e for e, _ in self.walk(root) if pred(e)]

    def find(self, pred, root=None):
        for e, _ in self.walk(root):
            if pred(e):
                return e
        return None

    def texts(self, root=None):
        """Every visible label and text value, in tree order."""
        out = []
        for e, _ in self.walk(root):
            for t in (self.label(e), self.value(e)):
                if t:
                    out.append(t)
        return out

    def button(self, label, root=None):
        return self.find(lambda e: self.role(e) == "AXButton" and self.label(e) == label, root)

    def press(self, element):
        assert element is not None, "nothing to press"
        err = self.AX.AXUIElementPerformAction(element, "AXPress")
        assert err == 0, f"AXPress failed: {err}"

    def set_text(self, element, text):
        self.AX.AXUIElementSetAttributeValue(element, "AXFocused", True)
        err = self.AX.AXUIElementSetAttributeValue(element, "AXValue", text)
        assert err == 0, f"set value failed: {err}"

    def focus(self, element):
        self.AX.AXUIElementSetAttributeValue(element, "AXFocused", True)

    def activate(self):
        """Bring the app to the front (UI tests type into it)."""
        import AppKit
        app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(self.pid)
        app.activateWithOptions_(AppKit.NSApplicationActivateIgnoringOtherApps)
        time.sleep(0.3)

    def key(self, keycode, flags=0):
        import Quartz
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, keycode, down)
            if flags:
                Quartz.CGEventSetFlags(event, flags)
            Quartz.CGEventPostToPid(self.pid, event)
            time.sleep(0.03)

    def focused(self):
        return self.attr(self.app, "AXFocusedUIElement")

    def editable(self, element):
        if element is None:
            return False
        err, settable = self.AX.AXUIElementIsAttributeSettable(element, "AXValue", None)
        return err == 0 and bool(settable)

    def enter_text(self, text, element=None, replace=False):
        """Put text into the focused (or given) text input, as an input method or paste would.
        Synthetic keystrokes don't reach every kind of view; accessibility values do."""
        element = element or self.focused()
        assert self.editable(element), "the focused element doesn't take text through accessibility"
        self.focus(element)
        current = "" if replace else self.value(element)
        err = self.AX.AXUIElementSetAttributeValue(element, "AXValue", current + text)
        assert err == 0, f"setting the text failed: {err}"
        time.sleep(0.3)   # let the view take in the new text before the next key, as a typist would
        return element

    def focused_input(self, timeout=5):
        """The focused element once it takes text, or None."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            element = self.focused()
            if self.editable(element):
                return element
            time.sleep(0.1)
        return None

    def type_text(self, text):
        """Type text as keyboard input (unicode key events, no key codes involved)."""
        import Quartz
        for ch in text:
            for down in (True, False):
                event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
                Quartz.CGEventKeyboardSetUnicodeString(event, len(ch.encode("utf-16-le")) // 2, ch)
                Quartz.CGEventPostToPid(self.pid, event)
            time.sleep(0.01)

    # -- the menu bar: shortcuts are found by their key equivalent, not their title

    _MODS = {"shift": 1, "option": 2, "ctrl": 4}
    _VKEYS = {"left": 123, "right": 124, "up": 126, "down": 125, "return": 36, "tab": 48, "esc": 53}

    def menu_items(self):
        bar = self.attr(self.app, "AXMenuBar")
        out = []

        def walk(e):
            for child in self.attr(e, "AXChildren") or []:
                if self.role(child) == "AXMenuItem":
                    out.append(child)
                walk(child)
        walk(bar)
        return out

    def shortcut(self, spec):
        """The menu item bound to a shortcut like "cmd+ctrl+t" or "cmd+ctrl+left" (⌘ is required)."""
        parts = spec.lower().split("+")
        assert "cmd" in parts, "only ⌘ shortcuts are menu key equivalents"
        key = parts[-1]
        mods = sum(self._MODS[p] for p in parts[:-1] if p in self._MODS)
        for item in self.menu_items():
            if (self.attr(item, "AXMenuItemCmdModifiers") or 0) != mods:
                continue
            char = self.attr(item, "AXMenuItemCmdChar") or ""
            vkey = self.attr(item, "AXMenuItemCmdVirtualKey")
            if key in self._VKEYS and vkey == self._VKEYS[key]:
                return item
            if len(key) == 1 and char.lower() == key:
                return item
        return None

    def choose(self, item):
        """Choose a menu item the way a person does: open its menu, then pick the item."""
        top = item
        while top is not None and self.role(top) != "AXMenuBarItem":
            top = self.attr(top, "AXParent")
        if top is not None:
            self.press(top)
            time.sleep(0.3)
        assert self.attr(item, "AXEnabled") is not False, f"the menu item {self.label(item)!r} is disabled"
        self.press(item)
        time.sleep(0.3)

    def press_shortcut(self, spec):
        item = self.shortcut(spec)
        assert item is not None, f"no menu item has the shortcut {spec}"
        self.choose(item)

    def press_keys(self, spec):
        """A ⌘ shortcut: through its menu item if there is one, else as a key event (which text views,
        unlike terminal views, receive)."""
        item = self.shortcut(spec)
        if item is not None:
            return self.choose(item)
        parts = spec.lower().split("+")
        flags = sum({"cmd": self.CMD, "shift": self.SHIFT, "ctrl": self.CTRL, "option": self.OPT}[p] for p in parts[:-1])
        self.key(self.KEY[parts[-1]], flags)

    def menu_item(self, title_prefix):
        return next((i for i in self.menu_items() if self.label(i).startswith(title_prefix)), None)

    def all_text(self):
        """Everything the app shows as text, in tree order, as one string."""
        return "\n".join(self.texts())

    def text_area(self, containing):
        return self.find(lambda e: self.role(e) == "AXTextArea" and containing in self.value(e))

    # Key codes and modifier flags (Carbon / CGEventFlags).
    RETURN = 36
    ESCAPE = 53
    CMD = 1 << 20
    SHIFT = 1 << 17
    CTRL = 1 << 18
    OPT = 1 << 19
    KEY = {"a": 0, "s": 1, "b": 11, "e": 14, "t": 17, "o": 31, "p": 35, "r": 15, "n": 45, "m": 46, "j": 38,
           "z": 6, "left": 123, "right": 124}
