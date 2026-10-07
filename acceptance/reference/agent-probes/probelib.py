"""Shared probe helpers for driving `claude` (stream-json) and `codex app-server`.

Python 3.9, stdlib only. Every event is recorded with a relative timestamp and
written to a JSONL log so findings can be re-checked later.
"""
import json
import os
import subprocess
import sys
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LOGS = os.path.join(ROOT, "logs")
WORK = os.path.join(ROOT, "work")
os.makedirs(LOGS, exist_ok=True)
os.makedirs(WORK, exist_ok=True)

DROP_KEYS = ("tools", "mcp_servers", "slash_commands", "agents", "skills", "plugins")


def abbrev(obj, maxlen=160):
    """Recursively shorten long strings / lists for display."""
    if isinstance(obj, str):
        return obj if len(obj) <= maxlen else obj[:maxlen] + "...(%d)" % len(obj)
    if isinstance(obj, list):
        if len(obj) > 8:
            return [abbrev(x, maxlen) for x in obj[:8]] + ["...+%d" % (len(obj) - 8)]
        return [abbrev(x, maxlen) for x in obj]
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in DROP_KEYS and isinstance(v, list):
                out[k] = "<%d items>" % len(v)
            else:
                out[k] = abbrev(v, maxlen)
        return out
    return obj


class Proc(object):
    def __init__(self, cmd, name, cwd=None, env=None, quiet=False, filt=None):
        self.name = name
        self.t0 = time.time()
        self.events = []  # (t, kind, obj) kind in out/raw/err/in
        self.cond = threading.Condition()
        self.quiet = quiet
        self.filt = filt
        self.log = open(os.path.join(LOGS, name + ".jsonl"), "w")
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, cwd=cwd or WORK,
                                  env=env, bufsize=1)
        self._rec("meta", {"cmd": cmd})
        threading.Thread(target=self._rd_out, daemon=True).start()
        threading.Thread(target=self._rd_err, daemon=True).start()

    def t(self):
        return round(time.time() - self.t0, 2)

    def _rec(self, kind, obj):
        t = self.t()
        with self.cond:
            self.events.append((t, kind, obj))
            self.cond.notify_all()
        try:
            self.log.write(json.dumps({"t": t, "k": kind, "m": obj}) + "\n")
            self.log.flush()
        except Exception:
            pass
        if not self.quiet and (self.filt is None or self.filt(kind, obj)):
            print("%6.2f %-3s %s" % (t, kind, json.dumps(abbrev(obj))[:900]), flush=True)

    def _rd_out(self):
        for line in self.p.stdout:
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                self._rec("out", json.loads(line))
            except Exception:
                self._rec("raw", line[:500])
        self._rec("eof", "stdout closed")

    def _rd_err(self):
        for line in self.p.stderr:
            self._rec("err", line.rstrip("\n")[:500])

    def write_raw(self, s):
        self._rec("in", s)
        self._write(s + "\n")

    def send(self, obj):
        self._rec("in", obj)
        self._write(json.dumps(obj) + "\n")

    def _write(self, data):
        try:
            self.p.stdin.write(data)
            self.p.stdin.flush()
        except (BrokenPipeError, ValueError, OSError) as e:
            self._rec("meta", "write failed: %r" % e)

    def wait_for(self, pred, timeout=60, start=0):
        """Wait until some out-event (index >= start) satisfies pred. Returns (idx, obj)."""
        end = time.time() + timeout
        with self.cond:
            while True:
                for i in range(start, len(self.events)):
                    t, k, o = self.events[i]
                    if k == "out" and pred(o):
                        return i, o
                rem = end - time.time()
                if rem <= 0:
                    return None, None
                self.cond.wait(min(rem, 0.5))

    def n(self):
        with self.cond:
            return len(self.events)

    def close_stdin(self):
        self._rec("meta", "close stdin")
        try:
            self.p.stdin.close()
        except BaseException as e:
            self._rec("meta", "close err %r" % e)

    def wait_exit(self, timeout=30):
        try:
            rc = self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self._rec("meta", "exit timeout after %ss; killing" % timeout)
            self.p.kill()
            rc = self.p.wait()
            self._rec("meta", {"killed_rc": rc})
            return None
        time.sleep(0.2)
        self._rec("meta", {"exit_code": rc})
        return rc

    def kill(self):
        try:
            self.p.kill()
        except Exception:
            pass


# ---------------------------------------------------------------- Claude

def claude_env():
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")}
    env["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1"
    return env


def claude_filter(kind, obj):
    if kind != "out":
        return True
    if obj.get("type") == "stream_event":
        return False
    return True


class Claude(Proc):
    BASE = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--replay-user-messages", "--permission-prompt-tool", "stdio",
            "--model", "haiku"]

    def __init__(self, name, extra=(), auto_allow=False, cmd=None, **kw):
        self.auto_allow = auto_allow
        Proc.__init__(self, (cmd or self.BASE) + list(extra), name, env=claude_env(),
                      filt=claude_filter, **kw)

    def _rec(self, kind, obj):
        if kind == "out" and isinstance(obj, dict) and obj.get("type") in ("assistant", "user"):
            # keep full in log, but display shortened content
            pass
        Proc._rec(self, kind, obj)
        if (kind == "out" and getattr(self, "auto_allow", False) and isinstance(obj, dict)
                and obj.get("type") == "control_request"
                and obj.get("request", {}).get("subtype") == "can_use_tool"):
            self.reply_perm(obj, True)

    def init(self, timeout=30):
        self.send({"type": "control_request", "request_id": "init1",
                   "request": {"subtype": "initialize", "hooks": None}})
        return self.wait_for(lambda m: m.get("type") == "control_response"
                             and m.get("response", {}).get("request_id") == "init1", timeout)

    def user(self, text, uid=None):
        uid = uid or str(uuid.uuid4())
        self.send({"type": "user", "message": {"role": "user", "content": text},
                   "parent_tool_use_id": None, "session_id": "default", "uuid": uid})
        return uid

    def control(self, subtype, rid=None, **kw):
        rid = rid or ("c_" + uuid.uuid4().hex[:8])
        req = {"subtype": subtype}
        req.update(kw)
        self.send({"type": "control_request", "request_id": rid, "request": req})
        return rid

    def reply_perm(self, req, allow, message="no"):
        if allow:
            r = {"behavior": "allow", "updatedInput": req["request"].get("input")}
        else:
            r = {"behavior": "deny", "message": message}
        self.send({"type": "control_response",
                   "response": {"subtype": "success", "request_id": req["request_id"], "response": r}})

    def wait_result(self, timeout=90, start=0):
        return self.wait_for(lambda m: m.get("type") == "result", timeout, start)

    def wait_state(self, state, timeout=60, start=0):
        return self.wait_for(lambda m: m.get("type") == "system"
                             and m.get("subtype") == "session_state_changed"
                             and m.get("state") == state, timeout, start)


# ---------------------------------------------------------------- Codex

CODEX_SKIP = set(["item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta",
                  "item/commandExecution/outputDelta", "thread/tokenUsage/updated",
                  "account/rateLimits/updated", "mcpServer/startupStatus/updated",
                  "item/reasoning/summaryPartAdded"])


def codex_filter(kind, obj):
    if kind == "out" and isinstance(obj, dict) and obj.get("method") in CODEX_SKIP:
        return False
    return True


class Codex(Proc):
    MODEL = "gpt-6-luna"

    def __init__(self, name, cmd=None, auto_decision=None, **kw):
        self.nid = 0
        self.auto_decision = auto_decision
        Proc.__init__(self, cmd or ["codex", "app-server", "--listen", "stdio://"], name,
                      filt=codex_filter, **kw)

    def _rec(self, kind, obj):
        Proc._rec(self, kind, obj)
        if (kind == "out" and self.auto_decision and isinstance(obj, dict) and "id" in obj
                and "method" in obj and "Approval" in obj["method"]):
            self.respond(obj["id"], {"decision": self.auto_decision})

    def req(self, method, params=None):
        self.nid += 1
        msg = {"id": self.nid, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        return self.nid

    def notify(self, method, params=None):
        msg = {"method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)

    def respond(self, rid, result):
        self.send({"id": rid, "result": result})

    def call(self, method, params=None, timeout=60):
        rid = self.req(method, params)
        i, m = self.wait_for(lambda m: m.get("id") == rid and "method" not in m, timeout)
        return m

    def init(self):
        r = self.call("initialize", {"clientInfo": {"name": "probe", "title": None, "version": "0"},
                                     "capabilities": {"experimentalApi": True, "requestAttestation": False}})
        self.notify("initialized")
        return r

    def thread_start(self, **extra):
        params = {"model": self.MODEL, "cwd": WORK, "approvalPolicy": "never", "sandbox": "workspace-write",
                  "config": {"model_reasoning_effort": "low"}}
        params.update(extra)
        return self.call("thread/start", params)

    def turn_start(self, tid, text, cmid=None, **extra):
        cmid = cmid or str(uuid.uuid4())
        params = {"threadId": tid, "clientUserMessageId": cmid,
                  "input": [{"type": "text", "text": text, "text_elements": []}]}
        params.update(extra)
        rid = self.req("turn/start", params)
        return rid, cmid

    def wait_note(self, method, timeout=60, start=0, pred=None):
        return self.wait_for(lambda m: m.get("method") == method and "id" not in m
                             and (pred is None or pred(m)), timeout, start)


def dump_types(proc, kinds=("out",)):
    """Return list of compact type descriptors for the event sequence."""
    out = []
    for t, k, o in proc.events:
        if k not in kinds or not isinstance(o, dict):
            continue
        out.append((t, o.get("type") or o.get("method"), o.get("subtype") or o.get("state")))
    return out
