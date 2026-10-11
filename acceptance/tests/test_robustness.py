"""Robustness: orphans, crashes, restarts and long runs of agent sessions (SPEC AG-21, AG-22, AG-23), and
the app's own robustness (SPEC R): restarts, paths, isolation, stale environments."""

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid

import pytest

from harness import Instance, alive, processes_of_bundle, wait_until, zombies
from test_sessions import fake_args, json_in

pytestmark = pytest.mark.robustness


def nonce():
    return uuid.uuid4().hex[:10]


def receipt_pid(inst, marker):
    return wait_until(lambda: next((r["pid"] for r in inst.receipts() if marker in r["text"]), None), 15,
                      message="a harness pid")


def stubborn_child(inst):
    path = os.path.join(inst.fake_dir, "stubborn.pid")
    pid = int(wait_until(lambda: os.path.exists(path) and open(path).read().strip(), 15, message="a detached child"))
    os.remove(path)
    return pid


def gone(pids, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline and any(alive(p) for p in pids):
        time.sleep(0.2)
    return not any(alive(p) for p in pids)


# ---- AG-21: no orphans -----------------------------------------------------------------------------

def running(session):
    """A session listed as running: one that isn't stopped or failed."""
    return session.get("status") not in ("stopped", "error")


@pytest.mark.req("AG-21")
@pytest.mark.harness
def test_quitting_the_app_leaves_no_unowned_processes(fresh):
    """Sessions may keep running after the app quits, or stop with it. Either way, nothing keeps
    running that the product no longer owns: "Every process started for a session belongs to a session
    listed as running, or is gone." """
    other = fresh(prefix="acc-r1q-")
    n = nonce()
    sid = other.start_agent("claude", f"IGNORE_TERM SPAWN_STUBBORN SLEEP 60 {n}")
    pids = [receipt_pid(other, n), stubborn_child(other)]
    other.quit_app()
    time.sleep(3)
    if not gone(pids, 20):
        proc = other.cli("--json", "agent", "ls", check=False, timeout=60)
        assert proc.returncode == 0, "session processes outlived the app, and the CLI can't reach their owner"
        listed = {s["id"] for s in json.loads(proc.stdout)["sessions"] if running(s)}
        assert sid in listed, "session processes outlived the app without a running session owning them"
        other.cli("agent", "stop", sid, timeout=60)
        assert gone(pids, 20), "`agent stop` after the app quit left processes running"


@pytest.mark.req("AG-21", "AG-22")
@pytest.mark.harness
def test_killing_the_product_leaves_nothing_running_once_it_is_back(fresh):
    other = fresh(prefix="acc-r1k-")
    n = nonce()
    other.start_agent("codex", f"IGNORE_TERM SPAWN_STUBBORN SLEEP 60 {n}")
    pids = [receipt_pid(other, n), stubborn_child(other)]
    other.kill_everything()
    other.start_app()
    assert gone(pids, 30), "processes of a killed product's sessions were never cleaned up"


@pytest.mark.req("AG-21")
@pytest.mark.harness
def test_no_zombies_accumulate(inst):
    for _ in range(5):
        sid = inst.start_agent("codex", "ECHO short-lived")
        inst.wait(sid)
        inst.cli("agent", "rm", sid, "--force")
    time.sleep(2)
    product = set(processes_of_bundle(inst.target.app))
    first = {z for z in zombies() if z[1] in product}
    # A child caught between its exit and its parent's wait isn't accumulating: what counts is a zombie
    # still there a few seconds later.
    time.sleep(5)
    left = first & set(zombies())
    details = subprocess.run(["ps", "-o", "pid=,ppid=,stat=,lstart=,command=", "-p",
                              ",".join(str(p) for z in left for p in z) or "1"],
                             capture_output=True, text=True).stdout
    assert not left, f"zombie children of the product:\n{details}"


@pytest.mark.req("AG-21")
@pytest.mark.slow
@pytest.mark.harness
def test_quitting_right_after_an_agent_crash_leaves_nothing(fresh):
    """The agent crashes and the app quits while its detached child is still being cleaned up: the
    child must not survive the quit."""
    other = fresh(prefix="acc-ag21-crashquit-")
    sid = other.start_agent("claude", "ECHO warm-up")
    other.wait(sid)
    other.send(sid, "SPAWN_STUBBORN")
    other.wait(sid)
    child = stubborn_child(other)
    other.send(sid, "CRASH")
    other.wait(sid)
    other.quit_gracefully(timeout=60)
    wait_until(lambda: not alive(child), 10, message="the detached child is gone after the quit")


# ---- AG-22, R-3: crashes and restarts ------------------------------------------------------------

def remember(inst, kind):
    word = f"{kind}-word-{nonce()}"
    sid = inst.start_agent(kind, f"ECHO remember {word}", name=f"r-{kind}-{nonce()}")
    inst.wait(sid)
    n = nonce()
    inst.send(sid, f"ECHO second {n}")
    inst.wait(sid)
    return sid, word


@pytest.mark.req("AG-22", "AG-11", "AG-10")
@pytest.mark.harness
def test_crash_recovery(fresh):
    other = fresh(prefix="acc-r2-")
    sessions = [remember(other, kind) for kind in ("claude", "codex")]
    before = {sid: [i["id"] for i in other.transcript(sid)] for sid, _ in sessions}
    busy = sessions[0][0]
    other.send(busy, f"SLEEP 30 {nonce()}")
    wait_until(lambda: other.info(busy)["status"] == "working", 10, message="working")
    other.kill_everything()
    other.start_app()
    listed = {s["id"] for s in other.agents()}
    assert {sid for sid, _ in sessions} <= listed, "every session is listed after the crash"
    for sid, word in sessions:
        other.send(sid, "RECALL")
        code, out = other.wait(sid, timeout=90)
        assert out["status"] == "DONE", out
        assert word in out["reply"]
        items = [i["id"] for i in other.transcript(sid)]
        assert items[:len(before[sid])] == before[sid], "earlier transcript entries kept, in order"
        assert len(items) == len(set(items)), "no transcript entry reused"
    deliveries = [(r["session"], r["text"]) for r in other.receipts()]
    assert len(deliveries) == len(set(deliveries)), "no message delivered twice"


@pytest.mark.req("AG-22", "AG-10")
@pytest.mark.harness
def test_restart_resumes_sessions(fresh):
    other = fresh(prefix="acc-r3-")
    sessions = [remember(other, kind) for kind in ("claude", "codex")]
    other.quit_app()
    other.start_app()
    for sid, word in sessions:
        other.send(sid, "RECALL")
        code, out = other.wait(sid, timeout=90)
        assert out["status"] == "DONE" and word in out["reply"], out


@pytest.mark.req("R-3", "L-2")
def test_restart_restores_pins_and_names(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-r3p-", restore=True)
    pane = other.cli("tab", "new", "--name", "kept-name").stdout.strip()
    tab = other.json("pane", "info", pane)["tab"]
    other.cli("tab", "pin", tab)
    other.quit_app()
    other.start_app()
    tabs = [t for w in other.tree()["windows"] for t in w["tabs"]]
    kept = [t for t in tabs if t.get("name") == "kept-name"]
    assert kept and kept[0]["pinned"]


@pytest.mark.req("AG-22", "AG-11")
@pytest.mark.harness
def test_a_partial_log_line_left_by_a_crash_loses_nothing_after_it(fresh):
    """A crash can cut the last line of a session's log short. Entries written after the restart must
    still be read back at the next one. (Tern-specific: it keeps each session in sessions/<id>/log.jsonl.)"""
    other = fresh(prefix="acc-ag22-partial-")
    sid = other.start_agent("claude", "ECHO first")
    other.wait(sid)
    other.quit_app()
    log = os.path.join(other.dir, "sessions", sid, "log.jsonl")
    if not os.path.exists(log):
        pytest.skip("this build keeps no sessions/<id>/log.jsonl")
    with open(log, "a") as f:
        f.write('{"m": {"id": "cut-sho')
    other.start_app()
    n = nonce()
    message = other.send(sid, f"ECHO after the cut {n}")
    other.wait(sid, "--message", message)
    other.quit_app()
    other.start_app()
    assert other.read_reply(sid, message) == f"ECHO after the cut {n}"


# ---- R-4 ----------------------------------------------------------------------------------------

def spaced_instance(fresh):
    base = os.path.realpath(tempfile.mkdtemp(prefix="acc r4 "))
    state = os.path.join(base, "state dir with spaces", "x" * 90)
    assert len(state) > 104
    other = fresh(state_dir=state)
    work = os.path.join(base, "work dir with spaces")
    os.makedirs(work)
    return base, other, work


@pytest.mark.req("R-4")
def test_paths_with_spaces_and_long_state_dirs(target, fresh):
    base, other, work = spaced_instance(fresh)
    pane = other.cli("tab", "new", "--cwd", work).stdout.strip()
    wait_until(lambda: os.path.realpath(other.json("pane", "info", pane).get("cwd") or "") == work, 10,
               message="a pane in a folder with spaces")
    other.cli("send", "--pane", pane, "-e", "echo spaced-$((40+2))")
    other.cli("wait", "--pane", pane, "--pattern", "^spaced-42", "--timeout", "15")
    inner = other.cli("send", "--pane", pane, "-e", f"{other.target.cli_name} pane rename spaced-ok; echo RENAMED")
    other.cli("wait", "--pane", pane, "--pattern", "^RENAMED", "--timeout", "15")
    assert other.json("pane", "info", pane).get("name") == "spaced-ok", "the CLI inside the pane reaches its app"
    shutil.rmtree(base, ignore_errors=True)


@pytest.mark.req("R-4", "AG-1")
@pytest.mark.harness
def test_agents_with_spaces_and_long_state_dirs(target, fresh):
    base, other, work = spaced_instance(fresh)
    sid = other.json("agent", "start", "claude", "--cwd", work, *fake_args(other), "RUN pwd")["session"]["id"]
    code, out = other.wait(sid)
    assert out["status"] == "DONE" and os.path.realpath(out["reply"].splitlines()[1]) == work, out
    pane = other.cli("tab", "new", "--cwd", work).stdout.strip()
    wait_until(lambda: os.path.realpath(other.json("pane", "info", pane).get("cwd") or "") == work, 10,
               message="a pane in a folder with spaces")
    shutil.rmtree(base, ignore_errors=True)


@pytest.mark.req("R-4")
def test_builds_from_a_path_with_spaces(target, tmp_path):
    if not target.build_cli:
        pytest.skip("the target file has no build_cli command")
    src = os.path.join(tmp_path, "src with spaces")
    out = os.path.join(tmp_path, "out dir", "cli")
    command = target.subst(target.build_cli["command"], src=src, out=out)
    shutil.copytree(target.build_cli["source"], src)
    proc = subprocess.run(command, capture_output=True, text=True, timeout=900,
                          env={**os.environ, "TMPDIR": os.path.join(tmp_path, "tmp dir") + "/"})
    assert proc.returncode == 0, proc.stdout[-2000:] + proc.stderr[-2000:]
    assert subprocess.run([out, "doctor"], capture_output=True, timeout=60).returncode in (0, 1)


# ---- R-5, R-7 -----------------------------------------------------------------------------------

@pytest.mark.req("R-5")
def test_instances_never_talk_to_each_other(fresh):
    a, b = fresh(prefix="acc-r5a-"), fresh(prefix="acc-r5b-")
    a_pane = a.json("window", "new", "--name", "only-in-a")["pane"]
    names_b = [t.get("name") for w in b.tree()["windows"] for t in w["tabs"]]
    assert "only-in-a" not in names_b
    assert b.cli("pane", "info", a_pane, check=False).returncode != 0, "B doesn't know A's panes"
    # The CLI inside one of A's panes reaches A.
    a.cli("send", "--pane", a_pane, "-e", f"{a.target.cli_name} --json ls > '{a.dir}/from-pane.json'; echo LISTED")
    a.cli("wait", "--pane", a_pane, "--pattern", "^LISTED", "--timeout", "15")
    with open(os.path.join(a.dir, "from-pane.json")) as f:
        seen = [p["id"] for w in json.load(f)["windows"] for t in w["tabs"] for p in t["panes"]]
    assert a_pane in seen


@pytest.mark.req("R-5", "AG-16")
@pytest.mark.harness
def test_agents_of_one_instance_never_reach_another(fresh):
    a, b = fresh(prefix="acc-r5a-"), fresh(prefix="acc-r5b-")
    a.cli("window", "new", "--name", "only-in-a")
    sa = a.start_agent("claude", "ECHO in a", name="only-a")
    sb = b.start_agent("codex", "ECHO in b", name="only-b")
    names_b = [t.get("name") for w in b.tree()["windows"] for t in w["tabs"]]
    assert "only-in-a" not in names_b
    assert sa not in {s["id"] for s in b.agents()} and sb not in {s["id"] for s in a.agents()}
    assert b.cli("agent", "info", sa, check=False).returncode != 0
    # An agent of A, using the CLI, reaches A.
    a.send(sa, f"RUN {a.target.cli_name} --json agent ls")
    code, out = a.wait(sa)
    listed = {s["id"] for s in json_in(out["reply"])["sessions"]}
    assert sa in listed and sb not in listed


def stale_pane_env(a):
    pane = a.json("window", "new")["pane"]
    dump = os.path.join(a.dir, "pane-env")
    a.cli("send", "--pane", pane, "-e", f"env > '{dump}'; echo DUMPED")
    a.cli("wait", "--pane", pane, "--pattern", "^DUMPED", "--timeout", "15")
    with open(dump) as f:
        return dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)


def assert_stale_envs_never_act_on(b, envs):
    b_pane = b.json("window", "new", "--name", "b-window")["pane"]
    b_name = b.json("pane", "info", b_pane).get("name")
    for env in envs:
        proc = subprocess.run([b.target.cli_path, "pane", "rename", "stale-was-here"], env=env, capture_output=True,
                              text=True, timeout=60, stdin=subprocess.DEVNULL)
        if proc.returncode != 0:
            assert proc.stderr.strip(), "a failure is explained"
        names = [p.get("name") for w in b.tree()["windows"] for t in w["tabs"] for p in t["panes"]]
        assert "stale-was-here" not in names, "a stale environment acted on another instance's pane"
    assert b.json("pane", "info", b_pane).get("name") == b_name


@pytest.mark.req("R-7")
def test_stale_pane_environments_never_act_on_the_wrong_instance(fresh):
    a = fresh(prefix="acc-r7a-")
    stale = stale_pane_env(a)
    a.quit_app()
    b = fresh(prefix="acc-r7b-")
    assert_stale_envs_never_act_on(b, [stale])   # a terminal that outlived its instance


@pytest.mark.req("R-7")
@pytest.mark.harness
def test_stale_environments_never_act_on_the_wrong_instance(fresh):
    a = fresh(prefix="acc-r7a-")
    stale = stale_pane_env(a)
    sid = a.start_agent("claude", "RUN env")
    agent_env = dict(line.split("=", 1) for line in a.wait(sid)[1]["reply"].splitlines()[1:] if "=" in line)
    a.quit_app()
    b = fresh(prefix="acc-r7b-")
    assert_stale_envs_never_act_on(b, [stale, agent_env])   # a terminal and an agent that outlived their instance


@pytest.mark.req("R-7", "L-4")
def test_an_explicit_target_overrides_a_stale_caller(inst, win):
    """A CLI carrying the identity of a pane that's gone still creates a tab where --pane or --window
    says."""
    gone = inst.json("tab", "new", "--window", win["window"])["pane"]
    pane_env = {"TERN_PANE_ID": gone, "TERN_INSTANCE": json.loads(inst.cli("--json", "ping").stdout)["instance"]}
    inst.cli("pane", "close", gone)
    time.sleep(0.5)
    created = inst.json("tab", "new", "--pane", win["pane"], "--no-focus", env=pane_env)
    assert created["window"] == win["window"]
    created = inst.json("tab", "new", "--window", win["window"], "--no-focus", env=pane_env)
    assert created["window"] == win["window"]


# ---- AG-23: long runs ----------------------------------------------------------------------------

def timed(fn):
    t0 = time.time()
    fn()
    return time.time() - t0


@pytest.mark.req("AG-23", "AG-13")
@pytest.mark.harness
def test_cli_stays_responsive_and_truthful_while_busy(inst):
    busy = [inst.start_agent("codex", "SLEEP 10") for _ in range(3)]
    asking = inst.start_agent("claude", "ASK_PERMISSION", "--permission-mode", "default")
    inst.wait(asking)
    stalled = subprocess.Popen([inst.target.cli_path, "events"], stdout=subprocess.PIPE, env=inst.env,
                               stdin=subprocess.DEVNULL)
    try:
        for _ in range(5):
            assert timed(lambda: inst.cli("ls", timeout=10)) < 2
            assert timed(lambda: inst.agents()) < 2
        assert inst.info(asking)["status"] == "needs_input"
        assert all(inst.info(s)["status"] == "working" for s in busy)
    finally:
        stalled.kill()
        for s in busy + [asking]:
            inst.cli("agent", "stop", s, check=False)


@pytest.mark.req("AG-23")
@pytest.mark.slow
@pytest.mark.harness
def test_long_runs_stay_fast_and_disk_follows_what_is_kept(fresh):
    other = fresh(prefix="acc-r9-")

    def du():
        """The product's own storage: the state directory minus the fakes' data and the work folder."""
        out = subprocess.run(["du", "-sk", "-I", "fake-agent", "-I", "work", other.dir], capture_output=True,
                             text=True).stdout
        return int(out.split()[0])

    baseline = du()
    long_one = other.start_agent("claude", "ECHO start", name="long-one")
    other.wait(long_one)
    for i in range(80):
        other.send(long_one, f"ECHO turn {i} " + "x" * 2000)
        other.wait(long_one)
    other.send(long_one, "HUGE 8")
    other.wait(long_one, timeout=120)
    many = [other.start_agent("codex", f"ECHO s{i}") for i in range(15)]
    for s in many:
        other.wait(s)
    for check in (lambda: other.cli("ls"), lambda: other.agents(), lambda: other.info(long_one)):
        assert timed(check) < 1.5
    assert timed(lambda: other.transcript(long_one)) < 5
    assert timed(lambda: other.cli("agent", "read", long_one)) < 1.5
    grown = du()
    for s in [long_one, *many]:
        other.cli("agent", "rm", s, "--force")
    shrunk = du()
    assert shrunk - baseline <= (grown - baseline) / 2 + 1024, \
        f"removing every session freed little disk: baseline {baseline} kB, grown {grown} kB, after rm {shrunk} kB"
