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
