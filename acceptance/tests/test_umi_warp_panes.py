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
    window = ui.attr(ui.app, "AXFocusedWindow")

    def left_pane():
        # In a split, the left pane's element is "Left pane" (Ghostty's split view); maximized,
        # it's the window's only "Terminal pane".
        return (ui.find(lambda e: ui.label(e) == "Left pane", root=window)
                or ui.find(lambda e: ui.label(e) == "Terminal pane", root=window))

    def open_menu():
        _right_click(_frame(ui, wait_until(left_pane, 5, message="the left pane")))
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
    from test_umi_panes_ui import _row_element
    title = row(inst, win["window"], win["tab"])["line1"]
    element = wait_until(lambda: _row_element(ui, title), 5, message=f"the row {title!r}")
    row_height = _frame(ui, element)[3]
    try:
        ui.key(KEY_EQUAL, ui.CMD)
        wait_until(lambda: zoom(inst, a)["level"] == 110, 5, message="⌘= to 110%")
        z = wait_until(lambda: (lambda z: z if z["cell_width_px"] > start["cell_width_px"] else None)(zoom(inst, a)), 5,
                       message="the terminal's text grew")
        assert z["terminal_font_size"] == pytest.approx(start["font_size"] * 1.1, abs=0.05)
        # The sidebar grew too.
        element = wait_until(lambda: _row_element(ui, title), 5, message="the row")
        assert _frame(ui, element)[3] == pytest.approx(row_height * 1.1, rel=0.05)
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


# ---- Review follow-ups (2026-11-05) -------------------------------------------------------------

from test_umi_web import site, web  # noqa: E402,F401  (fixtures: an instance with a web origin)


@pytest.fixture
def clipboard():
    """Put text on the clipboard; the clipboard's text is put back afterwards."""
    import subprocess
    saved = subprocess.run(["pbpaste"], capture_output=True).stdout

    def put(text):
        subprocess.run(["pbcopy"], input=text.encode(), check=True)

    yield put
    subprocess.run(["pbcopy"], input=saved, check=True)


def stop_sync(inst):
    try:
        rpc(inst, "debug.menu.perform", title="Stop Synchronizing Any Panes")
    except AssertionError as e:
        if "disabled" not in str(e):
            raise


def menu_item(inst, pane, title):
    return next((i for i in rpc(inst, "debug.ui.pane.menu", pane=pane)["items"] if i.get("title") == title), None)


def confirmation(inst, pane, action=None):
    params = {"pane": pane}
    if action:
        params["action"] = action
    return rpc(inst, "debug.ui.clipboard.confirmation", **params)["pending"]


@pytest.mark.req("L-32")
def test_option_command_i_in_a_one_tab_window_leaves_tabs_opened_later_out(inst, win):
    """Warp: from no sync, ⌥⌘I syncs just this tab, even when it's the window's only one."""
    a = win["pane"]
    try:
        assert key(inst, win, "option+cmd+i")["handled"]
        wait_until(lambda: row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="the tab synced")
        other = inst.json("tab", "new", "--window", win["window"], "--no-focus")
        c = other["pane"]
        wait_until(lambda: screen(inst, c).strip() != "", 20, message="the new tab's prompt")
        assert not row(inst, win["window"], other["tab"]).get("input_synced"), "a tab opened later was synced"
        assert row(inst, win["window"], win["tab"]).get("input_synced")
        inst.cli("tab", "focus", win["tab"])
        inst.cli("pane", "focus", a)
        marker = word("one")
        type_keys(inst, win, f"echo {marker}")
        wait_until(lambda: screen(inst, a).count(marker) >= 2, 10, message="a ran it")
        time.sleep(0.5)
        assert marker not in screen(inst, c), "the tab opened later got the keys"
        # ⌥⌘I again: nothing is synced.
        assert key(inst, win, "option+cmd+i")["handled"]
        wait_until(lambda: not row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="stopped")
    finally:
        stop_sync(inst)


@pytest.mark.req("L-32")
def test_a_paste_into_a_synced_pane_is_confirmed_once_and_reaches_every_pane(inst, win, clipboard):
    a = win["pane"]
    b = split(inst, "right", a)
    wait_until(lambda: screen(inst, b).strip() != "", 20, message="b's prompt")
    inst.cli("pane", "focus", a)
    try:
        assert key(inst, win, "option+cmd+i")["handled"]
        wait_until(lambda: row(inst, win["window"], win["tab"]).get("input_synced"), 5, message="the tab synced")
        # A paste the shell takes as it is (one line): typed into both, no dialog.
        marker = word("pas")
        clipboard(f"echo {marker}")
        key(inst, win, "cmd+v")
        wait_until(lambda: marker in screen(inst, a), 5, message="pasted into a")
        wait_until(lambda: marker in screen(inst, b), 5, message="pasted into b too")
        assert not confirmation(inst, a) and not confirmation(inst, b)
        key(inst, win, "return")
        wait_until(lambda: screen(inst, b).count(marker) >= 2, 10, message="b ran it")
        # Both run cat, which doesn't ask for bracketed paste: a paste of several lines is unsafe
        # there, and Ghostty asks first. Once, in a; b asks nothing.
        type_keys(inst, win, "cat")
        time.sleep(1)
        first, second = word("lio"), word("lit")
        clipboard(f"{first}\n{second}\n")
        key(inst, win, "cmd+v")
        wait_until(lambda: confirmation(inst, a), 5, message="a asks before pasting")
        assert not confirmation(inst, b), "b asks too"
        assert first not in screen(inst, b) and first not in screen(inst, a), "pasted before it was confirmed"
        confirmation(inst, a, "confirm")
        wait_until(lambda: second in screen(inst, a), 5, message="pasted into a once confirmed")
        wait_until(lambda: second in screen(inst, b), 5, message="and into b, with no dialog of its own")
        assert not confirmation(inst, b)
        # Cancelled, it goes nowhere.
        third = word("can")
        clipboard(f"{third}\n{third}\n")
        key(inst, win, "cmd+v")
        wait_until(lambda: confirmation(inst, a), 5, message="a asks again")
        confirmation(inst, a, "cancel")
        time.sleep(0.5)
        assert third not in screen(inst, a) and third not in screen(inst, b)
        key(inst, win, "ctrl+c")
    finally:
        stop_sync(inst)


@pytest.mark.req("L-32")
def test_file_and_web_panes_in_a_synced_tab_get_no_keys(web, tmp_path):
    from test_umi_web import web_panes
    inst, a = web["inst"], web["pane"]
    w = {"window": web["window"], "tab": web["tab"]}
    b = split(inst, "right", a)
    doc = tmp_path / "sync.md"
    doc.write_text("# Sync\n")
    before = {p["id"] for p in tab_of(inst, web["tab"])["panes"]}
    inst.cli("edit", str(doc), "--source", "--pane", a)
    file_pane = wait_until(lambda: next((p["id"] for p in tab_of(inst, web["tab"])["panes"] if p["id"] not in before), None),
                           5, message="the file pane")
    page = inst.json("edit", web["site"] + "/doc", "--pane", a)["pages"][0]["pane"]
    wait_until(lambda: web_panes(inst), 10, message="the web pane")
    for p in (b, file_pane, page):
        wait_until(lambda: screen(inst, p).strip() != "", 20, message=f"the shell under {p}")
    time.sleep(0.5)
    hidden = {p: screen(inst, p) for p in (file_pane, page)}
    try:
        rpc(inst, "debug.menu.perform", title="Toggle Synchronizing All Panes in All Tabs")
        wait_until(lambda: all(r.get("input_synced") for r in rpc(inst, "debug.ui.rows", window=web["window"])["rows"]),
                   5, message="every tab synced")
        inst.cli("tab", "focus", web["tab"])
        inst.cli("pane", "focus", a)
        marker = word("fil")
        type_keys(inst, w, f"echo {marker}")
        wait_until(lambda: screen(inst, b).count(marker) >= 2, 10, message="b, a terminal, got the keys")
        time.sleep(0.5)
        for p in (file_pane, page):
            assert marker not in screen(inst, p), f"the terminal under {p} got the keys"
            assert screen(inst, p) == hidden[p]
        assert marker not in doc.read_text()
    finally:
        stop_sync(inst)


@pytest.mark.ui
@pytest.mark.req("L-32")
def test_a_synced_tabs_row_shows_the_link_mark_ui(inst, win, ui):
    from test_umi_panes_ui import _row_element
    inst.cli("window", "focus", win["window"])
    ui.activate()
    time.sleep(0.5)
    title = row(inst, win["window"], win["tab"])["line1"]

    def mark():
        # The row is one accessibility element: the mark shows in its value.
        element = _row_element(ui, title)
        return element is not None and "Synchronized input" in ui.value(element)

    assert not mark()
    try:
        ui.key(KEY_I, ui.CMD | ui.OPT)
        wait_until(mark, 5, message="the row's link mark")
        ui.key(KEY_I, ui.CMD | ui.OPT | ui.SHIFT)
        wait_until(lambda: not mark(), 5, message="the mark gone after ⌥⇧⌘I")
    finally:
        stop_sync(inst)


@pytest.mark.req("L-31")
def test_the_pane_menu_with_a_selection_or_a_full_screen_program_has_no_paste_or_clear(inst, win, clipboard):
    import subprocess
    a = win["pane"]
    b = split(inst, "right", a)
    wait_until(lambda: screen(inst, b).strip() != "", 20, message="b's prompt")
    # Paste is disabled with nothing to paste.
    clipboard("")
    assert menu_item(inst, a, "Paste")["enabled"] is False
    clipboard("something")
    assert menu_item(inst, a, "Paste")["enabled"] is True
    # With text selected: Copy, then the pane's items.
    inst.cli("pane", "focus", a)
    key(inst, win, "cmd+a")
    wait_until(lambda: rpc(inst, "debug.selection", pane=a)["text"], 5, message="a's text selected")
    titles = menu_titles(inst, a)
    assert titles[0] == "Copy", titles
    assert "Paste" not in titles and "Clear" not in titles, titles
    for title in ("Split Pane Right", "Maximize Pane", "Close Pane"):
        assert title in titles, titles
    rpc(inst, "debug.ui.pane.menu", pane=a, title="Copy")
    assert subprocess.run(["pbpaste"], capture_output=True, text=True).stdout.strip() not in ("", "something")
    # A program's full-screen view (less): the pane's items only.
    inst.cli("send", "--pane", b, "-e", "less /etc/hosts")
    wait_until(lambda: "Paste" not in menu_titles(inst, b), 10, message="less's full-screen view")
    titles = menu_titles(inst, b)
    assert "Clear" not in titles and "Copy" not in titles, titles
    for title in ("Split Pane Right", "Split Pane Up", "Maximize Pane", "Close Pane"):
        assert title in titles, titles
    inst.cli("send", "--pane", b, "q")
    wait_until(lambda: "Paste" in menu_titles(inst, b) and "Clear" in menu_titles(inst, b), 10,
               message="Paste and Clear back at the prompt")


@pytest.mark.req("L-31")
def test_close_pane_from_the_menu_asks_first_when_a_program_runs(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    wait_until(lambda: screen(inst, b).strip() != "", 20, message="b's prompt")
    inst.cli("send", "--pane", b, "-e", "sleep 100")
    time.sleep(1.5)
    rpc(inst, "debug.ui.pane.menu", pane=b, title="Close Pane")
    sheet = wait_until(lambda: (lambda s: s if s["sheet"] else None)(rpc(inst, "debug.ui.sheet", window=win["window"])), 5,
                       message="a confirmation")
    assert any("Close" in t for t in sheet["texts"]), sheet
    assert b in [p["id"] for p in tab_of(inst, win["tab"])["panes"]], "b closed without asking"
    rpc(inst, "debug.ui.sheet", window=win["window"], action="cancel")
    wait_until(lambda: not rpc(inst, "debug.ui.sheet", window=win["window"])["sheet"], 5, message="the dialog dismissed")
    time.sleep(0.5)
    assert b in [p["id"] for p in tab_of(inst, win["tab"])["panes"]], "Cancel closed b"


# L-19: the minimum in a column, beyond the dragged divider's neighbours, and for small panes.

@pytest.mark.req("L-19")
def test_a_dragged_divider_between_rows_stops_at_190_points(inst, win):
    a = win["pane"]
    b = split(inst, "down", a)
    total = sum(f["height"] for f in frames(inst, win["tab"]).values())
    if total < 2 * MINIMUM + 20:
        pytest.skip(f"the window is too short ({total} points) for two panes of {MINIMUM}")
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.02)
    f = frames(inst, win["tab"])
    assert MINIMUM - 1 <= f[a]["height"] <= MINIMUM + 6, f
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.98)
    f = frames(inst, win["tab"])
    assert MINIMUM - 1 <= f[b]["height"] <= MINIMUM + 6, f


@pytest.mark.req("L-19")
def test_a_drag_stops_where_a_pane_beyond_the_divider_would_get_too_small(inst, win):
    """In a row of three, dragging the first divider shares the rest between the other two (L-19):
    the drag stops when they reach 190 points, the far one included."""
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    total = sum(f["width"] for f in frames(inst, win["tab"]).values())
    if total < 3 * MINIMUM + 40:
        pytest.skip(f"the window is too narrow ({total} points) for three panes of {MINIMUM}")
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.98)
    f = frames(inst, win["tab"])
    for p in (b, c):
        assert MINIMUM - 1 <= f[p]["width"] <= MINIMUM + 6, f
    assert f[a]["width"] > MINIMUM


@pytest.mark.req("L-19")
def test_a_pane_already_smaller_than_190_points_may_grow_but_not_shrink(inst, win):
    a = win["pane"]
    total = frames(inst, win["tab"])[a]["width"]
    if total < 2 * MINIMUM + 60:
        pytest.skip(f"the window is too narrow ({total} points)")
    b = split(inst, "right", a, "--ratio", f"{150 / total:.4f}")
    before = frames(inst, win["tab"])
    assert before[b]["width"] < MINIMUM, before
    # Smaller still: refused, nothing moves (but for half a point of rounding).
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=(total - 100) / total)
    f = frames(inst, win["tab"])
    assert f[b]["width"] >= before[b]["width"] - 0.5, (before, f)
    # Bigger: it grows (a stays above the minimum).
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=(total - 210) / total)
    f = frames(inst, win["tab"])
    assert f[b]["width"] == pytest.approx(210, abs=6), f
    assert f[a]["width"] >= MINIMUM


# L-33: kept across restarts; the editor and the preview; the sidebar zoomed.

@pytest.mark.req("L-33")
def test_the_zoom_and_font_size_are_kept_across_restarts(fresh):
    from test_umi_panes_ui import ready
    other = fresh(prefix="acc-zoom-")
    created = other.json("window", "new", "--name", "zoom")
    ready(other, created["pane"])
    w = {"window": created["window"]}
    start = zoom(other, created["pane"])
    key(other, w, "cmd+=")
    key(other, w, "cmd+=")
    key(other, w, "option+shift+.")
    z = wait_until(lambda: (lambda z: z if z["level"] == 125 and z["font_size"] == start["font_size"] + 1
                            and z["cell_width_px"] > start["cell_width_px"] else None)(zoom(other, created["pane"])),
                   5, message="125% and a point bigger")
    other.quit_gracefully()
    other.start_app()
    again = other.json("window", "new", "--name", "zoom-again")
    ready(other, again["pane"])
    wait_until(lambda: (lambda y: y["level"] == 125 and y["font_size"] == z["font_size"]
                        and y["cell_width_px"] == z["cell_width_px"])(zoom(other, again["pane"])),
               10, message=f"125%, the font size and the text size kept (was {z})")


@pytest.mark.req("L-33")
def test_the_zoom_scales_the_editor_and_the_markdown_preview(inst, win, tmp_path):
    a = win["pane"]
    txt = tmp_path / "zoom.txt"
    txt.write_text("plain text\n")
    md = tmp_path / "zoom.md"
    md.write_text("# Zoom\n\nSome text.\n")

    def sizes(field):
        return rpc(inst, "debug.ui.zoom", pane=a, window=win["window"])[field]

    inst.cli("edit", str(txt), "--pane", a)
    wait_until(lambda: sizes("editor_font_sizes"), 10, message="the source editor")
    assert set(sizes("editor_font_sizes")) == {12.5}
    try:
        key(inst, win, "cmd+=")
        wait_until(lambda: all(abs(s - 13.75) < 0.01 for s in sizes("editor_font_sizes")), 5,
                   message="the editor's text at 110%")
        inst.cli("edit", str(md), "--pane", a)
        wait_until(lambda: sizes("preview_page_zooms"), 10, message="the Markdown preview")
        assert all(abs(z - 1.1) < 0.001 for z in sizes("preview_page_zooms")), sizes("preview_page_zooms")
        key(inst, win, "cmd+0")
        wait_until(lambda: all(abs(z - 1.0) < 0.001 for z in sizes("preview_page_zooms")), 5, message="the preview at 100%")
    finally:
        key(inst, win, "cmd+0")


def _click(rect):
    import Quartz
    x, y, w, h = rect
    point = (x + w / 2, y + h / 2)
    for kind in (Quartz.kCGEventMouseMoved, Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonLeft))
        time.sleep(0.1)


@pytest.mark.ui
@pytest.mark.req("L-33", "M-4")
def test_sidebar_rows_drag_and_click_when_zoomed_ui(inst, win, ui):
    from test_umi_panes_ui import _frame, _mouse_drag, _row_element, new_tab, tab_ids
    a = win["pane"]
    _, t2 = new_tab(inst, win, "--name", "zoom-second")
    _, t3 = new_tab(inst, win, "--name", "zoom-third")
    inst.cli("window", "focus", win["window"])
    ui.activate()
    time.sleep(0.5)
    first_title = tab_of(inst, win["tab"])["title"]
    try:
        ui.key(KEY_EQUAL, ui.CMD)
        ui.key(KEY_EQUAL, ui.CMD)
        wait_until(lambda: zoom(inst, a)["level"] == 125, 5, message="125%")
        time.sleep(0.5)
        third = wait_until(lambda: _row_element(ui, "zoom-third"), 5, message="the row")
        first = _row_element(ui, first_title)
        x3, y3, w3, h3 = _frame(ui, third)
        x1, y1, w1, h1 = _frame(ui, first)
        _mouse_drag((x3 + w3 / 2, y3 + h3 / 2), (x1 + w1 / 2, y1 + 4))
        wait_until(lambda: tab_ids(inst, win["window"])[0] == t3, 5, message="dropped before the first row")
        # A click lands on the row under the mouse.
        _click(_frame(ui, wait_until(lambda: _row_element(ui, "zoom-second"), 5, message="the second row")))
        wait_until(lambda: inst.tree().get("current_tab") == t2, 5, message="the clicked row's tab shown")
    finally:
        ui.key(KEY_ZERO, ui.CMD)


@pytest.mark.ui
@pytest.mark.req("L-31")
def test_right_clicking_selected_text_opens_the_selection_menu_ui(inst, win, ui):
    """With text selected before the right-click, Warp's menu has Copy and the pane's items; a
    right-click with nothing selected (Ghostty selects the word under it) keeps Paste and Clear."""
    from test_umi_panes_ui import _frame, _right_click
    a = win["pane"]
    split(inst, "right", a)
    inst.cli("pane", "focus", a)
    inst.cli("window", "focus", win["window"])
    ui.activate()
    time.sleep(0.5)
    window = ui.attr(ui.app, "AXFocusedWindow")

    def menu_texts():
        pane = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Left pane", root=window), 5, message="the left pane")
        _right_click(_frame(ui, pane))
        menus = wait_until(lambda: ui.find_all(lambda e: ui.role(e) == "AXMenu"), 3, message="the pane's menu")
        texts = [t for m in menus for t in ui.texts(m)]
        ui.key(ui.ESCAPE)
        wait_until(lambda: not ui.find_all(lambda e: ui.role(e) == "AXMenu"), 3, message="the menu closed")
        return texts

    texts = menu_texts()
    assert "Paste" in texts and "Clear" in texts, texts
    key(inst, win, "cmd+a")
    wait_until(lambda: rpc(inst, "debug.selection", pane=a)["text"], 5, message="a's text selected")
    texts = menu_texts()
    assert "Copy" in texts and "Paste" not in texts and "Clear" not in texts, texts
    assert "Split Pane Right" in texts and "Close Pane" in texts, texts
