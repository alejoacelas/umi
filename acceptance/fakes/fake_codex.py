#!/usr/bin/env python3
"""fake_codex.py - deterministic stand-in for `codex app-server --listen stdio://`.

Python 3.9, stdlib only. JSON-RPC 2.0 over newline-delimited stdio (the
"jsonrpc" field is optional on input and omitted on output, like the real
server). Shapes mirror codex-cli 0.160.0 as observed in the probes (see
reference/PROTOCOLS.md). README.md in this directory documents every env var,
trigger and chaos variation.

Implemented methods: initialize, initialized (notification), thread/start,
thread/resume, thread/unsubscribe, thread/turns/list, thread/items/list, turn/start (new turn or
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
  HANG           after the userMessage item, stop responding to everything until killed (on a
                 unix socket it stops reading it too)
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

Transports: `app-server [--listen stdio://]` (newline-delimited JSON on stdin/stdout) or
`app-server --listen unix://PATH` (WebSocket over a unix socket, several clients at once; one JSON-RPC
message per text frame). A client that started or resumed a thread gets its notifications and server
requests; the first answer to a server request wins.

TUI mode: `fake_codex [OPTIONS] [PROMPT]` and `fake_codex resume [THREAD] [PROMPT] [--remote unix://PATH]`
show a line-oriented interface on a terminal. With --remote it is a client of that server; without, it
runs its own engine on the thread (same state files and lock). Hooks from $FAKE_CODEX_PLUGIN_DIRS
(DIR/hooks/hooks.json) run wherever the engine runs, detached from the terminal.
"""
import base64
import hashlib
import json
import os
import queue
import random
import re
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid as uuidlib

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fake_common import Hooks, LineUI, live_fake, log_violation, plugin_dirs, restore_terminals, short  # noqa: E402

VERSION = "0.160.0"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_MAX_UNFRAGMENTED = 16777216    # the real 101 response advertises x-codex-websocket-max-unfragmented-message-bytes
WS_MAX_MESSAGE = 256 * 1024 * 1024
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RUN_RE = re.compile(r"\bRUN[ \t]+(.+)")
WAKE_RE = re.compile(r"\bWAKE[ \t]+([0-9]*\.?[0-9]+)(?=\s|$)")
BACKGROUND_RE = re.compile(r"\bBACKGROUND[ \t]+([0-9]*\.?[0-9]+)(?=\s|$)")
MCP_STATUSES = ("connected", "pending", "failed", "needs-auth")
MCP_FINAL_AFTER = 0.2      # "ready" came 0.2-1.5 s after "starting" in every X log
KNOWN_METHODS = ["initialize", "thread/start", "thread/resume", "thread/unsubscribe",
                 "thread/turns/list", "thread/items/list", "turn/start", "turn/steer", "turn/interrupt", "thread/queue/add",
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

    def plan(self, length):
        """(delay, cut, gap) for one write: in chaos mode a 0-40 ms delay and sometimes a split."""
        if not self.on:
            return 0.0, 0, 0.0
        with self._lock:
            delay = self._out.uniform(0.0, 0.04)
            cut = self._out.randint(1, length - 1) if length > 2 and self._out.random() < 0.2 else 0
            gap = self._out.uniform(0.001, 0.015)
        return delay, cut, gap

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


# ------------------------------------------------------------------ WebSocket (RFC 6455) over a unix socket

def ws_mask(data, key):
    n = len(data)
    if not n:
        return b""
    k = (key * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(k, "big")).to_bytes(n, "big")


def ws_frame(op, payload, fin=True, mask=False):
    b0 = (0x80 if fin else 0) | op
    m = 0x80 if mask else 0
    n = len(payload)
    if n < 126:
        head = struct.pack(">BB", b0, m | n)
    elif n < 65536:
        head = struct.pack(">BBH", b0, m | 126, n)
    else:
        head = struct.pack(">BBQ", b0, m | 127, n)
    if mask:
        key = os.urandom(4)
        return head + key + ws_mask(payload, key)
    return head + payload


class WsProtocolError(Exception):
    def __init__(self, code, reason):
        Exception.__init__(self, reason)
        self.code = code


class WsEndpoint(object):
    """One side of a WebSocket. A server expects masked frames and sends unmasked ones; a client the
    reverse. recv_message() answers pings, joins fragments and returns (opcode, bytes) or None on close."""

    def __init__(self, sock, buf=b"", client=False):
        self.sock = sock
        self.buf = buf
        self.client = client
        self.send_lock = threading.Lock()
        self.close_sent = False

    def _need(self, n):
        while len(self.buf) < n:
            data = self.sock.recv(max(65536, n - len(self.buf)))
            if not data:
                raise EOFError("socket closed")
            self.buf += data
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv_frame(self):
        b0, b1 = struct.unpack(">BB", self._need(2))
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._need(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._need(8))[0]
        if n > WS_MAX_MESSAGE:
            raise WsProtocolError(1009, "frame too big")
        key = self._need(4) if b1 & 0x80 else None
        payload = self._need(n)
        if key is not None:
            payload = ws_mask(payload, key)
        return bool(b0 & 0x80), b0 & 0x70, b0 & 0x0F, key is not None, payload

    def recv_message(self):
        msg_op, parts, size = None, [], 0
        while True:
            fin, rsv, op, masked, payload = self.recv_frame()
            if rsv:
                raise WsProtocolError(1002, "reserved bits set")
            if masked == self.client:
                raise WsProtocolError(1002, "client frames must be masked, server frames must not")
            if op >= 8:
                if not fin or len(payload) > 125:
                    raise WsProtocolError(1002, "bad control frame")
                if op == 9:
                    self.send_frame(10, payload)
                elif op == 8:
                    if not self.close_sent:
                        self.send_frame(8, payload[:2])
                    return None
                elif op != 10:
                    raise WsProtocolError(1002, "unknown opcode %d" % op)
                continue
            if op == 0:
                if msg_op is None:
                    raise WsProtocolError(1002, "continuation without a message")
            elif op in (1, 2):
                if msg_op is not None:
                    raise WsProtocolError(1002, "new message inside a fragmented one")
                msg_op = op
            else:
                raise WsProtocolError(1002, "unknown opcode %d" % op)
            parts.append(payload)
            size += len(payload)
            if size > WS_MAX_MESSAGE:
                raise WsProtocolError(1009, "message too big")
            if fin:
                return msg_op, b"".join(parts)

    def send_frame(self, op, payload, fin=True):
        data = ws_frame(op, payload, fin, mask=self.client)
        with self.send_lock:
            if op == 8:
                if self.close_sent:
                    return
                self.close_sent = True
            self.sock.sendall(data)

    def send_text(self, text, chaos=None):
        """One message; above WS_MAX_UNFRAGMENTED bytes it goes out in fragments of that size.
        chaos: (delay, cut, gap) splits the bytes over two socket writes."""
        payload = text.encode("utf-8")
        if len(payload) <= WS_MAX_UNFRAGMENTED:
            data = ws_frame(1, payload, mask=self.client)
        else:
            chunks = [payload[i:i + WS_MAX_UNFRAGMENTED] for i in range(0, len(payload), WS_MAX_UNFRAGMENTED)]
            data = b"".join(ws_frame(1 if i == 0 else 0, c, fin=i == len(chunks) - 1, mask=self.client)
                            for i, c in enumerate(chunks))
        with self.send_lock:
            if chaos and chaos[1] and chaos[1] < len(data):
                self.sock.sendall(data[:chaos[1]])
                time.sleep(chaos[2])
                self.sock.sendall(data[chaos[1]:])
            else:
                self.sock.sendall(data)

    def close(self, code=1000):
        try:
            self.send_frame(8, struct.pack(">H", code))
        except OSError:
            pass


def ws_accept(key):
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def ws_connect_unix(path, timeout=10):
    """Client side: connect to unix socket `path` and upgrade. Returns a WsEndpoint."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(path)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        data = s.recv(4096)
        if not data:
            raise OSError("connection closed during the WebSocket handshake")
        buf += data
    head, rest = buf.split(b"\r\n\r\n", 1)
    status = head.split(b"\r\n")[0].decode("latin-1")
    if " 101 " not in status + " ":
        raise OSError("WebSocket upgrade refused: %s" % status)
    s.settimeout(None)
    return WsEndpoint(s, rest, client=True)


# ------------------------------------------------------------------ connections to the engine

class Conn(object):
    """A client of the engine. `subs`: threads whose notifications and server requests it receives."""

    def __init__(self, engine):
        self.engine = engine
        self.initialized = False
        self.subs = set()
        self.closed = False

    def send(self, obj):
        self.send_raw(json.dumps(obj))

    def send_raw(self, text):
        raise NotImplementedError


class StdioConn(Conn):
    """`--listen stdio://`: newline-delimited JSON on stdout (the only connection)."""

    def send_raw(self, text):
        self.engine.write_stdout(text + "\n")


class WsConn(Conn):
    """`--listen unix://PATH`: one WebSocket client. Outgoing messages go through a queue and a writer
    thread, so a slow client never blocks the engine."""

    def __init__(self, engine, endpoint):
        Conn.__init__(self, engine)
        self.ep = endpoint
        self.q = queue.Queue()
        threading.Thread(target=self._writer, daemon=True).start()

    def send_raw(self, text):
        if self.closed or self.engine.hung:
            return
        self.q.put(text)

    def _writer(self):
        while True:
            text = self.q.get()
            if text is None:
                return
            plan = self.engine.chaos.plan(len(text) + 10)
            if plan[0]:
                time.sleep(plan[0])
            try:
                self.ep.send_text(text, plan)
            except OSError:
                self.closed = True
                try:
                    self.ep.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return

    def serve(self):
        try:
            while True:
                while self.engine.hung:      # a hung server stops reading its socket too
                    time.sleep(3600)
                m = self.ep.recv_message()
                if m is None:
                    break
                op, data = m
                if self.engine.hung:
                    continue
                if op == 2:
                    sys.stderr.write("ERROR codex_app_server_transport::transport: ignoring a binary message\n")
                    sys.stderr.flush()
                    continue
                try:
                    text = data.decode("utf-8")
                except UnicodeDecodeError:
                    raise WsProtocolError(1007, "invalid UTF-8")
                try:
                    msg = json.loads(text)
                except ValueError as e:
                    sys.stderr.write("ERROR codex_app_server_transport::transport: Failed to deserialize "
                                     "JSONRPCMessage: %s\n" % e)
                    sys.stderr.flush()
                    continue
                self.engine.dispatch(self, msg)
        except WsProtocolError as e:
            self.ep.close(e.code)
        except (EOFError, OSError, struct.error):
            pass
        finally:
            self.engine.remove_conn(self)
            self.q.put(None)
            try:
                self.ep.sock.close()
            except OSError:
                pass


class LocalConn(Conn):
    """The in-process TUI (no --remote): messages are handed to `deliver` as fresh objects."""

    def __init__(self, engine, deliver):
        Conn.__init__(self, engine)
        self.deliver = deliver

    def send(self, obj):
        if not self.engine.hung:
            self.deliver(json.loads(json.dumps(obj)))

    def send_raw(self, text):
        try:
            obj = json.loads(text)
        except ValueError:
            return                     # GARBAGE has no meaning in-process
        self.send(obj)


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
    def __init__(self, argv=None):
        self.lock = threading.RLock()
        self.cv = threading.Condition(self.lock)
        self.out_lock = threading.Lock()
        self.save_lock = threading.RLock()
        self.load_lock = threading.Lock()
        self.argv = sys.argv[1:] if argv is None else argv
        self.conns = []            # connected clients (Conn)
        self.open_requests = {}    # server request id -> (thread id, request) until answered or dropped
        self.hooks = Hooks("codex", plugin_dirs("FAKE_CODEX_PLUGIN_DIRS"))
        self.sock_path = None      # --listen unix://PATH
        self.on_exit = None        # the in-process TUI's cleanup (SessionEnd, terminal)
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
        self.config = parse_config_args(self.argv)
        self.mcp = parse_fake_mcp()     # FAKE_MCP: [(name, status)]
        self.home = os.path.join(agent_root(), "codex")
        self.tdir = os.path.join(self.home, "threads")
        os.makedirs(self.tdir, exist_ok=True)

    # ------------------------------------------------------------ output and routing
    def write_stdout(self, line):
        with self.out_lock:
            if self.hung:
                return
            try:
                self.chaos.write(sys.stdout, line)
            except (BrokenPipeError, ValueError):
                os._exit(1)

    def add_conn(self, conn):
        with self.cv:
            self.conns.append(conn)

    def remove_conn(self, conn):
        with self.cv:
            conn.closed = True
            conn.subs.clear()
            if conn in self.conns:
                self.conns.remove(conn)

    def targets(self, tid=None):
        """Thread notifications and server requests go to the thread's subscribers; the rest to everyone."""
        with self.cv:
            if tid is None:
                return [c for c in self.conns if c.initialized and not c.closed]
            return [c for c in self.conns if tid in c.subs and not c.closed]

    def subscribe(self, conn, tid):
        with self.cv:
            conn.subs.add(tid)

    def notify(self, method, params):
        obj = {"method": method, "params": params, "emittedAtMs": now_ms()}
        tid = params.get("threadId") if isinstance(params, dict) else None
        for c in self.targets(tid):
            c.send(obj)

    def server_request(self, th, obj):
        """An approval / question for a thread: sent to every subscriber; the first answer wins
        (handle_client_response) and serverRequest/resolved tells all of them."""
        with self.cv:
            self.open_requests[obj["id"]] = (th["id"], obj)
        for c in self.targets(th["id"]):
            c.send(obj)

    def close_request(self, req_id):
        with self.cv:
            self.open_requests.pop(req_id, None)

    def replay_requests(self, conn, tid):
        """A client that subscribes while a request is pending gets it too (inferred)."""
        with self.cv:
            pending = [obj for t, obj in sorted(self.open_requests.values(), key=lambda v: v[1]["id"]) if t == tid]
        for obj in pending:
            conn.send(obj)

    # ------------------------------------------------------------ hooks (FAKE_CODEX_PLUGIN_DIRS)
    def fire(self, th, event, turn=None, match=None, **fields):
        if not self.hooks.has(event):
            return
        d = {"session_id": th["id"], "transcript_path": self.path(th["id"]), "cwd": th["cwd"],
             "hook_event_name": event, "model": th["model"]}
        if turn is not None:
            d["turn_id"] = turn.id
        d.update(fields)
        cwd = th["cwd"] if os.path.isdir(th["cwd"]) else os.getcwd()
        self.hooks.run(event, d, cwd, match=match)

    def pre_tool(self, th, turn, command, item_id):
        self.fire(th, "PreToolUse", turn, match="Bash", tool_name="Bash", tool_use_id=item_id,
                  tool_input={"command": command})

    def post_tool(self, th, turn, command, item_id, output):
        self.fire(th, "PostToolUse", turn, match="Bash", tool_name="Bash", tool_use_id=item_id,
                  tool_input={"command": command}, tool_response=output)

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

    def garbage(self, tid):
        for c in self.targets(tid):
            for line in GARBAGE_LINES:
                c.send_raw(line)

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
        """X5: a thread loaded by another live process is refused; that attempt is also a violation of
        "one process per conversation" ($FAKE_AGENT_DIR/violations.log). A dead or zombie owner doesn't count."""
        lp = self.lockpath(tid)
        if os.path.exists(lp):
            try:
                pid = int(open(lp).read().strip() or "0")
            except (ValueError, IOError):
                pid = 0
            if pid and pid != os.getpid() and live_fake(pid):
                log_violation("codex", tid, pid)
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

    # ------------------------------------------------------------ transports
    def dispatch(self, conn, msg):
        if not isinstance(msg, dict):
            return
        if "method" in msg:
            if "id" in msg:
                self.handle_request(conn, msg)
            # notifications (e.g. "initialized") need no answer
        elif "id" in msg:
            self.handle_client_response(msg)

    def run(self):
        """`--listen stdio://`: the one client is stdin/stdout; stdin EOF ends the server (X6)."""
        slow = float(os.environ.get("FAKE_SLOW_START") or 0)
        if slow > 0:
            time.sleep(slow)
        signal.signal(signal.SIGTERM, self.on_sigterm)
        conn = StdioConn(self)
        self.add_conn(conn)
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
                self.dispatch(conn, msg)
        finally:
            while self.hung:       # a hung server does not notice EOF either
                time.sleep(3600)
            self.shutdown()

    def run_unix(self, path):
        """`--listen unix://PATH`: a WebSocket server on a unix socket. Clients come and go; the server
        keeps running (stdin is not read) until SIGTERM/SIGINT/SIGHUP, and removes the socket file."""
        slow = float(os.environ.get("FAKE_SLOW_START") or 0)
        if slow > 0:
            time.sleep(slow)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, self.on_sigterm)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if os.path.exists(path):
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.connect(path)
                sys.stderr.write("Error: failed to bind %s: address already in use\n" % path)
                sys.stderr.flush()
                os._exit(1)
            except OSError:
                os.unlink(path)          # a stale socket file left by a dead server
            finally:
                probe.close()
        try:
            srv.bind(path)
        except OSError as e:
            sys.stderr.write("Error: failed to bind %s: %s\n" % (path, e))
            sys.stderr.flush()
            os._exit(1)
        self.sock_path = os.path.abspath(path)
        srv.listen(64)
        while True:
            try:
                s, _ = srv.accept()
            except InterruptedError:
                continue
            except OSError:
                time.sleep(0.05)
                continue
            threading.Thread(target=self.ws_client, args=(s,), daemon=True).start()

    def ws_client(self, s):
        """HTTP/1.1 upgrade, then one WsConn until the client goes away."""
        try:
            s.settimeout(10)
            buf = b""
            while b"\r\n\r\n" not in buf:
                data = s.recv(4096)
                if not data or len(buf) > 65536:
                    s.close()
                    return
                buf += data
            head, rest = buf.split(b"\r\n\r\n", 1)
            lines = head.decode("latin-1").split("\r\n")
            headers = {}
            for line in lines[1:]:
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
            key = headers.get("sec-websocket-key")
            if not lines[0].startswith("GET ") or "websocket" not in headers.get("upgrade", "").lower() or not key:
                s.sendall(b"HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                s.close()
                return
            s.sendall(("HTTP/1.1 101 Switching Protocols\r\nconnection: upgrade\r\nupgrade: websocket\r\n"
                       "sec-websocket-accept: %s\r\nx-codex-websocket-max-unfragmented-message-bytes: %d\r\n\r\n"
                       % (ws_accept(key), WS_MAX_UNFRAGMENTED)).encode())
            s.settimeout(None)
        except OSError:
            try:
                s.close()
            except OSError:
                pass
            return
        conn = WsConn(self, WsEndpoint(s, rest))
        self.add_conn(conn)
        conn.serve()

    def cleanup(self):
        """What every orderly exit does: kill RUN commands, release thread locks, remove the socket."""
        for sh in list(self.shells):
            sh.kill()
        self.release_locks()
        if self.sock_path:
            try:
                os.unlink(self.sock_path)
            except OSError:
                pass
            self.sock_path = None

    def shutdown(self):
        for sh in list(self.shells):
            sh.kill()               # X6: stdin EOF kills the running command
        with self.cv:
            for th in self.threads.values():
                turn = th.get("active")
                if turn is not None:
                    self.persist_turn(th, turn, "interrupted")
                    self.save(th)
        if self.on_exit is not None:
            self.on_exit("other")
        self.cleanup()
        with self.out_lock:
            try:
                sys.stdout.flush()
            except Exception:
                pass
        os._exit(0)

    def on_sigterm(self, signum, frame):
        if self.ignore_term and signum == signal.SIGTERM:
            return
        self.cleanup()
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    def hang(self):
        """HANG: stay alive, emit nothing, ignore stdin (and its EOF) until killed."""
        with self.out_lock:
            self.hung = True
        while True:
            time.sleep(3600)

    def handle_request(self, conn, msg):
        rid, method, params = msg["id"], msg["method"], msg.get("params") or {}
        try:
            if method == "initialize":
                if conn.initialized:
                    raise RpcError("Already initialized")
                conn.initialized = True
                result = {"userAgent": "%s/%s (fake)" % ((params.get("clientInfo") or {}).get("name", "client"),
                                                          VERSION),
                          "codexHome": self.home, "platformFamily": "unix", "platformOs": "macos"}
            elif not conn.initialized:
                raise RpcError("Not initialized")
            elif method not in KNOWN_METHODS:
                raise RpcError("Invalid request: unknown variant `%s`, expected one of %s"
                               % (method, ", ".join("`%s`" % m for m in KNOWN_METHODS)))
            else:
                fn = getattr(self, "m_" + method.replace("/", "_"))
                result = fn(params, rid, conn)
                if result is None:
                    return  # handler wrote the response itself
        except RpcError as e:
            conn.send({"error": {"code": e.code, "message": e.message}, "id": rid})
            return
        except KeyError as e:
            conn.send({"error": {"code": -32600, "message": "Invalid request: missing field `%s`" % e.args[0]},
                       "id": rid})
            return
        conn.send({"id": rid, "result": result})

    def loaded(self, tid):
        th = self.threads.get(tid)
        if th is None:
            raise RpcError("thread not found: %s" % tid)
        return th

    # ------------------------------------------------------------ thread methods
    def m_thread_start(self, p, rid, conn):
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
        self.subscribe(conn, tid)
        resp = self.thread_response(th)
        conn.send({"id": rid, "result": resp})
        self.notify("thread/started", {"thread": self.thread_obj(th)})
        self.mcp_startup(tid)          # X1, X2*, X7: right after thread/started
        self.fire(th, "SessionStart", match="startup", source="startup")
        return None

    def m_thread_resume(self, p, rid, conn):
        tid = p["threadId"]
        loaded_now = False
        with self.load_lock:
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
                loaded_now = True
        self.subscribe(conn, tid)
        if loaded_now:
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
        conn.send({"id": rid, "result": resp})
        if loaded_now:
            self.fire(th, "SessionStart", match="resume", source="resume")
        self.replay_requests(conn, tid)
        return None

    def m_thread_unsubscribe(self, p, rid, conn):
        self.loaded(p["threadId"])
        with self.cv:
            conn.subs.discard(p["threadId"])     # no more notifications for this client
        return {"status": "unsubscribed"}   # like the real server, the writer lock is NOT released

    def m_thread_turns_list(self, p, rid, conn):
        tid = p["threadId"]
        with self.cv:
            th = self.threads.get(tid)
        if th is None:
            if not os.path.exists(self.path(tid)):
                raise RpcError("no rollout found for thread id %s" % tid)
            th = json.load(open(self.path(tid)))
        return {"data": [self.turn_summary(t) for t in reversed(th["turns"])], "nextCursor": None}

    def m_thread_items_list(self, p, rid, conn):
        """Every item of the thread (or of one turn), not the turns' summaries: a message steered into a
        turn is listed with its clientId (the schema's ThreadItemsListResponse: {item, turnId} entries,
        ascending by default, `sortDirection` "desc" for newest first, `limit`)."""
        tid = p["threadId"]
        with self.cv:
            th = self.threads.get(tid)
            turns = [dict(t, items=list(t["items"])) for t in th["turns"]] if th is not None else None
            if th is not None and th.get("active") is not None:
                active = th["active"]
                for t in turns:
                    if t["id"] == active.id:
                        t["items"] = list(active.items)
        if turns is None:
            if not os.path.exists(self.path(tid)):
                raise RpcError("no rollout found for thread id %s" % tid)
            turns = json.load(open(self.path(tid)))["turns"]
        entries = [{"item": item, "turnId": t["id"], "startedAtMs": None, "completedAtMs": None}
                   for t in turns if p.get("turnId") in (None, t["id"]) for item in t["items"]]
        if p.get("sortDirection") == "desc":
            entries.reverse()
        start = int(p.get("cursor") or 0)
        limit = int(p.get("limit") or 100)
        page = entries[start:start + limit]
        more = start + limit < len(entries)
        return {"data": page, "nextCursor": str(start + limit) if more else None,
                "backwardsCursor": str(start) if page else None}

    # ------------------------------------------------------------ turn methods
    def parse_input(self, p):
        texts = [i.get("text", "") for i in p.get("input") or [] if i.get("type") == "text"]
        return {"text": "\n".join(texts), "content": p.get("input") or [],
                "clientId": p.get("clientUserMessageId")}

    def deliver(self, th, inp, rid, steer_result, conn, expected=None, steer_only=False):
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
                        conn.send({"id": rid, "result": steer_result(turn)})
                        turn.steer.append(inp)
                        self.cv.notify_all()
                        return
                elif turn is not None:
                    wait_for = turn
                elif steer_only:
                    raise RpcError("no active turn to steer")
                else:
                    turn = self.begin_turn(th, inp)
                    conn.send({"id": rid, "result": {"turn": self.turn_obj(turn, started=False)}})
                    self.launch(th, turn)
                    return
            wait_for.done.wait(30)

    def m_turn_start(self, p, rid, conn):
        th = self.loaded(p["threadId"])
        self.subscribe(conn, th["id"])     # a client that starts a turn sees it (inferred for an unsubscribed one)
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
        self.deliver(th, inp, rid, lambda turn: {"turn": self.turn_obj(turn, started=False)}, conn)
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

    def m_turn_steer(self, p, rid, conn):
        th = self.loaded(p["threadId"])
        self.subscribe(conn, th["id"])
        self.deliver(th, self.parse_input(p), rid, lambda turn: {"turnId": turn.id}, conn,
                     expected=p.get("expectedTurnId"), steer_only=True)
        return None

    def m_turn_interrupt(self, p, rid, conn):
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
                    conn.send({"id": rid, "result": {}})
                    turn.interrupted = True
                    self.cv.notify_all()
                    return None
            wait_for.done.wait(30)

    # ------------------------------------------------------------ queue (experimental)
    def m_thread_queue_list(self, p, rid, conn):
        th = self.loaded(p["threadId"])
        self.watch_queue(th["id"])
        return {"data": list(th["queue"]), "nextCursor": None}

    def m_thread_queue_add(self, p, rid, conn):
        th = self.loaded(p["threadId"])
        self.subscribe(conn, th["id"])
        self.watch_queue(th["id"])
        sub = {"id": uuid7(), "input": p.get("input") or [], "clientUserMessageId": p["clientUserMessageId"]}
        with self.cv:
            th["queue"].append(sub)
            conn.send({"id": rid, "result": {"queuedSubmission": sub}})
            self.notify("thread/queue/changed", {"threadId": th["id"]})
            if th.get("active") is None:
                self.drain_queue(th)
        return None

    def m_thread_queue_delete(self, p, rid, conn):
        th = self.loaded(p["threadId"])
        self.watch_queue(th["id"])
        with self.cv:
            before = len(th["queue"])
            th["queue"] = [q for q in th["queue"] if q["id"] != p["queuedSubmissionId"]]
            deleted = len(th["queue"]) != before
        if deleted:
            self.notify("thread/queue/changed", {"threadId": th["id"]})
        return {"deleted": deleted}

    def m_thread_queue_start(self, p, rid, conn):
        th = self.loaded(p["threadId"])
        self.subscribe(conn, th["id"])
        self.watch_queue(th["id"])
        with self.cv:
            if not th["queue"]:
                raise RpcError("queue is empty")
            if th.get("active") is not None:
                raise RpcError("thread already has an active turn")
            turn = self.drain_queue(th, p.get("queuedSubmissionId"), launch=False)
            conn.send({"id": rid, "result": {"turn": self.turn_obj(turn, started=False)}})
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
        # The real server matches ids by type too: an answer with id false to request 0 is not an
        # answer to it (observed 2026-10-08 with codex-cli 0.160.0: the approval stayed pending).
        if isinstance(msg["id"], bool):
            return
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
        self.fire(th, "UserPromptSubmit", turn, prompt=inp["text"])    # also for a steered input (inferred)
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
        self.pre_tool(th, turn, "sleep %s" % label, item["id"])
        self.item_started(turn, item)
        self.wait(turn, deadline=time.time() + secs)
        done = dict(item)
        done.update({"status": "completed", "exitCode": 0, "durationMs": int(secs * 1000)})
        self.item_completed(turn, done)
        self.post_tool(th, turn, "sleep %s" % label, item["id"], "")
        self.usage_noise(th, turn)

    def run_background(self, th, turn, secs, label):
        """X15wake: the command runs as a background terminal. Its item stays open through the
        turn's end; n seconds later item/completed arrives with the finished turn's id."""
        item = self.cmd_item(th, "sleep %s" % label, "inProgress", "unifiedExecStartup", pid=str(os.getpid()))
        self.pre_tool(th, turn, "sleep %s" % label, item["id"])
        self.item_started(turn, item)
        self.post_tool(th, turn, "sleep %s" % label, item["id"], "")   # the tool call returns at once
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
        command = "yes 0123456789abcdef | head -c %d" % size
        item = self.cmd_item(th, command, "inProgress", "unifiedExecStartup", pid=str(os.getpid()))
        self.pre_tool(th, turn, command, item["id"])
        self.item_started(turn, item)
        step = 1024 * 1024
        for i in range(0, len(out), step):
            self.checkpoint(turn)
            self.notify("item/commandExecution/outputDelta", {"threadId": th["id"], "turnId": turn.id,
                                                              "itemId": item["id"], "delta": out[i:i + step]})
        done = dict(item)
        done.update({"status": "completed", "exitCode": 0, "durationMs": 0, "aggregatedOutput": out})
        self.item_completed(turn, done)
        self.post_tool(th, turn, command, item["id"], out)
        self.usage_noise(th, turn)

    def run_shell(self, th, turn, cmd):
        """RUN: a real /bin/sh command as a commandExecution item (X10 shape). Interruptible; an
        interrupt kills it and leaves the item without item/completed (X1)."""
        self.maybe_commentary(turn)
        cwd = th["cwd"] if os.path.isdir(th["cwd"]) else os.getcwd()
        item_id = "exec-" + str(uuidlib.uuid4())
        self.pre_tool(th, turn, cmd, item_id)
        t0 = time.time()
        sh = ShellRun(cmd, cwd)
        self.shells.add(sh)
        item = self.cmd_item(th, cmd, "inProgress", "unifiedExecStartup", pid=str(sh.p.pid),
                             quoted=shlex.quote(cmd), cwd=cwd, item_id=item_id)
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
        self.post_tool(th, turn, cmd, item_id, out)
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
            self.pre_tool(th, turn, command, item["id"])
            self.item_started(turn, item)
            done = dict(item)
            done.update({"status": "completed", "exitCode": 0, "durationMs": 0})
            self.item_completed(turn, done)
            self.post_tool(th, turn, command, item["id"], "")
            return "approval not needed" if th["approvalPolicy"] == "never" else "approval accepted (remembered)"
        self.maybe_commentary(turn)
        with self.cv:
            req_id = self.server_req_id
            self.server_req_id += 1
            turn.approval = {"id": req_id, "decision": None}
            self.pending_server[req_id] = turn
        item = self.cmd_item(th, command, "inProgress", "agent")
        self.pre_tool(th, turn, command, item["id"])
        self.status(th, "active", ["waitingOnApproval"])
        self.item_started(turn, item)
        self.fire(th, "PermissionRequest", turn, match="Bash", tool_name="Bash", tool_input={"command": command})
        self.server_request(th, {"method": "item/commandExecution/requestApproval", "id": req_id, "params": {
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
        self.close_request(req_id)
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
            self.post_tool(th, turn, command, item["id"], "")
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
        self.server_request(th, {"method": "item/tool/requestUserInput", "id": req_id, "params": {
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
        self.close_request(req_id)
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
        self.server_request(th, {"method": method, "id": req_id, "params": params})
        self.wait(turn, pred=lambda: turn.approval["decision"] is not None)
        result = turn.approval.get("result") or {}
        with self.cv:
            turn.approval = None
            self.pending_server.pop(req_id, None)
        self.close_request(req_id)
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
                        restore_terminals()
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
                    self.garbage(th["id"])
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
                    self.open_requests.pop(pending["id"], None)
            self.status(th, "idle")
            self.persist_turn(th, turn, "interrupted")
            self.end_turn(th, turn, self.turn_obj(turn, "interrupted"), pending)
            return
        # Stop once no input can join the turn any more; an interrupted or failed turn fires none
        self.fire(th, "Stop", turn, stop_hook_active=False, last_assistant_message=turn.last_final["text"])
        self.status(th, "idle")
        self.persist_turn(th, turn, "completed")
        self.end_turn(th, turn, self.turn_obj(turn, "completed", items=[turn.last_final], view="summary"))
        if garbage:
            self.garbage(th["id"])

    def save_progress(self, th, turn):
        for t in th["turns"]:
            if t["id"] == turn.id:
                t["items"] = list(turn.items)
        self.save(th)

    # ------------------------------------------------------------ the in-process TUI's exit
    def tui_exit(self, reason):
        """The local TUI quits: a running turn is abandoned (persisted as interrupted, no hook), SessionEnd
        runs for its thread (inferred: input as SessionStart's plus `reason`), locks are released."""
        for sh in list(self.shells):
            sh.kill()
        with self.cv:
            loaded = list(self.threads.values())
            for th in loaded:
                turn = th.get("active")
                if turn is not None:
                    self.persist_turn(th, turn, "interrupted")
                    self.save(th)
        for th in loaded:
            self.fire(th, "SessionEnd", match=reason, reason=reason)
        self.cleanup()


# ------------------------------------------------------------------ TUI mode (codex [PROMPT] / codex resume ...)

CLI_VALUE_FLAGS = set("""-m --model -c --config -a --ask-for-approval -s --sandbox -C --cd -p --profile --remote -i
--image --add-dir --enable --disable --remote-auth-token-env --local-provider --listen""".split())


def parse_cli(argv):
    """(subcommand, options). subcommand is "app-server", "resume" or None (a new TUI session)."""
    o = {"model": None, "approval": None, "sandbox": None, "cd": None, "remote": None, "bypass": False,
         "positional": [], "listen": [], "last": False, "version": False}
    sub = None
    i = 0
    while i < len(argv):
        a, val = argv[i], None
        if a.startswith("--") and "=" in a:
            a, val = a.split("=", 1)
        if a in CLI_VALUE_FLAGS:
            if val is None:
                i += 1
                val = argv[i] if i < len(argv) else ""
            if a in ("-m", "--model"):
                o["model"] = val
            elif a in ("-a", "--ask-for-approval"):
                o["approval"] = val
            elif a in ("-s", "--sandbox"):
                o["sandbox"] = val
            elif a in ("-C", "--cd"):
                o["cd"] = val
            elif a == "--remote":
                o["remote"] = val
            elif a == "--listen":
                o["listen"].append(val)
        elif a in ("--dangerously-bypass-approvals-and-sandbox", "--yolo"):
            o["bypass"] = True
        elif a == "--last":
            o["last"] = True
        elif a in ("--version", "-V"):
            o["version"] = True
        elif a.startswith("-"):
            pass
        elif sub is None and not o["positional"] and a in ("app-server", "resume"):
            sub = a
        else:
            o["positional"].append(a)
        i += 1
    return sub, o


class CodexTui(object):
    """A line-oriented Codex interface on a terminal. With --remote unix://PATH it is a WebSocket client
    of that app server (`initialize`, `thread/resume` without overrides); otherwise it runs its own engine
    in-process on the thread (same state files and writer lock, hooks run here). It shows every turn on
    the thread, including those other clients start: `› text` a user message, `• text` an agent message,
    `• Ran cmd` a command, `─ Worked for Ns ─` a turn's end. Typed lines start a turn, or steer the
    running one. Approvals and questions wait for a typed answer."""

    def __init__(self, resume, opts):
        self.resume = resume
        self.opts = opts
        self.ui = LineUI("› ")
        self.nid = 0
        self.waiting = {}
        self.wlock = threading.Lock()
        self.tid = None
        self.active = None              # the running turn's id
        self.turn_t0 = {}
        self.requests = []              # server requests waiting for a typed answer (oldest first)
        self.rlock = threading.RLock()
        self.engine = None
        self.ep = None
        self.inbox = queue.Queue()      # local mode: engine -> TUI
        self.outbox = queue.Queue()     # local mode: TUI -> engine
        self.exiting = False
        self.ready = False              # banner shown: prompts for server requests may print
        self.ended = set()              # turns seen completing
        self.started_turns = set()      # turns this TUI started

    # ------------------------------------------------------------ plumbing
    def fail(self, msg, code=1):
        self.ui.restore()
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()
        os._exit(code)

    def connect(self):
        if self.opts["remote"]:
            url = self.opts["remote"]
            if not url.startswith("unix://") or len(url) <= 7:
                self.fail("Error: unsupported --remote URL %r (the fake knows unix://PATH)" % url, 2)
            try:
                self.ep = ws_connect_unix(url[7:])
            except (OSError, socket.error) as e:
                self.fail("Error: failed to connect to the app server at %s: %s" % (url, e))
            threading.Thread(target=self.ws_reader, daemon=True).start()
            return
        self.engine = FakeCodex()
        self.engine.on_exit = self.engine_exit
        conn = LocalConn(self.engine, self.inbox.put)
        self.engine.add_conn(conn)

        def to_engine():
            while True:
                self.engine.dispatch(conn, self.outbox.get())

        def from_engine():
            while True:
                self.incoming(self.inbox.get())

        threading.Thread(target=to_engine, daemon=True).start()
        threading.Thread(target=from_engine, daemon=True).start()

    def ws_reader(self):
        try:
            while True:
                m = self.ep.recv_message()
                if m is None:
                    break
                try:
                    msg = json.loads(m[1].decode("utf-8"))
                except ValueError:
                    continue
                if isinstance(msg, dict):
                    self.incoming(msg)
        except (EOFError, OSError, WsProtocolError, struct.error):
            pass
        if not self.exiting:
            self.ui.say("■ Lost the connection to the app server")
            self.fail("fake_codex: the app server closed the connection")

    def send(self, obj):
        if self.ep is not None:
            try:
                self.ep.send_text(json.dumps(obj))
            except OSError:
                pass
        else:
            self.outbox.put(obj)

    def call(self, method, params, timeout=35):
        with self.wlock:
            self.nid += 1
            rid = self.nid
            slot = [threading.Event(), None]
            self.waiting[rid] = slot
        self.send({"id": rid, "method": method, "params": params})
        slot[0].wait(timeout)
        with self.wlock:
            self.waiting.pop(rid, None)
        return slot[1] or {"error": {"code": -1, "message": "no answer to %s" % method}}

    def incoming(self, msg):
        if "method" not in msg and "id" in msg:
            with self.wlock:
                slot = self.waiting.get(msg["id"])
            if slot is not None:
                slot[1] = msg
                slot[0].set()
        elif "method" in msg and "id" in msg:
            if self.tid is None or (msg.get("params") or {}).get("threadId") in (None, self.tid):
                with self.rlock:
                    if any(r["msg"]["id"] == msg["id"] for r in self.requests):
                        return
                    self.requests.append({"msg": msg, "answers": {}})
                    first = len(self.requests) == 1
                if first and self.ready:
                    self.ask()
        elif "method" in msg:
            self.note(msg)

    # ------------------------------------------------------------ startup and the input loop
    def latest_thread(self):
        best = None
        tdir = os.path.join(agent_root(), "codex", "threads")
        for name in os.listdir(tdir) if os.path.isdir(tdir) else []:
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(tdir, name)) as f:
                    th = json.load(f)
            except (IOError, ValueError):
                continue
            if th.get("cwd") == os.getcwd():
                key = th.get("updatedAt") or th.get("createdAt") or 0
                if best is None or key > best[0]:
                    best = (key, th["id"])
        return best[1] if best else None

    def main(self):
        o = self.opts
        if o["cd"]:
            os.chdir(o["cd"])
        pos = list(o["positional"])
        thread_id = None
        if self.resume:
            if o["last"]:
                if o["remote"]:
                    self.fail("fake_codex: resume --last with --remote is not faked; pass a thread id", 2)
                thread_id = self.latest_thread()
                if thread_id is None:
                    self.fail("No saved session found in %s." % os.getcwd())
            elif pos:
                thread_id = pos.pop(0)
            else:
                self.fail("fake_codex: the session picker is not faked; pass a thread id (or --last)", 2)
        prompt = " ".join(pos) or None
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, self.on_term)
        signal.signal(signal.SIGINT, lambda s, f: threading.Thread(target=self.interrupt, args=(True,),
                                                                     daemon=True).start())
        self.ui.on_escape = lambda: threading.Thread(target=self.interrupt, daemon=True).start()
        self.connect()
        r = self.call("initialize", {"clientInfo": {"name": "codex-tui", "title": None, "version": VERSION},
                                     "capabilities": {"experimentalApi": True}})
        if "error" in r:
            self.fail("Error: %s" % r["error"]["message"])
        self.send({"method": "initialized"})
        if thread_id is None:
            params = {"cwd": os.getcwd()}
            params.update(self.overrides())
            r = self.call("thread/start", params)
        else:
            params = {"threadId": thread_id}
            if not o["remote"]:
                params.update(self.overrides())     # --remote: thread/resume without overrides (X16)
            r = self.call("thread/resume", params)
        if "error" in r:
            self.fail("Error: %s" % r["error"]["message"])
        res = r["result"]
        th = res["thread"]
        self.tid = th["id"]
        self.ui.start()
        sb = res.get("sandbox") or {}
        self.ui.say(">_ Fake Codex (v%s)" % VERSION, "  thread: %s" % self.tid, "  directory: %s" % res["cwd"],
                    "  model: %s · approvals: %s · sandbox: %s%s" % (
                        res["model"], res["approvalPolicy"], sb.get("type") if isinstance(sb, dict) else sb,
                        " · remote: %s" % o["remote"] if o["remote"] else ""), "")
        for t in th.get("turns") or []:
            for it in t.get("items") or []:
                self.show_item(it)
            if t.get("status") == "inProgress" and t["id"] not in self.ended and self.active is None:
                self.active = t["id"]
        with self.rlock:
            self.ready = True
            if self.requests:
                self.ask()
        if prompt:
            self.submit(prompt)
        self.ui.show_prompt()
        while True:
            line = self.ui.read_line()
            if line is None:
                if not self.ui.tty:            # piped input: let the work finish first
                    while self.active or self.started_turns - self.ended:
                        time.sleep(0.05)
                self.quit("other" if self.ui.hangup else "exit")
            text = line.strip()
            if not text:
                continue
            if self.answer(text):
                continue
            if text in ("/exit", "/quit"):
                self.quit("exit")
            self.submit(text)

    def overrides(self):
        o, p = self.opts, {}
        if o["model"]:
            p["model"] = o["model"]
        if o["approval"]:
            p["approvalPolicy"] = o["approval"]
        if o["sandbox"]:
            p["sandbox"] = o["sandbox"]
        if o["bypass"]:
            p["approvalPolicy"], p["sandbox"] = "never", "danger-full-access"
        return p

    def submit(self, text):
        params = {"threadId": self.tid, "clientUserMessageId": str(uuidlib.uuid4()),
                  "input": [{"type": "text", "text": text, "text_elements": []}]}
        if self.active:
            r = self.call("turn/steer", dict(params, expectedTurnId=self.active))
            if "error" not in r:
                return
        r = self.call("turn/start", params)
        if "error" in r:
            self.ui.say("■ %s" % r["error"]["message"])
        else:
            self.started_turns.add(r["result"]["turn"]["id"])

    def interrupt(self, hint=False):
        turn = self.active
        if turn:
            self.call("turn/interrupt", {"threadId": self.tid, "turnId": turn})
        elif hint:
            self.ui.say("  (Ctrl-C does not quit: type /exit or press Ctrl-D)")

    def engine_exit(self, reason):
        """EXIT_CLEAN in the local engine: SessionEnd, then the terminal is restored."""
        for th in list(self.engine.threads.values()):
            self.engine.fire(th, "SessionEnd", match=reason, reason=reason)
        self.ui.restore()

    def quit(self, reason, signum=None):
        if self.exiting:
            return
        self.exiting = True
        if self.engine is not None:
            self.engine.tui_exit(reason)
        elif self.ep is not None:
            self.ep.close(1000)
            try:
                self.ep.sock.close()
            except OSError:
                pass
        self.ui.restore()
        if signum is not None:
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
        os._exit(0)

    def on_term(self, signum, frame):
        if self.engine is not None and self.engine.ignore_term and signum == signal.SIGTERM:
            return
        self.quit("other", signum)

    # ------------------------------------------------------------ rendering
    def show_item(self, it):
        ty = it.get("type")
        if ty == "userMessage":
            text = "\n".join(c.get("text", "") for c in it.get("content") or [] if c.get("type") == "text")
            self.ui.say("› " + text.replace("\n", "\n  "))
        elif ty == "agentMessage":
            self.ui.say("• " + (it.get("text") or "").replace("\n", "\n  "))
        elif ty == "commandExecution":
            cmd = ((it.get("commandActions") or [{}])[0] or {}).get("command") or it.get("command")
            if it.get("status") == "declined":
                self.ui.say("✗ Declined: %s" % cmd)
            else:
                out = (it.get("aggregatedOutput") or "").strip("\n").split("\n")
                first = out[0][:200] if out and out[0] else "(no output)"
                self.ui.say("• Ran %s" % cmd, "  └ %s" % first)

    def note(self, msg):
        m, p = msg["method"], msg.get("params") or {}
        if self.tid is not None and p.get("threadId") not in (None, self.tid):
            return
        if m == "turn/started":
            self.active = p["turn"]["id"]
            self.turn_t0[self.active] = time.time()
        elif m == "item/completed":
            self.show_item(p["item"])
        elif m == "turn/completed":
            t = p["turn"]
            self.ended.add(t["id"])
            if self.active == t["id"]:
                self.active = None
            secs = int(time.time() - self.turn_t0.pop(t["id"], time.time()))
            if t["status"] == "completed":
                self.ui.say("─ Worked for %ds ─" % secs)
            elif t["status"] == "interrupted":
                self.ui.say("■ Conversation interrupted - tell the model what to do differently.")
            else:
                self.ui.say("■ Turn failed: %s" % short((t.get("error") or {}).get("message", ""), 200))
        elif m == "serverRequest/resolved":
            with self.rlock:
                current = self.requests[0]["msg"]["id"] if self.requests else None
                self.requests = [r for r in self.requests if r["msg"]["id"] != p.get("requestId")]
                if current == p.get("requestId"):
                    self.ui.say("  (answered elsewhere)")
                    if self.requests:
                        self.ask()
        elif m == "warning":
            self.ui.say("⚠ %s" % p.get("message", ""))

    def ask(self):
        with self.rlock:
            if not self.requests:
                return
            r = self.requests[0]
            m, p = r["msg"]["method"], r["msg"].get("params") or {}
            if m == "item/commandExecution/requestApproval":
                cmd = ((p.get("commandActions") or [{}])[0] or {}).get("command") or p.get("command")
                self.ui.say("", "Allow command?", "  $ %s" % cmd,
                            "[y]es / [a]lways (this session) / [n]o, tell Codex what to do differently")
            elif m == "item/tool/requestUserInput":
                q = p["questions"][len(r["answers"])]
                opts = "  ".join("(%d) %s" % (i + 1, x.get("label")) for i, x in enumerate(q.get("options") or []))
                self.ui.say("", "? %s" % q["question"], "  %s   (type a number or an answer)" % opts)
            elif m == "item/permissions/requestApproval":
                self.ui.say("", "Grant permissions? %s" % json.dumps(p.get("permissions")), "[y]es / [n]o")
            elif m == "mcpServer/elicitation/request":
                self.ui.say("", "%s: %s %s" % (p.get("serverName"), p.get("message"), p.get("url") or ""),
                            "[y]es / [n]o")
            else:
                self.ui.say("", "%s (y/n)" % m)

    def answer(self, text):
        with self.rlock:
            if not self.requests:
                return False
            r = self.requests[0]
            m, p = r["msg"]["method"], r["msg"].get("params") or {}
            yes, no = text.lower() in ("y", "yes"), text.lower() in ("n", "no")
            if m == "item/tool/requestUserInput":
                q = p["questions"][len(r["answers"])]
                labels = [x.get("label") for x in q.get("options") or []]
                if text.isdigit() and 1 <= int(text) <= len(labels):
                    text = labels[int(text) - 1]
                r["answers"][q["id"]] = {"answers": [text]}
                if len(r["answers"]) < len(p["questions"]):
                    self.ask()
                    return True
                result = {"answers": r["answers"]}
            elif m == "item/commandExecution/requestApproval":
                if text.lower() in ("a", "always"):
                    result = {"decision": "acceptForSession"}
                elif yes or no:
                    # the real TUI's "No, and tell Codex what to do differently" aborts the turn
                    result = {"decision": "accept" if yes else "cancel"}
                else:
                    self.ask()
                    return True
            elif yes or no:
                if m == "item/permissions/requestApproval":
                    result = {"permissions": p.get("permissions") if yes else {}, "scope": "turn"}
                else:
                    result = {"action": "accept" if yes else "decline", "content": {} if yes else None}
            else:
                self.ask()
                return True
            self.requests.pop(0)
            self.send({"id": r["msg"]["id"], "result": result})
            if self.requests:
                self.ask()
        return True


def main():
    sub, opts = parse_cli(sys.argv[1:])
    if opts["version"]:
        sys.stdout.write("codex-cli %s\n" % VERSION)
        return
    if sub == "app-server":
        if len(opts["listen"]) > 1:
            sys.stderr.write("error: the argument '--listen <URL>' cannot be used multiple times\n")
            sys.exit(2)
        url = opts["listen"][0] if opts["listen"] else "stdio://"
        if url in ("stdio://", "stdio"):
            FakeCodex().run()
        elif url.startswith("unix://") and len(url) > len("unix://"):
            FakeCodex().run_unix(url[len("unix://"):])
        else:
            sys.stderr.write("error: invalid value '%s' for '--listen <URL>' (the fake knows stdio:// and "
                             "unix://PATH)\n" % url)
            sys.exit(2)
        return
    CodexTui(sub == "resume", opts).main()


if __name__ == "__main__":
    main()
