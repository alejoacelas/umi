"""Panes as Warp's (2026-11-05): the smallest pane and the dividers (L-19), the terminal's right-click
menu (L-31), synchronized input (L-32) and the interface's zoom (L-33).

Checks that need a mouse or the keyboard are marked `ui`: they press the real keys (⌥⌘I, ⌥⇧⌘I,
⌘= ⌘- ⌘0, ⌥⇧> ⌥⇧<) and right-click a pane, so run them only when nobody is using the Mac. The
others go through the CLI and Umi's internal `debug.ui.*` methods, which run the code the UI runs.
"""

import json
import os
import socket
import time
import uuid

import pytest

from harness import wait_until

pytestmark = pytest.mark.layout

MINIMUM = 190


# ---- helpers ------------------------------------------------------------------------------------

def rpc(inst, method, **params):
    with open(os.path.join(inst.dir, "instance.json")) as f:
        path = json.load(f)["socket"]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(60)
    s.connect(path)
    s.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    reply = json.loads(data)
    if reply.get("error"):
        raise AssertionError(f"{method}: {reply['error']}")
    return reply.get("result", reply)


def tab_of(inst, tab_id):
    for w in inst.tree()["windows"]:
        for t in w["tabs"]:
            if t["id"] == tab_id:
                return t
    return None


def frames(inst, tab_id):
    return {p["id"]: p["frame"] for p in tab_of(inst, tab_id)["panes"] if "frame" in p}


def split(inst, direction, pane, *extra):
    return inst.cli("split", direction, "--pane", pane, *extra).stdout.strip()


def menu_titles(inst, pane):
    return [i["title"] for i in rpc(inst, "debug.ui.pane.menu", pane=pane)["items"] if "title" in i]


def row(inst, window, tab):
    return next(r for r in rpc(inst, "debug.ui.rows", window=window)["rows"] if r["tab"] == tab)


def screen(inst, pane):
    return inst.cli("read", "--pane", pane).stdout


def zoomed_pane(inst, tab):
    return next((p["id"] for p in tab_of(inst, tab)["panes"] if p.get("zoomed")), None)


# ---- L-19: Warp's smallest pane -----------------------------------------------------------------

@pytest.mark.req("L-19")
def test_a_dragged_divider_stops_where_a_pane_would_get_smaller_than_190_points(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    total = sum(f["width"] for f in frames(inst, win["tab"]).values())
    if total < 2 * MINIMUM + 20:
        pytest.skip(f"the window is too narrow ({total} points) for two panes of {MINIMUM}")
    # Dragged nearly all the way left: a stops at the minimum.
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.02)
    f = frames(inst, win["tab"])
    assert MINIMUM - 1 <= f[a]["width"] <= MINIMUM + 6, f
    # And nearly all the way right: b does.
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.98)
    f = frames(inst, win["tab"])
    assert MINIMUM - 1 <= f[b]["width"] <= MINIMUM + 6, f
    # A drag within the limits goes where it's dropped.
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.5)
    f = frames(inst, win["tab"])
    assert abs(f[a]["width"] - f[b]["width"]) <= 3, f


@pytest.mark.req("L-19")
def test_a_keyboard_resize_below_190_points_is_refused(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    before = frames(inst, win["tab"])
    if before[a]["width"] < MINIMUM + 40:
        pytest.skip("the window is too narrow")
    # Far more cells than a has: refused, and nothing moves.
    result = inst.cli("pane", "resize", a, "left", "400", check=False)
    assert result.returncode != 0 and "190" in (result.stderr + result.stdout), result
    assert frames(inst, win["tab"]) == before
    # A step that keeps both panes above the minimum still works.
    inst.cli("pane", "resize", a, "left", "2")
    after = frames(inst, win["tab"])
    assert after[a]["width"] < before[a]["width"] and after[b]["width"] > before[b]["width"]


# ---- L-19: dividers -----------------------------------------------------------------------------

@pytest.mark.req("L-19")
def test_the_divider_color_is_warps_foreground_at_15_percent(inst, win):
    with open(os.path.join(inst.dir, "themes", "Umi Dark")) as f:
        theme = f.read()
    assert "split-divider-color = #262626" in theme


@pytest.mark.ui
@pytest.mark.req("L-19")
def test_the_divider_is_grabbed_4_points_either_side_ui(inst, win, ui):
    a = win["pane"]
    split(inst, "right", a)
    inst.cli("window", "focus", win["window"])
    ui.activate()
    divider = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Horizontal split divider"), 5,
                         message="the divider in the accessibility tree")
    size = ui.attr(divider, "AXSize")
    import ApplicationServices as AX  # noqa: N812
    width = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)[1].width
    assert width == pytest.approx(9, abs=0.5), f"the divider's grab area is {width} points wide"


# ---- L-31: the terminal's right-click menu ------------------------------------------------------

@pytest.mark.req("L-31")
def test_the_pane_menu_has_warps_items(inst, win):
    a = win["pane"]
    titles = menu_titles(inst, a)
    for title in ("Paste", "Clear", "Split Pane Right", "Split Pane Left", "Split Pane Down", "Split Pane Up",
                  "Reset Terminal", "Toggle Terminal Inspector", "Terminal Read-only"):
        assert title in titles, f"{title} missing from {titles}"
    # Warp offers Maximize and Close only in a split.
    assert "Maximize Pane" not in titles and "Close Pane" not in titles
    # Warp's order: Paste, then Clear, then the splits.
    assert titles.index("Paste") < titles.index("Clear") < titles.index("Split Pane Right")
    # Copy only with a selection.
    assert "Copy" not in titles


@pytest.mark.req("L-31")
def test_the_pane_menu_maximizes_minimizes_splits_and_closes(inst, win):
    a = win["pane"]
    rpc(inst, "debug.ui.pane.menu", pane=a, title="Split Pane Right")
    wait_until(lambda: len(tab_of(inst, win["tab"])["panes"]) == 2, 5, message="Split Pane Right")
    b = next(p["id"] for p in tab_of(inst, win["tab"])["panes"] if p["id"] != a)
    titles = menu_titles(inst, a)
    assert titles.index("Split Pane Up") < titles.index("Maximize Pane") < titles.index("Close Pane"), titles
    rpc(inst, "debug.ui.pane.menu", pane=a, title="Maximize Pane")
    wait_until(lambda: zoomed_pane(inst, win["tab"]) == a, 5, message="a maximized")
    assert "Minimize Pane" in menu_titles(inst, a)
    rpc(inst, "debug.ui.pane.menu", pane=a, title="Minimize Pane")
    wait_until(lambda: zoomed_pane(inst, win["tab"]) is None, 5, message="a back in its split")
    # Close Pane closes the pane it was opened on, focused or not, right away when only its shell runs.
    wait_until(lambda: screen(inst, b).strip() != "", 20, message="b's prompt")
    inst.cli("pane", "focus", a)
    rpc(inst, "debug.ui.pane.menu", pane=b, title="Close Pane")
    wait_until(lambda: [p["id"] for p in tab_of(inst, win["tab"])["panes"]] == [a], 10, message="b closed")
    rpc(inst, "debug.ui.pane.menu", pane=a, title="Split Pane Down")
    wait_until(lambda: len(tab_of(inst, win["tab"])["panes"]) == 2, 5, message="Split Pane Down")
    f = frames(inst, win["tab"])
    assert len({round(v["x"]) for v in f.values()}) == 1, f"split down puts the new pane below: {f}"


@pytest.mark.ui
@pytest.mark.req("L-31")
def test_right_clicking_a_pane_opens_warps_menu_ui(inst, win, ui):
    from test_umi_panes_ui import _frame, _right_click
    a = win["pane"]
    b = split(inst, "right", a)
    inst.cli("window", "focus", win["window"])
    ui.activate()
    time.sleep(0.5)
    panes = wait_until(lambda: [e for e in ui.find_all(lambda e: ui.label(e) == "Terminal pane")
                                if ui.attr(e, "AXSize") is not None] or None, 5, message="the panes")
    # The left pane of this window: the leftmost of the two in the frontmost window.
    window = ui.attr(ui.app, "AXFocusedWindow")
    mine = [e for e in panes if _window_of(ui, e) == window] or panes
    left = min(mine, key=lambda e: _frame(ui, e)[0])

    def open_menu():
        _right_click(_frame(ui, left))
        return wait_until(lambda: ui.find_all(lambda e: ui.role(e) == "AXMenu"), 3, message="the pane's menu")

    def choose(title):
        menus = open_menu()
        item = next((e for m in menus for e, _ in ui.walk(m) if ui.role(e) == "AXMenuItem" and ui.label(e) == title), None)
        titles = [t for m in menus for t in ui.texts(m)]
        assert item is not None, f"{title} missing from the menu ({titles})"
        ui.press(item)
        time.sleep(0.5)
        return titles

    titles = choose("Maximize Pane")
    for title in ("Paste", "Clear", "Split Pane Right", "Split Pane Down", "Close Pane"):
        assert title in titles, f"{title} missing from {titles}"
    wait_until(lambda: zoomed_pane(inst, win["tab"]) == a, 5, message="Maximize Pane")
    choose("Minimize Pane")
    wait_until(lambda: zoomed_pane(inst, win["tab"]) is None, 5, message="Minimize Pane")
    choose("Close Pane")
    wait_until(lambda: [p["id"] for p in tab_of(inst, win["tab"])["panes"]] == [b], 10, message="Close Pane")


def _window_of(ui, element):
    while element is not None and ui.role(element) != "AXWindow":
        element = ui.attr(element, "AXParent")
    return element


# ---- L-32: synchronized input -------------------------------------------------------------------

KEY_I = 34


def type_line(ui, text):
    ui.type_text(text)
    ui.key(ui.RETURN)


@pytest.mark.ui
@pytest.mark.req("L-32")
def test_option_command_i_types_into_every_pane_of_the_tab_ui(inst, win, ui):
    a = win["pane"]
    b = split(inst, "right", a)
    other = inst.json("tab", "new", "--window", win["window"], "--no-focus")
    c = other["pane"]
    wait_until(lambda: screen(inst, c).strip() != "", 20, message="the other tab's prompt")
    inst.cli("window", "focus", win["window"])
    inst.cli("tab", "focus", win["tab"])
    inst.cli("pane", "focus", a)
    ui.activate()
    time.sleep(0.5)
    # The key is the Window menu's item, and the inspector moved off it.
    item = ui.shortcut("cmd+option+i")
    assert item is not None and ui.label(item) == "Toggle Synchronizing All Panes in Current Tab"
    inspector = ui.shortcut("cmd+option+ctrl+i")
    assert inspector is not None and "Inspector" in ui.label(inspector), "the inspector's new key is ⌃⌥⌘I"
    try:
        ui.key(KEY_I, ui.CMD | ui.OPT)
        wait_until(lambda: row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="the tab synced")
        assert not row(inst, win["window"], other["tab"]).get("input_synced")
        marker = "sync" + uuid.uuid4().hex[:8]
        type_line(ui, f"echo {marker}-$((40+2))")
        wait_until(lambda: f"{marker}-42" in screen(inst, a), 10, message="a ran it")
        wait_until(lambda: f"{marker}-42" in screen(inst, b), 10, message="b got the same keys")
        assert marker not in screen(inst, c), "a tab that isn't synced got the keys"
        # ⌥⇧⌘I stops it.
        ui.key(KEY_I, ui.CMD | ui.OPT | ui.SHIFT)
        wait_until(lambda: not row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="stopped")
        alone = "alone" + uuid.uuid4().hex[:8]
        type_line(ui, f"echo {alone}")
        wait_until(lambda: alone in screen(inst, a), 10, message="a ran it")
        time.sleep(1)
        assert alone not in screen(inst, b), "b still got a's keys after ⌥⇧⌘I"
        # Every tab of the window (Window ▸ Synchronize Input).
        ui.choose(ui.menu_item("Toggle Synchronizing All Panes in All Tabs"))
        wait_until(lambda: row(inst, win["window"], other["tab"]).get("input_synced"), 5, message="all tabs synced")
        assert row(inst, win["window"], win["tab"]).get("input_synced")
        everywhere = "every" + uuid.uuid4().hex[:8]
        inst.cli("pane", "focus", a)
        type_line(ui, f"echo {everywhere}")
        wait_until(lambda: everywhere in screen(inst, c), 10, message="the other tab got the keys")
        # ⌥⌘I in a window syncing every tab leaves the others synced and this one not, as Warp.
        ui.key(KEY_I, ui.CMD | ui.OPT)
        wait_until(lambda: not row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="this tab out")
        assert row(inst, win["window"], other["tab"]).get("input_synced")
    finally:
        item = ui.menu_item("Stop Synchronizing Any Panes")
        if item is not None and ui.attr(item, "AXEnabled"):
            ui.choose(item)


# ---- L-33: the interface's zoom -----------------------------------------------------------------

KEY_EQUAL, KEY_MINUS, KEY_ZERO, KEY_PERIOD, KEY_COMMA = 24, 27, 29, 47, 43


def zoom(inst, pane):
    return rpc(inst, "debug.ui.zoom", pane=pane)


# Keys delivered inside the app (Umi's internal `debug.key`: what the app's key monitor does with
# a key press, then the focused view), so these run without the accessibility tree; the `ui`
# tests below press the same keys through the system.

def key(inst, win, keys):
    return rpc(inst, "debug.key", window=win["window"], keys=keys, focus="terminal")


def word(prefix):
    """A marker of letters with no letter twice in a row (a key pressed again with no key-up in
    between is dropped)."""
    letters = [c for c in "abcdefghijklmnopqrstuvwxyz"]
    import random
    out = prefix
    while len(out) < len(prefix) + 6:
        c = random.choice(letters)
        if c != out[-1]:
            out += c
    return out


def type_keys(inst, win, text):
    for ch in text:
        key(inst, win, "space" if ch == " " else ch)
    key(inst, win, "return")


@pytest.mark.req("L-32", "L-9")
def test_the_sync_keys_are_menu_items_and_the_inspector_moved(inst, win):
    items = rpc(inst, "debug.menu")["items"]
    for title, k, mods in (("Toggle Synchronizing All Panes in Current Tab", "i", ["option", "cmd"]),
                           ("Stop Synchronizing Any Panes", "i", ["option", "shift", "cmd"])):
        found = [i for i in items if i["title"] == title]
        assert len(found) == 1 and found[0]["key"].lower() == k and sorted(found[0]["modifiers"]) == sorted(mods), found
        same = [i["title"] for i in items if i["key"].lower() == k and sorted(i["modifiers"]) == sorted(mods)]
        assert same == [title], f"{title}: the key is also on {same}"
    assert [i for i in items if i["title"] == "Toggle Synchronizing All Panes in All Tabs"]
    shortcuts = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    assert shortcuts["input.sync_tab"]["keys"] == ["option+cmd+i"]
    assert shortcuts["input.sync_stop"]["keys"] == ["option+shift+cmd+i"]
    inspector = shortcuts.get("ghostty:inspector:toggle")
    assert inspector is not None and inspector["display"] == ["⌃⌥⌘I"], inspector


@pytest.mark.req("L-32")
def test_option_command_i_types_into_every_pane_of_the_tab(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    other = inst.json("tab", "new", "--window", win["window"], "--no-focus")
    c = other["pane"]
    wait_until(lambda: screen(inst, c).strip() != "" and screen(inst, b).strip() != "", 20, message="the prompts")
    inst.cli("tab", "focus", win["tab"])
    inst.cli("pane", "focus", a)
    try:
        assert key(inst, win, "option+cmd+i")["handled"]
        wait_until(lambda: row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="the tab synced")
        assert not row(inst, win["window"], other["tab"]).get("input_synced")
        marker = word("syn")
        type_keys(inst, win, f"echo {marker}")
        wait_until(lambda: screen(inst, a).count(marker) >= 2, 10, message=f"a ran it: {screen(inst, a)!r}")
        wait_until(lambda: screen(inst, b).count(marker) >= 2, 10,
                   message=f"b got the same keys and ran them: {screen(inst, b)!r}")
        assert marker not in screen(inst, c), "a tab that isn't synced got the keys"
        # ⌥⇧⌘I stops it.
        assert key(inst, win, "option+shift+cmd+i")["handled"]
        wait_until(lambda: not row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="stopped")
        alone = word("alo")
        type_keys(inst, win, f"echo {alone}")
        wait_until(lambda: screen(inst, a).count(alone) >= 2, 10, message="a ran it")
        time.sleep(0.5)
        assert alone not in screen(inst, b), "b still got a's keys after ⌥⇧⌘I"
        # Every tab of the window.
        rpc(inst, "debug.menu.perform", title="Toggle Synchronizing All Panes in All Tabs")
        wait_until(lambda: row(inst, win["window"], other["tab"]).get("input_synced"), 5, message="all tabs synced")
        everywhere = word("eve")
        type_keys(inst, win, f"echo {everywhere}")
        wait_until(lambda: screen(inst, c).count(everywhere) >= 2, 10, message="the other tab got the keys")
        wait_until(lambda: screen(inst, b).count(everywhere) >= 2, 10, message="b got the keys")
        # ⌥⌘I in a window syncing every tab: this tab stops, the others stay synced (Warp).
        assert key(inst, win, "option+cmd+i")["handled"]
        wait_until(lambda: not row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="this tab out")
        assert row(inst, win["window"], other["tab"]).get("input_synced")
        # ⌘ shortcuts stay with the pane: ⌘K clears only a.
        assert key(inst, win, "option+cmd+i")["handled"]
        wait_until(lambda: row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="synced again")
        key(inst, win, "cmd+k")
        wait_until(lambda: everywhere not in screen(inst, a), 5, message="⌘K cleared a")
        time.sleep(0.5)
        assert everywhere in screen(inst, b), "⌘K went to b too"
    finally:
        rpc(inst, "debug.menu.perform", title="Stop Synchronizing Any Panes")
    assert not row(inst, win["window"], other["tab"]).get("input_synced")


@pytest.mark.req("L-33", "L-9")
def test_the_zoom_and_font_keys(inst, win):
    a = win["pane"]
    start = zoom(inst, a)
    assert start["level"] == 100
    shortcuts = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    assert shortcuts["view.zoom_in"]["keys"] == ["cmd+="]
    assert shortcuts["view.zoom_out"]["keys"] == ["cmd+-"]
    assert shortcuts["view.zoom_reset"]["keys"] == ["cmd+0"]
    assert shortcuts["view.font_bigger"]["keys"] == ["option+shift+."]
    assert shortcuts["view.font_smaller"]["keys"] == ["option+shift+,"]
    for action in ("increase_font_size:1", "decrease_font_size:1", "reset_font_size"):
        entry = shortcuts.get("ghostty:" + action)
        assert entry is None or entry["keys"] == [], (action, entry)
    try:
        assert key(inst, win, "cmd+=")["handled"]
        wait_until(lambda: zoom(inst, a)["level"] == 110, 5, message="⌘= to 110%")
        wait_until(lambda: zoom(inst, a)["cell_width_px"] > start["cell_width_px"], 5, message="the terminal's text grew")
        assert zoom(inst, a)["terminal_font_size"] == pytest.approx(start["font_size"] * 1.1, abs=0.05)
        key(inst, win, "cmd+=")
        key(inst, win, "cmd+=")
        wait_until(lambda: zoom(inst, a)["level"] == 150, 5, message="Warp's levels: 110, 125, 150")
        # A new pane gets the zoomed size.
        b = split(inst, "right", a)
        wait_until(lambda: zoom(inst, b)["cell_width_px"] == zoom(inst, a)["cell_width_px"], 5, message="the new pane's size")
        for _ in range(4):
            key(inst, win, "cmd+-")
        wait_until(lambda: zoom(inst, a)["level"] == 90, 5, message="⌘- ×4 to 90%")
        with open(os.path.join(inst.dir, "zoom.json")) as f:
            assert json.load(f)["level"] == 90
        assert key(inst, win, "cmd+0")["handled"]
        wait_until(lambda: zoom(inst, a)["level"] == 100, 5, message="⌘0")
        wait_until(lambda: zoom(inst, a)["cell_width_px"] == start["cell_width_px"], 5, message="the text back")
        # ⌥⇧> / ⌥⇧<: the font size, a point at a time.
        assert key(inst, win, "option+shift+.")["handled"]
        wait_until(lambda: zoom(inst, a)["font_size"] == start["font_size"] + 1, 5, message="⌥⇧>")
        wait_until(lambda: zoom(inst, a)["cell_width_px"] > start["cell_width_px"], 5, message="bigger text")
        wait_until(lambda: zoom(inst, b)["cell_width_px"] == zoom(inst, a)["cell_width_px"], 5, message="in every pane")
        key(inst, win, "option+shift+,")
        key(inst, win, "option+shift+,")
        wait_until(lambda: zoom(inst, a)["font_size"] == start["font_size"] - 1, 5, message="⌥⇧< twice")
        assert "˘" not in screen(inst, a) and "¯" not in screen(inst, a), "the key reached the shell"
    finally:
        key(inst, win, "cmd+0")
        rpc(inst, "debug.menu.perform", title="Reset Font Size")
    wait_until(lambda: zoom(inst, a)["font_size"] == start["font_size"] and zoom(inst, a)["level"] == 100
               and zoom(inst, a)["cell_width_px"] == start["cell_width_px"], 5, message="back to the start")


@pytest.mark.ui
@pytest.mark.req("L-33")
def test_command_equals_minus_and_zero_zoom_the_interface_ui(inst, win, ui):
    from test_umi_panes_ui import _frame
    a = win["pane"]
    inst.cli("window", "focus", win["window"])
    ui.activate()
    time.sleep(0.5)
    start = zoom(inst, a)
    assert start["level"] == 100
    title = row(inst, win["window"], win["tab"])["line1"]
    element = wait_until(lambda: ui.find(lambda e: ui.role(e) == "AXStaticText" and ui.value(e) == title), 5,
                         message="the row's title")
    text_height = _frame(ui, element)[3]
    try:
        ui.key(KEY_EQUAL, ui.CMD)
        wait_until(lambda: zoom(inst, a)["level"] == 110, 5, message="⌘= to 110%")
        z = wait_until(lambda: (lambda z: z if z["cell_width_px"] > start["cell_width_px"] else None)(zoom(inst, a)), 5,
                       message="the terminal's text grew")
        assert z["terminal_font_size"] == pytest.approx(start["font_size"] * 1.1, abs=0.05)
        # The sidebar grew too.
        element = ui.find(lambda e: ui.role(e) == "AXStaticText" and ui.value(e) == title)
        assert _frame(ui, element)[3] == pytest.approx(text_height * 1.1, rel=0.08)
        # Warp's levels: 110 → 125 → 150.
        ui.key(KEY_EQUAL, ui.CMD)
        ui.key(KEY_EQUAL, ui.CMD)
        wait_until(lambda: zoom(inst, a)["level"] == 150, 5, message="⌘= ⌘= to 150%")
        for _ in range(4):
            ui.key(KEY_MINUS, ui.CMD)
        wait_until(lambda: zoom(inst, a)["level"] == 90, 5, message="⌘- ×4 to 90%")
        with open(os.path.join(inst.dir, "zoom.json")) as f:
            assert json.load(f)["level"] == 90
        ui.key(KEY_ZERO, ui.CMD)
        wait_until(lambda: zoom(inst, a)["level"] == 100, 5, message="⌘0 back to 100%")
        wait_until(lambda: zoom(inst, a)["cell_width_px"] == start["cell_width_px"], 5, message="the terminal's text back")
    finally:
        if zoom(inst, a)["level"] != 100:
            ui.key(KEY_ZERO, ui.CMD)


@pytest.mark.ui
@pytest.mark.req("L-33")
def test_option_shift_angle_brackets_change_the_font_size_ui(inst, win, ui):
    a = win["pane"]
    inst.cli("window", "focus", win["window"])
    ui.activate()
    time.sleep(0.5)
    start = zoom(inst, a)
    try:
        ui.key(KEY_PERIOD, ui.OPT | ui.SHIFT)
        wait_until(lambda: zoom(inst, a)["font_size"] == start["font_size"] + 1, 5, message="⌥⇧> one point bigger")
        wait_until(lambda: zoom(inst, a)["cell_width_px"] > start["cell_width_px"], 5, message="the terminal's text grew")
        # The key didn't reach the shell as text.
        assert "˘" not in screen(inst, a) and "¯" not in screen(inst, a)
        # A new pane gets the size too.
        b = split(inst, "right", a)
        wait_until(lambda: zoom(inst, b)["cell_width_px"] == zoom(inst, a)["cell_width_px"], 5, message="the new pane's size")
        ui.key(KEY_COMMA, ui.OPT | ui.SHIFT)
        ui.key(KEY_COMMA, ui.OPT | ui.SHIFT)
        wait_until(lambda: zoom(inst, a)["font_size"] == start["font_size"] - 1, 5, message="⌥⇧< twice")
        # ⌘= no longer changes the font size alone: it zooms.
        ui.key(KEY_EQUAL, ui.CMD)
        wait_until(lambda: zoom(inst, a)["level"] == 110, 5, message="⌘= zooms")
        assert zoom(inst, a)["font_size"] == start["font_size"] - 1
    finally:
        ui.key(KEY_ZERO, ui.CMD)
        ui.choose(ui.menu_item("Reset Font Size"))
        wait_until(lambda: zoom(inst, a)["font_size"] == start["font_size"] and zoom(inst, a)["level"] == 100, 5,
                   message="back to the start")
