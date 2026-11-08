"""The drawer (SPEC DR-1 to DR-5; design/attention-ui.md, "The drawer"; prototypes/drawer.html, option B;
CLI.md "Drawer").

A window's drawer rises over the lower half of its panes without changing the tab's layout. Panes sent
there leave their tab (no strip chip, no place among the tab's three) and keep running. ⌃⌘M runs
`drawer toggle @manager`. While it is closed, a drawer pane that needs the user shows as a thin line
along the bottom edge. Keys are pressed with `debug.key` (inside the app); `debug.drawer` reports what
the window draws, and screenshots (`<cli> screenshot`, which draws the real views) show it. The `_ui`
tests use real keys and clicks and need an unlocked screen.
"""

import os
import time
import uuid

import pytest

from harness import wait_until
from test_hidden_panes import events_since, hidden, iso_now, shown, three
from test_pane_indicator import near
from test_umi_blocks import load_png
from test_umi_panes_ui import new_tab, ready, rpc, split, tab_of, type_and_wait

pytestmark = pytest.mark.layout

AMBER = (0xE0, 0xA9, 0x3E)


def reddish(c):
    """The theme's ANSI red background (whatever its exact shade)."""
    return c[0] > 170 and c[0] - c[1] > 60 and c[0] - c[2] > 60


def drawer(inst, win):
    return rpc(inst, "debug.drawer", window=win["window"])


def window_json(inst, win):
    return next(w for w in inst.tree()["windows"] if w["id"] == win["window"])


def key(inst, win, keys):
    return rpc(inst, "debug.key", window=win["window"], keys=keys, focus="none")


def settled(inst, win):
    """`debug.drawer` once the drawer has finished rising or going down."""
    return wait_until(lambda: (lambda d: d if not d["sliding"] else None)(drawer(inst, win)), 5,
                      message="the drawer's slide ended")


def ended(pid):
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def shell_pid(inst, pane):
    inst.cli("send", "--pane", pane, "-e", "echo SHELL-PID-$$")
    out = inst.cli("wait", "--pane", pane, "--pattern", r"^SHELL-PID-\d+", "--timeout", "10").stdout.strip()
    return int(out.split("-")[-1])


@pytest.fixture
def closing(inst, win):
    """Put the window's drawer away after the test, whatever happened."""
    yield
    inst.cli("drawer", "hide", "--window", win["window"], check=False)


class Shot:
    """A window image, addressed in the content view's points (origin bottom left, as `debug.drawer`
    reports frames)."""

    def __init__(self, inst, win, path):
        inst.cli("screenshot", "--window", win["window"], str(path))
        self.w, self.h, self.buf = load_png(path)
        content = drawer(inst, win)["content"]
        self.scale = self.w / content["width"]

    def px(self, x, y):
        col = int(x * self.scale)
        row = self.h - 1 - int(y * self.scale)
        i = (row * self.w + col) * 4
        return tuple(self.buf[i:i + 3])


def fill_red(inst, pane, rows=4):
    """Paint the bottom rows of a pane's terminal red (a block of red background)."""
    marker = "RED-" + uuid.uuid4().hex[:6]
    script = "; ".join([f"printf '\\033[41m%200s\\033[0m\\n' ''"] * rows) + f"; echo {marker}"
    inst.cli("send", "--pane", pane, "-e", "clear; " + script)
    wait_until(lambda: marker in inst.cli("read", "--pane", pane).stdout, 10, message="red rows drawn")
    time.sleep(0.5)


# ---- DR-1: the drawer over the tab --------------------------------------------------------------------

@pytest.mark.req("DR-1", "DR-5")
def test_drawer_show_moves_the_pane_in_and_opens_the_drawer_over_the_tab(inst, win, closing, tmp_path):
    a, b, c = three(inst, win)
    inst.cli("pane", "focus", a)
    start = iso_now()
    out = inst.json("drawer", "show", c)
    assert out["open"] and [p["id"] for p in out["panes"]] == [c], out
    # It left its tab: not on show, not hidden, not in the strip; the tab shows the other two.
    tab = tab_of(inst, win["tab"])
    assert [p["id"] for p in tab["panes"]] == [a, b] and tab["strip"] == [a, b], tab
    w = window_json(inst, win)
    assert w["drawer"]["open"] and [p["id"] for p in w["drawer"]["panes"]] == [c]
    pane = w["drawer"]["panes"][0]
    assert pane["in_drawer"] and pane["attributes"]["in_drawer"] == "true" and not pane["hidden"]
    assert [p["id"] for p in inst.json("ls", "--where", "in_drawer")["panes"]] == [c]
    # It has keyboard focus.
    wait_until(lambda: inst.tree()["current_pane"] == c, 5, message="the drawer pane has focus")
    # The panel, once risen: the panes' full width, the lower half, its bottom on the window's bottom edge.
    d = settled(inst, win)
    assert d["rise"] == 1, d
    area = d["panes_area"]
    assert abs(d["frame"]["width"] - area["width"]) <= 1 and abs(d["frame"]["x"] - area["x"]) <= 1, d
    assert abs(d["frame"]["y"] - area["y"]) <= 1, "the drawer sits on the bottom edge"
    assert 0.40 * area["height"] <= d["frame"]["height"] <= 0.52 * area["height"], (d["frame"], area)
    # The tab's layout under it is unchanged.
    assert all(p["frame"]["height"] > 0.9 * area["height"] for p in tab["panes"])
    # Events: the move into the drawer and the drawer opening.
    moved = events_since(inst, start, "pane.moved")
    assert moved and moved[-1]["data"]["to"].get("drawer") is True and moved[-1]["data"]["from"]["tab"] == win["tab"]
    opened = events_since(inst, start, "drawer.opened")
    assert opened and opened[-1]["data"]["pane"] == c and opened[-1]["data"]["window"] == win["window"]
    # What the screen shows: the drawer's terminal over the lower part of the panes.
    fill_red(inst, c)
    shot = Shot(inst, win, tmp_path / "drawer-open.png")
    f = d["frame"]
    reds = [x for x in range(int(f["x"]) + 4, int(f["x"] + f["width"]) - 20, 40)
            if any(reddish(shot.px(x, y)) for y in range(int(f["y"]) + 2, int(f["y"] + f["height"]), 6))]
    assert len(reds) > 5, "the drawer pane's red rows show across the panes' width"
    above = [shot.px(x, f["y"] + f["height"] + 40) for x in range(int(f["x"]) + 4, int(f["x"] + f["width"]) - 4, 40)]
    assert not any(reddish(p) for p in above), "nothing of it above the drawer"


@pytest.mark.req("DR-1")
def test_the_drawer_rises_and_goes_down_in_a_quarter_second(inst, win, closing, tmp_path):
    """prototypes/drawer.html, option B: the panel slides up from below the bottom edge over 0.26 s
    (`transform .26s ease`), and back down when put away."""
    a, b, c = three(inst, win)
    inst.cli("pane", "focus", a)
    fill_red(inst, c)

    def samples(until, limit=3):
        out, start = [], time.time()
        while time.time() - start < limit:
            d = drawer(inst, win)
            out.append((time.time() - start, d))
            if until(d):
                return out
        raise AssertionError(f"the slide didn't end: {[(round(t, 3), x['rise'], x['sliding']) for t, x in out]}")

    began = time.time()
    rpc(inst, "drawer.show", pane=c, window=win["window"])
    up = samples(lambda d: not d["sliding"] and d["rise"] == 1 and "frame" in d)
    took = time.time() - began
    rises = [d["rise"] for _, d in up]
    assert any(0.05 < r < 0.95 for r in rises), f"seen part way up: {rises}"
    assert rises == sorted(rises), f"it only goes up: {rises}"
    assert 0.2 <= took <= 1.0, f"rose in {took:.3f} s"
    # Part way up, the panel itself is lower: its bottom below the panes' bottom edge.
    area = up[-1][1]["panes_area"]
    mid = [d["frame"]["y"] for _, d in up if "frame" in d and 0.05 < d["rise"] < 0.95]
    assert mid and min(mid) < area["y"] - 5, f"the panel was below its place while rising: {mid} vs {area['y']}"
    assert abs(up[-1][1]["frame"]["y"] - area["y"]) <= 1

    began = time.time()
    rpc(inst, "drawer.hide", window=win["window"])
    # The picture it goes down as: the panel at its size, its header on top, the terminal's red rows under it.
    png = tmp_path / "leaving.png"
    d = rpc(inst, "debug.drawer", window=win["window"], leaving_png=str(png))
    assert d["leaving"] and d["leaving_size"]["width"] == pytest.approx(area["width"], abs=1), d
    assert d["leaving_size"]["height"] == pytest.approx(up[-1][1]["frame"]["height"] + 27, abs=2), d
    w, h, buf = load_png(png)
    sx = w / d["leaving_size"]["width"]

    def px(x, y_from_top):
        i = (int(y_from_top * sx) * w + int(x * sx)) * 4
        return tuple(buf[i:i + 3])
    header = [px(x, 13) for x in range(10, int(area["width"]) - 10, 20)]
    assert not any(reddish(p) for p in header), "the header on top"
    body = [px(x, y) for x in range(10, int(area["width"]) - 30, 30) for y in range(30, int(d["leaving_size"]["height"]), 6)]
    assert sum(reddish(p) for p in body) > 10, "the terminal's red rows in the picture"
    down = samples(lambda d: not d["sliding"] and d["rise"] == 0)
    took = time.time() - began
    falls = [d["rise"] for _, d in down]
    assert any(0.05 < r < 0.95 for r in falls), f"seen part way down: {falls}"
    assert falls == sorted(falls, reverse=True), f"it only goes down: {falls}"
    assert 0.2 <= took <= 1.0, f"went down in {took:.3f} s"
    # It goes down as a picture of itself (its pane is no longer in the drawer's view), gone at the end.
    assert any(d["leaving"] for _, d in down if 0 < d["rise"] < 1), "a picture of the panel goes down"
    assert not down[-1][1]["leaving"] and "frame" not in down[-1][1]
    # Opened again half way down, it rises from where it is.
    rpc(inst, "drawer.show", window=win["window"])
    settled(inst, win)
    rpc(inst, "drawer.hide", window=win["window"])
    time.sleep(0.1)
    rpc(inst, "drawer.show", window=win["window"])
    back = samples(lambda d: not d["sliding"] and d["rise"] == 1)
    assert min(d["rise"] for _, d in back) > 0.05, "it rose from part way, not from the bottom"
    assert not back[-1][1]["leaving"]


@pytest.mark.req("DR-1")
def test_drawer_hide_puts_it_away_and_focus_goes_back(inst, win, closing):
    a, b, c = three(inst, win)
    inst.cli("pane", "focus", b)
    inst.cli("drawer", "show", c)
    wait_until(lambda: inst.tree()["current_pane"] == c, 5, message="the drawer pane has focus")
    start = iso_now()
    out = inst.json("drawer", "hide", "--window", win["window"])
    assert not out["open"] and [p["id"] for p in out["panes"]] == [c]
    wait_until(lambda: inst.tree()["current_pane"] == b, 5, message="focus back on the pane focused before")
    closed = events_since(inst, start, "drawer.closed")
    assert closed and closed[-1]["data"]["pane"] == c
    # Its program keeps running while the drawer is closed.
    type_and_wait(inst, c, "echo DRAWER-RUNS", "DRAWER-RUNS")
    assert "frame" not in drawer(inst, win), "nothing of the drawer on screen"
    # `drawer show` with no pane opens it as it was; a tab switch keeps it open (it is the window's).
    assert inst.json("drawer", "show", "--window", win["window"])["open"]
    other, tab2 = new_tab(inst, win)
    inst.cli("tab", "focus", tab2)
    assert window_json(inst, win)["drawer"]["open"]
    inst.cli("tab", "focus", win["tab"])
    # `drawer toggle` with the pane on show puts it away.
    assert not inst.json("drawer", "toggle", c)["open"]


@pytest.mark.req("DR-1")
def test_a_tab_left_without_panes_closes_and_the_windows_only_pane_stays(inst, win, closing):
    a = win["pane"]
    lone, tab2 = new_tab(inst, win)
    inst.cli("drawer", "show", lone)
    assert tab2 not in [t["id"] for t in window_json(inst, win)["tabs"]], "its tab closed"
    assert [p["id"] for p in window_json(inst, win)["drawer"]["panes"]] == [lone]
    inst.cli("drawer", "hide", "--window", win["window"])
    r = inst.cli("drawer", "show", a, check=False)
    assert r.returncode == 1 and "only pane" in r.stderr, r.stderr


# ---- DR-2: ⌃⌘M and the menu ----------------------------------------------------------------------------

@pytest.mark.req("DR-2", "L-9")
def test_ctrl_cmd_m_shows_and_hides_the_manager_pane(inst, win, closing):
    a, b, c = three(inst, win)
    inst.cli("pane", "focus", a)
    inst.cli("pane", "set", c, "role=manager")
    try:
        key(inst, win, "ctrl+cmd+m")
        d = drawer(inst, win)
        assert d["open"] and d["current"] == c, d
        assert shown(inst, win["tab"]) == [a, b]
        wait_until(lambda: inst.tree()["current_pane"] == c, 5, message="the manager has focus")
        key(inst, win, "ctrl+cmd+m")
        assert not drawer(inst, win)["open"]
        wait_until(lambda: inst.tree()["current_pane"] == a, 5, message="focus back where it was")
        # With nothing holding role=manager, ⌃⌘M moves nothing.
        inst.cli("pane", "unset", c, "role")
        key(inst, win, "ctrl+cmd+m")
        assert not drawer(inst, win)["open"]
    finally:
        inst.cli("pane", "unset", c, "role", check=False)
    listed = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    assert listed["drawer.manager"]["keys"] == ["ctrl+cmd+m"], listed["drawer.manager"]
    items = rpc(inst, "debug.menu")["items"]
    item = next((i for i in items if i["title"] == "Show or Hide Manager"), None)
    assert item is not None and item["key"] == "m" and sorted(item["modifiers"]) == ["cmd", "ctrl"] and item["menu"].endswith("Drawer"), item
    for title in ("Show or Hide Drawer", "Move Pane to Drawer", "Dock Drawer Pane", "Next Drawer Pane", "Previous Drawer Pane"):
        assert any(i["title"] == title for i in items), f"no menu item {title!r}"


@pytest.mark.req("DR-2")
def test_cmd_brackets_in_the_drawer_go_through_its_panes(inst, win, closing):
    a, b, c = three(inst, win)
    d4 = split(inst, "down", a, "--no-focus")
    inst.cli("drawer", "show", c)
    inst.cli("drawer", "show", d4)
    assert [p["id"] for p in window_json(inst, win)["drawer"]["panes"]] == [c, d4]
    assert drawer(inst, win)["current"] == d4
    wait_until(lambda: inst.tree()["current_pane"] == d4, 5, message="the drawer pane has focus")
    rpc(inst, "debug.key", window=win["window"], keys="cmd+]", focus="none")
    assert drawer(inst, win)["current"] == c, "⌘] goes to the drawer's next pane"
    assert inst.json("drawer", "next", "--window", win["window"])["current"] == d4
    assert inst.json("drawer", "prev", "--window", win["window"])["current"] == c


@pytest.mark.req("DR-4", "H-2")
def test_window_hide_pane_is_disabled_on_a_tabs_only_pane_while_the_drawer_is_open(inst, win, closing):
    """Window ▸ Hide Pane acts on the focused pane: a drawer pane can always be hidden, a tab's only
    pane on show never (it beeped)."""
    a = win["pane"]
    lone, tab2 = new_tab(inst, win)
    inst.cli("tab", "focus", win["tab"])
    inst.cli("drawer", "show", lone)
    assert shown(inst, win["tab"]) == [a]

    def hide_item():
        return next(i for i in rpc(inst, "debug.menu")["items"] if i["title"] == "Hide Pane")
    wait_until(lambda: inst.tree()["current_pane"] == lone, 5, message="the drawer pane has focus")
    assert hide_item()["enabled"], "a drawer pane can be hidden"
    # Focus on the tab's only pane, the drawer still open.
    inst.cli("pane", "focus", a)
    wait_until(lambda: inst.tree()["current_pane"] == a, 5, message="the tab's pane has focus")
    assert drawer(inst, win)["open"]
    assert not hide_item()["enabled"], "Hide Pane is off for the tab's only pane"
    inst.cli("drawer", "hide", "--window", win["window"])
    assert not hide_item()["enabled"]
    # With a second pane on show, it is on again.
    split(inst, "right", a, "--no-focus")
    inst.cli("pane", "focus", a)
    assert hide_item()["enabled"]


# ---- DR-3: the waiting line ------------------------------------------------------------------------------

@pytest.mark.req("DR-3", "PI-1")
def test_a_drawer_pane_that_needs_you_shows_a_line_along_the_bottom_edge(inst, win, closing, tmp_path):
    a, b, c = three(inst, win)
    inst.cli("pane", "rename", c, "deploy-check")
    inst.cli("drawer", "show", c)
    inst.cli("drawer", "hide", "--window", win["window"])
    settled(inst, win)
    assert drawer(inst, win)["waiting"] == [] and drawer(inst, win)["line_label"] is None
    plain = Shot(inst, win, tmp_path / "no-line.png")
    try:
        rpc(inst, "debug.attention.set", pane=c, status="needs_input")
        d = wait_until(lambda: (lambda d: d if d["waiting"] == [c] else None)(drawer(inst, win)), 5, message="waiting")
        assert d["line_label"] == "deploy-check · needs you", d
        area = d["panes_area"]
        shot = Shot(inst, win, tmp_path / "line.png")
        x = area["x"] + area["width"] * 0.85
        assert near(shot.px(x, area["y"] + 1), AMBER, 60), f"amber line at the bottom edge: {shot.px(x, area['y'] + 1)}"
        assert not near(plain.px(x, area["y"] + 1), AMBER, 60)
        assert not near(shot.px(x, area["y"] + 40), AMBER, 40), "only a thin line"
        # Open, the drawer shows the pane and the line goes.
        inst.cli("drawer", "show", "--window", win["window"])
        assert drawer(inst, win)["waiting"] == []
        inst.cli("drawer", "hide", "--window", win["window"])
        # Working is not waiting.
        rpc(inst, "debug.attention.set", pane=c, status="working")
        wait_until(lambda: drawer(inst, win)["waiting"] == [], 5, message="no line for a working pane")
    finally:
        rpc(inst, "debug.attention.set", pane=c, clear=True)


# ---- DR-4: dock, hide, close and the other ways out --------------------------------------------------------

@pytest.mark.req("DR-4", "H-1")
def test_drawer_dock_puts_the_pane_right_of_the_focused_pane_making_room(inst, win, closing):
    a, b, c = three(inst, win)
    d4, tab2 = new_tab(inst, win)
    inst.cli("drawer", "show", d4)
    inst.cli("pane", "focus", a)
    inst.cli("drawer", "show", "--window", win["window"])
    # Focusing a pane of the tab while the drawer stays open makes it the tab's focused pane.
    inst.cli("pane", "focus", b)
    assert drawer(inst, win)["open"]
    start = iso_now()
    out = inst.json("drawer", "dock", "--window", win["window"])
    assert out["pane"] == d4 and len(out["hid"]) == 1 and out["hid"][0] in (a, c), out
    order = shown(inst, win["tab"])
    assert order.index(d4) == order.index(b) + 1, "right of the tab's focused pane"
    assert hidden(inst, win["tab"]) == out["hid"]
    assert not window_json(inst, win)["drawer"]["panes"] and not window_json(inst, win)["drawer"]["open"]
    wait_until(lambda: inst.tree()["current_pane"] == d4, 5, message="the docked pane has focus")
    moved = events_since(inst, start, "pane.moved")
    assert moved and moved[-1]["data"]["from"].get("drawer") is True and moved[-1]["data"]["to"]["tab"] == win["tab"]
    r = inst.cli("drawer", "dock", a, check=False)
    assert r.returncode == 1 and "isn't in a drawer" in r.stderr


@pytest.mark.req("DR-4", "H-2")
def test_hiding_a_drawer_pane_puts_it_back_hidden_in_its_tab(inst, win, closing):
    a, b, c = three(inst, win)
    inst.cli("drawer", "show", c)
    inst.cli("pane", "hide", c)
    assert hidden(inst, win["tab"]) == [c] and shown(inst, win["tab"]) == [a, b]
    assert not window_json(inst, win)["drawer"]["panes"] and not window_json(inst, win)["drawer"]["open"]
    # The tab it came from is gone: it goes to the current tab.
    lone, tab2 = new_tab(inst, win)
    inst.cli("drawer", "show", lone)
    assert tab2 not in [t["id"] for t in window_json(inst, win)["tabs"]]
    inst.cli("tab", "focus", win["tab"])
    inst.cli("pane", "hide", lone)
    assert lone in hidden(inst, win["tab"])


@pytest.mark.req("DR-4", "L-6")
def test_layout_actions_on_a_drawer_pane(inst, win, closing):
    a, b, c = three(inst, win)
    inst.cli("drawer", "show", c)
    for args in (["split", "right", "--pane", c], ["pane", "zoom", c], ["pane", "swap", c, a],
                 ["pane", "resize", c, "left", "3"]):
        r = inst.cli(*args, check=False)
        assert r.returncode == 1 and "drawer" in r.stderr, (args, r.stderr)
    # `pane focus` and `go` open the drawer on it.
    inst.cli("drawer", "hide", "--window", win["window"])
    inst.cli("pane", "focus", c)
    assert drawer(inst, win)["open"] and drawer(inst, win)["current"] == c
    inst.cli("drawer", "hide", "--window", win["window"])
    inst.cli("pane", "set", c, "drawer-go=yes")
    inst.cli("go", "drawer-go=yes")
    assert drawer(inst, win)["open"]
    # `pane move` takes it out of the drawer.
    out = inst.json("pane", "move", c, "--to", a)
    assert out["tab"] == win["tab"] and c in shown(inst, win["tab"])
    assert not window_json(inst, win)["drawer"]["panes"]
    # `pane close` ends it.
    inst.cli("drawer", "show", c)
    inst.cli("pane", "close", c)
    assert not window_json(inst, win)["drawer"]["panes"]
    assert c not in [p["id"] for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"]]


@pytest.mark.req("DR-4")
def test_a_drawer_panes_program_ending_takes_it_out(inst, win, closing):
    a, b, c = three(inst, win)
    ready(inst, c)
    inst.cli("drawer", "show", c)
    start = iso_now()
    inst.cli("send", "--pane", c, "-e", "exit")
    wait_until(lambda: not window_json(inst, win)["drawer"]["panes"], 10, message="the pane left the drawer")
    assert not window_json(inst, win)["drawer"]["open"]
    # design/cli.md's events: pane.closed has `pane`, `tab` (the tab the drawer is over) and `window`.
    closed = [e for e in events_since(inst, start, "pane.closed") if e["data"]["pane"] == c]
    assert closed and closed[-1]["data"]["tab"] == win["tab"] and closed[-1]["data"]["window"] == win["window"], closed


@pytest.mark.req("DR-4", "L-20")
def test_closing_a_drawer_pane_ends_its_program(inst, win, closing):
    """A closed drawer pane can't be reopened (as a hidden pane), so its shell ends, the drawer open
    or closed; pane.closed names the tab the drawer is over."""
    a, b, c = three(inst, win)
    d4 = split(inst, "down", a, "--no-focus")
    ready(inst, c, d4)
    pids = {c: shell_pid(inst, c), d4: shell_pid(inst, d4)}
    inst.cli("drawer", "show", d4)
    inst.cli("drawer", "show", c)
    assert drawer(inst, win)["open"] and drawer(inst, win)["current"] == c
    start = iso_now()
    inst.cli("pane", "close", c)          # on show, the drawer open
    settled(inst, win)
    inst.cli("drawer", "hide", "--window", win["window"])
    inst.cli("pane", "close", d4)         # in the closed drawer
    for pane, pid in pids.items():
        wait_until(lambda: ended(pid), 10, message=f"the closed drawer pane's shell ended ({pane})")
    assert not window_json(inst, win)["drawer"]["panes"]
    assert not any(p in i["panes"] for i in inst.json("reopen", "--list")["items"] for p in pids)
    closed = {e["data"]["pane"]: e["data"] for e in events_since(inst, start, "pane.closed")}
    for pane in pids:
        assert closed[pane]["tab"] == win["tab"] and closed[pane]["window"] == win["window"], closed


# ---- DR-5: saved with the layout ---------------------------------------------------------------------------

@pytest.mark.req("DR-5", "R-3")
def test_drawer_panes_come_back_after_a_relaunch(fresh):
    other = fresh(prefix="acc-drawer-", restore=True)
    w = other.json("window", "new")
    b = other.cli("split", "right", "--pane", w["pane"]).stdout.strip()
    other.cli("pane", "rename", b, "the-manager")
    other.cli("pane", "set", b, "role=manager")
    other.cli("drawer", "show", b)
    time.sleep(1.5)
    other.quit_gracefully()
    other.start_app()
    wait_until(lambda: other.tree()["windows"], 20, message="the window came back")
    window = next(w for w in other.tree()["windows"] if w["drawer"]["panes"])
    panes = window["drawer"]["panes"]
    assert [p.get("name") for p in panes] == ["the-manager"] and not window["drawer"]["open"], window["drawer"]
    assert panes[0]["attributes"].get("role") == "manager"
    assert all(p["id"] != panes[0]["id"] for t in window["tabs"] for p in t["panes"])
    out = other.json("drawer", "toggle", "@manager", "--window", window["id"])
    assert out["open"]


# ---- with real keys and clicks (an unlocked screen) ---------------------------------------------------------

@pytest.mark.req("DR-2", "DR-1")
def test_real_ctrl_cmd_m_and_the_drawers_buttons_ui(inst, win, ui, closing):
    a, b, c = three(inst, win)
    inst.cli("pane", "rename", c, "mgr")
    inst.cli("pane", "set", c, "role=manager")
    try:
        inst.cli("pane", "focus", a)
        ui.activate()
        ui.press_keys("ctrl+cmd+m")
        wait_until(lambda: drawer(inst, win)["open"], 5, message="⌃⌘M opened the drawer")
        drawer_el = ui.find(lambda e: ui.label(e) == "Drawer")
        assert drawer_el is not None, "the drawer says itself to accessibility"
        ui.type_text("echo TYPED-IN-DRAWER\n")
        wait_until(lambda: "TYPED-IN-DRAWER" in inst.cli("read", "--pane", c).stdout, 5, message="typing goes to the drawer")
        ui.press(ui.button("Put away", root=drawer_el))
        wait_until(lambda: not drawer(inst, win)["open"], 5, message="Put away closed it")
        ui.press_keys("ctrl+cmd+m")
        wait_until(lambda: drawer(inst, win)["open"], 5)
        ui.press(ui.button("Dock", root=ui.find(lambda e: ui.label(e) == "Drawer")))
        wait_until(lambda: c in shown(inst, win["tab"]), 5, message="Dock put it in the tab")
    finally:
        inst.cli("pane", "unset", c, "role", check=False)


@pytest.mark.req("DR-1", "DR-3", "DR-4")
def test_real_clicks_on_a_chip_hide_and_the_waiting_line_ui(inst, win, ui, closing):
    """Real mouse clicks (not accessibility presses) on the drawer's header: a chip shows its pane,
    Hide puts the pane on show back hidden in its tab; and on the waiting line's label, which opens the
    drawer on the pane that waits."""
    from test_umi_panes_ui import _frame
    from test_umi_sidebar_warp import click, front
    a, b, c = three(inst, win)
    d4 = split(inst, "down", a, "--no-focus")
    inst.cli("pane", "rename", c, "chip-one")
    inst.cli("pane", "rename", d4, "chip-two")
    front(inst, win, ui, a)
    inst.cli("drawer", "show", c)
    inst.cli("drawer", "show", d4)
    settled(inst, win)
    assert drawer(inst, win)["current"] == d4
    panel = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Drawer"), 5, message="the drawer in the accessibility tree")
    # A click on the other pane's chip shows it.
    chip = wait_until(lambda: ui.find(lambda e: ui.role(e) == "AXButton" and ui.label(e) == "chip-one", root=panel), 5,
                      message="chip-one's chip")
    click(_frame(ui, chip))
    wait_until(lambda: drawer(inst, win)["current"] == c and drawer(inst, win)["open"], 5, message="the chip's click showed chip-one")
    wait_until(lambda: inst.tree()["current_pane"] == c, 5, message="chip-one has focus")
    # Hide: back, hidden, in the tab it came from; the drawer goes down; chip-two stays in it.
    settled(inst, win)
    panel = ui.find(lambda e: ui.label(e) == "Drawer")
    click(_frame(ui, ui.button("Hide", root=panel)))
    wait_until(lambda: c in hidden(inst, win["tab"]), 5, message="Hide put it back hidden in its tab")
    d = settled(inst, win)
    assert not d["open"] and [p["id"] for p in d["panes"]] == [d4], d
    # The waiting line's label opens the drawer on the pane that waits.
    try:
        rpc(inst, "debug.attention.set", pane=d4, status="needs_input")
        label = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Drawer: chip-two · needs you"), 5,
                           message="the waiting line's label")
        click(_frame(ui, label))
        wait_until(lambda: drawer(inst, win)["open"] and drawer(inst, win)["current"] == d4, 5,
                   message="the label's click opened the drawer on chip-two")
        wait_until(lambda: inst.tree()["current_pane"] == d4, 5, message="chip-two has focus")
    finally:
        rpc(inst, "debug.attention.set", pane=d4, clear=True)
