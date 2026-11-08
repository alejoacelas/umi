"""Moving panes and tabs from the keyboard (SPEC KM-1 to KM-5, L-9, L-11, L-13; design/attention-ui.md,
"Moving panes").

Hold ⌃⌘ and press the arrows: ←/→ move the focused pane within the tab it is over, ↑/↓ carry it to
the tab above or below, a new tab last. The window shows the target tab with the pane landed, the
sidebar comes out and lists every tab's panes; letting go of ⌃⌘ lands it, Esc cancels, ⌘Z undoes.
Keys are pressed with `debug.key` (inside the app), ⌃⌘ held with `hold` and let go with
`debug.release`; `debug.move` reports the move going on. The `_ui` tests use real keys and need an
unlocked screen.
"""

import time

import pytest

from harness import wait_until
from test_hidden_panes import events_since, hidden, iso_now, shown
from test_umi_panes_ui import new_tab, rpc, split, tab_of

pytestmark = pytest.mark.layout


def key(inst, win, keys, hold=False):
    return rpc(inst, "debug.key", window=win["window"], keys=keys, hold=hold, focus="none")


def move(inst, win):
    return rpc(inst, "debug.move", window=win["window"])


def tab_ids(inst, window):
    return [t["id"] for w in inst.tree()["windows"] if w["id"] == window for t in w["tabs"]]


def selected(inst, window):
    return next(w for w in inst.tree()["windows"] if w["id"] == window)["selected_tab"]


def row(state, tab):
    return next(r for r in state["rows"] if r["tab"] == tab)


def places(state, tab):
    return [p["place"] for p in row(state, tab)["panes"]]


def sidebar_visible(inst, win):
    return inst.json("sidebar", "status", "--window", win["window"])["visible"]


def setup(inst, win):
    """The window's tab with a, b, c on show (b focused), a second tab with d, e, and a third with
    f, g, h (full). The sidebar is hidden."""
    a = win["pane"]
    b = split(inst, "right", a, "--no-focus")
    c = split(inst, "right", b, "--no-focus")
    d, second = new_tab(inst, win)
    e = split(inst, "right", d, "--no-focus")
    f, third = new_tab(inst, win)
    g = split(inst, "right", f, "--no-focus")
    h = split(inst, "right", g, "--no-focus")
    inst.cli("sidebar", "off", "--window", win["window"])
    inst.cli("pane", "focus", b)
    tabs = tab_ids(inst, win["window"])
    assert tabs == [win["tab"], second, third], tabs
    return {"a": a, "b": b, "c": c, "d": d, "e": e, "f": f, "g": g, "h": h,
            "A": win["tab"], "B": second, "C": third}


@pytest.fixture
def moving(inst):
    """Let go of ⌃⌘ after each test, whatever happened."""
    yield
    rpc(inst, "debug.release")


# ---- KM-1: within the tab -----------------------------------------------------------------------

@pytest.mark.req("KM-1", "KM-4")
def test_ctrl_cmd_arrows_move_the_pane_within_its_tab_and_land_on_release(inst, win, moving):
    p = setup(inst, win)
    start = iso_now()
    key(inst, win, "ctrl+cmd+right", hold=True)
    state = move(inst, win)
    assert state["active"] and state["target"] == p["A"] and state["spot"] == 2, state
    # The preview is the layout itself.
    assert shown(inst, p["A"]) == [p["a"], p["c"], p["b"]]
    key(inst, win, "ctrl+cmd+right", hold=True)
    assert move(inst, win)["spot"] == 2, "→ at the right end stays"
    key(inst, win, "ctrl+cmd+left", hold=True)
    key(inst, win, "ctrl+cmd+left", hold=True)
    assert shown(inst, p["A"]) == [p["b"], p["a"], p["c"]]
    assert events_since(inst, start, "pane.moved") == [], "previews report nothing"
    rpc(inst, "debug.release")
    wait_until(lambda: not move(inst, win)["active"], 5, message="landed")
    assert shown(inst, p["A"]) == [p["b"], p["a"], p["c"]]
    assert inst.tree()["current_pane"] == p["b"], "the pane keeps focus"
    moved = events_since(inst, start, "pane.moved")
    assert len(moved) == 1 and moved[0]["cause"]["kind"] == "key", moved
    assert moved[0]["data"]["from"]["index"] == 2 and moved[0]["data"]["to"]["index"] == 1


@pytest.mark.req("KM-1")
def test_letters_with_ctrl_cmd_start_no_move(inst, win, moving):
    p = setup(inst, win)
    key(inst, win, "ctrl+cmd+r", hold=True)  # Rename Tab… : a ⌃⌘ shortcut with a letter
    assert not move(inst, win)["active"], "only an arrow starts a move"
    rpc(inst, "debug.release")
    assert shown(inst, p["A"]) == [p["a"], p["b"], p["c"]]


# ---- KM-2, KM-3: to other tabs, the preview and the sidebar -------------------------------------

@pytest.mark.req("KM-2", "KM-3")
def test_ctrl_cmd_down_shows_the_target_tab_with_the_pane_landed(inst, win, moving):
    p = setup(inst, win)
    assert not sidebar_visible(inst, win)
    key(inst, win, "ctrl+cmd+down", hold=True)
    state = move(inst, win)
    assert state["target"] == p["B"] and state["selected_tab"] == p["B"], state
    assert shown(inst, p["B"]) == [p["d"], p["e"], p["b"]], "it arrives at the right end of the tab"
    assert shown(inst, p["A"]) == [p["a"], p["c"]]
    assert state["sidebar_visible"] and sidebar_visible(inst, win), "the sidebar comes out for the move"
    # Every row lists its tab's panes; the target lists the moving pane; the source is marked.
    assert places(state, p["B"]) == ["shown", "shown", "moving"]
    assert places(state, p["A"]) == ["shown", "shown"] and row(state, p["A"])["source"]
    assert row(state, p["B"])["target"] and not row(state, p["C"])["target"]
    assert [x["title"] for x in row(state, p["B"])["panes"]][-1] == tab_of(inst, p["B"])["panes"][2]["title"]
    # ← picks its spot there.
    key(inst, win, "ctrl+cmd+left", hold=True)
    assert shown(inst, p["B"]) == [p["d"], p["b"], p["e"]]
    rpc(inst, "debug.release")
    wait_until(lambda: not move(inst, win)["active"], 5, message="landed")
    assert shown(inst, p["B"]) == [p["d"], p["b"], p["e"]] and shown(inst, p["A"]) == [p["a"], p["c"]]
    assert not sidebar_visible(inst, win), "the sidebar goes away again"
    assert inst.tree()["current_pane"] == p["b"] and selected(inst, win["window"]) == p["B"]


@pytest.mark.req("KM-2", "KM-3", "H-1")
def test_over_a_full_tab_the_preview_hides_the_pane_that_would_make_room(inst, win, moving):
    p = setup(inst, win)
    start = iso_now()
    key(inst, win, "ctrl+cmd+down", hold=True)
    key(inst, win, "ctrl+cmd+down", hold=True)
    state = move(inst, win)
    assert state["target"] == p["C"] and len(state["hid"]) == 1, state
    victim = state["hid"][0]
    assert victim in (p["f"], p["g"], p["h"]) and victim in hidden(inst, p["C"])
    assert len(shown(inst, p["C"])) == 3 and p["b"] in shown(inst, p["C"])
    assert places(state, p["C"]).count("hiding") == 1 and places(state, p["C"]).count("moving") == 1
    preview = shown(inst, p["C"])
    assert events_since(inst, start, "pane.hidden") == [], "previews report nothing"
    rpc(inst, "debug.release")
    wait_until(lambda: not move(inst, win)["active"], 5, message="landed")
    assert shown(inst, p["C"]) == preview and victim in hidden(inst, p["C"]), "it lands as shown"
    assert [e["data"]["pane"] for e in events_since(inst, start, "pane.hidden")] == [victim]
    assert len(events_since(inst, start, "pane.moved")) == 1


@pytest.mark.req("KM-4", "L-20")
def test_undo_puts_a_landed_move_back(inst, win, moving):
    p = setup(inst, win)
    key(inst, win, "ctrl+cmd+down", hold=True)
    key(inst, win, "ctrl+cmd+down", hold=True)
    victim = move(inst, win)["hid"][0]
    rpc(inst, "debug.release")
    wait_until(lambda: p["b"] in shown(inst, p["C"]), 5, message="landed")
    rpc(inst, "debug.menu.perform", title="Undo")
    wait_until(lambda: shown(inst, p["A"]) == [p["a"], p["b"], p["c"]], 5, message="undone")
    assert victim in shown(inst, p["C"]), "the pane hidden for it is back on show"


@pytest.mark.req("KM-4")
def test_esc_cancels_a_move(inst, win, moving):
    p = setup(inst, win)
    before = [shown(inst, p[t]) + hidden(inst, p[t]) for t in "ABC"]
    start = iso_now()
    key(inst, win, "ctrl+cmd+down", hold=True)
    key(inst, win, "ctrl+cmd+down", hold=True)
    key(inst, win, "esc")
    wait_until(lambda: not move(inst, win)["active"], 5, message="cancelled")
    assert [shown(inst, p[t]) + hidden(inst, p[t]) for t in "ABC"] == before
    assert selected(inst, win["window"]) == p["A"] and inst.tree()["current_pane"] == p["b"]
    assert not sidebar_visible(inst, win)
    assert events_since(inst, start, "pane.moved") == [] and events_since(inst, start, "pane.hidden") == []


# ---- KM-5: the targets -----------------------------------------------------------------------------

@pytest.mark.req("KM-5")
def test_a_new_tab_is_the_last_target(inst, win, moving):
    p = setup(inst, win)
    count = len(tab_ids(inst, win["window"]))
    # From the window's first tab, ↑ wraps to the last target: a new tab.
    inst.cli("tab", "move", p["A"], "--index", "1")
    inst.cli("pane", "focus", p["b"])
    key(inst, win, "ctrl+cmd+up", hold=True)
    state = move(inst, win)
    assert state["target"] == "new" and state["offers_new_tab"], state
    assert len(tab_ids(inst, win["window"])) == count + 1
    rpc(inst, "debug.release")
    wait_until(lambda: not move(inst, win)["active"], 5, message="landed")
    tabs = tab_ids(inst, win["window"])
    assert len(tabs) == count + 1 and shown(inst, tabs[-1]) == [p["b"]], "a tab of its own, last"


@pytest.mark.req("KM-5")
def test_a_pane_alone_in_its_tab_is_not_offered_a_new_tab(inst, win, moving):
    p = setup(inst, win)
    inst.cli("pane", "close", p["e"])
    wait_until(lambda: shown(inst, p["B"]) == [p["d"]], 5, message="closed")
    inst.cli("pane", "focus", p["d"])
    key(inst, win, "ctrl+cmd+down", hold=True)
    state = move(inst, win)
    assert state["active"] and not state["offers_new_tab"], state
    key(inst, win, "esc")


@pytest.mark.req("KM-5", "S-14")
def test_a_collapsed_group_opens_while_the_pane_is_over_it(inst, win, moving):
    p = setup(inst, win)
    rpc(inst, "debug.ui.menu.perform", tab=p["C"], title="New group with tab")
    group = rpc(inst, "debug.ui.groups", window=win["window"])["groups"][0]["id"]
    rpc(inst, "debug.ui.groups", window=win["window"], toggle=group)
    inst.cli("pane", "focus", p["b"])

    def collapsed():
        return next(g for g in rpc(inst, "debug.ui.groups", window=win["window"])["groups"] if g["id"] == group)["collapsed"]

    assert collapsed()
    key(inst, win, "ctrl+cmd+down", hold=True)
    key(inst, win, "ctrl+cmd+down", hold=True)
    assert move(inst, win)["target"] == p["C"] and not collapsed(), "open while the pane is over it"
    key(inst, win, "ctrl+cmd+down", hold=True)
    assert collapsed(), "closed again when it moves on"
    key(inst, win, "esc")


@pytest.mark.req("KM-1", "L-9")
def test_a_step_from_the_menu_lands_at_once(inst, win, moving):
    p = setup(inst, win)
    rpc(inst, "debug.menu.perform", title="Move Pane Left")
    assert not move(inst, win)["active"]
    assert shown(inst, p["A"]) == [p["b"], p["a"], p["c"]]
    rpc(inst, "debug.menu.perform", title="Move Pane to Tab Below")
    wait_until(lambda: p["b"] in shown(inst, p["B"]), 5, message="moved to the tab below")
    assert not move(inst, win)["active"]


# ---- Keyboard resizing is gone; tabs move with ⌃⇧↑/↓; ⇧⌘[ is the previous tab ------------------

@pytest.mark.req("KM-1", "L-19", "L-9")
def test_splits_are_not_resized_from_the_keyboard(inst, win):
    listed = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    for direction in ("up", "down", "left", "right"):
        entry = listed.get(f"ghostty:resize_split:{direction},10")
        assert entry is None or entry["keys"] == [], entry
        assert listed[f"pane.move_{direction}"]["keys"] == [f"ctrl+cmd+{direction}"], listed[f"pane.move_{direction}"]
    # `pane resize` stays, from the CLI.
    a = win["pane"]
    b = split(inst, "right", a)
    assert inst.cli("pane", "resize", a, "right", "5", check=False).returncode == 0
    assert b in shown(inst, win["tab"])


@pytest.mark.req("L-13")
def test_ctrl_shift_up_and_down_move_the_tab(inst, win):
    _, second = new_tab(inst, win)
    inst.cli("tab", "focus", second)
    order = tab_ids(inst, win["window"])
    index = order.index(second)
    key(inst, win, "ctrl+shift+up")
    wait_until(lambda: tab_ids(inst, win["window"]).index(second) == index - 1, 5, message="⌃⇧↑")
    key(inst, win, "ctrl+shift+down")
    wait_until(lambda: tab_ids(inst, win["window"]) == order, 5, message="⌃⇧↓")


@pytest.mark.req("L-11")
def test_shift_cmd_brackets_show_the_previous_and_next_tab_in_sidebar_order(inst, win):
    _, second = new_tab(inst, win)
    _, third = new_tab(inst, win)
    order = tab_ids(inst, win["window"])
    inst.cli("tab", "focus", second)
    i = order.index(second)
    key(inst, win, "cmd+shift+[")
    wait_until(lambda: selected(inst, win["window"]) == order[i - 1], 5, message="⇧⌘[ to the tab above")
    key(inst, win, "cmd+shift+]")
    key(inst, win, "cmd+shift+]")
    wait_until(lambda: selected(inst, win["window"]) == third, 5, message="⇧⌘] down twice")
    assert tab_ids(inst, win["window"]) == order
    proc = inst.cli("tab", "back", check=False)
    assert proc.returncode == 1, "`tab back` is removed"


# ---- With real keys (an unlocked screen) ------------------------------------------------------------

def _post(ui, code, down, flags):
    import Quartz
    event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
    Quartz.CGEventSetFlags(event, flags)
    Quartz.CGEventPostToPid(ui.pid, event)
    time.sleep(0.15)


@pytest.mark.req("KM-1", "KM-2", "KM-3", "KM-4")
def test_real_ctrl_cmd_arrows_move_and_land_on_release_ui(inst, win, ui, moving):
    import Quartz
    p = setup(inst, win)
    inst.cli("window", "focus", win["window"])
    ui.activate()
    held = Quartz.kCGEventFlagMaskCommand | Quartz.kCGEventFlagMaskControl
    _post(ui, 59, True, Quartz.kCGEventFlagMaskControl)   # ⌃ down
    _post(ui, 55, True, held)                             # ⌘ down
    _post(ui, 125, True, held)                            # ↓
    _post(ui, 125, False, held)
    wait_until(lambda: move(inst, win).get("target") == p["B"], 5, message="over the tab below")
    _post(ui, 123, True, held)                            # ←
    _post(ui, 123, False, held)
    wait_until(lambda: shown(inst, p["B"]) == [p["d"], p["b"], p["e"]], 5, message="← picked a spot")
    _post(ui, 55, False, Quartz.kCGEventFlagMaskControl)  # ⌘ up: lands
    _post(ui, 59, False, 0)
    wait_until(lambda: not move(inst, win)["active"], 5, message="landed on letting go")
    assert shown(inst, p["B"]) == [p["d"], p["b"], p["e"]] and shown(inst, p["A"]) == [p["a"], p["c"]]
    # Esc while held cancels.
    _post(ui, 59, True, Quartz.kCGEventFlagMaskControl)
    _post(ui, 55, True, held)
    _post(ui, 124, True, held)                            # →
    _post(ui, 124, False, held)
    wait_until(lambda: move(inst, win).get("active"), 5, message="moving again")
    _post(ui, 53, True, held)                             # Esc
    _post(ui, 53, False, held)
    wait_until(lambda: not move(inst, win)["active"], 5, message="Esc cancelled")
    _post(ui, 55, False, Quartz.kCGEventFlagMaskControl)
    _post(ui, 59, False, 0)
    assert shown(inst, p["B"]) == [p["d"], p["b"], p["e"]]


@pytest.mark.req("KM-3")
def test_the_rows_list_their_panes_to_accessibility_during_a_move_ui(inst, win, ui, moving):
    p = setup(inst, win)
    inst.cli("window", "focus", win["window"])
    ui.activate()
    key(inst, win, "ctrl+cmd+down", hold=True)
    title = tab_of(inst, p["B"])["panes"][0]["title"]

    def target_row():
        return ui.find(lambda e: "moving here" in (ui.value(e) or "") and "panes:" in (ui.value(e) or ""))

    found = wait_until(target_row, 5, message="the target row says the pane lands there")
    assert title in ui.value(found), ui.value(found)
    key(inst, win, "esc")
