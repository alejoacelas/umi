#!/usr/bin/env python3
"""fake_codex.py - deterministic stand-in for `codex app-server --listen stdio://`.

Python 3.9, stdlib only. JSON-RPC 2.0 over newline-delimited stdio (the
"jsonrpc" field is optional on input and omitted on output, like the real
server). Shapes mirror codex-cli 0.160.0 as observed in the probes (see
reference/PROTOCOLS.md). README.md in this directory documents every env var,
trigger and chaos variation.

Implemented methods: initialize, initialized (notification), thread/start,
thread/resume, thread/unsubscribe, thread/turns/list, turn/start (new turn or
steer), turn/steer, turn/interrupt, thread/queue/{add,list,delete,start}
(experimental queue; auto-drains like the real one).

Threads persist as JSON under $FAKE_AGENT_DIR/codex/threads/ (default
<tmp>/fake-agent). A thread loaded by a live process holds a writer lock; a
second process gets "thread <id> already has an active writer". Every user
message handed to the "model" (= its userMessage item) appends one line to
$FAKE_AGENT_DIR/receipts.jsonl.

Env: FAKE_CHAOS=<seed>, FAKE_SLOW_START=<secs>, FAKE_INPUT_DELAY=<secs> (gap between
turn/started and the first userMessage item; an interrupt inside it drops the input),
FAKE_MCP=<name:status,...> (status connected/pending/failed/needs-auth): after thread/start and a
thread/resume that loads a thread, mcpServer/startupStatus/updated "starting" for each server, then
"ready" (connected), "failed" (failed), "failed" + failureReason "reauthenticationRequired"
(needs-auth) or nothing more (pending).

Triggers (substring of the user text; text after `RUN ` is the command and is not
scanned for other triggers):
  CRASH          exit(1) mid-turn (after the userMessage item)
  FAIL           turn fails like an API error (status systemError, `error`
                 notification, turn/completed status "failed"); a model name
                 containing "no-such-model" does the same
  SLEEP n        commentary agentMessage + commandExecution `sleep n` (n seconds,
                 interruptible); steered input is picked up after it
  RUN <cmd>      commandExecution running <cmd> with /bin/sh in the thread cwd and our env
                 (interruptible); reply "exit=<code>\\n<combined output>"
  HUGE n         commandExecution whose output is n MB
  ASK_QUESTIONS  item/tool/requestUserInput with two questions; reply
                 "answers: <id>=<answer>; ..."
  ASK_PERMS / ASK_URL / ASK_FORM
                 item/permissions/requestApproval (write /tmp/x, network) or an MCP
                 elicitation (url or form mode); reply "result: <the client's JSON result>"
  ASK_APPROVAL[:name]
                 commandExecution `touch <name>` (default fake_approval.txt) needing approval when
                 approvalPolicy != "never": server request item/commandExecution/requestApproval; reply
                 "approval accepted" / "approval declined"; "cancel" interrupts. "acceptForSession"
                 skips later approvals of the same command in that thread for this process (X13);
                 acceptWithExecpolicyAmendment appends a prefix_rule to <codexHome>/rules/default.rules
                 (persistent, all threads). Skipped approvals reply "approval accepted (remembered)"
  GARBAGE        non-JSON and blank lines on stdout around the reply
  STDERR_SPAM    ~2 MB written to stderr during the turn
  HANG           after the userMessage item, stop responding to everything until killed
  EXIT_CLEAN     after turn/completed, once no turn is active, exit 0
  IGNORE_TERM    ignore SIGTERM from then on
  SPAWN_STUBBORN detached child (own session) ignoring SIGTERM; pid -> $FAKE_AGENT_DIR/stubborn.pid
  PRINTENV NAME  reply with the value of environment variable NAME
  STATE          reply is one line of JSON: harness, session, model, effort, full_access,
                 permission_mode, cwd, argv (what this harness was told)
  ECHO           reply == user text;  RECALL -> "history: <prior user texts>"
  WAKE n [text]  reply "wake: not supported by codex" (Codex doesn't start a turn by itself: X15wake)
  BACKGROUND n   a commandExecution `sleep n` that keeps running after the turn (a background terminal):
                 reply "started"; turn/completed while the item is still open; n s later item/completed
                 for it, with the finished turn's id and no new turn (X15wake)
  default        "ok: <text>"
"""
import json
import os
import random
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid as uuidlib

VERSION = "0.160.0"
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RUN_RE = re.compile(r"\bRUN[ \t]+(.+)")
WAKE_RE = re.compile(r"\bWAKE[ \t]+([0-9]*\.?[0-9]+)(?=\s|$)")
BACKGROUND_RE = re.compile(r"\bBACKGROUND[ \t]+([0-9]*\.?[0-9]+)(?=\s|$)")
MCP_STATUSES = ("connected", "pending", "failed", "needs-auth")
MCP_FINAL_AFTER = 0.2      # "ready" came 0.2-1.5 s after "starting" in every X log
KNOWN_METHODS = ["initialize", "thread/start", "thread/resume", "thread/unsubscribe",
                 "thread/turns/list", "turn/start", "turn/steer", "turn/interrupt", "thread/queue/add",
                 "thread/queue/list", "thread/queue/delete", "thread/queue/start"]
GARBAGE_LINES = ["", "this is not json", "   ", "\x1b[2m2026-01-01T00:00:00Z\x1b[0m \x1b[32mINFO\x1b[0m fake garbage",
                 "{\"method\": \"item/started\", \"truncated", "[object Object]"]


def now_ms():
    return int(time.time() * 1000)


def uuid7():
    ms = now_ms()
    r = uuidlib.uuid4().hex
    h = "%012x" % ms + "7" + r[:3] + "%x" % (8 | (int(r[3], 16) & 3)) + r[4:19]
    return "%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:32])


def parse_config_args(argv):
    """`-c key=value` / `--config key=value` overrides (the real app-server accepts them)."""
    cfg = {}
    i = 0
    while i < len(argv):
        a, val = argv[i], None
        if a in ("-c", "--config") and i + 1 < len(argv):
            i += 1
            val = argv[i]
        elif a.startswith("--config="):
            val = a.split("=", 1)[1]
        if val and "=" in val:
            k, v = val.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            cfg[k.strip()] = v
        i += 1
    return cfg


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
            sys.stderr.write("fake_codex: bad FAKE_MCP entry %r (want name:status with status one of %s)\n"
                             % (part, ", ".join(MCP_STATUSES)))
            sys.stderr.flush()
            sys.exit(2)
        out.append((name, status))
    return out


def mcp_final(name, status):
    """The last mcpServer/startupStatus/updated for a FAKE_MCP status (None: stays "starting").
    0.160.0 schema: McpServerStartupState starting|ready|failed|cancelled, McpServerStartupFailureReason
    reauthenticationRequired. Error texts are built from strings in the 0.160.0 binary (not observed live)."""
    if status == "connected":
        return {"status": "ready", "error": None, "failureReason": None}
    if status == "failed":
        return {"status": "failed", "error": "MCP client for `%s` failed to start: fake MCP server exited" % name,
                "failureReason": None}
    if status == "needs-auth":
        return {"status": "failed", "error": "MCP client for `%s` failed to start: requires OAuth reauthentication. "
                                             "Use your client's MCP OAuth sign-in flow." % name,
                "failureReason": "reauthenticationRequired"}
    return None


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
    """A detached process (own session) that ignores SIGTERM; pid -> $FAKE_AGENT_DIR/stubborn.pid."""
    child = subprocess.Popen([sys.executable, "-c",
                              "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"],
                             start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    os.makedirs(agent_root(), exist_ok=True)
    with open(os.path.join(agent_root(), "stubborn.pid"), "w") as f:
        f.write(str(child.pid))


class Chaos(object):
    """FAKE_CHAOS=<int seed>: only legal variation (timing, partial writes, noise notifications,
    orderings the real server was seen to produce). Seeded; interleavings still depend on timing."""

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

    def shuffled(self, seq):
        seq = list(seq)
        if self.on:
            with self._lock:
                self._dec.shuffle(seq)
        return seq

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


class RpcError(Exception):
    def __init__(self, message, code=-32600):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


class Interrupted(Exception):
    pass


class ActiveTurn(object):
    def __init__(self, tid):
        self.id = uuid7()
        self.thread_id = tid
        self.started_at = int(time.time())
        self.t0 = time.time()
        self.steer = []            # pending steered inputs
        self.interrupted = False
        self.closing = False       # final answer out, turn/completed not yet (the X4/X9 race window)
        self.finishing = False     # no more input accepted; turn/completed follows
        self.approval = None       # {"id": req_id, "decision": None|...}
        self.items = []            # persisted items
        self.last_final = None
        self.done = threading.Event()  # set once turn/completed has been written
        self.prev = None           # previous (finishing) turn to wait for
        self.first_input = None


class FakeCodex(object):
    def __init__(self):
        self.lock = threading.RLock()
        self.cv = threading.Condition(self.lock)
        self.out_lock = threading.Lock()
        self.save_lock = threading.RLock()
        self.initialized = False
        self.threads = {}          # loaded threads: id -> dict
        self.server_req_id = 0
        self.pending_server = {}   # req id -> ActiveTurn
        self.chaos = Chaos()
        self.hung = False          # HANG
        self.exit_when_idle = False  # EXIT_CLEAN
        self.ignore_term = False   # IGNORE_TERM
        self.shells = set()        # running RUN commands
        self.queue_watch = set()   # chaos: threads whose queue API was used get periodic queue/changed
        self.input_delay = float(os.environ.get("FAKE_INPUT_DELAY") or 0)
        self.session_approvals = {}   # thread id -> commands approved with acceptForSession (memory only)
        self.config = parse_config_args(sys.argv[1:])
        self.mcp = parse_fake_mcp()     # FAKE_MCP: [(name, status)]
        self.home = os.path.join(agent_root(), "codex")
        self.tdir = os.path.join(self.home, "threads")
        os.makedirs(self.tdir, exist_ok=True)

    # ------------------------------------------------------------ output
    def write(self, obj):
        self.write_raw(json.dumps(obj) + "\n")

    def write_raw(self, line):
        with self.out_lock:
            if self.hung:
                return
            try:
                self.chaos.write(sys.stdout, line)
            except (BrokenPipeError, ValueError):
                os._exit(1)

    def notify(self, method, params):
        self.write({"method": method, "params": params, "emittedAtMs": now_ms()})

    def status(self, th, typ, flags=None):
        st = {"type": typ}
        if typ == "active":
            st["activeFlags"] = flags or []
        th["status"] = st
        self.notify("thread/status/changed", {"threadId": th["id"], "status": st})

    def item_started(self, turn, item):
        self.notify("item/started", {"item": item, "threadId": turn.thread_id, "turnId": turn.id,
                                     "startedAtMs": now_ms()})

    def item_completed(self, turn, item):
        turn.items.append(item)
        self.notify("item/completed", {"item": item, "threadId": turn.thread_id, "turnId": turn.id,
                                       "completedAtMs": now_ms()})

    def garbage(self):
        for line in GARBAGE_LINES:
            self.write_raw(line + "\n")

    # ------------------------------------------------------------ chaos noise (shapes from X1/X4/X4q/X7/X8)
    def usage_noise(self, th, turn):
        """thread/tokenUsage/updated (+ account/rateLimits/updated) after a model response / before an
        interrupt ack, as in X1, X4, X8."""
        if not self.chaos.chance(0.7):
            return
        used = {"totalTokens": 15539, "inputTokens": 15501, "cachedInputTokens": 12032,
                "cacheWriteInputTokens": 0, "outputTokens": 38, "reasoningOutputTokens": 0}
        self.notify("thread/tokenUsage/updated", {"threadId": th["id"], "turnId": turn.id, "tokenUsage": {
            "total": used, "last": used, "modelContextWindow": 258400}})
        if self.chaos.chance(0.8):
            self.notify("account/rateLimits/updated", {"rateLimits": {
                "limitId": "codex", "limitName": None, "normalModelSlug": None,
                "primary": {"usedPercent": 84, "windowDurationMins": 10080, "resetsAt": int(time.time()) + 86400},
                "secondary": None, "credits": {"hasCredits": True, "unlimited": False, "balance": "62500"},
                "individualLimit": None, "spendControlReached": None, "planType": "pro",
                "rateLimitReachedType": None}})

    def chaos_pause(self, turn, lo=0.0, hi=0.04):
        if self.chaos.on:
            self.wait(turn, deadline=time.time() + self.chaos.uniform(lo, hi))

    def maybe_reasoning(self, turn):
        """A reasoning item (summary/content empty) before a model output, as in X4q."""
        if not self.chaos.chance(0.3):
            return
        item = {"type": "reasoning", "id": "rs_fake" + uuidlib.uuid4().hex, "summary": [], "content": []}
        self.item_started(turn, item)
        self.chaos_pause(turn, 0.0, 0.1)
        self.item_completed(turn, item)

    def maybe_commentary(self, turn, always=None):
        """A commentary agentMessage before a tool call. Present in X5a/X8, absent in X1/X10."""
        if always is not None:
            self.agent_message(turn, always, "commentary")
        elif self.chaos.chance(0.5):
            self.agent_message(turn, "I'll run the requested shell command.", "commentary")

    def queue_poller(self):
        """Chaos: the real server re-announces thread/queue/changed every ~10 s once a thread's
        queue API was used (X4q); we do it every 1-3 s so tests see it."""
        while True:
            time.sleep(self.chaos.uniform(1.0, 3.0))
            with self.cv:
                tids = [t for t in self.queue_watch if t in self.threads]
            for tid in tids:
                self.notify("thread/queue/changed", {"threadId": tid})

    def watch_queue(self, tid):
        if not self.chaos.on:
            return
        with self.cv:
            first = not self.queue_watch
            self.queue_watch.add(tid)
        if first:
            threading.Thread(target=self.queue_poller, daemon=True).start()

    # ------------------------------------------------------------ MCP startup (FAKE_MCP)
    def mcp_startup(self, tid):
        """mcpServer/startupStatus/updated: "starting" for every server at once, then each final status
        a little later (X logs: 0.2-1.5 s later, order varying). Chaos shuffles both orders and spreads
        the final ones over 0.1-1.5 s."""
        if not self.mcp:
            return
        for name, _ in self.chaos.shuffled(self.mcp):
            self.notify("mcpServer/startupStatus/updated", {"threadId": tid, "name": name, "status": "starting",
                                                            "error": None, "failureReason": None})
        finals = [(name, mcp_final(name, st)) for name, st in self.mcp if mcp_final(name, st) is not None]
        if finals:
            threading.Thread(target=self.mcp_finish, args=(tid, finals), daemon=True).start()

    def mcp_finish(self, tid, finals):
        t0 = time.time()
        if self.chaos.on:
            plan = sorted((self.chaos.uniform(0.1, 1.5), name, fin) for name, fin in finals)
        else:
            plan = [(MCP_FINAL_AFTER, name, fin) for name, fin in finals]
        for at, name, fin in plan:
            time.sleep(max(0.0, t0 + at - time.time()))
            params = {"threadId": tid, "name": name}
            params.update(fin)
            self.notify("mcpServer/startupStatus/updated", params)

    # ------------------------------------------------------------ persistence
    def path(self, tid):
        return os.path.join(self.tdir, tid + ".json")

    def lockpath(self, tid):
        return os.path.join(self.tdir, tid + ".lock")

    def save(self, th):
        with self.save_lock:
            data = json.loads(json.dumps({k: v for k, v in th.items() if k not in ("active", "status")}))
            tmp = "%s.%d.%d.tmp" % (self.path(th["id"]), os.getpid(), threading.get_ident())
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, self.path(th["id"]))

    def take_lock(self, tid):
        lp = self.lockpath(tid)
        if os.path.exists(lp):
            try:
                pid = int(open(lp).read().strip() or "0")
            except ValueError:
                pid = 0
            if pid and pid != os.getpid():
                try:
                    os.kill(pid, 0)
                    alive = True
                except OSError:
                    alive = False
                if alive:
                    raise RpcError("thread %s already has an active writer" % tid)
        with open(lp, "w") as f:
            f.write(str(os.getpid()))

    def release_locks(self):
        for tid in list(self.threads):
            try:
                if open(self.lockpath(tid)).read().strip() == str(os.getpid()):
                    os.remove(self.lockpath(tid))
            except (OSError, IOError):
                pass

    # ------------------------------------------------------------ shapes
    def thread_obj(self, th, with_turns=False):
        cwd = th["cwd"]
        return {"id": th["id"], "environments": [{"environmentId": "local", "cwd": cwd,
                                                  "runtimeWorkspaceRoots": [cwd]}],
                "extra": None, "sessionId": th["id"], "forkedFromId": None, "parentThreadId": None,
                "preview": th.get("preview", ""), "ephemeral": False, "historyMode": "paginated",
                "modelProvider": "openai", "model": th["model"], "reasoningEffort": th.get("effort"),
                "createdAt": th["createdAt"], "updatedAt": th.get("updatedAt", th["createdAt"]),
                "status": th.get("status", {"type": "idle"}), "path": self.path(th["id"]), "cwd": cwd,
                "cliVersion": VERSION, "originator": "fake_codex", "source": "vscode", "name": None,
                "turns": [self.turn_summary(t) for t in th["turns"]] if with_turns else []}

    def sandbox_obj(self, sb):
        if isinstance(sb, dict):
            return sb
        return {"read-only": {"type": "readOnly"}, "danger-full-access": {"type": "dangerFullAccess"}}.get(
            sb, {"type": "workspaceWrite", "writableRoots": [], "networkAccess": False,
                 "excludeTmpdirEnvVar": False, "excludeSlashTmp": False})

    def thread_response(self, th, with_turns=False):
        return {"thread": self.thread_obj(th, with_turns), "model": th["model"], "modelProvider": "openai",
                "serviceTier": None, "disabledPluginIds": [], "cwd": th["cwd"],
                "runtimeWorkspaceRoots": [th["cwd"]], "instructionSources": [],
                "approvalPolicy": th["approvalPolicy"], "approvalsReviewer": "user",
                "sandbox": self.sandbox_obj(th["sandbox"]), "activePermissionProfile": None,
                "reasoningEffort": th.get("effort"), "multiAgentMode": "explicitRequestOnly"}

    def turn_obj(self, turn, status="inProgress", items=None, view="notLoaded", error=None, started=True):
        done = status != "inProgress"
        return {"id": turn.id, "items": items or [], "itemsView": view, "status": status, "error": error,
                "startedAt": turn.started_at if started else None,
                "completedAt": int(time.time()) if done else None,
                "durationMs": int((time.time() - turn.t0) * 1000) if done else None}

    def turn_summary(self, t):
        items = t["items"]
        users = [i for i in items if i["type"] == "userMessage"][:1]
        finals = [i for i in items if i["type"] == "agentMessage"][-1:]
        return {"id": t["id"], "items": users + finals, "itemsView": "summary", "status": t["status"],
                "error": t.get("error"), "startedAt": t.get("startedAt"), "completedAt": t.get("completedAt"),
                "durationMs": t.get("durationMs")}

    # ------------------------------------------------------------ input loop
    def run(self):
        slow = float(os.environ.get("FAKE_SLOW_START") or 0)
        if slow > 0:
            time.sleep(slow)
        signal.signal(signal.SIGTERM, self.on_sigterm)
        try:
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
                except ValueError as e:
                    sys.stderr.write("ERROR codex_app_server_transport::transport: Failed to deserialize "
                                     "JSONRPCMessage: %s\n" % e)
                    sys.stderr.flush()
                    continue
                if not isinstance(msg, dict):
                    continue
                if "method" in msg:
                    if "id" in msg:
                        self.handle_request(msg)
                    # notifications (e.g. "initialized") need no answer
                elif "id" in msg:
                    self.handle_client_response(msg)
        finally:
            while self.hung:       # a hung server does not notice EOF either
                time.sleep(3600)
            self.shutdown()

    def shutdown(self):
        for sh in list(self.shells):
            sh.kill()               # X6: stdin EOF kills the running command
        with self.cv:
            for th in self.threads.values():
                turn = th.get("active")
                if turn is not None:
                    self.persist_turn(th, turn, "interrupted")
                    self.save(th)
        self.release_locks()
        with self.out_lock:
            try:
                sys.stdout.flush()
            except Exception:
                pass
        os._exit(0)

    def on_sigterm(self, signum, frame):
        if self.ignore_term:
            return
        for sh in list(self.shells):
            sh.kill()
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)

    def hang(self):
        """HANG: stay alive, emit nothing, ignore stdin (and its EOF) until killed."""
        with self.out_lock:
            self.hung = True
        while True:
            time.sleep(3600)

    def handle_request(self, msg):
        rid, method, params = msg["id"], msg["method"], msg.get("params") or {}
        try:
            if method == "initialize":
                if self.initialized:
                    raise RpcError("Already initialized")
                self.initialized = True
                result = {"userAgent": "%s/%s (fake)" % ((params.get("clientInfo") or {}).get("name", "client"),
                                                          VERSION),
                          "codexHome": self.home, "platformFamily": "unix", "platformOs": "macos"}
            elif not self.initialized:
                raise RpcError("Not initialized")
            elif method not in KNOWN_METHODS:
                raise RpcError("Invalid request: unknown variant `%s`, expected one of %s"
                               % (method, ", ".join("`%s`" % m for m in KNOWN_METHODS)))
            else:
                fn = getattr(self, "m_" + method.replace("/", "_"))
                result = fn(params, rid)
                if result is None:
                    return  # handler wrote the response itself
        except RpcError as e:
            self.write({"error": {"code": e.code, "message": e.message}, "id": rid})
            return
        except KeyError as e:
            self.write({"error": {"code": -32600, "message": "Invalid request: missing field `%s`" % e.args[0]},
                        "id": rid})
            return
        self.write({"id": rid, "result": result})

    def loaded(self, tid):
        th = self.threads.get(tid)
        if th is None:
            raise RpcError("thread not found: %s" % tid)
        return th

    # ------------------------------------------------------------ thread methods
    def m_thread_start(self, p, rid):
        tid = uuid7()
        cfg = dict(self.config)
        cfg.update(p.get("config") or {})
        model = p.get("model") or cfg.get("model")
        th = {"id": tid, "cwd": p.get("cwd") or os.getcwd(), "model": model or "gpt-6-luna",
              "modelGiven": model,
              "approvalPolicy": p.get("approvalPolicy") or cfg.get("approval_policy") or "on-request",
              "sandbox": p.get("sandbox") or cfg.get("sandbox_mode") or "workspace-write",
              "effort": p.get("effort") or cfg.get("model_reasoning_effort"),
              "createdAt": int(time.time()), "preview": "", "turns": [], "queue": [],
              "status": {"type": "idle"}, "active": None}
        self.take_lock(tid)
        with self.cv:
            self.threads[tid] = th
        self.save(th)
        resp = self.thread_response(th)
        self.write({"id": rid, "result": resp})
        self.notify("thread/started", {"thread": self.thread_obj(th)})
        self.mcp_startup(tid)          # X1, X2*, X7: right after thread/started
        return None

    def m_thread_resume(self, p, rid):
        tid = p["threadId"]
        with self.cv:
            th = self.threads.get(tid)
        if th is None:
            if not UUID_RE.match(tid):
                raise RpcError("invalid session id: invalid character: expected an optional prefix of "
                               "`urn:uuid:` followed by [0-9a-fA-F-], found `%s` at 1" % tid[:1])
            if not os.path.exists(self.path(tid)):
                raise RpcError("no rollout found for thread id %s" % tid)
            self.take_lock(tid)
            with open(self.path(tid)) as f:
                th = json.load(f)
            for t in th["turns"]:
                if t["status"] == "inProgress":
                    t["status"] = "interrupted"
            th.setdefault("queue", [])
            th["active"] = None
            th["status"] = {"type": "idle"}
            with self.cv:
                self.threads[tid] = th
            self.mcp_startup(tid)      # X5c_b: before the thread/resume response
        for k_in, k_th in (("model", "model"), ("approvalPolicy", "approvalPolicy"), ("sandbox", "sandbox"),
                           ("cwd", "cwd"), ("effort", "effort")):
            if p.get(k_in):
                th[k_th] = p[k_in]
        if p.get("model"):
            th["modelGiven"] = p["model"]
        if (p.get("config") or {}).get("model_reasoning_effort"):
            th["effort"] = p["config"]["model_reasoning_effort"]
        resp = self.thread_response(th, with_turns=not p.get("excludeTurns"))
        resp.update({"collaborationMode": None, "turnsBackwardsCursor": None, "itemsBackwardsCursor": None})
        return resp

    def m_thread_unsubscribe(self, p, rid):
        self.loaded(p["threadId"])
        return {"status": "unsubscribed"}   # like the real server, the writer lock is NOT released

    def m_thread_turns_list(self, p, rid):
        tid = p["threadId"]
        with self.cv:
            th = self.threads.get(tid)
        if th is None:
            if not os.path.exists(self.path(tid)):
                raise RpcError("no rollout found for thread id %s" % tid)
            th = json.load(open(self.path(tid)))
        return {"data": [self.turn_summary(t) for t in reversed(th["turns"])], "nextCursor": None}

    # ------------------------------------------------------------ turn methods
    def parse_input(self, p):
        texts = [i.get("text", "") for i in p.get("input") or [] if i.get("type") == "text"]
        return {"text": "\n".join(texts), "content": p.get("input") or [],
                "clientId": p.get("clientUserMessageId")}

    def deliver(self, th, inp, rid, steer_result, expected=None, steer_only=False):
        """Steer `inp` into the active turn, or start and launch a new turn; writes the response.
        Responses are written under the lock so they precede anything the worker emits for the input.

        A turn that is already closing is waited for, so the answer follows its turn/completed (X9).
        Chaos: input arriving after the final answer but before turn/completed either joins the turn
        (second userMessage + second final_answer) or waits for it to complete first (X4/X9)."""
        while True:
            with self.cv:
                turn = th.get("active")
                wait_for = None
                if turn is not None and not turn.finishing:
                    if expected is not None and expected != turn.id:
                        raise RpcError("expected active turn id `%s` but found `%s`" % (expected, turn.id))
                    if turn.closing and not turn.steer and self.chaos.chance(0.5):
                        turn.finishing = True      # let it complete; this input comes after
                        wait_for = turn
                    else:
                        self.write({"id": rid, "result": steer_result(turn)})
                        turn.steer.append(inp)
                        self.cv.notify_all()
                        return
                elif turn is not None:
                    wait_for = turn
                elif steer_only:
                    raise RpcError("no active turn to steer")
                else:
                    turn = self.begin_turn(th, inp)
                    self.write({"id": rid, "result": {"turn": self.turn_obj(turn, started=False)}})
                    self.launch(th, turn)
                    return
            wait_for.done.wait(30)

    def m_turn_start(self, p, rid):
        th = self.loaded(p["threadId"])
        inp = self.parse_input(p)
        for k_in, k_th in (("model", "model"), ("approvalPolicy", "approvalPolicy"), ("cwd", "cwd"),
                           ("effort", "effort")):
            if p.get(k_in):
                th[k_th] = p[k_in]
        if p.get("sandboxPolicy"):
            th["sandbox"] = p["sandboxPolicy"]
        if p.get("model"):
            th["modelGiven"] = p["model"]
        if p.get("model") and "no-such-model" in p["model"]:
            self.notify("warning", {"threadId": th["id"], "message": (
                "Model metadata for `%s` not found. Defaulting to fallback metadata; this can degrade "
                "performance and cause issues." % p["model"])})
        elif self.chaos.chance(0.1):
            self.notify("warning", {"threadId": th["id"], "message": "fake chaos: a harmless warning notification"})
        self.deliver(th, inp, rid, lambda turn: {"turn": self.turn_obj(turn, started=False)})
        return None

    def begin_turn(self, th, inp):
        """Create the active turn (caller holds the lock); launch() starts its worker."""
        turn = ActiveTurn(th["id"])
        turn.prev = th.get("active")      # a turn that is still finishing, if any
        turn.first_input = inp
        th["active"] = turn
        if not th.get("preview"):
            th["preview"] = inp["text"][:200]
        th["turns"].append({"id": turn.id, "status": "inProgress", "items": [], "error": None,
                            "startedAt": turn.started_at, "completedAt": None, "durationMs": None})
        return turn

    def launch(self, th, turn):
        threading.Thread(target=self.turn_worker, args=(th, turn, turn.first_input), daemon=True).start()

    def m_turn_steer(self, p, rid):
        th = self.loaded(p["threadId"])
        self.deliver(th, self.parse_input(p), rid, lambda turn: {"turnId": turn.id},
                     expected=p.get("expectedTurnId"), steer_only=True)
        return None

    def m_turn_interrupt(self, p, rid):
        th = self.loaded(p["threadId"])
        while True:
            with self.cv:
                turn = th.get("active")
                if turn is not None and turn.finishing:
                    wait_for = turn       # answer after its turn/completed
                else:
                    if turn is None:
                        raise RpcError("no active turn to interrupt")
                    if p.get("turnId") != turn.id:
                        raise RpcError("expected active turn id %s but found %s" % (p.get("turnId"), turn.id))
                    self.usage_noise(th, turn)
                    self.write({"id": rid, "result": {}})
                    turn.interrupted = True
                    self.cv.notify_all()
                    return None
            wait_for.done.wait(30)

    # ------------------------------------------------------------ queue (experimental)
    def m_thread_queue_list(self, p, rid):
        th = self.loaded(p["threadId"])
        self.watch_queue(th["id"])
        return {"data": list(th["queue"]), "nextCursor": None}

    def m_thread_queue_add(self, p, rid):
        th = self.loaded(p["threadId"])
        self.watch_queue(th["id"])
        sub = {"id": uuid7(), "input": p.get("input") or [], "clientUserMessageId": p["clientUserMessageId"]}
        with self.cv:
            th["queue"].append(sub)
            self.write({"id": rid, "result": {"queuedSubmission": sub}})
            self.notify("thread/queue/changed", {"threadId": th["id"]})
            if th.get("active") is None:
                self.drain_queue(th)
        return None

    def m_thread_queue_delete(self, p, rid):
        th = self.loaded(p["threadId"])
        self.watch_queue(th["id"])
        with self.cv:
            before = len(th["queue"])
            th["queue"] = [q for q in th["queue"] if q["id"] != p["queuedSubmissionId"]]
            deleted = len(th["queue"]) != before
        if deleted:
            self.notify("thread/queue/changed", {"threadId": th["id"]})
        return {"deleted": deleted}

    def m_thread_queue_start(self, p, rid):
        th = self.loaded(p["threadId"])
        self.watch_queue(th["id"])
        with self.cv:
            if not th["queue"]:
                raise RpcError("queue is empty")
            if th.get("active") is not None:
                raise RpcError("thread already has an active turn")
            turn = self.drain_queue(th, p.get("queuedSubmissionId"), launch=False)
            self.write({"id": rid, "result": {"turn": self.turn_obj(turn, started=False)}})
            self.launch(th, turn)
            return None

    def drain_queue(self, th, sub_id=None, launch=True):
        """Start the next queued submission as a new turn (caller holds the lock)."""
        if not th["queue"]:
            return None
        idx = 0
        if sub_id:
            idx = [q["id"] for q in th["queue"]].index(sub_id)
        sub = th["queue"].pop(idx)
        self.notify("thread/queue/changed", {"threadId": th["id"]})
        inp = {"text": "\n".join(i.get("text", "") for i in sub["input"] if i.get("type") == "text"),
               "content": sub["input"], "clientId": sub["clientUserMessageId"]}
        turn = self.begin_turn(th, inp)
        if launch:
            self.launch(th, turn)
        return turn

    # ------------------------------------------------------------ client responses (approvals)
    def handle_client_response(self, msg):
        with self.cv:
            turn = self.pending_server.get(msg["id"])
            if turn is None or turn.approval is None or turn.approval["id"] != msg["id"]:
                return  # late / unknown responses are ignored
            if "error" in msg:
                turn.approval["decision"] = "decline"
            else:
                result = msg.get("result") or {}
                turn.approval["result"] = result
                turn.approval["decision"] = result.get("decision", "answered" if "answers" in result else "decline")
            self.cv.notify_all()

    # ------------------------------------------------------------ turn worker
    def checkpoint(self, turn):
        with self.cv:
            if turn.interrupted:
                raise Interrupted()

    def wait(self, turn, deadline=None, pred=None):
        with self.cv:
            while True:
                if turn.interrupted:
                    raise Interrupted()
                if pred is not None and pred():
                    return
                if deadline is not None and time.time() >= deadline:
                    return
                self.cv.wait(0.05 if deadline is None else max(0.0, min(0.05, deadline - time.time())))

    def user_item(self, th, turn, inp):
        item = {"type": "userMessage", "id": uuid7(), "clientId": inp["clientId"], "content": inp["content"]}
        self.item_started(turn, item)
        self.item_completed(turn, item)
        write_receipt("codex", th["id"], inp["clientId"], inp["text"], turn.id)

    def agent_message(self, turn, text, phase):
        item = {"type": "agentMessage", "id": "msg_fake%s" % uuidlib.uuid4().hex, "text": "", "phase": phase,
                "memoryCitation": None, "delivery": None, "questions": None}
        self.item_started(turn, item)
        chunks = [text]
        if self.chaos.on and len(text) > 1:
            cuts = sorted(set(self.chaos.randint(1, len(text) - 1) for _ in range(self.chaos.randint(0, 4))))
            chunks = [text[a:b] for a, b in zip([0] + cuts, cuts + [len(text)])]
        for i, chunk in enumerate(chunks):
            if i:
                self.chaos_pause(turn, 0.0, 0.03)    # an interrupt here leaves the item open (X1)
            self.notify("item/agentMessage/delta", {"threadId": turn.thread_id, "turnId": turn.id,
                                                    "itemId": item["id"], "delta": chunk})
        done = dict(item)
        done["text"] = text
        self.item_completed(turn, done)
        return done

    def cmd_item(self, th, command, status, source, pid=None, exit_code=None, dur=None, item_id=None,
                 quoted=None, cwd=None):
        return {"type": "commandExecution", "id": item_id or "exec-" + str(uuidlib.uuid4()), "pluginId": None,
                "scriptPath": None, "command": "/bin/zsh -lc %s" % (quoted or "'%s'" % command),
                "cwd": cwd or th["cwd"], "processId": pid, "source": source, "status": status,
                "commandActions": [{"type": "unknown", "command": command}], "aggregatedOutput": None,
                "exitCode": exit_code, "durationMs": dur}

    def state_json(self, th):
        sb = th["sandbox"]
        full_sandbox = sb == "danger-full-access" or (isinstance(sb, dict) and sb.get("type") == "dangerFullAccess")
        return json.dumps({"harness": "codex", "session": th["id"], "model": th.get("modelGiven"),
                           "effort": th.get("effort"),
                           "full_access": th["approvalPolicy"] == "never" and full_sandbox,
                           "permission_mode": th["approvalPolicy"], "cwd": th["cwd"], "argv": sys.argv[1:]})

    def reply_for(self, th, inp, trig, extra):
        text = inp["text"]
        if "STATE" in trig:
            return self.state_json(th)
        if extra is not None:
            return extra
        m = re.search(r"PRINTENV\s+(\w+)", trig)
        if m:
            return os.environ.get(m.group(1), "<unset>")
        if "ECHO" in trig:
            return text
        if "RECALL" in trig:
            prev = []
            for t in th["turns"]:
                for it in t["items"]:
                    if it["type"] == "userMessage":
                        s = "\n".join(c.get("text", "") for c in it["content"] if c.get("type") == "text")
                        if s != text:
                            prev.append(s)
            return "history: " + " | ".join(prev)
        return "ok: " + text

    def persist_turn(self, th, turn, status, error=None):
        for t in th["turns"]:
            if t["id"] == turn.id:
                t.update({"status": status, "items": turn.items, "error": error,
                          "completedAt": int(time.time()), "durationMs": int((time.time() - turn.t0) * 1000)})
        th["updatedAt"] = int(time.time())

    def run_sleep(self, th, turn, secs, label):
        self.maybe_commentary(turn, None if self.chaos.on else "Running sleep %s." % label)
        item = self.cmd_item(th, "sleep %s" % label, "inProgress", "unifiedExecStartup", pid=str(os.getpid()))
        self.item_started(turn, item)
        self.wait(turn, deadline=time.time() + secs)
        done = dict(item)
        done.update({"status": "completed", "exitCode": 0, "durationMs": int(secs * 1000)})
        self.item_completed(turn, done)
        self.usage_noise(th, turn)

    def run_background(self, th, turn, secs, label):
        """X15wake: the command runs as a background terminal. Its item stays open through the
        turn's end; n seconds later item/completed arrives with the finished turn's id."""
        item = self.cmd_item(th, "sleep %s" % label, "inProgress", "unifiedExecStartup", pid=str(os.getpid()))
        self.item_started(turn, item)
        started = time.time()

        def finish():
            time.sleep(secs)
            done = dict(item)
            done.update({"status": "completed", "exitCode": 0, "durationMs": int((time.time() - started) * 1000)})
            self.notify("item/completed", {"item": done, "threadId": turn.thread_id, "turnId": turn.id,
                                           "completedAtMs": now_ms()})

        threading.Thread(target=finish, daemon=True).start()

    def run_huge(self, th, turn, out, size):
        self.maybe_commentary(turn)
        item = self.cmd_item(th, "yes 0123456789abcdef | head -c %d" % size, "inProgress", "unifiedExecStartup",
                             pid=str(os.getpid()))
        self.item_started(turn, item)
        step = 1024 * 1024
        for i in range(0, len(out), step):
            self.checkpoint(turn)
            self.notify("item/commandExecution/outputDelta", {"threadId": th["id"], "turnId": turn.id,
                                                              "itemId": item["id"], "delta": out[i:i + step]})
        done = dict(item)
        done.update({"status": "completed", "exitCode": 0, "durationMs": 0, "aggregatedOutput": out})
        self.item_completed(turn, done)
        self.usage_noise(th, turn)

    def run_shell(self, th, turn, cmd):
        """RUN: a real /bin/sh command as a commandExecution item (X10 shape). Interruptible; an
        interrupt kills it and leaves the item without item/completed (X1)."""
        self.maybe_commentary(turn)
        cwd = th["cwd"] if os.path.isdir(th["cwd"]) else os.getcwd()
        t0 = time.time()
        sh = ShellRun(cmd, cwd)
        self.shells.add(sh)
        item = self.cmd_item(th, cmd, "inProgress", "unifiedExecStartup", pid=str(sh.p.pid),
                             quoted=shlex.quote(cmd), cwd=cwd)
        self.item_started(turn, item)
        try:
            while not sh.done():
                self.wait(turn, deadline=time.time() + 0.05)
        except Interrupted:
            sh.kill()
            self.shells.discard(sh)
            raise
        self.shells.discard(sh)
        out = sh.output()
        code = sh.p.returncode
        if out:
            self.notify("item/commandExecution/outputDelta", {"threadId": th["id"], "turnId": turn.id,
                                                              "itemId": item["id"], "delta": out})
        done = dict(item)
        done.update({"status": "completed" if code == 0 else "failed", "exitCode": code,
                     "aggregatedOutput": out, "durationMs": int((time.time() - t0) * 1000)})
        self.item_completed(turn, done)
        self.usage_noise(th, turn)
        return "exit=%d\n%s" % (code, out.rstrip("\n"))

    # ------------------------------------------------------------ remembered approvals
    def rules_path(self):
        return os.path.join(self.home, "rules", "default.rules")

    def policy_allows(self, argv):
        """An allow prefix_rule in <codexHome>/rules/default.rules whose pattern prefixes argv."""
        try:
            with open(self.rules_path()) as f:
                lines = f.read().splitlines()
        except IOError:
            return False
        for line in lines:
            m = re.match(r'\s*prefix_rule\(pattern=(\[.*?\])\s*,\s*decision="allow"', line)
            if not m:
                continue
            try:
                pat = json.loads(m.group(1))
            except ValueError:
                continue
            if pat and argv[:len(pat)] == pat:
                return True
        return False

    def add_policy_rule(self, pattern):
        os.makedirs(os.path.dirname(self.rules_path()), exist_ok=True)
        fd = os.open(self.rules_path(), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, ('prefix_rule(pattern=%s, decision="allow")\n' % json.dumps(pattern)).encode("utf-8"))
        finally:
            os.close(fd)

    def run_approval(self, th, turn, target=None):
        command = "touch %s" % (target or "fake_approval.txt")
        argv = ["/bin/zsh", "-lc", command]
        remembered = command in self.session_approvals.get(th["id"], ()) or self.policy_allows(argv)
        if th["approvalPolicy"] == "never" or remembered:
            # X13: a remembered command runs straight away, like an approval-free one
            item = self.cmd_item(th, command, "inProgress", "unifiedExecStartup", pid=str(os.getpid()))
            self.item_started(turn, item)
            done = dict(item)
            done.update({"status": "completed", "exitCode": 0, "durationMs": 0})
            self.item_completed(turn, done)
            return "approval not needed" if th["approvalPolicy"] == "never" else "approval accepted (remembered)"
        self.maybe_commentary(turn)
        with self.cv:
            req_id = self.server_req_id
            self.server_req_id += 1
            turn.approval = {"id": req_id, "decision": None}
            self.pending_server[req_id] = turn
        self.status(th, "active", ["waitingOnApproval"])
        item = self.cmd_item(th, command, "inProgress", "agent")
        self.item_started(turn, item)
        self.write({"method": "item/commandExecution/requestApproval", "id": req_id, "params": {
            "kind": "command", "threadId": th["id"], "turnId": turn.id, "itemId": item["id"],
            "startedAtMs": now_ms(), "environmentId": "local", "command": item["command"], "cwd": th["cwd"],
            "commandActions": item["commandActions"], "proposedExecpolicyAmendment": argv,
            "availableDecisions": ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": argv}},
                                   "cancel"]}})
        self.wait(turn, pred=lambda: turn.approval["decision"] is not None)
        decision = turn.approval["decision"]
        with self.cv:
            turn.approval = None
            self.pending_server.pop(req_id, None)
        self.notify("serverRequest/resolved", {"threadId": th["id"], "requestId": req_id})
        accepted = decision not in ("decline", "cancel")
        if decision == "acceptForSession":
            self.session_approvals.setdefault(th["id"], set()).add(command)
        elif isinstance(decision, dict) and isinstance(decision.get("acceptWithExecpolicyAmendment"), dict):
            self.add_policy_rule(decision["acceptWithExecpolicyAmendment"].get("execpolicy_amendment") or argv)
        done = dict(item)
        if accepted:
            self.status(th, "active", [])
            done.update({"status": "completed", "exitCode": 0, "durationMs": 0, "source": "unifiedExecStartup",
                         "processId": str(os.getpid())})
            self.item_completed(turn, done)
            return "approval accepted"
        done["status"] = "declined"
        if decision == "cancel":
            self.item_completed(turn, done)
            self.status(th, "active", [])
            with self.cv:
                turn.interrupted = True
            raise Interrupted()
        self.status(th, "active", [])
        self.item_completed(turn, done)
        return "approval declined"

    def run_questions(self, th, turn):
        with self.cv:
            req_id = self.server_req_id
            self.server_req_id += 1
            turn.approval = {"id": req_id, "decision": None}
            self.pending_server[req_id] = turn
        self.status(th, "active", ["waitingOnUserInput"])
        item_id = "call_" + uuidlib.uuid4().hex[:12]
        self.write({"method": "item/tool/requestUserInput", "id": req_id, "params": {
            "threadId": th["id"], "turnId": turn.id, "itemId": item_id, "isBlocking": True, "autoResolutionMs": None,
            "questions": [
                {"id": "q_color", "header": "Color", "question": "Favorite color?", "isOther": False, "isSecret": False,
                 "options": [{"label": "red", "description": ""}, {"label": "blue", "description": ""}]},
                {"id": "q_size", "header": "Size", "question": "Which size?", "isOther": True, "isSecret": False,
                 "options": None}]}})
        self.wait(turn, pred=lambda: turn.approval["decision"] is not None)
        result = turn.approval.get("result") or {}
        with self.cv:
            turn.approval = None
            self.pending_server.pop(req_id, None)
        self.notify("serverRequest/resolved", {"threadId": th["id"], "requestId": req_id})
        self.status(th, "active", [])
        answers = result.get("answers") or {}
        return "answers: " + "; ".join("%s=%s" % (k, ",".join((answers[k] or {}).get("answers", [])))
                                       for k in sorted(answers))

    def run_server_request(self, th, turn, method, params):
        with self.cv:
            req_id = self.server_req_id
            self.server_req_id += 1
            turn.approval = {"id": req_id, "decision": None}
            self.pending_server[req_id] = turn
        self.status(th, "active", ["waitingOnApproval"])
        params = dict(params, threadId=th["id"], turnId=turn.id)
        self.write({"method": method, "id": req_id, "params": params})
        self.wait(turn, pred=lambda: turn.approval["decision"] is not None)
        result = turn.approval.get("result") or {}
        with self.cv:
            turn.approval = None
            self.pending_server.pop(req_id, None)
        self.notify("serverRequest/resolved", {"threadId": th["id"], "requestId": req_id})
        self.status(th, "active", [])
        return "result: " + json.dumps(result, sort_keys=True)

    def fail_turn(self, th, turn):
        msg = ('{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The \'%s\' '
               'model is not supported when using Codex with a ChatGPT account."}}' % th["model"])
        err = {"message": msg, "codexErrorInfo": "other", "additionalDetails": None, "misalignment": None}
        with self.cv:
            turn.finishing = True
        self.status(th, "systemError")
        self.notify("error", {"error": err, "willRetry": False, "threadId": th["id"], "turnId": turn.id})
        self.persist_turn(th, turn, "failed", err)
        self.end_turn(th, turn, self.turn_obj(turn, "failed", error=err))

    def end_turn(self, th, turn, turn_payload, pending=None):
        with self.cv:
            if th.get("active") is turn:
                th["active"] = None
        self.notify("turn/completed", {"threadId": th["id"], "turn": turn_payload})
        turn.done.set()
        if pending:   # X3: the dropped approval is resolved after turn/completed
            self.notify("serverRequest/resolved", {"threadId": th["id"], "requestId": pending["id"]})
        self.save(th)
        with self.cv:
            if th["queue"] and th.get("active") is None:
                self.drain_queue(th)
            if self.exit_when_idle and not any(t.get("active") for t in self.threads.values()):
                self.shutdown()

    def input_pause(self, turn):
        """The gap between turn/started and the userMessage item (real: 0.04-2.8 s, X1/X3/X4)."""
        delay = self.input_delay
        if self.chaos.on:
            delay = max(delay, self.chaos.uniform(0.05, 0.3) if self.chaos.chance(0.3)
                        else self.chaos.uniform(0.0, 0.04))
        if delay > 0:
            self.wait(turn, deadline=time.time() + delay)

    def turn_worker(self, th, turn, first):
        if turn.prev is not None:
            turn.prev.done.wait(30)
            turn.prev = None
        self.status(th, "active", [])
        self.notify("turn/started", {"threadId": th["id"], "turn": self.turn_obj(turn)})
        garbage = False
        try:
            self.input_pause(turn)
            work = [first]
            while True:
                replies = []
                while work:
                    inp = work.pop(0)
                    self.user_item(th, turn, inp)
                    self.save_progress(th, turn)
                    text = inp["text"]
                    trig, run_cmd = split_run(text)
                    trig, wake = split_wake(trig)
                    if "HANG" in trig:
                        self.hang()
                    if "CRASH" in trig:
                        sys.stderr.write("fake_codex: CRASH requested\n")
                        sys.stderr.flush()
                        os._exit(1)
                    if "FAIL" in trig or "no-such-model" in th["model"]:
                        self.fail_turn(th, turn)
                        return
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
                    used_tool = False
                    extra = None
                    m = re.search(r"SLEEP\s+([0-9]*\.?[0-9]+)", trig)
                    if m:
                        used_tool = True
                        self.run_sleep(th, turn, float(m.group(1)), m.group(1))
                    if wake is not None:
                        extra = "wake: not supported by codex"
                    m = BACKGROUND_RE.search(trig)
                    if m:
                        used_tool = True
                        self.run_background(th, turn, float(m.group(1)), m.group(1))
                        extra = "started"
                    m = re.search(r"HUGE\s+([0-9]*\.?[0-9]+)", trig)
                    if m:
                        used_tool = True
                        out, size = huge_output(float(m.group(1)))
                        self.run_huge(th, turn, out, size)
                        extra = "huge: %s MB" % m.group(1)
                    m = re.search(r"ASK_APPROVAL(?::([\w.-]+))?", trig)
                    if m:
                        used_tool = True
                        extra = self.run_approval(th, turn, m.group(1))
                    if "ASK_QUESTIONS" in trig:
                        used_tool = True
                        extra = self.run_questions(th, turn)
                    if "ASK_PERMS" in trig:
                        used_tool = True
                        extra = self.run_server_request(th, turn, "item/permissions/requestApproval", {
                            "itemId": "perm_1", "environmentId": "local", "startedAtMs": now_ms(), "cwd": th["cwd"],
                            "reason": "needs to write the build cache",
                            "permissions": {"network": {"enabled": True},
                                            "fileSystem": {"read": None, "write": ["/tmp/x"]}}})
                    if "ASK_URL" in trig:
                        used_tool = True
                        extra = self.run_server_request(th, turn, "mcpServer/elicitation/request", {
                            "serverName": "github", "mode": "url", "_meta": None, "message": "Sign in to GitHub",
                            "url": "https://example.com/login", "elicitationId": "e1"})
                    if "ASK_FORM" in trig:
                        used_tool = True
                        extra = self.run_server_request(th, turn, "mcpServer/elicitation/request", {
                            "serverName": "deploy", "mode": "form", "_meta": None, "message": "Which environment?",
                            "requestedSchema": {"type": "object", "properties": {"env": {"type": "string"}},
                                                "required": ["env"]}})
                    if run_cmd is not None:
                        used_tool = True
                        extra = self.run_shell(th, turn, run_cmd)
                    replies.append(self.reply_for(th, inp, trig, extra))
                    if used_tool:
                        with self.cv:
                            work.extend(turn.steer)
                            del turn.steer[:]
                self.checkpoint(turn)
                if garbage:
                    self.garbage()
                self.maybe_reasoning(turn)
                turn.last_final = self.agent_message(turn, "\n".join(replies), "final_answer")
                with self.cv:
                    turn.closing = True
                self.chaos_pause(turn)          # X4/X9: turn/completed trails the final answer by ~30 ms
                self.usage_noise(th, turn)
                with self.cv:
                    if turn.interrupted:
                        raise Interrupted()
                    if turn.steer and not turn.finishing:   # steered after the final message: same turn
                        work = turn.steer[:]
                        del turn.steer[:]
                        turn.closing = False
                        continue
                    turn.finishing = True
                break
        except Interrupted:
            with self.cv:
                turn.finishing = True
                pending = turn.approval
                turn.approval = None
                if pending:
                    self.pending_server.pop(pending["id"], None)
            self.status(th, "idle")
            self.persist_turn(th, turn, "interrupted")
            self.end_turn(th, turn, self.turn_obj(turn, "interrupted"), pending)
            return
        self.status(th, "idle")
        self.persist_turn(th, turn, "completed")
        self.end_turn(th, turn, self.turn_obj(turn, "completed", items=[turn.last_final], view="summary"))
        if garbage:
            self.garbage()

    def save_progress(self, th, turn):
        for t in th["turns"]:
            if t["id"] == turn.id:
                t["items"] = list(turn.items)
        self.save(th)


if __name__ == "__main__":
    FakeCodex().run()
