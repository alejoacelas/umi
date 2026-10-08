#!/usr/bin/env python3
"""Self-test for fake_claude.py and fake_codex.py.  Run: python3 test_fakes.py [-v] [name-filter]

Python 3.9, stdlib only. Each test drives a fake through a scripted conversation
and asserts the protocol behaviours that a driver relies on.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE_CLAUDE = os.path.join(HERE, "fake_claude.py")
FAKE_CODEX = os.path.join(HERE, "fake_codex.py")
VERBOSE = "-v" in sys.argv
TMP = tempfile.mkdtemp(prefix="fake-agent-test-")


class Proc(object):
    def __init__(self, argv, env_extra=None, cwd=None):
        env = dict(os.environ)
        env["FAKE_AGENT_DIR"] = TMP
        env["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1"
        for k in ("FAKE_CHAOS", "FAKE_SLOW_START", "FAKE_INPUT_DELAY", "FAKE_MCP", "FAKE_WAKE_TURN_SECS"):
            env.pop(k, None)
        env.update(env_extra or {})
        self.t_spawn = time.time()
        self.p = subprocess.Popen([sys.executable] + argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=env, cwd=cwd or TMP, bufsize=1)
        self.msgs = []
        self.garbage = []          # non-JSON stdout lines (GARBAGE trigger)
        self.blank = 0             # blank stdout lines
        self.partial_reads = 0     # reads that ended mid-line (chaos splits lines)
        self.stderr = []
        self.cv = threading.Condition()
        threading.Thread(target=self._out, daemon=True).start()
        threading.Thread(target=self._err, daemon=True).start()

    def _out(self):
        # raw reads, so partial lines and non-JSON lines are visible
        fd = self.p.stdout.fileno()
        pieces = []
        while True:
            try:
                chunk = os.read(fd, 1 << 20)
            except OSError:
                break
            if not chunk:
                break
            if not chunk.endswith(b"\n"):
                self.partial_reads += 1
            start = 0
            while True:
                i = chunk.find(b"\n", start)
                if i < 0:
                    pieces.append(chunk[start:])
                    break
                pieces.append(chunk[start:i])
                self._line(b"".join(pieces).decode("utf-8", "replace"))
                pieces = []
                start = i + 1

    def _line(self, line):
        if VERBOSE:
            print("   <-", line[:240])
        if not line.strip():
            with self.cv:
                self.blank += 1
            return
        try:
            m = json.loads(line)
        except ValueError:
            with self.cv:
                self.garbage.append(line)
            return
        with self.cv:
            self.msgs.append(m)
            self.cv.notify_all()

    def _err(self):
        for line in self.p.stderr:
            if VERBOSE:
                print("   !!", line.rstrip()[:300])
            with self.cv:
                self.stderr.append(line.rstrip())

    def send(self, obj):
        if VERBOSE:
            print("   ->", json.dumps(obj)[:240])
        self.p.stdin.write((obj if isinstance(obj, str) else json.dumps(obj)) + "\n")
        self.p.stdin.flush()

    def wait_for(self, pred, timeout=10, start=0, what="message"):
        end = time.time() + timeout
        with self.cv:
            while True:
                for i in range(start, len(self.msgs)):
                    if pred(self.msgs[i]):
                        return i, self.msgs[i]
                if time.time() > end:
                    raise AssertionError("timed out waiting for %s; got tail %s" % (
                        what, json.dumps(self.msgs[-6:])[:1500]))
                self.cv.wait(0.05)

    def n(self):
        with self.cv:
            return len(self.msgs)

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass

    def exit_code(self, timeout=10):
        return self.p.wait(timeout=timeout)

    def alive(self):
        return self.p.poll() is None

    def kill(self):
        try:
            self.p.kill()
        except Exception:
            pass
        self.p.wait(5)


def receipts():
    try:
        return [json.loads(l) for l in open(os.path.join(TMP, "receipts.jsonl"))]
    except IOError:
        return []


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    # a zombie still answers kill(0); ask ps for its state
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], stdout=subprocess.PIPE, text=True).stdout.strip()
    return bool(out) and not out.startswith("Z")


def wait_dead(pid, timeout=3):
    end = time.time() + timeout
    while time.time() < end:
        if not pid_alive(pid):
            return True
        time.sleep(0.05)
    return False


def wait_file(path, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = open(path).read().strip()
            if s:
                return s
        except IOError:
            pass
        time.sleep(0.02)
    raise AssertionError("no file " + path)


# ============================================================ Claude helpers

class FC(Proc):
    def __init__(self, *flags, **kw):
        Proc.__init__(self, [FAKE_CLAUDE, "-p", "--input-format", "stream-json", "--output-format",
                             "stream-json", "--verbose", "--replay-user-messages", "--permission-prompt-tool",
                             "stdio", "--model", "haiku", "--some-unknown-flag"] + list(flags), kw.get("env"),
                      kw.get("cwd"))

    def init(self):
        self.send({"type": "control_request", "request_id": "init1",
                   "request": {"subtype": "initialize", "hooks": None}})
        return self.wait_for(lambda m: m.get("type") == "control_response"
                             and m["response"]["request_id"] == "init1", what="init response")[1]

    def user(self, text, uid=None):
        uid = uid or str(uuid.uuid4())
        self.send({"type": "user", "message": {"role": "user", "content": text}, "parent_tool_use_id": None,
                   "session_id": "default", "uuid": uid})
        return uid

    def result(self, start=0):
        return self.wait_for(lambda m: m.get("type") == "result", start=start, what="result")

    def lifecycle(self, uid, state, start=0):
        return self.wait_for(lambda m: m.get("type") == "command_lifecycle" and m["command_uuid"] == uid
                             and m["state"] == state, start=start, what="lifecycle %s %s" % (uid, state))

    def state(self, st, start=0):
        return self.wait_for(lambda m: m.get("subtype") == "session_state_changed" and m["state"] == st,
                             start=start, what="state " + st)

    def tool_use(self, start=0):
        return self.wait_for(lambda m: m.get("type") == "assistant"
                             and m["message"]["content"][0]["type"] == "tool_use", start=start, what="tool_use")

    def perm_request(self, start=0):
        return self.wait_for(lambda m: m.get("type") == "control_request"
                             and m["request"]["subtype"] == "can_use_tool", start=start, what="can_use_tool")

    def answer(self, req, allow, message="no"):
        r = {"behavior": "allow", "updatedInput": req["request"]["input"]} if allow else \
            {"behavior": "deny", "message": message}
        self.send({"type": "control_response",
                   "response": {"subtype": "success", "request_id": req["request_id"], "response": r}})

    def interrupt(self, rid="int1"):
        self.send({"type": "control_request", "request_id": rid, "request": {"subtype": "interrupt"}})
        return self.wait_for(lambda m: m.get("type") == "control_response"
                             and m["response"]["request_id"] == rid, what="interrupt response")

    def types(self, start=0, end=None):
        out = []
        for m in self.msgs[start:end]:
            t = m.get("type")
            if t == "command_lifecycle":
                out.append("lifecycle:%s" % m["state"])
            elif t == "system":
                out.append("system:%s" % (m["state"] if m["subtype"] == "session_state_changed" else m["subtype"]))
            else:
                out.append(t)
        return out


def text_of(assistant_msg):
    return "".join(b.get("text", "") for b in assistant_msg["message"]["content"] if b["type"] == "text")


def t_claude_basic():
    c = FC()
    init = c.init()
    assert init["response"]["subtype"] == "success"
    assert init["response"]["response"]["session_state"] == "idle"
    n = c.n()
    u = c.user("hello there")
    i, r = c.result(n)
    assert r["subtype"] == "success" and r["is_error"] is False and r["result"] == "ok: hello there", r
    assert r["user_message_uuid"] == u and r["user_message_uuids"] == [u]
    c.state("idle", i)
    seq = c.types(n)
    assert seq == ["system:running", "lifecycle:queued", "lifecycle:started", "system:init", "user", "assistant",
                   "result", "lifecycle:completed", "system:idle"], seq
    replay = [m for m in c.msgs[n:] if m.get("type") == "user"][0]
    assert replay["isReplay"] is True and replay["uuid"] == u
    sysinit = [m for m in c.msgs[n:] if m.get("subtype") == "init"][0]
    assert sysinit["model"] == "claude-haiku-4-5-20251001" and sysinit["permissionMode"] == "default"
    asst = [m for m in c.msgs[n:] if m.get("type") == "assistant"][0]
    assert asst["user_message_uuid"] == u
    n = c.n()
    c.user("ECHO this exact text")
    i, r = c.result(n)
    assert r["result"] == "ECHO this exact text" and r["result_index"] == 1
    c.state("idle", i)   # the turn's lifecycle `completed` trails its result
    # a user message without uuid: no lifecycle frames
    n = c.n()
    c.send({"type": "user", "message": {"role": "user", "content": "no uuid"}})
    i, r = c.result(n)
    assert "user_message_uuid" not in r
    assert not any(m.get("type") == "command_lifecycle" for m in c.msgs[n:])
    # unknown control subtype -> error response, unknown type ignored
    c.send({"type": "control_request", "request_id": "bad", "request": {"subtype": "nope"}})
    i, m = c.wait_for(lambda m: m.get("type") == "control_response" and m["response"]["request_id"] == "bad")
    assert m["response"]["subtype"] == "error" and "Unsupported control request subtype" in m["response"]["error"]
    c.send({"type": "bogus"})
    c.close()
    assert c.exit_code() == 0


def t_claude_interrupt_sleep():
    c = FC()
    c.init()
    u1 = c.user("please SLEEP 5 then answer")
    c.tool_use()
    t0 = time.time()
    i, resp = c.interrupt()
    assert resp["response"]["response"] == {"still_queued": []}
    i, r = c.result(i)
    assert time.time() - t0 < 2
    assert r["subtype"] == "error_during_execution" and r["is_error"] is True
    assert r["terminal_reason"] == "aborted_tools" and r["user_message_uuids"] == [u1]
    c.lifecycle(u1, "cancelled", i)
    c.state("idle", i)
    assert any(m.get("type") == "user" and isinstance(m["message"]["content"], list)
               and m["message"]["content"][0].get("text") == "[Request interrupted by user for tool use]"
               for m in c.msgs)
    # process stays alive
    n = c.n()
    c.user("after")
    i, r = c.result(n)
    assert r["result"] == "ok: after"
    # interrupt while idle -> plain success
    i, resp = c.interrupt("int2")
    assert resp["response"]["subtype"] == "success"
    c.close()
    assert c.exit_code() == 0


def t_claude_interrupt_keeps_queued():
    c = FC()
    c.init()
    u1 = c.user("SLEEP 5")
    c.tool_use()
    u2 = c.user("queued one")
    c.lifecycle(u2, "queued")
    i, resp = c.interrupt()
    assert resp["response"]["response"]["still_queued"] == [u2], resp
    i, r1 = c.result(i)
    assert r1["is_error"]
    c.lifecycle(u1, "cancelled", i)
    c.lifecycle(u2, "started", i)
    i, r2 = c.result(i + 1)
    assert r2["result"] == "ok: queued one" and r2["user_message_uuid"] == u2
    c.close()
    assert c.exit_code() == 0


def t_claude_injection():
    c = FC()
    c.init()
    u1 = c.user("first SLEEP 1")
    c.tool_use()
    u2 = c.user("second message")
    i_q, _ = c.lifecycle(u2, "queued")
    i, r = c.result()
    assert r["user_message_uuids"] == [u1, u2], r
    assert r["result"] == "ok: first SLEEP 1\nok: second message"
    i_s, _ = c.lifecycle(u2, "started")
    i_c2, _ = c.lifecycle(u2, "completed")
    i_c1, _ = c.lifecycle(u1, "completed")
    assert i_q < i_s < i_c2 < i < i_c1, (i_q, i_s, i_c2, i, i_c1)
    # replay of the injected message right before its `started`
    assert c.msgs[i_s - 1].get("isReplay") and c.msgs[i_s - 1]["uuid"] == u2
    results = [m for m in c.msgs if m.get("type") == "result"]
    assert len(results) == 1
    c.close()
    assert c.exit_code() == 0


def t_claude_permissions():
    c = FC("--permission-mode", "default")
    c.init()
    n = c.n()
    c.user("ASK_PERMISSION please")
    i, req = c.perm_request(n)
    assert c.msgs[i - 1].get("state") == "requires_action"
    r = req["request"]
    assert r["tool_name"] == "Bash" and r["tool_use_id"] and "input" in r and "permission_suggestions" in r
    c.answer(req, True)
    c.wait_for(lambda m: m.get("type") == "control_response" and m["response"]["request_id"] == req["request_id"],
               what="echoed control_response")
    i, res = c.result(n)
    assert res["result"] == "permission allowed" and res["permission_denials"] == []
    n = c.n()
    c.user("ASK_PERMISSION again")
    i, req = c.perm_request(n)
    c.answer(req, False, "nope")
    i, res = c.result(n)
    assert res["result"] == "permission denied: nope" and len(res["permission_denials"]) == 1
    # interrupt while the permission is pending -> control_cancel_request
    n = c.n()
    c.user("ASK_PERMISSION third")
    i, req = c.perm_request(n)
    c.interrupt("int3")
    c.wait_for(lambda m: m.get("type") == "control_cancel_request" and m["request_id"] == req["request_id"],
               what="control_cancel_request")
    i, res = c.result(n)
    assert res["is_error"] and res["subtype"] == "error_during_execution"
    c.answer(req, True)  # late answer is ignored silently
    time.sleep(0.3)
    assert not any(m.get("type") == "control_response" and m["response"]["request_id"] == req["request_id"]
                   for m in c.msgs[i:])
    c.close()
    assert c.exit_code() == 1  # last result was an error -> exit 1 (like the real CLI)


def t_claude_skip_permissions():
    c = FC("--dangerously-skip-permissions")
    c.init()
    c.user("ASK_PERMISSION")
    i, r = c.result()
    assert r["result"] == "permission allowed"
    assert not any(m.get("type") == "control_request" for m in c.msgs)
    assert [m for m in c.msgs if m.get("subtype") == "init"][0]["permissionMode"] == "bypassPermissions"
    c.close()
    assert c.exit_code() == 0


def t_claude_resume():
    sid = str(uuid.uuid4())
    c = FC("--session-id", sid)
    c.init()
    c.user("remember PAPAYA")
    c.result()
    c.close()
    assert c.exit_code() == 0
    c = FC("--resume", sid)
    c.init()
    time.sleep(0.2)
    assert not any(m.get("type") in ("user", "assistant") for m in c.msgs)  # no history replay
    c.user("RECALL")
    i, r = c.result()
    assert r["result"] == "history: remember PAPAYA", r
    assert r["session_id"] == sid
    c.close()
    assert c.exit_code() == 0
    # --session-id together with --resume needs --fork-session
    c = FC("--resume", sid, "--session-id", str(uuid.uuid4()))
    assert c.exit_code() == 1
    time.sleep(0.1)
    assert any("--fork-session" in l for l in c.stderr), c.stderr
    new = str(uuid.uuid4())
    c = FC("--resume", sid, "--fork-session", "--session-id", new)
    c.init()
    c.user("RECALL")
    i, r = c.result()
    assert r["session_id"] == new and "PAPAYA" in r["result"]
    c.close()
    assert c.exit_code() == 0
    # reusing an existing --session-id
    c = FC("--session-id", sid)
    assert c.exit_code() == 1
    # unknown session id -> result error on stdout, exit 1
    bad = str(uuid.uuid4())
    c = FC("--resume", bad)
    i, r = c.result()
    assert r["is_error"] and r["errors"] == ["No conversation found with session ID: %s" % bad]
    assert c.exit_code() == 1


def t_claude_crash_and_malformed():
    c = FC()
    c.init()
    c.user("please CRASH now")
    assert c.exit_code() == 1
    c = FC()
    c.init()
    c.send("this is not json")
    assert c.exit_code() == 1
    time.sleep(0.1)
    assert any("Error parsing streaming input line" in l for l in c.stderr)


def t_claude_stdin_close_mid_turn():
    c = FC()
    c.init()
    c.user("SLEEP 1")
    c.tool_use()
    c.close()  # the turn still finishes, then the process exits 0
    i, r = c.result()
    assert r["subtype"] == "success"
    assert c.exit_code() == 0
    # pending permission + stdin close -> permission auto-fails, turn completes
    c = FC()
    c.init()
    c.user("ASK_PERMISSION")
    c.perm_request()
    c.close()
    i, r = c.result()
    assert "stream closed" in r["result"]
    assert c.exit_code() == 0


# ============================================================ Codex helpers

class FX(Proc):
    def __init__(self, env=None, args=()):
        Proc.__init__(self, [FAKE_CODEX, "app-server", "--listen", "stdio://"] + list(args), env)
        self.nid = 0

    def req(self, method, params=None):
        self.nid += 1
        self.send({"id": self.nid, "method": method, "params": params or {}})
        return self.nid

    def call(self, method, params=None):
        rid = self.req(method, params)
        return self.wait_for(lambda m: m.get("id") == rid and "method" not in m, what="response " + method)[1]

    def init(self):
        r = self.call("initialize", {"clientInfo": {"name": "t", "title": None, "version": "0"},
                                     "capabilities": {"experimentalApi": True}})
        self.send({"method": "initialized"})
        return r

    def thread(self, **kw):
        p = {"model": "gpt-6-luna", "cwd": TMP, "approvalPolicy": "never", "sandbox": "workspace-write"}
        p.update(kw)
        return self.call("thread/start", p)["result"]["thread"]["id"]

    def turn(self, tid, text, cmid=None):
        cmid = cmid or str(uuid.uuid4())
        r = self.call("turn/start", {"threadId": tid, "clientUserMessageId": cmid,
                                     "input": [{"type": "text", "text": text, "text_elements": []}]})
        return r, cmid

    def note(self, method, start=0, pred=None, timeout=10):
        return self.wait_for(lambda m: m.get("method") == method and "id" not in m and (pred is None or pred(m)),
                             start=start, timeout=timeout, what=method)

    def completed(self, start=0, timeout=10):
        return self.note("turn/completed", start, timeout=timeout)

    def server_req(self, start=0):
        return self.wait_for(lambda m: "id" in m and "method" in m, start=start, what="server request")


def item(kind, phase=None):
    return lambda m: m["params"]["item"]["type"] == kind and (phase is None or m["params"]["item"].get("phase") == phase)


def t_codex_basic():
    x = FX()
    assert x.call("thread/start", {})["error"]["message"] == "Not initialized"
    r = x.init()
    assert "userAgent" in r["result"]
    tid = x.thread()
    x.note("thread/started")
    n = x.n()
    r, cmid = x.turn(tid, "hi")
    turn_id = r["result"]["turn"]["id"]
    assert r["result"]["turn"]["status"] == "inProgress"
    i, done = x.completed(n)
    t = done["params"]["turn"]
    assert t["id"] == turn_id and t["status"] == "completed" and t["itemsView"] == "summary"
    assert t["items"][0]["type"] == "agentMessage" and t["items"][0]["text"] == "ok: hi"
    assert t["items"][0]["phase"] == "final_answer"
    methods = [m.get("method") for m in x.msgs[n:] if "method" in m]
    assert methods == ["thread/status/changed", "turn/started", "item/started", "item/completed", "item/started",
                       "item/agentMessage/delta", "item/completed", "thread/status/changed", "turn/completed"], methods
    ui = [m for m in x.msgs[n:] if m.get("method") == "item/completed" and m["params"]["item"]["type"] == "userMessage"]
    assert ui[0]["params"]["item"]["clientId"] == cmid
    assert x.msgs[n:][-2]["params"]["status"] == {"type": "idle"}
    resp = x.msgs[n]  # the turn/start response precedes the notifications
    assert resp.get("id") is not None and "result" in resp, resp
    assert x.call("turn/interrupt", {"threadId": tid, "turnId": turn_id})["error"]["message"] == \
        "no active turn to interrupt"
    assert "unknown variant" in x.call("no/such", {})["error"]["message"]
    x.send("not json")  # logged, not fatal
    assert x.call("thread/turns/list", {"threadId": tid})["result"]["data"][0]["id"] == turn_id
    x.close()
    assert x.exit_code() == 0


def t_codex_steer_and_commentary():
    x = FX()
    x.init()
    tid = x.thread()
    n = x.n()
    r1, c1 = x.turn(tid, "first SLEEP 1")
    x.note("item/started", n, item("commandExecution"))
    r2, c2 = x.turn(tid, "second")
    assert r2["result"]["turn"]["id"] == r1["result"]["turn"]["id"]  # steered into the active turn
    i, done = x.completed(n)
    assert done["params"]["turn"]["items"][0]["text"] == "ok: first SLEEP 1\nok: second"
    i_cmd, _ = x.note("item/completed", n, item("commandExecution"))
    i_u2, u2 = x.note("item/completed", n, lambda m: m["params"]["item"].get("clientId") == c2)
    assert i_cmd < i_u2 < i
    x.note("item/completed", n, item("agentMessage", "commentary"))
    assert len([m for m in x.msgs[n:] if m.get("method") == "turn/completed"]) == 1
    # turn/steer: precondition errors
    e = x.call("turn/steer", {"threadId": tid, "expectedTurnId": "x", "input": []})["error"]["message"]
    assert e == "no active turn to steer"
    x.close()
    assert x.exit_code() == 0


def t_codex_interrupt():
    x = FX()
    x.init()
    tid = x.thread()
    n = x.n()
    r, _ = x.turn(tid, "SLEEP 10")
    turn_id = r["result"]["turn"]["id"]
    x.note("item/started", n, item("commandExecution"))
    t0 = time.time()
    resp = x.call("turn/interrupt", {"threadId": tid, "turnId": turn_id})
    assert resp["result"] == {}
    i, done = x.completed(n)
    assert time.time() - t0 < 2
    assert done["params"]["turn"]["status"] == "interrupted" and done["params"]["turn"]["items"] == []
    assert x.msgs[i - 1]["params"]["status"] == {"type": "idle"}
    n = x.n()
    x.turn(tid, "again")
    i, done = x.completed(n)
    assert done["params"]["turn"]["status"] == "completed"
    x.close()
    assert x.exit_code() == 0


def t_codex_approvals():
    x = FX()
    x.init()
    tid = x.thread(approvalPolicy="untrusted", sandbox="read-only")
    for decision, expect, status in (("accept", "approval accepted", "completed"),
                                     ("decline", "approval declined", "declined")):
        n = x.n()
        x.turn(tid, "ASK_APPROVAL")
        i, req = x.server_req(n)
        assert req["method"] == "item/commandExecution/requestApproval"
        p = req["params"]
        for k in ("threadId", "turnId", "itemId", "command", "cwd", "availableDecisions", "kind"):
            assert k in p, k
        x.note("thread/status/changed", n, lambda m: m["params"]["status"].get("activeFlags") == ["waitingOnApproval"])
        x.send({"id": req["id"], "result": {"decision": decision}})
        x.note("serverRequest/resolved", i, lambda m: m["params"]["requestId"] == req["id"])
        x.note("item/completed", i, lambda m: m["params"]["item"]["type"] == "commandExecution"
               and m["params"]["item"]["status"] == status)
        j, done = x.completed(n)
        assert done["params"]["turn"]["items"][0]["text"] == expect
    # interrupt with a pending approval: turn/completed(interrupted) then serverRequest/resolved
    n = x.n()
    r, _ = x.turn(tid, "ASK_APPROVAL")
    i, req = x.server_req(n)
    x.call("turn/interrupt", {"threadId": tid, "turnId": r["result"]["turn"]["id"]})
    i_done, done = x.completed(n)
    i_res, _ = x.note("serverRequest/resolved", n, lambda m: m["params"]["requestId"] == req["id"])
    assert done["params"]["turn"]["status"] == "interrupted" and i_done < i_res
    x.send({"id": req["id"], "result": {"decision": "accept"}})  # late answer ignored
    # cancel -> interrupted turn
    n = x.n()
    x.turn(tid, "ASK_APPROVAL")
    i, req = x.server_req(n)
    x.send({"id": req["id"], "result": {"decision": "cancel"}})
    i, done = x.completed(n)
    assert done["params"]["turn"]["status"] == "interrupted"
    x.close()
    assert x.exit_code() == 0


def t_codex_resume_and_lock():
    a = FX()
    a.init()
    tid = a.thread()
    a.turn(tid, "remember MANGO")
    a.completed()
    b = FX()
    b.init()
    e = b.call("thread/resume", {"threadId": tid})["error"]["message"]
    assert e == "thread %s already has an active writer" % tid, e
    assert b.call("turn/start", {"threadId": tid, "input": []})["error"]["message"] == "thread not found: %s" % tid
    a.close()
    assert a.exit_code() == 0
    r = b.call("thread/resume", {"threadId": tid})
    assert r["result"]["thread"]["id"] == tid and len(r["result"]["thread"]["turns"]) == 1
    n = b.n()
    b.turn(tid, "RECALL")
    i, done = b.completed(n)
    assert done["params"]["turn"]["items"][0]["text"] == "history: remember MANGO"
    bad = str(uuid.uuid4())
    assert b.call("thread/resume", {"threadId": bad})["error"]["message"] == "no rollout found for thread id " + bad
    assert b.call("thread/resume", {"threadId": "nope"})["error"]["message"].startswith("invalid session id")
    b.close()
    assert b.exit_code() == 0


def t_codex_eof_crash_fail_queue():
    x = FX()
    x.init()
    tid = x.thread()
    x.turn(tid, "SLEEP 20")
    x.note("item/started", 0, item("commandExecution"))
    t0 = time.time()
    x.close()
    assert x.exit_code() == 0 and time.time() - t0 < 2  # exits promptly, turn abandoned
    x = FX()
    x.init()
    tid = x.thread()
    x.turn(tid, "CRASH")
    assert x.exit_code() == 1
    # a crashed owner leaves a stale lock; resume must still work
    y = FX()
    y.init()
    assert "result" in y.call("thread/resume", {"threadId": tid})
    # model failure
    tid2 = y.thread(model="no-such-model-xyz")
    n = y.n()
    y.turn(tid2, "hi")
    i, done = y.completed(n)
    assert done["params"]["turn"]["status"] == "failed" and done["params"]["turn"]["error"]["message"]
    y.note("error", n)
    y.note("thread/status/changed", n, lambda m: m["params"]["status"]["type"] == "systemError")
    # experimental queue: add while active -> auto-started after the active turn
    tid3 = y.thread()
    n = y.n()
    y.turn(tid3, "SLEEP 1")
    q = y.call("thread/queue/add", {"threadId": tid3, "clientUserMessageId": "q1",
                                    "input": [{"type": "text", "text": "queued", "text_elements": []}]})
    assert q["result"]["queuedSubmission"]["clientUserMessageId"] == "q1"
    assert len(y.call("thread/queue/list", {"threadId": tid3})["result"]["data"]) == 1
    i1, d1 = y.completed(n)
    i2, d2 = y.completed(i1 + 1)
    assert d2["params"]["turn"]["items"][0]["text"] == "ok: queued"
    assert y.call("thread/queue/start", {"threadId": tid3})["error"]["message"] == "queue is empty"
    y.close()
    assert y.exit_code() == 0



# ============================================================ helpers for the new modes

def claude_say(c, text, uid=None):
    """Send one message, wait for the result that covers it and the following idle; return the result."""
    n = c.n()
    u = c.user(text, uid)
    i, r = c.wait_for(lambda m: m.get("type") == "result" and u in m.get("user_message_uuids", []), start=n,
                      what="result for " + text)
    c.state("idle", i)
    return r


def codex_say(x, tid, text, timeout=10):
    """Start a turn, wait for its turn/completed; return (turn payload, clientUserMessageId)."""
    n = x.n()
    r, cmid = x.turn(tid, text)
    T = r["result"]["turn"]["id"]
    i, done = x.note("turn/completed", n, lambda m: m["params"]["turn"]["id"] == T, timeout=timeout)
    return done["params"]["turn"], cmid


def receipts_for(session):
    return [r for r in receipts() if r["session"] == session]


def self_turns_for(session):
    try:
        recs = [json.loads(l) for l in open(os.path.join(TMP, "self_turns.jsonl"))]
    except IOError:
        return []
    return [r for r in recs if r["session"] == session]


def final_text(turn_payload):
    return turn_payload["items"][0]["text"]


# ============================================================ chaos: legality checks

CHAOS_SEEDS = (1, 2, 3)


def check_claude_sequence(msgs, sent):
    """The frame stream is legal for the user messages `sent` (uuids), whatever chaos did."""
    lc = {}
    for i, m in enumerate(msgs):
        if m.get("type") == "command_lifecycle":
            lc.setdefault(m["command_uuid"], []).append((m["state"], i))
    for u in sent:
        st = [s for s, _ in lc.get(u, [])]
        assert len(st) == 3 and st[:2] == ["queued", "started"] and st[2] in ("completed", "cancelled"), (u, st)
    results = [(i, m) for i, m in enumerate(msgs) if m.get("type") == "result"]
    assert [m["result_index"] for _, m in results] == list(range(len(results)))
    covered = [u for _, r in results for u in r.get("user_message_uuids", [])]
    assert sorted(covered) == sorted(sent), (covered, sent)
    for i, r in results:
        if "origin" in r:   # a turn the harness started by itself (WAKE, C11wake): it covers no message
            assert "user_message_uuid" not in r and "user_message_uuids" not in r, r
            continue
        uu = r["user_message_uuids"]
        assert r["user_message_uuid"] == uu[0]
        if r["is_error"]:
            assert all(lc[u][2][0] == "cancelled" and lc[u][2][1] > i for u in uu)
        else:   # C9: injected messages complete before the shared result, the first one after it
            assert all(lc[u][2][0] == "completed" and lc[u][2][1] < i for u in uu[1:]), r
            assert lc[uu[0]][2][0] == "completed" and lc[uu[0]][2][1] > i
    inits = [i for i, m in enumerate(msgs) if m.get("type") == "system" and m.get("subtype") == "init"]
    assert len(inits) == len(results), (len(inits), len(results))
    prev = -1
    for k, (ri, r) in enumerate(results):
        a = inits[k]
        assert prev < a < ri
        prev = ri
        asst = [m for m in msgs[a:ri] if m.get("type") == "assistant"]
        if "origin" in r:
            assert all("user_message_uuid" not in m for m in asst)
            assert not any(m.get("isReplay") for m in msgs[a:ri]), "a self-started turn replays nothing"
            continue
        assert asst and asst[0].get("user_message_uuid") == r["user_message_uuid"]
        assert all("user_message_uuid" not in m for m in asst[1:])
    assert sorted(m["uuid"] for m in msgs if m.get("isReplay")) == sorted(sent)
    st = [m["state"] for m in msgs if m.get("subtype") == "session_state_changed" and m["state"] in ("running", "idle")]
    assert st and st == ["running", "idle"] * (len(st) // 2), st
    for m in msgs:
        if m.get("type") == "rate_limit_event":
            assert m["rate_limit_info"]["status"] == "allowed"
        if m.get("subtype") == "thinking_tokens":
            assert m["estimated_tokens"] > 0
        if m.get("type") not in ("system", "command_lifecycle", "user", "assistant", "result", "control_response",
                                 "control_request", "control_cancel_request", "rate_limit_event"):
            raise AssertionError("unexpected frame type %r" % m)


def check_codex_sequence(msgs, tid, sent):
    """The notification stream for thread `tid` is legal for clientUserMessageIds `sent` (all delivered)."""
    notes = [(i, m) for i, m in enumerate(msgs) if "method" in m and "id" not in m
             and (m["params"].get("threadId") in (None, tid))]
    started, completed = {}, {}
    for i, m in notes:
        if m["method"] == "turn/started":
            T = m["params"]["turn"]["id"]
            assert T not in started
            started[T] = i
        elif m["method"] == "turn/completed":
            T = m["params"]["turn"]["id"]
            assert T not in completed
            completed[T] = i
    assert set(started) == set(completed)
    order = sorted(started, key=started.get)
    for a, b in zip(order, order[1:]):
        assert completed[a] < started[b], "turns overlap"
    for i, m in notes:
        T = m["params"].get("turnId")
        if T is not None:
            assert started[T] < i < completed[T], ("notification outside its turn", m["method"])
    # turn/start / turn/steer responses: a steer answers inside the open turn; a new turn answers
    # before its turn/started and after every earlier turn's turn/completed (X9)
    for i, m in enumerate(msgs):
        res = m.get("result") if "method" not in m else None
        if not isinstance(res, dict):
            continue
        T = (res.get("turn") or {}).get("id") or res.get("turnId")
        if T is None or T not in started:
            continue
        if started[T] < i:
            assert i < completed[T], "steer answered after the turn completed"
        else:
            assert all(completed[o] < i for o in started if started[o] < i)
    users = [m["params"]["item"]["clientId"] for _, m in notes
             if m["method"] == "item/completed" and m["params"]["item"]["type"] == "userMessage"]
    assert sorted(users) == sorted(sent), (users, sent)
    deltas = {}
    for _, m in notes:
        if m["method"] == "item/agentMessage/delta":
            deltas[m["params"]["itemId"]] = deltas.get(m["params"]["itemId"], "") + m["params"]["delta"]
    finals = {}
    for _, m in notes:
        if m["method"] == "item/completed" and m["params"]["item"]["type"] == "agentMessage":
            it = m["params"]["item"]
            assert deltas.get(it["id"], "") == it["text"], "deltas do not add up"
            if it["phase"] == "final_answer":
                finals[m["params"]["turnId"]] = it
    for _, m in notes:
        if m["method"] == "turn/completed" and m["params"]["turn"]["status"] == "completed":
            t = m["params"]["turn"]
            assert t["items"] == [finals[t["id"]]], "turn/completed must carry the last final answer"
    rec = sorted(r["message"] for r in receipts_for(tid))
    assert rec == sorted(sent), (rec, sent)


def t_claude_chaos_basic():
    partial = noise = 0
    for seed in CHAOS_SEEDS:
        c = FC(env={"FAKE_CHAOS": str(seed)})
        c.init()
        sent = []
        u = c.user("hello chaos %d" % seed)
        sent.append(u)
        c.lifecycle(u, "completed")
        n = c.n()
        u2 = c.user("first SLEEP 0.5")
        sent.append(u2)
        c.tool_use(n)
        u3 = c.user("second")
        sent.append(u3)
        i2, _ = c.lifecycle(u2, "completed")
        i3, _ = c.lifecycle(u3, "completed")
        c.state("idle", max(i2, i3))
        n = c.n()
        u4 = c.user("SLEEP 5")
        sent.append(u4)
        c.tool_use(n)
        u5 = c.user("queued behind")
        sent.append(u5)
        c.lifecycle(u5, "queued")
        i, resp = c.interrupt()
        assert resp["response"]["response"]["still_queued"] == [u5]
        c.lifecycle(u4, "cancelled")
        c.lifecycle(u5, "completed")
        c.close()
        assert c.exit_code() == 0
        check_claude_sequence(c.msgs, sent)
        sid = [m for m in c.msgs if m.get("type") == "result"][0]["session_id"]
        assert sorted(r["message"] for r in receipts_for(sid)) == sorted(sent)
        partial += c.partial_reads
        noise += len([m for m in c.msgs if m.get("type") == "rate_limit_event" or m.get("subtype") == "thinking_tokens"
                      or (m.get("type") == "assistant" and m["message"]["content"][0]["type"] == "thinking")])
    assert partial > 0, "chaos never split a line"
    assert noise > 0, "chaos never added noise frames"


def t_claude_chaos_injection_choice():
    # a message sent during a tool is injected at the boundary or run as the next turn; both happen
    c = FC(env={"FAKE_CHAOS": "5"})
    c.init()
    sent, seen = [], set()
    for k in range(30):
        n = c.n()
        u1 = c.user("SLEEP 0.2 k%d" % k)
        c.tool_use(n)
        u2 = c.user("follow k%d" % k)
        sent += [u1, u2]
        i1, _ = c.lifecycle(u1, "completed", n)
        i2, _ = c.lifecycle(u2, "completed", n)
        c.state("idle", max(i1, i2))
        seen.add(any(m.get("type") == "result" and m.get("user_message_uuids") == [u1, u2] for m in c.msgs[n:]))
        if len(seen) == 2:
            break
    assert seen == {True, False}, seen
    c.close()
    assert c.exit_code() == 0
    check_claude_sequence(c.msgs, sent)


def t_codex_chaos_basic():
    partial = 0
    for seed in CHAOS_SEEDS:
        x = FX(env={"FAKE_CHAOS": str(seed)})
        x.init()
        tid = x.thread()
        sent = []
        t, c1 = codex_say(x, tid, "hello chaos %d" % seed)
        sent.append(c1)
        assert final_text(t) == "ok: hello chaos %d" % seed
        n = x.n()
        r2, c2 = x.turn(tid, "first SLEEP 0.5")
        T2 = r2["result"]["turn"]["id"]
        x.note("item/started", n, item("commandExecution"))
        r3, c3 = x.turn(tid, "steered")
        sent += [c2, c3]
        assert r3["result"]["turn"]["id"] == T2
        x.note("turn/completed", n, lambda m: m["params"]["turn"]["id"] == T2)
        n = x.n()
        r4, c4 = x.turn(tid, "SLEEP 5")
        sent.append(c4)
        T4 = r4["result"]["turn"]["id"]
        x.note("item/started", n, item("commandExecution"))
        assert x.call("turn/interrupt", {"threadId": tid, "turnId": T4})["result"] == {}
        i, done = x.note("turn/completed", n, lambda m: m["params"]["turn"]["id"] == T4)
        assert done["params"]["turn"]["status"] == "interrupted"
        assert not any(m.get("method") == "item/completed" and m["params"]["item"]["type"] == "commandExecution"
                       for m in x.msgs[n:]), "interrupted command must not complete"
        n = x.n()
        c5 = str(uuid.uuid4())
        x.call("thread/queue/add", {"threadId": tid, "clientUserMessageId": c5,
                                    "input": [{"type": "text", "text": "from the queue", "text_elements": []}]})
        sent.append(c5)
        i, um = x.note("item/completed", n, lambda m: m["params"]["item"].get("clientId") == c5)
        x.note("turn/completed", i, lambda m: m["params"]["turn"]["id"] == um["params"]["turnId"])
        x.close()
        assert x.exit_code() == 0
        check_codex_sequence(x.msgs, tid, sent)
        partial += x.partial_reads
    assert partial > 0, "chaos never split a line"


def t_codex_chaos_steer_race():
    # turn/start or turn/steer right after the final answer: joins the turn or waits for it (X4/X9)
    x = FX(env={"FAKE_CHAOS": "7"})
    x.init()
    tid = x.thread()
    sent, seen = [], set()
    for k in range(60):
        n = x.n()
        r, ca = x.turn(tid, "race a%d" % k)
        sent.append(ca)
        T = r["result"]["turn"]["id"]
        x.note("item/completed", n, lambda m: m["params"]["turnId"] == T and m["params"]["item"]["type"] == "agentMessage"
               and m["params"]["item"]["phase"] == "final_answer")
        steer = k % 2 == 1
        if steer:
            cb = str(uuid.uuid4())
            rid = x.req("turn/steer", {"threadId": tid, "expectedTurnId": T, "clientUserMessageId": cb,
                                       "input": [{"type": "text", "text": "race b%d" % k, "text_elements": []}]})
            i_r, resp = x.wait_for(lambda m: m.get("id") == rid and "method" not in m)
            joined = "result" in resp
            if joined:
                sent.append(cb)
            else:
                assert resp["error"]["message"] == "no active turn to steer", resp
        else:
            rid = x.req("turn/start", {"threadId": tid, "clientUserMessageId": str(uuid.uuid4()),
                                       "input": [{"type": "text", "text": "race b%d" % k, "text_elements": []}]})
            i_r, resp = x.wait_for(lambda m: m.get("id") == rid and "method" not in m)
            joined = resp["result"]["turn"]["id"] == T
        i_c, done = x.note("turn/completed", n, lambda m: m["params"]["turn"]["id"] == T)
        if not joined:
            assert i_c < i_r, "the late input is answered after turn/completed"
        finals = [m for m in x.msgs[n:i_c] if m.get("method") == "item/completed"
                  and m["params"]["item"]["type"] == "agentMessage" and m["params"]["item"]["phase"] == "final_answer"]
        assert len(finals) == (2 if joined else 1)
        if not steer and not joined:
            T2 = resp["result"]["turn"]["id"]
            x.note("turn/completed", i_c, lambda m: m["params"]["turn"]["id"] == T2)
        seen.add((steer, joined))
        if len(seen) == 4:
            break
    assert seen == {(False, False), (False, True), (True, False), (True, True)}, seen
    x.close()
    assert x.exit_code() == 0
    # every turn/start input was delivered exactly once
    users = [m["params"]["item"]["clientId"] for m in x.msgs if m.get("method") == "item/completed"
             and m["params"]["item"]["type"] == "userMessage"]
    assert len(users) == len(set(users))
    check_codex_sequence(x.msgs, tid, users)


def t_codex_early_interrupt():
    # interrupt after the turn/start answer but before the userMessage item: input never delivered
    x = FX(env={"FAKE_INPUT_DELAY": "1"})
    x.init()
    tid = x.thread()
    n = x.n()
    r, cm = x.turn(tid, "never delivered")
    T = r["result"]["turn"]["id"]
    x.note("turn/started", n)
    assert x.call("turn/interrupt", {"threadId": tid, "turnId": T})["result"] == {}
    i, done = x.completed(n)
    assert done["params"]["turn"]["status"] == "interrupted" and done["params"]["turn"]["items"] == []
    assert not any(m.get("method", "").startswith("item/") for m in x.msgs[n:]), "no items at all"
    assert not any(r["message"] == cm for r in receipts())
    t, cm2 = codex_say(x, tid, "after")
    assert final_text(t) == "ok: after"
    assert [r["message"] for r in receipts_for(tid)] == [cm2]
    x.close()
    assert x.exit_code() == 0


# ============================================================ receipts

def t_receipts_exactly_once():
    c = FC()
    c.init()
    r1 = claude_say(c, "one")
    sid = r1["session_id"]
    n = c.n()
    u2 = c.user("two SLEEP 0.3")
    c.tool_use(n)
    u3 = c.user("three")
    i, r = c.result(n)
    assert r["user_message_uuids"] == [u2, u3]
    c.state("idle", i)
    n = c.n()
    c.send({"type": "user", "message": {"role": "user", "content": "four"}})
    c.result(n)
    c.close()
    assert c.exit_code() == 0
    rec = receipts_for(sid)
    assert [(x["message"], x["text"], x["turn"]) for x in rec] == [
        (r1["user_message_uuid"], "one", 0), (u2, "two SLEEP 0.3", 1), (u3, "three", 1), (None, "four", 2)], rec
    assert all(x["harness"] == "claude" and x["pid"] == c.p.pid for x in rec)
    # resumed in a new process: same session, new pid
    c = FC("--resume", sid)
    c.init()
    claude_say(c, "five")
    c.close()
    assert c.exit_code() == 0
    rec = receipts_for(sid)
    assert len(rec) == 5 and rec[-1]["text"] == "five" and rec[-1]["pid"] == c.p.pid

    x = FX()
    x.init()
    tid = x.thread()
    t1, c1 = codex_say(x, tid, "one")
    n = x.n()
    r2, c2 = x.turn(tid, "two SLEEP 0.3")
    x.note("item/started", n, item("commandExecution"))
    r3, c3 = x.turn(tid, "three")
    x.completed(n)
    rec = receipts_for(tid)
    assert [(r["message"], r["text"]) for r in rec] == [(c1, "one"), (c2, "two SLEEP 0.3"), (c3, "three")]
    assert rec[1]["turn"] == rec[2]["turn"] == r2["result"]["turn"]["id"] and rec[0]["turn"] == t1["id"]
    assert all(r["harness"] == "codex" and r["pid"] == x.p.pid for r in rec)
    x.close()
    assert x.exit_code() == 0


# ============================================================ STATE / FAIL

def t_state():
    c = FC("--effort", "high", "--permission-mode", "acceptEdits")
    c.init()
    r = claude_say(c, "STATE")
    assert "\n" not in r["result"]
    s = json.loads(r["result"])
    assert s == {"harness": "claude", "session": r["session_id"], "model": "haiku", "effort": "high",
                 "full_access": False, "permission_mode": "acceptEdits", "cwd": os.path.realpath(TMP),
                 "argv": c.p.args[2:]}, s
    c.send({"type": "control_request", "request_id": "sm", "request": {"subtype": "set_model", "model": "sonnet"}})
    c.wait_for(lambda m: m.get("type") == "control_response" and m["response"]["request_id"] == "sm")
    assert json.loads(claude_say(c, "STATE")["result"])["model"] == "sonnet"
    c.close()
    assert c.exit_code() == 0
    c = FC("--dangerously-skip-permissions")
    c.init()
    s = json.loads(claude_say(c, "STATE")["result"])
    assert s["full_access"] is True and s["permission_mode"] == "bypassPermissions" and s["effort"] is None
    c.close()
    assert c.exit_code() == 0

    x = FX(args=["-c", 'model="cfg-model"', "-c", "model_reasoning_effort=medium"])
    x.init()
    tid = x.thread(model="gpt-x", approvalPolicy="never", sandbox="danger-full-access",
                   config={"model_reasoning_effort": "high"})
    t, _ = codex_say(x, tid, "STATE")
    s = json.loads(final_text(t))
    assert s == {"harness": "codex", "session": tid, "model": "gpt-x", "effort": "high", "full_access": True,
                 "permission_mode": "never", "cwd": TMP, "argv": x.p.args[2:]}, s
    n = x.n()
    x.call("turn/start", {"threadId": tid, "clientUserMessageId": "s2", "model": "gpt-y", "effort": "low",
                          "input": [{"type": "text", "text": "STATE", "text_elements": []}]})
    i, done = x.completed(n)
    s = json.loads(final_text(done["params"]["turn"]))
    assert s["model"] == "gpt-y" and s["effort"] == "low"
    p = {"cwd": TMP, "approvalPolicy": "never", "sandbox": "workspace-write"}
    tid2 = x.call("thread/start", p)["result"]["thread"]["id"]
    s = json.loads(final_text(codex_say(x, tid2, "STATE")[0]))
    assert s["model"] == "cfg-model" and s["effort"] == "medium" and s["full_access"] is False, s
    x.close()
    assert x.exit_code() == 0


def t_fail():
    c = FC()
    c.init()
    r = claude_say(c, "please FAIL")
    assert r["is_error"] is True and r["subtype"] == "success" and r["api_error_status"] == 404, r
    assert r["result"].startswith("API Error: 404")
    assert claude_say(c, "next")["result"] == "ok: next"
    c.close()
    assert c.exit_code() == 0
    c = FC("--model", "no-such-model-xyz")
    c.init()
    r = claude_say(c, "hi")
    assert r["is_error"] and "no-such-model-xyz" in r["result"]
    c.close()
    assert c.exit_code() == 1   # the last result was an error
    x = FX()
    x.init()
    tid = x.thread()
    n = x.n()
    t, _ = codex_say(x, tid, "please FAIL")
    assert t["status"] == "failed" and t["error"]["message"]
    x.note("error", n)
    t, _ = codex_say(x, tid, "next")
    assert t["status"] == "completed"
    x.close()
    assert x.exit_code() == 0


# ============================================================ hostile triggers

def t_hostile_garbage():
    c = FC()
    c.init()
    r = claude_say(c, "GARBAGE please")
    assert r["result"] == "ok: GARBAGE please"
    time.sleep(0.2)
    assert "this is not json" in c.garbage and len(c.garbage) == 8 and c.blank == 4, (c.garbage, c.blank)
    c.close()
    assert c.exit_code() == 0
    x = FX()
    x.init()
    tid = x.thread()
    t, _ = codex_say(x, tid, "GARBAGE please")
    assert final_text(t) == "ok: GARBAGE please"
    time.sleep(0.2)
    assert len(x.garbage) == 8 and x.blank == 4, (x.garbage, x.blank)
    x.close()
    assert x.exit_code() == 0


def t_hostile_huge():
    size = 3 * 1024 * 1024
    c = FC()
    c.init()
    r = claude_say(c, "HUGE 3")
    assert r["result"] == "huge: 3 MB"
    tr = [m for m in c.msgs if m.get("type") == "user" and isinstance(m["message"]["content"], list)
          and m["message"]["content"][0].get("type") == "tool_result"][0]
    assert len(tr["message"]["content"][0]["content"]) >= size - 1
    c.close()
    assert c.exit_code() == 0
    x = FX()
    x.init()
    tid = x.thread()
    t, _ = codex_say(x, tid, "HUGE 3")
    assert final_text(t) == "huge: 3 MB"
    done = [m for m in x.msgs if m.get("method") == "item/completed" and m["params"]["item"]["type"] == "commandExecution"]
    assert len(done[0]["params"]["item"]["aggregatedOutput"]) == size
    x.close()
    assert x.exit_code() == 0


def t_hostile_stderr_spam():
    for proc in (FC(), FX()):
        proc.init()
        if isinstance(proc, FC):
            assert claude_say(proc, "STDERR_SPAM")["result"] == "ok: STDERR_SPAM"
        else:
            assert final_text(codex_say(proc, proc.thread(), "STDERR_SPAM")[0]) == "ok: STDERR_SPAM"
        end = time.time() + 5
        while len(proc.stderr) < 20000 and time.time() < end:
            time.sleep(0.05)
        assert len(proc.stderr) >= 20000, len(proc.stderr)
        proc.close()
        assert proc.exit_code() == 0


def t_hostile_hang():
    c = FC()
    c.init()
    n = c.n()
    u = c.user("HANG now")
    c.wait_for(lambda m: m.get("isReplay") and m["uuid"] == u, start=n)
    time.sleep(0.2)
    k = c.n()
    c.send({"type": "control_request", "request_id": "int1", "request": {"subtype": "interrupt"}})
    c.user("anyone there?")
    c.send("not json either")      # would be fatal to a live CLI; a hung one ignores it
    time.sleep(0.5)
    assert c.n() == k and c.alive()
    c.close()
    time.sleep(0.5)
    assert c.alive(), "a hung process does not exit on EOF"
    assert [r["message"] for r in receipts() if r["text"] == "HANG now"] == [u]
    c.kill()
    x = FX()
    x.init()
    tid = x.thread()
    n = x.n()
    r, cm = x.turn(tid, "HANG now")
    x.note("item/completed", n, lambda m: m["params"]["item"].get("clientId") == cm)
    time.sleep(0.2)
    k = x.n()
    x.req("turn/interrupt", {"threadId": tid, "turnId": r["result"]["turn"]["id"]})
    time.sleep(0.5)
    assert x.n() == k and x.alive()
    x.close()
    time.sleep(0.5)
    assert x.alive()
    x.kill()


def t_hostile_exit_clean():
    c = FC()
    c.init()
    claude_say(c, "EXIT_CLEAN bye")
    assert c.exit_code(5) == 0       # stdin still open
    x = FX()
    x.init()
    tid = x.thread()
    t, _ = codex_say(x, tid, "EXIT_CLEAN bye")
    assert final_text(t) == "ok: EXIT_CLEAN bye"
    assert x.exit_code(5) == 0
    assert not os.path.exists(os.path.join(TMP, "codex", "threads", tid + ".lock"))


def t_hostile_term_and_stubborn():
    import signal
    pidfile = os.path.join(TMP, "stubborn.pid")
    for proc in (FC(), FX()):
        if os.path.exists(pidfile):
            os.remove(pidfile)
        proc.init()
        if isinstance(proc, FC):
            claude_say(proc, "IGNORE_TERM SPAWN_STUBBORN")
        else:
            codex_say(proc, proc.thread(), "IGNORE_TERM SPAWN_STUBBORN")
        pid = int(wait_file(pidfile))
        proc.p.send_signal(signal.SIGTERM)
        time.sleep(0.3)
        assert proc.alive(), "IGNORE_TERM"
        assert os.getsid(pid) == pid, "stubborn child runs in its own session"
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.2)
        assert pid_alive(pid), "stubborn child ignores SIGTERM"
        os.kill(pid, signal.SIGKILL)
        proc.kill()


def t_run():
    import signal
    env = {"FAKE_TEST_VAR": "xyz"}
    cmd = "echo hello-$FAKE_TEST_VAR; pwd -P; echo oops >&2; exit 3"
    pidfile = os.path.join(TMP, "run.pid")
    for kind in ("claude", "codex"):
        if kind == "claude":
            p = FC(env=env)
            p.init()
            say = lambda text: claude_say(p, text)["result"]
        else:
            p = FX(env=env)
            p.init()
            tid = p.thread()
            say = lambda text: final_text(codex_say(p, tid, text)[0])
        out = say("please RUN " + cmd)
        assert out.startswith("exit=3\n") and "hello-xyz" in out and "oops" in out, out
        assert os.path.realpath(TMP) in out, out
        if kind == "claude":
            tu = [m for m in p.msgs if m.get("type") == "assistant" and m["message"]["content"][0]["type"] == "tool_use"]
            assert tu[-1]["message"]["content"][0]["input"]["command"] == cmd
        else:
            ce = [m["params"]["item"] for m in p.msgs if m.get("method") == "item/completed"
                  and m["params"]["item"]["type"] == "commandExecution"]
            assert ce[-1]["exitCode"] == 3 and ce[-1]["status"] == "failed" and "hello-xyz" in ce[-1]["aggregatedOutput"]
        # trigger words inside the command are the command's business
        assert say("RUN echo SLEEP 30 CRASH") == "exit=0\nSLEEP 30 CRASH"
        # interrupt kills the running command
        for f in (pidfile,):
            if os.path.exists(f):
                os.remove(f)
        n = p.n()
        if kind == "claude":
            p.user("RUN echo $$ > run.pid; exec sleep 30")
        else:
            r, _ = p.turn(tid, "RUN echo $$ > run.pid; exec sleep 30")
        pid = int(wait_file(pidfile))
        t0 = time.time()
        if kind == "claude":
            p.interrupt("intr")
            i, res = p.result(n)
            assert res["is_error"]
        else:
            p.call("turn/interrupt", {"threadId": tid, "turnId": r["result"]["turn"]["id"]})
            i, done = p.completed(n)
            assert done["params"]["turn"]["status"] == "interrupted"
        assert time.time() - t0 < 2
        assert wait_dead(pid), "interrupted RUN command still alive"
        # SIGTERM to the harness also takes a running command down
        os.remove(pidfile)
        if kind == "claude":
            p.user("RUN echo $$ > run.pid; exec sleep 30")
        else:
            p.turn(tid, "RUN echo $$ > run.pid; exec sleep 30")
        pid = int(wait_file(pidfile))
        p.p.send_signal(signal.SIGTERM)
        assert p.exit_code() == -signal.SIGTERM
        assert wait_dead(pid), "RUN command outlived a SIGTERMed harness"


def t_slow_start():
    for proc in (FC(env={"FAKE_SLOW_START": "1"}), FX(env={"FAKE_SLOW_START": "1"})):
        proc.init()
        assert time.time() - proc.t_spawn >= 1.0
        proc.close()
        assert proc.exit_code() == 0



# ============================================================ "allow for the rest of the session"

def t_claude_always():
    import shutil as _sh
    sid = str(uuid.uuid4())
    c = FC("--session-id", sid)
    c.init()

    def ask(text):
        n = c.n()
        u = c.user(text)
        i, m = c.wait_for(lambda m: (m.get("type") == "control_request" and m["request"]["subtype"] == "can_use_tool")
                          or (m.get("type") == "result" and u in m.get("user_message_uuids", [])), start=n)
        return (m, i) if m["type"] == "control_request" else (None, i)

    def finish(n):
        i, r = c.result(n)
        c.state("idle", i)
        return r["result"]

    # real suggestions for a Bash `touch` (CBash, C10)
    req, i = ask("ASK_PERMISSION:a.txt")
    r = req["request"]
    assert r["input"]["command"] == "touch a.txt"
    cwd = os.path.realpath(TMP)
    assert r["permission_suggestions"] == [
        {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "touch a.txt"}], "behavior": "allow",
         "destination": "localSettings"},
        {"type": "addDirectories", "directories": [cwd], "destination": "session"},
        {"type": "setMode", "mode": "acceptEdits", "destination": "session"}], r["permission_suggestions"]
    assert r["blocked_path"] == os.path.join(cwd, "a.txt")
    session_rule = [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "touch a.txt"}],
                     "behavior": "allow", "destination": "session"}]
    c.send({"type": "control_response", "response": {"subtype": "success", "request_id": req["request_id"], "response": {
        "behavior": "allow", "updatedInput": r["input"], "updatedPermissions": session_rule}}})
    i_echo, _ = c.wait_for(lambda m: m.get("type") == "control_response"
                           and m["response"]["request_id"] == req["request_id"], start=i)
    i_run, _ = c.state("running", i)
    assert i_run < i_echo, "state running precedes the echo (C3allow, C10)"
    assert finish(i) == "permission allowed"
    # same command: no prompt for the rest of the process
    req, i = ask("ASK_PERMISSION:a.txt again")
    assert req is None
    assert finish(i - 1) == "permission allowed (remembered)"
    # a different command still asks; answer with setMode acceptEdits (session)
    req, i = ask("ASK_PERMISSION:b.txt")
    assert req is not None
    c.send({"type": "control_response", "response": {"subtype": "success", "request_id": req["request_id"], "response": {
        "behavior": "allow", "updatedInput": req["request"]["input"],
        "updatedPermissions": [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]}}})
    i_st, st = c.wait_for(lambda m: m.get("subtype") == "status", start=i)
    assert st["permissionMode"] == "acceptEdits" and st["status"] is None
    assert c.state("running", i)[0] > i_st
    assert finish(i) == "permission allowed"
    n = c.n()
    req, i = ask("ASK_PERMISSION:c.txt")
    assert req is None
    assert finish(n) == "permission allowed (acceptEdits)"
    assert [m for m in c.msgs[n:] if m.get("subtype") == "init"][0]["permissionMode"] == "acceptEdits"
    # AskUserQuestion is not covered by Bash rules or acceptEdits
    req, i = ask("ASK_QUESTIONS")
    assert req is not None and req["request"]["tool_name"] == "AskUserQuestion"
    c.answer(req, True)
    finish(i)
    c.close()
    assert c.exit_code() == 0
    assert not os.path.exists(os.path.join(TMP, ".claude")), "session updates must not touch settings files"
    # --resume: session rules and the session mode are gone (C10resume)
    c = FC("--resume", sid)
    c.init()
    req, i = ask("ASK_PERMISSION:a.txt")
    assert req is not None
    assert [m for m in c.msgs if m.get("subtype") == "init"][0]["permissionMode"] == "default"
    c.answer(req, False)
    finish(i)
    c.close()
    c.exit_code()
    # a persisted destination (localSettings) is written where the real CLI writes it and survives restarts
    c = FC()
    c.init()
    req, i = ask("ASK_PERMISSION:d.txt")
    c.send({"type": "control_response", "response": {"subtype": "success", "request_id": req["request_id"], "response": {
        "behavior": "allow", "updatedInput": req["request"]["input"],
        "updatedPermissions": [dict(req["request"]["permission_suggestions"][0])]}}})
    finish(i)
    c.close()
    assert c.exit_code() == 0
    local = json.load(open(os.path.join(TMP, ".claude", "settings.local.json")))
    assert local["permissions"]["allow"] == ["Bash(touch d.txt)"]
    c = FC()
    c.init()
    req, i = ask("ASK_PERMISSION:d.txt")
    assert req is None
    assert finish(i - 1) == "permission allowed (remembered)"
    c.close()
    assert c.exit_code() == 0
    _sh.rmtree(os.path.join(TMP, ".claude"))


def t_codex_always():
    rules = os.path.join(TMP, "codex", "rules", "default.rules")
    if os.path.exists(rules):
        os.remove(rules)
    x = FX()
    x.init()
    A = x.thread(approvalPolicy="untrusted", sandbox="read-only")

    def ask(tid, text, decision):
        n = x.n()
        r, _ = x.turn(tid, text)
        T = r["result"]["turn"]["id"]
        reqs = []
        while True:
            i, m = x.wait_for(lambda m: (m.get("method") == "turn/completed" and m["params"]["turn"]["id"] == T)
                              or ("id" in m and "method" in m), start=n)
            n = i + 1
            if m.get("method") == "turn/completed":
                return reqs, final_text(m["params"]["turn"]), i
            reqs.append(m)
            x.send({"id": m["id"], "result": {"decision": decision(m) if callable(decision) else decision}})

    reqs, out, i = ask(A, "ASK_APPROVAL:a.txt", "acceptForSession")
    p = reqs[0]["params"]
    argv = ["/bin/zsh", "-lc", "touch a.txt"]
    # X2/X13: what the real server offers (acceptForSession is accepted but not offered)
    assert p["availableDecisions"] == ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": argv}},
                                       "cancel"] and p["proposedExecpolicyAmendment"] == argv
    assert out == "approval accepted"
    n = x.n()
    reqs, out, i = ask(A, "ASK_APPROVAL:a.txt again", "decline")
    assert reqs == [] and out == "approval accepted (remembered)"
    assert not any(m.get("method") == "thread/status/changed" and m["params"]["status"].get("activeFlags")
                   for m in x.msgs[n:]), "no waitingOnApproval for a remembered command (X13)"
    reqs, out, i = ask(A, "ASK_APPROVAL:b.txt", "decline")
    assert len(reqs) == 1 and out == "approval declined"
    B = x.thread(approvalPolicy="untrusted", sandbox="read-only")
    reqs, out, i = ask(B, "ASK_APPROVAL:a.txt", "decline")
    assert len(reqs) == 1, "acceptForSession is per thread (X13)"
    # execpolicy amendment: persisted, applies to every thread and later processes
    reqs, out, i = ask(B, "ASK_APPROVAL:c.txt",
                       lambda m: {"acceptWithExecpolicyAmendment": {
                           "execpolicy_amendment": m["params"]["proposedExecpolicyAmendment"]}})
    assert out == "approval accepted"
    assert open(rules).read() == 'prefix_rule(pattern=["/bin/zsh", "-lc", "touch c.txt"], decision="allow")\n'
    x.close()
    assert x.exit_code() == 0
    x = FX()
    x.init()
    x.call("thread/resume", {"threadId": A})
    reqs, out, i = ask(A, "ASK_APPROVAL:a.txt", "decline")
    assert len(reqs) == 1, "acceptForSession does not survive the process"
    C = x.thread(approvalPolicy="untrusted", sandbox="read-only")
    reqs, out, i = ask(C, "ASK_APPROVAL:c.txt", "decline")
    assert reqs == [] and out == "approval accepted (remembered)"
    x.close()
    assert x.exit_code() == 0
    os.remove(rules)


# ============================================================ turns the harness starts by itself (C11wake)

def is_self_result(m):
    return m.get("type") == "result" and "origin" in m


def t_claude_wake():
    c = FC("--dangerously-skip-permissions")
    c.init()
    n = c.n()
    r = claude_say(c, "WAKE 1 nonce-w1 ECHO CRASH")     # the WAKE text is not scanned for triggers
    t_started = time.time()
    assert r["result"] == "started", r
    sid = r["session_id"]
    first = c.msgs[n:]
    tu = [m for m in first if m.get("type") == "assistant" and m["message"]["content"][0]["type"] == "tool_use"][0]
    block = tu["message"]["content"][0]
    assert block["name"] == "Bash" and block["input"] == {"command": "sleep 1", "run_in_background": True}, block
    k = first.index(tu)
    seq = c.types(n)
    assert seq[k + 1:k + 4] == ["system:background_tasks_changed", "system:task_started", "user"], seq
    btc, ts, tr = first[k + 1:k + 4]
    task = ts["task_id"]
    assert btc["tasks"] == [{"task_id": task, "run_id": ts["run_id"], "task_type": "local_bash",
                             "description": "sleep 1"}], btc
    assert ts["is_backgrounded"] is True and ts["tool_use_id"] == block["id"] and ts["task_type"] == "local_bash"
    res = tr["message"]["content"][0]
    assert res["tool_use_id"] == block["id"] and res["is_error"] is False
    assert res["content"].startswith("Command running in background with ID: %s. Output is being written to: " % task)
    assert res["content"].endswith("You will be notified when it completes. To check interim output, use Read on "
                                   "that file path.")
    assert tr["tool_use_result"]["backgroundTaskId"] == task
    assert seq[-4:] == ["assistant", "result", "lifecycle:completed", "system:idle"], seq
    # the turn nobody sent
    n2 = c.n()
    i, r2 = c.wait_for(is_self_result, start=n2, what="self-started result")
    assert time.time() - t_started >= 2.2, "1 s command + FAKE_WAKE_TURN_SECS (default 1.5)"
    i_idle, _ = c.state("idle", i)
    seq = c.types(n2, i_idle + 1)
    assert seq == ["system:task_updated", "system:task_notification", "system:background_tasks_changed",
                   "system:running", "system:init", "assistant", "result", "system:idle"], seq
    upd, note, btc2 = c.msgs[n2:n2 + 3]
    assert upd["task_id"] == task and upd["run_id"] == ts["run_id"] and upd["patch"]["status"] == "completed"
    assert note["task_id"] == task and note["tool_use_id"] == block["id"] and note["status"] == "completed"
    assert note["summary"] == 'Background command "sleep 1" completed (exit code 0)' and note["output_file"]
    assert btc2["tasks"] == []
    assert r2["result"] == "woke: nonce-w1 ECHO CRASH" and r2["subtype"] == "success" and not r2["is_error"]
    assert r2["origin"] == {"kind": "task-notification", "producer": "session-task", "runId": ts["run_id"]}, r2
    assert r2["result_index"] == 1 and r2["num_turns"] == 1 and r2["session_id"] == sid
    assert "user_message_uuid" not in r2 and "user_message_uuids" not in r2
    assert all("user_message_uuid" not in m for m in c.msgs[n2:i] if m.get("type") == "assistant")
    # no receipt for it; one self_turns.jsonl line instead
    assert [x["text"] for x in receipts_for(sid)] == ["WAKE 1 nonce-w1 ECHO CRASH"]
    st = self_turns_for(sid)
    assert len(st) == 1 and st[0]["harness"] == "claude" and st[0]["text"] == "woke: nonce-w1 ECHO CRASH", st
    assert set(st[0]) == {"harness", "session", "text", "ts"}
    c.close()
    assert c.exit_code() == 0


def t_claude_wake_busy_and_queue():
    c = FC()
    c.init()
    sent = []
    r = claude_say(c, "WAKE 0.3")
    sent.append(r["user_message_uuid"])
    sid = r["session_id"]
    # the timer fires during another turn: the self-started turn follows that turn
    n = c.n()
    u = c.user("SLEEP 1.5")
    sent.append(u)
    i_r, _ = c.wait_for(lambda m: m.get("type") == "result" and u in m.get("user_message_uuids", []), start=n)
    i_upd, _ = c.wait_for(lambda m: m.get("subtype") == "task_updated", start=n)
    assert i_upd > i_r, "the self-started turn waits for the running turn"
    i_init, _ = c.wait_for(lambda m: m.get("subtype") == "init", start=i_upd)
    # a message arriving during the self-started turn is queued and runs after it
    u2 = c.user("during the self-started turn")
    sent.append(u2)
    i_self, r_self = c.wait_for(is_self_result, start=i_upd)
    assert r_self["result"] == "woke"
    i_q, _ = c.lifecycle(u2, "queued", i_init)
    i_s, _ = c.lifecycle(u2, "started", i_init)
    assert i_q < i_self < i_s
    assert "system:idle" not in c.types(i_self, i_s), "no idle between the two turns (C9b)"
    i, r2 = c.wait_for(lambda m: m.get("type") == "result" and u2 in m.get("user_message_uuids", []), start=i_s)
    assert r2["result"] == "ok: during the self-started turn"
    c.state("idle", i)
    # an interrupt during a self-started turn ends it like any turn
    r = claude_say(c, "WAKE 0.2 interrupted one")
    sent.append(r["user_message_uuid"])
    n = c.n()
    c.wait_for(lambda m: m.get("subtype") == "init", start=n, what="self-started init")
    i, resp = c.interrupt("wint")
    assert resp["response"]["response"] == {"still_queued": []}
    i, r3 = c.wait_for(is_self_result, start=n)
    assert r3["is_error"] and r3["subtype"] == "error_during_execution" and "user_message_uuids" not in r3
    c.state("idle", i)
    r = claude_say(c, "after")
    assert r["result"] == "ok: after"
    sent.append(r["user_message_uuid"])
    # stdin EOF while a background command still runs: the fake exits once idle; the wake is lost (not probed)
    r = claude_say(c, "WAKE 5")
    sent.append(r["user_message_uuid"])
    t0 = time.time()
    c.close()
    assert c.exit_code() == 0 and time.time() - t0 < 2
    check_claude_sequence(c.msgs, sent)
    assert sorted(r["message"] for r in receipts_for(sid)) == sorted(sent)
    assert [x["text"] for x in self_turns_for(sid)] == ["woke", "woke: interrupted one"]


def t_claude_chaos_wake():
    for seed in CHAOS_SEEDS:
        c = FC(env={"FAKE_CHAOS": str(seed), "FAKE_WAKE_TURN_SECS": "0.3"})
        c.init()
        sent = []
        n = c.n()
        u = c.user("WAKE 0.2 chaos %d" % seed)
        sent.append(u)
        i, r = c.wait_for(is_self_result, start=n)
        assert r["result"] == "woke: chaos %d" % seed
        c.state("idle", i)
        n = c.n()
        u = c.user("first SLEEP 0.6 WAKE 0.1")
        sent.append(u)
        c.tool_use(n)
        u2 = c.user("second")
        sent.append(u2)
        i, r = c.wait_for(is_self_result, start=n)
        c.lifecycle(u2, "completed", n)
        c.state("idle", i)
        c.close()
        assert c.exit_code() == 0
        check_claude_sequence(c.msgs, sent)


def t_codex_wake():
    x = FX()
    x.init()
    tid = x.thread()
    t, _ = codex_say(x, tid, "WAKE 0.3 hello CRASH")
    assert final_text(t) == "wake: not supported by codex"
    n = x.n()
    time.sleep(0.8)
    assert x.alive() and not any(m.get("method") == "turn/started" for m in x.msgs[n:])
    x.close()
    assert x.exit_code() == 0


# ============================================================ missing conversations (C12, X14)

C12_RESULT_KEYS = {"type", "subtype", "duration_ms", "duration_api_ms", "is_error", "num_turns", "stop_reason",
                   "session_id", "total_cost_usd", "usage", "modelUsage", "permission_denials", "uuid", "errors",
                   "result_index"}


def t_codex_background():
    """BACKGROUND n: the X15wake shape. The command item stays open past turn/completed, its
    item/completed arrives n s later with the finished turn's id, and no turn starts by itself."""
    x = FX(env={"FAKE_AGENT_DIR": os.path.join(TMP, "bg-" + uuid.uuid4().hex[:6])})
    x.init()
    tid = x.thread()
    n = x.n()
    r, cmid = x.turn(tid, "BACKGROUND 1.5 now")
    turn_id = r["result"]["turn"]["id"]
    i, done = x.completed(n)
    assert done["params"]["turn"]["items"][0]["text"] == "started"
    started = [m for m in x.msgs[n:i] if m.get("method") == "item/started"
               and m["params"]["item"]["type"] == "commandExecution"]
    assert len(started) == 1 and started[0]["params"]["item"]["status"] == "inProgress"
    ref = started[0]["params"]["item"]["id"]
    assert not [m for m in x.msgs[n:i] if m.get("method") == "item/completed"
                and m["params"]["item"]["id"] == ref], "the command is still running when the turn ends"
    j, late = x.wait_for(lambda m: m.get("method") == "item/completed" and m["params"]["item"]["id"] == ref,
                         start=i, timeout=10, what="the background command's item/completed")
    assert late["params"]["turnId"] == turn_id and late["params"]["item"]["status"] == "completed"
    assert late["params"]["item"]["exitCode"] == 0
    time.sleep(0.5)
    assert not [m for m in x.msgs[i:] if m.get("method") == "turn/started"], "no turn started by itself"
    # The thread takes messages normally afterwards.
    n = x.n()
    x.turn(tid, "ECHO after")
    i, done = x.completed(n)
    assert done["params"]["turn"]["items"][0]["text"] == "ECHO after"
    x.close()


def t_claude_resume_missing():
    # C12missing / C4e: stderr line, then one error `result` on stdout, no initialize response, exit 1.
    # The fake does all of it before reading stdin, so it happens even if nothing is sent.
    bad = str(uuid.uuid4())
    c = FC("--resume", bad)
    i, r = c.result()
    assert c.exit_code() == 1
    time.sleep(0.2)
    assert c.stderr == ["No conversation found with session ID: %s" % bad], c.stderr
    assert c.msgs == [r], c.msgs
    assert set(r) == C12_RESULT_KEYS, set(r) ^ C12_RESULT_KEYS
    assert r["subtype"] == "error_during_execution" and r["is_error"] is True and r["num_turns"] == 0
    assert r["session_id"] == bad and r["result_index"] == 0 and r["stop_reason"] is None
    assert r["errors"] == ["No conversation found with session ID: %s" % bad]
    assert not os.path.exists(os.path.join(TMP, "claude", bad + ".json"))
    # with an initialize sent first (as in C12missing) there is still no answer to it
    c = FC("--resume", bad)
    try:
        c.send({"type": "control_request", "request_id": "init1", "request": {"subtype": "initialize", "hooks": None}})
    except (BrokenPipeError, OSError):
        pass
    c.result()
    assert c.exit_code() == 1
    assert not any(m.get("type") == "control_response" for m in c.msgs)


def t_claude_resume_other_cwd():
    # C12othercwd-1/-2: a session made in one folder resumes from another, keeps context, reports the new cwd
    a, b = os.path.join(TMP, "cwd-a"), os.path.join(TMP, "cwd-b")
    os.makedirs(a, exist_ok=True)
    os.makedirs(b, exist_ok=True)
    sid = str(uuid.uuid4())
    c = FC("--session-id", sid, cwd=a)
    c.init()
    assert claude_say(c, "remember KUMQUAT")["result"] == "ok: remember KUMQUAT"
    assert [m for m in c.msgs if m.get("subtype") == "init"][0]["cwd"] == os.path.realpath(a)
    c.close()
    assert c.exit_code() == 0
    c = FC("--resume", sid, cwd=b)
    c.init()
    r = claude_say(c, "RECALL")
    assert r["result"] == "history: remember KUMQUAT" and r["session_id"] == sid, r
    init = [m for m in c.msgs if m.get("subtype") == "init"][0]
    assert init["cwd"] == os.path.realpath(b) and init["session_id"] == sid
    assert json.loads(claude_say(c, "STATE")["result"])["cwd"] == os.path.realpath(b)
    c.close()
    assert c.exit_code() == 0


def t_codex_resume_missing():
    # X14missing: JSON-RPC error -32600 "no rollout found for thread id <id>"; the server keeps running
    x = FX(env={"FAKE_MCP": "github:connected"})
    x.init()
    bad = str(uuid.uuid4())
    n = x.n()
    r = x.call("thread/resume", {"threadId": bad})
    assert r == {"error": {"code": -32600, "message": "no rollout found for thread id %s" % bad}, "id": r["id"]}, r
    time.sleep(0.3)
    assert x.alive() and x.msgs[n:] == [r], "no notifications for a failed resume"
    assert x.call("turn/start", {"threadId": bad, "input": []})["error"]["message"] == "thread not found: %s" % bad
    assert not os.path.exists(os.path.join(TMP, "codex", "threads", bad + ".lock"))
    tid = x.thread()
    t, _ = codex_say(x, tid, "still here")
    assert final_text(t) == "ok: still here"
    x.close()
    assert x.exit_code() == 0


# ============================================================ FAKE_MCP

MCP_ENV = "github:connected, jira:needs-auth,slow:pending,broken:failed"


def t_claude_mcp():
    # C13projectmcp: a project (.mcp.json) server appears as {"name", "status", "source": "project"}
    expected = [{"name": n, "status": s, "source": "project"} for n, s in
                (("github", "connected"), ("jira", "needs-auth"), ("slow", "pending"), ("broken", "failed"))]
    c = FC(env={"FAKE_MCP": MCP_ENV, "FAKE_WAKE_TURN_SECS": "0.2"})
    c.init()
    claude_say(c, "one")
    n = c.n()
    c.user("WAKE 0.1")
    c.wait_for(is_self_result, start=n)
    inits = [m for m in c.msgs if m.get("subtype") == "init"]
    assert len(inits) == 3 and all(m["mcp_servers"] == expected for m in inits), [m["mcp_servers"] for m in inits]
    c.close()
    assert c.exit_code() == 0
    c = FC()
    c.init()
    claude_say(c, "none")
    assert [m for m in c.msgs if m.get("subtype") == "init"][0]["mcp_servers"] == []
    c.close()
    assert c.exit_code() == 0
    c = FC(env={"FAKE_MCP": "github:bogus"})
    assert c.exit_code() == 2
    time.sleep(0.1)
    assert any("FAKE_MCP" in l for l in c.stderr) and c.msgs == [], c.stderr


def mcp_notes(proc, start=0):
    return [(i, m["params"]) for i, m in enumerate(proc.msgs) if i >= start
            and m.get("method") == "mcpServer/startupStatus/updated"]


def check_codex_mcp(x, tid, start):
    """X logs: every server reports "starting", then its final status, all with the five real keys."""
    end = time.time() + 5
    while len(mcp_notes(x, start)) < 7 and time.time() < end:
        time.sleep(0.05)
    notes = mcp_notes(x, start)
    assert len(notes) == 7, notes
    for _, p in notes:
        assert set(p) == {"threadId", "name", "status", "error", "failureReason"} and p["threadId"] == tid, p
    assert sorted(p["name"] for _, p in notes[:4]) == ["broken", "github", "jira", "slow"]
    assert all(p["status"] == "starting" and p["error"] is None and p["failureReason"] is None for _, p in notes[:4])
    finals = {p["name"]: p for _, p in notes[4:]}
    assert set(finals) == {"github", "jira", "broken"}, finals
    assert finals["github"]["status"] == "ready" and finals["github"]["error"] is None
    assert finals["jira"]["status"] == "failed" and finals["jira"]["failureReason"] == "reauthenticationRequired"
    assert finals["jira"]["error"].startswith("MCP client for `jira` failed to start")
    assert finals["broken"]["status"] == "failed" and finals["broken"]["failureReason"] is None
    assert finals["broken"]["error"].startswith("MCP client for `broken` failed to start")
    return notes


def t_codex_mcp():
    for chaos in (None, "3"):
        env = {"FAKE_MCP": MCP_ENV}
        if chaos:
            env["FAKE_CHAOS"] = chaos
        x = FX(env=env)
        x.init()
        n = x.n()
        tid = x.thread()
        i_ts, _ = x.note("thread/started", n)
        notes = check_codex_mcp(x, tid, n)
        assert notes[0][0] > i_ts, "thread/start: after thread/started (X1, X2, X7)"
        t, _ = codex_say(x, tid, "with mcp")
        assert final_text(t) == "ok: with mcp"
        x.close()
        assert x.exit_code() == 0
        # thread/resume that loads the thread: "starting" before the response (X5c_b)
        y = FX(env=env)
        y.init()
        n = y.n()
        rid = y.req("thread/resume", {"threadId": tid})
        i_resp, resp = y.wait_for(lambda m: m.get("id") == rid and "method" not in m)
        assert "result" in resp
        notes = check_codex_mcp(y, tid, n)
        assert max(i for i, _ in notes[:4]) < i_resp < min(i for i, _ in notes[4:])
        y.close()
        assert y.exit_code() == 0
    x = FX()
    x.init()
    tid = x.thread()
    codex_say(x, tid, "no mcp")
    time.sleep(0.4)
    assert mcp_notes(x) == []
    x.close()
    assert x.exit_code() == 0
    x = FX(env={"FAKE_MCP": "github"})
    assert x.exit_code() == 2
    time.sleep(0.1)
    assert any("FAKE_MCP" in l for l in x.stderr), x.stderr


TESTS = [t_codex_background, t_claude_basic, t_claude_interrupt_sleep, t_claude_interrupt_keeps_queued, t_claude_injection,
         t_claude_permissions, t_claude_skip_permissions, t_claude_resume, t_claude_crash_and_malformed,
         t_claude_stdin_close_mid_turn, t_codex_basic, t_codex_steer_and_commentary, t_codex_interrupt,
         t_codex_approvals, t_codex_resume_and_lock, t_codex_eof_crash_fail_queue,
         t_claude_chaos_basic, t_claude_chaos_injection_choice, t_codex_chaos_basic, t_codex_chaos_steer_race,
         t_codex_early_interrupt, t_receipts_exactly_once, t_state, t_fail, t_hostile_garbage, t_hostile_huge,
         t_hostile_stderr_spam, t_hostile_hang, t_hostile_exit_clean, t_hostile_term_and_stubborn, t_run,
         t_slow_start, t_claude_always, t_codex_always, t_claude_wake, t_claude_wake_busy_and_queue,
         t_claude_chaos_wake, t_codex_wake, t_claude_resume_missing, t_claude_resume_other_cwd,
         t_codex_resume_missing, t_claude_mcp, t_codex_mcp]


def main():
    filt = [a for a in sys.argv[1:] if not a.startswith("-")]
    failed = 0
    ran = 0
    for t in TESTS:
        if filt and not any(f in t.__name__ for f in filt):
            continue
        ran += 1
        t0 = time.time()
        try:
            t()
            print("PASS %-36s %.2fs" % (t.__name__, time.time() - t0))
        except Exception:
            failed += 1
            print("FAIL %-36s %.2fs" % (t.__name__, time.time() - t0))
            traceback.print_exc()
    shutil.rmtree(TMP, ignore_errors=True)
    print("%d/%d passed" % (ran - failed, ran))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
