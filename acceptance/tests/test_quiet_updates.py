"""I-4: an update installs itself at a quiet moment. What "quiet" means, checked through `update
--status` (its `quiet` part: `quiet` and what it is `waiting_for`) with the fake agents and fake time.

Fake time is Umi's internal `debug.update.clock` (it moves the clock the quiet checks read, in an
isolated instance); `debug.update.input` is someone typing or clicking in the app, as the app's event
monitor sees it. Text and keys sent with `umi send` are not the user's input, so the tests can drive
panes without restarting the two minutes. Each test has an instance of its own: quiet is about every
pane and session of an instance.

The end-to-end installs (download, countdown, relaunch, rollback) are in test_umi_extra.py.
"""

import os
import time

import pytest

from harness import FAKE_CLAUDE, wait_until
from test_sessions import fake_args, nonce

pytestmark = [pytest.mark.install]

IDLE = 120          # seconds without typing or clicking that a quiet moment needs
PLUGIN = "Contents/Resources/agent-plugins/claude"


def quiet(inst):
    return inst.json("update", "--status")["quiet"]


def reasons(inst):
    return quiet(inst)["waiting_for"]


def no_input(inst):
    """Fake time: the two minutes without typing or clicking have passed."""
    inst.rpc("debug.update.clock", advance=IDLE + 5)


def wait_quiet(inst, timeout=20):
    return wait_until(lambda: (q := quiet(inst))["quiet"] and q, timeout,
                      message="a quiet moment").get("waiting_for")


def wait_reason(inst, match, timeout=20):
    """Wait until one reason matches; return it."""
    def found():
        return next((r for r in reasons(inst) if match(r)), None)
    return wait_until(found, timeout, message="the reason it isn't quiet")


def shell_ready(inst, pane):
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20,
               message="the shell prompt")
    time.sleep(0.5)


@pytest.fixture
def calm(fresh):
    """An instance of its own with one window at its shell's prompt."""
    inst = fresh(prefix="acc-quiet-")
    pane = inst.json("window", "new", "--cwd", inst.work)["pane"]
    shell_ready(inst, pane)
    return inst, pane


@pytest.mark.req("I-4")
def test_a_quiet_moment_needs_two_minutes_without_typing_or_clicking(calm):
    inst, pane = calm
    # Launching counts as activity: right after it, it isn't quiet yet.
    found = wait_reason(inst, lambda r: r["kind"] == "input")
    assert "typed or clicked" in found["reason"], found
    inst.rpc("debug.update.clock", advance=IDLE - 10)
    assert any(r["kind"] == "input" for r in reasons(inst)), "quiet before two minutes passed"
    inst.rpc("debug.update.clock", advance=15)
    assert wait_quiet(inst) == []
    # Someone types or clicks: two more minutes.
    inst.rpc("debug.update.input")
    assert [r["kind"] for r in reasons(inst)] == ["input"]
    inst.rpc("debug.update.clock", advance=60)
    assert [r["kind"] for r in reasons(inst)] == ["input"]
    inst.rpc("debug.update.clock", advance=65)
    wait_quiet(inst)


@pytest.mark.req("I-4")
def test_a_busy_pane_is_not_quiet(calm):
    """A pane is quiet only at its own shell's prompt with nothing typed and nothing else running:
    a program in front, a job in the background, a shell started from it, or text typed at the
    prompt each keep the moment from being quiet, and say which pane."""
    inst, pane = calm
    no_input(inst)
    wait_quiet(inst)

    def busy_with(words):
        found = wait_reason(inst, lambda r: r.get("pane") == pane and all(w in r["reason"] for w in words))
        assert found["kind"] == "pane" and found.get("tab"), found
        return found

    inst.cli("send", "--pane", pane, "echo half-typed")
    busy_with(["typed"])
    inst.cli("keys", "--pane", pane, "ctrl+u")
    wait_quiet(inst)

    inst.cli("send", "--pane", pane, "--enter", "sleep 300")
    busy_with(["sleep", "running"])
    inst.cli("keys", "--pane", pane, "ctrl+c")
    wait_quiet(inst)

    inst.cli("send", "--pane", pane, "--enter", "sleep 300 &")
    busy_with(["sleep", "background"])
    inst.cli("send", "--pane", pane, "--enter", "kill %1")
    wait_quiet(inst)

    # A shell started from the pane's shell is a program running there (its state would be lost).
    inst.cli("send", "--pane", pane, "--enter", "/bin/zsh")
    busy_with(["zsh", "running"])
    inst.cli("send", "--pane", pane, "--enter", "exit")
    wait_quiet(inst)

    # A second pane: each is judged on its own.
    other = inst.json("split", "right", "--pane", pane, "--cwd", inst.work)["pane"]
    shell_ready(inst, other)
    inst.cli("send", "--pane", other, "--enter", "cat")
    found = wait_reason(inst, lambda r: r.get("pane") == other)
    assert "cat" in found["reason"], found
    assert not [r for r in reasons(inst) if r.get("pane") == pane], "the idle pane was blamed"
    inst.cli("keys", "--pane", other, "ctrl+c")
    wait_quiet(inst)


@pytest.mark.req("I-4", "AG-18")
@pytest.mark.harness
def test_a_running_turn_or_a_waiting_message_is_not_quiet(calm):
    """No agent turn may run in any session the app knows, and no message may wait to be delivered."""
    inst, pane = calm
    no_input(inst)
    wait_quiet(inst)
    sid = inst.start_agent("claude", f"SLEEP 6 {nonce()}", name="busy-" + nonce())
    # First its message waits for the agent to start, then its turn runs.
    found = wait_reason(inst, lambda r: r.get("session") == sid and "turn is running" in r["reason"])
    assert found["kind"] == "session" and found["name"].startswith("busy-"), found
    assert inst.wait(sid, timeout=30)[1]["status"] == "DONE"
    wait_quiet(inst)

    # A message waiting for a live Claude whose user has something typed in it.
    live = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--split", "right",
                     "--pane", pane, "--name", "live-" + nonce(), "ECHO hello")
    lid, lpane = live["session"]["id"], live["pane"]
    assert inst.wait(lid, timeout=30)[1]["status"] == "DONE"
    wait_until(lambda: inst.info(lid)["location"] == "live", 30, message="live")
    wait_until(lambda: "Fake Claude Code" in inst.screen(lpane, scrollback=True), 20, message="its interface")
    wait_quiet(inst)
    inst.cli("send", "--pane", lpane, "a draft")
    typed = wait_reason(inst, lambda r: r.get("session") == lid)
    assert "typed in its interface" in typed["reason"], typed
    inst.send(lid, f"ECHO waiting {nonce()}")
    wait_reason(inst, lambda r: r.get("session") == lid and "waiting to be delivered" in r["reason"])
    inst.cli("keys", "--pane", lpane, "ctrl+u")
    wait_quiet(inst, timeout=60)
    for s in (sid, lid):
        inst.cli("agent", "stop", s, check=False, timeout=60)


@pytest.mark.req("I-4")
def test_unsaved_changes_in_the_editor_are_not_quiet(calm):
    inst, pane = calm
    path = os.path.join(inst.work, f"notes-{nonce()}.md")
    with open(path, "w") as f:
        f.write("# Notes\n")
    inst.cli("edit", path, "--pane", pane)
    no_input(inst)
    wait_quiet(inst)
    inst.rpc("debug.editor.type", path=path, text="an edit not saved yet\n")
    found = wait_reason(inst, lambda r: r["kind"] == "editor")
    assert os.path.basename(path) in found["reason"] and "unsaved" in found["reason"], found
    inst.cli("editor", "close", path, "--force", "--pane", pane)
    wait_quiet(inst)


@pytest.mark.req("I-4", "AG-5", "AG-18")
@pytest.mark.harness
def test_idle_agents_in_panes_are_quiet(calm):
    """A pane showing an idle agent is quiet: its own interface with nothing typed in it (started by
    Umi or typed by the user), or a session's read-only view."""
    inst, pane = calm
    live = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--split", "right",
                     "--pane", pane, "--name", "live-" + nonce(), "ECHO hello")
    lid, lpane = live["session"]["id"], live["pane"]
    assert inst.wait(lid, timeout=30)[1]["status"] == "DONE"
    wait_until(lambda: inst.info(lid)["location"] == "live", 30, message="live")
    viewed = inst.start_agent("codex", "ECHO viewed", name="viewed-" + nonce())
    assert inst.wait(viewed, timeout=30)[1]["status"] == "DONE"
    view_pane = inst.json("agent", "open", viewed, "--split", "down", "--pane", pane)["pane"]
    wait_until(lambda: inst.session_view(view_pane).get("showing") == "agent", 20, message="the read-only view")

    # The user's own `claude`, typed in a pane (Umi's plugin reports it, AG-18).
    typed_pane = inst.json("split", "down", "--pane", lpane, "--cwd", inst.work)["pane"]
    shell_ready(inst, typed_pane)
    known = {s["id"] for s in inst.agents()}
    plugin = os.path.join(inst.target.app, PLUGIN)
    inst.type_line(typed_pane, f"FAKE_AGENT_DIR='{inst.fake_dir}' FAKE_CLAUDE_PLUGIN_DIRS='{plugin}' '{FAKE_CLAUDE}'")
    typed = wait_until(lambda: next((s for s in inst.agents() if s["id"] not in known), None), 20,
                       message="the typed agent to become a session")
    wait_until(lambda: "Fake Claude Code" in inst.screen(typed_pane, scrollback=True), 20, message="its interface")

    no_input(inst)
    assert wait_quiet(inst) == []
    inst.cli("send", "--pane", typed_pane, "not sent yet")
    found = wait_reason(inst, lambda r: r.get("session") == typed["id"])
    assert "typed in its interface" in found["reason"], found
    # Esc at the prompt leaves what was typed (only a turn is interrupted); Ctrl-U clears it.
    inst.cli("keys", "--pane", typed_pane, "esc")
    time.sleep(0.5)
    assert any(r.get("session") == typed["id"] for r in reasons(inst)), "Esc counted as clearing the draft"
    inst.cli("keys", "--pane", typed_pane, "ctrl+u")
    wait_quiet(inst)
    # Up (or Ctrl-P, or any edit Umi can't follow) may put an earlier prompt on the input line: not
    # quiet until it's sent or cleared.
    for key in ("up", "ctrl+p"):
        inst.cli("keys", "--pane", typed_pane, key)
        found = wait_reason(inst, lambda r: r.get("session") == typed["id"])
        assert "history" in found["reason"], (key, found)
        inst.cli("keys", "--pane", typed_pane, "ctrl+u")
        wait_quiet(inst)
    for s in (lid, viewed, typed["id"]):
        inst.cli("agent", "stop", s, check=False, timeout=60)


@pytest.mark.req("I-4", "AG-18")
@pytest.mark.harness
def test_a_job_beside_an_agent_interface_is_not_quiet(calm):
    """An idle agent in front doesn't make its pane quiet when the shell also runs a job (`sleep &`
    before typing `claude`): the relaunch would end it."""
    inst, pane = calm
    plugin = os.path.join(inst.target.app, PLUGIN)
    known = {s["id"] for s in inst.agents()}
    inst.type_line(pane, f"sleep 300 & FAKE_AGENT_DIR='{inst.fake_dir}' FAKE_CLAUDE_PLUGIN_DIRS='{plugin}' '{FAKE_CLAUDE}'")
    typed = wait_until(lambda: next((s for s in inst.agents() if s["id"] not in known), None), 20,
                       message="the typed agent to become a session")
    wait_until(lambda: "Fake Claude Code" in inst.screen(pane, scrollback=True), 20, message="its interface")
    no_input(inst)
    found = wait_reason(inst, lambda r: r.get("pane") == pane)
    assert "sleep" in found["reason"] and "background" in found["reason"], found
    inst.cli("agent", "stop", typed["id"], check=False, timeout=60)
    wait_until(lambda: "Fake Claude Code" not in inst.screen(pane) or inst.info(typed["id"])["location"] != "live", 20,
               message="the interface to end")
    inst.cli("send", "--pane", pane, "--enter", "kill %1")
    wait_quiet(inst)
