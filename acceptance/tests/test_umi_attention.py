"""Attention and the note after an update: S-3 (a pane's agent marks its tab's row while it needs the
user, or finished and the pane wasn't looked at since: `changed_at > seen_at`, per pane), and I-4 (the
note after an update, until ⌃⌘U).

Agent state comes from `<cli> hook` run as Umi's plugin runs it from inside a pane (`Instance.hook`).
Looking needs the app in front; `debug.ui.assume_active` counts it as active with its current window
as key.
"""

import json
import os
import plistlib
import time

import pytest

from harness import wait_until
from test_umi_panes_ui import new_tab, row, rpc, split

pytestmark = pytest.mark.layout


def note(inst):
    return rpc(inst, "debug.ui.update_note")["update_note"]


def window_for(inst, prefix):
    """A window of a fresh instance, as the `win` fixture makes one."""
    created = inst.json("window", "new", "--name", prefix)
    pane = created["pane"]
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="the shell prompt")
    found = inst.find_pane(pane)
    return {"pane": found[2]["id"], "tab": found[1]["id"], "window": found[0]["id"]}


def turn(inst, pane, reply="done"):
    """A turn that runs and ends, as the plugin reports it."""
    inst.hook(pane, "UserPromptSubmit", prompt="a task")
    inst.hook(pane, "Stop", last_assistant_message=reply)


def mark(inst, pane):
    return (rpc(inst, "debug.ui.attention")["panes"].get(pane) or {}).get("mark")


@pytest.fixture
def active(inst):
    rpc(inst, "debug.ui.assume_active", on=True)
    yield
    rpc(inst, "debug.ui.assume_active", on=False)


# ---- S-3: seen is per pane ------------------------------------------------------------------------

@pytest.mark.req("S-3")
def test_a_finish_seen_from_another_pane_of_its_tab_keeps_its_mark(inst, win, active):
    """Looking at another pane of the same tab doesn't count (design/primitives.md: `seen_at` is set
    while the pane itself has keyboard focus); a look at its own pane clears it."""
    beside = split(inst, "right", win["pane"], "--no-focus")
    try:
        inst.hook(beside, "SessionStart")
        inst.cli("pane", "focus", win["pane"])
        wait_until(lambda: rpc(inst, "debug.ui.attention")["looked_at"] == win["pane"], 5, message="looking at the pane")
        turn(inst, beside)
        assert mark(inst, beside) == "finished"
        assert rpc(inst, "debug.ui.attention")["panes"][beside]["unseen"] is True
        inst.cli("pane", "focus", beside)
        wait_until(lambda: mark(inst, beside) == "none", 5, message="a look at its own pane clears it")
    finally:
        inst.hook(beside, "SessionEnd")


@pytest.mark.req("S-3")
def test_a_finish_in_the_pane_looked_at_leaves_no_mark(inst, win, active):
    pane = win["pane"]
    try:
        inst.hook(pane, "SessionStart")
        inst.cli("pane", "focus", pane)
        wait_until(lambda: rpc(inst, "debug.ui.attention")["looked_at"] == pane, 5, message="looking at the pane")
        turn(inst, pane)
        assert mark(inst, pane) == "none"
    finally:
        inst.hook(pane, "SessionEnd")


@pytest.mark.req("S-3")
def test_a_new_turn_clears_the_mark_and_a_question_keeps_it(inst, win):
    pane, tab = new_tab(inst, win)
    try:
        inst.hook(pane, "SessionStart")
        assert mark(inst, pane) == "none", "an agent that just started asks for nothing"
        turn(inst, pane)
        wait_until(lambda: row(inst, win["window"], tab)["mark"] == "finished", 5, message="finished out of sight")
        inst.hook(pane, "UserPromptSubmit", prompt="more")
        assert row(inst, win["window"], tab)["mark"] == "none"
        inst.hook(pane, "PermissionRequest", tool_name="Bash")
        assert row(inst, win["window"], tab)["mark"] == "needs_you"
        assert rpc(inst, "debug.ui.attention")["needing_you"] >= 1
        inst.hook(pane, "PostToolUse", tool_name="Bash")
        assert row(inst, win["window"], tab)["mark"] == "none"
    finally:
        inst.hook(pane, "SessionEnd")


@pytest.mark.req("S-3", "L-12")
def test_jump_goes_to_the_pane_that_needs_you_then_the_unseen_one(inst, win):
    for pane in rpc(inst, "debug.ui.attention")["panes"]:
        rpc(inst, "debug.attention.set", pane=pane, clear=True)
    finished, _ = new_tab(inst, win)
    waiting, _ = new_tab(inst, win)
    home = win["pane"]
    inst.cli("pane", "focus", home)
    try:
        inst.hook(finished, "SessionStart")
        turn(inst, finished)
        time.sleep(0.2)
        inst.hook(waiting, "SessionStart")
        inst.hook(waiting, "PermissionRequest", tool_name="Bash")
        assert inst.json("go", "--next", "jump")["pane"] == waiting
        assert inst.json("go", "--next", "jump")["pane"] == finished
        assert inst.json("go", "--back")["pane"] == home
    finally:
        inst.hook(finished, "SessionEnd")
        inst.hook(waiting, "SessionEnd")


# ---- I-4: the note after an update ----------------------------------------------------------------

def app_version(target):
    with open(os.path.join(target.app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f)["CFBundleShortVersionString"]


@pytest.mark.req("I-4")
def test_a_note_says_what_changed_once_after_an_update(fresh, target):
    """What the previous run leaves when it hands an update to the installer (`updates/attempt.json`):
    the next launch, being that version, says so once, with the release's notes."""
    version = app_version(target)
    inst = fresh(start_app=False, prefix="acc-upnote-")
    os.makedirs(os.path.join(inst.dir, "updates"), exist_ok=True)
    with open(os.path.join(inst.dir, "updates", "attempt.json"), "w") as f:
        json.dump({"version": version, "from": "0.0.1", "at": "2026-11-05T00:00:00Z",
                   "notes": "Agents in panes.\nNo more sessions."}, f)
    inst.start_app()
    window_for(inst, "note")
    wait_until(lambda: note(inst), 10, message="the note")
    assert note(inst) == {"version": version, "notes": "Agents in panes.\nNo more sessions."}
    assert rpc(inst, "debug.ui.update_note", dismiss=True)["update_note"] is None
    # Once: the next launch says nothing.
    inst.quit_gracefully()
    inst.start_app()
    window_for(inst, "note-again")
    time.sleep(1)
    assert note(inst) is None


@pytest.mark.req("I-4")
def test_no_note_after_a_failed_update(fresh):
    inst = fresh(start_app=False, prefix="acc-upnote-failed-")
    os.makedirs(os.path.join(inst.dir, "updates"), exist_ok=True)
    with open(os.path.join(inst.dir, "updates", "attempt.json"), "w") as f:
        json.dump({"version": "999.0.0", "from": "0.0.1", "notes": "never installed"}, f)
    inst.start_app()
    window_for(inst, "no-note")
    time.sleep(1)
    assert note(inst) is None


@pytest.mark.req("I-4")
def test_no_note_after_a_rollback(fresh, target):
    """`update --rollback` installs an older version through the same path: it isn't an update."""
    version = app_version(target)
    inst = fresh(start_app=False, prefix="acc-upnote-rollback-")
    os.makedirs(os.path.join(inst.dir, "updates"), exist_ok=True)
    with open(os.path.join(inst.dir, "updates", "attempt.json"), "w") as f:
        json.dump({"version": version, "from": "999.0.0", "at": "2026-11-05T00:00:00Z"}, f)
    inst.start_app()
    window_for(inst, "rollback")
    time.sleep(1)
    assert note(inst) is None
