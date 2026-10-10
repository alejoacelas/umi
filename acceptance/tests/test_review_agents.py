"""Regression tests for what the adversarial review of the agent-sessions work found (BRIEF-agents.md §3).

Each test names the round and the finding. Fakes only (no model is called).
"""

import os
import time
import uuid

import pytest

from harness import wait_until

pytestmark = pytest.mark.sessions

BANNER = "Fake Claude Code"


def nonce():
    return uuid.uuid4().hex[:8]


def fake_args(inst):
    return ["--env", "FAKE_AGENT_DIR=" + inst.fake_dir, "--env", "CLAUDE_CONFIG_DIR=" + inst.claude_config]


def wait_live(inst, sid, timeout=30):
    wait_until(lambda: inst.info(sid)["location"] == "live", timeout, message=f"the session to be live: {inst.info(sid)}")
    pane = inst.info(sid)["pane"]
    wait_until(lambda: BANNER in inst.screen(pane), timeout, message="the interface in its pane")
    return pane


def menu_item(inst, title):
    return next((i for i in inst.rpc("debug.menu")["items"] if i["title"] == title), None)


# ---- round 1 -------------------------------------------------------------------------------------

@pytest.mark.req("AG-6")
def test_take_over_while_the_headless_process_is_still_launching(fresh):
    """Round 1, P1: Take Over reaching a Claude session whose headless process is still being launched
    cancelled the launch and never answered `agent attach`. It must go live at once."""
    inst = fresh(prefix="acc-rv-", env={"TERN_TEST_LAUNCH_DELAY": "4"})
    w = inst.json("window", "new", "--cwd", inst.work)
    wait_until(lambda: inst.screen(w["pane"]).strip(), 20, message="the shell")
    n = nonce()
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), f"ECHO first {n}")["session"]["id"]
    assert inst.info(sid)["status"] == "starting"
    began = time.time()
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", w["pane"], "--live")["pane"]
    assert wait_live(inst, sid, timeout=20) == pane
    assert time.time() - began < 15, "taking over waited for the launch instead of cancelling it"
    # The message it was launched for isn't lost: it reaches the agent once, through the interface
    # being taken back while idle, and the session comes back live.
    code, out = inst.wait(sid, timeout=60)
    assert (code, out["status"]) == (0, "DONE") and f"ECHO first {n}" in out["reply"], out
    assert not inst.violations()


@pytest.mark.req("AG-6")
def test_attach_for_a_session_live_elsewhere_leaves_the_pane_as_it_was(inst, win):
    """Round 1, P2: `agent attach S` run in a second pane, for a session live in another, failed but left
    the second pane covered by the session's read-only view."""
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--name", f"elsewhere-{nonce()}",
                    "--split", "right", "--pane", win["pane"], "ECHO hello")["session"]["id"]
    live_pane = wait_live(inst, sid)
    inst.cli("send", "--pane", win["pane"], "-e", f'"$TERN_CLI" agent attach {sid}')
    wait_until(lambda: "already live" in inst.screen(win["pane"]), 15, message="attach says the session is live elsewhere")
    time.sleep(0.5)
    view = inst.session_view(win["pane"])
    assert view.get("showing") == "terminal" and not view.get("session"), view
    assert inst.info(sid)["location"] == "live" and inst.info(sid)["pane"] == live_pane


@pytest.mark.req("AG-6", "AG-2")
def test_a_session_whose_name_has_quotes_goes_live(inst, win):
    """Round 1, P2: the attach line typed into the pane quoted the session's name without escaping an
    apostrophe, so a name like "worker's task" left the shell waiting for a closing quote."""
    name = f"worker's task {nonce()}"
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--name", name,
                    "--split", "right", "--pane", win["pane"], "ECHO quoted")["session"]["id"]
    pane = wait_live(inst, sid)
    assert "quote>" not in inst.screen(pane)


@pytest.mark.req("L-17")
def test_a_key_freed_from_one_action_and_given_to_another_stays_bound(inst, win):
    """Round 1, P2: bindings were written action by action in alphabetical order, so clearing Paste (⌘V)
    and giving ⌘V to Copy wrote `super+v=copy_to_clipboard` before `super+v=unbind`."""
    try:
        inst.cli("shortcuts", "clear", "ghostty:paste_from_clipboard")
        inst.cli("shortcuts", "set", "ghostty:copy_to_clipboard", "cmd+v")
        conf = open(os.path.join(inst.dir, "keybindings.conf")).read().splitlines()
        bind = conf.index("keybind = super+v=copy_to_clipboard")
        unbinds = [i for i, line in enumerate(conf) if line.endswith("=unbind")]
        assert unbinds and max(unbinds) < bind, conf
        wait_until(lambda: (lambda i: i and i["key"] == "v" and i["modifiers"] == ["cmd"])(menu_item(inst, "Copy")), 5,
                   message="Copy is on ⌘V")
    finally:
        inst.cli("shortcuts", "reset")


@pytest.mark.req("L-14")
def test_a_command_cancelled_by_opening_another_palette_leaves_that_palette_alone(inst, win):
    """Round 1, P2: opening another palette while a command ran killed the command, but its completion
    then replaced the new palette with its output (or closed it)."""
    query = f"tern wait --pane {win['pane']} --pattern never-{nonce()} --timeout 20"
    inst.rpc("debug.palette", window=win["window"], mode="commands", query=query)
    started = inst.rpc("debug.palette.perform", window=win["window"], title="Run " + query, timeout=1)
    assert started.get("step") == "running", started
    inst.rpc("debug.palette", window=win["window"], mode="panes")
    time.sleep(2)   # the killed command has ended and its completion has run
    state = inst.rpc("debug.palette.state", window=win["window"])
    try:
        assert state["presented"] and state["mode"] == "panes" and state["step"] == "list", state
        assert state["entries"] and not state["output"], state
    finally:
        inst.rpc("debug.palette.close", window=win["window"])
