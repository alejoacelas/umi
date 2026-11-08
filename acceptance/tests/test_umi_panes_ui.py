"""Equal panes, reopening closed things, and the sidebar after the user's decisions (BRIEF-agents §2):
L-19 (panes share rows and columns equally), L-20 (⇧⌘T / `reopen`), S-3 (rows: folder, then the
session's title, quiet agent marks), S-4 (the row menu), S-8 (sidebar width per window), M-4 (panes
and tabs dropped on the sidebar, tabs dragged out), E-10 (Markdown opens in the docs tab, other
text files in the closest tab).

What only a mouse can do (drops, drags, the row menu, dividers) is driven through Umi's internal
`debug.ui.*` control methods, which run the same code the UI runs; the `ui` tests do it with the
real mouse and need the lead's run.
"""

import json
import os
import socket
import subprocess
import time
import uuid

import pytest

from harness import wait_until

pytestmark = pytest.mark.layout


# ---- helpers ------------------------------------------------------------------------------------

def rpc(inst, method, **params):
    """A raw control request (for the internal debug.* methods)."""
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
    if "error" in reply and reply["error"]:
        raise AssertionError(f"{method}: {reply['error']}")
    return reply.get("result", reply)


def window_of(inst, window_id):
    return next(w for w in inst.tree()["windows"] if w["id"] == window_id)


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


def close(a, b, tolerance=2.0):
    return abs(a - b) <= tolerance


def shares(inst, tab_id, panes, key="width"):
    """Each pane's share of the tab's width (or height), in percent."""
    f = frames(inst, tab_id)
    total = sum(f[p][key] for p in panes)
    return [round(100 * f[p][key] / total, 1) for p in panes]


def type_and_wait(inst, pane, command, marker, timeout=15):
    inst.cli("send", "--pane", pane, "-e", command)
    inst.cli("wait", "--pane", pane, "--pattern", f"^{marker}", "--timeout", str(timeout))


def rows(inst, window):
    return rpc(inst, "debug.ui.rows", window=window)["rows"]


def row(inst, window, tab):
    return next(r for r in rows(inst, window) if r["tab"] == tab)


def tab_ids(inst, window):
    return [t["id"] for t in window_of(inst, window)["tabs"]]


def new_tab(inst, win, *extra):
    pane = inst.cli("tab", "new", "--window", win["window"], "--no-focus", *extra).stdout.strip()
    return pane, inst.json("pane", "info", pane)["tab"]


def room_for(inst, tab, n):
    """Let a tab show n panes (its `visible_limit`; three by default, H-1), for checks of how panes
    share a row of more than three."""
    inst.cli("tab", "set", "--tab", tab, f"visible_limit={n}")


def ready(inst, *panes):
    """Wait for the panes' shells to show a prompt (until then, closing one asks first)."""
    for pane in panes:
        wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="prompt")
    time.sleep(0.5)


# ---- L-19: panes share rows and columns equally -------------------------------------------------

@pytest.mark.req("L-19", "L-1")
def test_splits_along_a_row_share_it_equally(inst, win):
    room_for(inst, win["tab"], 6)
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    assert shares(inst, win["tab"], [a, b, c]) == pytest.approx([33.3, 33.3, 33.3], abs=0.2)
    d = split(inst, "left", a)
    order = [p["id"] for p in tab_of(inst, win["tab"])["panes"]]
    assert order == [d, a, b, c], "a split to the left goes before its pane"
    assert shares(inst, win["tab"], order) == pytest.approx([25, 25, 25, 25], abs=0.2)
    # A split across the row halves only that pane; the columns keep their widths.
    e = split(inst, "down", b)
    f = frames(inst, win["tab"])
    assert shares(inst, win["tab"], [d, a, b, c]) == pytest.approx([25, 25, 25, 25], abs=0.2)
    assert close(f[b]["width"], f[e]["width"]) and close(f[b]["height"], f[e]["height"])
    assert close(f[b]["height"] * 2, f[a]["height"])


@pytest.mark.req("L-19", "L-3")
def test_closing_a_pane_shares_its_space_in_proportion(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    inst.cli("pane", "close", b)
    wait_until(lambda: len(tab_of(inst, win["tab"])["panes"]) == 2, 5, message="closed")
    assert shares(inst, win["tab"], [a, c]) == pytest.approx([50, 50], abs=0.2)
    # 40/40/20: closing a 40 leaves 67/33, the others keeping their proportions.
    d = split(inst, "right", c, "--ratio", "0.2")
    assert shares(inst, win["tab"], [a, c, d]) == pytest.approx([40, 40, 20], abs=0.3)
    inst.cli("pane", "close", a)
    wait_until(lambda: len(tab_of(inst, win["tab"])["panes"]) == 2, 5, message="closed")
    assert shares(inst, win["tab"], [c, d]) == pytest.approx([66.7, 33.3], abs=0.3)


@pytest.mark.req("L-19", "L-1")
def test_ratio_sets_the_new_panes_share_of_its_row(inst, win):
    a = win["pane"]
    b = split(inst, "right", a, "--ratio", "0.3")
    assert shares(inst, win["tab"], [a, b]) == pytest.approx([70, 30], abs=0.3)
    c = split(inst, "right", b, "--ratio", "0.25")
    assert shares(inst, win["tab"], [a, b, c]) == pytest.approx([52.5, 22.5, 25], abs=0.3)
    inst.cli("tab", "equalize", win["tab"])
    assert shares(inst, win["tab"], [a, b, c]) == pytest.approx([33.3, 33.3, 33.3], abs=0.2)


@pytest.mark.req("L-19", "M-1")
def test_moves_and_drops_share_rows_equally(inst, win):
    room_for(inst, win["tab"], 6)
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "down", b)
    # `pane move` into the row: three equal columns.
    inst.cli("pane", "move", c, "--to", b, "--dir", "right")
    assert shares(inst, win["tab"], [a, b, c]) == pytest.approx([33.3, 33.3, 33.3], abs=0.2)
    # Dropping a pane (from another window) on another's edge does the same.
    other = inst.json("window", "new", "--no-focus")
    rpc(inst, "debug.ui.split.drop", pane=other["pane"], target=a, zone="left")
    wait_until(lambda: len(tab_of(inst, win["tab"])["panes"]) == 4, 5, message="dropped")
    order = [p["id"] for p in tab_of(inst, win["tab"])["panes"]]
    assert order == [other["pane"], a, b, c]
    assert shares(inst, win["tab"], order) == pytest.approx([25, 25, 25, 25], abs=0.2)
    # Within the window too: c dropped on a's right edge.
    rpc(inst, "debug.ui.split.drop", pane=c, target=a, zone="right")
    order = [p["id"] for p in tab_of(inst, win["tab"])["panes"]]
    assert order == [other["pane"], a, c, b]
    assert shares(inst, win["tab"], order) == pytest.approx([25, 25, 25, 25], abs=0.2)


@pytest.mark.req("L-19", "L-8")
def test_splits_in_a_background_tab_share_equally_too(inst, win):
    p, tab = new_tab(inst, win)
    q = split(inst, "right", p, "--no-focus")
    r = split(inst, "right", q, "--no-focus")
    assert window_of(inst, win["window"])["selected_tab"] == win["tab"]
    assert shares(inst, tab, [p, q, r]) == pytest.approx([33.3, 33.3, 33.3], abs=0.2)


@pytest.mark.req("L-19", "L-1")
def test_the_split_menu_items_share_equally(inst, win, ui):
    """⌘D / ⇧⌘D are the menu's Split Right / Split Down, on the focused pane (needs the app in
    front, so it's a UI test)."""
    room_for(inst, win["tab"], 6)
    a = win["pane"]
    b = split(inst, "right", a)
    inst.cli("pane", "focus", b)
    ui.activate()
    wait_until(lambda: inst.tree().get("current_pane") == b, 5, message="focused")
    ui.choose(ui.menu_item("Split Right"))
    wait_until(lambda: len(tab_of(inst, win["tab"])["panes"]) == 3, 5, message="Split Right")
    order = [p["id"] for p in tab_of(inst, win["tab"])["panes"]]
    assert shares(inst, win["tab"], order) == pytest.approx([33.3, 33.3, 33.3], abs=0.2)
    ui.choose(ui.menu_item("Split Down"))
    wait_until(lambda: len(tab_of(inst, win["tab"])["panes"]) == 4, 5, message="Split Down")
    assert shares(inst, win["tab"], order) == pytest.approx([33.3, 33.3, 33.3], abs=0.2)


@pytest.mark.req("L-19")
def test_a_dragged_divider_moves_only_its_two_neighbors_and_double_click_equalizes_its_row(inst, win):
    room_for(inst, win["tab"], 6)
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    d = split(inst, "down", b, "--ratio", "0.3")
    # Dragging the divider between a and b to 40%: a grows into b, c keeps its third (as in Warp).
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.4)
    assert shares(inst, win["tab"], [a, b, c]) == pytest.approx([40, 26.7, 33.3], abs=0.3)
    # b's column counts as one pane of the row: b and d keep their 70/30.
    assert shares(inst, win["tab"], [b, d], key="height") == pytest.approx([70, 30], abs=0.3)
    # The divider between b and c (its split holds b and c, the last 60% of the row) to 78% of the
    # row: a keeps its 40, b and c share their 60 as dropped (every pane stays above Warp's
    # 190-point minimum).
    rpc(inst, "debug.ui.split.divider", pane=c, action="move", ratio=(0.78 - 0.4) / 0.6)
    assert shares(inst, win["tab"], [a, b, c]) == pytest.approx([40, 38, 22], abs=0.3)
    # A split after the drags shares in proportion: the new pane gets a quarter.
    e = split(inst, "right", c)
    assert shares(inst, win["tab"], [a, b, c, e]) == pytest.approx([30, 28.5, 16.5, 25], abs=0.4)
    # Double-clicking a column divider equalizes the columns only: b/d keep their 70/30.
    rpc(inst, "debug.ui.split.divider", pane=a, action="equalize")
    assert shares(inst, win["tab"], [a, b, c, e]) == pytest.approx([25, 25, 25, 25], abs=0.2)
    assert shares(inst, win["tab"], [b, d], key="height") == pytest.approx([70, 30], abs=0.3)


@pytest.mark.req("L-19")
def test_a_dragged_middle_divider_leaves_the_other_panes_alone(inst, win):
    room_for(inst, win["tab"], 6)
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    d = split(inst, "right", c)
    # The divider between b and c (its split holds b, c and d, the last 3/4 of the row) to 47%:
    # only b and c change (b stays above Warp's 190-point minimum in the suite's window).
    rpc(inst, "debug.ui.split.divider", pane=b, action="move", ratio=(0.47 - 0.25) / 0.75)
    assert shares(inst, win["tab"], [a, b, c, d]) == pytest.approx([25, 22, 28, 25], abs=0.3)


@pytest.mark.req("L-19")
def test_a_keyboard_resize_still_moves_only_the_two_neighbors(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    before = shares(inst, win["tab"], [a, b, c])
    inst.cli("pane", "resize", a, "right", "10")
    after = shares(inst, win["tab"], [a, b, c])
    assert after[0] > before[0] + 1 and after[1] < before[1] - 1
    assert after[2] == pytest.approx(before[2], abs=0.2)


@pytest.mark.req("L-19", "E-1")
def test_a_file_pane_shares_its_row_like_any_pane(inst, win, tmp_path):
    a = win["pane"]
    b = split(inst, "right", a)
    doc = tmp_path / "row.md"
    doc.write_text("# Row\n")
    inst.cli("edit", str(doc), "--pane", a)
    order = [p["id"] for p in tab_of(inst, win["tab"])["panes"]]
    assert len(order) == 3 and order[0] == a and order[2] == b
    assert shares(inst, win["tab"], order) == pytest.approx([33.3, 33.3, 33.3], abs=0.2)
    rpc(inst, "debug.ui.split.divider", pane=a, action="move", ratio=0.4)
    assert shares(inst, win["tab"], order) == pytest.approx([40, 26.7, 33.3], abs=0.3)


@pytest.mark.req("L-7", "L-19")
def test_ls_and_pane_info_report_pane_frames(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    info = inst.json("pane", "info", b)
    f = info["frame"]
    assert set(f) >= {"x", "y", "width", "height"} and f["width"] > 0 and f["height"] > 0
    fa = frames(inst, win["tab"])[a]
    assert close(fa["x"], 0, 0.5) and close(f["x"], fa["width"], 0.5) and close(f["y"], 0, 0.5)


# ---- L-20: reopening closed panes, tabs and windows ---------------------------------------------

@pytest.mark.req("L-20")
def test_reopen_brings_a_closed_pane_back_to_its_slot_with_its_program(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "down", b, "--ratio", "0.4")
    marker = "KEEP-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, b, f"echo {marker}", marker)
    before = frames(inst, win["tab"])
    inst.cli("pane", "close", b)
    wait_until(lambda: inst.find_pane(b) is None, 5, message="closed")
    reopened = inst.json("reopen")
    assert reopened["kind"] == "pane" and reopened["pane"] == b and reopened["tab"] == win["tab"]
    after = frames(inst, win["tab"])
    assert set(after) == set(before)
    for pane in before:
        for key in ("x", "y", "width", "height"):
            assert close(after[pane][key], before[pane][key], 0.5), f"{pane[:8]} {key}: {before[pane]} -> {after[pane]}"
    assert marker in inst.cli("read", "--pane", b, "--scrollback").stdout, "the same program, with its scrollback"
    again = "AGAIN-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, b, f"echo {again}", again)
    assert c in frames(inst, win["tab"])


@pytest.mark.req("L-20")
def test_a_pane_comes_back_beside_its_neighbor_after_its_tab_changed(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    inst.cli("pane", "close", b)
    wait_until(lambda: inst.find_pane(b) is None, 5, message="closed")
    d = split(inst, "down", a)
    inst.json("reopen")
    f = frames(inst, win["tab"])
    assert set(f) == {a, b, d}
    assert close(f[b]["x"], f[a]["x"] + f[a]["width"], 1), "to the right of the pane it was beside"
    assert close(f[b]["y"], f[a]["y"], 1)


@pytest.mark.req("L-20")
def test_reopen_brings_back_closed_tabs_and_windows_in_their_place(inst, win):
    p2, t2 = new_tab(inst, win, "--name", "second")
    p3, t3 = new_tab(inst, win, "--name", "third")
    order = tab_ids(inst, win["window"])
    inst.cli("tab", "close", t2)
    assert t2 not in tab_ids(inst, win["window"])
    reopened = inst.json("reopen")
    assert reopened["kind"] == "tab" and reopened["tab"] == t2
    assert tab_ids(inst, win["window"]) == order, "back at its old index"
    assert tab_of(inst, t2)["name"] == "second" and [p["id"] for p in tab_of(inst, t2)["panes"]] == [p2]

    # A window, with its tabs and panes.
    other = inst.json("window", "new", "--name", "reopen-window")
    q = split(inst, "right", other["pane"])
    old = window_of(inst, other["window"])
    inst.cli("window", "close", other["window"])
    wait_until(lambda: inst.find_pane(q) is None, 5, message="window closed")
    reopened = inst.json("reopen")
    assert reopened["kind"] == "window"
    w = window_of(inst, reopened["window"])
    assert [t["id"] for t in w["tabs"]] == [t["id"] for t in old["tabs"]]
    assert {p["id"] for p in w["tabs"][0]["panes"]} == {other["pane"], q}
    inst.cli("window", "close", reopened["window"])


@pytest.mark.req("L-20")
def test_reopen_goes_last_closed_first_and_skips_what_came_back(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    p2, t2 = new_tab(inst, win)
    inst.cli("pane", "close", b)
    inst.cli("tab", "close", t2)
    listed = inst.json("reopen", "--list")["items"]
    assert [i["kind"] for i in listed[:2]] == ["tab", "pane"]
    assert listed[0]["tab"] == t2 and listed[1]["panes"] == [b]
    assert all(0 < i["expires_in"] <= 60 for i in listed)
    assert inst.json("reopen")["tab"] == t2
    assert inst.json("reopen")["pane"] == b
    # Nothing left from this test: a pane that came back by other means isn't reopened twice.
    c = split(inst, "right", a)
    inst.cli("pane", "close", c)
    inst.json("reopen")
    proc = inst.cli("reopen", check=False)
    leftovers = [i for i in inst.json("reopen", "--list")["items"] if set(i["panes"]) & {b, c, p2}]
    assert not leftovers
    if proc.returncode != 0:
        assert "nothing to reopen" in proc.stderr


@pytest.mark.req("L-20")
def test_a_pane_whose_program_ended_is_not_reopened(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    wait_until(lambda: inst.cli("read", "--pane", b, check=False).stdout.strip() != "", 15, message="prompt")
    time.sleep(1.5)   # past Ghostty's abnormal-command-exit-runtime
    inst.cli("send", "--pane", b, "-e", "exit")
    wait_until(lambda: inst.find_pane(b) is None, 15, message="the pane closed by itself")
    assert not [i for i in inst.json("reopen", "--list")["items"] if b in i["panes"]]


@pytest.mark.req("L-20", "L-9")
def test_shift_cmd_t_is_reopen_in_the_file_menu(inst, win):
    items = rpc(inst, "debug.menu")["items"]
    reopen = [i for i in items if i["title"].startswith("Reopen Closed")]
    assert len(reopen) == 1, reopen
    assert reopen[0]["key"].lower() == "t" and set(reopen[0]["modifiers"]) == {"shift", "cmd"}
    assert reopen[0]["menu"].startswith("File")
    undo_keys = [i for i in items if i["key"].lower() == "t" and set(i["modifiers"]) == {"shift", "cmd"}]
    assert len(undo_keys) == 1, "⇧⌘T isn't also Undo"
    # The item names what it would reopen, and reopens it.
    b = split(inst, "right", win["pane"])
    inst.cli("pane", "close", b)
    reopen = next(i for i in rpc(inst, "debug.menu")["items"] if i["title"].startswith("Reopen Closed"))
    assert reopen["title"] == "Reopen Closed Pane" and reopen["enabled"]
    rpc(inst, "debug.menu.perform", title="Reopen Closed Pane")
    wait_until(lambda: inst.find_pane(b) is not None, 5, message="reopened from the menu")


@pytest.mark.req("L-17", "L-20")
def test_shift_cmd_t_is_listed_where_shortcuts_are_edited(inst, win):
    """⇧⌘T is one of the shortcuts `umi shortcuts` edits: it can be given another key, which the
    menu item then shows, and reset."""
    listed = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    reopen = listed.get("file.reopen")
    assert reopen is not None, "Reopen isn't in the shortcut list"
    assert reopen["kind"] == "umi" and reopen["default"] == reopen["keys"] and len(reopen["keys"]) == 1
    assert set(reopen["keys"][0].split("+")) == {"cmd", "shift", "t"}, reopen
    try:
        inst.cli("shortcuts", "set", "file.reopen", "ctrl+cmd+y")
        item = next(i for i in rpc(inst, "debug.menu")["items"] if i["title"].startswith("Reopen Closed"))
        assert item["key"].lower() == "y" and set(item["modifiers"]) == {"ctrl", "cmd"}, item
    finally:
        inst.cli("shortcuts", "reset", "file.reopen")
    item = next(i for i in rpc(inst, "debug.menu")["items"] if i["title"].startswith("Reopen Closed"))
    assert item["key"].lower() == "t" and set(item["modifiers"]) == {"shift", "cmd"}, item


@pytest.mark.req("L-20")
@pytest.mark.slow
def test_closed_items_expire_after_60_seconds_and_their_programs_end(inst, win):
    b = split(inst, "right", win["pane"])
    inst.cli("send", "--pane", b, "-e", "echo SHELL-PID-$$")
    out = inst.cli("wait", "--pane", b, "--pattern", r"^SHELL-PID-\d+", "--timeout", "10").stdout.strip()
    pid = int(out.split("-")[-1])
    inst.cli("pane", "close", b)
    time.sleep(2)
    os.kill(pid, 0)   # still running while it can be reopened
    deadline = time.time() + 75
    while time.time() < deadline and any(b in i["panes"] for i in inst.json("reopen", "--list")["items"]):
        time.sleep(1)
    assert not any(b in i["panes"] for i in inst.json("reopen", "--list")["items"]), "expired after 60 s"

    def ended():
        try:
            os.kill(pid, 0)
            return False
        except ProcessLookupError:
            return True
    wait_until(ended, 20, message="the closed pane's shell ended once it couldn't come back")



@pytest.mark.req("L-20")
@pytest.mark.slow
def test_a_closed_panes_program_ends_after_60_seconds_with_the_sidebar_hidden(inst, win):
    """With the sidebar hidden nothing else updates the window's views; the closed pane's shell still
    ends once it can't come back (found by design step 6)."""
    inst.cli("sidebar", "off", "--window", win["window"])
    try:
        b = split(inst, "right", win["pane"])
        inst.cli("send", "--pane", b, "-e", "echo SHELL-PID-$$")
        out = inst.cli("wait", "--pane", b, "--pattern", r"^SHELL-PID-\d+", "--timeout", "10").stdout.strip()
        pid = int(out.split("-")[-1])
        inst.cli("pane", "close", b)
        time.sleep(2)
        os.kill(pid, 0)   # still running while it can be reopened
        deadline = time.time() + 75
        while time.time() < deadline and any(b in i["panes"] for i in inst.json("reopen", "--list")["items"]):
            time.sleep(1)

        def ended():
            try:
                os.kill(pid, 0)
                return False
            except ProcessLookupError:
                return True
        wait_until(ended, 20, message="the closed pane's shell ended once it couldn't come back")
    finally:
        # Hiding it also makes the shared instance's new windows start without one.
        inst.cli("sidebar", "on", "--window", win["window"], check=False)

# ---- S-3: rows (folder, then the agent's title; quiet marks) ------------------------------------

def set_agent(inst, pane, kind="claude", title="", status="idle", mark="none"):
    return rpc(inst, "debug.ui.attention.set", pane=pane, kind=kind, title=title, status=status, mark=mark)


def clear_agent(inst, pane):
    rpc(inst, "debug.ui.attention.clear", pane=pane)


@pytest.mark.req("S-3")
def test_rows_show_the_folder_then_the_agents_title(inst, win, tmp_path):
    folder = tmp_path / "row-project"
    folder.mkdir()
    pane, tab = new_tab(inst, win, "--cwd", str(folder))
    wait_until(lambda: row(inst, win["window"], tab)["line1"] == "row-project", 10, message="the folder on line 1")
    plain = row(inst, win["window"], tab)
    assert plain["icon"] == "terminal" and plain["mark"] == "none"
    try:
        set_agent(inst, pane, "claude", title="Fix the login bug", status="working")
        r = row(inst, win["window"], tab)
        assert (r["line1"], r["line2"], r["icon"], r["detail"]) == ("row-project", "Fix the login bug", "claude", "session")
        set_agent(inst, pane, "codex", title="Review the parser", status="idle")
        r = row(inst, win["window"], tab)
        assert (r["line2"], r["icon"]) == ("Review the parser", "codex")
        # An agent with no title yet says what it's doing.
        set_agent(inst, pane, "claude", title="", status="working")
        assert row(inst, win["window"], tab)["line2"] == "working"
    finally:
        clear_agent(inst, pane)
    # A user-given name replaces the folder on line 1; the folder comes back when it's cleared.
    inst.cli("tab", "rename", tab, "renamed")
    assert row(inst, win["window"], tab)["line1"] == "renamed"
    inst.cli("tab", "rename", tab, "")
    assert row(inst, win["window"], tab)["line1"] == "row-project"


@pytest.mark.req("S-3", "S-6")
def test_a_tab_without_an_agent_shows_its_command_on_line_2(inst, win):
    marker = "ROW-" + uuid.uuid4().hex[:6]
    type_and_wait(inst, win["pane"], f"echo {marker}", marker)
    wait_until(lambda: marker in row(inst, win["window"], win["tab"])["line2"], 10, message="the last command")
    assert row(inst, win["window"], win["tab"])["detail"] in ("last_command", "running_command")


@pytest.mark.req("S-3")
def test_rows_keep_the_branch_and_pane_count(inst, win, tmp_path):
    repo = tmp_path / "rowrepo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "row-branch", str(repo)], check=True)
    pane, tab = new_tab(inst, win, "--cwd", str(repo))
    split(inst, "right", pane, "--no-focus")
    wait_until(lambda: row(inst, win["window"], tab).get("branch") == "row-branch", 10, message="the branch")
    assert row(inst, win["window"], tab)["panes"] == 2


@pytest.fixture
def assume_active(inst):
    """Looking needs the app in front (active, with a key window), which a test can't force while the
    person uses another app. This counts the app as active and its current window as key; the `ui`
    tests below check the real thing."""
    rpc(inst, "debug.ui.assume_active", on=True)
    yield
    rpc(inst, "debug.ui.assume_active", on=False)


@pytest.mark.req("S-3")
def test_an_unseen_finish_or_a_question_marks_the_row_and_counts_on_the_dock(inst, win):
    """The marks come from the panes' agent hooks (UmiAttention); the row shows the pane indicator of
    its `tab.summary` pane (PI-2) and the Dock badge counts the panes whose agent needs the user (not
    the finishes not seen yet)."""
    pane, tab = new_tab(inst, win)
    other, other_tab = new_tab(inst, win)
    try:
        set_agent(inst, pane, "claude", title="Long task", status="idle", mark="finished")
        assert row(inst, win["window"], tab)["mark"] == "finished"
        # A finish not seen yet is the row's quiet mark; the badge counts sessions that need the user.
        assert rpc(inst, "debug.ui.attention")["badge"] == ""
        set_agent(inst, other, "codex", title="Asks", status="needs_input", mark="needs_you")
        assert row(inst, win["window"], other_tab)["mark"] == "needs_you"
        assert rpc(inst, "debug.ui.attention")["badge"] == "1"
        set_agent(inst, pane, "claude", title="Long task", status="needs_input", mark="needs_you")
        assert rpc(inst, "debug.ui.attention")["badge"] == "2"
        set_agent(inst, pane, "claude", title="Long task", status="working", mark="none")
        assert row(inst, win["window"], tab)["mark"] == "working", "the row shows the pane indicator (PI-2)"
        assert rpc(inst, "debug.ui.attention")["badge"] == "1"
    finally:
        clear_agent(inst, pane)
        clear_agent(inst, other)
    assert rpc(inst, "debug.ui.attention")["badge"] == ""


@pytest.mark.req("S-3")
def test_looking_at_the_pane_clears_the_mark(inst, win, assume_active):
    pane, tab = new_tab(inst, win)
    try:
        set_agent(inst, pane, "claude", title="Long task", status="idle", mark="finished")
        assert row(inst, win["window"], tab)["mark"] == "finished"
        inst.cli("tab", "focus", tab)
        wait_until(lambda: row(inst, win["window"], tab)["mark"] == "none", 5, message="a tab switch is a look")
        assert rpc(inst, "debug.ui.attention")["badge"] == ""
        # A question, then focusing the pane from another tab: it still needs the user (the mark
        # follows agent.status=needs_input), and a finish after it is seen as it happens.
        inst.cli("tab", "focus", win["tab"])
        set_agent(inst, pane, "claude", title="Long task", status="needs_input", mark="needs_you")
        assert row(inst, win["window"], tab)["mark"] == "needs_you"
        inst.cli("pane", "focus", pane)
        time.sleep(0.5)
        assert row(inst, win["window"], tab)["mark"] == "needs_you", "looking doesn't answer the question"
        # A finish seen as it happens leaves no mark.
        set_agent(inst, pane, "claude", title="Long task", status="idle", mark="finished")
        wait_until(lambda: row(inst, win["window"], tab)["mark"] == "none", 5, message="seen as it finished")
    finally:
        clear_agent(inst, pane)


@pytest.mark.req("S-3")
def test_looking_at_the_pane_clears_the_mark_ui(inst, win, ui):
    """The real thing: the app in front, a tab switch and a pane focus clear the marks."""
    pane, tab = new_tab(inst, win)
    try:
        ui.activate()
        set_agent(inst, pane, "claude", title="Long task", status="idle", mark="finished")
        assert row(inst, win["window"], tab)["mark"] == "finished"
        inst.cli("tab", "focus", tab)
        ui.activate()
        wait_until(lambda: row(inst, win["window"], tab)["mark"] == "none", 10, message="looked at")
        set_agent(inst, pane, "codex", title="Quick", status="idle", mark="finished")
        wait_until(lambda: row(inst, win["window"], tab)["mark"] == "none", 5, message="seen as it finished")
    finally:
        clear_agent(inst, pane)


# ---- S-4: the row menu ---------------------------------------------------------------------------

# Warp's labels (its tab.rs). Move Tab Down and Close Tabs Below are left out for the last tab, as in
# Warp; test_umi_sidebar_warp.py checks them on a tab in the middle.
WARP_ITEMS = ["Pin tab", "Copy working directory", "Copy tab title", "Rename tab", "Rename active pane", "Move Tab Up",
              "Close tab", "Close other tabs", "Tab Color", "Move Tab to New Window"]


@pytest.mark.req("S-4")
def test_the_row_menu_has_warps_items(inst, win, tmp_path):
    repo = tmp_path / "menurepo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "menu-branch", str(repo)], check=True)
    pane, tab = new_tab(inst, win, "--cwd", str(repo))
    inst.cli("tab", "rename", tab, "named")
    inst.cli("pane", "rename", pane, "pane-named")
    wait_until(lambda: any(i["title"] == "Copy branch" for i in rpc(inst, "debug.ui.menu", tab=tab)["items"]), 10,
               message="Copy branch")
    titles = [i["title"] for i in rpc(inst, "debug.ui.menu", tab=tab)["items"]]
    missing = [t for t in WARP_ITEMS + ["Copy branch", "Reset tab name", "Reset active pane name"] if t not in titles]
    assert not missing, f"missing: {missing}"
    colors = [i for i in rpc(inst, "debug.ui.menu", tab=tab)["items"] if i["path"].startswith("Tab Color > ")]
    assert len(colors) == 7 and sum(i["checked"] for i in colors) == 1

    def perform(title):
        return rpc(inst, "debug.ui.menu.perform", tab=tab, title=title)

    assert perform("Copy branch")["copied"] == "menu-branch"
    assert os.path.realpath(perform("Copy working directory")["copied"]) == os.path.realpath(repo)
    assert perform("Copy tab title")["copied"] == "named"
    perform("Reset tab name")
    assert not tab_of(inst, tab).get("name")
    perform("Reset active pane name")
    assert not inst.json("pane", "info", pane).get("name")
    perform("Tab Color > Blue")
    assert tab_of(inst, tab)["color"] == "blue"
    perform("Pin tab")
    assert tab_of(inst, tab)["pinned"] and tab_ids(inst, win["window"])[0] == tab
    perform("Unpin tab")


@pytest.mark.req("S-4", "L-2")
def test_move_tab_up_and_down_stay_in_their_pin_group(inst, win):
    _, t2 = new_tab(inst, win)
    _, t3 = new_tab(inst, win)
    t1 = win["tab"]
    assert tab_ids(inst, win["window"]) == [t1, t2, t3]
    rpc(inst, "debug.ui.menu.perform", tab=t3, title="Move Tab Up")
    assert tab_ids(inst, win["window"]) == [t1, t3, t2]
    rpc(inst, "debug.ui.menu.perform", tab=t1, title="Move Tab Down")
    assert tab_ids(inst, win["window"]) == [t3, t1, t2]
    menu = {i["title"]: i for i in rpc(inst, "debug.ui.menu", tab=t3)["items"]}
    assert "Move Tab Up" not in menu, "the first tab can't move up (left out, as in Warp)"
    inst.cli("tab", "pin", t2)
    # Pinning moves only the pinned tab, to the end of the pinned group (S-7); the first unpinned
    # tab sits right below it and can't move up into it.
    assert tab_ids(inst, win["window"]) == [t2, t3, t1]
    menu = {i["title"]: i for i in rpc(inst, "debug.ui.menu", tab=t3)["items"]}
    assert "Move Tab Up" not in menu, "an unpinned tab can't move into the pinned group"
    menu = {i["title"]: i for i in rpc(inst, "debug.ui.menu", tab=t2)["items"]}
    assert "Move Tab Down" not in menu, "a pinned tab can't move out of the pinned group"
    inst.cli("tab", "unpin", t2)


@pytest.mark.req("S-4", "L-2", "L-20")
def test_close_other_tabs_and_tabs_below(inst, win):
    p2, t2 = new_tab(inst, win)
    p3, t3 = new_tab(inst, win)
    p4, t4 = new_tab(inst, win)
    ready(inst, p2, p3, p4)
    rpc(inst, "debug.ui.menu.perform", tab=t2, title="Close Tabs Below")
    assert tab_ids(inst, win["window"]) == [win["tab"], t2]
    p5, t5 = new_tab(inst, win)
    ready(inst, p5)
    rpc(inst, "debug.ui.menu.perform", tab=t5, title="Close other tabs")
    assert tab_ids(inst, win["window"]) == [t5]
    # Each closed tab can be reopened.
    assert inst.json("reopen")["kind"] == "tab"
    assert len(tab_ids(inst, win["window"])) == 2


# ---- S-8: sidebar width ---------------------------------------------------------------------------

@pytest.mark.req("S-8", "S-2")
def test_each_window_has_its_own_sidebar_width(inst, win):
    other = inst.json("window", "new", "--no-focus")
    status = inst.json("sidebar", "status", "--window", win["window"])
    assert {"visible", "mode", "width"} <= set(status)
    inst.cli("sidebar", "width", "320", "--window", win["window"])
    assert inst.json("sidebar", "status", "--window", win["window"])["width"] == 320
    assert inst.json("sidebar", "status", "--window", other["window"])["width"] != 320
    assert rpc(inst, "debug.ui.rows", window=win["window"])["sidebar_width"] == 320
    assert inst.cli("sidebar", "width", "--window", win["window"]).stdout.strip() == "320"
    inst.cli("sidebar", "width", "10", "--window", win["window"])
    assert inst.json("sidebar", "status", "--window", win["window"])["width"] == 180, "a minimum width"
    inst.cli("sidebar", "width", "5000", "--window", win["window"])
    assert inst.json("sidebar", "status", "--window", win["window"])["width"] == 600, "a maximum width"
    inst.cli("window", "close", other["window"])


@pytest.mark.req("S-8", "R-3")
def test_sidebar_widths_are_restored_with_the_layout(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-s8-", restore=True)
    first = other.json("window", "new", "--name", "wide")["window"]
    second = other.json("window", "new", "--name", "narrow")["window"]
    other.cli("sidebar", "width", "333", "--window", first)
    other.cli("sidebar", "width", "210", "--window", second)
    time.sleep(0.6)
    other.quit_app()
    other.start_app()
    widths = {}
    for w in other.tree()["windows"]:
        widths[w["id"]] = other.json("sidebar", "status", "--window", w["id"])["width"]
    assert {210, 333} <= set(widths.values()), widths


# ---- M-4: dragging a pane to the previous or next tab ---------------------------------------------

def _select(inst, win, tab):
    inst.cli("tab", "focus", tab)
    wait_until(lambda: window_of(inst, win["window"])["selected_tab"] == tab, 5, message="the tab shown")


@pytest.mark.req("M-4", "M-1")
def test_a_pane_dropped_on_the_previous_or_next_tab_target_moves_there(inst, win):
    t1 = win["tab"]
    p2, t2 = new_tab(inst, win)
    q2 = split(inst, "right", p2, "--no-focus")
    p3, t3 = new_tab(inst, win)
    marker = "TABDROP-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, q2, f"echo {marker}", marker)
    _select(inst, win, t2)

    # Top centre: q2 goes to the end of the previous tab, which is shown with q2 focused.
    result = rpc(inst, "debug.ui.pane.tabdrop", pane=q2, target="previous")
    assert result["tab"] == t1
    assert [p["id"] for p in tab_of(inst, t1)["panes"]] == [win["pane"], q2]
    assert window_of(inst, win["window"])["selected_tab"] == t1
    assert inst.tree().get("current_pane") == q2
    assert marker in inst.cli("read", "--pane", q2, "--scrollback").stdout, "the session kept running"
    # The first tab has no previous tab.
    with pytest.raises(AssertionError, match="no previous tab"):
        rpc(inst, "debug.ui.pane.tabdrop", pane=q2, target="previous")

    # Bottom centre: back to the next tab, beside its last pane.
    rpc(inst, "debug.ui.pane.tabdrop", pane=q2, target="next")
    assert [p["id"] for p in tab_of(inst, t2)["panes"]] == [p2, q2]
    assert window_of(inst, win["window"])["selected_tab"] == t2

    # A tab's only pane: in the last tab, "next" makes a new tab after it, and its old tab closes.
    _select(inst, win, t3)
    result = rpc(inst, "debug.ui.pane.tabdrop", pane=p3, target="next")
    ids = tab_ids(inst, win["window"])
    assert t3 not in ids and ids[:2] == [t1, t2] and ids[2] == result["tab"]
    assert [p["id"] for p in tab_of(inst, result["tab"])["panes"]] == [p3]


@pytest.mark.req("M-4")
def test_dragging_a_pane_to_the_top_or_bottom_centre_moves_it_between_tabs_ui(inst, win, ui):
    """The real mouse: the pane's chip in the pane strip (its drag handle, H-8) dragged onto the
    targets."""
    t1 = win["tab"]
    p2, t2 = new_tab(inst, win)
    ready(inst, p2)
    _select(inst, win, t2)
    inst.cli("window", "focus", win["window"])
    ui.activate()

    def pane_area():
        element = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Terminal pane"), 5, message="the pane")
        return _frame(ui, element)

    def chip(pane):
        inst.cli("pane", "rename", pane, "drag-" + pane[:6])
        strip = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Pane strip"), 5, message="the pane strip")
        element = wait_until(lambda: ui.find(lambda e: ui.label(e) == "drag-" + pane[:6], root=strip), 5, message="the chip")
        cx, cy, cw, chh = _frame(ui, element)
        return cx + cw / 2, cy + chh / 2

    x, y, w, h = pane_area()
    _mouse_drag(chip(p2), (x + w / 2, y + 36))
    wait_until(lambda: [p["id"] for p in tab_of(inst, t1)["panes"]] == [win["pane"], p2], 5,
               message="moved to the end of the previous tab")
    assert tab_of(inst, t2) is None, "its tab, left empty, closed"

    # Back down: the first tab is shown with two panes; drag the second one (the right half).
    # The accessibility tree doesn't tell split panes apart, so the app's frames (relative to the
    # same pane area) place it.
    area_x, area_y = x, y
    wait_until(lambda: len(tab_of(inst, t1)["panes"]) == 2, 5, message="two panes shown")
    f = frames(inst, t1)[p2]
    left = frames(inst, t1)[win["pane"]]
    px, py, pw, ph = area_x + f["x"], area_y + f["y"], f["width"], f["height"]
    area_centre = area_x + (left["x"] + f["x"] + pw) / 2
    _mouse_drag(chip(p2), (area_centre, py + ph - 36))
    wait_until(lambda: len(tab_ids(inst, win["window"])) == 2 and [p["id"] for p in tab_of(inst, t1)["panes"]] == [win["pane"]],
               5, message="moved to a new tab after the last")


# ---- M-4: dropping panes and tabs on the sidebar, dragging tabs out ------------------------------

@pytest.mark.req("M-4", "M-1")
def test_a_pane_dropped_on_a_row_moves_into_that_tab(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    marker = "DROP-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, b, f"echo {marker}", marker)
    p2, t2 = new_tab(inst, win)
    result = rpc(inst, "debug.ui.drop", window=win["window"], pane=b, row=t2, zone="into")
    assert result["dropped"] and result["tab"] == t2
    assert {p["id"] for p in tab_of(inst, t2)["panes"]} == {p2, b}
    assert shares(inst, t2, [p2, b]) == pytest.approx([50, 50], abs=0.2)
    assert marker in inst.cli("read", "--pane", b, "--scrollback").stdout
    # Its own tab's row takes nothing (the pane is already there).
    assert not rpc(inst, "debug.ui.drop", window=win["window"], pane=a, row=win["tab"], zone="into")["dropped"]


@pytest.mark.req("M-4", "M-1")
def test_a_pane_dropped_between_rows_makes_a_new_tab_there(inst, win):
    a = win["pane"]
    b = split(inst, "right", a)
    c = split(inst, "right", b)
    _, t2 = new_tab(inst, win)
    rpc(inst, "debug.ui.drop", window=win["window"], pane=b, row=t2, zone="before")
    ids = tab_ids(inst, win["window"])
    assert len(ids) == 3 and ids[0] == win["tab"] and ids[2] == t2
    assert [p["id"] for p in tab_of(inst, ids[1])["panes"]] == [b]
    rpc(inst, "debug.ui.drop", window=win["window"], pane=c, row=t2, zone="after")
    ids = tab_ids(inst, win["window"])
    assert len(ids) == 4 and ids[2] == t2 and [p["id"] for p in tab_of(inst, ids[3])["panes"]] == [c]
    rpc(inst, "debug.ui.drop", window=win["window"], pane=a, zone="end")
    ids = tab_ids(inst, win["window"])
    assert [p["id"] for p in tab_of(inst, ids[-1])["panes"]] == [a]
    assert win["tab"] not in ids, "the emptied tab closed"


@pytest.mark.req("M-4", "M-2")
def test_a_tab_dropped_between_rows_lands_there(inst, win):
    _, t2 = new_tab(inst, win)
    _, t3 = new_tab(inst, win)
    t1 = win["tab"]
    rpc(inst, "debug.ui.drop", window=win["window"], tab=t3, row=t1, zone="before")
    assert tab_ids(inst, win["window"]) == [t3, t1, t2]
    rpc(inst, "debug.ui.drop", window=win["window"], tab=t3, row=t2, zone="after")
    assert tab_ids(inst, win["window"]) == [t1, t2, t3]
    rpc(inst, "debug.ui.drop", window=win["window"], tab=t1, row=t2, zone="after")
    assert tab_ids(inst, win["window"]) == [t2, t1, t3]


def _point_outside(frame):
    """A point on the main screen outside a window's frame (AppKit screen coordinates), or None."""
    from AppKit import NSScreen
    visible = NSScreen.mainScreen().visibleFrame()
    vx, vy, vw, vh = visible.origin.x, visible.origin.y, visible.size.width, visible.size.height
    x, y, w, h = frame["x"], frame["y"], frame["width"], frame["height"]
    for px, py in ((x + w + 120, y + h - 80), (x - 120, y + h - 80), (x + 80, y - 120), (x + 80, y + h + 60)):
        if vx + 20 < px < vx + vw - 20 and vy + 20 < py < vy + vh - 20:
            return px, py
    return None


@pytest.mark.req("M-4", "M-2", "M-6")
def test_a_tab_dragged_out_of_its_window_makes_a_window_at_the_drop_point(inst, win):
    p2, t2 = new_tab(inst, win)
    marker = "OUT-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, p2, f"echo {marker}", marker)
    frame = rpc(inst, "debug.ui.rows", window=win["window"])["frame"]
    # Dropped back over its own window, between targets: nothing happens.
    inside = rpc(inst, "debug.ui.drag_out", tab=t2, x=frame["x"] + frame["width"] / 2, y=frame["y"] + frame["height"] / 2)
    assert inside["window"] == "" and t2 in tab_ids(inst, win["window"])
    # Outside: a window of its own, at the drop point, with the tab's program still running.
    before = {w["id"] for w in inst.tree()["windows"]}
    point = _point_outside(frame)
    x, y = point if point else (frame["x"] + frame["width"] + 5000, frame["y"])
    result = rpc(inst, "debug.ui.drag_out", tab=t2, x=x, y=y)
    assert result["window"] and result["window"] not in before
    assert [t["id"] for t in window_of(inst, result["window"])["tabs"]] == [t2]
    assert t2 not in tab_ids(inst, win["window"])
    if point:
        f = result["frame"]
        assert f["x"] <= x <= f["x"] + f["width"] and f["y"] <= y <= f["y"] + f["height"], "the window is where it was dropped"
    marker2 = "OUT2-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, p2, f"echo {marker2}", marker2)
    assert marker in inst.cli("read", "--pane", p2, "--scrollback").stdout


# ---- E-10: text files open in the closest tab, Markdown in the docs tab---------------------------------------------------

@pytest.mark.req("E-10", "I-3")
def test_text_files_open_in_the_tab_whose_folder_is_closest(inst, win, tmp_path):
    root = tmp_path / "proj"
    deep = root / "pkg" / "docs"
    deep.mkdir(parents=True)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    for path in (deep / "guide.txt", root / "README.txt", elsewhere / "notes.txt", elsewhere / "more.txt"):
        path.write_text(f"# {path.name}\n")
    p_root, t_root = new_tab(inst, win, "--cwd", str(root))
    p_pkg, t_pkg = new_tab(inst, win, "--cwd", str(root / "pkg"))

    def opened(path):
        return rpc(inst, "debug.ui.open_file", path=str(path))

    assert opened(deep / "guide.txt")["tab"] == t_pkg, "the deepest folder containing the file"
    assert opened(root / "README.txt")["tab"] == t_root
    # Already open: it shows where it is.
    inst.cli("tab", "focus", t_root)
    assert opened(deep / "guide.txt")["tab"] == t_pkg
    # No tab above it: a new tab in its folder, in the current window, right after the current tab
    # (S-7); the next file there joins it.
    inst.cli("tab", "focus", win["tab"])
    before = tab_ids(inst, win["window"])
    first = opened(elsewhere / "notes.txt")
    assert first["window"] == win["window"] and first["tab"] not in before
    assert tab_ids(inst, win["window"]) == before[:1] + [first["tab"]] + before[1:], "right after the current tab"
    new_pane = tab_of(inst, first["tab"])["panes"][0]
    assert os.path.realpath(new_pane["cwd"]) == os.path.realpath(elsewhere)
    assert opened(elsewhere / "more.txt")["tab"] == first["tab"]
    docs = inst.json("editor", "ls", "--tab", first["tab"])["documents"]
    assert {os.path.basename(d["path"]) for d in docs} == {"notes.txt", "more.txt"}


@pytest.mark.req("E-10")
def test_ties_go_to_the_current_tab_and_any_pane_of_a_tab_counts(inst, win, tmp_path):
    root = tmp_path / "tie"
    (root / "sub").mkdir(parents=True)
    (root / "a.txt").write_text("# a\n")
    (root / "sub" / "b.txt").write_text("# b\n")
    _, t1 = new_tab(inst, win, "--cwd", str(root))
    p2, t2 = new_tab(inst, win, "--cwd", str(root))
    inst.cli("tab", "focus", t2)
    assert rpc(inst, "debug.ui.open_file", path=str(root / "a.txt"))["tab"] == t2
    # A second pane of t1 in the deeper folder makes t1 the closest, though it isn't focused.
    split(inst, "right", tab_of(inst, t1)["panes"][0]["id"], "--cwd", str(root / "sub"), "--no-focus")
    assert rpc(inst, "debug.ui.open_file", path=str(root / "sub" / "b.txt"))["tab"] == t1


@pytest.mark.req("E-10", "H-1")
def test_markdown_opens_in_the_docs_tab_at_its_right_end_three_on_show(inst, win, tmp_path):
    names = [f"doc{i}.md" for i in range(1, 6)]
    for i, name in enumerate(names):
        folder = tmp_path / ("a" if i % 2 else "b")   # two folders: the folder doesn't matter
        folder.mkdir(exist_ok=True)
        (folder / name).write_text(f"# {name}\n")
    paths = {name: next(tmp_path.glob(f"*/{name}")) for name in names}
    before = tab_ids(inst, win["window"])
    first = rpc(inst, "debug.ui.open_file", path=str(paths["doc1.md"]))
    assert first["window"] == win["window"] and first["tab"] not in before
    docs_tab = first["tab"]
    for name in names[1:]:
        assert rpc(inst, "debug.ui.open_file", path=str(paths[name]))["tab"] == docs_tab
    assert len(tab_ids(inst, win["window"])) == len(before) + 1, "one tab for all of them"
    tab = tab_of(inst, docs_tab)
    assert tab["attributes"]["role"] == "docs" and tab.get("name") == "Docs" and tab["selected"]
    on_show = [os.path.basename(p["file"]) for p in tab["panes"] if not p["hidden"]]
    # Each new one at the right end of the tab, focused; three on show, the others hidden.
    assert len(on_show) == 3 and on_show[-1] == "doc5.md", on_show
    assert {os.path.basename(p["file"]) for p in tab["panes"]} == set(names), "every one stays in the tab"
    assert inst.tree()["current_pane"] == next(p["id"] for p in tab["panes"] if p["file"].endswith("doc5.md"))
    # Opening a hidden one again shows it where it is: brought in, no second pane.
    hidden_one = next(os.path.basename(p["file"]) for p in tab["panes"] if p["hidden"])
    rpc(inst, "debug.ui.open_file", path=str(paths[hidden_one]))
    tab = tab_of(inst, docs_tab)
    assert len(tab["panes"]) == 5
    assert hidden_one in [os.path.basename(p["file"]) for p in tab["panes"] if not p["hidden"]]
    # Text files still go by folder: a tab with a pane in their folder (the docs tab's panes start
    # in their files' folders, so a folder of its own here).
    other = tmp_path / "c"
    other.mkdir()
    (other / "notes.txt").write_text("notes\n")
    assert rpc(inst, "debug.ui.open_file", path=str(other / "notes.txt"))["tab"] != docs_tab


# ---- UI (real mouse; the lead runs these) ---------------------------------------------------------

def _mouse_drag(start, end, steps=30, hold=0.25):
    import Quartz
    def post(kind, point):
        event = Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    post(Quartz.kCGEventMouseMoved, start)
    time.sleep(0.2)
    post(Quartz.kCGEventLeftMouseDown, start)
    time.sleep(hold)
    for i in range(1, steps + 1):
        x = start[0] + (end[0] - start[0]) * i / steps
        y = start[1] + (end[1] - start[1]) * i / steps
        post(Quartz.kCGEventLeftMouseDragged, (x, y))
        time.sleep(0.02)
    time.sleep(0.3)
    post(Quartz.kCGEventLeftMouseUp, end)
    time.sleep(0.5)


def _right_click(rect):
    """A real right-click in the middle of rect (top-left screen coordinates, as AX gives)."""
    import Quartz
    x, y, w, h = rect
    point = (x + w / 2, y + h / 2)
    for kind in (Quartz.kCGEventMouseMoved, Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp):
        event = Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonRight)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.1)


def _frame(ui, element):
    pos = ui.attr(element, "AXPosition")
    size = ui.attr(element, "AXSize")
    import ApplicationServices as AX  # noqa: N812
    p = AX.AXValueGetValue(pos, AX.kAXValueCGPointType, None)[1]
    s = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)[1]
    return p.x, p.y, s.width, s.height


def _row_element(ui, title):
    return ui.find(lambda e: ui.role(e) in ("AXButton", "AXGroup", "AXStaticText") and ui.label(e) == title)


def _window_of(ui, element):
    while element is not None and ui.role(element) != "AXWindow":
        element = ui.attr(element, "AXParent")
    return element


def _screen_point_outside(rect):
    """A point on the main display (top-left coordinates, as AX and CGEvent use) outside rect."""
    import Quartz
    b = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
    x, y, w, h = rect
    for px, py in ((x + w + 150, y + 120), (x - 150, y + 120), (x + 120, y + h + 80), (x + 120, y - 80)):
        if b.origin.x + 30 < px < b.origin.x + b.size.width - 30 and b.origin.y + 60 < py < b.origin.y + b.size.height - 30:
            return px, py
    return None


@pytest.mark.req("M-4")
def test_dragging_a_tab_row_out_of_the_window_makes_a_window_ui(inst, win, ui):
    _, t2 = new_tab(inst, win, "--name", "drag-me-out")
    inst.cli("window", "focus", win["window"])
    ui.activate()
    element = wait_until(lambda: _row_element(ui, "drag-me-out"), 5, message="the row in the accessibility tree")
    x, y, w, h = _frame(ui, element)
    end = _screen_point_outside(_frame(ui, _window_of(ui, element)))
    if end is None:
        pytest.skip("the window covers the screen; no room to drop outside it")
    before = {w["id"] for w in inst.tree()["windows"]}
    _mouse_drag((x + w / 2, y + h / 2), end)
    wait_until(lambda: any(w["id"] not in before and [t["id"] for t in w["tabs"]] == [t2] for w in inst.tree()["windows"]),
               5, message="a new window holding the tab")


@pytest.mark.req("M-4", "S-4")
def test_dragging_a_tab_row_reorders_and_the_row_menu_opens_ui(inst, win, ui):
    _, t2 = new_tab(inst, win, "--name", "drag-second")
    _, t3 = new_tab(inst, win, "--name", "drag-third")
    inst.cli("window", "focus", win["window"])
    ui.activate()
    third = wait_until(lambda: _row_element(ui, "drag-third"), 5, message="the row")
    first = _row_element(ui, tab_of(inst, win["tab"])["title"])
    x3, y3, w3, h3 = _frame(ui, third)
    x1, y1, w1, h1 = _frame(ui, first)
    _mouse_drag((x3 + w3 / 2, y3 + h3 / 2), (x1 + w1 / 2, y1 + 4))
    wait_until(lambda: tab_ids(inst, win["window"])[0] == t3, 5, message="dropped before the first row")
    # Right-click menu: Warp's items. The menu sits in the window's accessibility tree, not
    # among the app's children.
    # The middle row (now the window's first tab), where every move and close item applies.
    _right_click(_frame(ui, _row_element(ui, tab_of(inst, win["tab"])["title"])))
    menus = wait_until(lambda: ui.find_all(lambda e: ui.role(e) == "AXMenu"), 3, message="the row menu")
    titles = set(t for m in menus for t in ui.texts(m))
    ui.key(ui.ESCAPE)
    wait_until(lambda: not ui.find_all(lambda e: ui.role(e) == "AXMenu"), 3, message="Escape closed the menu")
    missing = [t for t in ("Copy tab title", "Move Tab Up", "Close Tabs Below", "Close other tabs",
                           "Default (no color)") if t not in titles]
    assert not missing, f"the row menu lacks {missing} (it has {sorted(titles)})"
