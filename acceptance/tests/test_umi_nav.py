"""Moving around Umi from the keyboard, menus, palettes and CLI (SPEC L-9 to L-18, S-7).

Shortcuts work whatever has focus; ⌘⇧[ goes back through the tabs visited; ⌘⇧] walks the
sidebar order; ⌃⌘J / ⌃⌘K go to the sessions that need the user and back; ⌃⇧←/→ move tabs;
⌘P, ⇧⌘P and ⌘O open the command, pane and file palettes; ⌘, opens Settings, where shortcuts
are edited; a close returns focus to the pane used before; tabs stay where the user put them:
selecting one or an agent finishing its turn moves nothing, as in Warp (S-7).

Most checks go through the CLI. Behavior that only the UI shows is checked through the app's
internal `debug.*` control methods (menus, the palettes, a key press delivered inside the app,
attention data standing in for the agent engine). Tests that need the accessibility tree are
marked `ui` and take over the keyboard; run them only when nobody is using the Mac.
"""

import json
import os
import socket
import subprocess
import time

import pytest

from harness import wait_until

pytestmark = pytest.mark.layout


# ---- helpers ------------------------------------------------------------------------------------

def rpc(inst, method, timeout=60, **params):
    """Call one of the app's control methods directly (the internal debug.* ones included)."""
    with open(os.path.join(inst.dir, "instance.json")) as f:
        path = json.load(f)["socket"]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
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
    if "error" in reply:
        raise AssertionError(f"{method}: {reply['error']['message']}")
    return reply["result"]


def pane_info(inst, pane):
    return inst.json("pane", "info", pane)


def window_of(inst, window_id):
    return next(w for w in inst.tree()["windows"] if w["id"] == window_id)


def tab_ids(inst, window_id):
    return [t["id"] for t in window_of(inst, window_id)["tabs"]]


def selected(inst, window_id):
    return window_of(inst, window_id)["selected_tab"]


def new_tab(inst, win, *extra):
    pane = inst.cli("tab", "new", "--window", win["window"], *extra).stdout.strip()
    return pane_info(inst, pane)


def menu_item(inst, title):
    return next((i for i in rpc(inst, "debug.menu")["items"] if i["title"] == title), None)


# ---- L-9, L-10: shortcuts are menu items and work whatever has focus --------------------------------

NAV_SHORTCUTS = {
    "Back to Previous Tab": ("[", ["shift", "cmd"]),
    "Show Next Tab": ("]", ["shift", "cmd"]),
    "Cycle to Next Tab": ("\t", ["ctrl"]),
    "Cycle to Previous Tab": ("\t", ["ctrl", "shift"]),
    "Tab 1": ("1", ["cmd"]), "Tab 2": ("2", ["cmd"]), "Tab 8": ("8", ["cmd"]), "Last Tab": ("9", ["cmd"]),
    "Move Tab Up": ("left", ["ctrl", "shift"]),
    "Move Tab Down": ("right", ["ctrl", "shift"]),
    "Command Palette…": ("p", ["cmd"]),
    "Go to Pane…": ("p", ["shift", "cmd"]),
    "Open Quickly…": ("o", ["cmd"]),
    "Settings…": (",", ["cmd"]),
    "Jump to Next Session Needing You": ("j", ["ctrl", "cmd"]),
    "Jump Back": ("k", ["ctrl", "cmd"]),
}


@pytest.mark.req("L-9")
def test_navigation_shortcuts_are_menu_items(inst, win):
    items = rpc(inst, "debug.menu")["items"]
    for title, (key, mods) in NAV_SHORTCUTS.items():
        found = [i for i in items if i["title"] == title]
        assert len(found) == 1, f"one menu item {title!r}: {found}"
        assert found[0]["key"].lower() == key and found[0]["modifiers"] == mods, (title, found[0])
        # No other menu item has the same shortcut.
        same = [i["title"] for i in items if i["key"].lower() == key and i["modifiers"] == mods]
        assert same == [title], f"{title}: the shortcut is also on {same}"


@pytest.mark.req("L-10")
def test_ghostty_no_longer_binds_the_tab_keys(inst, win):
    """The terminal doesn't take the tab keys first: Umi's defaults unbind Ghostty's bindings for
    them, so one path handles each key wherever focus is."""
    shortcuts = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    for action in ("next_tab", "previous_tab", "toggle_command_palette", "goto_tab:1", "last_tab"):
        entry = shortcuts.get("ghostty:" + action)
        assert entry is None or entry["keys"] == [], (action, entry)
    assert shortcuts["tab.next"]["keys"] == ["shift+cmd+]"]
    assert shortcuts["tab.cycle_next"]["keys"] == ["ctrl+tab"]


@pytest.mark.req("L-10")
@pytest.mark.parametrize("focus", ["terminal", "editor", "palette", "settings"])
def test_tab_keys_work_whatever_has_focus(inst, win, tmp_path, focus):
    """⇧⌘] and ⌃Tab change tabs with focus in a terminal, the editor, the palette or Settings
    (a key press delivered inside the app; the AX test below presses real keys)."""
    second = new_tab(inst, win)
    inst.cli("tab", "focus", win["tab"])
    if focus == "editor":
        doc = tmp_path / "notes.txt"
        doc.write_text("hello\n")
        inst.cli("edit", str(doc), "--tab", win["tab"])
    before = selected(inst, win["window"])
    result = rpc(inst, "debug.key", window=win["window"], keys="cmd+shift+]", focus=focus)
    result["current_window"] = inst.tree().get("current_window") == win["window"]
    wait_until(lambda: selected(inst, win["window"]) != before, 5, message=f"⇧⌘] from {focus} ({result})")
    assert selected(inst, win["window"]) == second["tab"]
    rpc(inst, "debug.palette.close", window=win["window"])
    before = selected(inst, win["window"])
    rpc(inst, "debug.key", window=win["window"], keys="ctrl+tab", focus=focus)
    wait_until(lambda: selected(inst, win["window"]) != before, 5, message=f"⌃Tab from {focus}")
    rpc(inst, "debug.palette.close", window=win["window"])
    assert result["handled"] or selected(inst, win["window"]) != before


# ---- L-11: back through the tabs visited; next in sidebar order; ⌘1–9 -----------------------------

@pytest.mark.req("L-11")
def test_tab_back_follows_the_tabs_visited_across_windows(inst, win):
    a2 = new_tab(inst, win)
    other = inst.json("window", "new")
    b1 = pane_info(inst, other["pane"])
    # Visit: win's first tab, then the other window's tab, then win's second tab.
    inst.cli("tab", "focus", win["tab"])
    inst.cli("tab", "focus", b1["tab"])
    inst.cli("tab", "focus", a2["tab"])
    assert inst.tree()["current_tab"] == a2["tab"]
    back = inst.json("tab", "back")
    assert back["tab"] == b1["tab"] and back["window"] == other["window"]
    assert inst.tree()["current_tab"] == b1["tab"]
    # Pressed again: the tab before that, in the first window.
    back = inst.json("tab", "back")
    assert back["tab"] == win["tab"] and inst.tree()["current_tab"] == win["tab"]
    # Visiting a tab another way ends the walk: back then returns to where the walk ended.
    inst.cli("tab", "focus", a2["tab"])
    assert inst.json("tab", "back")["tab"] == win["tab"]


@pytest.mark.req("L-11")
def test_tab_back_skips_closed_tabs_and_fails_clearly_at_the_start(fresh):
    inst = fresh(prefix="acc-nav-")
    win = inst.json("window", "new")
    first = pane_info(inst, win["pane"])["tab"]
    second = new_tab(inst, {"window": win["window"]})
    third = new_tab(inst, {"window": win["window"]})
    inst.cli("tab", "close", second["tab"])
    wait_until(lambda: second["tab"] not in tab_ids(inst, win["window"]), 5, message="tab closed")
    inst.cli("tab", "focus", third["tab"])
    assert inst.json("tab", "back")["tab"] == first
    proc = inst.cli("tab", "back", check=False)
    if proc.returncode != 0:
        assert "earlier tab" in proc.stderr


@pytest.mark.req("L-11", "S-7")
def test_next_and_prev_walk_the_sidebar_order_which_stays_put(inst, win):
    """⇧⌘] goes down the list and ⌃⇧Tab up it, both wrapping around, and the list never changes on
    the way (before 0.6.1 the selected tab moved to the top a moment after the last press)."""
    tabs = [win["tab"]] + [new_tab(inst, win)["tab"] for _ in range(3)]
    assert tab_ids(inst, win["window"]) == tabs, "each new tab opens right after the current one"
    inst.cli("tab", "focus", win["tab"])
    walked = [inst.json("tab", "next")["tab"] for _ in range(4)]
    assert walked == tabs[1:] + tabs[:1], f"walked {walked}, the list was {tabs}"
    inst.json("tab", "next")
    time.sleep(1.5)  # longer than the old order's settle delay
    assert tab_ids(inst, win["window"]) == tabs, "walking moved tabs"
    assert selected(inst, win["window"]) == tabs[1]
    assert [inst.json("tab", "prev")["tab"] for _ in range(2)] == [tabs[0], tabs[-1]], "prev wraps to the last"
    assert tab_ids(inst, win["window"]) == tabs


@pytest.mark.req("L-11")
def test_tab_number_items_and_cycling(inst, win):
    second = new_tab(inst, win)
    third = new_tab(inst, win)
    inst.cli("tab", "focus", win["tab"])
    order = tab_ids(inst, win["window"])
    assert order == [win["tab"], second["tab"], third["tab"]]
    rpc(inst, "debug.menu.perform", title="Tab 2")
    assert selected(inst, win["window"]) == order[1]
    rpc(inst, "debug.menu.perform", title="Last Tab")
    assert selected(inst, win["window"]) == order[2]
    rpc(inst, "debug.menu.perform", title="Tab 1")
    assert selected(inst, win["window"]) == order[0]
    rpc(inst, "debug.menu.perform", title="Cycle to Previous Tab")
    assert selected(inst, win["window"]) == order[2]
    rpc(inst, "debug.menu.perform", title="Cycle to Next Tab")
    assert selected(inst, win["window"]) == order[0]
    assert tab_ids(inst, win["window"]) == order, "selecting by number or cycling moved tabs"


# ---- L-12: the sessions that need the user, and back -----------------------------------------------

@pytest.mark.req("L-12")
def test_jump_goes_to_sessions_needing_you_then_back(inst, win):
    # Only this test's marks: sessions earlier tests left in the shared instance may have theirs.
    for pane in rpc(inst, "debug.ui.attention")["panes"]:
        rpc(inst, "debug.attention.set", pane=pane, clear=True)
    home = win["pane"]
    finished = new_tab(inst, win, "--no-focus")
    waiting = new_tab(inst, win, "--no-focus")
    rpc(inst, "debug.attention.set", pane=finished["id"], title="worker A", mark="finished", stopped_ago=60)
    rpc(inst, "debug.attention.set", pane=waiting["id"], title="worker B", mark="needs_you", stopped_ago=10)
    try:
        inst.cli("pane", "focus", home)
        # Needs input comes first, then finished-and-unseen.
        assert inst.json("jump")["pane"] == waiting["id"]
        assert inst.tree()["current_pane"] == waiting["id"]
        assert inst.json("jump")["pane"] == finished["id"]
        # Back returns to where the user was before the first jump.
        assert inst.json("jump", "back")["pane"] == home
        assert inst.tree()["current_pane"] == home
        assert inst.cli("jump", "back", check=False).returncode != 0
    finally:
        for pane in (finished["id"], waiting["id"]):
            rpc(inst, "debug.attention.set", pane=pane, clear=True)
    proc = inst.cli("jump", check=False)
    assert proc.returncode != 0 and "needs you" in proc.stderr


@pytest.mark.req("L-12")
def test_jump_to_a_session_no_pane_shows(inst, win):
    rpc(inst, "debug.attention.background", items=[{"session": "s-bg-1", "title": "background worker", "since_ago": 5}],
        record_shows=True)
    try:
        assert inst.json("jump")["session"] == "s-bg-1"
        assert "s-bg-1" in rpc(inst, "debug.navigation")["shown_sessions"]
    finally:
        rpc(inst, "debug.attention.background", items=[])


# ---- L-13: moving tabs up and down ----------------------------------------------------------------

@pytest.mark.req("L-13", "L-2")
def test_move_tab_up_and_down_stays_in_its_pin_group(inst, win):
    a = new_tab(inst, win)
    b = new_tab(inst, win)
    inst.cli("tab", "pin", a["tab"])
    order = tab_ids(inst, win["window"])
    assert order[0] == a["tab"]
    unpinned = order[1:]
    # Down then up within the unpinned group.
    inst.cli("tab", "move", unpinned[0], "--down")
    assert tab_ids(inst, win["window"])[1:3] == [unpinned[1], unpinned[0]]
    inst.cli("tab", "move", unpinned[0], "--up")
    assert tab_ids(inst, win["window"])[1:3] == unpinned[:2]
    # Never into the pinned group, nor past the end.
    assert inst.cli("tab", "move", unpinned[0], "--up", check=False).returncode != 0
    assert inst.cli("tab", "move", unpinned[-1], "--down", check=False).returncode != 0
    assert inst.cli("tab", "move", a["tab"], "--down", check=False).returncode != 0
    assert tab_ids(inst, win["window"])[0] == a["tab"]
    # The menu items act on the selected tab.
    inst.cli("tab", "focus", unpinned[0])
    time.sleep(0.2)
    before = tab_ids(inst, win["window"])
    index = before.index(unpinned[0])
    rpc(inst, "debug.menu.perform", title="Move Tab Down")
    assert tab_ids(inst, win["window"]).index(unpinned[0]) == index + 1
    assert b["tab"] in before


# ---- L-14: the command palette offers the CLI's commands ---------------------------------------------

@pytest.mark.req("L-14")
def test_help_json_describes_the_cli(inst):
    described = inst.json("help")
    assert described["cli"] == inst.target.cli_name and described["commands"]
    usages = [c["usage"] for c in described["commands"]]
    text = inst.cli("help").stdout
    # One table: every command of the human help is in the description, and the other way round.
    for usage in usages:
        assert usage.split(" ")[0] in text
    for line in text.splitlines():
        if line.startswith("  ") and not line.startswith("   ") and line.strip():
            first = line.strip().split()[0]
            assert any(u.startswith(first) for u in usages), line
    actions = [a for c in described["commands"] for a in c["actions"]]
    assert any(a["argv"] == ["tab", "rename"] and a["ask"] and a["ask"][0]["name"] == "NAME" for a in actions)
    for action in actions:
        assert action["title"] and action["argv"], action


@pytest.mark.req("L-14")
def test_command_palette_offers_cli_commands_menu_actions_and_ghostty_actions(inst, win):
    entries = rpc(inst, "debug.palette", window=win["window"], mode="commands")["entries"]
    titles = [e["title"] for e in entries]
    try:
        cli = [e for e in entries if e["kind"] == "cli"]
        described = [a["title"] for c in inst.json("help")["commands"] for a in c["actions"]]
        assert set(titles) >= set(described), "every CLI action is offered (as itself or as the menu action of that name)"
        assert len(titles) == len(set(titles)), "one entry per title"
        assert "Toggle Sidebar" in titles and "Back to Previous Tab" in titles, "Umi's menu actions are offered"
        assert any(e["kind"] == "action" and e.get("subtitle") is not None for e in entries) or len(entries) > len(cli)
        # A typed command line runs as typed.
        typed = rpc(inst, "debug.palette", window=win["window"], mode="commands", query="umi ls")["entries"]
        assert typed[0]["title"] == "Run umi ls", typed[:3]
    finally:
        rpc(inst, "debug.palette.close", window=win["window"])


@pytest.mark.req("L-14")
def test_palette_runs_a_cli_command_for_the_focused_pane_and_asks_its_arguments(inst, win):
    other = new_tab(inst, win)
    inst.cli("pane", "focus", other["id"])
    time.sleep(0.3)
    rpc(inst, "debug.palette", window=win["window"], mode="commands", query="rename tab")
    result = rpc(inst, "debug.palette.perform", window=win["window"], title="Rename Tab…", answers=["from-palette"])
    assert not result.get("failed"), result
    tab = next(t for t in window_of(inst, win["window"])["tabs"] if t["id"] == other["tab"])
    assert tab.get("name") == "from-palette", "the command ran for the focused pane's tab"
    # Choices come from the CLI's description.
    rpc(inst, "debug.palette", window=win["window"], mode="commands", query="tab color")
    result = rpc(inst, "debug.palette.perform", window=win["window"], title="Set Tab Color…", answers=["green"])
    assert next(t for t in window_of(inst, win["window"])["tabs"] if t["id"] == other["tab"]).get("color") == "green"
    # Output is shown in the palette; failures too.
    rpc(inst, "debug.palette", window=win["window"], mode="commands", query="umi pane info")
    result = rpc(inst, "debug.palette.perform", window=win["window"], title="Run umi pane info")
    assert other["id"] in result.get("output", ""), result
    rpc(inst, "debug.palette", window=win["window"], mode="commands", query="umi tab focus no-such-tab")
    result = rpc(inst, "debug.palette.perform", window=win["window"], title="Run umi tab focus no-such-tab")
    assert result.get("failed") and "no-such-tab" in result.get("output", ""), result
    rpc(inst, "debug.palette.close", window=win["window"])


# ---- L-15: panes, most recent first, each with its own title -----------------------------------------

@pytest.mark.req("L-15")
def test_pane_palette_lists_panes_most_recent_first_with_their_own_titles(inst, win):
    inst.cli("tab", "rename", win["tab"], "the-tab-name")
    right = inst.cli("split", "right", "--pane", win["pane"], "--name", "right-pane").stdout.strip()
    right = pane_info(inst, right)["id"]
    elsewhere = new_tab(inst, win)
    inst.cli("pane", "rename", elsewhere["id"], "elsewhere-pane")
    inst.cli("pane", "focus", right)
    inst.cli("pane", "focus", elsewhere["id"])
    inst.cli("pane", "focus", win["pane"])
    wait_until(lambda: inst.tree()["current_pane"] == win["pane"], 5, message="focus settled")
    time.sleep(0.5)
    assert inst.tree()["current_pane"] == win["pane"], "focus stays where it was put last"
    entries = rpc(inst, "debug.palette", window=win["window"], mode="panes")["entries"]
    try:
        ids = [e["value"] for e in entries]
        assert ids[:3] == [win["pane"], elsewhere["id"], right], entries[:3]
        titles = {e["value"]: e["title"] for e in entries}
        assert titles[right] == "right-pane" and titles[elsewhere["id"]] == "elsewhere-pane"
        assert "the-tab-name" not in (titles[win["pane"]], titles[right]), "a pane's own title, not its tab's"
        assert entries[0].get("badge") == "Current"
        result = rpc(inst, "debug.palette.perform", window=win["window"], title="right-pane")
        assert not result["presented"]
        wait_until(lambda: inst.tree()["current_pane"] == right, 5, message="the chosen pane focused")
    finally:
        rpc(inst, "debug.palette.close", window=win["window"])


# ---- L-16: quick file search ----------------------------------------------------------------------

def make_repo(path):
    path.mkdir()
    (path / "src").mkdir()
    (path / "src" / "parser.py").write_text("one\ntwo\nthree\nfour\n")
    (path / "README.md").write_text("# readme\n")
    (path / ".gitignore").write_text("build/\n")
    (path / "build").mkdir()
    (path / "build" / "parser_out.txt").write_text("ignored\n")
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "add", "."], cwd=path, check=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], cwd=path, check=True)
    (path / "src" / "untracked_parser_notes.txt").write_text("new\n")


@pytest.mark.req("L-16")
def test_quick_open_searches_the_focused_panes_repository(inst, win, tmp_path):
    repo = tmp_path / "repo"
    make_repo(repo)
    pane = inst.cli("tab", "new", "--window", win["window"], "--cwd", str(repo)).stdout.strip()
    wait_until(lambda: os.path.realpath(pane_info(inst, pane)["cwd"]) == os.path.realpath(repo), 15, message="cwd")
    inst.cli("pane", "focus", pane)
    time.sleep(0.3)
    try:
        everything = [e["value"] for e in rpc(inst, "debug.palette", window=win["window"], mode="files")["entries"]
                      if e["kind"] == "file"]
        assert {"src/parser.py", "README.md", "src/untracked_parser_notes.txt"} <= set(everything), everything
        assert not any(p.startswith("build/") for p in everything), "ignored files are left out"
        entries = rpc(inst, "debug.palette", window=win["window"], mode="files", query="parser")["entries"]
        files = [e["value"] for e in entries if e["kind"] == "file"]
        assert files[0] == "src/parser.py", files
        assert entries[-1]["title"] == "Browse…", "the Open panel stays reachable"
        # path:line opens the file at that line.
        rpc(inst, "debug.palette", window=win["window"], mode="files", query="parser.py:3")
        result = rpc(inst, "debug.palette.perform", window=win["window"], title="parser.py")
        assert not result["presented"], result
        docs = inst.json("editor", "ls", "--pane", pane)["documents"]
        assert any(d["path"].endswith("src/parser.py") for d in docs), docs
        # Recently opened files come first.
        first = rpc(inst, "debug.palette", window=win["window"], mode="files")["entries"][0]
        assert first["value"] == "src/parser.py", first
    finally:
        rpc(inst, "debug.palette.close", window=win["window"])


# ---- L-17: Settings and the shortcuts editor -----------------------------------------------------

@pytest.mark.req("L-17")
def test_settings_opens_from_the_menu(inst, win):
    rpc(inst, "debug.menu.perform", title="Settings…")
    wait_until(lambda: rpc(inst, "debug.navigation")["settings_visible"], 5, message="the Settings window")


@pytest.mark.req("L-17")
def test_shortcuts_can_be_changed_cleared_and_reset_without_a_restart(inst, win):
    listed = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    assert listed["tab.next"]["kind"] == "umi" and listed["ghostty:new_tab"]["kind"] == "ghostty"
    assert listed["ghostty:new_tab"]["keys"] == ["super+t"]
    try:
        # An Umi item: the menu item takes the new key at once.
        inst.cli("shortcuts", "set", "tab.next", "ctrl+cmd+down")
        item = menu_item(inst, "Show Next Tab")
        assert item["modifiers"] == ["ctrl", "cmd"], item
        assert inst.json("shortcuts")["shortcuts"][0] is not None
        assert {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}["tab.next"]["changed"]
        # Clearing removes it.
        inst.cli("shortcuts", "clear", "tab.back")
        assert menu_item(inst, "Back to Previous Tab")["key"] == ""
        # A Ghostty binding: written to Umi's own file, applied by reloading the config.
        inst.cli("shortcuts", "set", "ghostty:new_tab", "ctrl+cmd+y")
        conf = open(os.path.join(inst.dir, "keybindings.conf")).read()
        assert "keybind = super+t=unbind" in conf and "keybind = ctrl+super+y=new_tab" in conf, conf
        wait_until(lambda: (lambda i: i and i["key"] == "y" and i["modifiers"] == ["ctrl", "cmd"])(menu_item(inst, "New Tab")),
                   5, message="Ghostty's New Tab menu item shows the new key (config reloaded)")
        entry = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}["ghostty:new_tab"]
        assert entry["keys"] == ["ctrl+super+y"], entry
        # Giving an Umi item a key the terminal uses takes the key away from the terminal.
        notes = inst.json("shortcuts", "set", "tab.cycle_next", "cmd+d")["notes"]
        assert any("New split" in n or "new split" in n.lower() for n in notes), notes
        assert "keybind = super+d=unbind" in open(os.path.join(inst.dir, "keybindings.conf")).read()
        bad = inst.cli("shortcuts", "set", "tab.next", "x", check=False)
        assert bad.returncode != 0 and "⌘" in bad.stderr
        assert inst.cli("shortcuts", "set", "no.such", "cmd+y", check=False).returncode != 0
    finally:
        inst.cli("shortcuts", "reset")
    assert menu_item(inst, "Show Next Tab")["modifiers"] == ["shift", "cmd"]
    assert menu_item(inst, "Back to Previous Tab")["key"] == "["
    wait_until(lambda: (lambda i: i and i["key"] == "t" and i["modifiers"] == ["cmd"])(menu_item(inst, "New Tab")), 5,
               message="New Tab back on ⌘T")


# ---- L-18: focus after a close --------------------------------------------------------------------

@pytest.mark.req("L-18")
def test_closing_a_pane_focuses_the_pane_used_before(inst, win):
    a = win["pane"]
    b = pane_info(inst, inst.cli("split", "right", "--pane", a).stdout.strip())["id"]
    c = pane_info(inst, inst.cli("split", "right", "--pane", b).stdout.strip())["id"]
    # Used: c, then a, then c again. Closing c goes back to a, not to its neighbor b.
    inst.cli("pane", "focus", c)
    inst.cli("pane", "focus", a)
    inst.cli("pane", "focus", c)
    time.sleep(0.3)
    inst.cli("pane", "close", c)
    wait_until(lambda: inst.find_pane(c) is None, 5, message="closed")
    tab = inst.find_pane(a)[1]
    assert tab["focused_pane"] == a, f"focus went to {tab['focused_pane']} (a={a}, b={b})"


# ---- S-7: the sidebar order ----------------------------------------------------------------------

def assert_order(inst, window, order, what):
    assert tab_ids(inst, window) == order, f"{what} moved tabs (they were {order})"


@pytest.mark.req("S-7", "L-11", "L-12", "L-20")
def test_selecting_a_tab_never_moves_it(inst, win):
    """Alejo (2026-10-27): "the standard behavior from warp that doesn't switch tab order depending on
    recency". Selecting a tab, by any route, leaves every tab where it is, then and a moment later."""
    a = win["tab"]
    b, c, d = (new_tab(inst, win) for _ in range(3))
    panes = {a: win["pane"], b["tab"]: b["id"], c["tab"]: c["id"], d["tab"]: d["id"]}
    b, c, d = b["tab"], c["tab"], d["tab"]
    order = [a, b, c, d]
    window = win["window"]
    assert_order(inst, window, order, "opening tabs")
    try:
        for target in (a, "#3", d, b):
            inst.cli("tab", "focus", target)
            assert_order(inst, window, order, f"tab focus {target}")
        assert selected(inst, window) == b
        for command in (("tab", "next"), ("tab", "prev"), ("tab", "back"), ("tab", "back")):
            inst.json(*command)
            assert_order(inst, window, order, " ".join(command))
        for title in ("Tab 1", "Tab 3", "Last Tab", "Cycle to Next Tab", "Cycle to Previous Tab", "Show Next Tab",
                      "Back to Previous Tab"):
            rpc(inst, "debug.menu.perform", title=title)
            assert_order(inst, window, order, title)
        rpc(inst, "debug.key", window=window, keys="cmd+shift+]", focus="terminal")
        assert_order(inst, window, order, "⇧⌘] pressed")
        inst.cli("pane", "focus", panes[c])
        assert selected(inst, window) == c
        assert_order(inst, window, order, "pane focus")
        # Going to a session that needs the user (⌃⌘J), and back. Only this test's marks: sessions
        # earlier tests left in the shared instance may have theirs.
        for pane in rpc(inst, "debug.ui.attention")["panes"]:
            rpc(inst, "debug.attention.set", pane=pane, clear=True)
        inst.cli("tab", "focus", a)
        rpc(inst, "debug.attention.set", pane=panes[d], title="d", mark="needs_you", stopped_ago=0)
        assert inst.json("jump")["tab"] == d
        assert_order(inst, window, order, "jump")
        inst.json("jump", "back")
        assert_order(inst, window, order, "jump back")
        # A tab closed and reopened comes back where it was, and selecting it there moves nothing.
        inst.cli("tab", "close", b)
        wait_until(lambda: b not in tab_ids(inst, window), 5, message="closed")
        assert inst.json("reopen")["tab"] == b
        assert_order(inst, window, order, "reopen")
        inst.cli("tab", "focus", b)
        time.sleep(1.5)  # longer than the old order's settle delay: nothing moves later either
        assert_order(inst, window, order, "waiting")
        # `#N` selectors and `ls` follow the order.
        assert inst.json("tab", "focus", "#4")["tab"] == d
    finally:
        rpc(inst, "debug.attention.set", pane=panes[d], clear=True)


@pytest.mark.req("S-7", "S-3")
def test_an_agent_finishing_its_turn_never_moves_its_tab(inst, win):
    """A stop or a question in any tab, the current one or not, leaves the tabs where they are; the
    tab shows its mark. (The fake agents do it for real in test_live.py.)"""
    a = win["tab"]
    b, c, d = (new_tab(inst, win, "--no-focus") for _ in range(3))
    panes = {a: win["pane"], b["tab"]: b["id"], c["tab"]: c["id"], d["tab"]: d["id"]}
    b, c, d = b["tab"], c["tab"], d["tab"]
    order = [a, b, c, d]
    window = win["window"]
    assert_order(inst, window, order, "opening tabs in the background")
    inst.cli("tab", "focus", b)
    try:
        for tab, mark, ago in ((d, "finished", 1), (c, "needs_you", 0), (a, "finished", 0), (b, "finished", 0),
                               (d, "finished", 0)):
            rpc(inst, "debug.attention.set", pane=panes[tab], title=f"agent {tab}", mark=mark, stopped_ago=ago)
            assert_order(inst, window, order, f"a stop in {tab}")
        marks = {r["tab"]: r["mark"] for r in rpc(inst, "debug.ui.rows", window=window)["rows"]}
        assert marks[d] == "finished" and marks[c] == "needs_you", marks
        time.sleep(1.5)
        assert_order(inst, window, order, "waiting after the stops")
        # Then the user looks at them one by one: still nothing moves.
        for tab in (d, c, a):
            inst.cli("tab", "focus", tab)
            assert_order(inst, window, order, f"looking at {tab}")
    finally:
        for pane in panes.values():
            rpc(inst, "debug.attention.set", pane=pane, clear=True)


@pytest.mark.req("S-7", "L-1", "L-2")
def test_new_tabs_open_right_after_the_current_one(inst, win):
    """As in Warp: a new tab the user goes to opens right after the current tab (below the pinned
    tabs); one opened in the background goes last; `--index` puts it where asked."""
    a = win["tab"]
    window = win["window"]
    b = new_tab(inst, win)["tab"]
    c = new_tab(inst, win)["tab"]
    assert tab_ids(inst, window) == [a, b, c]
    inst.cli("tab", "focus", a)
    d = new_tab(inst, win)["tab"]
    assert tab_ids(inst, window) == [a, d, b, c], "right after the current tab, not last"
    e = new_tab(inst, win, "--no-focus")["tab"]
    assert tab_ids(inst, window) == [a, d, b, c, e], "a background tab goes last"
    assert selected(inst, window) == d
    f = new_tab(inst, win, "--index", "2")["tab"]
    assert tab_ids(inst, window) == [a, f, d, b, c, e], "--index is where it goes"
    # With the current tab pinned, a new tab opens at the top of the others.
    inst.cli("tab", "pin", c)
    assert tab_ids(inst, window) == [c, a, f, d, b, e]
    inst.cli("tab", "focus", c)
    g = new_tab(inst, win)["tab"]
    assert tab_ids(inst, window) == [c, g, a, f, d, b, e]
    inst.cli("tab", "unpin", c)


@pytest.mark.req("S-7", "L-2", "L-13", "M-4")
def test_tabs_move_only_when_the_user_moves_them(inst, win):
    """Moves by hand (`tab move`, Move Tab Up/Down, a drop, pinning) put a tab where the user put
    it, and selecting other tabs afterwards leaves it there. Pinned tabs stay first."""
    a = win["tab"]
    window = win["window"]
    b, c, d = (new_tab(inst, win)["tab"] for _ in range(3))
    assert tab_ids(inst, window) == [a, b, c, d]
    inst.cli("tab", "move", d, "--index", "1")
    assert tab_ids(inst, window) == [d, a, b, c] and selected(inst, window) == d
    inst.cli("tab", "move", a, "--down")
    assert tab_ids(inst, window) == [d, b, a, c]
    inst.cli("tab", "focus", c)
    rpc(inst, "debug.menu.perform", title="Move Tab Up")
    assert tab_ids(inst, window) == [d, b, c, a]
    rpc(inst, "debug.ui.drop", window=window, tab=d, row=a, zone="after")
    assert tab_ids(inst, window) == [b, c, a, d]
    for tab in (b, a, c, d):
        inst.cli("tab", "focus", tab)
    assert tab_ids(inst, window) == [b, c, a, d], "selecting moved a tab placed by hand"
    # Pinning puts a tab at the end of the pinned tabs; unpinning, at the top of the others.
    inst.cli("tab", "pin", a)
    inst.cli("tab", "pin", d)
    assert tab_ids(inst, window) == [a, d, b, c]
    inst.cli("tab", "focus", b)
    inst.cli("tab", "focus", d)
    assert tab_ids(inst, window) == [a, d, b, c], "selecting a pinned tab moved it"
    inst.cli("tab", "unpin", a)
    assert tab_ids(inst, window) == [d, a, b, c]
    inst.cli("tab", "unpin", d)
    assert tab_ids(inst, window) == [d, a, b, c]


# ---- With real key presses (accessibility; take over the keyboard) --------------------------------

KEYCODES = {"]": 30, "[": 33, ",": 43, "tab": 48, "return": 36, "esc": 53, "down": 125, "left": 123, "right": 124,
            "p": 35, "o": 31, "j": 38, "k": 40, "1": 18, "2": 19}


def press(ui, key, *mods):
    flags = 0
    for mod in mods:
        flags |= {"cmd": ui.CMD, "shift": ui.SHIFT, "ctrl": ui.CTRL, "option": ui.OPT}[mod]
    ui.key(KEYCODES[key], flags)
    time.sleep(0.4)


@pytest.mark.req("L-10", "L-11")
def test_tab_keys_from_the_editor_the_file_tree_and_the_palette(inst, win, ui, tmp_path):
    """Real ⇧⌘] / ⌃Tab presses change tabs with focus in the editor's source and preview, the
    sidebar's file tree and the palette's query field."""
    second = new_tab(inst, win)
    doc = tmp_path / "keys.md"
    doc.write_text("# keys\n\ntext\n")
    inst.cli("tab", "focus", win["tab"])
    inst.cli("edit", str(doc), "--tab", win["tab"])
    ui.activate()
    for mode in ("source", "preview"):
        inst.cli("editor", "mode", mode, "--tab", win["tab"])
        inst.cli("tab", "focus", win["tab"])
        rpc(inst, "debug.editor.focus", tab=win["tab"])
        press(ui, "]", "cmd", "shift")
        wait_until(lambda: selected(inst, win["window"]) == second["tab"], 5, message=f"⇧⌘] from the editor ({mode})")
    # The palette's query field.
    inst.cli("tab", "focus", win["tab"])
    press(ui, "p", "cmd")
    assert ui.focused_input(5) is not None, "the palette's field has focus"
    press(ui, "tab", "ctrl")
    wait_until(lambda: selected(inst, win["window"]) == second["tab"], 5, message="⌃Tab from the palette")
    press(ui, "esc")
    # The file tree.
    inst.cli("sidebar", "files")
    inst.cli("tab", "focus", win["tab"])
    row = ui.find(lambda e: ui.label(e) == "keys.md")
    if row is not None:
        ui.press(row)
        time.sleep(0.3)
    press(ui, "[", "cmd", "shift")
    wait_until(lambda: selected(inst, win["window"]) != win["tab"], 5, message="⇧⌘[ from the file tree")
    inst.cli("sidebar", "tabs")


@pytest.mark.req("S-7", "M-3")
def test_cmd_t_opens_after_the_current_tab_and_redo_puts_it_back_there(inst, win, ui):
    """⌘T opens a tab right after the current one (S-7); Undo closes it and Redo opens it again in
    the same place (0.6.1 review round 1: redo worked out the place again after Undo had selected the
    next tab, and opened it one further down)."""
    a = win["tab"]
    b = new_tab(inst, win, "--no-focus")["tab"]
    c = new_tab(inst, win, "--no-focus")["tab"]
    inst.cli("tab", "focus", a)
    inst.cli("window", "focus", win["window"])
    ui.activate()
    ui.choose(ui.menu_item("New Tab"))
    wait_until(lambda: len(tab_ids(inst, win["window"])) == 4, 5, message="⌘T made a tab")
    made = tab_ids(inst, win["window"])
    assert made[0] == a and made[2:] == [b, c], f"not right after the current tab: {made}"
    ui.choose(ui.menu_item("Undo"))
    wait_until(lambda: tab_ids(inst, win["window"]) == [a, b, c], 5, message="undo closed it")
    ui.choose(ui.menu_item("Redo"))
    wait_until(lambda: len(tab_ids(inst, win["window"])) == 4, 5, message="redo opened it again")
    again = tab_ids(inst, win["window"])
    assert again[0] == a and again[2:] == [b, c], f"redo put it elsewhere: {again}"


@pytest.mark.req("L-14")
def test_cmd_p_runs_a_cli_command_typed_into_the_palette(inst, win, ui):
    ui.activate()
    inst.cli("pane", "focus", win["pane"])
    press(ui, "p", "cmd")
    field = ui.focused_input(5)
    assert field is not None, "the palette opened with its field focused"
    ui.enter_text("Split Down", field)
    press(ui, "return")
    wait_until(lambda: len(inst.find_pane(win["pane"])[1]["panes"]) == 2, 10, message="the split from the palette")


@pytest.mark.req("L-15")
def test_shift_cmd_p_goes_to_a_pane_by_its_title(inst, win, ui):
    target = new_tab(inst, win)
    inst.cli("pane", "rename", target["id"], "palette-target")
    inst.cli("pane", "focus", win["pane"])
    ui.activate()
    press(ui, "p", "cmd", "shift")
    field = ui.focused_input(5)
    assert field is not None
    ui.enter_text("palette-target", field)
    press(ui, "return")
    wait_until(lambda: inst.tree()["current_pane"] == target["id"], 5, message="the chosen pane focused")


@pytest.mark.req("L-16")
def test_cmd_o_opens_a_file_from_the_repository(inst, win, ui, tmp_path):
    repo = tmp_path / "repo"
    make_repo(repo)
    pane = inst.cli("tab", "new", "--window", win["window"], "--cwd", str(repo)).stdout.strip()
    wait_until(lambda: os.path.realpath(pane_info(inst, pane)["cwd"]) == os.path.realpath(repo), 15, message="cwd")
    inst.cli("pane", "focus", pane)
    ui.activate()
    press(ui, "o", "cmd")
    field = ui.focused_input(5)
    assert field is not None
    ui.enter_text("parser.py:2", field)
    time.sleep(0.5)
    press(ui, "return")
    wait_until(lambda: any(d["path"].endswith("src/parser.py") for d in inst.json("editor", "ls", "--pane", pane)["documents"]),
               5, message="the file open in the editor")


@pytest.mark.req("L-17")
def test_cmd_comma_opens_settings_where_a_shortcut_is_recorded(inst, win, ui):
    ui.activate()
    press(ui, ",", "cmd")
    wait_until(lambda: rpc(inst, "debug.navigation")["settings_visible"], 5, message="Settings")
    button = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Shortcut for Show Next Tab"), 10,
                        message="the Show Next Tab row")
    try:
        ui.press(button)
        time.sleep(0.3)
        press(ui, "down", "ctrl", "cmd")
        wait_until(lambda: {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}["tab.next"]["keys"] == ["ctrl+cmd+down"],
                   5, message="the recorded shortcut")
        item = menu_item(inst, "Show Next Tab")
        assert item["modifiers"] == ["ctrl", "cmd"]
    finally:
        inst.cli("shortcuts", "reset")


@pytest.mark.req("L-12", "L-13")
def test_jump_and_move_tab_keys(inst, win, ui):
    waiting = new_tab(inst, win, "--no-focus")
    rpc(inst, "debug.attention.set", pane=waiting["id"], title="worker", mark="needs_you", stopped_ago=5)
    try:
        inst.cli("pane", "focus", win["pane"])
        ui.activate()
        press(ui, "j", "ctrl", "cmd")
        wait_until(lambda: inst.tree()["current_pane"] == waiting["id"], 5, message="⌃⌘J")
        press(ui, "k", "ctrl", "cmd")
        wait_until(lambda: inst.tree()["current_pane"] == win["pane"], 5, message="⌃⌘K back")
    finally:
        rpc(inst, "debug.attention.set", pane=waiting["id"], clear=True)
    order = tab_ids(inst, win["window"])
    index = order.index(win["tab"])
    press(ui, "right", "ctrl", "shift")
    assert tab_ids(inst, win["window"]).index(win["tab"]) == index + 1, "⌃⇧→ moved the tab down"
    press(ui, "left", "ctrl", "shift")
    assert tab_ids(inst, win["window"]).index(win["tab"]) == index
