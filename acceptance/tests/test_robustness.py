"""The app's own robustness (SPEC R): restarts, paths, isolation, stale environments. (Agents that come
back in their panes after a quit or a crash: test_agent_panes.py.)"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid

import pytest

from harness import wait_until

pytestmark = pytest.mark.robustness


def nonce():
    return uuid.uuid4().hex[:10]


# ---- R-3: restarts -------------------------------------------------------------------------------

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
    inner = other.cli("send", "--pane", pane, "-e", f"'{other.target.cli_path}' pane rename spaced-ok; echo RENAMED")
    other.cli("wait", "--pane", pane, "--pattern", "^RENAMED", "--timeout", "15")
    assert other.json("pane", "info", pane).get("name") == "spaced-ok", "the CLI inside the pane reaches its app"
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
    a.cli("send", "--pane", a_pane, "-e", f"'{a.target.cli_path}' --json ls > '{a.dir}/from-pane.json'; echo LISTED")
    a.cli("wait", "--pane", a_pane, "--pattern", "^LISTED", "--timeout", "15")
    with open(os.path.join(a.dir, "from-pane.json")) as f:
        seen = [p["id"] for w in json.load(f)["windows"] for t in w["tabs"] for p in t["panes"]]
    assert a_pane in seen


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


@pytest.mark.req("R-7", "L-4")
def test_an_explicit_target_overrides_a_stale_caller(inst, win):
    """A CLI carrying the identity of a pane that's gone still creates a tab where --pane or --window
    says."""
    gone = inst.json("tab", "new", "--window", win["window"])["pane"]
    pane_env = {"UMI_PANE": gone, "UMI_INSTANCE": json.loads(inst.cli("--json", "ping").stdout)["instance"]}
    inst.cli("pane", "close", gone)
    time.sleep(0.5)
    created = inst.json("tab", "new", "--pane", win["pane"], "--no-focus", env=pane_env)
    assert created["window"] == win["window"]
    created = inst.json("tab", "new", "--window", win["window"], "--no-focus", env=pane_env)
    assert created["window"] == win["window"]




@pytest.mark.req("R-4", "AG-18")
def test_agents_report_with_spaces_and_long_state_dirs(target, fresh):
    """An agent typed in a pane reports itself through `<cli> hook` with a state directory whose path
    holds spaces and is longer than a Unix socket path may be."""
    base, other, work = spaced_instance(fresh)
    pane = other.json("window", "new", "--cwd", work)["pane"]
    wait_until(lambda: other.screen(pane).strip(), 20, message="the shell")
    time.sleep(0.5)
    try:
        attributes = other.type_agent(pane, "claude")
        assert attributes["agent.status"] == "idle", attributes
        other.type_line(pane, "ECHO spaced")
        wait_until(lambda: other.attributes(pane).get("agent.title") == "ECHO spaced", 15, message="its first turn")
    finally:
        other.type_line(pane, "/exit")
        shutil.rmtree(base, ignore_errors=True)
