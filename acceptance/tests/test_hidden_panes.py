"""Hidden panes, the three-pane limit and the pane strip (SPEC H-1 to H-8; CLI.md "Hidden panes").

A tab shows at most `visible_limit` panes (3); every way a pane arrives in a full tab hides the pane
the `strip.make-room` slot picks (not pinned, not focused, looked at longest ago). `pane hide` and
`pane show` take panes out and back; `--until` brings them back by itself. ⌘[ ⌘] walk every pane of
the tab: keys are pressed with `debug.key` (inside the app), ⌘ held with `hold` and let go with
`debug.release`. The `_ui` tests use real keys, clicks and drags and need an unlocked screen.
"""

import os
import time
import uuid

import pytest

from harness import Instance, wait_until
from test_umi_panes_ui import (_frame, _mouse_drag, _terminal_frames, _test_window, new_tab, ready, rpc, split,
                               tab_of, type_and_wait)

pytestmark = pytest.mark.layout


def shown(inst, tab_id):
    return [p["id"] for p in tab_of(inst, tab_id)["panes"] if not p["hidden"]]


def hidden(inst, tab_id):
    return [p["id"] for p in tab_of(inst, tab_id)["panes"] if p["hidden"]]


def three(inst, win):
    """The window's tab with three panes on show, a focused (b and c made without focus)."""
    a = win["pane"]
    b = split(inst, "right", a, "--no-focus")
    c = split(inst, "right", b, "--no-focus")
    assert shown(inst, win["tab"]) == [a, b, c]
    return a, b, c


def events_since(inst, start, name):
    return [e for e in inst.json("log", "--since", start, "--filter", name)["events"] if e["event"] == name]


def iso_now():
    import datetime
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


# ---- H-1: three panes on show, and making room ------------------------------------------------------

@pytest.mark.req("H-1", "L-1")
def test_a_tab_shows_three_panes_and_a_fourth_hides_one(inst, win):
    a, b, c = three(inst, win)
    marker = "HID-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, b, f"echo {marker}", marker)
    made = inst.json("split", "right", "--pane", c, "--no-focus")
    d = made["pane"]
    gone = made["hid"]
    assert gone in (b, c), "never the pane that arrived, never the focused one"
    tab = tab_of(inst, win["tab"])
    assert tab["visible_limit"] == 3 and tab["attributes"]["visible_count"] == "3"
    assert shown(inst, win["tab"]) == [p for p in [a, b, c, d] if p != gone]
    assert hidden(inst, win["tab"]) == [gone], "the hidden pane stays in its tab"
    # ls order: the panes on show in layout order, then the hidden ones; `strip` the same.
    assert [p["id"] for p in tab["panes"]] == tab["strip"]
    hid = next(p for p in tab["panes"] if p["id"] == gone)
    assert hid["hidden"] and hid["attributes"]["hidden"] == "true" and "frame" not in hid
    # Its program keeps running.
    marker2 = "HID2-" + uuid.uuid4().hex[:8]
    inst.cli("send", "--pane", gone, "-e", f"echo {marker2}")
    wait_until(lambda: marker2 in inst.cli("read", "--pane", gone, "--scrollback").stdout, 10,
               message="the hidden pane's shell still runs")
    assert gone in [p["id"] for p in inst.json("ls", "--where", "hidden")["panes"]]
    assert inst.tree()["current_pane"] == a, "focus stayed where it was"


@pytest.mark.req("H-1", "D-1")
def test_pinned_panes_are_never_hidden_to_make_room(inst, win):
    a, b, c = three(inst, win)
    inst.cli("pane", "set", b, "pinned=true")
    try:
        made = inst.json("split", "right", "--pane", c, "--no-focus")
        assert made["hid"] == c, "a focused, b pinned: c is the one hidden"
        # Every candidate pinned: the tab shows more than its limit rather than hide one.
        inst.cli("pane", "set", made["pane"], "pinned=true")
        inst.cli("pane", "show", c)
        pinned_all = [p for p in shown(inst, win["tab"]) if p != a]
        for p in pinned_all:
            inst.cli("pane", "set", p, "pinned=true")
        extra = inst.json("split", "right", "--pane", made["pane"], "--no-focus")
        assert "hid" not in extra and len(shown(inst, win["tab"])) >= 4
    finally:
        for p in [x["id"] for x in tab_of(inst, win["tab"])["panes"]]:
            inst.cli("pane", "unset", p, "pinned", check=False)


@pytest.mark.req("H-1", "E-9", "M-1", "L-20")
def test_every_way_a_pane_arrives_makes_room(inst, win, tmp_path):
    a, b, c = three(inst, win)
    # A file opened from a pane goes to its right; the tab makes room.
    md = tmp_path / "arrive.md"
    md.write_text("# Arrive\n")
    opened = inst.json("edit", str(md), "--pane", a)
    file_pane = opened["documents"][0]["pane"]
    assert len(opened["hid"]) == 1 and opened["hid"][0] != file_pane and opened["tab"] == win["tab"]
    assert shown(inst, win["tab"]).index(file_pane) == 1, "right of the calling pane"
    assert len(shown(inst, win["tab"])) == 3
    # A pane moved into a full tab.
    p2, t2 = new_tab(inst, win)
    moved = inst.json("pane", "move", p2, "--tab", win["tab"], "--no-focus")
    assert moved["hid"] and moved["hid"] != p2 and len(shown(inst, win["tab"])) == 3
    assert tab_of(inst, t2) is None
    # A pane reopened into a full tab.
    ready(inst, p2)
    inst.cli("pane", "close", p2)
    wait_until(lambda: p2 not in [p["id"] for p in tab_of(inst, win["tab"])["panes"]], 5, message="closed")
    inst.json("split", "right", "--pane", a, "--no-focus")
    assert len(shown(inst, win["tab"])) == 3
    before_hidden = set(hidden(inst, win["tab"]))
    inst.cli("reopen")
    wait_until(lambda: p2 in shown(inst, win["tab"]), 5, message="reopened on show")
    assert len(shown(inst, win["tab"])) == 3 and len(set(hidden(inst, win["tab"])) - before_hidden) == 1
    # Focusing a hidden pane brings it in at the right end, hiding another.
    target = hidden(inst, win["tab"])[0]
    focused = inst.json("pane", "focus", target)
    assert shown(inst, win["tab"])[-1] == target and focused["hid"] != target
    assert inst.tree()["current_pane"] == target
    # A lower limit hides at once; a higher one lets more in.
    inst.cli("tab", "set", "--tab", win["tab"], "visible_limit=2")
    assert len(shown(inst, win["tab"])) == 2 and target in shown(inst, win["tab"]), "the focused pane stays"
    inst.cli("tab", "unset", "--tab", win["tab"], "visible_limit")
    assert tab_of(inst, win["tab"])["visible_limit"] == 3


# ---- H-2: hide and show ------------------------------------------------------------------------------

@pytest.mark.req("H-2", "D-2")
def test_hide_and_show_a_pane(inst, win):
    a, b, c = three(inst, win)
    start = iso_now()
    assert inst.json("pane", "hide", b) == {"panes": [b]}
    assert shown(inst, win["tab"]) == [a, c] and hidden(inst, win["tab"]) == [b]
    attrs = inst.attributes(b)
    assert attrs["hidden"] == "true" and attrs.get("changed_at"), "hiding sets changed_at"
    ev = events_since(inst, start, "pane.hidden")
    assert ev and ev[-1]["data"]["pane"] == b and ev[-1]["data"]["tab"] == win["tab"] and ev[-1]["cause"]["kind"] == "cli"
    # A hidden pane stays hidden; it's still a pane of its tab for every command.
    inst.cli("pane", "hide", b)
    assert inst.json("pane", "info", b)["tab"] == win["tab"]
    # Hiding every pane on show fails, and changes nothing.
    inst.cli("pane", "hide", c)
    proc = inst.cli("pane", "hide", a, check=False)
    assert proc.returncode == 1 and "last pane on show" in proc.stderr
    assert shown(inst, win["tab"]) == [a]
    # Showing brings it in at the right end; focus stays unless --focus.
    out = inst.json("pane", "show", b)
    assert out == {"panes": [b], "hid": []}
    assert shown(inst, win["tab"]) == [a, b] and inst.tree()["current_pane"] == a
    assert events_since(inst, start, "pane.shown")[-1]["data"]["pane"] == b
    inst.cli("pane", "show", c, "--focus")
    assert shown(inst, win["tab"]) == [a, b, c] and inst.tree()["current_pane"] == c
    # A query hides every match.
    inst.cli("pane", "set", b, "hq=1")
    inst.cli("pane", "set", c, "hq=1")
    proc = inst.cli("pane", "hide", "hq=1", check=False)
    assert proc.returncode == 0 and shown(inst, win["tab"]) == [a]
    # Unless that would empty the tab.
    inst.cli("pane", "set", a, "hq=1")
    inst.cli("pane", "show", "hq=1")
    assert len(shown(inst, win["tab"])) == 3
    proc = inst.cli("pane", "hide", "hq=1", check=False)
    assert proc.returncode == 1 and len(shown(inst, win["tab"])) == 3
    proc = inst.cli("pane", "set", a, "hidden=false", check=False)
    assert proc.returncode == 1, "hidden is Umi's own key"


# ---- H-3: hide --until -------------------------------------------------------------------------------

@pytest.mark.req("H-3", "Q-1")
def test_a_pane_hidden_until_a_condition_comes_back_by_itself(inst, win):
    a, b, c = three(inst, win)
    start = iso_now()
    inst.cli("pane", "hide", b, "--until", "owner=me or agent.status=needs_input")
    listed = inst.json("pane", "until", b)
    assert listed["pane"] == b and listed["until"] == [{"query": "owner=me or agent.status=needs_input"}]
    inst.cli("pane", "set", b, "owner=you")
    time.sleep(0.5)
    assert b in hidden(inst, win["tab"]), "the condition doesn't hold yet"
    inst.cli("pane", "set", b, "owner=me")
    wait_until(lambda: b in shown(inst, win["tab"]), 5, message="back once the condition held")
    assert shown(inst, win["tab"])[-1] == b, "at the right end"
    assert inst.tree()["current_pane"] == a, "coming back never moves keyboard focus"
    ev = events_since(inst, start, "pane.shown")[-1]
    assert ev["data"]["pane"] == b and ev["data"].get("by_condition") is True and ev["cause"]["kind"] == "config"
    assert inst.attributes(b)["unseen"] == "true", "unseen until looked at"
    assert inst.json("pane", "until", b)["until"] == [], "showing clears its conditions"
    # A duration, and a query, as two options: the first to hold wins.
    inst.cli("pane", "hide", c, "--until", "2s", "--until", "owner=nobody")
    assert len(inst.json("pane", "until", c)["until"]) == 2
    wait_until(lambda: c in shown(inst, win["tab"]), 6, message="back after 2 s")
    # Showing a pane by hand clears its conditions.
    inst.cli("pane", "hide", c, "--until", "owner=me2")
    inst.cli("pane", "show", c)
    assert inst.json("pane", "until", c)["until"] == []
    # A condition that doesn't parse is refused.
    proc = inst.cli("pane", "hide", c, "--until", "owner=(", check=False)
    assert proc.returncode == 1 and c in shown(inst, win["tab"])


# ---- H-4: closes ---------------------------------------------------------------------------------------

@pytest.mark.req("H-4", "L-18")
def test_closing_the_last_pane_on_show_brings_a_hidden_one_in(inst, win):
    a, b, c = three(inst, win)
    ready(inst, a, b, c)
    inst.cli("pane", "hide", b)
    inst.cli("pane", "hide", c)
    # Closing a pane on show never brings a hidden one in by itself …
    d = split(inst, "right", a, "--no-focus")
    ready(inst, d)
    inst.cli("pane", "close", d)
    wait_until(lambda: shown(inst, win["tab"]) == [a], 5, message="d closed")
    assert sorted(hidden(inst, win["tab"])) == sorted([b, c])
    # … except the last one: a tab always shows a pane, so a hidden one comes in.
    inst.cli("pane", "close", a)
    wait_until(lambda: len(shown(inst, win["tab"])) == 1, 5, message="a hidden pane came in")
    assert tab_of(inst, win["tab"]) is not None, "the tab stays"
    assert shown(inst, win["tab"])[0] in (b, c)
    # A hidden pane whose program ends leaves its tab.
    left = hidden(inst, win["tab"])[0]
    inst.cli("send", "--pane", left, "-e", "exit")
    wait_until(lambda: left not in [p["id"] for p in tab_of(inst, win["tab"])["panes"]], 10, message="it left")


@pytest.mark.req("H-2")
def test_closing_a_tab_asks_first_when_a_hidden_pane_runs_a_program(inst, win):
    p, t = new_tab(inst, win)
    q = split(inst, "right", p, "--no-focus")
    ready(inst, p, q)
    inst.cli("send", "--pane", q, "-e", "sleep 100")
    time.sleep(1.5)
    inst.cli("pane", "hide", q)
    assert hidden(inst, t) == [q]
    rpc(inst, "debug.ui.menu.perform", tab=t, title="Close tab")
    sheet = wait_until(lambda: (lambda s: s if s["sheet"] else None)(rpc(inst, "debug.ui.sheet", window=win["window"])), 5,
                       message="a confirmation")
    assert any("Close" in text for text in sheet["texts"]), sheet
    assert tab_of(inst, t) is not None, "the tab closed without asking"
    rpc(inst, "debug.ui.sheet", window=win["window"], action="cancel")
    wait_until(lambda: not rpc(inst, "debug.ui.sheet", window=win["window"])["sheet"], 5, message="the dialog dismissed")
    time.sleep(0.5)
    assert hidden(inst, t) == [q], "Cancel closed the tab"


# ---- H-6: ⌘[ and ⌘] -------------------------------------------------------------------------------------

def key(inst, win, keys, hold=False):
    return rpc(inst, "debug.key", window=win["window"], keys=keys, hold=hold)


@pytest.mark.req("H-6", "L-9")
def test_cmd_brackets_walk_shown_panes_then_hidden_ones_and_land_on_release(inst, win):
    a, b, c = three(inst, win)
    d = split(inst, "right", c, "--no-focus")
    e = split(inst, "right", d, "--no-focus")
    inst.cli("pane", "focus", a)
    start_shown, start_hidden = shown(inst, win["tab"]), hidden(inst, win["tab"])
    assert len(start_shown) == 3 and len(start_hidden) == 2 and start_shown[0] == a
    order = start_shown + start_hidden
    # ⌘ held: ⌘] walks the panes on show …
    key(inst, win, "cmd+]", hold=True)
    assert inst.tree()["current_pane"] == order[1] and shown(inst, win["tab"]) == start_shown
    key(inst, win, "cmd+]", hold=True)
    assert inst.tree()["current_pane"] == order[2]
    # … then onto a hidden one, which comes in at the right end in place of another.
    key(inst, win, "cmd+]", hold=True)
    assert inst.tree()["current_pane"] == order[3]
    now = shown(inst, win["tab"])
    assert now[-1] == order[3] and len(now) == 3 and a in now, "the pane the walk began on stays"
    # Stepping on puts it back first and brings in the next one.
    key(inst, win, "cmd+]", hold=True)
    assert inst.tree()["current_pane"] == order[4]
    now = shown(inst, win["tab"])
    assert now[-1] == order[4] and order[3] not in now and len(now) == 3
    # On round to a pane that was on show: the layout as it was.
    key(inst, win, "cmd+]", hold=True)
    assert inst.tree()["current_pane"] == a and shown(inst, win["tab"]) == start_shown
    start = iso_now()
    rpc(inst, "debug.release")
    assert shown(inst, win["tab"]) == start_shown and hidden(inst, win["tab"]) == start_hidden
    assert not events_since(inst, start, "pane.shown"), "landing where it began changes nothing"
    # ⌘[ from the first pane goes back to the last hidden one, at the left end; releasing ⌘ keeps it.
    key(inst, win, "cmd+[", hold=True)
    assert inst.tree()["current_pane"] == order[4] and shown(inst, win["tab"])[0] == order[4]
    rpc(inst, "debug.release")
    assert shown(inst, win["tab"])[0] == order[4] and len(shown(inst, win["tab"])) == 3
    landed = events_since(inst, start, "pane.shown")
    assert [x["data"]["pane"] for x in landed] == [order[4]], "the walk reports where it landed"
    assert len(events_since(inst, start, "pane.hidden")) == 1
    # Without ⌘ held (the menu), each step lands at once.
    inst.cli("pane", "focus", shown(inst, win["tab"])[-1])
    tab = tab_of(inst, win["tab"])
    nxt = tab["strip"][tab["strip"].index(inst.tree()["current_pane"]) + 1]
    rpc(inst, "debug.menu.perform", title="Next Pane")
    wait_until(lambda: inst.tree()["current_pane"] == nxt, 5, message="the next pane")
    assert nxt in shown(inst, win["tab"])


# ---- H-7: restart, undo and launch configurations -------------------------------------------------------

@pytest.mark.req("H-7", "M-3")
def test_a_move_that_made_room_is_undone_with_the_pane_it_hid(inst, win):
    a, b, c = three(inst, win)
    p2, t2 = new_tab(inst, win)
    ready(inst, p2)
    moved = inst.json("pane", "move", p2, "--tab", win["tab"])
    gone = moved["hid"]
    assert inst.rpc("debug.undo")["undo"] == "Move Pane"
    inst.rpc("debug.menu.perform", title="Undo")
    wait_until(lambda: shown(inst, win["tab"]) == [a, b, c], 5, message="undone: the three as they were")
    assert hidden(inst, win["tab"]) == [] and gone in shown(inst, win["tab"])
    assert [p["id"] for p in tab_of(inst, t2)["panes"]] == [p2]


@pytest.mark.req("H-7", "R-3")
def test_hidden_panes_and_their_conditions_come_back_after_a_restart(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-h7-", restore=True)
    made = other.json("window", "new")
    a = made["pane"]
    b = other.cli("split", "right", "--pane", a, "--no-focus").stdout.strip()
    c = other.cli("split", "right", "--pane", b, "--no-focus").stdout.strip()
    marker = "KEPT-" + uuid.uuid4().hex[:8]
    other.cli("send", "--pane", c, "-e", f"echo {marker}")
    other.cli("pane", "hide", b, "--until", "owner=me")
    other.cli("pane", "hide", c)
    time.sleep(1)
    other.quit_app()
    other.start_app()
    window, tab, _ = other.find_pane(b)
    assert sorted(p["id"] for p in tab["panes"] if p["hidden"]) == sorted([b, c])
    assert [p["id"] for p in tab["panes"] if not p["hidden"]] == [a]
    assert other.json("pane", "until", b)["until"] == [{"query": "owner=me"}]
    other.cli("pane", "set", b, "owner=me")
    wait_until(lambda: not other.find_pane(b)[2]["hidden"], 5, message="the condition still works")


@pytest.mark.req("H-7", "L-21")
def test_launch_configurations_save_hidden_panes_and_open_the_rest_hidden(target, tmp_path):
    home = os.path.realpath(str(tmp_path / "xdg"))
    os.makedirs(os.path.join(home, "umi", "launch_configurations"))
    inst = Instance(target, prefix="acc-h7lc-", env={"XDG_CONFIG_HOME": home})
    inst.start_app()
    try:
        folders = []
        for name in "abcde":
            folders.append(str(tmp_path / name))
            os.makedirs(folders[-1])
        panes = "\n".join(f"            - cwd: {f}" for f in folders)
        with open(os.path.join(home, "umi", "launch_configurations", "five.yaml"), "w") as f:
            f.write(f"name: Five\nwindows:\n  - tabs:\n      - layout:\n          split_direction: horizontal\n          panes:\n{panes}\n")
        opened = inst.json("layout", "open", "five")
        window = next(w for w in inst.tree()["windows"] if w["id"] == opened["windows"][0])
        tab = window["tabs"][0]
        assert len(tab["panes"]) == 5
        assert [p["hidden"] for p in tab["panes"]] == [False, False, False, True, True], "the rest open hidden"
        # Saving includes hidden panes, marked is_hidden.
        inst.json("layout", "save", "again")
        text = open(os.path.join(home, "umi", "launch_configurations", "again.yaml")).read()
        assert text.count("is_hidden: true") == 2, text
        inst.cli("window", "close", window["id"])
        reopened = inst.json("layout", "open", "again")
        tab = next(t for w in inst.tree()["windows"] if w["id"] in reopened["windows"] for t in w["tabs"]
                   if len(t["panes"]) == 5)
        assert [p["hidden"] for p in tab["panes"]] == [False, False, False, True, True]
    finally:
        inst.cleanup()


# ---- H-5, H-6, H-8 with the real mouse and keyboard (unlocked screen) ------------------------------------

def strip_chips(ui, window=None):
    strip = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Pane strip", root=window), 5, message="the pane strip")
    return [e for e in ui.find_all(lambda e: ui.role(e) == "AXButton" and ui.label(e), root=strip)]


@pytest.mark.req("H-5")
def test_the_strip_names_every_pane_and_a_click_brings_a_hidden_one_in_ui(inst, win, ui):
    a, b, c = three(inst, win)
    for pane, name in ((a, "chip-a"), (b, "chip-b"), (c, "chip-c")):
        inst.cli("pane", "rename", pane, name)
    inst.cli("pane", "hide", b)
    window = _test_window(ui, inst, win)
    chips = wait_until(lambda: (lambda cs: cs if len(cs) == 3 else None)(strip_chips(ui, window)), 5, message="three chips")
    assert [ui.label(e) for e in chips] == ["chip-a", "chip-c", "chip-b"], "on show in layout order, then hidden"
    values = {ui.label(e): ui.value(e) for e in chips}
    assert values["chip-b"] == "hidden" and values["chip-a"].startswith("on show")
    # The chips sit in the title bar, above the panes.
    panes = wait_until(lambda: (lambda fs: fs if len(fs) == 2 else None)(_terminal_frames(ui, window)), 5, message="two panes")
    assert _frame(ui, chips[0])[1] + _frame(ui, chips[0])[3] <= min(f[1] for f in panes) + 1
    # A click on the hidden chip brings it in, focused.
    x, y, w, h = _frame(ui, next(e for e in chips if ui.label(e) == "chip-b"))
    _click((x + w / 2, y + h / 2))
    wait_until(lambda: b in shown(inst, win["tab"]), 5, message="the hidden pane came in")
    assert inst.tree()["current_pane"] == b
    # A click on a chip on show focuses its pane.
    chips = strip_chips(ui, window)
    x, y, w, h = _frame(ui, next(e for e in chips if ui.label(e) == "chip-a"))
    _click((x + w / 2, y + h / 2))
    wait_until(lambda: inst.tree()["current_pane"] == a, 5, message="a focused")
    # Panes have no grab handle at their top any more: the strip is the only one.
    assert not ui.find(lambda e: ui.label(e) == "Drag to move this pane", root=window)


@pytest.mark.req("H-6")
def test_real_cmd_brackets_walk_and_land_on_release_ui(inst, win, ui):
    import Quartz
    a, b, c = three(inst, win)
    d = split(inst, "right", c, "--no-focus")
    inst.cli("pane", "focus", a)
    start_shown = shown(inst, win["tab"])
    order = start_shown + hidden(inst, win["tab"])
    inst.cli("window", "focus", win["window"])
    ui.activate()
    cmd = Quartz.kCGEventFlagMaskCommand

    def post(code, down, flags):
        event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPostToPid(ui.pid, event)
        time.sleep(0.15)

    post(55, True, cmd)              # ⌘ down
    for _ in range(3):
        post(30, True, cmd)          # ]
        post(30, False, cmd)
    wait_until(lambda: inst.tree()["current_pane"] == order[3], 5, message="walked onto the hidden pane")
    assert shown(inst, win["tab"])[-1] == order[3]
    post(55, False, 0)               # ⌘ up: lands
    time.sleep(0.5)
    assert shown(inst, win["tab"])[-1] == order[3] and order[3] not in hidden(inst, win["tab"])
    # Walk on and back to a pane that was on show, then let go: the layout as it was.
    landed = shown(inst, win["tab"])
    post(55, True, cmd)
    post(33, True, cmd)              # [
    post(33, False, cmd)
    wait_until(lambda: inst.tree()["current_pane"] == landed[1], 5, message="back one")
    post(55, False, 0)
    time.sleep(0.5)
    assert shown(inst, win["tab"]) == landed


@pytest.mark.req("H-6")
def test_a_rebound_next_pane_key_walks_and_stepping_on_puts_the_layout_back_ui(inst, win, ui):
    import Quartz
    a, b, c = three(inst, win)
    d = split(inst, "right", c, "--no-focus")
    e = split(inst, "right", d, "--no-focus")
    inst.cli("pane", "focus", a)
    start_shown = shown(inst, win["tab"])
    order = start_shown + hidden(inst, win["tab"])
    assert len(order) == 5
    cmd, ctrl = Quartz.kCGEventFlagMaskCommand, Quartz.kCGEventFlagMaskControl

    def post(code, down, flags):
        event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPostToPid(ui.pid, event)
        time.sleep(0.15)

    try:
        inst.cli("shortcuts", "set", "pane.stack_next", "ctrl+cmd+]")
        inst.cli("window", "focus", win["window"])
        ui.activate()
        post(55, True, cmd)              # ⌘ down
        post(59, True, cmd | ctrl)       # ⌃ down
        for _ in range(3):
            post(30, True, cmd | ctrl)   # ]
            post(30, False, cmd | ctrl)
        wait_until(lambda: inst.tree()["current_pane"] == order[3], 5, message="walked onto the first hidden pane")
        # One more step, still held: the first hidden pane goes back and the next one comes in.
        post(30, True, cmd | ctrl)
        post(30, False, cmd | ctrl)
        wait_until(lambda: inst.tree()["current_pane"] == order[4], 5, message="walked onto the second hidden pane")
        assert order[3] in hidden(inst, win["tab"]), "stepping on didn't put the layout back"
        # The start layout with the next one brought in: one pane (never a, where the walk began)
        # hidden for it and the others closed up in their order, the new one at the right end.
        now = shown(inst, win["tab"])
        assert len(now) == 3 and now[-1] == order[4] and a in now
        assert now[:-1] == [p for p in start_shown if p in now], (now, start_shown)
        assert [p for p in start_shown if p not in now] == [p for p in hidden(inst, win["tab"]) if p in start_shown]
        post(59, False, cmd)
        post(55, False, 0)               # ⌘ up: lands
        time.sleep(0.5)
        assert shown(inst, win["tab"])[-1] == order[4]
    finally:
        inst.cli("shortcuts", "reset", "pane.stack_next")


@pytest.mark.req("H-8", "M-4")
def test_a_chip_dragged_onto_a_pane_edge_moves_its_pane_there_ui(inst, win, ui):
    a, b, c = three(inst, win)
    inst.cli("pane", "rename", c, "chip-drag")
    inst.cli("pane", "hide", c)
    window = _test_window(ui, inst, win)
    chip = next(e for e in strip_chips(ui, window) if ui.label(e) == "chip-drag")
    x, y, w, h = _frame(ui, chip)
    panes = wait_until(lambda: (lambda fs: fs if len(fs) == 2 else None)(_terminal_frames(ui, window)), 5, message="two panes")
    px, py, pw, ph = panes[0]
    # The left pane's left edge: the hidden pane lands before a.
    _mouse_drag((x + w / 2, y + h / 2), (px + 12, py + ph / 2))
    wait_until(lambda: shown(inst, win["tab"])[0] == c, 5, message="dropped on a's left edge")
    assert c not in hidden(inst, win["tab"])


@pytest.mark.req("H-8", "M-4")
def test_a_hidden_chip_dragged_out_of_the_window_gets_a_window_of_its_own_ui(inst, win, ui):
    from test_umi_panes_ui import _make_room_outside, _point_outside_windows
    a, b, c = three(inst, win)
    inst.cli("pane", "rename", c, "chip-out")
    inst.cli("pane", "hide", c)
    window = _test_window(ui, inst, win)
    _make_room_outside(ui, window)
    chip = next(e for e in strip_chips(ui, window) if ui.label(e) == "chip-out")
    x, y, w, h = _frame(ui, chip)
    end = _point_outside_windows(ui)
    assert end is not None, "no room outside the app's windows to drop, even with this one made smaller"
    before = {w["id"] for w in inst.tree()["windows"]}
    _mouse_drag((x + w / 2, y + h / 2), end)

    def new_window_with_c():
        for w in inst.tree()["windows"]:
            if w["id"] not in before and [p["id"] for t in w["tabs"] for p in t["panes"]] == [c]:
                return w
    wait_until(new_window_with_c, 5, message="a new window holding the hidden pane")
    assert shown(inst, win["tab"]) == [a, b] and c not in hidden(inst, win["tab"])


def _click(point):
    import Quartz
    for kind in (Quartz.kCGEventMouseMoved, Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        event = Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.1)
    time.sleep(0.3)
