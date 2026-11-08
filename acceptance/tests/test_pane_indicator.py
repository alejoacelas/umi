"""The pane indicator (SPEC PI-1 to PI-4; design/attention-ui.md, "The pane indicator";
prototypes/pane-indicator.html).

One small mark per pane, at its bottom right: working, needs you (`needs_input` or `error`), finished
and not seen (`idle`/`stopped` while `unseen`), or nothing. The same mark on the pane's strip chip;
a tab's sidebar row shows the mark of the pane `tab.summary` picks. The focused pane's mark is larger
and brighter and the focused pane of a split is a little brighter (`indicator.focus`); colours come
from the `indicator.<state>` slots. No cyan focus line.

States are read back from `ls --json` (`indicator`), what is drawn from `debug.ui.indicator` (the
looks the views use) and from window screenshots (`<cli> screenshot`, which draws the marks over
the terminals as the window does). The `_ui` tests capture the real window from the screen and
click with the real mouse; they need an unlocked screen.
"""

import os
import subprocess
import time

import pytest

from harness import Instance, wait_until
from test_umi_blocks import load_png
from test_umi_panes_ui import new_tab, rpc, split, tab_of

pytestmark = pytest.mark.layout

AMBER = (0xE0, 0xA9, 0x3E)
CYAN = (0x19, 0xAA, 0xD8)


def indicator(inst, pane):
    return inst.json("pane", "info", pane)["indicator"]


def drawn(inst, window):
    return rpc(inst, "debug.ui.indicator", window=window)


def pane_look(inst, window, pane):
    return next(p for p in drawn(inst, window)["panes"] if p["pane"] == pane)


def near(a, b, by):
    return max(abs(x - y) for x, y in zip(a, b)) <= by


def three(inst, win):
    a = win["pane"]
    b = split(inst, "right", a, "--no-focus")
    c = split(inst, "right", b, "--no-focus")
    for pane in (b, c):
        wait_until(lambda p=pane: inst.cli("read", "--pane", p, check=False).stdout.strip(), 20, message="the shell")
    inst.cli("pane", "focus", a)
    return a, b, c


@pytest.fixture
def agents(inst):
    """Panes given agents through the hook plugin's command; their agents end afterwards."""
    started = []

    def start(pane):
        inst.hook(pane, "SessionStart")
        started.append(pane)
    yield start
    for pane in started:
        try:
            inst.hook(pane, "SessionEnd")
        except Exception:  # noqa: BLE001 - the pane may be closed by now
            pass


@pytest.fixture
def active(inst):
    rpc(inst, "debug.ui.assume_active", on=True)
    yield
    rpc(inst, "debug.ui.assume_active", on=False)


class Picture:
    """A window image, and where a pane's points land in it."""

    def __init__(self, inst, win, path, image=None):
        self.inst, self.win = inst, win
        if image is None:
            inst.cli("screenshot", "--window", win["window"], str(path))
            image = load_png(path)
        self.w, self.h, self.buf = image
        sidebar = float(inst.cli("sidebar", "width", "--window", win["window"]).stdout.split()[0])
        if not inst.json("sidebar", "status", "--window", win["window"])["visible"]:
            sidebar = 0
        self.frames = {p["id"]: p["frame"] for p in tab_of(inst, win["tab"])["panes"] if "frame" in p}
        width = max(f["x"] + f["width"] for f in self.frames.values())
        height = max(f["y"] + f["height"] for f in self.frames.values())
        self.scale = self.w / (sidebar + width)
        self.left = sidebar * self.scale
        self.top = self.h - height * self.scale
        self.inset = drawn(inst, win["window"])["inset"]

    def px(self, x, y):
        i = (int(y) * self.w + int(x)) * 4
        return tuple(self.buf[i:i + 3])

    def at(self, pane, x, y):
        """The colour at (x, y) points from the pane's top-left (negative: from its right or bottom)."""
        f = self.frames[pane]
        px = f["x"] + (x if x >= 0 else f["width"] + x)
        py = f["y"] + (y if y >= 0 else f["height"] + y)
        return self.px(self.left + px * self.scale, self.top + py * self.scale)

    def mark(self, pane):
        return self.at(pane, -self.inset["right"], -self.inset["bottom"])

    def background(self, pane):
        """The pane's own background: in its left padding, just above its bottom edge."""
        return self.at(pane, 6, -4)

    def cyan_on_top(self, pane):
        f = self.frames[pane]
        y0 = self.top + f["y"] * self.scale
        x0, x1 = self.left + f["x"] * self.scale, self.left + (f["x"] + f["width"]) * self.scale
        return [x for x in range(int(x0), int(x1)) for y in range(int(y0), int(y0 + 3 * self.scale))
                if near(self.px(x, y), CYAN, 40)]


# ---- PI-1: the states ------------------------------------------------------------------------------

@pytest.mark.req("PI-1", "D-4")
def test_the_indicator_follows_the_agents_status(inst, win, agents):
    a, b, _ = three(inst, win)
    assert indicator(inst, b) == "none", "a shell has no mark"
    agents(b)
    assert indicator(inst, b) == "none", "an agent that just started asks for nothing"
    inst.hook(b, "UserPromptSubmit", prompt="a task")
    assert indicator(inst, b) == "working"
    inst.hook(b, "PermissionRequest", tool_name="Bash")
    assert indicator(inst, b) == "needs_you"
    inst.hook(b, "PostToolUse", tool_name="Bash")
    assert indicator(inst, b) == "working", "answering the question takes it back to working"
    inst.hook(b, "Stop", last_assistant_message="done")
    assert indicator(inst, b) == "finished", "a turn ended out of sight: finished and not seen"
    # The status written as the hook plugin would: error needs you too.
    inst.cli("pane", "set", b, "agent.status=error")
    assert indicator(inst, b) == "needs_you"
    inst.cli("pane", "set", b, "agent.status=stopped")
    assert indicator(inst, b) == "finished"
    pane = next(p for p in tab_of(inst, win["tab"])["panes"] if p["id"] == b)
    assert pane["indicator"] == "finished" and pane["attributes"]["unseen"] == "true"


@pytest.mark.req("PI-1")
def test_looking_at_a_finished_pane_clears_its_mark_and_a_question_keeps_it(inst, win, agents, active):
    a, b, _ = three(inst, win)
    agents(b)
    inst.hook(b, "UserPromptSubmit", prompt="a task")
    inst.hook(b, "Stop", last_assistant_message="done")
    assert indicator(inst, b) == "finished"
    inst.cli("pane", "focus", a)
    time.sleep(0.3)
    assert indicator(inst, b) == "finished", "looking at another pane of the tab doesn't count"
    inst.cli("pane", "focus", b)
    wait_until(lambda: indicator(inst, b) == "none", 5, message="a look at the pane clears it")
    inst.hook(b, "PermissionRequest", tool_name="Bash")
    time.sleep(0.3)
    assert indicator(inst, b) == "needs_you", "looking doesn't answer the question"


@pytest.mark.req("PI-1", "H-3")
def test_a_finished_pane_brought_back_by_its_condition_shows_finished(inst, win, agents):
    a, b, _ = three(inst, win)
    agents(b)
    inst.hook(b, "UserPromptSubmit", prompt="a task")
    inst.cli("pane", "hide", b, "--until", "agent.status=idle")
    inst.hook(b, "Stop", last_assistant_message="done")
    wait_until(lambda: not next(p for p in tab_of(inst, win["tab"])["panes"] if p["id"] == b)["hidden"], 5,
               message="the condition brings it back")
    assert indicator(inst, b) == "finished"


# ---- PI-2: where the mark shows -----------------------------------------------------------------------

@pytest.mark.req("PI-2")
def test_the_mark_sits_at_the_panes_bottom_right_and_on_its_chip(inst, win, agents, tmp_path):
    a, b, c = three(inst, win)
    agents(c)
    inst.hook(c, "PermissionRequest", tool_name="Bash")
    agents(b)
    inst.hook(b, "UserPromptSubmit", prompt="a task")
    look = drawn(inst, win["window"])
    chips = {ch["pane"]: ch for ch in look["chips"]}
    assert [chips[p]["state"] for p in (a, b, c)] == ["none", "working", "needs_you"], chips
    assert chips[c]["mark"]["color"] == "#e0a93e" and chips[a]["mark"] is None
    pic = Picture(inst, win, tmp_path / "marks.png")
    assert near(pic.mark(c), AMBER, 40), f"amber at the needs-you pane's bottom right: {pic.mark(c)}"
    # Nothing at the same spot of a pane with no state and no focus … but working's muted mark at b's.
    assert near(pic.mark(b), (0x6F, 0x7F, 0x76), 45), f"working's muted mark: {pic.mark(b)}"
    # Hidden panes keep their chip's state.
    inst.cli("pane", "hide", c)
    chips = {ch["pane"]: ch for ch in drawn(inst, win["window"])["chips"]}
    assert chips[c]["state"] == "needs_you"


@pytest.mark.req("PI-2", "Q-4")
def test_a_tab_row_shows_the_mark_of_the_pane_tab_summary_picks(inst, win, agents):
    pane, tab = new_tab(inst, win)
    other = split(inst, "right", pane, "--no-focus")
    wait_until(lambda: inst.cli("read", "--pane", other, check=False).stdout.strip(), 20, message="the shell")

    def row():
        return next(r for r in drawn(inst, win["window"])["rows"] if r["tab"] == tab)
    assert row()["state"] == "none"
    agents(other)
    inst.hook(other, "UserPromptSubmit", prompt="work")
    assert row()["state"] == "working" and row()["mark"]["color"] == "#6f7f76"
    rows = {r["tab"]: r for r in rpc(inst, "debug.ui.rows", window=win["window"])["rows"]}
    assert rows[tab]["mark"] == "working"
    # A hidden pane that needs you still speaks for its tab.
    inst.hook(other, "PermissionRequest", tool_name="Bash")
    inst.cli("pane", "hide", other)
    assert row()["state"] == "needs_you" and row()["mark"]["color"] == "#e0a93e"


# ---- PI-3: focus ----------------------------------------------------------------------------------

@pytest.mark.req("PI-3")
def test_the_focused_pane_has_a_larger_mark_and_is_a_little_brighter(inst, win, agents, tmp_path):
    a, b, c = three(inst, win)
    agents(c)
    inst.hook(c, "PermissionRequest", tool_name="Bash")
    focused, other = pane_look(inst, win["window"], a), pane_look(inst, win["window"], b)
    assert focused["focused"] and focused["lift"] == 0.03 and other["lift"] == 0
    assert focused["mark"] == {"color": "#6a6a6a", "size": 9, "opacity": 1}, "an idle focused pane of a split: grey"
    assert "mark" not in other, "an idle pane without focus: nothing"
    assert pane_look(inst, win["window"], c)["mark"] == {"color": "#e0a93e", "size": 7, "opacity": 1}
    pic = Picture(inst, win, tmp_path / "focus-a.png")
    fa, fb = pic.background(a), pic.background(b)
    assert 4 <= fa[0] - fb[0] <= 14, f"the focused pane slightly brighter: {fa} vs {fb}"
    assert not pic.cyan_on_top(a), "no cyan focus line"
    # Focus moves: the mark grows and the lift follows.
    inst.cli("pane", "focus", c)
    time.sleep(0.4)
    assert pane_look(inst, win["window"], c)["mark"] == {"color": "#e0a93e", "size": 9, "opacity": 1}
    assert pane_look(inst, win["window"], a)["lift"] == 0 and "mark" not in pane_look(inst, win["window"], a)
    pic = Picture(inst, win, tmp_path / "focus-c.png")
    assert pic.background(c)[0] - pic.background(a)[0] >= 4
    # One pane alone: no lift and no grey mark.
    inst.cli("pane", "close", b)
    inst.cli("pane", "close", c)
    lone = pane_look(inst, win["window"], a)
    assert lone["lift"] == 0 and "mark" not in lone and not lone["split"]


# ---- PI-4: the slots ------------------------------------------------------------------------------

@pytest.fixture(scope="module")
def configured(target, tmp_path_factory):
    xdg = str(tmp_path_factory.mktemp("xdg"))
    os.makedirs(os.path.join(xdg, "umi"))
    with open(os.path.join(xdg, "umi", "config"), "w") as f:
        f.write("font-size = 13\n")
    instance = Instance(target, prefix="acc-indicator-", env={"XDG_CONFIG_HOME": xdg})
    instance.start_app()
    instance.xdg = xdg
    created = instance.json("window", "new", "--name", "indicator")
    pane = created["pane"]
    wait_until(lambda: instance.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="the shell")
    instance.win = {"pane": pane, "tab": created["tab"], "window": created["window"]}
    yield instance
    instance.cleanup()


def write_config(inst, text):
    path = os.path.join(inst.xdg, "umi", "config")
    with open(path, "w") as f:
        f.write(text)
    os.utime(path, (time.time() + 1, time.time() + 1))
    time.sleep(1.2)


@pytest.mark.req("PI-4", "Q-4")
def test_the_indicator_slots_set_its_colours_and_the_focus_amount(configured, tmp_path):
    inst, win = configured, configured.win
    slots = {s["name"]: s for s in inst.json("slot", "ls")["slots"]}
    assert [slots[n]["value"] for n in ("indicator.working", "indicator.needs_you", "indicator.finished",
                                        "indicator.focus")] == ["muted", "amber", "muted", "3%"]
    a = win["pane"]
    b = split(inst, "right", a, "--no-focus")
    wait_until(lambda: inst.cli("read", "--pane", b, check=False).stdout.strip(), 20, message="the shell")
    inst.cli("pane", "focus", a)
    inst.hook(b, "SessionStart")
    try:
        inst.hook(b, "PermissionRequest", tool_name="Bash")
        write_config(inst, "font-size = 13\nslot.indicator.needs_you = #ff0000\nslot.indicator.focus = 10%\n"
                           "slot.indicator.working = none\n")
        wait_until(lambda: drawn(inst, win["window"])["style"]["needs_you"] == "#ff0000", 5, message="read again")
        assert drawn(inst, win["window"])["style"] == {"working": "none", "needs_you": "#ff0000",
                                                       "finished": "#bdbdbd", "focus": 0.1}
        pic = Picture(inst, win, tmp_path / "slots.png")
        assert near(pic.mark(b), (0xFF, 0, 0), 50), f"the needs-you mark in the slot's colour: {pic.mark(b)}"
        lifted = pic.background(a)[0] - pic.background(b)[0]
        assert 18 <= lifted <= 40, f"a 10% lift: {pic.background(a)} vs {pic.background(b)}"
        # working = none: no mark while working.
        inst.hook(b, "PostToolUse", tool_name="Bash")
        assert indicator(inst, b) == "working" and "mark" not in pane_look(inst, win["window"], b)
        # Values that don't read show in slot ls, and the defaults hold.
        write_config(inst, "font-size = 13\nslot.indicator.needs_you = blinking\nslot.indicator.focus = 50%\n")
        slots = {s["name"]: s for s in inst.json("slot", "ls")["slots"]}
        assert "isn't a colour" in slots["indicator.needs_you"]["error"]
        assert "more than 20%" in slots["indicator.focus"]["error"]
        style = drawn(inst, win["window"])["style"]
        assert style["needs_you"] == "#e0a93e" and style["focus"] == 0.03
        write_config(inst, "font-size = 13\nslot.indicator.focus = 0\nslot.indicator.finished = violet\n")
        style = drawn(inst, win["window"])["style"]
        assert style["focus"] == 0 and style["finished"] == "#a78bfa"
        assert pane_look(inst, win["window"], a)["lift"] == 0
    finally:
        inst.hook(b, "SessionEnd")
        write_config(inst, "font-size = 13\n")


# ---- On the real screen --------------------------------------------------------------------------

def window_element(ui, inst, win):
    from test_umi_editor_warp import window_of
    inst.cli("window", "focus", win["window"])
    ui.activate()
    pane = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Terminal pane"), 5, message="a pane")
    return window_of(ui, pane)


def capture(ui, inst, win, path):
    """The window as it is on screen (screencapture), read as a Picture."""
    from test_umi_editor_warp import frame
    x, y, w, h = frame(ui, window_element(ui, inst, win))
    time.sleep(0.3)
    subprocess.run(["screencapture", "-x", "-o", "-R", f"{x},{y},{w},{h}", str(path)], check=True)
    return Picture(inst, win, path, image=load_png(path))


@pytest.mark.req("PI-2", "PI-3")
def test_the_marks_and_the_lift_on_screen_ui(inst, win, ui, agents, tmp_path):
    """The marks and the brighter focused pane as the window draws them (SwiftUI over the terminals),
    and a real click moving focus, the lift and the larger mark with it."""
    a, b, c = three(inst, win)
    agents(c)
    inst.hook(c, "PermissionRequest", tool_name="Bash")
    pic = capture(ui, inst, win, tmp_path / "screen-a.png")
    assert near(pic.mark(c), AMBER, 45), f"amber at the bottom right on screen: {pic.mark(c)}"
    assert near(pic.mark(a), (0x6A, 0x6A, 0x6A), 35), f"the focused pane's grey mark on screen: {pic.mark(a)}"
    assert pic.background(a)[0] - pic.background(b)[0] >= 4, (pic.background(a), pic.background(b))
    assert not pic.cyan_on_top(a), "no cyan focus line on screen"
    # A real click in pane b's middle focuses it: the lift and the grey mark move there.
    import Quartz
    from test_umi_editor_warp import frame
    wx, wy, _, _ = frame(ui, window_element(ui, inst, win))
    f = pic.frames[b]
    point = (wx + pic.left / pic.scale + f["x"] + f["width"] / 2,
             wy + pic.top / pic.scale + f["y"] + f["height"] / 2)
    for kind in (Quartz.kCGEventMouseMoved, Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonLeft))
        time.sleep(0.1)
    wait_until(lambda: inst.json("pane", "info", b)["focused"], 5, message="the click focuses b")
    pic = capture(ui, inst, win, tmp_path / "screen-b.png")
    assert pic.background(b)[0] - pic.background(a)[0] >= 4, (pic.background(b), pic.background(a))
    assert near(pic.mark(b), (0x6A, 0x6A, 0x6A), 35), f"b's grey mark after the click: {pic.mark(b)}"


@pytest.mark.req("PI-2")
def test_chips_and_rows_say_the_state_to_accessibility_ui(inst, win, ui, agents):
    """A chip's accessibility value ends with its pane's state; the row's value says it needs you."""
    from test_hidden_panes import strip_chips
    a, b, c = three(inst, win)
    for pane, name in ((a, "ind-a"), (b, "ind-b"), (c, "ind-c")):
        inst.cli("pane", "rename", pane, name)
    agents(c)
    inst.hook(c, "PermissionRequest", tool_name="Bash")
    agents(b)
    inst.hook(b, "UserPromptSubmit", prompt="work")
    window_element(ui, inst, win)
    chips = wait_until(lambda: (lambda cs: cs if len(cs) == 3 else None)(strip_chips(ui)), 5, message="three chips")
    values = {ui.label(e): ui.value(e) for e in chips}
    assert values["ind-c"].endswith(", needs you"), values
    assert values["ind-b"].endswith(", working"), values
    assert values["ind-a"] == "on show, focused", values
    inst.cli("pane", "focus", c)
    # The sidebar row (its value names the agent, which a chip's doesn't).
    row = wait_until(lambda: ui.find(lambda e: ui.role(e) == "AXButton" and "claude" in (ui.value(e) or "")
                                     and "needs you" in (ui.value(e) or "")), 5, message="the row says needs you")
    assert row is not None
