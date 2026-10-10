"""Agent sessions through the CLI, against the fake harnesses (SPEC AG-1, AG-3, AG-4, AG-10 to AG-17,
and the cut-off turns of AG-22).

A session is controlled headless. These tests never put one in a pane on purpose (test_live.py does):
they check outcomes through the CLI, the fakes' receipts (one line per message the "model" received,
fakes/README.md, "Receipts") and processes. Every message carries a nonce, and delivery is counted by
the receipts that contain it.
"""

import json
import os
import random
import re
import shutil
import stat
import subprocess
import time
import uuid

import pytest

from harness import alive, descendants, login_env, wait_until, zombies

pytestmark = [pytest.mark.sessions, pytest.mark.harness]

KINDS = ["claude", "codex"]
MODEL = {"claude": "haiku", "codex": "gpt-6-luna"}
# How each harness spells "ask before acting" (the fakes accept the real CLIs' values).
ASKING_MODE = {"claude": "default", "codex": "on-request"}
PERMISSION_TRIGGER = {"claude": "ASK_PERMISSION", "codex": "ASK_APPROVAL"}
HARNESS_ARGS = {"claude": ["--add-dir", "/tmp"], "codex": ["-c", "model_verbosity=low"]}
FAILED = {"INTERRUPTED", "FAILED", "STOPPED", "ERROR", "CANCELLED"}
FINAL = FAILED | {"DONE"}


# ---- helpers (test_live.py, test_robustness.py and test_chaos.py use them too) --------------------

def nonce():
    return uuid.uuid4().hex[:10]


def fake_args(inst):
    """The `--env` options that point a session at this instance's fake state (start_agent adds them)."""
    return ["--env", "FAKE_AGENT_DIR=" + inst.fake_dir, "--env", "CLAUDE_CONFIG_DIR=" + inst.claude_config]


@pytest.fixture
def started(inst):
    """Start sessions for one test (headless, no placement); every one of them is stopped afterwards."""
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
    """The message carrying `marker` reached the model exactly once; its receipt."""
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


def wait_status(inst, sid, wanted, timeout=15):
    wanted = {wanted} if isinstance(wanted, str) else set(wanted)
    return wait_until(lambda: status(inst, sid) in wanted and status(inst, sid), timeout,
                      message=f"status {' or '.join(sorted(wanted))}")


def stop(inst, sid):
    inst.cli("agent", "stop", sid, timeout=60)
    wait_status(inst, sid, ("stopped", "error"), 30)


def pane_ids(inst):
    return {p["id"] for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"]}


def session_receipts(inst, hid, since=0.0):
    return [r for r in inst.receipts() if r["session"] == hid and r["ts"] > since]


def harness_id(inst, sid):
    return wait_until(lambda: inst.info(sid).get("harness_id"), 20, message="the agent's own session id")


def redirect(inst, sid, text):
    return inst.json("agent", "send", sid, "--interrupt", text)["message"]["id"]


def json_in(text):
    """The JSON document that ends a command's output (a RUN reply also has its exit line, and the
    stderr hints of the commands it ran)."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("{"):
            try:
                return json.loads("\n".join(lines[i:]))
            except json.JSONDecodeError:
                continue
    raise AssertionError(f"no JSON in {text!r}")


# ---- AG-1: launching --------------------------------------------------------------------------------

@pytest.mark.req("AG-1", "AG-10", "AG-12", "AG-14")
@pytest.mark.parametrize("kind", KINDS)
def test_start_prints_the_id_and_shows_nothing(inst, started, kind):
    n = nonce()
    name = f"plain-{n}"
    before = pane_ids(inst)
    proc = inst.cli("agent", "start", kind, "--cwd", inst.work, *fake_args(inst), "--name", name, f"ECHO first {n}")
    sid = proc.stdout.strip()
    started.ids.append(sid)
    assert len(proc.stdout.splitlines()) == 1 and len(sid) >= 8, f"stdout is just the session id: {proc.stdout!r}"
    proc = inst.cli("agent", "wait", sid, "--timeout", "60", check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert proc.stdout.splitlines()[0] == "DONE"
    assert f"ECHO first {n}" in proc.stdout
    assert inst.cli("agent", "read", sid).stdout.strip() == f"ECHO first {n}"
    info = inst.info(sid)
    assert (info["status"], info["kind"], info["location"], info["origin"]) == ("idle", kind, "background", "started")
    assert pane_ids(inst) == before and not inst.session_panes(sid), "without a placement nothing appears on screen"
    receipt = delivered_once(inst, n)
    # The agent's own session (thread) id is the session's harness_id, and selects the session, as do a
    # unique id prefix and the name.
    assert info["harness_id"] == receipt["session"]
    assert inst.info(info["harness_id"])["id"] == sid
    assert inst.info(sid[:8])["id"] == sid
    assert inst.info(name)["id"] == sid


@pytest.mark.req("AG-1", "AG-4")
@pytest.mark.parametrize("kind", KINDS)
def test_start_options_reach_the_agent(inst, started, kind):
    value = "v-" + nonce()
    sid = started(kind, None, "--model", MODEL[kind], "--effort", "low", "--full-access", "--env",
                  f"ACC_VALUE={value}", "--", *HARNESS_ARGS[kind])
    inst.send(sid, "STATE")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    state = json.loads(out["reply"])
    assert state["model"] == MODEL[kind]
    assert state["effort"] == "low"
    assert state["full_access"] is True
    assert os.path.realpath(state["cwd"]) == os.path.realpath(inst.work)
    joined = " ".join(state["argv"])
    assert all(a in joined for a in HARNESS_ARGS[kind]), f"arguments after -- are the agent's: {state['argv']}"
    inst.send(sid, "PRINTENV ACC_VALUE")
    assert inst.wait(sid)[1]["reply"] == value


@pytest.mark.req("AG-1", "L-5")
def test_start_in_a_new_worktree(inst, started, tmp_path):
    repo = str(tmp_path / "repo")
    subprocess.run(["git", "init", "-q", repo], check=True)
    subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty",
                    "-m", "init"], check=True)
    branch = "agent-" + nonce()
    sid = inst.json("agent", "start", "claude", "--cwd", repo, "--worktree", branch, *fake_args(inst),
                    "RUN pwd; git branch --show-current")["session"]["id"]
    started.ids.append(sid)
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    lines = out["reply"].splitlines()
    assert lines[0] == "exit=0"
    assert os.path.realpath(lines[1]) != os.path.realpath(repo)
    assert lines[2] == branch


@pytest.mark.req("AG-1", "T-1")
def test_text_from_stdin_and_after_separator(inst, started):
    n = nonce()
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "-",
                    stdin=f"ECHO from stdin {n}\n")["session"]["id"]
    started.ids.append(sid)
    assert inst.wait(sid)[1]["reply"] == f"ECHO from stdin {n}"
    inst.cli("agent", "send", sid, "-", stdin="ECHO piped text\n")
    assert inst.wait(sid)[1]["reply"] == "ECHO piped text"
    inst.cli("agent", "send", sid, "--", "ECHO --flag-looking text")
    assert inst.wait(sid)[1]["reply"] == "ECHO --flag-looking text"


@pytest.mark.req("AG-1")
def test_no_command_waits_on_stdin_unless_asked(inst, started):
    sid = started("claude", "ECHO x")
    inst.wait(sid)
    for args in (["agent", "start", "claude", *fake_args(inst)], ["agent", "start", "codex", "ECHO y", *fake_args(inst)],
                 ["agent", "info", sid], ["agent", "ls"], ["agent", "read", sid], ["agent", "wait", sid],
                 ["agent", "send", sid, "ECHO z"]):
        proc = subprocess.Popen([inst.target.cli_path, "--json", *args], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=inst.env, cwd=inst.work, text=True)
        try:
            out, _ = proc.communicate(timeout=30)   # stdin stays open: a reader would hang
        except subprocess.TimeoutExpired:
            proc.kill()
            pytest.fail(f"`{' '.join(args[:3])}` waited on stdin")
        if args[1] == "start" and proc.returncode == 0:
            started.ids.append(json.loads(out)["session"]["id"])


@pytest.mark.req("AG-1", "AG-12")
def test_start_with_wait(inst, started):
    n = nonce()
    proc = inst.cli("agent", "start", "codex", *fake_args(inst), "--name", "sw-" + n, "--wait", "--timeout", "60",
                    f"ECHO waited {n}", check=False)
    started.ids.append("sw-" + n)
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines()[0] == "DONE" and f"ECHO waited {n}" in proc.stdout


@pytest.mark.req("AG-1", "AG-3", "L-4")
def test_bad_requests_fail_clearly(inst):
    for args in (["agent", "start", "gemini", "hi"],
                 ["agent", "start", "claude", "--cwd", "/nonexistent/dir", "hi"],
                 ["agent", "send", "no-such-session-" + nonce(), "hi"],
                 ["agent", "wait", "no-such-session-" + nonce()],
                 ["agent", "read", "no-such-session-" + nonce(), "--transcript", "--last", "-1"]):
        proc = inst.cli(*args, check=False, timeout=30)
        assert proc.returncode == 1, (args, proc.returncode)
        assert proc.stderr.startswith(inst.target.cli_name + ": "), proc.stderr


@pytest.mark.req("AG-1")
def test_session_settings_are_private_to_the_user(inst, started):
    """`--env` values (tokens, say) are stored with the session: only its owner can read them."""
    sid = started("claude", "ECHO private", env={"ACC_TOKEN": "secret-" + nonce()})
    inst.wait(sid)
    for root, _, files in os.walk(inst.dir):
        for name in files:
            path = os.path.join(root, name)
            if "fake-agent" in path or path.endswith("app.log"):
                continue
            try:
                with open(path, "rb") as f:
                    if b"ACC_TOKEN" not in f.read():
                        continue
            except OSError:
                continue
            mode = stat.S_IMODE(os.stat(path).st_mode)
            assert mode & 0o077 == 0, f"{path} is readable by others ({oct(mode)})"


# ---- AG-3: reliable launches ----------------------------------------------------------------------

@pytest.mark.req("AG-3")
@pytest.mark.parametrize("kind", KINDS)
def test_the_first_turn_starts_within_seconds(inst, started, kind):
    n = nonce()
    t0 = time.time()
    started(kind, f"ECHO quick {n}")
    receipt = delivered_once(inst, n, timeout=20)
    assert receipt["ts"] - t0 < 5, f"the first turn started {receipt['ts'] - t0:.1f} s after `agent start`"


@pytest.mark.req("AG-3")
@pytest.mark.parametrize("kind", KINDS)
def test_an_agent_that_is_not_installed_fails_at_once(target, fresh, kind):
    other = fresh(prefix="acc-ag3-", env={target.env_names["claude_bin"]: "/nonexistent/claude",
                                          target.env_names["codex_bin"]: "/nonexistent/codex"})
    t0 = time.time()
    proc = other.cli("--json", "agent", "start", kind, "--cwd", other.work, "ECHO hi", check=False)
    if proc.returncode != 0:
        reason = proc.stderr
    else:
        sid = json.loads(proc.stdout)["session"]["id"]
        code, out = other.wait(sid, timeout=30)
        assert code == 3 and out["status"] in ("ERROR", "FAILED"), out
        reason = out.get("error") or ""
        info = other.info(sid)
        assert info["status"] == "error" and (info.get("error") or "").strip(), info
        proc = other.cli("agent", "send", sid, "ECHO again", check=False)
        if proc.returncode == 0:
            code, out = other.wait(sid, timeout=30)
            assert code == 3 and (out.get("error") or "").strip(), out
    assert time.time() - t0 < 20, "the failure was reported at once"
    assert kind in reason.lower() or "install" in reason.lower() or "found" in reason.lower(), \
        f"the reason doesn't say what's missing: {reason!r}"


def conversation_store(inst, kind, hid):
    if kind == "claude":
        return os.path.join(inst.fake_dir, "claude", f"{hid}.json")
    return os.path.join(inst.fake_dir, "codex", "threads", f"{hid}.json")


@pytest.mark.req("AG-3", "AG-10", "AG-11")
@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("gone", ["folder", "conversation"])
def test_a_send_that_cannot_resume_fails_at_once_and_never_starts_fresh(inst, started, kind, gone, tmp_path):
    cwd = str(tmp_path / f"project-{nonce()}")
    os.makedirs(cwd)
    sid = started(kind, f"ECHO remember {nonce()}", cwd=cwd)
    assert inst.wait(sid)[1]["status"] == "DONE"
    hid = harness_id(inst, sid)
    stop(inst, sid)
    if gone == "folder":
        shutil.rmtree(cwd)
    else:
        store = conversation_store(inst, kind, hid)
        assert os.path.exists(store), "the fake keeps its conversations where fakes/README.md says"
        os.remove(store)
    n = nonce()
    t0 = time.time()
    proc = inst.cli("--json", "agent", "send", sid, f"ECHO after {n}", check=False)
    if proc.returncode == 0:
        message = json.loads(proc.stdout)["message"]["id"]
        code, out = inst.wait(sid, "--message", message, timeout=30)
        assert code == 3 and out["status"] in FAILED, out
        reason = out.get("error") or inst.info(sid).get("error") or ""
        assert inst.info(sid)["status"] == "error", "info says the session can't start"
    else:
        reason = proc.stderr
    assert time.time() - t0 < 20, "the failure was reported at once"
    assert reason.strip(), "the failure says why"
    time.sleep(3)
    assert not receipts_with(inst, n), "the message went to a fresh conversation"


# ---- AG-4: fidelity -------------------------------------------------------------------------------

@pytest.mark.req("AG-4")
@pytest.mark.parametrize("kind", KINDS)
def test_agents_get_a_fresh_login_environment(inst, started, kind):
    markers = {"CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "sdk-ts", "CODEX_THREAD_ID": "stale-thread",
               "CLAUDE_CODE_SESSION_ID": "stale-session"}
    sid = inst.json("agent", "start", kind, "--cwd", inst.work, *fake_args(inst), "RUN env", env=markers)["session"]["id"]
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


@pytest.mark.req("AG-4")
def test_user_agent_config_is_untouched(inst, started):
    watched = [os.path.expanduser(p) for p in ("~/.claude/settings.json", "~/.claude/plugins/installed_plugins.json",
                                               "~/.codex/config.toml", "~/.codex/auth.json")]
    before = {p: os.stat(p).st_mtime_ns for p in watched if os.path.exists(p)}
    for kind in KINDS:
        sid = started(kind, "ECHO config check")
        inst.wait(sid)
    after = {p: os.stat(p).st_mtime_ns for p in watched if os.path.exists(p)}
    assert before == after


@pytest.mark.req("AG-4", "AG-16")
def test_the_cli_inside_an_agent_is_this_builds_cli(inst, started):
    """The CLI on an agent's PATH is the CLI of the app that started it, ahead of any other one on the
    login PATH (an older install would not know the newer commands)."""
    cli = inst.target.cli_name
    sid = started("claude", f"RUN command -v {cli}")
    code, out = inst.wait(sid)
    assert out["reply"].startswith("exit=0"), out
    found = out["reply"].splitlines()[1].strip()
    assert os.path.realpath(found) == os.path.realpath(inst.target.cli_path), found


# ---- AG-10: send, steer, interrupt, resume ---------------------------------------------------------

@pytest.mark.req("AG-10", "AG-11")
@pytest.mark.parametrize("kind", KINDS)
def test_a_message_sent_while_working_steers_the_running_turn(inst, started, kind):
    """"While the session works, the agent sees TEXT during its current turn (steering, at its next
    step)." The fakes take steered input at the next tool boundary of the same turn."""
    a, b = nonce(), nonce()
    sid = started(kind, f"SLEEP 3 {a}")
    first = delivered_once(inst, a, timeout=15)
    wait_status(inst, sid, "working")
    t0 = time.time()
    proc = inst.cli("agent", "send", sid, f"ECHO steer {b}")
    assert time.time() - t0 < 3, "`agent send` prints the message id at once"
    message = proc.stdout.strip()
    assert message and len(proc.stdout.splitlines()) == 1, proc.stdout
    code, out = inst.wait(sid, "--message", message)
    assert (code, out["status"]) == (0, "DONE") and f"ECHO steer {b}" in out["reply"], out
    second = delivered_once(inst, b)
    assert (second["pid"], second["turn"]) == (first["pid"], first["turn"]), \
        "the steered message started a turn of its own instead of reaching the running one"
    assert status(inst, sid) == "idle"


@pytest.mark.req("AG-10", "AG-12", "AG-14")
@pytest.mark.parametrize("kind", KINDS)
def test_a_message_to_an_idle_session_starts_a_turn_and_old_replies_stay(inst, started, kind):
    a, b = nonce(), nonce()
    sid = started(kind, f"ECHO one {a}")
    code, first = inst.wait(sid)
    assert (code, first["status"]) == (0, "DONE")
    m2 = inst.send(sid, f"ECHO two {b}")
    code, out = inst.wait(sid)
    assert (out["status"], out["reply"], out["message"]["id"]) == ("DONE", f"ECHO two {b}", m2)
    ra, rb = delivered_once(inst, a), delivered_once(inst, b)
    assert ra["turn"] != rb["turn"] or ra["pid"] != rb["pid"], "a message to an idle session starts a turn"
    # An older message still reports its own reply, through wait and read.
    m1 = first["message"]["id"]
    code, old = inst.wait(sid, "--message", m1)
    assert (code, old["reply"]) == (0, f"ECHO one {a}")
    assert inst.json("agent", "read", sid, "--message", m1)["reply"] == f"ECHO one {a}"
    # The transcript has both messages, in order, with their ids; --last trims it.
    items = inst.transcript(sid)
    users = [i for i in items if i["kind"] == "user"]
    assert [u.get("message") for u in users][-2:] == [m1, m2]
    texts = [i.get("text") for i in items]
    assert texts.index(f"ECHO one {a}") < texts.index(f"ECHO two {b}")
    last = inst.json("agent", "read", sid, "--transcript", "--last", "2")["items"]
    assert [i["id"] for i in last] == [i["id"] for i in items[-2:]]


@pytest.mark.req("AG-10")
@pytest.mark.parametrize("kind", KINDS)
def test_message_ids_are_the_ones_the_agent_knows(inst, started, kind):
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    n = nonce()
    message = inst.send(sid, f"ECHO {n}")
    code, out = inst.wait(sid, "--message", message)
    assert (code, out["status"]) == (0, "DONE"), out
    assert out["message"]["id"] == message
    receipt = delivered_once(inst, n)
    assert receipt["message"] == message, "the id `agent send` printed is the id the agent echoed for that message"


@pytest.mark.req("AG-10", "AG-11", "AG-15")
@pytest.mark.parametrize("kind", KINDS)
def test_interrupt_goes_first_and_nothing_sent_before_it_is_lost(inst, started, kind):
    """`--interrupt` stops the running turn first, and TEXT is the next thing the agent sees. A message
    sent just before (steered, not taken in yet) is still delivered exactly once."""
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    hid = harness_id(inst, sid)
    a, b, c = nonce(), nonce(), nonce()
    ma = inst.send(sid, f"SLEEP 30 {a}")
    delivered_once(inst, a, timeout=15)
    mb = inst.send(sid, f"ECHO steered {b}")
    time.sleep(0.5)
    before = time.time()
    mc = redirect(inst, sid, f"ECHO redirect {c}")
    code, out = inst.wait(sid, "--message", mc, timeout=60)
    assert out["status"] == "DONE" and c in out["reply"], out
    code, out = inst.wait(sid, "--message", ma, timeout=30)
    assert out["status"] == "INTERRUPTED", out
    first_new = min(session_receipts(inst, hid, before), key=lambda r: r["ts"])
    assert c in first_new["text"], f"the redirect was not the next thing the agent saw: {first_new['text']}"
    code, out = inst.wait(sid, "--message", mb, timeout=60)
    assert out["status"] == "DONE", f"a message sent before the interrupt was lost: {out}"
    delivered_once(inst, b)
    delivered_once(inst, c)


@pytest.mark.req("AG-10", "AG-11")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
def test_an_interrupt_as_the_turn_ends_never_interrupts_the_new_message(inst, started, kind):
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    rng = random.Random(7)
    for _ in range(8):
        x, y = nonce(), nonce()
        inst.send(sid, f"SLEEP 1 {x}")
        time.sleep(rng.uniform(0.6, 1.6))
        my = redirect(inst, sid, f"ECHO redirect {y}")
        code, out = inst.wait(sid, "--message", my, timeout=60)
        assert out["status"] == "DONE" and y in out["reply"], f"the redirect's own turn was hit: {out}"
        delivered_once(inst, y)


@pytest.mark.req("AG-10", "AG-11")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
def test_an_interrupt_gets_through_a_hung_turn(inst, started, kind):
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    h, n = nonce(), nonce()
    inst.send(sid, f"HANG {h}")
    delivered_once(inst, h, timeout=15)
    mn = redirect(inst, sid, f"ECHO after the hang {n}")
    code, out = inst.wait(sid, "--message", mn, timeout=120)
    assert out["status"] == "DONE" and n in out["reply"], out
    delivered_once(inst, n)


@pytest.mark.req("AG-10", "AG-11")
@pytest.mark.parametrize("kind", KINDS)
def test_an_interrupt_survives_its_agent_dying(inst, started, kind):
    """The interrupted turn's agent dies instead of ending the turn: the redirect is delivered after
    the resume, at once."""
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    h = nonce()
    inst.send(sid, f"HANG {h}")
    pid = harness_pid(inst, h)
    r = nonce()
    message = redirect(inst, sid, f"ECHO redirected {r}")
    time.sleep(1)
    os.kill(pid, 9)
    t0 = time.time()
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert out["status"] == "DONE" and r in out["reply"], out
    assert time.time() - t0 < 20, "the redirect waited for a deadline of a turn that was already gone"
    delivered_once(inst, r)


@pytest.mark.req("AG-10", "AG-13")
def test_an_interrupt_during_a_turn_the_agent_started_itself(inst, started):
    sid = started("claude", "ECHO warm-up", env={"FAKE_WAKE_TURN_SECS": "30"})
    inst.wait(sid)
    w = nonce()
    inst.send(sid, f"WAKE 1 {w}")
    wait_until(lambda: any(w in t["text"] for t in inst.self_turns()), 15, message="the self-started turn")
    wait_status(inst, sid, "working")
    r = nonce()
    message = redirect(inst, sid, f"ECHO redirected {r}")
    code, out = inst.wait(sid, "--message", message, timeout=30)
    assert out["status"] == "DONE" and out["reply"] == f"ECHO redirected {r}", out
    delivered_once(inst, r)


@pytest.mark.req("AG-10", "AG-15")
@pytest.mark.parametrize("kind", KINDS)
def test_stop_then_send_resumes_the_conversation(inst, started, kind):
    word = "pomegranate-" + nonce()
    sid = started(kind, f"ECHO remember {word}")
    inst.wait(sid)
    harness = inst.info(sid)["harness_id"]
    stop(inst, sid)
    assert status(inst, sid) == "stopped"
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    assert word in out["reply"]
    assert inst.info(sid)["harness_id"] == harness, "the same conversation, not a fresh one"


@pytest.mark.req("AG-10")
@pytest.mark.parametrize("kind", KINDS)
def test_a_session_that_never_got_a_message_resumes_after_stop(inst, started, kind):
    sid = started(kind, None)
    inst.wait(sid)
    stop(inst, sid)
    n = nonce()
    message = inst.send(sid, f"ECHO first after stop {n}")
    code, out = inst.wait(sid, "--message", message)
    assert out["status"] == "DONE", out
    delivered_once(inst, n)
    inst.send(sid, "RECALL")
    assert n in inst.wait(sid)[1]["reply"]


def assert_same_settings(inst, sid, kind, value, cwd, when):
    inst.send(sid, "STATE")
    code, out = inst.wait(sid, timeout=90)
    assert out["status"] == "DONE", out
    got = json.loads(out["reply"])
    assert got["model"] == MODEL[kind], f"{when}: model {got['model']}"
    assert got["effort"] == "low", f"{when}: effort {got['effort']}"
    assert got["full_access"] is True, f"{when}: full access lost"
    assert os.path.realpath(got["cwd"]) == os.path.realpath(cwd), f"{when}: cwd {got['cwd']}"
    joined = " ".join(got["argv"])
    assert all(a in joined for a in HARNESS_ARGS[kind]), f"{when}: agent arguments lost: {got['argv']}"
    inst.send(sid, "PRINTENV ACC_VALUE")
    assert inst.wait(sid)[1]["reply"] == value, f"{when}: environment lost"


@pytest.mark.req("AG-10", "AG-22", "AG-11")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
def test_every_resume_keeps_context_and_settings(fresh, kind):
    other = fresh(prefix="acc-ag10-")
    value = "v-" + nonce()
    word = "w-" + nonce()
    sid = other.start_agent(kind, None, "--model", MODEL[kind], "--effort", "low", "--full-access",
                            "--env", f"ACC_VALUE={value}", "--", *HARNESS_ARGS[kind])
    other.send(sid, f"ECHO remember {word}")
    assert other.wait(sid)[1]["status"] == "DONE"

    def stopped():
        stop(other, sid)

    def crashed():
        other.send(sid, "CRASH")
        wait_status(other, sid, ("error", "stopped"), 30)

    def product_killed():
        other.kill_everything()
        other.start_app()

    def app_quit():
        other.quit_app()
        other.start_app()

    for when, event in (("after stop", stopped), ("after the agent crashed", crashed),
                        ("after the product was killed", product_killed), ("after the app quit", app_quit)):
        event()
        n = nonce()
        t0 = time.time()
        other.send(sid, f"ECHO back {n}")
        delivered_once(other, n, timeout=30)
        assert time.time() - t0 < 15, f"{when}: the message took {time.time() - t0:.0f} s to reach the agent"
        assert other.wait(sid)[1]["status"] == "DONE"
        other.send(sid, "RECALL")
        code, out = other.wait(sid)
        assert word in out["reply"], f"{when}: context lost: {out['reply']}"
        assert_same_settings(other, sid, kind, value, other.work, when)


# ---- AG-11: exactly once ------------------------------------------------------------------------

@pytest.mark.req("AG-11", "AG-13")
@pytest.mark.parametrize("kind", KINDS)
def test_messages_sent_while_working_are_each_delivered_once_in_order(inst, started, kind):
    a, b = nonce(), nonce()
    sid = started(kind, "SLEEP 3")
    wait_status(inst, sid, "working")
    m2 = inst.send(sid, f"ECHO second {a}")
    m3 = inst.send(sid, f"ECHO third {b}")
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
    assert ra["ts"] <= rb["ts"], "messages reach the agent in the order they were sent"


@pytest.mark.req("AG-11")
def test_messages_racing_the_end_of_a_turn_are_delivered_once(inst, started):
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


@pytest.mark.req("AG-11")
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


@pytest.mark.req("AG-11", "AG-15")
def test_interrupt_before_the_agent_takes_the_message(inst, started):
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
    assert status(inst, sid) in ("idle", "stopped")


@pytest.mark.req("AG-11", "AG-10")
def test_a_message_sent_while_stopping_is_not_lost(inst, started):
    word = "lychee-" + nonce()
    sid = started("claude", f"ECHO remember {word}")
    inst.wait(sid)
    inst.send(sid, "IGNORE_TERM SLEEP 30")
    wait_status(inst, sid, "working")
    inst.cli("agent", "stop", sid)
    n = nonce()
    message = inst.send(sid, f"RECALL {n}")   # while the old process is still dying
    code, out = inst.wait(sid, "--message", message, timeout=40)
    assert out["status"] == "DONE", out
    assert word in out["reply"]
    delivered_once(inst, n)


@pytest.mark.req("AG-11", "AG-22")
@pytest.mark.slow
def test_a_message_the_product_died_while_handing_over_is_delivered_once(fresh):
    """The product is killed after Codex accepted a turn but before the model took its input
    (FAKE_INPUT_DELAY): after the restart the message reaches the model exactly once."""
    other = fresh(prefix="acc-ag11-handover-")
    sid = other.start_agent("codex", None, env={"FAKE_INPUT_DELAY": "4"})
    other.wait(sid)
    n = nonce()
    message = other.send(sid, f"ECHO handed over {n}")
    time.sleep(1.0)
    assert not receipts_with(other, n), "the fake delays the input"
    other.kill_everything()
    other.start_app()
    code, out = other.wait(sid, "--message", message, timeout=60)
    assert out["status"] == "DONE" and out["reply"] == f"ECHO handed over {n}", out
    delivered_once(other, n)


# ---- AG-12: wait ----------------------------------------------------------------------------------

@pytest.mark.req("AG-12")
def test_wait_with_nothing_pending_and_timeouts(inst, started):
    sid = started("claude", None)
    t0 = time.time()
    code, out = inst.wait(sid, timeout=20)
    assert code == 0 and time.time() - t0 < 5, out
    slow = started("claude", "SLEEP 20")
    wait_status(inst, slow, "working")
    proc = inst.cli("agent", "wait", slow, "--timeout", "1", check=False)
    assert proc.returncode == 124
    lines = proc.stdout.splitlines()
    assert lines[0] == "TIMEOUT"
    assert "sleep" in proc.stdout.lower(), f"a timeout says what is still running: {proc.stdout!r}"


@pytest.mark.req("AG-12", "AG-13")
def test_wait_waits_until_background_work_has_settled(inst, started):
    """Claude Code starts a turn by itself when a background command it started finishes (C11wake):
    the message's turn ended, but the session hasn't settled until that turn has."""
    sid = started("claude", "ECHO warm-up")
    inst.wait(sid)
    w = nonce()
    t0 = time.time()
    message = inst.send(sid, f"WAKE 3 {w}")
    code, out = inst.wait(sid, timeout=60)
    assert (code, out["status"]) == (0, "DONE"), out
    assert time.time() - t0 >= 3, "`agent wait` returned before the background command had finished"
    assert any(w in t["text"] for t in inst.self_turns()), "the agent's own turn ran before the wait returned"
    assert any(f"woke: {w}" in (i.get("text") or "") for i in inst.transcript(sid)), \
        "the wait returned before the turn the background work started had ended"
    info = inst.info(sid)
    assert info["status"] == "idle" and not info.get("background_tasks"), info
    assert inst.read_reply(sid, message) == "started", "the self-started turn's reply was taken as the message's"
    code, again = inst.wait(sid, "--message", message, timeout=10)
    assert (code, again["status"]) == (0, "DONE"), again


@pytest.mark.req("AG-12")
def test_a_wait_keeps_its_message_when_someone_sends_more(inst, started):
    sid = started("claude", "ECHO warm-up")
    inst.wait(sid)
    a = nonce()
    inst.send(sid, f"SLEEP 2 {a}")
    proc = subprocess.Popen([inst.target.cli_path, "--json", "agent", "wait", sid, "--timeout", "60"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=inst.env, cwd=inst.work)
    time.sleep(0.5)
    b = nonce()
    inst.send(sid, f"ECHO later {b}")
    out, err = proc.communicate(timeout=90)
    got = json.loads(out)
    assert got["status"] == "DONE" and a in got["message"]["text"], got


@pytest.mark.req("AG-12")
def test_a_timed_out_wait_names_its_own_message(inst, started):
    sid = started("claude", "ECHO warm-up")
    inst.wait(sid)
    first = inst.send(sid, f"SLEEP 5 {nonce()}")
    inst.send(sid, f"ECHO later {nonce()}")
    code, out = inst.wait(sid, "--message", first, timeout=1)
    assert (code, out["status"]) == (124, "TIMEOUT") and out["message"]["id"] == first, out


@pytest.mark.req("AG-12", "AG-15")
def test_a_wait_ends_when_its_session_is_removed(inst, started):
    sid = started("claude", "ECHO hi")
    inst.wait(sid)
    proc = subprocess.Popen([inst.target.cli_path, "--json", "agent", "wait", sid, "--report", "--timeout", "60"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=inst.env, cwd=inst.work)
    time.sleep(1)
    inst.cli("agent", "rm", sid, "--force")
    out, err = proc.communicate(timeout=30)
    assert proc.returncode != 124 and "TIMEOUT" not in out, (out, err)


@pytest.mark.req("AG-12", "AG-22")
@pytest.mark.slow
def test_wait_keeps_waiting_across_an_app_restart(fresh):
    """A supervisor blocked in `agent wait` while the app quits and comes back gets the reply of the
    continued turn, not a dropped connection."""
    other = fresh(prefix="acc-ag12-wait-")
    sid = other.start_agent("claude", "ECHO warm-up")
    other.wait(sid)
    n = nonce()
    message = other.send(sid, f"SLEEP 6 {n}")
    delivered_once(other, n, timeout=15)
    proc = subprocess.Popen([other.target.cli_path, "--json", "agent", "wait", sid, "--message", message,
                             "--timeout", "120"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            env=other.env, cwd=other.work)
    time.sleep(1)
    other.quit_gracefully(timeout=60)
    time.sleep(1)
    other.start_app()
    out, err = proc.communicate(timeout=150)
    assert proc.returncode == 0, (out, err)
    assert json.loads(out)["status"] == "DONE"
    delivered_once(other, n)


# ---- AG-13: truthful status -----------------------------------------------------------------------

@pytest.mark.req("AG-13", "AG-23")
def test_status_is_truthful_and_cheap_while_busy(inst, started):
    sid = started("codex", "SLEEP 4")
    statuses = []
    t0 = time.time()
    while time.time() - t0 < 10:
        s = time.time()
        info = inst.info(sid)
        assert time.time() - s < 2, "agent info stays fast while the agent works"
        statuses.append(info["status"])
        if info["status"] == "idle":
            break
        time.sleep(0.1)
    assert "working" in statuses and statuses[-1] == "idle"
    first_idle = statuses.index("idle")
    assert all(s == "idle" for s in statuses[first_idle:])
    assert all(s in ("starting", "working", "idle") for s in statuses)


@pytest.mark.req("AG-13", "AG-12", "AG-11")
def test_turns_the_agent_starts_itself(inst, started):
    """Claude Code starts a turn by itself when a background command finishes (C11wake). Codex doesn't
    (X15wake)."""
    sid = started("claude", "ECHO warm-up")
    inst.wait(sid)
    w = nonce()
    m1 = inst.send(sid, f"WAKE 4 {w}")
    wait_until(lambda: inst.info(sid)["last_message"]["state"] in ("done", "delivered") and
               inst.json("agent", "read", sid, "--message", m1)["reply"] == "started", 15,
               message="the message's own turn ended")
    info = inst.info(sid)
    assert info.get("background_tasks") == 1, f"a background task still running is shown: {info}"
    pending = set()
    deadline = time.time() + 20
    while time.time() < deadline and not any(w in t.get("text", "") for t in inst.self_turns()):
        pending.add(status(inst, sid))
        time.sleep(0.1)
    assert any(w in t["text"] for t in inst.self_turns()), "the fake started its own turn"
    assert pending == {"working"}, f"while background work that will wake it was pending, the status was {pending}"
    own = set()
    while time.time() < deadline:
        now = status(inst, sid)
        if now == "idle":
            break
        own.add(now)
        time.sleep(0.1)
    assert own <= {"working"}, own
    wait_status(inst, sid, "idle")
    assert inst.read_reply(sid, m1) == "started", "the self-started turn's reply was taken as the message's"
    assert any(f"woke: {w}" in (i.get("text") or "") for i in inst.transcript(sid)), "the turn is in the transcript"
    assert not inst.info(sid).get("background_tasks"), "no background task is left"

    # A message sent while the agent runs a turn of its own gets its own reply, exactly once.
    w2, d = nonce(), nonce()
    inst.send(sid, f"WAKE 2 {w2}")
    wait_until(lambda: any(w2 in t["text"] for t in inst.self_turns()), 15, message="the second self-started turn")
    md = inst.send(sid, f"ECHO during {d}")
    code, out = inst.wait(sid, "--message", md, timeout=60)
    assert out["status"] == "DONE" and inst.read_reply(sid, md) == f"ECHO during {d}", out
    delivered_once(inst, d)


@pytest.mark.req("AG-13", "AG-14")
def test_a_codex_background_command_is_counted_and_never_a_turn(inst, started):
    """Codex runs a long command as a background terminal: its item is still open when the turn
    completes, and its completion arrives later (X15wake). It never wakes Codex, so the session is
    idle, but the task is shown, and messages sent meanwhile get their own replies."""
    n = nonce()
    sid = started("codex", f"BACKGROUND 4 {n}")
    code, out = inst.wait(sid)
    assert (code, out["status"], out["reply"]) == (0, "DONE", "started"), out
    info = inst.info(sid)
    assert info["status"] == "idle", "a background command that will never wake Codex isn't a running turn"
    assert info.get("background_tasks") == 1, info
    d = nonce()
    md = inst.send(sid, f"ECHO meanwhile {d}")
    code, out = inst.wait(sid, "--message", md)
    assert out["status"] == "DONE" and out["reply"] == f"ECHO meanwhile {d}", out
    delivered_once(inst, d)
    wait_until(lambda: not inst.info(sid).get("background_tasks"), 15, message="the background task finished")
    tools = [i for i in inst.transcript(sid) if i["kind"] == "tool" and "sleep 4" in (i.get("detail") or "")]
    assert tools and tools[0]["state"] == "done", tools
    assert status(inst, sid) == "idle"
    assert inst.read_reply(sid, md) == f"ECHO meanwhile {d}"


@pytest.mark.req("AG-13", "AG-15")
def test_a_stopped_background_command_is_not_counted_again(inst, started):
    sid = started("codex", "BACKGROUND 30 bg")
    inst.wait(sid)
    assert inst.info(sid).get("background_tasks") == 1
    inst.cli("agent", "stop", sid)
    n = nonce()
    message = inst.send(sid, f"ECHO after {n}")
    assert inst.wait(sid, "--message", message)[1]["status"] == "DONE"
    assert not inst.info(sid).get("background_tasks"), inst.info(sid)


# ---- AG-14: read, ls, info ------------------------------------------------------------------------

@pytest.mark.req("AG-14", "AG-12")
@pytest.mark.parametrize("kind", KINDS)
def test_what_failed_to_load_is_shown(inst, started, kind):
    sid = started(kind, "ECHO hi", env={"FAKE_MCP": "probe-auth:needs-auth,probe-ok:connected"})
    proc = inst.cli("agent", "wait", sid, "--timeout", "60", check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "probe-auth" in proc.stdout + proc.stderr, "`agent wait` warns about the server that needs auth"
    startup = inst.info(sid)["startup"]
    names = {s["name"] for s in startup.get("mcp_servers", [])}
    assert {"probe-auth", "probe-ok"} <= names, startup
    flags = " ".join(startup["flags"])
    assert "probe-auth" in flags and "probe-ok" not in flags, startup
    assert startup.get("model"), startup
    first = startup["at"]
    stop(inst, sid)
    inst.send(sid, "ECHO again")
    inst.wait(sid)
    assert inst.info(sid)["startup"]["at"] != first, "the report is refreshed when the session resumes"


@pytest.mark.req("AG-14")
def test_ls_and_info_say_what_each_session_is_doing(inst, started):
    """Status and activity, where it is, its parent, its report and the messages waiting."""
    busy = started("codex", "SLEEP 5", name="busy-" + nonce())
    wait_status(inst, busy, "working")
    listed = {s["id"]: s for s in inst.agents()}
    assert busy in listed
    entry = listed[busy]
    for key in ("id", "name", "kind", "status", "activity", "cwd", "location", "requests", "title", "origin"):
        assert key in entry, f"`agent ls` has no {key}: {entry}"
    assert entry["status"] == "working" and "sleep" in entry["activity"].lower(), entry
    assert entry["location"] == "background"
    stop(inst, busy)


# ---- AG-15: interrupt, stop, rm, rename ------------------------------------------------------------

@pytest.mark.req("AG-15", "AG-11")
@pytest.mark.parametrize("kind", KINDS)
def test_interrupt_keeps_the_session_and_messages_sent_meanwhile(inst, started, kind):
    sid = started(kind, "SLEEP 20")
    first = inst.info(sid)["last_message"]["id"]
    wait_status(inst, sid, "working")
    time.sleep(0.5)
    n = nonce()
    steered = inst.send(sid, f"ECHO after interrupt {n}")
    inst.cli("agent", "interrupt", sid)
    code, out = inst.wait(sid, "--message", first, timeout=15)
    assert (code, out["status"]) == (3, "INTERRUPTED"), out
    code, out = inst.wait(sid, "--message", steered, timeout=30)
    assert out["status"] == "DONE", f"a message sent before the interrupt was lost: {out}"
    assert status(inst, sid) == "idle", "the session stays"
    delivered_once(inst, n)


@pytest.mark.req("AG-15", "AG-21")
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
    assert out["status"] in ("INTERRUPTED", "STOPPED"), out
    wait_until(lambda: not alive(harness), 15, message="the agent (it ignores SIGTERM) is gone")
    wait_until(lambda: not alive(child), 15, message="the detached child that ignores SIGTERM is gone")
    assert not [p for p in tree if alive(p)], "every process the agent started is gone"
    assert status(inst, sid) == "stopped"


@pytest.mark.req("AG-15", "AG-21")
def test_names_list_rename_remove(inst, started):
    name = "dup-" + nonce()
    a = started("claude", "ECHO a", name=name)
    proc = inst.cli("agent", "start", "claude", "--name", name, "ECHO b", *fake_args(inst), check=False)
    assert proc.returncode != 0 and proc.stderr.strip(), "a running session keeps its name"
    inst.cli("agent", "rename", a, name + "-2")
    assert inst.info(name + "-2")["id"] == a
    assert any(s["id"] == a for s in inst.agents())
    inst.wait(a)
    n = nonce()
    inst.send(a, f"SLEEP 30 {n}")
    pid = harness_pid(inst, n)
    proc = inst.cli("agent", "rm", a, check=False)
    assert proc.returncode != 0 and proc.stderr.strip(), "removing a running session needs --force"
    inst.cli("agent", "rm", a, "--force")
    assert not any(s["id"] == a for s in inst.agents())
    assert inst.cli("agent", "info", a, check=False).returncode != 0
    wait_until(lambda: not alive(pid), 10, message="the removed session's process is gone")
    wait_until(lambda: not any(p == pid for p, _ in zombies()), 10, message="and reaped (no zombie)")
    # A stopped session gives up its name.
    b = started("claude", "ECHO b", name=name + "-3")
    inst.wait(b)
    stop(inst, b)
    c = started("claude", "ECHO c", name=name + "-3")
    assert inst.info(name + "-3")["id"] == c


@pytest.mark.req("AG-15", "AG-21")
def test_stopping_a_session_that_is_still_starting(inst, started):
    sid = started("codex", "ECHO slow", env={"FAKE_SLOW_START": "3"})
    inst.cli("agent", "stop", sid, timeout=60)
    assert status(inst, sid) in ("stopped", "error")
    time.sleep(4)
    assert status(inst, sid) in ("stopped", "error"), "a stopped session started up afterwards"
    n = nonce()
    message = inst.send(sid, f"ECHO again {n}")
    assert inst.wait(sid, "--message", message)[1]["status"] == "DONE"


@pytest.mark.req("AG-15", "AG-10", "AG-21")
@pytest.mark.parametrize("kind", KINDS)
def test_a_crash_is_an_error_and_a_send_resumes(inst, started, kind):
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
    assert code == 3 and out["status"] in ("ERROR", "FAILED", "STOPPED"), out
    info = inst.info(sid)
    assert info["status"] == "error" and info.get("error"), info
    wait_until(lambda: not alive(child), 15, message="the crashed agent's detached child is cleaned up")
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    assert word in out["reply"]


@pytest.mark.req("AG-11", "AG-15")
@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("chaos", [None, 1, 2], ids=["calm", "chaos1", "chaos2"])
def test_a_message_that_crashed_the_agent_is_not_sent_again(inst, started, kind, chaos):
    """The agent dies right after taking a message in (CRASH). The message was delivered: it ends in a
    failure the caller sees, and is never handed to the agent again (under chaos the agent's last
    notifications may be lost with it, but its conversation records the message)."""
    sid = started(kind, "ECHO warm-up", chaos=chaos)
    inst.wait(sid)
    n = nonce()
    message = inst.send(sid, f"CRASH {n}")
    code, out = inst.wait(sid, "--message", message, timeout=30)
    assert code == 3 and out["status"] in FAILED, out
    time.sleep(5)
    delivered_once(inst, n)
    later = nonce()
    message = inst.send(sid, f"ECHO after the crash {later}")
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert out["status"] == "DONE", out
    delivered_once(inst, n)
    delivered_once(inst, later)


@pytest.mark.req("AG-15", "AG-13")
@pytest.mark.parametrize("kind", KINDS)
def test_an_agent_exiting_on_its_own(inst, started, kind):
    word = "kumquat-" + nonce()
    sid = started(kind, f"ECHO {word} EXIT_CLEAN")
    inst.wait(sid)
    wait_status(inst, sid, ("stopped", "error", "idle"))
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE" and word in out["reply"], out


@pytest.mark.req("AG-12", "AG-13")
def test_a_failed_turn(inst, started):
    sid = started("codex", "FAIL")
    code, out = inst.wait(sid)
    assert (code, out["status"]) == (3, "FAILED"), out
    inst.send(sid, "ECHO still usable")
    assert inst.wait(sid)[1]["status"] == "DONE"


# ---- AG-16: agents supervise agents ----------------------------------------------------------------

@pytest.mark.req("AG-16")
def test_self_and_parent(inst, started):
    cli = inst.target.cli_name
    sid = started("claude", f"RUN {cli} --json agent info self")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    assert json_in(out["reply"])["id"] == sid
    child = "child-" + nonce()
    inst.send(sid, f"RUN {cli} agent start codex --name {child} 'ECHO from the child' && "
                   f"{cli} agent wait {child} --timeout 60 >/dev/null && {cli} --json agent ls --parent self")
    code, out = inst.wait(sid)
    assert out["reply"].startswith("exit=0"), out
    listed = json_in(out["reply"])["sessions"]
    assert [s["name"] for s in listed] == [child], listed
    info = inst.info(child)
    assert info["kind"] == "codex" and info.get("parent") == sid
    assert [s["name"] for s in inst.json("agent", "ls", "--parent", sid)["sessions"]] == [child]
    assert not inst.session_panes(info["id"]), "a session an agent starts shows nothing on screen"
    inst.cli("agent", "stop", child, check=False)


@pytest.mark.req("AG-16")
@pytest.mark.parametrize("boss,worker", [("claude", "codex"), ("codex", "claude")])
def test_agents_orchestrate_agents(inst, started, boss, worker):
    cli = inst.target.cli_name
    n = nonce()
    child = "sub-" + n
    script = (f"{cli} agent start {worker} --name {child} 'ECHO hello {n}' >/dev/null && "
              f"{cli} agent wait {child} --timeout 60 && "
              f"{cli} agent send {child} 'ECHO again {n}' >/dev/null && "
              f"{cli} agent wait {child} --timeout 60 && {cli} agent read {child}")
    sid = started(boss, f"RUN {script}")
    code, out = inst.wait(sid, timeout=150)
    assert out["status"] == "DONE", out
    assert out["reply"].startswith("exit=0"), out["reply"]
    assert f"ECHO hello {n}" in out["reply"] and out["reply"].rstrip().endswith(f"ECHO again {n}")
    assert any(s.get("name") == child for s in inst.agents()), "the worker is a session of this very instance"
    inst.cli("agent", "stop", child, check=False)


@pytest.mark.req("AG-16")
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
    got = wait_until(notified, 40, message="the supervisor gets a message about its worker")
    assert len(got) == 1, "notified once per watched turn"
    code, out = inst.wait(boss)
    assert out["status"] == "DONE"


@pytest.mark.req("AG-16")
def test_watching_a_finished_turn_notifies_at_once(inst, started):
    """A supervisor that starts watching after the worker finished must not sleep forever."""
    boss = started("claude", "ECHO boss")
    inst.wait(boss)
    worker_name = "w-" + nonce()
    worker = started("codex", "ECHO done already", name=worker_name)
    inst.wait(worker)
    harness = inst.info(boss)["harness_id"]
    inst.cli("agent", "watch", worker, "--notify", boss)
    got = wait_until(lambda: [x for x in inst.receipts() if x["session"] == harness and worker_name in x["text"]],
                     20, message="the supervisor is told at once")
    assert len(got) == 1


@pytest.mark.req("AG-16", "AG-12")
@pytest.mark.parametrize("kind", KINDS)
def test_workers_report_and_supervisors_wait_for_reports(inst, started, kind):
    cli = inst.target.cli_name
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    n1 = nonce()
    inst.send(sid, f"RUN {cli} agent report done all-good-{n1}")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE" and out["reply"].startswith("exit=0"), out
    report = inst.info(sid)["report"]
    assert report["verdict"] == "done" and n1 in report["summary"] and report["at"]
    listed = next(s for s in inst.agents() if s["id"] == sid)
    assert listed["report"]["verdict"] == "done"

    # A report counts only if it came after the latest message.
    inst.send(sid, f"ECHO next {nonce()}")
    inst.wait(sid)
    proc = inst.cli("--json", "agent", "wait", sid, "--report", "--timeout", "3", check=False, timeout=60)
    assert proc.returncode == 124, proc.stdout + proc.stderr

    for verdict, exit_code in (("blocked", 2), ("failed", 3), ("done", 0)):
        n = nonce()
        inst.send(sid, f"RUN {cli} agent report {verdict} summary-{n}")
        proc = inst.cli("--json", "agent", "wait", sid, "--report", "--timeout", "60", check=False, timeout=120)
        assert proc.returncode == exit_code, proc.stdout + proc.stderr
        got = json.loads(proc.stdout)
        assert got["report"]["verdict"] == verdict and n in got["report"]["summary"]
        assert got["session"]["status"], "the wait also says what the agent is doing"
        inst.wait(sid)


@pytest.mark.req("AG-16", "AG-1", "AG-5")
def test_workers_run_in_the_background_and_their_orchestrator_finds_them(inst, win, started):
    """`agent start` shows nothing, also when an agent starts its own workers. The orchestrator lists
    its workers (`agent ls --parent self`), sees their state and replies, and can show one in a pane
    (`agent open`: a new tab that takes no focus)."""
    cli = inst.target.cli_name
    n = nonce()
    w1, w2 = f"bg-one-{n}", f"bg-two-{n}"
    boss = started("claude", "ECHO boss", name=f"boss-{n}")
    assert inst.wait(boss)[1]["status"] == "DONE"
    script = (f"{cli} agent start codex --name {w1} 'ECHO one {n}' >/dev/null && "
              f"{cli} agent start claude --name {w2} 'ECHO two {n}' >/dev/null && "
              f"{cli} agent wait {w1} --timeout 60 >/dev/null && {cli} agent wait {w2} --timeout 60 >/dev/null && "
              f"{cli} --json agent ls --parent self")
    inst.send(boss, f"RUN {script}")
    code, out = inst.wait(boss, timeout=150)
    try:
        assert out["status"] == "DONE" and out["reply"].startswith("exit=0"), out
        listed = json_in(out["reply"])["sessions"]
        assert sorted(s["name"] for s in listed) == sorted([w1, w2]), listed
        assert all(s["status"] == "idle" and s["location"] == "background" for s in listed), listed
        ids = {s["name"]: s["id"] for s in listed}
        assert not inst.session_panes(boss) and not inst.session_panes(ids[w1]) and not inst.session_panes(ids[w2])
        assert f"ECHO one {n}" in inst.cli("agent", "read", w1).stdout

        inst.cli("pane", "focus", win["pane"])
        before = inst.json("ls")
        opened = inst.json("agent", "open", w1, "--window", win["window"])
        after = inst.json("ls")
        assert (after["current_tab"], after["current_pane"]) == (before["current_tab"], before["current_pane"])
        panes = inst.session_panes(ids[w1])
        assert [p["id"] for p in panes] == [opened["pane"]], panes
        info = inst.info(w1)
        assert info.get("pane") == opened["pane"] and info["location"] == "pane", info
        assert "pane" not in inst.info(w2)
    finally:
        for name in (w1, w2):
            inst.cli("agent", "stop", name, check=False, timeout=60)


@pytest.mark.req("AG-16")
def test_a_session_knows_its_situation(inst, started):
    """"A session knows its situation without being told: its name and id, parent, folder, that nobody
    may be watching, and how to report and reach other sessions." The fake Claude shows what it was
    told on its command line (STATE's argv); both fakes show their environment."""
    cli = inst.target.cli_name
    boss = started("claude", "ECHO boss")
    inst.wait(boss)
    name = "situated-" + nonce()
    inst.send(boss, f"RUN {cli} agent start claude --name {name} STATE >/dev/null && {cli} agent wait {name} "
                    f"--timeout 60 >/dev/null && {cli} agent read {name}")
    code, out = inst.wait(boss, timeout=120)
    assert out["reply"].startswith("exit=0"), out
    argv = json_in(out["reply"])["argv"]
    told = " ".join(argv)
    worker = inst.info(name)
    for fact in (name, worker["id"], boss, os.path.realpath(inst.work), "agent report"):
        assert fact in told or fact.replace("/private", "") in told, f"the worker isn't told {fact!r}: {told[:600]}"
    assert re.search(r"no(body| person| one)[^.]*watch", told, re.I), "the worker isn't told nobody may be watching"
    assert "background" in told and "--parent self" in told, \
        "the worker isn't told that the sessions it starts run in the background, and how to find them"
    inst.cli("agent", "stop", name, check=False)
    codex = started("codex", f"RUN {cli} --json agent info self")
    code, out = inst.wait(codex)
    assert json_in(out["reply"])["id"] == codex, "`self` names the session, in Codex too"


@pytest.mark.req("AG-16", "AG-20")
def test_the_help_is_short_plain_and_says_workers_run_in_the_background(inst):
    """"The help is short and plain; errors say what to do instead.\""""
    text = inst.cli("agent", "--help").stdout
    assert len(text.splitlines()) <= 60, f"`agent --help` is {len(text.splitlines())} lines"
    for command in ("agent start", "agent send", "agent wait", "agent read", "agent ls", "agent stop",
                    "agent interrupt", "agent report", "--parent", "--interrupt"):
        assert command in text, f"`agent --help` doesn't mention {command}"
    assert "background" in text and "agent open" in text
    for args in (["agent", "wait"], ["agent", "send"], ["agent", "start"], ["agent", "start", "gpt", "x"]):
        proc = inst.cli(*args, check=False)
        assert proc.returncode != 0 and proc.stderr.strip(), args
        assert "agent" in proc.stderr or "claude" in proc.stderr, f"`{' '.join(args)}` doesn't say what to do: {proc.stderr}"


# ---- AG-17: approvals and questions ----------------------------------------------------------------

@pytest.mark.req("AG-17", "AG-12", "AG-13")
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
    assert "fake_" in request["detail"], "the request says exactly what would be allowed"
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


@pytest.mark.req("AG-17")
@pytest.mark.parametrize("kind", KINDS)
def test_full_access_never_asks(inst, started, kind):
    sid = started(kind, PERMISSION_TRIGGER[kind], "--full-access")
    code, out = inst.wait(sid)
    assert (code, out["status"]) == (0, "DONE"), out


@pytest.mark.req("AG-17")
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
    assert status(inst, sid) == "needs_input"
    inst.cli("agent", "answer", sid, "--answer", "1=blue", "--answer", f"{request['questions'][1]['id']}=L")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE", out
    expected = ("answers: Favorite color?=blue; Which size?=L" if kind == "claude"
                else "answers: q_color=blue; q_size=L")
    assert out["reply"] == expected


@pytest.mark.req("AG-17")
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


@pytest.mark.req("AG-17", "AG-13")
@pytest.mark.parametrize("kind", KINDS)
def test_withdrawn_requests_disappear(inst, started, kind):
    sid = started(kind, PERMISSION_TRIGGER[kind], "--permission-mode", ASKING_MODE[kind])
    assert inst.wait(sid)[0] == 2
    inst.cli("agent", "interrupt", sid)
    wait_until(lambda: not inst.info(sid)["requests"], 10, message="the withdrawn request is gone")
    assert status(inst, sid) != "needs_input"


# ---- AG-22 (and AG-3): turns cut off by a quit or crash --------------------------------------------

@pytest.mark.req("AG-22", "AG-11", "AG-12")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("how", ["product killed", "quit"])
def test_cut_off_turns_continue_by_themselves(fresh, kind, how):
    other = fresh(prefix="acc-ag22-")
    sid = other.start_agent(kind, "ECHO warm-up")
    other.wait(sid)
    hid = harness_id(other, sid)
    c = nonce()
    mc = other.send(sid, f"SLEEP {30 if how == 'product killed' else 8} {c}")
    delivered_once(other, c, timeout=15)
    wait_status(other, sid, "working")
    cut = time.time()
    pid = receipts_with(other, c)[0]["pid"]
    if how == "product killed":
        other.kill_everything()
    else:
        other.quit_gracefully(timeout=60)
    survived = alive(pid)   # a design may keep agents running while the app is gone
    other.start_app()
    code, out = other.wait(sid, "--message", mc, timeout=120)
    assert out["status"] == "DONE" and out.get("reply"), f"the cut-off message didn't end with a reply: {out}"
    delivered_once(other, c)
    if not survived:
        notes = [r for r in session_receipts(other, hid, cut) if c not in r["text"]]
        assert notes, "the session didn't continue by itself"
        note = notes[0]["text"]
        assert len(note) > 40 and re.search(r"\d{1,2}:\d{2}", note), f"the note doesn't say when: {note!r}"
        assert re.search(r"stop", note, re.I), f"the note doesn't say what it had running was stopped: {note!r}"


@pytest.mark.req("AG-22", "AG-13")
@pytest.mark.slow
def test_a_cut_off_turn_the_agent_started_itself_continues(fresh):
    other = fresh(prefix="acc-ag22-wake-")
    sid = other.start_agent("claude", "ECHO warm-up", env={"FAKE_WAKE_TURN_SECS": "20"})
    other.wait(sid)
    w = nonce()
    other.send(sid, f"WAKE 1 {w}")
    wait_until(lambda: any(w in t["text"] for t in other.self_turns()), 15, message="the self-started turn began")
    wait_status(other, sid, "working")
    hid = other.info(sid)["harness_id"]
    cut = time.time()
    other.kill_everything()
    other.start_app()
    wait_until(lambda: session_receipts(other, hid, cut), 30, message="the session continued by itself")
    note = session_receipts(other, hid, cut)[0]["text"]
    assert "cut off" in note, note
    wait_status(other, sid, "idle", 30)


@pytest.mark.req("AG-22", "AG-3")
@pytest.mark.slow
def test_a_cut_off_turn_whose_conversation_is_gone_fails_at_once(fresh):
    other = fresh(prefix="acc-ag22-gone-")
    sid = other.start_agent("codex", "ECHO warm-up")
    other.wait(sid)
    hid = other.info(sid)["harness_id"]
    n = nonce()
    message = other.send(sid, f"SLEEP 30 {n}")
    delivered_once(other, n, timeout=15)
    other.kill_everything()
    time.sleep(1)
    os.remove(os.path.join(other.fake_dir, "codex", "threads", f"{hid}.json"))
    other.start_app()
    code, out = other.wait(sid, "--message", message, timeout=60)
    assert code == 3 and out["status"] in ("ERROR", "FAILED"), out
    assert (out.get("error") or "").strip(), out


@pytest.mark.req("AG-22", "AG-3")
@pytest.mark.slow
def test_a_cut_off_turn_whose_folder_is_gone_fails_at_once(fresh, tmp_path):
    other = fresh(prefix="acc-ag22-nofolder-")
    folder = str(tmp_path / "project")
    os.makedirs(folder)
    sid = other.start_agent("claude", "ECHO warm-up", cwd=folder)
    other.wait(sid)
    n = nonce()
    message = other.send(sid, f"SLEEP 30 {n}")
    delivered_once(other, n, timeout=15)
    other.kill_everything()
    shutil.rmtree(folder)
    other.start_app()
    code, out = other.wait(sid, "--message", message, timeout=30)
    assert code == 3 and out["status"] == "ERROR" and "folder" in (out.get("error") or ""), out


@pytest.mark.req("AG-22")
def test_installing_an_update_now_asks_before_cutting_turns_off(inst, started):
    """"An update installs while turns run only if the user agrees": `update --now` refuses while a
    turn runs, and says how to agree."""
    sid = started("claude", "SLEEP 20")
    wait_status(inst, sid, "working")
    proc = inst.cli("update", "--now", check=False, timeout=60)
    assert proc.returncode != 0 and "--force" in proc.stderr, proc.stdout + proc.stderr
    assert status(inst, sid) == "working", "the turn keeps running"
    assert inst.app_running()
