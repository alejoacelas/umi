"""Stacks (SPEC M-7): panes sharing one place, a strip of their names on top, ⌘[ / ⌘] between them.

Drops are driven through Umi's internal `debug.ui.split.drop` (the split view's drop target code);
the `ui` test uses real keys and needs the lead's run.
"""

import uuid

import pytest

from harness import wait_until
from test_umi_panes_ui import new_tab, ready, rpc, shares, split, tab_of, type_and_wait

pytestmark = pytest.mark.layout


def stack_of(inst, tab_id, pane):
    return next(p for p in tab_of(inst, tab_id)["panes"] if p["id"] == pane).get("stack")


def shown(inst, tab_id):
    return [p["id"] for p in tab_of(inst, tab_id)["panes"] if p.get("shown", True)]


@pytest.mark.req("M-7", "M-1")
def test_a_pane_dropped_on_the_middle_of_another_shares_its_place(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    marker = "STACK-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, a, f"echo {marker}", marker)
    # c dropped on b's middle: b and c share b's place, c on show and focused.
    rpc(inst, "debug.ui.split.drop", pane=c, target=b, zone="center")
    assert shown(inst, win["tab"]) == [a, c]
    assert stack_of(inst, win["tab"], b) == [b, c]
    assert inst.tree().get("current_pane") == c
    assert shares(inst, win["tab"], [a, c]) == pytest.approx([50, 50], abs=0.3)
    # A pane from another tab joins too; its tab, left empty, closes.
    p2, t2 = new_tab(inst, win)
    rpc(inst, "debug.ui.split.drop", pane=p2, target=c, zone="center")
    assert tab_of(inst, t2) is None
    assert stack_of(inst, win["tab"], b) == [b, c, p2] and shown(inst, win["tab"]) == [a, p2]
    # Focusing a member shows it.
    inst.cli("pane", "focus", b)
    assert shown(inst, win["tab"]) == [a, b]
    # a joins as well; its shell keeps running, output and all.
    rpc(inst, "debug.ui.split.drop", pane=a, target=b, zone="center")
    assert shown(inst, win["tab"]) == [a]
    assert marker in inst.cli("read", "--pane", a, "--scrollback").stdout
    # Closing the member on show shows the next one in its place.
    inst.cli("pane", "close", a)
    assert len(shown(inst, win["tab"])) == 1 and a not in stack_of(inst, win["tab"], b)
    # A member that isn't on show and whose program ends leaves the stack.
    hidden = [p["id"] for p in tab_of(inst, win["tab"])["panes"] if p.get("shown") is False]
    ready(inst, *hidden)
    inst.cli("send", "--pane", hidden[0], "-e", "exit")
    wait_until(lambda: hidden[0] not in [p["id"] for p in tab_of(inst, win["tab"])["panes"]], 10,
               message="the exited member left")
    # Two left, then one: an ordinary pane again.
    remaining = [p["id"] for p in tab_of(inst, win["tab"])["panes"]]
    assert len(remaining) == 2
    inst.cli("pane", "close", remaining[0])
    only = tab_of(inst, win["tab"])["panes"]
    assert len(only) == 1 and not only[0].get("stack")


@pytest.mark.req("M-7", "M-3")
def test_stacking_can_be_undone(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    # Its own step: the split's undo registration, made in the same pass of the run loop as the
    # stacking's, would join it into one undo group (a person's clicks are separate events).
    ready(inst, b)
    rpc(inst, "debug.ui.split.drop", pane=b, target=a, zone="center")
    assert shown(inst, win["tab"]) == [b]
    assert inst.rpc("debug.undo")["undo"] == "Stack Pane"
    inst.rpc("debug.menu.perform", title="Undo")
    wait_until(lambda: sorted(shown(inst, win["tab"])) == sorted([a, b]), 5, message="undone: side by side")
    assert not stack_of(inst, win["tab"], a)


@pytest.mark.req("M-7", "E-1")
def test_files_stack_with_terminals(inst, win, tmp_path):
    md = tmp_path / "stacked.md"
    md.write_text("# Stacked\n")
    inst.cli("edit", str(md), "--pane", win["pane"])
    file_pane = next(p["id"] for p in tab_of(inst, win["tab"])["panes"] if p.get("file"))
    rpc(inst, "debug.ui.split.drop", pane=file_pane, target=win["pane"], zone="center")
    assert shown(inst, win["tab"]) == [file_pane]
    assert inst.json("editor", "ls", "--tab", win["tab"])["documents"][0]["pane"] == file_pane
    inst.cli("pane", "focus", win["pane"])
    assert shown(inst, win["tab"]) == [win["pane"]]
    # A file already open, opened again, comes on show in its stack.
    inst.cli("edit", str(md), "--pane", win["pane"])
    assert shown(inst, win["tab"]) == [file_pane]


@pytest.mark.req("M-7")
def test_cmd_brackets_cycle_a_stack_and_the_strip_names_its_members_ui(inst, win, ui):
    a = win["pane"]
    b = split(inst, "right", a)
    rpc(inst, "debug.ui.split.drop", pane=b, target=a, zone="center")
    inst.cli("window", "focus", win["window"])
    ui.activate()
    wait_until(lambda: inst.tree().get("current_pane") == b, 5, message="b focused")
    ui.press_keys("cmd+[")
    wait_until(lambda: shown(inst, win["tab"]) == [a], 5, message="⌘[ showed a")
    ui.press_keys("cmd+]")
    wait_until(lambda: shown(inst, win["tab"]) == [b], 5, message="⌘] showed b")
    strip = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Stacked panes"), 5, message="the strip")
    names = [e for e in ui.find_all(lambda e: ui.role(e) == "AXButton" and ui.label(e), root=strip)]
    assert len(names) >= 2, "a name per member"


# ---- The fourth pane (2026-11-07): a tab shows three places; new panes past that stack ----------

def three_places(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    ready(inst, b, c)
    assert shown(inst, win["tab"]) == [a, b, c]
    return a, b, c


@pytest.mark.req("M-7", "L-1")
def test_a_fourth_split_joins_the_stack_at_the_split_pane(inst, win):
    a, b, c = three_places(inst, win)
    widths = shares(inst, win["tab"], [a, b, c])
    d = split(inst, "right", b)
    # d takes b's place, on show and focused; b waits in the stack. The tab's places don't change.
    assert shown(inst, win["tab"]) == [a, d, c]
    assert stack_of(inst, win["tab"], b) == [b, d]
    assert inst.tree().get("current_pane") == d
    assert shares(inst, win["tab"], [a, d, c]) == pytest.approx(widths, abs=0.5)
    # A fifth from d goes right after d in the strip's order.
    ready(inst, d)
    e = split(inst, "down", d)
    assert shown(inst, win["tab"]) == [a, e, c]
    assert stack_of(inst, win["tab"], b) == [b, d, e]
    # Split from the member waiting in the stack: still that place, right after the member on show.
    ready(inst, e)
    f = split(inst, "right", b, "--no-focus")
    assert shown(inst, win["tab"]) == [a, f, c]
    assert stack_of(inst, win["tab"], b) == [b, d, e, f]
    # e had keyboard focus and f covers it: focus moves to f, never staying on a pane not on show.
    assert inst.tree().get("current_pane") == f


@pytest.mark.req("M-7")
def test_without_focus_a_stacked_pane_leaves_focus_on_another_place(inst, win):
    a, b, c = three_places(inst, win)
    inst.cli("pane", "focus", a)
    d = split(inst, "right", c, "--no-focus")
    assert shown(inst, win["tab"]) == [a, b, d]
    assert stack_of(inst, win["tab"], c) == [c, d]
    assert inst.tree().get("current_pane") == a


@pytest.mark.req("M-7", "L-1")
def test_split_no_stack_splits_a_fourth_time(inst, win):
    a, b, c = three_places(inst, win)
    d = split(inst, "right", c, "--no-stack")
    assert shown(inst, win["tab"]) == [a, b, c, d]
    assert not any(p.get("stack") for p in tab_of(inst, win["tab"])["panes"])
    # The tab is past three places: a split without the flag still stacks.
    ready(inst, d)
    e = split(inst, "right", a)
    assert shown(inst, win["tab"]) == [e, b, c, d]
    assert stack_of(inst, win["tab"], a) == [a, e]


@pytest.mark.req("M-7")
def test_a_stack_counts_as_one_place(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    ready(inst, b, c)
    rpc(inst, "debug.ui.split.drop", pane=c, target=b, zone="center")
    assert shown(inst, win["tab"]) == [a, c]
    # Two places (one of them a stack of two): a new pane takes a place of its own.
    d = split(inst, "right", c)
    assert shown(inst, win["tab"]) == [a, c, d]
    assert stack_of(inst, win["tab"], b) == [b, c]
    # Three places now: the next one stacks.
    ready(inst, d)
    e = split(inst, "right", a)
    assert shown(inst, win["tab"]) == [e, c, d]
    assert stack_of(inst, win["tab"], a) == [a, e]


@pytest.mark.req("M-7")
def test_the_split_shortcut_stacks_a_fourth_pane(inst, win):
    """Ghostty's own split action (⌘D, the pane's right-click menu, AppleScript) goes the same way."""
    a, b, c = three_places(inst, win)
    before = {p["id"] for p in tab_of(inst, win["tab"])["panes"]}
    assert rpc(inst, "debug.terminal.action", pane=c, action="new_split:right")["ok"]
    new = wait_until(lambda: [p["id"] for p in tab_of(inst, win["tab"])["panes"] if p["id"] not in before],
                     10, message="the new pane")
    assert len(new) == 1
    assert shown(inst, win["tab"]) == [a, b, new[0]]
    assert stack_of(inst, win["tab"], c) == [c, new[0]]


@pytest.mark.req("M-7", "M-3")
def test_a_stacked_fourth_pane_can_be_undone_and_redone(inst, win):
    a, b, c = three_places(inst, win)
    d = split(inst, "right", b)
    assert stack_of(inst, win["tab"], b) == [b, d]
    assert inst.rpc("debug.undo")["undo"] == "New Pane"
    inst.rpc("debug.menu.perform", title="Undo")
    wait_until(lambda: shown(inst, win["tab"]) == [a, b, c], 5, message="undone: b on show again")
    assert not stack_of(inst, win["tab"], b)
    assert d not in [p["id"] for p in tab_of(inst, win["tab"])["panes"]]
    inst.rpc("debug.menu.perform", title="Redo")
    wait_until(lambda: shown(inst, win["tab"]) == [a, d, c], 5, message="redone: d on show")
    assert stack_of(inst, win["tab"], b) == [b, d]


@pytest.mark.req("M-7", "R-3")
def test_a_stacked_fourth_pane_survives_a_restart(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-m7r-", restore=True)
    a = other.json("window", "new")["pane"]
    b = split(other, "right", a)
    c = split(other, "right", b)
    ready(other, a, b, c)
    d = split(other, "right", b)
    tab = other.json("pane", "info", d)["tab"]
    assert stack_of(other, tab, b) == [b, d]
    other.quit_app()
    other.start_app()
    tabs = [t for w in other.tree()["windows"] for t in w["tabs"]]
    restored = [t for t in tabs if len(t["panes"]) == 4]
    assert len(restored) == 1, tabs
    panes = restored[0]["panes"]
    assert [p.get("shown", True) for p in panes] == [True, True, True, False]
    stacks = [p["stack"] for p in panes if p.get("stack")]
    assert stacks and all(len(s) == 2 for s in stacks), panes
