"""Managed agents through the CLI, against the fake harnesses (SPEC MA)."""

import json
import os
import signal
import subprocess
import time
import uuid

import pytest

from harness import alive, descendants, login_env, wait_until, zombies

pytestmark = [pytest.mark.managed, pytest.mark.harness]

KINDS = ["claude", "codex"]
# How each harness spells "ask before acting" (the fakes accept the real CLIs' values).
ASKING_MODE = {"claude": "default", "codex": "on-request"}
PERMISSION_TRIGGER = {"claude": "ASK_PERMISSION", "codex": "ASK_APPROVAL"}


def nonce():
    return uuid.uuid4().hex[:10]


@pytest.fixture
def started(inst):
    """Start sessions for one test; every one of them is stopped afterwards."""
    ids = []

    def start(kind, prompt=None, *options, name=None, **kwargs):
        sid = inst.start_agent(kind, prompt, *options, name=name or f"{kind}-{nonce()}", **kwargs)
        ids.append(sid)
        return sid

    start.ids = ids
    yield start
    for sid in ids:
        inst.cli("agent", "stop", sid, check=False, timeout=60)


def receipts_with(inst, marker):
    return [r for r in inst.receipts() if marker in (r.get("text") or "")]


def delivered_once(inst, marker, timeout=0):
    """The message carrying `marker` reached the model exactly once."""
    if timeout:
        wait_until(lambda: receipts_with(inst, marker), timeout, message=f"delivery of {marker}")
    got = receipts_with(inst, marker)
    assert len(got) == 1, f"message {marker} was delivered {len(got)} times"
    return got[0]


def harness_pid(inst, marker):
    """The harness process that received the message carrying `marker`."""
    return wait_until(lambda: (receipts_with(inst, marker) or [{}])[0].get("pid"), 15, message="a harness pid")


def status(inst, sid):
    return inst.info(sid)["status"]


# ---- lifecycle and messages -------------------------------------------------------------------

@pytest.mark.req("MA-1", "MA-2", "MA-5", "MA-6")
@pytest.mark.parametrize("kind", KINDS)
def test_start_wait_read(inst, started, kind):
    n = nonce()
    sid = started(kind, f"ECHO first {n}")
    assert len(sid) >= 8
    proc = inst.cli("agent", "wait", sid, "--timeout", "60", check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert proc.stdout.splitlines()[0] == "DONE"
    assert f"ECHO first {n}" in proc.stdout
    assert inst.cli("agent", "read", sid).stdout.strip() == f"ECHO first {n}"
    info = inst.info(sid)
    assert info["status"] == "idle" and info["kind"] == kind and info["live"] is True
    receipt = delivered_once(inst, n)
    # The harness's own session id is the session's harness_id, and selects the session.
    assert info["harness_id"] == receipt["session"]
    assert inst.info(info["harness_id"])["id"] == sid
    assert inst.info(sid[:8])["id"] == sid


@pytest.mark.req("MA-2")
@pytest.mark.parametrize("kind", KINDS)
def test_message_ids_are_the_ones_the_harness_knows(inst, started, kind):
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    n = nonce()
    message = inst.send(sid, f"ECHO {n}")
    code, out = inst.wait(sid, "--message", message)
    assert (code, out["status"]) == (0, "DONE"), out
    assert out["message"]["id"] == message
    receipt = delivered_once(inst, n)
    assert receipt["message"] == message, "the id `agent send` printed is the id the harness echoed for that message"


@pytest.mark.req("MA-1")
@pytest.mark.parametrize("kind", KINDS)
def test_start_options_reach_the_harness(inst, started, kind):
    model = "haiku" if kind == "claude" else "gpt-5.1-codex-mini"
    harness_args = ["--add-dir", "/tmp"] if kind == "claude" else ["-c", "model_verbosity=low"]
    value = "v-" + nonce()
    sid = started(kind, None, "--model", model, "--effort", "low", "--full-access", "--env", f"ACC_VALUE={value}",
                  "--", *harness_args)
    inst.send(sid, "STATE")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    state = json.loads(out["reply"])
    assert state["model"] == model
    assert state["effort"] == "low"
    assert state["full_access"] is True
    assert os.path.realpath(state["cwd"]) == os.path.realpath(inst.work)
    joined = " ".join(state["argv"])
    assert all(a in joined for a in harness_args), f"harness arguments after -- are passed on: {state['argv']}"
    inst.send(sid, "PRINTENV ACC_VALUE")
    assert inst.wait(sid)[1]["reply"] == value


@pytest.mark.req("MA-1", "L-5")
def test_start_in_a_new_worktree(inst, started, tmp_path):
    repo = str(tmp_path / "repo")
    subprocess.run(["git", "init", "-q", repo], check=True)
    subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty",
                    "-m", "init"], check=True)
    branch = "agent-" + nonce()
    sid = inst.json("agent", "start", "claude", "--background", "--cwd", repo, "--worktree", branch,
                    "--env", "FAKE_AGENT_DIR=" + inst.fake_dir, "RUN pwd; git branch --show-current")["session"]["id"]
    started.ids.append(sid)
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    lines = out["reply"].splitlines()
    assert lines[0] == "exit=0"
    assert os.path.realpath(lines[1]) != os.path.realpath(repo)
    assert lines[2] == branch


@pytest.mark.req("MA-3", "MA-5", "MA-6")
@pytest.mark.parametrize("kind", KINDS)
def test_follow_up_after_finish_and_old_replies(inst, started, kind):
    a, b = nonce(), nonce()
    sid = started(kind, f"ECHO one {a}")
    code, first = inst.wait(sid)
    assert (code, first["status"]) == (0, "DONE")
    m2 = inst.send(sid, f"ECHO two {b}")
    code, out = inst.wait(sid)
    assert (out["status"], out["reply"], out["message"]["id"]) == ("DONE", f"ECHO two {b}", m2)
    # An older message still reports its own reply, through wait and read.
    m1 = first["message"]["id"]
    code, old = inst.wait(sid, "--message", m1)
    assert (code, old["reply"]) == (0, f"ECHO one {a}")
    assert inst.json("agent", "read", sid, "--message", m1)["reply"] == f"ECHO one {a}"
    # The transcript has both messages, in order, with their ids.
    users = [i for i in inst.transcript(sid) if i["kind"] == "user"]
    assert [u.get("message") for u in users][-2:] == [m1, m2]


@pytest.mark.req("MA-3", "MA-4", "MA-7")
@pytest.mark.parametrize("kind", KINDS)
def test_follow_ups_while_busy_are_queued_in_order(inst, started, kind):
    a, b = nonce(), nonce()
    sid = started(kind, "SLEEP 3")
    wait_until(lambda: status(inst, sid) == "working", 10, message="working")
    m2 = inst.send(sid, f"ECHO second {a}")
    m3 = inst.send(sid, f"ECHO third {b}")
    # Not idle while a message is unanswered (MA-7).
    seen = set()
    deadline = time.time() + 60
    while time.time() < deadline:
        s = status(inst, sid)
        seen.add(s)
        if s == "idle":
            break
        time.sleep(0.05)
    for m in (m2, m3):
        code, out = inst.wait(sid, "--message", m, "--timeout", "5")
        assert (code, out["status"]) == (0, "DONE"), f"idle while {m} was unanswered: {out}"
    assert seen <= {"working", "idle"}, seen
    ra, rb = delivered_once(inst, a), delivered_once(inst, b)
    assert ra["ts"] <= rb["ts"], "queued messages reach the agent in the order they were sent"


@pytest.mark.req("MA-5")
def test_wait_with_nothing_pending_and_timeouts(inst, started):
    sid = started("claude", None)
    t0 = time.time()
    code, out = inst.wait(sid, timeout=20)
    assert code == 0 and time.time() - t0 < 5, out
    slow = started("claude", "SLEEP 20")
    proc = inst.cli("agent", "wait", slow, "--timeout", "1", check=False)
    assert proc.returncode == 124
    assert proc.stdout.startswith("TIMEOUT")


@pytest.mark.req("MA-8", "MA-4")
@pytest.mark.parametrize("kind", KINDS)
def test_interrupt_keeps_session_and_queued_messages(inst, started, kind):
    sid = started(kind, "SLEEP 20")
    first = inst.info(sid)["last_message"]["id"]
    wait_until(lambda: status(inst, sid) == "working", 10, message="working")
    time.sleep(0.5)
    n = nonce()
    queued = inst.send(sid, f"ECHO after interrupt {n}")
    inst.cli("agent", "interrupt", sid)
    code, out = inst.wait(sid, "--message", first, timeout=15)
    assert (code, out["status"]) == (3, "INTERRUPTED"), out
    code, out = inst.wait(sid, "--message", queued, timeout=30)
    assert out["status"] == "DONE", out
    assert inst.info(sid)["live"]
    delivered_once(inst, n)


@pytest.mark.req("MA-3", "MA-9")
@pytest.mark.parametrize("kind", KINDS)
def test_stop_then_follow_up_resumes_the_conversation(inst, started, kind):
    word = "pomegranate-" + nonce()
    sid = started(kind, f"ECHO remember {word}")
    inst.wait(sid)
    harness = inst.info(sid)["harness_id"]
    inst.cli("agent", "stop", sid)
    wait_until(lambda: status(inst, sid) == "exited", 10, message="exited")
    assert inst.info(sid)["live"] is False
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    assert word in out["reply"]
    assert inst.info(sid)["harness_id"] == harness


@pytest.mark.req("MA-9", "R-1")
@pytest.mark.parametrize("kind", KINDS)
def test_stop_ends_everything_the_agent_started(inst, started, kind):
    n = nonce()
    sid = started(kind, f"IGNORE_TERM SPAWN_STUBBORN SLEEP 60 {n}")
    pid_file = os.path.join(inst.fake_dir, "stubborn.pid")
    wait_until(lambda: os.path.exists(pid_file) and open(pid_file).read().strip(), 15, message="detached child")
    child = int(open(pid_file).read())
    os.remove(pid_file)
    harness = harness_pid(inst, n)
    tree = descendants(harness)
    assert alive(child) and alive(harness)
    inst.cli("agent", "stop", sid)
    code, out = inst.wait(sid, timeout=20)
    assert out["status"] in ("INTERRUPTED", "EXITED"), out
    wait_until(lambda: not alive(harness), 15, message="the harness (it ignores SIGTERM) is gone")
    wait_until(lambda: not alive(child), 15, message="the detached child that ignores SIGTERM is gone")
    assert not [p for p in tree if alive(p)], "every process the agent started is gone"
    assert status(inst, sid) == "exited"


@pytest.mark.req("MA-3", "MA-4")
def test_follow_up_sent_while_stopping_is_not_lost(inst, started):
    word = "lychee-" + nonce()
    sid = started("claude", f"ECHO remember {word}")
    inst.wait(sid)
    inst.send(sid, "IGNORE_TERM SLEEP 30")
    wait_until(lambda: status(inst, sid) == "working", 10, message="working")
    inst.cli("agent", "stop", sid)
    n = nonce()
    message = inst.send(sid, f"RECALL {n}")   # while the old process is still dying
    code, out = inst.wait(sid, "--message", message, timeout=40)
    assert out["status"] == "DONE", out
    assert word in out["reply"]
    delivered_once(inst, n)


@pytest.mark.req("MA-10", "R-1")
@pytest.mark.parametrize("kind", KINDS)
def test_crash_is_an_error_and_a_follow_up_resumes(inst, started, kind):
    word = "quince-" + nonce()
    sid = started(kind, f"ECHO remember {word}")
    inst.wait(sid)
    pid_file = os.path.join(inst.fake_dir, "stubborn.pid")
    inst.send(sid, "SPAWN_STUBBORN")
    inst.wait(sid)
    child = int(open(pid_file).read())
    os.remove(pid_file)
    inst.send(sid, "CRASH")
    code, out = inst.wait(sid)
    assert code == 3 and out["status"] in ("ERROR", "FAILED", "EXITED"), out
    info = inst.info(sid)
    assert info["status"] == "error" and info.get("error"), info
    wait_until(lambda: not alive(child), 15, message="the crashed harness's detached child is cleaned up")
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    assert word in out["reply"]


@pytest.mark.req("MA-10")
@pytest.mark.parametrize("kind", KINDS)
def test_harness_exiting_on_its_own(inst, started, kind):
    word = "kumquat-" + nonce()
    sid = started(kind, f"ECHO {word} EXIT_CLEAN")
    inst.wait(sid)
    wait_until(lambda: status(inst, sid) in ("exited", "error"), 15, message="the exit is noticed")
    assert inst.info(sid)["live"] is False
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE" and word in out["reply"], out


@pytest.mark.req("MA-10", "MA-5")
def test_failed_turn(inst, started):
    sid = started("codex", "FAIL")
    code, out = inst.wait(sid)
    assert (code, out["status"]) == (3, "FAILED"), out
    inst.send(sid, "ECHO still usable")
    assert inst.wait(sid)[1]["status"] == "DONE"


@pytest.mark.req("MA-11", "R-1")
def test_names_list_rename_remove(inst, started):
    name = "dup-" + nonce()
    a = started("claude", "ECHO a", name=name)
    proc = inst.cli("agent", "start", "claude", "--background", "--name", name, "ECHO b",
                    "--env", "FAKE_AGENT_DIR=" + inst.fake_dir, check=False)
    assert proc.returncode != 0 and proc.stderr.strip(), "a running session keeps its name"
    inst.cli("agent", "rename", a, name + "-2")
    assert inst.info(name + "-2")["id"] == a
    assert any(s["id"] == a for s in inst.agents())
    inst.wait(a)
    n = nonce()
    inst.send(a, f"SLEEP 30 {n}")
    pid = harness_pid(inst, n)
    proc = inst.cli("agent", "rm", a, check=False)
    assert proc.returncode != 0, "removing a running session needs --force"
    inst.cli("agent", "rm", a, "--force")
    assert not any(s["id"] == a for s in inst.agents())
    assert inst.cli("agent", "info", a, check=False).returncode != 0
    wait_until(lambda: not alive(pid), 10, message="the removed session's process is gone")
    wait_until(lambda: not any(p == pid for p, _ in zombies()), 10, message="and reaped (no zombie)")
    # A finished session gives up its name.
    b = started("claude", "ECHO b", name=name + "-3")
    inst.wait(b)
    inst.cli("agent", "stop", b)
    wait_until(lambda: not inst.info(b)["live"], 15, message="the stopped session is no longer live")
    c = started("claude", "ECHO c", name=name + "-3")
    assert inst.info(name + "-3")["id"] == c


@pytest.mark.req("MA-12", "MA-18")
def test_self_and_parent(inst, started):
    cli = inst.target.cli_name
    sid = started("claude", f"RUN {cli} --json agent info self")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    body = out["reply"].split("\n", 1)[1]
    assert json.loads(body)["id"] == sid
    child = "child-" + nonce()
    inst.send(sid, f"RUN {cli} agent start codex --background --name {child} 'ECHO from the child'")
    code, out = inst.wait(sid)
    assert out["reply"].startswith("exit=0"), out
    info = inst.info(child)
    assert info["kind"] == "codex" and info.get("parent") == sid
    inst.cli("agent", "stop", child, check=False)


@pytest.mark.req("MA-18")
@pytest.mark.parametrize("boss,worker", [("claude", "codex"), ("codex", "claude")])
def test_agents_orchestrate_agents(inst, started, boss, worker):
    cli = inst.target.cli_name
    n = nonce()
    child = "sub-" + n
    script = (f"{cli} agent start {worker} --background --name {child} 'ECHO hello {n}' >/dev/null && "
              f"{cli} agent wait {child} --timeout 60 && "
              f"{cli} agent send {child} 'ECHO again {n}' >/dev/null && "
              f"{cli} agent wait {child} --timeout 60 && {cli} agent read {child}")
    sid = started(boss, f"RUN {script}")
    code, out = inst.wait(sid, timeout=150)
    assert out["status"] == "DONE", out
    assert out["reply"].startswith("exit=0"), out["reply"]
    assert f"ECHO hello {n}" in out["reply"] and out["reply"].rstrip().endswith(f"ECHO again {n}")
    # The worker is a session of this very instance.
    assert any(s.get("name") == child for s in inst.agents())
    inst.cli("agent", "stop", child, check=False)


@pytest.mark.req("MA-19")
def test_watch_notifies_the_supervisor(inst, started):
    boss = started("claude", "ECHO I supervise")
    inst.wait(boss)
    worker_name = "worker-" + nonce()
    worker = started("codex", "SLEEP 2", name=worker_name)
    inst.cli("agent", "watch", worker, "--notify", boss)
    harness = inst.info(boss)["harness_id"]

    def notified():
        return [r for r in inst.receipts() if r["session"] == harness
                and (worker_name in r["text"] or worker in r["text"])]
    got = wait_until(notified, 40, message="the supervisor gets a follow-up about its worker")
    assert len(got) == 1, "notified once per watched turn"
    code, out = inst.wait(boss)
    assert out["status"] == "DONE"


@pytest.mark.req("MA-13", "T-1")
def test_text_from_stdin_and_after_separator(inst, started):
    sid = started("claude", "ECHO x")
    inst.wait(sid)
    inst.cli("agent", "send", sid, "-", stdin="ECHO piped text\n")
    assert inst.wait(sid)[1]["reply"] == "ECHO piped text"
    inst.cli("agent", "send", sid, "--", "ECHO --flag-looking text")
    assert inst.wait(sid)[1]["reply"] == "ECHO --flag-looking text"


@pytest.mark.req("MA-13")
def test_no_command_waits_on_stdin_unless_asked(inst, started):
    sid = started("claude", "ECHO x")
    inst.wait(sid)
    for args in (["agent", "start", "claude", "--background", "--env", "FAKE_AGENT_DIR=" + inst.fake_dir],
                 ["agent", "info", sid], ["agent", "ls"], ["agent", "read", sid], ["agent", "wait", sid]):
        proc = subprocess.Popen([inst.target.cli_path, "--json", *args], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=inst.env, cwd=inst.work, text=True)
        try:
            out, _ = proc.communicate(timeout=20)   # stdin stays open: a reader would hang
        except subprocess.TimeoutExpired:
            proc.kill()
            pytest.fail(f"`{' '.join(args[:3])}` waited on stdin")
        if args[1] == "start" and proc.returncode == 0:
            inst.cli("agent", "stop", json.loads(out)["session"]["id"], check=False)


@pytest.mark.req("MA-13", "AP-3")
@pytest.mark.parametrize("flags", [["--tab"], ["--split"], ["--split", "down"], ["--new-window"], ["--focus"]])
def test_placement_flags_never_swallow_the_prompt(inst, started, flags):
    n = nonce()
    sid = inst.json("agent", "start", "codex", *flags, f"ECHO placed {n}", "--background",
                    "--env", "FAKE_AGENT_DIR=" + inst.fake_dir)["session"]["id"]
    started.ids.append(sid)
    code, out = inst.wait(sid)
    assert (out["status"], out["reply"]) == ("DONE", f"ECHO placed {n}")


@pytest.mark.req("MA-5", "MA-1")
def test_start_with_wait(inst, started):
    n = nonce()
    proc = inst.cli("agent", "start", "codex", "--background", "--env", "FAKE_AGENT_DIR=" + inst.fake_dir,
                    "--name", "sw-" + n, "--wait", "--timeout", "60", f"ECHO waited {n}", check=False)
    started.ids.append("sw-" + n)
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines()[0] == "DONE" and f"ECHO waited {n}" in proc.stdout


@pytest.mark.req("MA-11", "L-4")
def test_bad_requests_fail_clearly(inst):
    for args in (["agent", "start", "gemini", "--background", "hi"],
                 ["agent", "start", "claude", "--background", "--cwd", "/nonexistent/dir", "hi"],
                 ["agent", "send", "no-such-session-" + nonce(), "hi"],
                 ["agent", "wait", "no-such-session-" + nonce()],
                 ["agent", "read", "no-such-session-" + nonce(), "--transcript", "--last", "-1"]):
        proc = inst.cli(*args, check=False, timeout=30)
        assert proc.returncode == 1, (args, proc.returncode)
        assert proc.stderr.startswith(inst.target.cli_name + ": "), proc.stderr


# ---- approvals and questions -------------------------------------------------------------------

@pytest.mark.req("MA-14", "MA-5")
@pytest.mark.parametrize("kind", KINDS)
def test_approvals_allow_once_always_and_deny(inst, started, kind, tmp_path):
    trigger = PERMISSION_TRIGGER[kind]
    folder = str(tmp_path)   # its own folder: an "always" that leaks into project settings would show up here
    sid = started(kind, trigger, "--permission-mode", ASKING_MODE[kind], cwd=folder)
    proc = inst.cli("agent", "wait", sid, "--timeout", "30", check=False)
    assert proc.returncode == 2 and proc.stdout.startswith("NEEDS_INPUT"), proc.stdout + proc.stderr
    info = inst.info(sid)
    assert info["status"] == "needs_input" and len(info["requests"]) == 1
    request = info["requests"][0]
    assert request["kind"] == "approval"
    assert request["detail"].strip(), "the request says what would be allowed"
    inst.cli("agent", "approve", sid, request["id"])
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    assert ("allowed" if kind == "claude" else "accepted") in out["reply"]
    # Denied, with a message the agent sees.
    inst.send(sid, trigger)
    assert inst.wait(sid)[0] == 2
    inst.cli("agent", "deny", sid, "--message", "not now")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    assert ("denied" if kind == "claude" else "declined") in out["reply"]
    if kind == "claude":
        assert "not now" in out["reply"]
    # Allowed always: the same kind of action doesn't ask again in this session...
    inst.send(sid, trigger)
    assert inst.wait(sid)[0] == 2
    inst.cli("agent", "approve", sid, "--always")
    assert inst.wait(sid)[1]["status"] == "DONE"
    inst.send(sid, trigger)
    code, out = inst.wait(sid)
    assert (code, out["status"]) == (0, "DONE"), "an always-allowed action asked again"
    # ...but only that exact action...
    inst.send(sid, f"{trigger}:other-file")
    assert inst.wait(sid)[0] == 2, "allow-always covered a different command"
    inst.cli("agent", "deny", sid)
    inst.wait(sid)
    # ...and only in this session.
    other = started(kind, trigger, "--permission-mode", ASKING_MODE[kind], cwd=folder)
    assert inst.wait(other)[0] == 2, "allow-always leaked beyond the session"


@pytest.mark.req("MA-14")
@pytest.mark.parametrize("kind", KINDS)
def test_full_access_never_asks(inst, started, kind):
    sid = started(kind, PERMISSION_TRIGGER[kind], "--full-access")
    code, out = inst.wait(sid)
    assert (code, out["status"]) == (0, "DONE"), out


@pytest.mark.req("MA-15")
@pytest.mark.parametrize("kind", KINDS)
def test_several_questions_get_separate_answers(inst, started, kind):
    sid = started(kind, "ASK_QUESTIONS", "--permission-mode", ASKING_MODE[kind])
    proc = inst.cli("agent", "wait", sid, "--timeout", "30", check=False)
    assert proc.returncode == 2, proc.stdout + proc.stderr
    assert "Favorite color?" in proc.stdout and "Which size?" in proc.stdout
    request = inst.info(sid)["requests"][0]
    assert request["kind"] == "question"
    assert [q["question"] for q in request["questions"]] == ["Favorite color?", "Which size?"]
    assert request["questions"][0]["options"] == ["red", "blue"], "every option is shown"
    # One answer for two questions is refused, not copied to both.
    proc = inst.cli("agent", "answer", sid, "red", check=False)
    assert proc.returncode != 0 and proc.stderr.strip()
    assert inst.info(sid)["status"] == "needs_input"
    inst.cli("agent", "answer", sid, "--answer", "1=blue", "--answer", f"{request['questions'][1]['id']}=L")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    expected = ("answers: Favorite color?=blue; Which size?=L" if kind == "claude"
                else "answers: q_color=blue; q_size=L")
    assert out["reply"] == expected


@pytest.mark.req("MA-16")
def test_mcp_elicitations(inst, started):
    sid = started("codex", "ASK_PERMS", "--permission-mode", ASKING_MODE["codex"])
    assert inst.wait(sid)[0] == 2
    request = inst.info(sid)["requests"][0]
    assert "network" in request["detail"].lower() and "/tmp/x" in request["detail"]
    inst.cli("agent", "approve", sid)
    assert '"write": ["/tmp/x"]' in inst.wait(sid)[1]["reply"]
    inst.send(sid, "ASK_URL")
    proc = inst.cli("agent", "wait", sid, "--timeout", "30", check=False)
    assert proc.returncode == 2 and "https://example.com/login" in proc.stdout
    assert inst.info(sid)["requests"][0]["details"]["url"] == "https://example.com/login"
    inst.cli("agent", "approve", sid)
    assert '"action": "accept"' in inst.wait(sid)[1]["reply"]
    inst.send(sid, "ASK_FORM")
    assert inst.wait(sid)[0] == 2
    assert inst.info(sid)["requests"][0]["details"].get("schema")
    inst.cli("agent", "answer", sid, "staging")
    assert '"content": {"env": "staging"}' in inst.wait(sid)[1]["reply"]


@pytest.mark.req("MA-17", "MA-7")
@pytest.mark.parametrize("kind", KINDS)
def test_withdrawn_requests_disappear(inst, started, kind):
    sid = started(kind, PERMISSION_TRIGGER[kind], "--permission-mode", ASKING_MODE[kind])
    assert inst.wait(sid)[0] == 2
    inst.cli("agent", "interrupt", sid)
    wait_until(lambda: not inst.info(sid)["requests"], 10, message="the withdrawn request is gone")
    assert status(inst, sid) != "needs_input"


# ---- environment ------------------------------------------------------------------------------


@pytest.mark.req("MA-20")
@pytest.mark.parametrize("kind", KINDS)
def test_agents_get_a_fresh_login_environment(inst, started, kind):
    markers = {"CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "sdk-ts", "CODEX_THREAD_ID": "stale-thread",
               "CLAUDE_CODE_SESSION_ID": "stale-session"}
    sid = inst.json("agent", "start", kind, "--background", "--cwd", inst.work, "--env",
                    "FAKE_AGENT_DIR=" + inst.fake_dir, "RUN env", env=markers)["session"]["id"]
    started.ids.append(sid)
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    env = dict(line.split("=", 1) for line in out["reply"].splitlines()[1:] if "=" in line)
    leaked = {k: env[k] for k in markers if env.get(k) == markers[k]}
    assert not leaked, f"the agent inherited the launcher's markers: {leaked}"
    assert env.get("HOME") == os.path.expanduser("~")
    agent_path = env.get("PATH", "").split(":")
    missing = [p for p in login_env().get("PATH", "").split(":") if p and p not in agent_path]
    assert not missing, f"login PATH entries missing from the agent's PATH (the app was started with a bare PATH): {missing}"


@pytest.mark.req("MA-21", "IA-4")
def test_user_agent_config_is_untouched(inst, started):
    watched = [os.path.expanduser(p) for p in ("~/.claude/settings.json", "~/.codex/config.toml", "~/.codex/auth.json")]
    before = {p: os.stat(p).st_mtime_ns for p in watched if os.path.exists(p)}
    for kind in KINDS:
        sid = started(kind, "ECHO config check")
        inst.wait(sid)
    after = {p: os.stat(p).st_mtime_ns for p in watched if os.path.exists(p)}
    assert before == after


# ---- status ------------------------------------------------------------------------------------

@pytest.mark.req("MA-7", "R-6")
def test_status_is_truthful_and_cheap_while_busy(inst, started):
    sid = started("codex", "SLEEP 4")
    statuses = []
    t0 = time.time()
    while time.time() - t0 < 8:
        s = time.time()
        info = inst.info(sid)
        assert time.time() - s < 2, "agent info stays fast while the agent works"
        statuses.append(info["status"])
        if info["status"] == "idle":
            break
        time.sleep(0.1)
    assert "working" in statuses and statuses[-1] == "idle"
    # No flapping: once idle with nothing pending, it stays idle.
    first_idle = statuses.index("idle")
    assert all(s == "idle" for s in statuses[first_idle:])
    assert all(s in ("starting", "working", "idle") for s in statuses)


@pytest.mark.req("MA-4", "MA-22")
def test_follow_ups_racing_the_end_of_a_turn_are_delivered_once(inst, started):
    for kind in KINDS:
        sid = started(kind, "ECHO warm-up")
        inst.wait(sid)
        for delay in (0.3, 0.45, 0.5, 0.55, 0.6, 0.75):
            inst.send(sid, "SLEEP 0.5")
            time.sleep(delay)
            n = nonce()
            message = inst.send(sid, f"ECHO after {delay} {n}")
            code, out = inst.wait(sid, "--message", message)
            assert out["status"] == "DONE", (kind, delay, out)
            delivered_once(inst, n)


@pytest.mark.req("MA-4")
def test_a_message_the_agent_never_received_fails_visibly(inst, started):
    sid = started("claude", "ECHO warm-up")
    inst.wait(sid)
    inst.send(sid, "HANG")
    time.sleep(1)
    n = nonce()
    message = inst.send(sid, f"ECHO behind a hung turn {n}")
    inst.cli("agent", "stop", sid)
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert out["status"] != "TIMEOUT", "never pending forever"
    if out["status"] == "DONE":
        delivered_once(inst, n)
    else:
        assert code == 3 and not receipts_with(inst, n), out


@pytest.mark.req("MA-4", "MA-8")
def test_interrupt_before_the_harness_takes_the_message(inst, started):
    """The fake waits FAKE_INPUT_DELAY seconds between starting a turn and taking its input; an interrupt
    in that window drops the input (a timing the real Codex can produce)."""
    sid = started("codex", None, env={"FAKE_INPUT_DELAY": "2"})
    inst.wait(sid)
    n = nonce()
    message = inst.send(sid, f"ECHO early {n}")
    time.sleep(0.5)
    inst.cli("agent", "interrupt", sid, check=False)
    code, out = inst.wait(sid, "--message", message, timeout=30)
    assert out["status"] != "TIMEOUT", "a message the agent never received is pending forever"
    got = receipts_with(inst, n)
    if out["status"] == "DONE":
        assert len(got) == 1
    else:
        assert code == 3 and not got, (out["status"], len(got))
    assert inst.info(sid)["status"] in ("idle", "exited")
