"""Regression tests from the adversarial reviews of earlier rounds (BRIEF-agents.md §3) that still apply
now that Umi runs no agents of its own: shortcuts, the palette, reopening, and agents in panes.

Each test names the round and the finding. Fakes only (no model is called).
"""

import os
import time
import uuid

import pytest

from harness import wait_until

pytestmark = pytest.mark.layout


def nonce():
    return uuid.uuid4().hex[:8]


def menu_item(inst, title):
    return next((i for i in inst.rpc("debug.menu")["items"] if i["title"] == title), None)


# ---- round 1 -------------------------------------------------------------------------------------

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
    query = f"umi wait --pane {win['pane']} --pattern never-{nonce()} --timeout 20"
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


# ---- round 2 -------------------------------------------------------------------------------------

@pytest.mark.req("L-17")
def test_a_key_given_to_a_second_terminal_action_leaves_the_first(inst, win):
    """Round 2, P2: giving a terminal action a key another terminal action had been given kept both
    bindings, and the alphabetically later one won."""
    try:
        inst.cli("shortcuts", "set", "ghostty:paste_from_clipboard", "ctrl+cmd+y")
        inst.cli("shortcuts", "set", "ghostty:copy_to_clipboard", "ctrl+cmd+y")
        conf = open(os.path.join(inst.dir, "keybindings.conf")).read()
        assert "=copy_to_clipboard" in conf and "ctrl+super+y=paste_from_clipboard" not in conf, conf
        entries = {e["id"]: e for e in inst.json("shortcuts")["shortcuts"]}
        wait_until(lambda: "ctrl+super+y" in {e["id"]: e for e in inst.json("shortcuts")["shortcuts"]}
                   ["ghostty:copy_to_clipboard"]["keys"], 5, message="Copy has the key")
        assert "ctrl+super+y" not in {e["id"]: e for e in inst.json("shortcuts")["shortcuts"]}[
            "ghostty:paste_from_clipboard"]["keys"], entries
    finally:
        inst.cli("shortcuts", "reset")


@pytest.mark.req("L-17")
def test_resetting_a_shortcut_takes_its_key_back(inst, win):
    """Round 2, P2: resetting one shortcut restored its default key without taking that key from the item
    that had been given it meanwhile, so two items had the same key."""
    try:
        inst.cli("shortcuts", "set", "tab.next", "cmd+p")
        assert menu_item(inst, "Command Palette…")["key"] == ""
        inst.cli("shortcuts", "reset", "view.palette")
        palette, nxt = menu_item(inst, "Command Palette…"), menu_item(inst, "Show Next Tab")
        assert (palette["key"], palette["modifiers"]) == ("p", ["cmd"]), palette
        assert not (nxt["key"] == "p" and nxt["modifiers"] == ["cmd"]), nxt
    finally:
        inst.cli("shortcuts", "reset")


# ---- round 3 -------------------------------------------------------------------------------------

@pytest.mark.req("I-4", "AG-18")
def test_an_update_now_counts_work_in_a_live_interface(fresh):
    """Round 3, P2: installing an update now (it restarts the app) cut off work in an agent's own
    interface in a pane without asking for --force."""
    inst = fresh(prefix="acc-rv-update-")
    win = inst.json("window", "new", "--cwd", inst.work)
    wait_until(lambda: inst.screen(win["pane"]).strip(), 20, message="the shell")
    time.sleep(0.5)
    assert "turn" not in inst.cli("update", "--now", check=False, timeout=30).stderr, "nothing runs yet"
    pane = win["pane"]
    inst.type_agent(pane, "claude")
    inst.type_line(pane, f"SLEEP 8 {nonce()}")
    inst.wait_agent_status(pane, "working", 10)
    refused = inst.cli("update", "--now", check=False, timeout=30)
    assert refused.returncode != 0 and "1 agent turn is running" in refused.stderr, (refused.returncode, refused.stderr)
    inst.wait_agent_status(pane, "idle", 20)
    inst.type_line(pane, "/exit")


@pytest.mark.req("S-3", "L-12")
def test_a_pane_waiting_for_the_user_stops_counting_once_it_closes(inst, win):
    """Round 3, P2: closing the pane of an agent waiting for approval left its mark behind: the Dock
    badge kept a stale count and ⌃⌘J (`jump`) went nowhere."""
    pane = inst.json("split", "right", "--pane", win["pane"])["pane"]
    wait_until(lambda: inst.screen(pane).strip(), 20, message="the shell")
    before = inst.rpc("debug.ui.attention")["needing_you"]
    inst.hook(pane, "SessionStart")
    inst.hook(pane, "PermissionRequest", tool_name="Bash")
    wait_until(lambda: inst.rpc("debug.ui.attention")["needing_you"] == before + 1, 10, message="it counts")
    inst.cli("pane", "close", pane)
    wait_until(lambda: inst.rpc("debug.ui.attention")["needing_you"] == before, 10, message="the closed pane stops counting")
    if before == 0:
        assert inst.cli("jump", check=False).returncode == 1


@pytest.mark.req("L-14", "L-2")
def test_rename_tab_from_the_palette_with_an_empty_name_clears_it(inst, win):
    """Round 3, P2: the palette's Rename Tab says an empty name names the tab after its folder, but an
    empty answer was refused (and would have been dropped from the command line)."""
    inst.cli("tab", "rename", win["tab"], "named-for-now")
    inst.cli("pane", "focus", win["pane"])
    inst.rpc("debug.palette", window=win["window"], mode="commands", query="rename tab")
    result = inst.rpc("debug.palette.perform", window=win["window"], title="Rename Tab…", answers=[""])
    assert not result.get("failed"), result
    tab = next(t for w in inst.tree()["windows"] for t in w["tabs"] if t["id"] == win["tab"])
    assert not tab.get("name"), tab
    inst.rpc("debug.palette.close", window=win["window"])


# ---- round 4 -------------------------------------------------------------------------------------

def tab_frames(inst, tab_id):
    for w in inst.tree()["windows"]:
        for t in w["tabs"]:
            if t["id"] == tab_id:
                return {p["id"]: p["frame"] for p in t["panes"]}
    return {}


@pytest.mark.req("L-20", "L-19")
def test_reopening_a_pane_keeps_a_resize_made_after_the_close(inst, win):
    """Round 4, P2: reopening a pane restored the whole tab as it was before the close when its
    structure hadn't changed, undoing a resize made since."""
    a = win["pane"]
    b = inst.cli("split", "right", "--pane", a).stdout.strip()
    c = inst.cli("split", "right", "--pane", b).stdout.strip()
    inst.cli("pane", "close", b)
    wait_until(lambda: not inst.find_pane(b), 5, message="closed")
    inst.cli("pane", "resize", a, "right", "20")
    resized = tab_frames(inst, win["tab"])
    share = resized[a]["width"] / (resized[a]["width"] + resized[c]["width"])
    assert share > 0.55, resized
    inst.json("reopen")
    after = tab_frames(inst, win["tab"])
    assert set(after) == {a, b, c}
    assert after[a]["width"] / after[c]["width"] > 1.1, f"the resize was undone: {after}"


# ---- found while running the suite with the screen locked ---------------------------------------

@pytest.mark.req("R-6", "L-8")
def test_many_windows_opened_while_the_screen_is_locked_leave_the_app_responsive(fresh):
    """With the screen locked (or the display asleep) AppKit's window-opening animation never ends, and
    each window opened then kept a worker thread waiting for ever. After 64 of them the shared thread
    pool was gone and every command that waited on it stalled. (On an unlocked screen this passes either way.)"""
    inst = fresh(prefix="acc-rv-windows-")
    for _ in range(70):
        w = inst.json("window", "new")
        inst.cli("window", "close", w["window"])
    pane = inst.json("window", "new")["pane"]
    inst.cli("wait", "--pane", pane, "--idle", "1", "--timeout", "20")
    inst.type_line(pane, f"echo still-answering-{nonce()}")
    inst.cli("wait", "--pane", pane, "--pattern", "^still-answering-", "--timeout", "20")


# ---- round 8 -------------------------------------------------------------------------------------

@pytest.mark.req("L-17")
@pytest.mark.parametrize("action", ["", "no_such_action"])
def test_an_unknown_terminal_action_is_refused_and_the_app_stays_up(inst, win, action):
    """Round 8, P2: `umi shortcuts set 'ghostty:' cmd+j` saved a broken binding and crashed the app."""
    try:
        refused = inst.cli("shortcuts", "set", f"ghostty:{action}", "cmd+j", check=False)
        assert refused.returncode != 0, refused.stdout
        assert inst.json("ping") and inst.json("shortcuts")["shortcuts"]
        assert f"={action}\n" not in open(os.path.join(inst.dir, "keybindings.conf")).read() + "\n" if os.path.exists(
            os.path.join(inst.dir, "keybindings.conf")) else True
    finally:
        inst.cli("shortcuts", "reset", check=False)
