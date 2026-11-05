"""Agent status, attention, inbox, toasts and the update note, as Warp (Warp parity, 2026-11-05):
S-3 (status badges on the agent's mark, Warp's seen rule, a new turn clears the mark, no desktop
notifications from agents), AG-24 (the inbox on ⇧⌘U and toasts), I-4 (the note after an update).

The agent engine's writes are stood in for with Umi's internal `debug.ui.attention.set`, except in
the test marked `harness`, which runs a fake Claude. What the inbox and toasts show is read with
`debug.ui.inbox`; the `ui` tests press the real keys.
"""

import json
import os
import plistlib
import time
import uuid

import pytest

from harness import wait_until
from test_umi_panes_ui import new_tab, row, rpc, set_agent, clear_agent, split

pytestmark = pytest.mark.layout


def inbox(inst, **params):
    return rpc(inst, "debug.ui.inbox", **params)


def window_for(inst, prefix):
    """A window of a fresh instance, as the `win` fixture makes one."""
    created = inst.json("window", "new", "--name", prefix)
    pane = created["pane"]
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="the shell prompt")
    found = inst.find_pane(pane)
    return {"pane": found[2]["id"], "tab": found[1]["id"], "window": found[0]["id"]}


def finish(inst, pane, kind="claude", title="", mark="finished"):
    """A turn that ran and ended (what the engine reports)."""
    set_agent(inst, pane, kind, title=title, status="working")
    set_agent(inst, pane, kind, title=title, status="idle", mark=mark)


@pytest.fixture
def active(inst):
    rpc(inst, "debug.ui.assume_active", on=True)
    yield
    rpc(inst, "debug.ui.assume_active", on=False)


# ---- S-3: Warp's status badges --------------------------------------------------------------------

@pytest.mark.req("S-3")
def test_the_agents_mark_wears_warps_status_badge(inst, win):
    pane, tab = new_tab(inst, win)
    try:
        expected = [
            (dict(status="starting"), "working"),
            (dict(status="working"), "working"),
            (dict(status="idle", mark="finished"), "done"),
            (dict(status="needs_input", mark="needs_you"), "needs_you"),
            (dict(status="error", mark="finished"), "error"),
            (dict(status="stopped"), "cancelled"),
            (dict(status="idle"), "none"),
        ]
        for params, badge in expected:
            set_agent(inst, pane, "claude", title="Badges", **params)
            r = row(inst, win["window"], tab)
            assert r["badge"] == badge, (params, r)
            assert r["icon"] == "claude"
    finally:
        clear_agent(inst, pane)
    assert row(inst, win["window"], tab)["badge"] == "none"


# ---- S-3: Warp's seen rule ------------------------------------------------------------------------

def agent_beside(inst, pane):
    """A fake Claude session shown in a split right of `pane` (the split isn't focused)."""
    sid = inst.start_agent("claude", f"ECHO hi {uuid.uuid4().hex[:6]}")
    inst.wait(sid)
    beside = inst.json("agent", "open", sid, "--split", "right", "--pane", pane)["pane"]
    return sid, beside


def run_a_turn(inst, sid, window, tab):
    """A short turn through the engine, until it has ended."""
    inst.send(sid, "SLEEP 2")
    wait_until(lambda: row(inst, window, tab)["badge"] == "working", 15, message="the turn runs")
    wait_until(lambda: row(inst, window, tab)["badge"] != "working", 20, message="the turn ends")


@pytest.mark.harness
@pytest.mark.req("S-3")
def test_a_finish_seen_from_another_pane_of_its_tab_leaves_no_mark(inst, win, active):
    """The engine: Warp counts a session as seen if any pane of its tab had focus as it finished."""
    sid, beside = agent_beside(inst, win["pane"])
    try:
        inst.cli("pane", "focus", win["pane"])
        wait_until(lambda: rpc(inst, "debug.ui.attention")["looked_at"] == win["pane"], 5, message="looking at the pane")
        run_a_turn(inst, sid, win["window"], win["tab"])
        time.sleep(0.5)
        r = row(inst, win["window"], win["tab"])
        assert r["mark"] == "none" and r["badge"] == "none", r
        item = next(i for i in inbox(inst)["items"] if i["pane"] == beside)
        assert item["category"] == "complete" and item["read"], item
    finally:
        inst.cli("agent", "stop", sid, check=False)


@pytest.mark.harness
@pytest.mark.req("S-3")
def test_a_sibling_that_finished_out_of_sight_keeps_its_mark(inst, win, active):
    """A finish nobody saw keeps its mark when the user later switches to a sibling pane of its tab;
    only a look at its own pane clears it (Warp marks items read for the focused pane only)."""
    a, tab = new_tab(inst, win)
    sid, beside = agent_beside(inst, a)
    inst.cli("pane", "focus", win["pane"])
    try:
        wait_until(lambda: rpc(inst, "debug.ui.attention")["looked_at"] == win["pane"], 5, message="looking elsewhere")
        run_a_turn(inst, sid, win["window"], tab)
        wait_until(lambda: row(inst, win["window"], tab)["mark"] == "finished", 5, message="finished out of sight")
        inst.cli("pane", "focus", a)
        wait_until(lambda: rpc(inst, "debug.ui.attention")["looked_at"] == a, 5, message="looking at the sibling")
        # Something unrelated changes (any agent's status or title): the mark stays.
        set_agent(inst, win["pane"], "claude", title="Unrelated", status="working")
        time.sleep(0.5)
        assert row(inst, win["window"], tab)["mark"] == "finished"
        assert not next(i for i in inbox(inst)["items"] if i["pane"] == beside)["read"]
        inst.cli("pane", "focus", beside)
        wait_until(lambda: row(inst, win["window"], tab)["mark"] == "none", 5, message="a look at its pane clears it")
    finally:
        clear_agent(inst, win["pane"])
        inst.cli("agent", "stop", sid, check=False)


@pytest.mark.harness
@pytest.mark.req("S-3")
def test_a_new_turn_clears_the_mark(inst, win):
    """The engine: a turn that ends out of sight marks the tab; the agent starting again clears the
    mark (and takes its stale inbox item away), as Warp does."""
    sid = inst.start_agent("claude", f"ECHO hi {uuid.uuid4().hex[:6]}")
    inst.wait(sid)
    pane = inst.json("agent", "open", sid)["pane"]   # a new tab, not focused
    tab = inst.json("pane", "info", pane)["tab"]
    window = inst.json("pane", "info", pane)["window"]
    inst.send(sid, "SLEEP 2")
    wait_until(lambda: row(inst, window, tab)["badge"] == "working", 15, message="the turn runs")
    wait_until(lambda: row(inst, window, tab)["mark"] == "finished", 20, message="the turn ended out of sight")
    assert row(inst, window, tab)["badge"] == "done"
    assert any(i["pane"] == pane and i["category"] == "complete" for i in inbox(inst)["items"])
    inst.send(sid, "SLEEP 4")
    wait_until(lambda: row(inst, window, tab)["badge"] == "working", 15, message="the new turn")
    assert row(inst, window, tab)["mark"] == "none"
    assert not any(i["pane"] == pane for i in inbox(inst)["items"]), "the stale item goes"
    inst.cli("agent", "stop", sid, check=False)


# ---- S-3: no desktop notifications from agents ----------------------------------------------------

@pytest.mark.req("S-3")
def test_an_agents_own_desktop_notifications_are_dropped(inst, win):
    """Claude Code and Codex post OSC 9 / 777 notifications; a pane running an agent session drops
    them, as Warp does for agents its plugin reports. Other panes keep Ghostty's behavior."""
    pane = win["pane"]
    before = inbox(inst)["dropped_notifications"]
    set_agent(inst, pane, "claude", title="Notifies", status="working")
    try:
        inst.cli("send", "--pane", pane, "-e", "printf '\\033]9;umi agent says hi\\007'; echo OSC9-SENT")
        wait_until(lambda: inbox(inst)["dropped_notifications"] == before + 1, 10, message="the OSC 9 is dropped")
        time.sleep(1.2)   # Ghostty lets one notification through per second
        inst.cli("send", "--pane", pane, "-e", "printf '\\033]777;notify;Title;Body\\007'; echo OSC777-SENT")
        wait_until(lambda: inbox(inst)["dropped_notifications"] == before + 2, 10, message="the OSC 777 is dropped")
    finally:
        clear_agent(inst, pane)
    time.sleep(1.2)
    inst.cli("send", "--pane", pane, "-e", "printf '\\033]9;a plain shell\\007'; echo OSC9-PLAIN")
    inst.cli("wait", "--pane", pane, "--pattern", "^OSC9-PLAIN", "--timeout", "10")
    time.sleep(0.5)
    assert inbox(inst)["dropped_notifications"] == before + 2, "a pane without an agent isn't affected"


# ---- AG-24: the inbox and toasts --------------------------------------------------------------------

@pytest.mark.req("AG-24")
def test_the_inbox_lists_agent_events_with_filters_and_keys(fresh):
    inst = fresh(prefix="acc-inbox-")
    win = window_for(inst, "inbox")
    a, tab_a = new_tab(inst, win)
    b, tab_b = new_tab(inst, win)
    c, tab_c = new_tab(inst, win)
    assert inbox(inst)["items"] == []
    finish(inst, a, title="Wrote the parser")
    set_agent(inst, b, "codex", title="Wants approval", status="working")
    set_agent(inst, b, "codex", title="Wants approval", status="needs_input", mark="needs_you")
    set_agent(inst, c, "claude", title="Broke", status="working")
    set_agent(inst, c, "claude", title="Broke", status="error", mark="finished")
    got = inbox(inst)
    assert [(i["title"], i["category"], i["read"]) for i in got["items"]] == [
        ("Broke", "error", False), ("Wants approval", "request", False), ("Wrote the parser", "complete", False)]
    assert [i["badge"] for i in got["items"]] == ["error", "needs_you", "done"]
    assert got["filters"] == ["all", "unread", "errors"]
    # A pane keeps one item: its newest.
    finish(inst, a, title="Wrote the parser again")
    assert [i["title"] for i in inbox(inst)["items"]].count("Wrote the parser again") == 1
    assert len(inbox(inst)["items"]) == 3

    got = rpc(inst, "debug.ui.inbox.toggle")
    assert got["open"] and got["filter"] == "all" and got["selected"] == 0
    assert rpc(inst, "debug.ui.inbox.key", key="tab")["filter"] == "unread"
    got = rpc(inst, "debug.ui.inbox.key", key="tab")
    assert got["filter"] == "errors" and [i["title"] for i in got["shown"]] == ["Broke"]
    assert rpc(inst, "debug.ui.inbox.key", key="tab")["filter"] == "all"
    assert rpc(inst, "debug.ui.inbox.key", key="down")["selected"] == 1
    assert rpc(inst, "debug.ui.inbox.key", key="down")["selected"] == 2
    assert rpc(inst, "debug.ui.inbox.key", key="down")["selected"] == 2, "stays on the last"
    assert rpc(inst, "debug.ui.inbox.key", key="up")["selected"] == 1
    shown = inbox(inst)["shown"]
    assert [i["pane"] for i in shown] == [a, c, b]
    got = rpc(inst, "debug.ui.inbox.key", key="return")
    assert not got["open"]
    wait_until(lambda: inst.tree().get("current_pane") == c, 5, message="Return goes to the session's pane")
    assert next(i for i in inbox(inst)["items"] if i["pane"] == c)["read"]
    assert rpc(inst, "debug.ui.inbox.toggle")["open"]
    assert not rpc(inst, "debug.ui.inbox.key", key="escape")["open"]

    # Looking at a pane reads its item; Unread and Errors show only while they have items.
    rpc(inst, "debug.ui.assume_active", on=True)
    inst.cli("pane", "focus", b)
    wait_until(lambda: next(i for i in inbox(inst)["items"] if i["pane"] == b)["read"], 5, message="read by a look")
    rpc(inst, "debug.ui.assume_active", on=False)
    # An agent starting again takes its item away.
    set_agent(inst, c, "claude", title="Broke", status="working")
    assert inbox(inst)["filters"] == ["all", "unread"]

    # At most 100, newest first.
    rpc(inst, "debug.ui.inbox.fill", count=105)
    got = inbox(inst)
    assert len(got["items"]) == 100
    assert got["items"][0]["title"] == "filler 104"


@pytest.mark.req("AG-24")
def test_unread_events_toast_in_the_active_window(fresh):
    inst = fresh(prefix="acc-toast-")
    win = window_for(inst, "toasts")
    a, _ = new_tab(inst, win)
    b, _ = new_tab(inst, win)
    c, _ = new_tab(inst, win)
    if not rpc(inst, "debug.ui.attention")["active"]:
        # Not in front: no toasts (the Dock badge covers it).
        finish(inst, a, title="Unseen")
        assert inbox(inst, window=win["window"])["window_toasts"] == []
        set_agent(inst, a, "claude", status="working")
    rpc(inst, "debug.ui.assume_active", on=True)
    try:
        inst.cli("pane", "focus", win["pane"])
        started = time.time()
        finish(inst, a, title="First")
        got = inbox(inst, window=win["window"])
        assert [t["title"] for t in got["window_toasts"]] == ["First"]
        # Two at most: the oldest goes.
        finish(inst, b, title="Second")
        set_agent(inst, c, "codex", title="Third", status="needs_input", mark="needs_you")
        assert [t["title"] for t in inbox(inst, window=win["window"])["window_toasts"]] == ["Second", "Third"]
        # Looking at the pane takes its toast away.
        inst.cli("pane", "focus", c)
        wait_until(lambda: [t["title"] for t in inbox(inst, window=win["window"])["window_toasts"]] == ["Second"], 5,
                   message="a look reads the item and takes its toast")
        # 8 seconds.
        time.sleep(max(0, 6.5 - (time.time() - started)))
        assert inbox(inst, window=win["window"])["window_toasts"], "still there before 8 s"
        wait_until(lambda: inbox(inst, window=win["window"])["window_toasts"] == [], 4, message="gone after 8 s")
        # ⌃⌘U dismisses; opening the inbox does too, and nothing toasts while it's open.
        set_agent(inst, a, "claude", status="working")
        finish(inst, a, title="Fourth")
        assert inbox(inst)["toasts"]
        assert rpc(inst, "debug.ui.inbox.dismiss")["toasts"] == []
        set_agent(inst, b, "claude", status="working")
        finish(inst, b, title="Fifth")
        assert rpc(inst, "debug.ui.inbox.toggle")["toasts"] == []
        set_agent(inst, a, "claude", status="working")
        finish(inst, a, title="Sixth")
        assert inbox(inst)["toasts"] == []
        rpc(inst, "debug.ui.inbox.toggle")
    finally:
        rpc(inst, "debug.ui.assume_active", on=False)


@pytest.mark.req("AG-24", "L-9")
def test_inbox_and_toast_keys_ui(fresh, ui):
    """The real keys: ⇧⌘U opens the inbox, ↓ and Return go to a session, Escape closes, ⌃⌘U dismisses
    the toasts. (The `ui` fixture checks the Accessibility permission; this drives its own instance.)"""
    from harness import UI
    inst = fresh(prefix="acc-inbox-ui-")
    win = window_for(inst, "inbox-ui")
    ui = UI(inst.app_pid)
    a, _ = new_tab(inst, win)
    b, _ = new_tab(inst, win)
    ui.activate()
    wait_until(lambda: rpc(inst, "debug.ui.attention")["active"], 5, message="the app in front")
    finish(inst, a, title="Older")
    finish(inst, b, title="Newer")
    wait_until(lambda: len(inbox(inst, window=win["window"])["window_toasts"]) == 2, 5, message="two toasts")
    assert ui.find(lambda e: ui.label(e) == "Toast: Newer") is not None
    ui.press_shortcut("cmd+ctrl+u")
    wait_until(lambda: inbox(inst)["toasts"] == [], 5, message="⌃⌘U dismisses the toasts")

    ui.press_shortcut("cmd+shift+u")
    wait_until(lambda: inbox(inst)["open"], 5, message="⇧⌘U opens the inbox")
    assert ui.find(lambda e: ui.label(e) == "Notifications") is not None
    assert inbox(inst)["selected"] == 0
    ui.key(125)   # ↓
    wait_until(lambda: inbox(inst)["selected"] == 1, 5, message="↓ selects the next item")
    ui.key(ui.RETURN)
    wait_until(lambda: not inbox(inst)["open"], 5, message="Return closes the inbox")
    wait_until(lambda: inst.tree().get("current_pane") == a, 5, message="Return goes to the older session")

    ui.press_shortcut("cmd+shift+u")
    wait_until(lambda: inbox(inst)["open"], 5, message="opens again")
    ui.key(48, ui.SHIFT)   # Shift-Tab
    wait_until(lambda: inbox(inst)["filter"] != "all", 5, message="Shift-Tab changes the filter")
    ui.key(ui.ESCAPE)
    wait_until(lambda: not inbox(inst)["open"], 5, message="Escape closes the inbox")
    ui.press_shortcut("cmd+shift+u")
    wait_until(lambda: inbox(inst)["open"], 5, message="opens again")
    ui.press_shortcut("cmd+shift+u")
    wait_until(lambda: not inbox(inst)["open"], 5, message="⇧⌘U closes it")


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
                   "notes": "Inbox on ⇧⌘U.\nToasts for agents."}, f)
    inst.start_app()
    window_for(inst, "note")
    wait_until(lambda: inbox(inst)["update_note"], 10, message="the note")
    assert inbox(inst)["update_note"] == {"version": version, "notes": "Inbox on ⇧⌘U.\nToasts for agents."}
    assert rpc(inst, "debug.ui.inbox.dismiss")["update_note"] is None
    # Once: the next launch says nothing.
    inst.quit_gracefully()
    inst.start_app()
    window_for(inst, "note-again")
    time.sleep(1)
    assert inbox(inst)["update_note"] is None


@pytest.mark.req("I-4")
def test_no_note_after_a_failed_update(fresh):
    inst = fresh(start_app=False, prefix="acc-upnote-failed-")
    os.makedirs(os.path.join(inst.dir, "updates"), exist_ok=True)
    with open(os.path.join(inst.dir, "updates", "attempt.json"), "w") as f:
        json.dump({"version": "999.0.0", "from": "0.0.1", "notes": "never installed"}, f)
    inst.start_app()
    window_for(inst, "no-note")
    time.sleep(1)
    assert inbox(inst)["update_note"] is None
