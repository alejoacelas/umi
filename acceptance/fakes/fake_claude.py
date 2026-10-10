#!/usr/bin/env python3
"""fake_claude.py - deterministic stand-in for
    claude -p --input-format stream-json --output-format stream-json --verbose
           --replay-user-messages --permission-prompt-tool stdio ...

Python 3.9, stdlib only. Shapes mirror what Claude Code 2.1.289 emitted in the
probes (see reference/PROTOCOLS.md). Fields that the real CLI sends but a driver is
unlikely to need (usage details, tool lists, ...) are present but minimal.
README.md in this directory documents every env var, trigger and chaos variation.

Supported flags: -p/--print, --session-id UUID, --resume/-r ID, --fork-session, --model M,
--permission-mode M, --effort E, --dangerously-skip-permissions, --plugin-dir DIR (repeatable),
-n/--name NAME, --version. Everything else is ignored.

Sessions persist as JSON under $FAKE_AGENT_DIR/claude/ (default: <tmp>/fake-agent).
Every user message handed to the "model" appends one line to
$FAKE_AGENT_DIR/receipts.jsonl.

Env: FAKE_CHAOS=<seed> (legal timing/noise/ordering variation), FAKE_SLOW_START=<secs>,
FAKE_MCP=<name:status,...> (servers listed in every system/init's mcp_servers with source
"project"; status one of connected, pending, failed, needs-auth), FAKE_WAKE_TURN_SECS=<secs>
(how long a self-started WAKE turn takes before its reply; default 1.5, like C11wake).

Triggers (substring of the user message text; text after `RUN ` is the command and
is not scanned for other triggers):
  WAKE n [text]    a Bash tool_use with run_in_background lasting n seconds (C11wake frames); reply
                   "started". After n s the fake starts a turn by itself (task_updated,
                   task_notification, background_tasks_changed, running, system/init, assistant
                   "woke: <text>" / "woke", result with origin task-notification, idle). No receipt;
                   one line in $FAKE_AGENT_DIR/self_turns.jsonl. The text is not scanned for triggers.
  CRASH            exit(1) mid-turn after the replay (stderr explains)
  FAIL             the turn fails like an API error (synthetic assistant "API Error: 404 ..." text,
                   result subtype "success" with is_error true and api_error_status 404); a model
                   name containing "no-such-model" does the same
  STATE            reply is one line of JSON: harness, session, model, effort, full_access,
                   permission_mode, cwd, argv (what this harness was told)
  SLEEP n          a Bash tool_use `sleep n` lasting n seconds (interruptible)
  RUN <cmd>        a Bash tool_use running <cmd> with /bin/sh in our cwd/env (interruptible);
                   reply "exit=<code>\\n<combined output>"
  HUGE n           a Bash tool_use whose output is n MB (fractions allowed)
  ASK_QUESTIONS    an AskUserQuestion tool_use with two questions (can_use_tool);
                   reply "answers: <question>=<answer>; ..." from updatedInput.answers
  ASK_PERMISSION[:name]
                   a Bash tool_use `touch <name>` (default fake_permission.txt) that needs a
                   can_use_tool control_request; reply "permission allowed" / "permission denied: <message>".
                   An allow answer's `updatedPermissions` is applied like the real CLI (C10): a matching
                   allow rule or setMode acceptEdits skips later prompts ("permission allowed (remembered)" /
                   "permission allowed (acceptEdits)"); destination session lives only in this process
  GARBAGE          non-JSON and blank lines on stdout around the reply
  STDERR_SPAM      ~2 MB written to stderr during the turn
  HANG             after the replay, stop responding to everything until killed
  EXIT_CLEAN       after the turn ends and the session is idle, exit 0
  IGNORE_TERM      the process ignores SIGTERM from then on (tests forced cleanup)
  SPAWN_STUBBORN   start a detached child (own session) that ignores SIGTERM;
                   its pid goes to $FAKE_AGENT_DIR/stubborn.pid
  ECHO             reply text == the user text
  PRINTENV NAME    reply with the value of environment variable NAME
  RECALL           reply "history: <previous user texts joined by ' | '>"
  default reply    "ok: <text>"
A user message arriving while a turn runs gets `command_lifecycle queued`; it is
injected at the next tool boundary (after SLEEP / RUN / HUGE / WAKE / ASK_*) like the real
CLI (replay + `started`, `completed` just before the shared `result`), otherwise
it runs as the next turn. Under FAKE_CHAOS it may also be left for the next turn.
An interrupt with "cancel_queued": true drops the queued messages (lifecycle `cancelled`,
response `cancelled: [uuids]`), as 2.1.296 does (C15cancelq).

Without -p/--print the fake is a line-oriented TUI on the same engine and session files (TUI mode):
a prompt line, typed lines are turns, replies are plain lines, Ctrl-C interrupts, /exit ends it.
Hooks from --plugin-dir DIR and $FAKE_CLAUDE_PLUGIN_DIRS (DIR/hooks/hooks.json) run in both modes, and
a transcript is appended to ${CLAUDE_CONFIG_DIR:-$FAKE_AGENT_DIR/claude-config}/projects/<slug>/<sid>.jsonl.
"""
import json
import os
import random
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid as uuidlib

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fake_common import Hooks, LineUI, append_line, claim_session, plugin_dirs, release_session, short  # noqa: E402

VERSION = "2.1.289"
CAPABILITIES = ["interrupt_receipt_v1", "interrupt_cancel_queued_v1", "interrupt_send_now_v1", "msg_lifecycle_v1",
                "request_marker_lists_v1", "sdk_mcp_tools_list_changed", "sdk_mcp_manifests", "mcp_read_resource_v1",
                "mcp_tool_ui_meta_v1", "ui_surface_v1"]     # system/init.capabilities in 2.1.296 (C14, C15)
IDLE_NOTIFY_SECS = 60.0    # the TUI's idle_prompt Notification
MODEL_ALIASES = {
    "haiku": "claude-haiku-4-5-20251001",
    "sonnet": "claude-sonnet-4-5-20250929",
    "opus": "claude-opus-4-1-20250805",
}
VALUE_FLAGS = set("""--session-id --resume --model --permission-mode --input-format --output-format
--permission-prompt-tool --system-prompt --append-system-prompt --system-prompt-file --max-turns
--allowedTools --allowed-tools --disallowedTools --disallowed-tools --mcp-config --settings --add-dir
--fallback-model --setting-sources --effort --max-thinking-tokens --thinking --thinking-display
--resume-session-at --resume-drops-turn --tools --betas --plugin-dir --json-schema --max-budget-usd
--agents --task-budget --agent --debug-file -n --name -r""".split())
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RUN_RE = re.compile(r"\bRUN[ \t]+(.+)")
INTERRUPT_TOOL_TEXT = ("The user doesn't want to proceed with this tool use. The tool use was rejected "
                       "(eg. if it was a file edit, the new_string was NOT written to the file). STOP what "
                       "you are doing and wait for the user to tell you how to proceed.")
STDIN_CLOSED_PERM = ("Tool permission request failed: AbortError: Tool permission stream closed "
                     "before response received")
TASK_STARTED_AFTER = 3.0   # the real Bash tool reports task_started ~3 s into a command (C2, C5, C9)
WAKE_RE = re.compile(r"\bWAKE[ \t]+([0-9]*\.?[0-9]+)(?=\s|$)")
WAKE_TURN_SECS = 1.5       # C11wake: ~1.5 s from task_notification to the self-started turn's result
BG_RESULT_TEXT = ("Command running in background with ID: %s. Output is being written to: %s. You will be "
                  "notified when it completes. To check interim output, use Read on that file path.")   # C11wake
MCP_STATUSES = ("connected", "pending", "failed", "needs-auth")
GARBAGE_LINES = ["", "this is not json", "   ", "\x1b[33mWARN\x1b[0m fake garbage on stdout",
                 "{\"type\": \"assistant\", \"truncated", "[object Object]"]


def now_iso():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def new_id():
    return str(uuidlib.uuid4())


def agent_root():
    return os.environ.get("FAKE_AGENT_DIR") or os.path.join(tempfile.gettempdir(), "fake-agent")


def write_receipt(harness, session, message, text, turn):
    """One JSON line per user message handed to the model; a single O_APPEND write."""
    rec = {"harness": harness, "session": session, "message": message, "text": text, "turn": turn,
           "pid": os.getpid(), "ts": time.time()}
    data = (json.dumps(rec) + "\n").encode("utf-8")
    root = agent_root()
    os.makedirs(root, exist_ok=True)
    fd = os.open(os.path.join(root, "receipts.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        while data:
            data = data[os.write(fd, data):]
    finally:
        os.close(fd)


def split_run(text):
    """(text scanned for triggers, RUN command or None). The command itself is never scanned."""
    m = RUN_RE.search(text)
    if not m:
        return text, None
    return text[:m.start()], m.group(1).strip()


def split_wake(trig):
    """(trig without the WAKE text, (seconds string, wake text) or None). The text is never scanned."""
    m = WAKE_RE.search(trig)
    if not m:
        return trig, None
    return trig[:m.end()], (m.group(1), trig[m.end():].strip())


def scan(text):
    """(text scanned for triggers, RUN command or None, WAKE (secs, text) or None)."""
    trig, run_cmd = split_run(text)
    trig, wake = split_wake(trig)
    return trig, run_cmd, wake


def parse_fake_mcp():
    """FAKE_MCP="name:status,..." -> [(name, status)]. A bad entry is a test-setup error: exit 2."""
    out = []
    for part in (os.environ.get("FAKE_MCP") or "").split(","):
        part = part.strip()
        if not part:
            continue
        name, sep, status = part.rpartition(":")
        name, status = name.strip(), status.strip()
        if not sep or not name or status not in MCP_STATUSES:
            sys.stderr.write("fake_claude: bad FAKE_MCP entry %r (want name:status with status one of %s)\n"
                             % (part, ", ".join(MCP_STATUSES)))
            sys.stderr.flush()
            sys.exit(2)
        out.append((name, status))
    return out


def write_self_turn(session, text):
    """One JSON line per turn the harness started by itself (WAKE); a single O_APPEND write."""
    rec = {"harness": "claude", "session": session, "text": text, "ts": time.time()}
    data = (json.dumps(rec) + "\n").encode("utf-8")
    root = agent_root()
    os.makedirs(root, exist_ok=True)
    fd = os.open(os.path.join(root, "self_turns.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        while data:
            data = data[os.write(fd, data):]
    finally:
        os.close(fd)


def short_id(n):
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(random.choice(alphabet) for _ in range(n))


def spam_stderr():
    chunk = "".join("fake stderr spam line %06d %s\n" % (i, "." * 70) for i in range(1000))
    for _ in range(20):          # ~2 MB; blocks if nobody drains our stderr (that is the point)
        sys.stderr.write(chunk)
        sys.stderr.flush()


def huge_output(mb):
    size = int(mb * 1024 * 1024)
    unit = "0123456789abcdef\n"
    return (unit * (size // len(unit) + 1))[:size], size


def spawn_stubborn():
    """A detached tool process (own session) that ignores SIGTERM; pid -> $FAKE_AGENT_DIR/stubborn.pid."""
    child = subprocess.Popen([sys.executable, "-c",
                              "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"],
                             start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    os.makedirs(agent_root(), exist_ok=True)
    with open(os.path.join(agent_root(), "stubborn.pid"), "w") as f:
        f.write(str(child.pid))


FS_COMMANDS = ("touch", "mkdir", "rm", "rmdir", "mv", "cp", "sed")   # acceptEdits auto-allows these (C10 t4)
PERSISTED_DESTINATIONS = ("localSettings", "projectSettings", "userSettings")


def settings_path(dest):
    """Where the real CLI keeps each persisted destination; userSettings stays inside FAKE_AGENT_DIR."""
    if dest == "localSettings":
        return os.path.join(os.getcwd(), ".claude", "settings.local.json")
    if dest == "projectSettings":
        return os.path.join(os.getcwd(), ".claude", "settings.json")
    return os.path.join(agent_root(), "claude", "user-settings.json")


def config_dir():
    """$CLAUDE_CONFIG_DIR, else $FAKE_AGENT_DIR/claude-config. Never the real ~/.claude."""
    d = os.environ.get("CLAUDE_CONFIG_DIR")
    real = os.path.realpath(os.path.expanduser("~/.claude"))
    if d and os.path.realpath(os.path.expanduser(d)) != real:
        return os.path.expanduser(d)
    return os.path.join(agent_root(), "claude-config")


def project_slug(cwd):
    """Claude Code's project directory name: every character but [A-Za-z0-9] becomes '-'
    (/Users/x/a/.b -> -Users-x-a--b, as in C14)."""
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def transcript_path(sid):
    return os.path.join(config_dir(), "projects", project_slug(os.getcwd()), sid + ".jsonl")


def rule_string(r):
    return "%s(%s)" % (r["toolName"], r["ruleContent"]) if r.get("ruleContent") else r["toolName"]


def rule_matches(rule, tool, command):
    """`Bash` (any command), `Bash(<exact command>)` or `Bash(<prefix>:*)`."""
    if rule == tool:
        return True
    if not (rule.startswith(tool + "(") and rule.endswith(")")):
        return False
    content = rule[len(tool) + 1:-1]
    if content.endswith(":*"):
        return command.startswith(content[:-2])
    return content == command


class Chaos(object):
    """FAKE_CHAOS=<int seed>: only legal variation (timing, partial writes, noise frames, orderings
    the real CLI was seen to produce). Seeded; exact interleavings still depend on thread timing."""

    def __init__(self):
        raw = (os.environ.get("FAKE_CHAOS") or "").strip()
        self.on = raw != ""
        try:
            seed = int(raw) if self.on else 0
        except ValueError:
            seed = sum((i + 1) * ord(c) for i, c in enumerate(raw))
        self._out = random.Random(seed * 2 + 1)    # write timing / splits
        self._dec = random.Random(seed * 2 + 2)    # behavioural choices
        self._lock = threading.Lock()

    def chance(self, p):
        if not self.on:
            return False
        with self._lock:
            return self._dec.random() < p

    def uniform(self, a, b):
        with self._lock:
            return self._dec.uniform(a, b)

    def randint(self, a, b):
        with self._lock:
            return self._dec.randint(a, b)

    def write(self, stream, line):
        """Write one line: in chaos mode after a 0-40 ms delay, sometimes as two writes 1-15 ms apart."""
        if self.on:
            with self._lock:
                delay = self._out.uniform(0.0, 0.04)
                cut = self._out.randint(1, len(line) - 1) if len(line) > 2 and self._out.random() < 0.2 else 0
                gap = self._out.uniform(0.001, 0.015)
            time.sleep(delay)
            if cut:
                stream.write(line[:cut])
                stream.flush()
                time.sleep(gap)
                stream.write(line[cut:])
                stream.flush()
                return
        stream.write(line)
        stream.flush()


class ShellRun(object):
    """A RUN command: /bin/sh -c CMD in its own process group, stdout+stderr combined."""

    def __init__(self, cmd, cwd):
        self.p = subprocess.Popen(["/bin/sh", "-c", cmd], cwd=cwd, env=dict(os.environ),
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  start_new_session=True)
        self.chunks = []
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        fd = self.p.stdout.fileno()
        while True:
            try:
                b = os.read(fd, 65536)
            except OSError:
                break
            if not b:
                break
            self.chunks.append(b)

    def done(self):
        return self.p.poll() is not None

    def output(self):
        self.reader.join(0.5)   # a backgrounded grandchild may keep the pipe open; don't wait for it
        return b"".join(self.chunks).decode("utf-8", "replace")

    def kill(self):
        try:
            os.killpg(self.p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            self.p.wait(2)
        except Exception:
            pass


def parse_args(argv):
    opts = {"session_id": None, "resume": None, "fork": False, "model": "default", "model_given": None,
            "effort": None, "permission_mode": "default", "skip_perms": False, "print": False, "plugin_dirs": [],
            "name": None, "prompt": None, "version": False}
    i = 0
    positional = []
    while i < len(argv):
        a = argv[i]
        val = None
        if a.startswith("--") and "=" in a:
            a, val = a.split("=", 1)
        if a in VALUE_FLAGS:
            if val is None:
                i += 1
                val = argv[i] if i < len(argv) else ""
            if a == "--session-id":
                opts["session_id"] = val
            elif a in ("--resume", "-r"):
                opts["resume"] = val
            elif a == "--plugin-dir":
                opts["plugin_dirs"].append(val)
            elif a in ("-n", "--name"):
                opts["name"] = val
            elif a == "--model":
                opts["model"] = val
                opts["model_given"] = val
            elif a == "--effort":
                opts["effort"] = val
            elif a == "--permission-mode":
                opts["permission_mode"] = val
        elif a == "--fork-session":
            opts["fork"] = True
        elif a in ("--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"):
            opts["skip_perms"] = a == "--dangerously-skip-permissions"
        elif a in ("-p", "--print"):
            opts["print"] = True
        elif a in ("-v", "--version"):
            opts["version"] = True
        elif not a.startswith("-"):
            positional.append(a)
        i += 1
    if opts["skip_perms"]:
        opts["permission_mode"] = "bypassPermissions"
    if positional:
        opts["prompt"] = " ".join(positional)
    return opts


class Interrupted(Exception):
    def __init__(self, rid, via_deny=False):
        Exception.__init__(self, rid)
        self.rid = rid
        self.via_deny = via_deny


class Turn(object):
    def __init__(self):
        self.interrupt_rid = None      # set by reader when an interrupt arrives
        self.interrupt_flag = False
        self.finishing = False         # past the last interrupt checkpoint
        self.perm = None               # pending permission dict
        self.tool_use_id = None        # tool currently running
        self.tool_kind = None          # "bash" | "perm"
        self.task_id = None            # set once task_started was emitted for the running tool
        self.task_desc = ""
        self.index = 0                 # result_index this turn will report
        # per-turn bookkeeping
        self.started = []              # uuids handed to the model in this turn
        self.denials = []
        self.num_turns = 1
        self.first_frame = True        # the first assistant frame carries user_message_uuid(s)
        self.first_response = True     # the first API response is followed by a rate_limit_event
        self.origin = None             # a self-started (WAKE) turn: the result's `origin` (C11wake)
        self.prompt_id = new_id()      # hook inputs' prompt_id (a steered message shares its turn's, C14)
        self.cancelled = None          # interrupt with cancel_queued: uuids dropped from the queue (C15)


class FakeClaude(object):
    def __init__(self, opts):
        self.opts = opts
        self.lock = threading.RLock()
        self.cv = threading.Condition(self.lock)
        self.out_lock = threading.Lock()
        self.pending = []              # queued, not yet started user messages
        self.turn_active = False       # between first `running` and `idle`
        self.turn = None
        self.eof = False
        self.last_is_error = False
        self.result_index = 0
        self.chaos = Chaos()
        self.hung = False              # HANG: drop all output and input
        self.exit_when_idle = False    # EXIT_CLEAN
        self.ignore_term = False       # IGNORE_TERM
        self.shells = set()            # running RUN commands
        self.state_events = os.environ.get("CLAUDE_CODE_SDK_READS_SESSION_STATE") in ("1", "true") or \
            os.environ.get("CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS") in ("1", "true")
        self.sess_dir = os.path.join(agent_root(), "claude")
        os.makedirs(self.sess_dir, exist_ok=True)
        self.model = MODEL_ALIASES.get(opts["model"], opts["model"])
        self.model_given = opts["model_given"]     # the model string as given (--model / set_model), or None
        self.perm_mode = opts["permission_mode"]
        self.history = []
        self.session_rules = {"allow": [], "deny": [], "ask": []}   # destination session / cliArg
        self.extra_dirs = []
        self.mcp = parse_fake_mcp()    # FAKE_MCP: [(name, status)] for system/init.mcp_servers
        self.bg_tasks = {}             # WAKE: running background tasks by task_id (insertion ordered)
        self.wakes_due = []            # WAKE: finished background tasks waiting for their self-started turn
        raw = os.environ.get("FAKE_WAKE_TURN_SECS")
        self.wake_turn_secs = float(raw) if raw not in (None, "") else WAKE_TURN_SECS
        self.hooks = Hooks("claude", plugin_dirs("FAKE_CLAUDE_PLUGIN_DIRS", opts["plugin_dirs"]))
        self.tui = None                # ClaudeTui in TUI mode (frames are rendered instead of printed)
        self.session_id = None
        self.title = None
        self.tr_path = None            # the transcript (projects/<slug>/<sid>.jsonl)
        self.tr_parent = None          # uuid of the last transcript entry (parentUuid chain)
        self.last_prompt_id = None
        self.started = False           # SessionStart ran (SessionEnd runs once at exit)
        self.exiting = False
        self.idle_since = None         # TUI idle_prompt notification

    # ------------------------------------------------------------ output
    def emit(self, obj):
        self.tap_transcript(obj)
        if self.tui is not None:
            if not self.hung:
                self.tui.frame(obj)
            return
        self.emit_raw(json.dumps(obj) + "\n")

    def emit_raw(self, line):
        if self.tui is not None:
            return                     # GARBAGE has no meaning on a terminal
        with self.out_lock:
            if self.hung:
                return
            try:
                self.chaos.write(sys.stdout, line)
            except (BrokenPipeError, ValueError):
                os._exit(1)

    def sysmsg(self, subtype, **kw):
        m = {"type": "system", "subtype": subtype}
        m.update(kw)
        m["uuid"] = new_id()
        m["session_id"] = self.session_id
        return m

    def state(self, st):
        if self.state_events:
            self.emit(self.sysmsg("session_state_changed", state=st, sdk_host_only=True))

    def lifecycle(self, cmd_uuid, st):
        if cmd_uuid:
            self.emit({"type": "command_lifecycle", "command_uuid": cmd_uuid, "state": st,
                       "uuid": new_id(), "session_id": self.session_id})

    def garbage(self):
        for line in GARBAGE_LINES:
            self.emit_raw(line + "\n")

    # ------------------------------------------------------------ chaos noise (shapes from C1/C9/CBash logs)
    def noise_thinking_tokens(self, turn):
        """system/thinking_tokens frames: seen after system/init and before later API responses."""
        if not self.chaos.chance(0.5):
            return
        total = 0
        for _ in range(self.chaos.randint(1, 3)):
            delta = self.chaos.randint(20, 150)
            total += delta
            m = {"type": "system", "subtype": "thinking_tokens", "estimated_tokens": total,
                 "estimated_tokens_delta": delta, "session_id": self.session_id, "uuid": new_id()}
            real = [u for u in turn.started if u]
            if real:
                m["user_message_uuid"] = real[0]
            self.emit(m)

    def rate_limit_event(self):
        reset = int(time.time()) + 3600
        return {"type": "rate_limit_event", "rate_limit_info": {
            "status": "allowed", "resetsAt": reset, "rateLimitType": "five_hour", "overageStatus": "rejected",
            "overageDisabledReason": "out_of_credits", "isUsingOverage": False,
            "unifiedWindows": {"five_hour": {"utilization": 0.06, "resetsAt": reset},
                               "seven_day": {"utilization": 0.05, "resetsAt": reset + 6 * 86400}}},
            "uuid": new_id(), "session_id": self.session_id}

    # ------------------------------------------------------------ sessions
    def sess_path(self, sid):
        return os.path.join(self.sess_dir, sid + ".json")

    def lock_path(self):
        return os.path.join(self.sess_dir, self.session_id + ".pid")

    def save(self):
        data = {"session_id": self.session_id, "cwd": os.getcwd(), "messages": self.history,
                "title": self.title, "transcript_path": self.tr_path}
        tmp = "%s.%d.tmp" % (self.sess_path(self.session_id), os.getpid())
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.sess_path(self.session_id))

    def fatal(self, msg):
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()
        sys.exit(1)

    def early_result_error(self, sid, msg):
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()
        if not self.opts["print"]:
            sys.exit(1)                # the TUI only prints the error
        self.emit({"type": "result", "subtype": "error_during_execution", "duration_ms": 0,
                   "duration_api_ms": 0, "is_error": True, "num_turns": 0, "stop_reason": None,
                   "session_id": sid, "total_cost_usd": 0, "usage": self.usage(), "modelUsage": {},
                   "permission_denials": [], "uuid": new_id(), "errors": [msg], "result_index": 0})
        sys.exit(1)

    def setup_session(self):
        o = self.opts
        if o["session_id"] is not None and not UUID_RE.match(o["session_id"]):
            self.fatal("Error: Invalid session ID. Must be a valid UUID.")
        if o["session_id"] and o["resume"] and not o["fork"]:
            self.fatal("Error: --session-id can only be used with --continue or --resume if "
                       "--fork-session is also specified.")
        if o["resume"]:
            rid = o["resume"]
            if not UUID_RE.match(rid):
                self.session_id = new_id()
                self.early_result_error(self.session_id, (
                    "Error: --resume requires a valid session ID or session title when used with --print. "
                    "Usage: claude -p --resume <session-id|title>. Provided value \"%s\" is not a UUID and "
                    "does not match any session title." % rid))
            if not os.path.exists(self.sess_path(rid)):
                self.session_id = rid
                self.early_result_error(rid, "No conversation found with session ID: %s" % rid)
            with open(self.sess_path(rid)) as f:
                data = json.load(f)
            self.history = data.get("messages", [])
            self.title = data.get("title")
            if not o["fork"]:
                self.tr_path = data.get("transcript_path")
            self.session_id = (o["session_id"] or new_id()) if o["fork"] else rid
        else:
            sid = o["session_id"] or new_id()
            if os.path.exists(self.sess_path(sid)):
                self.fatal("Error: Session ID %s is already in use." % sid)
            self.session_id = sid
        if o["name"]:
            self.title = o["name"]
        if not self.tr_path:
            self.tr_path = transcript_path(self.session_id)
        # one process per session: a second live fake on this session is a violation (logged, not refused)
        claim_session(self.lock_path(), "claude", self.session_id)

    # ------------------------------------------------------------ transcript (projects/<slug>/<sid>.jsonl)
    def tr_write(self, entry, chained=True):
        """Append one transcript line, shaped like Claude Code's (2.1.296)."""
        if not self.tr_path:
            return
        e = {}
        if chained:
            e["parentUuid"] = self.tr_parent
            e.update({"isSidechain": False, "userType": "external", "cwd": os.getcwd(),
                      "sessionId": self.session_id, "version": VERSION})
        e.update(entry)
        e.setdefault("timestamp", now_iso())
        if not chained:
            e.setdefault("sessionId", self.session_id)
        if chained:
            e.setdefault("uuid", new_id())
            self.tr_parent = e["uuid"]
        try:
            append_line(self.tr_path, json.dumps(e) + "\n")
        except OSError:
            pass

    def tap_transcript(self, obj):
        """Assistant frames and tool results / interrupt markers go to the transcript as they are emitted.
        User messages are written by on_user / start_item."""
        t = obj.get("type")
        if t == "assistant":
            m = obj["message"]
            self.tr_write({"type": "assistant", "uuid": obj["uuid"], "requestId": obj.get("request_id"),
                           "message": {"id": m["id"], "type": "message", "role": "assistant", "model": m["model"],
                                       "content": m["content"], "stop_reason": m.get("stop_reason"),
                                       "usage": m.get("usage")}})
        elif t == "user" and not obj.get("isReplay"):
            entry = {"type": "user", "uuid": obj["uuid"], "message": obj["message"]}
            if "tool_use_result" in obj:
                entry["toolUseResult"] = obj["tool_use_result"]
            self.tr_write(entry)

    # ------------------------------------------------------------ hooks
    def effort_obj(self):
        return {"level": self.opts["effort"] or "medium"}

    def hook_input(self, event, turn=None, perm=True, effort=False, **fields):
        d = {"session_id": self.session_id, "transcript_path": self.tr_path, "cwd": os.getcwd()}
        if turn is not None:
            d["prompt_id"] = turn.prompt_id
        if perm:
            d["permission_mode"] = self.perm_mode
        if effort:
            d["effort"] = self.effort_obj()
        d["hook_event_name"] = event
        d.update(fields)
        return d

    def fire(self, event, payload, match=None, on_start=None, on_done=None):
        if self.hooks.has(event):
            self.hooks.run(event, payload, os.getcwd(), match=match, on_start=on_start, on_done=on_done)

    def session_start_hooks(self, source):
        """SessionStart at startup. In -p mode the real CLI reports each hook with system/hook_started and
        system/hook_response before it answers `initialize` (C14headless, C14resume)."""
        self.started = True
        if not self.hooks.has("SessionStart"):
            return
        ids = {}

        def started(i, entry):
            ids[i] = new_id()
            if self.tui is None:
                self.emit(self.sysmsg("hook_started", hook_id=ids[i], hook_name="SessionStart:" + source,
                                      hook_event="SessionStart"))

        def done(i, entry, res):
            if self.tui is None:
                code = res["exit_code"] if res["exit_code"] is not None else 1
                self.emit(self.sysmsg("hook_response", hook_id=ids[i], hook_name="SessionStart:" + source,
                                      hook_event="SessionStart", output=res["stdout"] + res["stderr"],
                                      stdout=res["stdout"], stderr=res["stderr"], exit_code=code,
                                      outcome="success" if code == 0 else "error"))

        self.fire("SessionStart", self.hook_input("SessionStart", perm=False, source=source), match=source,
                  on_start=started, on_done=done)

    def before_exit(self, reason):
        """Runs once on a graceful end: SessionEnd hooks, release the session, restore the terminal."""
        with self.cv:
            if self.exiting:
                return
            self.exiting = True
        if self.started and self.hooks.has("SessionEnd"):
            d = {"session_id": self.session_id, "transcript_path": self.tr_path, "cwd": os.getcwd()}
            if self.last_prompt_id:
                d["prompt_id"] = self.last_prompt_id
            d.update({"hook_event_name": "SessionEnd", "reason": reason})
            self.fire("SessionEnd", d, match=reason)
        if self.session_id:
            release_session(self.lock_path())
        if self.tui is not None:
            self.tui.ui.restore()

    # ------------------------------------------------------------ shapes
    def usage(self):
        return {"input_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
                "output_tokens": 0, "server_tool_use": {"web_search_requests": 0, "web_fetch_requests": 0},
                "service_tier": "standard"}

    def init_response(self):
        return {"commands": [], "agents": [], "output_style": "default",
                "available_output_styles": ["default"], "models": [
                    {"value": "haiku", "resolvedModel": MODEL_ALIASES["haiku"], "displayName": "Haiku"}],
                "account": {"apiProvider": "firstParty"}, "pid": os.getpid(),
                "current_permission_mode": self.perm_mode, "fast_mode_state": "off",
                "session_state": "running" if self.turn_active else "idle", "capabilities": []}

    def system_init(self):
        # C13projectmcp: a server from the project's .mcp.json is {"name", "status", "source": "project"}
        mcp = [{"name": name, "status": status, "source": "project"} for name, status in self.mcp]
        # C14resume: a --plugin-dir plugin is {"name", "path", "source": "<name>@inline", "version"}
        # (an installed plugin's source would name its marketplace; FAKE_CLAUDE_PLUGIN_DIRS say "@installed")
        inline = set(os.path.realpath(os.path.abspath(d)) for d in self.opts["plugin_dirs"])
        plugins = [{"name": p["name"], "path": p["path"], "version": p["version"],
                    "source": "%s@%s" % (p["name"], "inline" if os.path.realpath(p["path"]) in inline else "installed")}
                   for p in self.hooks.plugins]
        return self.sysmsg("init", cwd=os.getcwd(), tools=["Bash", "Read", "Write", "Edit"], mcp_servers=mcp,
                           model=self.model, permissionMode=self.perm_mode, slash_commands=[],
                           apiKeySource="none", claude_code_version=VERSION, output_style="default",
                           agents=[], skills=[], plugins=plugins, capabilities=list(CAPABILITIES),
                           fast_mode_state="off")

    def assistant(self, content, turn_uuids=None, msg_id=None, req_id=None):
        m = {"type": "assistant",
             "message": {"model": self.model, "id": msg_id or "msg_fake_" + uuidlib.uuid4().hex[:20],
                         "type": "message", "role": "assistant", "content": content, "stop_reason": None,
                         "stop_sequence": None, "usage": self.usage()},
             "parent_tool_use_id": None, "session_id": self.session_id, "uuid": new_id(),
             "timestamp": now_iso(), "request_id": req_id or "req_fake_" + uuidlib.uuid4().hex[:16]}
        if turn_uuids:
            m["user_message_uuid"] = turn_uuids[0]
            m["user_message_uuids"] = list(turn_uuids)
        return m

    def frame_uuids(self, turn):
        if turn.first_frame:
            turn.first_frame = False
            return [u for u in turn.started if u] or None
        return None

    def api_response(self, turn, blocks):
        """One model response: each content block is its own assistant frame sharing message.id.
        Chaos adds what haiku really sends: thinking_tokens + a leading thinking block, and a
        rate_limit_event after the first response of a turn (C1, C9, CBash)."""
        msg_id = "msg_fake_" + uuidlib.uuid4().hex[:20]
        req_id = "req_fake_" + uuidlib.uuid4().hex[:16]
        if not turn.first_response:
            self.noise_thinking_tokens(turn)
        if self.chaos.chance(0.5):
            sig = uuidlib.uuid4().hex + uuidlib.uuid4().hex
            self.emit(self.assistant([{"type": "thinking", "thinking": "", "signature": sig}],
                                     self.frame_uuids(turn), msg_id, req_id))
        for b in blocks:
            self.emit(self.assistant([b], self.frame_uuids(turn), msg_id, req_id))
        if self.chaos.chance(0.6 if turn.first_response else 0.1):
            self.emit(self.rate_limit_event())
        turn.first_response = False

    def user_frame(self, content, **extra):
        m = {"type": "user", "message": {"role": "user", "content": content}, "parent_tool_use_id": None,
             "session_id": self.session_id, "uuid": new_id(), "timestamp": now_iso()}
        m.update(extra)
        return m

    def replay(self, msg):
        m = {"type": "user", "message": {"role": "user", "content": msg["content"]},
             "session_id": self.session_id, "parent_tool_use_id": None,
             "uuid": msg["uuid"] or new_id(), "timestamp": now_iso(), "isReplay": True}
        self.emit(m)

    def result(self, ok, text, uuids, denials, num_turns, started_at, errors=None, terminal="completed",
               stop="end_turn", api_error=None, origin=None):
        r = {"type": "result", "subtype": "success" if ok else "error_during_execution",
             "is_error": not ok, "duration_ms": int((time.time() - started_at) * 1000),
             "duration_api_ms": 0, "num_turns": num_turns, "stop_reason": stop,
             "session_id": self.session_id, "total_cost_usd": 0, "usage": self.usage(), "modelUsage": {},
             "permission_denials": denials, "terminal_reason": terminal, "fast_mode_state": "off",
             "uuid": new_id(), "queued_turn_count": 0, "result_index": self.result_index}
        if ok:
            r["result"] = text
            r["api_error_status"] = None
        else:
            r["errors"] = errors or []
        real = [u for u in uuids if u]
        if real:
            r["user_message_uuid"] = real[0]
            r["user_message_uuids"] = real
        if api_error is not None:
            # an API error ends the turn "successfully" with is_error set (the schema's api_error_status)
            r["is_error"] = True
            r["api_error_status"] = api_error
        if origin is not None:
            r["origin"] = origin      # a turn nobody sent (C11wake: kind task-notification)
        self.result_index += 1
        self.last_is_error = r["is_error"]
        return r

    # ------------------------------------------------------------ input
    def reader(self):
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            if self.hung:
                continue
            raw = line.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                sys.stderr.write("Error parsing streaming input line (type=unknown, %d chars): SyntaxError\n"
                                 % len(raw))
                sys.stderr.flush()
                os._exit(1)
            if not isinstance(msg, dict):
                continue
            t = msg.get("type")
            if t == "user":
                self.on_user(msg)
            elif t == "control_request":
                self.on_control_request(msg)
            elif t == "control_response":
                self.on_control_response(msg)
            # unknown types are silently ignored (matches the real CLI)
        if self.hung:
            return   # a hung process does not notice EOF either
        with self.cv:
            self.eof = True
            turn = self.turn
            if turn is not None and turn.perm is not None and turn.perm.get("response") is None:
                turn.perm["response"] = {"subtype": "stdin_closed"}
            self.cv.notify_all()

    def on_user(self, msg):
        content = (msg.get("message") or {}).get("content", "")
        if isinstance(content, list):
            text = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
        else:
            text = str(content)
        item = {"uuid": msg.get("uuid"), "text": text, "content": content}
        self.submit(item)

    def submit(self, item):
        """A user message (stream-json or typed in the TUI) joins the queue."""
        with self.cv:
            if not self.turn_active:
                self.turn_active = True
                self.state("running")
            else:
                # a message that waits behind a running turn (2.1.296 transcript: queue-operation enqueue)
                item["queued"] = True
                self.tr_write({"type": "queue-operation", "operation": "enqueue", "content": item["text"]},
                              chained=False)
            self.lifecycle(item["uuid"], "queued")
            self.pending.append(item)
            self.idle_since = None
            self.cv.notify_all()

    def on_control_request(self, msg):
        rid = msg.get("request_id")
        req = msg.get("request") or {}
        sub = req.get("subtype")

        def ok(resp):
            self.emit({"type": "control_response",
                       "response": {"subtype": "success", "request_id": rid, "response": resp}})

        if sub == "initialize":
            ok(self.init_response())
        elif sub == "interrupt":
            with self.cv:
                cancelled = None
                if req.get("cancel_queued"):
                    # C15cancelq: queued messages are dropped at once (lifecycle cancelled, before the answer)
                    cancelled = [p["uuid"] for p in self.pending if p["uuid"]]
                    for p in self.pending:
                        self.lifecycle(p["uuid"], "cancelled")
                        self.tr_write({"type": "queue-operation", "operation": "remove"}, chained=False)
                    del self.pending[:]
                turn = self.turn
                if turn is not None and not turn.finishing and not turn.interrupt_flag:
                    turn.interrupt_flag = True
                    turn.interrupt_rid = rid
                    turn.cancelled = cancelled
                    self.cv.notify_all()
                    return
                queued = [p["uuid"] for p in self.pending if p["uuid"]]
                if cancelled is not None and turn is None and not self.pending and not self.wakes_due \
                        and self.turn_active:
                    self.turn_active = False      # nothing left to run
                    self.state("idle")
            resp = {"still_queued": queued}
            if cancelled is not None:
                resp["cancelled"] = cancelled
            ok(resp)
        elif sub == "set_permission_mode":
            self.perm_mode = req.get("mode", self.perm_mode)
            ok({})
        elif sub == "set_model":
            m = req.get("model") or "default"
            self.model = MODEL_ALIASES.get(m, m)
            self.model_given = req.get("model")
            ok({})
        else:
            self.emit({"type": "control_response", "response": {
                "subtype": "error", "request_id": rid, "error": "Unsupported control request subtype: %s" % sub}})

    def on_control_response(self, msg):
        resp = msg.get("response") or {}
        rid = resp.get("request_id")
        with self.cv:
            turn = self.turn
            if turn is None or turn.perm is None or turn.perm["request_id"] != rid \
                    or turn.perm.get("response") is not None:
                return  # unknown / late answers are dropped silently
            turn.perm["response"] = resp
            turn.perm["raw"] = msg    # echoed by the worker after `running`, as the real CLI does
            self.cv.notify_all()

    # ------------------------------------------------------------ process-level behaviours
    def on_sigterm(self, signum, frame):
        if self.ignore_term and signum == signal.SIGTERM:
            return
        for sh in list(self.shells):
            sh.kill()
        self.before_exit("other")
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    def hang(self):
        """HANG: stay alive, emit nothing, ignore stdin (and its EOF) until killed."""
        with self.out_lock:
            self.hung = True
        while True:
            time.sleep(3600)

    def exit_now(self):
        self.before_exit("other")      # C14: `claude -p` ends with SessionEnd reason "other" at stdin EOF
        with self.out_lock:
            try:
                sys.stdout.flush()
            except Exception:
                pass
        os._exit(1 if self.last_is_error else 0)

    # ------------------------------------------------------------ turns
    def wait_until(self, turn, deadline=None, pred=None):
        """Block until pred() / deadline; raise Interrupted if an interrupt arrives."""
        with self.cv:
            while True:
                if turn.interrupt_flag:
                    raise Interrupted(turn.interrupt_rid)
                if pred is not None and pred():
                    return
                if deadline is not None and time.time() >= deadline:
                    return
                rem = None if deadline is None else max(0.0, deadline - time.time())
                self.cv.wait(0.05 if rem is None else min(rem, 0.05))

    def crash(self):
        if self.tui is not None:
            self.tui.ui.restore()
        sys.stderr.write("fake_claude: CRASH requested\n")
        sys.stderr.flush()
        os._exit(1)

    def state_json(self):
        return json.dumps({"harness": "claude", "session": self.session_id, "model": self.model_given,
                           "effort": self.opts["effort"], "full_access": self.perm_mode == "bypassPermissions",
                           "permission_mode": self.perm_mode, "cwd": os.getcwd(), "argv": sys.argv[1:]})

    def reply_for(self, item, trig, extra):
        text = item["text"]
        if "STATE" in trig:
            return self.state_json()
        if extra is not None:
            return extra
        m = re.search(r"PRINTENV\s+(\w+)", trig)
        if m:
            return os.environ.get(m.group(1), "<unset>")
        if "ECHO" in trig:
            return text
        if "RECALL" in trig:
            prev = [h["text"] for h in self.history if h["role"] == "user" and h.get("uuid") != item["uuid"]]
            prev = [p for p in prev if p != text]
            return "history: " + " | ".join(prev)
        return "ok: " + text

    def start_item(self, turn, item, injected=False):
        """The message becomes part of this turn (handed to the model)."""
        self.lifecycle(item["uuid"], "started")
        turn.started.append(item["uuid"])
        self.history.append({"role": "user", "text": item["text"], "uuid": item["uuid"]})
        if self.title is None and item["text"].strip():
            self.title = short(item["text"], 40)
            if self.tui is not None:
                self.tui.set_title()
        self.save()
        write_receipt("claude", self.session_id, item["uuid"], item["text"], turn.index)
        if injected:
            # 2.1.296: a steered message lands as a queued_command attachment, then leaves the queue
            self.tr_write({"type": "attachment", "attachment": {
                "type": "queued_command", "prompt": item["text"], "source_uuid": item["uuid"],
                "commandMode": "prompt"}})
            self.tr_write({"type": "queue-operation", "operation": "remove"}, chained=False)
        else:
            if item.get("queued"):
                self.tr_write({"type": "queue-operation", "operation": "dequeue"}, chained=False)
            self.tr_write({"type": "user", "uuid": item["uuid"] or new_id(),
                           "message": {"role": "user", "content": item["content"]}})
        self.last_prompt_id = turn.prompt_id
        # C14: UserPromptSubmit fires for every message, a steered one included (same prompt_id)
        self.fire("UserPromptSubmit", self.hook_input("UserPromptSubmit", turn, prompt=item["text"]))

    def delivered(self, item):
        """Checks that happen right after the model received a message."""
        trig = scan(item["text"])[0]
        if "CRASH" in trig:
            self.crash()
        if "HANG" in trig:
            self.hang()

    def run_turn(self, first):
        turn = self.turn
        turn.index = self.result_index
        t0 = time.time()
        self.start_item(turn, first)
        self.emit(self.system_init())
        self.noise_thinking_tokens(turn)
        self.replay(first)
        self.delivered(first)
        work = [first]
        replies = []
        garbage = False
        try:
            while work:
                item = work.pop(0)
                trig, run_cmd, wake = scan(item["text"])
                if "FAIL" in trig or "no-such-model" in self.model:
                    with self.cv:
                        turn.finishing = True
                    self.finish_api_error(turn, t0)
                    return
                used_tool = False
                extra = None
                if "IGNORE_TERM" in trig:
                    self.ignore_term = True
                if "SPAWN_STUBBORN" in trig:
                    spawn_stubborn()
                if "EXIT_CLEAN" in trig:
                    self.exit_when_idle = True
                if "GARBAGE" in trig:
                    garbage = True
                if "STDERR_SPAM" in trig:
                    spam_stderr()
                m = re.search(r"SLEEP\s+([0-9]*\.?[0-9]+)", trig)
                if m:
                    used_tool = True
                    self.bash_tool(turn, "sleep %s" % m.group(1), "Sleep %s seconds" % m.group(1),
                                   secs=float(m.group(1)))
                if wake is not None:
                    used_tool = True
                    self.background_bash(turn, wake[0], wake[1])
                    extra = "started"
                m = re.search(r"HUGE\s+([0-9]*\.?[0-9]+)", trig)
                if m:
                    used_tool = True
                    out, size = huge_output(float(m.group(1)))
                    self.bash_tool(turn, "yes 0123456789abcdef | head -c %d" % size, "Print a lot of output",
                                   secs=0, output=out)
                    extra = "huge: %s MB" % m.group(1)
                m = re.search(r"ASK_PERMISSION(?::([\w.-]+))?", trig)
                if m:
                    used_tool = True
                    turn.num_turns += 1
                    extra = self.ask_permission(turn, target=m.group(1))
                if "ASK_QUESTIONS" in trig:
                    used_tool = True
                    turn.num_turns += 1
                    extra = self.ask_permission(turn, questions=True)
                if run_cmd is not None:
                    used_tool = True
                    code, out = self.bash_tool(turn, run_cmd, "Run the requested command", shell=run_cmd)
                    extra = "exit=%d\n%s" % (code, out.rstrip("\n"))
                replies.append(self.reply_for(item, trig, extra))
                if used_tool:
                    with self.cv:
                        if self.pending and self.chaos.chance(0.5):
                            injected = []   # chaos: left queued; runs as the next turn (C2 / C9b shape)
                        else:
                            injected = self.pending[:]
                            del self.pending[:]
                    for inj in injected:
                        self.replay(inj)
                        self.start_item(turn, inj, injected=True)
                        self.delivered(inj)
                        work.append(inj)
            with self.cv:
                if turn.interrupt_flag:
                    raise Interrupted(turn.interrupt_rid)
                turn.finishing = True
        except Interrupted as e:
            self.finish_interrupted(turn, e, t0)
            return
        final = "\n".join(replies)
        if garbage:
            self.garbage()
        self.api_response(turn, [{"type": "text", "text": final}])
        self.history.append({"role": "assistant", "text": final})
        self.save()
        self.stop_hook(turn, final)
        for u in turn.started[1:]:
            self.lifecycle(u, "completed")
        self.emit(self.result(True, final, turn.started, turn.denials, turn.num_turns, t0))
        self.lifecycle(turn.started[0], "completed")
        if garbage:
            self.garbage()

    def bash_tool(self, turn, command, description, secs=None, shell=None, output=""):
        """A Bash tool_use: SLEEP (secs), HUGE (secs=0 + output) or RUN (shell). Interruptible.
        task_started only fires once the command has run ~3 s, and task_notification only after it."""
        turn.num_turns += 1
        tid = "toolu_fake_" + uuidlib.uuid4().hex[:20]
        tool_input = {"command": command, "description": description}
        self.api_response(turn, [{"type": "tool_use", "id": tid, "name": "Bash", "input": tool_input}])
        turn.tool_use_id, turn.tool_kind = tid, "bash"
        turn.task_id, turn.task_desc = None, description
        self.pre_tool(turn, "Bash", tool_input, tid)
        start = time.time()
        sh = None
        if shell is not None:
            cwd = os.getcwd()
            sh = ShellRun(shell, cwd)
            self.shells.add(sh)
        try:
            while True:
                if sh is not None:
                    if sh.done():
                        break
                elif time.time() >= start + secs:
                    break
                if turn.task_id is None and time.time() - start >= TASK_STARTED_AFTER:
                    turn.task_id = "b" + uuidlib.uuid4().hex[:8]
                    self.emit(self.sysmsg("task_started", task_id=turn.task_id, tool_use_id=tid,
                                          description=description, is_backgrounded=False, task_type="local_bash"))
                end = time.time() + 0.05
                if sh is None:
                    end = min(end, start + secs)
                self.wait_until(turn, deadline=end)
        except Interrupted:
            if sh is not None:
                sh.kill()
                self.shells.discard(sh)
            raise
        code = 0
        if sh is not None:
            self.shells.discard(sh)
            output = sh.output()
            code = sh.p.returncode
        if turn.task_id is not None:
            self.emit(self.sysmsg("task_notification", task_id=turn.task_id, tool_use_id=tid,
                                  status="completed", output_file="", summary=description))
        shown = output.rstrip("\n")
        result = {"stdout": shown, "stderr": "", "interrupted": False, "isImage": False,
                  "noOutputExpected": shown == ""}
        self.post_tool(turn, "Bash", tool_input, tid, result, start)
        self.emit(self.user_frame([{"tool_use_id": tid, "type": "tool_result", "content": shown,
                                    "is_error": code != 0}], tool_use_result=result))
        turn.tool_use_id = None
        turn.task_id = None
        return code, output

    # ------------------------------------------------------------ tool and stop hooks (C14)
    def pre_tool(self, turn, tool, tool_input, tid):
        self.fire("PreToolUse", self.hook_input("PreToolUse", turn, effort=True, tool_name=tool,
                                                tool_input=tool_input, tool_use_id=tid), match=tool)

    def post_tool(self, turn, tool, tool_input, tid, result, start):
        self.fire("PostToolUse", self.hook_input("PostToolUse", turn, effort=True, tool_name=tool,
                                                 tool_input=tool_input, tool_response=result, tool_use_id=tid,
                                                 duration_ms=int((time.time() - start) * 1000)), match=tool)

    def stop_hook(self, turn, final):
        """Stop, before the turn's result. background_tasks lists the WAKE tasks still running."""
        if not self.hooks.has("Stop"):
            return
        with self.cv:
            tasks = self.bg_task_list()
        self.fire("Stop", self.hook_input("Stop", turn, effort=True, stop_hook_active=False,
                                          last_assistant_message=final, background_tasks=tasks, session_crons=[]))

    # ------------------------------------------------------------ background tasks and self-started turns (C11wake)
    def bg_task_list(self):
        """background_tasks_changed.tasks: the background tasks still running (caller holds the lock)."""
        return [{"task_id": t["task_id"], "run_id": t["run_id"], "task_type": "local_bash",
                 "description": t["description"]} for t in self.bg_tasks.values() if not t["done"]]

    def background_bash(self, turn, secs, text):
        """WAKE: a Bash tool_use with run_in_background. The tool returns at once; after `secs` seconds the
        task completes and the fake starts a turn by itself (wake_fire -> worker -> run_self_turn).
        Frames and texts as in C11wake: background_tasks_changed, task_started(is_backgrounded), tool_result."""
        turn.num_turns += 1
        tid = "toolu_fake_" + uuidlib.uuid4().hex[:20]
        command = "sleep %s" % secs
        tool_input = {"command": command, "run_in_background": True}
        self.api_response(turn, [{"type": "tool_use", "id": tid, "name": "Bash", "input": tool_input}])
        self.pre_tool(turn, "Bash", tool_input, tid)
        start = time.time()
        task_id = "b" + short_id(8)
        run_id = "%s-%s" % (short_id(9), uuidlib.uuid4().hex[:8])
        out_dir = os.path.join(agent_root(), "claude", "tasks", self.session_id)
        os.makedirs(out_dir, exist_ok=True)
        output_file = os.path.join(out_dir, task_id + ".output")
        open(output_file, "w").close()       # `sleep` prints nothing; the real CLI writes the output here
        task = {"task_id": task_id, "run_id": run_id, "tool_use_id": tid, "description": command,
                "output_file": output_file, "text": text, "done": False, "end_ms": None}
        with self.cv:
            self.bg_tasks[task_id] = task
            self.emit(self.sysmsg("background_tasks_changed", tasks=self.bg_task_list()))
        self.emit(self.sysmsg("task_started", task_id=task_id, run_id=run_id, tool_use_id=tid,
                              description=command, is_backgrounded=True, task_type="local_bash"))
        result = {"stdout": "", "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False,
                  "backgroundTaskId": task_id}
        self.post_tool(turn, "Bash", tool_input, tid, result, start)
        self.emit(self.user_frame([{"tool_use_id": tid, "type": "tool_result",
                                    "content": BG_RESULT_TEXT % (task_id, output_file), "is_error": False}],
                                  tool_use_result=result))
        timer = threading.Timer(float(secs), self.wake_fire, args=(task_id,))
        timer.daemon = True
        timer.start()

    def wake_fire(self, task_id):
        """Timer thread: the background command finished. The worker starts the self-started turn as soon
        as no other turn is running."""
        with self.cv:
            task = self.bg_tasks.get(task_id)
            if task is None or task["done"]:
                return
            task["done"] = True
            task["end_ms"] = int(time.time() * 1000)
            self.wakes_due.append(task)
            self.cv.notify_all()

    def begin_self_turn(self, task):
        """Caller holds the lock. C11wake order: task_updated, task_notification, background_tasks_changed
        (the remaining tasks), session_state_changed running. No user replay and no command_lifecycle."""
        self.bg_tasks.pop(task["task_id"], None)
        self.emit(self.sysmsg("task_updated", task_id=task["task_id"], run_id=task["run_id"],
                              patch={"status": "completed", "end_time": task["end_ms"]}))
        self.emit(self.sysmsg("task_notification", task_id=task["task_id"], run_id=task["run_id"],
                              tool_use_id=task["tool_use_id"], status="completed", output_file=task["output_file"],
                              summary='Background command "%s" completed (exit code 0)' % task["description"]))
        self.emit(self.sysmsg("background_tasks_changed", tasks=self.bg_task_list()))
        if not self.turn_active:
            self.turn_active = True
            self.state("running")

    def run_self_turn(self, task):
        """A turn nobody sent: system/init, (chaos noise), a pause of FAKE_WAKE_TURN_SECS, the reply, and a
        result with `origin` and no user_message_uuid(s). Interruptible like any turn."""
        turn = self.turn
        turn.index = self.result_index
        turn.origin = {"kind": "task-notification", "producer": "session-task", "runId": task["run_id"]}
        t0 = time.time()
        final = "woke: " + task["text"] if task["text"] else "woke"
        self.emit(self.system_init())
        write_self_turn(self.session_id, final)
        self.noise_thinking_tokens(turn)
        try:
            self.wait_until(turn, deadline=time.time() + self.wake_turn_secs)
            with self.cv:
                if turn.interrupt_flag:
                    raise Interrupted(turn.interrupt_rid)
                turn.finishing = True
        except Interrupted as e:
            self.finish_interrupted(turn, e, t0)
            return
        self.api_response(turn, [{"type": "text", "text": final}])
        self.history.append({"role": "assistant", "text": final})
        self.save()
        self.last_prompt_id = turn.prompt_id
        self.stop_hook(turn, final)     # no UserPromptSubmit: nobody sent anything
        self.emit(self.result(True, final, [], [], 1, t0, origin=turn.origin))

    # ------------------------------------------------------------ permission rules (C10)
    def load_settings(self, dest):
        try:
            with open(settings_path(dest)) as f:
                return json.load(f)
        except (IOError, ValueError):
            return {}

    def rules_for(self, behavior):
        rules = list(self.session_rules.get(behavior, []))
        for dest in PERSISTED_DESTINATIONS:
            rules += (self.load_settings(dest).get("permissions") or {}).get(behavior) or []
        return rules

    def allowed_without_prompt(self, command):
        """None, or why the real CLI would run this Bash command without asking."""
        if any(rule_matches(r, "Bash", command) for r in self.rules_for("deny") + self.rules_for("ask")):
            return None    # deny/ask rules are not modelled further: the prompt is shown
        if any(rule_matches(r, "Bash", command) for r in self.rules_for("allow")):
            return "permission allowed (remembered)"
        if self.perm_mode == "acceptEdits" and command.split()[:1] and command.split()[0] in FS_COMMANDS:
            return "permission allowed (acceptEdits)"
        return None

    def apply_permission_updates(self, updates):
        """Apply an allow answer's updatedPermissions. Returns the new mode if setMode changed it."""
        new_mode = None
        for u in updates if isinstance(updates, list) else []:
            if not isinstance(u, dict):
                continue
            kind, dest = u.get("type"), u.get("destination", "session")
            if kind in ("addRules", "replaceRules", "removeRules"):
                behavior = u.get("behavior", "allow")
                rules = [rule_string(r) for r in u.get("rules") or [] if isinstance(r, dict) and r.get("toolName")]
                if dest in PERSISTED_DESTINATIONS:
                    data = self.load_settings(dest)
                    perms = data.setdefault("permissions", {})
                    current = perms.get(behavior) or []
                else:
                    current = self.session_rules.setdefault(behavior, [])
                if kind == "addRules":
                    current = current + [r for r in rules if r not in current]
                elif kind == "replaceRules":
                    current = rules
                else:
                    current = [r for r in current if r not in rules]
                if dest in PERSISTED_DESTINATIONS:
                    perms[behavior] = current
                    path = settings_path(dest)
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(path, "w") as f:
                        json.dump(data, f, indent=2)
                else:
                    self.session_rules[behavior] = current
            elif kind == "setMode" and u.get("mode"):
                if u["mode"] != self.perm_mode:
                    new_mode = u["mode"]
                self.perm_mode = u["mode"]
            elif kind == "addDirectories":
                self.extra_dirs += [d for d in u.get("directories") or [] if d not in self.extra_dirs]
            elif kind == "removeDirectories":
                self.extra_dirs = [d for d in self.extra_dirs if d not in (u.get("directories") or [])]
        return new_mode

    def ask_permission(self, turn, questions=False, target=None):
        tid = "toolu_fake_" + uuidlib.uuid4().hex[:20]
        target = target or "fake_permission.txt"
        cmd = "touch %s" % target
        tool = "AskUserQuestion" if questions else "Bash"
        if questions:
            inp = {"questions": [
                {"question": "Favorite color?", "header": "Color", "multiSelect": False,
                 "options": [{"label": "red", "description": ""}, {"label": "blue", "description": ""}]},
                {"question": "Which size?", "header": "Size", "multiSelect": False,
                 "options": [{"label": "S", "description": ""}, {"label": "L", "description": ""}]}]}
        else:
            inp = {"command": cmd, "description": "Create %s" % target}
        self.api_response(turn, [{"type": "tool_use", "id": tid, "name": tool, "input": inp}])
        turn.tool_use_id, turn.tool_kind = tid, "perm"
        self.pre_tool(turn, tool, inp, tid)
        start = time.time()
        bash_result = {"stdout": "", "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": True}
        auto = None
        if self.perm_mode == "bypassPermissions":
            auto = "permission allowed"
        elif not questions:
            auto = self.allowed_without_prompt(cmd)
        if auto is not None:
            self.post_tool(turn, tool, inp, tid, bash_result, start)
            self.emit(self.user_frame([{"tool_use_id": tid, "type": "tool_result", "content": "",
                                        "is_error": False}], tool_use_result=bash_result))
            turn.tool_use_id = None
            return auto
        rid = new_id()
        with self.cv:
            turn.perm = {"request_id": rid, "response": None, "input": inp, "tool_use_id": tid}
            eof = self.eof
        self.state("requires_action")
        request = {"subtype": "can_use_tool", "tool_name": tool, "display_name": tool, "input": inp,
                   "description": inp.get("description", "Questions for the user"),
                   "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": cmd}],
                                               "behavior": "allow", "destination": "localSettings"}]}
        if not questions:   # what the real CLI suggests for a Bash `touch` in the cwd (CBash, C10)
            request["permission_suggestions"] += [
                {"type": "addDirectories", "directories": [os.getcwd()], "destination": "session"},
                {"type": "setMode", "mode": "acceptEdits", "destination": "session"}]
            request["blocked_path"] = os.path.join(os.getcwd(), target)
        request["tool_use_id"] = tid
        if not questions:
            # PermissionRequest as the prompt is about to show; in the TUI also Notification permission_prompt
            self.fire("PermissionRequest", self.hook_input(
                "PermissionRequest", turn, effort=True, tool_name=tool, tool_input=inp,
                permission_suggestions=request["permission_suggestions"]), match=tool)
            if self.tui is not None:
                self.fire("Notification", self.hook_input(
                    "Notification", perm=True, message="Claude needs your permission to use %s" % tool,
                    notification_type="permission_prompt"), match="permission_prompt")
        self.emit({"type": "control_request", "request_id": rid, "request": request})
        if eof:
            with self.cv:
                turn.perm["response"] = {"subtype": "stdin_closed"}
        self.wait_until(turn, pred=lambda: turn.perm.get("response") is not None)
        resp = turn.perm["response"]
        allow = resp.get("subtype") == "success" and (resp.get("response") or {}).get("behavior") == "allow"
        if allow and not questions:
            new_mode = self.apply_permission_updates((resp.get("response") or {}).get("updatedPermissions"))
            if new_mode is not None:
                self.emit(self.sysmsg("status", status=None, permissionMode=new_mode))   # C10
        self.state("running")
        if turn.perm.get("raw") is not None:
            self.emit(turn.perm["raw"])   # the real CLI echoes the answer back on stdout
        denial = {"tool_name": "Bash", "tool_use_id": tid, "tool_input": inp}
        if resp.get("subtype") == "success" and (resp.get("response") or {}).get("behavior") == "allow":
            turn.perm = None
            if questions:
                answers = ((resp.get("response") or {}).get("updatedInput") or {}).get("answers") or {}
                self.post_tool(turn, tool, inp, tid, {"answers": answers}, start)
                self.emit(self.user_frame([{"tool_use_id": tid, "type": "tool_result", "content": json.dumps(answers),
                                            "is_error": False}], tool_use_result={"answers": answers}))
                turn.tool_use_id = None
                return "answers: " + "; ".join("%s=%s" % (k, answers[k]) for k in sorted(answers))
            self.post_tool(turn, tool, inp, tid, bash_result, start)
            self.emit(self.user_frame([{"tool_use_id": tid, "type": "tool_result", "content": "",
                                        "is_error": False}], tool_use_result=bash_result))
            turn.tool_use_id = None
            return "permission allowed"
        if resp.get("subtype") == "stdin_closed":
            message = STDIN_CLOSED_PERM
        elif resp.get("subtype") == "error":
            message = "Tool permission request failed: %s" % resp.get("error", "error")
        else:
            message = (resp.get("response") or {}).get("message", "")
        turn.denials.append(denial)
        if resp.get("subtype") == "success" and (resp.get("response") or {}).get("interrupt"):
            turn.perm = None
            raise Interrupted(None, via_deny=True)
        turn.perm = None
        self.emit(self.user_frame([{"type": "tool_result", "content": message, "is_error": True,
                                    "tool_use_id": tid}],
                                  tool_use_result="Error: " + message,
                                  tool_result_meta=[{"id": tid, "non_execution_kind": "permission-rule"}]))
        turn.tool_use_id = None
        return "permission denied: " + message

    def finish_api_error(self, turn, t0):
        """FAIL / bad model. Not probed against the real CLI: modelled on its result schema
        (api_error_status) and its synthetic "API Error: ..." assistant message."""
        text = ('API Error: 404 {"type":"error","error":{"type":"not_found_error","message":"model: %s"},'
                '"request_id":"req_fake_%s"}' % (self.model, uuidlib.uuid4().hex[:16]))
        m = self.assistant([{"type": "text", "text": text}], self.frame_uuids(turn))
        m["message"]["model"] = "<synthetic>"
        m["message"]["stop_reason"] = "stop_sequence"
        self.emit(m)
        self.history.append({"role": "assistant", "text": text})
        self.save()
        # an API error ends the turn with StopFailure instead of Stop (error type: inferred)
        self.fire("StopFailure", self.hook_input("StopFailure", turn, error="invalid_request",
                                                 last_assistant_message=text), match="invalid_request")
        for u in turn.started[1:]:
            self.lifecycle(u, "completed")
        self.emit(self.result(True, text, turn.started, turn.denials, turn.num_turns, t0, stop="stop_sequence",
                              api_error=404))
        self.lifecycle(turn.started[0], "completed")

    def finish_interrupted(self, turn, exc, t0):
        with self.cv:
            turn.finishing = True
            perm = turn.perm
            turn.perm = None
            queued = [p["uuid"] for p in self.pending if p["uuid"]]
        if perm is not None:
            self.emit({"type": "control_cancel_request", "request_id": perm["request_id"]})
            turn.denials.append({"tool_name": "Bash", "tool_use_id": perm["tool_use_id"], "tool_input": perm["input"]})
        if exc.rid is not None:
            resp = {"still_queued": queued}
            if turn.cancelled is not None:
                resp["cancelled"] = turn.cancelled
            self.emit({"type": "control_response", "response": {
                "subtype": "success", "request_id": exc.rid, "response": resp}})
        if turn.task_id is not None and turn.tool_use_id:
            # only when task_started had already fired (C1 vs C2)
            self.emit(self.sysmsg("task_notification", task_id=turn.task_id, tool_use_id=turn.tool_use_id,
                                  status="stopped", output_file="", summary=turn.task_desc))
        if perm is not None:
            self.state("running")
        terminal = "aborted_streaming"
        if turn.tool_use_id:
            terminal = "aborted_tools"
            self.emit(self.user_frame([{"type": "tool_result", "content": INTERRUPT_TOOL_TEXT, "is_error": True,
                                        "tool_use_id": turn.tool_use_id}],
                                      tool_use_result="User rejected tool use",
                                      tool_result_meta=[{"id": turn.tool_use_id,
                                                         "non_execution_kind": "user-rejected"}]))
            self.emit(self.user_frame([{"type": "text", "text": "[Request interrupted by user for tool use]"}]))
        else:
            self.emit(self.user_frame([{"type": "text", "text": "[Request interrupted by user]"}]))
        self.history.append({"role": "assistant", "text": "[interrupted]"})
        self.save()
        self.emit(self.result(False, None, turn.started, turn.denials, turn.num_turns + 1, t0, terminal=terminal,
                              stop="tool_use" if terminal == "aborted_tools" else None,
                              errors=["[ede_diagnostic] result_type=user last_content_type=n/a "
                                      "stop_reason=tool_use"], origin=turn.origin))
        for u in turn.started:
            self.lifecycle(u, "cancelled")

    def worker(self):
        while True:
            with self.cv:
                while not self.pending and not self.wakes_due and not self.eof:
                    self.cv.wait()
                item = wake = None
                if self.wakes_due:     # a finished background task goes first, right after the running turn
                    wake = self.wakes_due.pop(0)
                    self.turn = Turn()
                    self.begin_self_turn(wake)
                elif self.pending:
                    item = self.pending.pop(0)
                    self.turn = Turn()
                else:
                    break
            if wake is not None:
                self.run_self_turn(wake)
            else:
                self.run_turn(item)
            with self.cv:
                self.turn = None
                if not self.pending:
                    self.turn_active = False
                    self.state("idle")
                    self.idle_since = time.time()
                    if self.exit_when_idle:
                        self.exit_now()
        self.exit_now()

    def main(self):
        if self.opts["version"]:
            sys.stdout.write("%s (Claude Code)\n" % VERSION)
            return
        if not self.opts["print"]:
            ClaudeTui(self).main()
            return
        slow = float(os.environ.get("FAKE_SLOW_START") or 0)
        if slow > 0:
            time.sleep(slow)
        signal.signal(signal.SIGTERM, self.on_sigterm)
        self.setup_session()
        self.session_start_hooks("resume" if self.opts["resume"] else "startup")
        threading.Thread(target=self.reader, daemon=True).start()
        self.worker()


class ClaudeTui(object):
    """TUI mode: the same engine and session, shown as plain lines on a terminal.
    `> text` is a user message the model received, `⏺ text` a reply or tool call, `  ⎿  ...` a tool
    result; permission prompts and questions wait for a typed answer."""

    def __init__(self, app):
        self.app = app
        self.ui = LineUI("> ")
        self.req = None                 # the can_use_tool request waiting for a typed answer
        self.req_lock = threading.RLock()
        raw = os.environ.get("FAKE_CLAUDE_IDLE_SECS")
        self.idle_secs = float(raw) if raw not in (None, "") else IDLE_NOTIFY_SECS

    # ------------------------------------------------------------ startup and the input loop
    def main(self):
        app = self.app
        app.tui = self
        slow = float(os.environ.get("FAKE_SLOW_START") or 0)
        if slow > 0:
            time.sleep(slow)
        app.setup_session()
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, self.on_term)
        signal.signal(signal.SIGINT, self.on_sigint)
        self.ui.on_escape = lambda: threading.Thread(target=self.interrupt, daemon=True).start()
        self.ui.start()
        self.ui.say("✻ Fake Claude Code %s" % VERSION, "  session: %s" % app.session_id,
                    "  cwd: %s" % os.getcwd(), "")
        for h in app.history:          # a resumed conversation shows what was said
            self.ui.say(self.user_line(h["text"]) if h["role"] == "user" else self.reply_line(h["text"]))
        self.set_title()
        app.session_start_hooks("resume" if app.opts["resume"] else "startup")
        threading.Thread(target=app.worker, daemon=True).start()
        threading.Thread(target=self.idle_watch, daemon=True).start()
        if app.opts["prompt"]:
            self.send(app.opts["prompt"])
        self.ui.show_prompt()
        while True:
            line = self.ui.read_line()
            if line is None:
                if not self.ui.tty:            # piped input: let the work finish first
                    while self.app.turn_active or self.app.pending or self.app.wakes_due:
                        time.sleep(0.05)
                self.quit("other" if self.ui.hangup else "exit")
            text = line.strip()
            if not text:
                continue
            if self.answer(text):
                continue
            if text in ("/exit", "/quit"):
                self.quit("exit")
            self.send(text)

    def send(self, text):
        self.app.submit({"uuid": new_id(), "text": text, "content": text})

    def set_title(self):
        if self.app.title:
            self.ui.title("✳ " + self.app.title)

    def quit(self, reason):
        """/exit, EOF or a signal: whatever runs is abandoned (no Stop hook), SessionEnd runs."""
        for sh in list(self.app.shells):
            sh.kill()
        self.app.before_exit(reason)
        os._exit(0)

    def on_term(self, signum, frame):
        if self.app.ignore_term and signum == signal.SIGTERM:
            return
        for sh in list(self.app.shells):
            sh.kill()
        self.app.before_exit("other")
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    def on_sigint(self, signum, frame):
        threading.Thread(target=self.interrupt, args=(True,), daemon=True).start()

    def interrupt(self, hint=False):
        """Ctrl-C (or Esc) during a turn interrupts it; no hook fires. At the prompt it only hints."""
        app = self.app
        with app.cv:
            turn = app.turn
            if turn is not None and not turn.finishing and not turn.interrupt_flag:
                turn.interrupt_flag = True
                turn.interrupt_rid = None
                app.cv.notify_all()
                return
        if hint:
            self.ui.say("  (Ctrl-C does not quit: type /exit or press Ctrl-D)")

    def idle_watch(self):
        """Notification idle_prompt once the session has sat idle for FAKE_CLAUDE_IDLE_SECS after a turn."""
        app = self.app
        while True:
            time.sleep(0.1)
            with app.cv:
                since = app.idle_since
                due = since is not None and not app.turn_active and time.time() - since >= self.idle_secs
                if due:
                    app.idle_since = None
            if due and self.req is None:
                app.fire("Notification", app.hook_input("Notification", message="Claude is waiting for your input",
                                                        notification_type="idle_prompt"), match="idle_prompt")

    # ------------------------------------------------------------ rendering
    def user_line(self, text):
        return "> " + text.replace("\n", "\n  ")

    def reply_line(self, text):
        return "⏺ " + text.replace("\n", "\n  ")

    def frame(self, m):
        t = m.get("type")
        if t == "user" and m.get("isReplay"):
            c = m["message"]["content"]
            if isinstance(c, list):
                c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
            self.ui.say(self.user_line(str(c)))
        elif t == "assistant":
            for b in m["message"]["content"]:
                if b.get("type") == "text":
                    self.ui.say(self.reply_line(b["text"]))
                elif b.get("type") == "tool_use":
                    inp = b.get("input") or {}
                    if b["name"] == "Bash":
                        bg = " (background)" if inp.get("run_in_background") else ""
                        self.ui.say("⏺ Bash(%s)%s" % (inp.get("command", ""), bg))
                    else:
                        self.ui.say("⏺ %s" % b["name"])
        elif t == "user":
            for b in m["message"]["content"] if isinstance(m["message"]["content"], list) else []:
                if b.get("type") == "tool_result":
                    content = b.get("content") or ""
                    if not isinstance(content, str):
                        content = json.dumps(content)
                    lines = content.split("\n") if content else ["(No output)"]
                    shown = ["  ⎿  " + lines[0]] + ["     " + l for l in lines[1:3]]
                    if len(lines) > 3:
                        shown.append("     … +%d lines" % (len(lines) - 3))
                    self.ui.say(*shown)
        elif t == "result":
            if m.get("is_error") and str(m.get("terminal_reason", "")).startswith("aborted"):
                self.ui.say("  ⎿  Interrupted · What should Claude do instead?")
            else:
                self.ui.say("✻ Worked for %ds" % (m.get("duration_ms", 0) // 1000))
        elif t == "system" and m.get("subtype") == "task_notification" and str(m.get("summary", "")).startswith(
                "Background command"):
            self.ui.say("⏺ " + m["summary"])
        elif t == "control_request" and m["request"].get("subtype") == "can_use_tool":
            r = m["request"]
            with self.req_lock:
                self.req = {"rid": m["request_id"], "tool": r["tool_name"], "input": r["input"], "answers": {},
                            "questions": (r["input"].get("questions") or []) if r["tool_name"] == "AskUserQuestion"
                            else None}
            self.ask()
        elif t == "control_cancel_request":
            with self.req_lock:
                if self.req is not None and self.req["rid"] == m.get("request_id"):
                    self.req = None
                    self.ui.say("  ⎿  (request withdrawn)")

    def ask(self):
        with self.req_lock:
            req = self.req
            if req is None:
                return
            if req["questions"] is None:
                self.ui.say("", "%s command" % req["tool"], "  " + req["input"].get("command", ""),
                            "Do you want to proceed? [y]es / [a]lways / [n]o")
                return
            q = req["questions"][len(req["answers"])]
            opts = "  ".join("(%d) %s" % (i + 1, o.get("label")) for i, o in enumerate(q.get("options") or []))
            self.ui.say("", "? " + q["question"], "  " + opts + "   (type a number or an answer)")

    def answer(self, text):
        """A typed line answers the pending request, if there is one."""
        with self.req_lock:
            req = self.req
            if req is None:
                return False
            if req["questions"] is None:
                choice = text.lower()
                if choice in ("y", "yes"):
                    resp = {"behavior": "allow", "updatedInput": req["input"]}
                elif choice in ("a", "always"):
                    resp = {"behavior": "allow", "updatedInput": req["input"], "updatedPermissions": [
                        {"type": "addRules", "rules": [{"toolName": req["tool"],
                                                        "ruleContent": req["input"].get("command", "")}],
                         "behavior": "allow", "destination": "localSettings"}]}
                elif choice in ("n", "no"):
                    # the TUI's "No, and tell Claude what to do differently" stops the turn
                    resp = {"behavior": "deny", "message": "The user doesn't want to proceed with this tool use.",
                            "interrupt": True}
                else:
                    self.ask()
                    return True
            else:
                q = req["questions"][len(req["answers"])]
                labels = [o.get("label") for o in q.get("options") or []]
                if text.isdigit() and 1 <= int(text) <= len(labels):
                    text = labels[int(text) - 1]
                req["answers"][q["question"]] = text
                if len(req["answers"]) < len(req["questions"]):
                    self.ask()
                    return True
                resp = {"behavior": "allow", "updatedInput": dict(req["input"], answers=req["answers"])}
            self.req = None
        self.app.on_control_response({"type": "control_response", "response": {
            "subtype": "success", "request_id": req["rid"], "response": resp}})
        return True


if __name__ == "__main__":
    FakeClaude(parse_args(sys.argv[1:])).main()
