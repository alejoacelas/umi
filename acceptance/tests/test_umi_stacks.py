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


# ---- One header row (2026-11-07, "S1"): the chips take the place of the shown member's name ----

def strip_of(ui):
    return wait_until(lambda: ui.find(lambda e: ui.label(e) == "Stacked panes"), 5, message="the stack's row")


def rightmost(ui, label, root):
    """The element with this label farthest right in root (a chip's ✕ shares the header ✕'s label)."""
    from test_umi_editor_warp import frame
    found = ui.find_all(lambda e: ui.label(e) == label, root)
    return max(found, key=lambda e: frame(ui, e)[0]) if found else None


@pytest.mark.req("M-7", "E-24")
def test_a_stack_shows_one_row_with_its_chips_and_the_shown_files_controls_ui(inst, win, tmp_path, ui):
    """A stacked file pane draws no header of its own: the stack's 30-point row holds the grip, the
    chips (the shown file's tooltip is its path) and the file's Preview / Source, ⋯ and ✕; a
    right-click on the row opens the file's pane menu. Leaving the stack gives the header back."""
    import os

    from test_umi_editor_warp import ed, frame, open_file, open_menu_titles, right_click, K_ESC
    folder = tmp_path / "notes"
    folder.mkdir()
    path = folder / "plan.md"
    path.write_text("# Plan\n\nShip it.\n")
    a = win["pane"]
    f = open_file(inst, win, path)
    ready(inst, a)
    rpc(inst, "debug.ui.split.drop", pane=f, target=a, zone="center")
    assert shown(inst, win["tab"]) == [f] and stack_of(inst, win["tab"], a) == [a, f]
    inst.cli("window", "focus", win["window"])
    ui.activate()
    strip = strip_of(ui)
    group = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Editor"), 5, message="the file pane")
    sx, sy, sw, sh = frame(ui, strip)
    gx, gy, gw, gh = frame(ui, group)
    assert sh == pytest.approx(30, abs=1), f"one 30-point row: {sh}"
    assert gy - (sy + sh) == pytest.approx(0, abs=1), f"the editor starts right under the row: {gy - (sy + sh)}"
    # The file's own header isn't drawn.
    assert ui.find(lambda e: ui.label(e) == "More actions", group) is None, "no ⋯ in the editor"
    assert ui.button("Preview", group) is None and ui.button("Source", group) is None, "no switch in the editor"
    assert not any(t.startswith("notes") for t in ui.texts(group)), "no folder / name in the editor"
    # The row: the chips, then the file's controls on the right.
    chip = wait_until(lambda: ui.find(lambda e: ui.label(e) == "plan.md" and ui.role(e) != "AXStaticText", strip),
                      5, message="the file's chip")
    terminal_chip = [e for e in ui.find_all(lambda e: ui.role(e) == "AXButton" and ui.label(e), strip)
                     if not ui.label(e).startswith("Close")
                     and ui.label(e) not in ("plan.md", "Preview", "Source", "More actions")]
    assert terminal_chip, "a chip for the terminal too"
    help_text = ui.attr(chip, "AXHelp") or ""
    # The chip reads as one element, whose help joins its parts' tooltips: the name's first, then its ✕'s.
    assert os.path.realpath(help_text.split(", ")[0]) == os.path.realpath(path), f"the chip's tooltip is the path: {help_text!r}"
    more = ui.find(lambda e: ui.label(e) == "More actions", strip)
    preview, source = ui.button("Preview", strip), ui.button("Source", strip)
    close = rightmost(ui, "Close plan.md", strip)
    assert more is not None and preview is not None and source is not None and close is not None, ui.texts(strip)
    cx, _, cw, _ = frame(ui, chip)
    assert frame(ui, preview)[0] > cx + cw, "the switch is right of the chips"
    assert frame(ui, preview)[0] < frame(ui, more)[0] < frame(ui, close)[0], "Preview / Source, ⋯, ✕"
    assert sx + sw - (frame(ui, close)[0] + frame(ui, close)[2]) < 16, "✕ at the row's right end"
    # A right-click on the row (between the chips and the switch) opens the file's pane menu.
    gap_left = max(frame(ui, e)[0] + frame(ui, e)[2] for e in [chip] + terminal_chip)
    gap_right = frame(ui, preview)[0]
    assert gap_right - gap_left > 20, "room between the chips and the controls"
    right_click((gap_left, sy, gap_right - gap_left, sh))
    titles = wait_until(lambda: open_menu_titles(ui), 3, message="the row's right-click menu")
    ui.key(K_ESC)
    wait_until(lambda: not open_menu_titles(ui), 3, message="Esc closes the menu")
    assert titles == ["Maximize pane", "Refresh file", "Open in editor", "Copy file path"], titles
    # The switch works from the row.
    ui.press(source)
    wait_until(lambda: ed(inst, f)["mode"] == "source", 5, message="Source from the row")
    # The terminal leaves: the stack of one dissolves and the file's own header comes back.
    inst.cli("pane", "close", a)
    wait_until(lambda: ui.find(lambda e: ui.label(e) == "Stacked panes") is None, 5, message="the row gone")
    group = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Editor"), 5, message="the file pane")
    wait_until(lambda: ui.find(lambda e: ui.label(e) == "More actions", group), 5, message="the header back")
    assert ui.button("Preview", group) is not None


@pytest.mark.req("M-7", "E-24")
def test_the_rows_close_closes_the_shown_member_and_a_terminal_adds_no_controls_ui(inst, win, tmp_path, ui):
    from test_umi_editor_warp import open_file
    path = tmp_path / "todo.py"
    path.write_text("x = 1\n")
    f = open_file(inst, win, path)
    b = split(inst, "right", f)
    ready(inst, b)
    rpc(inst, "debug.ui.split.drop", pane=b, target=f, zone="center")
    assert shown(inst, win["tab"]) == [win["pane"], b] and stack_of(inst, win["tab"], f) == [f, b]
    inst.cli("window", "focus", win["window"])
    ui.activate()
    strip = strip_of(ui)
    # A terminal on show: the row has its chips and nothing else, as the strip had.
    wait_until(lambda: ui.find(lambda e: ui.label(e) == "todo.py", strip), 5, message="the file's chip")
    assert ui.find(lambda e: ui.label(e) in ("More actions", "Reload", "Preview", "Source"), strip) is None, \
        ui.texts(strip)
    # The file on show: its controls join the row; the row's ✕ closes it (the terminal stays).
    inst.cli("pane", "focus", f)
    more = wait_until(lambda: ui.find(lambda e: ui.label(e) == "More actions", strip_of(ui)), 5,
                      message="the file's ⋯ in the row")
    assert more is not None
    ui.press(rightmost(ui, "Close todo.py", strip_of(ui)))
    wait_until(lambda: f not in [p["id"] for p in tab_of(inst, win["tab"])["panes"]], 5, message="the file closed")
    assert shown(inst, win["tab"]) == [win["pane"], b] and not stack_of(inst, win["tab"], b)


@pytest.mark.req("M-7", "E-24")
def test_a_narrow_stacks_chips_are_never_cut_off_and_the_rest_wait_in_a_menu_ui(inst, win, tmp_path, ui):
    """A third-of-the-window place with seven members: every chip that shows is whole, inside the
    room between the grip and the controls; the shown one always shows; the others are in a "+N"
    chip whose menu shows one of them."""
    import re

    from test_umi_editor_warp import frame, open_menu_item, open_menu_titles
    a, b, c = three_places(inst, win)
    names = [f"a-rather-long-file-name-number-{i}.md" for i in range(1, 7)]
    for name in names:
        (tmp_path / name).write_text(f"# {name}\n")
        inst.cli("edit", str(tmp_path / name), "--pane", b)
    members = stack_of(inst, win["tab"], b)
    assert len(members) == 7, members
    inst.cli("window", "focus", win["window"])
    ui.activate()

    def check(shown_name):
        strip = strip_of(ui)
        sx, sy, sw, sh = frame(ui, strip)
        more = ui.find(lambda e: ui.label(e) == "More actions", strip)
        right_edge = frame(ui, ui.button("Preview", strip) or more)[0]
        chips = {ui.label(e): e for e in ui.find_all(lambda e: ui.label(e) in names and ui.role(e) != "AXStaticText", strip)}
        assert shown_name in chips, f"the shown chip shows: {ui.texts(strip)}"
        for name, e in chips.items():
            x, y, w, h = frame(ui, e)
            assert sx + 22 <= x and x + w <= right_edge + 0.5, f"{name} whole, left of the controls: {x}..{x + w} in {sx}..{right_edge}"
            assert w >= 60, f"{name} keeps a usable width: {w} (row {sx}+{sw}, controls from {right_edge}, chips {[(n, frame(ui, c)) for n, c in chips.items()]}, {ui.texts(strip)})"
        overflow = ui.find(lambda e: re.fullmatch(r"\d+ more", ui.label(e) or "") is not None, strip)
        assert overflow is not None, f"a +N chip for the rest: {ui.texts(strip)}"
        ox, _, ow, _ = frame(ui, overflow)
        assert ox + ow <= right_edge + 0.5, "the +N chip whole too"
        visible = [ui.label(e) for e in ui.find_all(lambda e: ui.role(e) == "AXButton" and ui.label(e), strip)
                   if ui.label(e) not in ("Preview", "Source") and not ui.label(e).startswith("Close")]
        assert len(visible) + int(ui.label(overflow).split()[0]) == 7, f"every member is a chip or in the menu: {visible}, {ui.texts(strip)}"
        return overflow, chips

    def settled(shown_name, timeout=5):
        """check() once the row has caught up (the last failure if it never does)."""
        import time
        deadline = time.time() + timeout
        while True:
            try:
                return check(shown_name)
            except AssertionError:
                if time.time() > deadline:
                    raise
                time.sleep(0.2)

    overflow, chips = settled(names[-1])
    hidden = [n for n in names if n not in chips]
    assert hidden, "some files wait in the menu"
    ui.press(overflow)
    titles = wait_until(lambda: open_menu_titles(ui), 3, message="the +N menu")
    assert set(hidden) <= set(titles), titles
    ui.press(open_menu_item(ui, hidden[0]))
    wait_until(lambda: [p["id"] for p in tab_of(inst, win["tab"])["panes"] if p.get("shown", True)][1] != members[-1],
               5, message="the picked file on show")
    settled(hidden[0])
