"""The sidebar as Warp's vertical tabs panel (Warp parity, 2026-11-05): S-2 (shown or hidden per
window, ⌘B and ⌘\\), S-3 (the failed-command triangle, the Maximized indicator, ⌘1–⌘9 while ⌘ is
held), S-4 (Warp's row menu: labels, order, hidden items, pull request link, color dots, renames
in the row), S-13 (search tabs: ⌥⌘F, Esc, cycling through the matches).

What needs the screen is driven with real key presses in the `ui` tests; the rest goes through the
CLI and Umi's internal `debug.ui.*` methods, which run the code the sidebar runs.
"""

import os
import subprocess
import time
import uuid

import pytest

from harness import wait_until

pytestmark = pytest.mark.layout


# ---- helpers ------------------------------------------------------------------------------------

def rows(inst, window):
    return inst.rpc("debug.ui.rows", window=window)["rows"]


def row(inst, window, tab):
    return next(r for r in rows(inst, window) if r["tab"] == tab)


def sidebar(inst, window, **params):
    return inst.rpc("debug.ui.sidebar", window=window, **params)


def window_of(inst, window_id):
    return next(w for w in inst.tree()["windows"] if w["id"] == window_id)


def tab_ids(inst, window):
    return [t["id"] for t in window_of(inst, window)["tabs"]]


def tab_of(inst, tab_id):
    for w in inst.tree()["windows"]:
        for t in w["tabs"]:
            if t["id"] == tab_id:
                return t
    return None


def selected(inst, window):
    return next(t["id"] for t in window_of(inst, window)["tabs"] if t["selected"])


def new_tab(inst, win, *extra):
    pane = inst.cli("tab", "new", "--window", win["window"], "--no-focus", *extra).stdout.strip()
    return pane, inst.json("pane", "info", pane)["tab"]


def ready(inst, *panes):
    for pane in panes:
        wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="prompt")
    time.sleep(0.3)


def run(inst, pane, command, marker):
    inst.cli("send", "--pane", pane, "-e", command)
    inst.cli("wait", "--pane", pane, "--pattern", marker, "--timeout", "15")


def menu(inst, tab):
    return inst.rpc("debug.ui.menu", tab=tab)["items"]


def titles(inst, tab):
    """The menu's top-level titles in order."""
    return [i["title"] for i in menu(inst, tab) if " > " not in i["path"]]


def perform(inst, tab, title):
    return inst.rpc("debug.ui.menu.perform", tab=tab, title=title)


def git_repo(path, branch):
    path.mkdir()
    subprocess.run(["git", "init", "-q", "-b", branch, str(path)], check=True)
    return path


# ---- S-2: shown or hidden per window, at once ----------------------------------------------------

@pytest.mark.req("S-2")
def test_each_window_shows_or_hides_its_own_sidebar(inst, win):
    other = inst.json("window", "new")["window"]
    inst.cli("sidebar", "off", "--window", win["window"])
    assert inst.json("sidebar", "status", "--window", win["window"])["visible"] is False
    assert inst.json("sidebar", "status", "--window", other)["visible"] is True, "the other window keeps its sidebar"
    assert sidebar(inst, win["window"])["visible"] is False
    # A new window starts as the window last toggled.
    third = inst.json("window", "new")["window"]
    assert inst.json("sidebar", "status", "--window", third)["visible"] is False
    inst.cli("sidebar", "toggle", "--window", win["window"])
    assert inst.json("sidebar", "status", "--window", win["window"])["visible"] is True
    assert inst.json("sidebar", "status", "--window", third)["visible"] is False
    inst.cli("sidebar", "on", "--window", third)


@pytest.mark.req("S-8")
def test_the_default_width_is_warps(fresh):
    other = fresh(prefix="acc-width-")
    created = other.json("window", "new")
    assert other.json("sidebar", "status", "--window", created["window"])["width"] == 248


# ---- S-3: what rows show besides their two lines --------------------------------------------------

@pytest.mark.req("S-3")
def test_a_failed_last_command_marks_the_row(inst, win):
    pane, tab = new_tab(inst, win)
    ready(inst, pane)
    assert row(inst, win["window"], tab)["failed"] is False
    inst.cli("send", "--pane", pane, "-e", "false")
    wait_until(lambda: row(inst, win["window"], tab)["failed"], 10, message="the triangle for a failed command")
    inst.cli("send", "--pane", pane, "-e", "true")
    wait_until(lambda: not row(inst, win["window"], tab)["failed"], 10, message="a command that succeeds clears it")
    # ⌃C (130) and SIGPIPE (141) aren't failures, as in Warp.
    for code in (130, 141):
        inst.cli("send", "--pane", pane, "-e", f"sh -c 'exit {code}'")
        time.sleep(1.5)
        assert not row(inst, win["window"], tab)["failed"], f"exit {code} counts as a failure"


@pytest.mark.req("S-3")
def test_a_zoomed_pane_shows_maximized_on_its_row(inst, win):
    pane, tab = new_tab(inst, win)
    second = inst.cli("split", "right", "--pane", pane, "--no-focus").stdout.strip()
    assert row(inst, win["window"], tab)["maximized"] is False
    inst.cli("pane", "zoom", second)
    wait_until(lambda: row(inst, win["window"], tab)["maximized"], 5, message="Maximized")
    inst.cli("pane", "zoom", second)
    wait_until(lambda: not row(inst, win["window"], tab)["maximized"], 5, message="no longer Maximized")


@pytest.mark.req("S-3")
def test_holding_cmd_shows_the_tab_keys(inst, win):
    for _ in range(9):
        new_tab(inst, win)
    ids = tab_ids(inst, win["window"])
    assert len(ids) == 10
    try:
        assert not any("hint" in r for r in rows(inst, win["window"])), "no hints until ⌘ is held"
        sidebar(inst, win["window"], command_held=True)
        hints = {r["tab"]: r.get("hint") for r in rows(inst, win["window"])}
        assert [hints[t] for t in ids[:8]] == [f"⌘{n}" for n in range(1, 9)]
        assert hints[ids[8]] is None, "the ninth of ten tabs has no key"
        assert hints[ids[9]] == "⌘9", "⌘9 is the last tab"
    finally:
        sidebar(inst, win["window"], command_held=False)
    assert not any("hint" in r for r in rows(inst, win["window"]))


# ---- S-13: search tabs ---------------------------------------------------------------------------

@pytest.mark.req("S-13")
def test_search_matches_title_folder_branch_command_and_agent_title(inst, win, tmp_path):
    folder = tmp_path / "srch-folder-q1"
    folder.mkdir()
    _, by_folder = new_tab(inst, win, "--cwd", str(folder))
    repo = git_repo(tmp_path / "plainrepo", "feature-q2")
    _, by_branch = new_tab(inst, win, "--cwd", str(repo))
    cmd_pane, by_command = new_tab(inst, win)
    agent_pane, by_agent = new_tab(inst, win)
    _, by_name = new_tab(inst, win, "--name", "named-q5")
    ready(inst, cmd_pane)
    marker = "q3" + uuid.uuid4().hex[:4]
    run(inst, cmd_pane, f"echo needle-{marker}", f"^needle-{marker}")
    inst.rpc("debug.ui.attention.set", pane=agent_pane, kind="claude", title="Agent needle-q4", status="idle")
    try:
        cases = {"FOLDER-Q1": by_folder, "feature-q2": by_branch, marker: by_command, "needle-q4": by_agent,
                 "named-q5": by_name}
        for query, tab in cases.items():
            wait_until(lambda: sidebar(inst, win["window"], query=query)["matching"] == [tab], 10,
                       message=f"only the tab matching {query!r}")
            shown = {r["tab"]: r["shown"] for r in rows(inst, win["window"])}
            assert [t for t, s in shown.items() if s] == [tab], "the sidebar lists only the match"
        assert sidebar(inst, win["window"], query="zz-no-such-tab")["matching"] == []
        assert len(sidebar(inst, win["window"], query="")["matching"]) == len(tab_ids(inst, win["window"]))
    finally:
        sidebar(inst, win["window"], query="")
        inst.rpc("debug.ui.attention.clear", pane=agent_pane)


# ---- S-4: Warp's row menu ------------------------------------------------------------------------

@pytest.mark.req("S-4")
def test_the_row_menu_has_warps_labels_in_warps_order(inst, win, tmp_path):
    repo = git_repo(tmp_path / "menuorder", "order-branch")
    pane, tab = new_tab(inst, win, "--cwd", str(repo))
    _, below = new_tab(inst, win)
    inst.cli("tab", "rename", tab, "named")
    inst.cli("pane", "rename", pane, "pane-named")
    wait_until(lambda: "Copy branch" in titles(inst, tab), 10, message="Copy branch")
    expected = ["Pin tab",
                "New group with tab",
                "Copy branch", "Copy tab title", "Copy working directory",
                "Rename tab", "Reset tab name", "Rename active pane", "Reset active pane name",
                "Move Tab Down", "Move Tab Up",
                "Close tab", "Close other tabs", "Close Tabs Below",
                "Tab Color",
                "Move Tab to New Window"]
    # "Move Tab to Window" follows when the instance has other windows.
    assert [t for t in titles(inst, tab) if t != "Move Tab to Window"] == expected
    # Items that can't apply are left out, as in Warp.
    last = titles(inst, below)
    assert "Move Tab Down" not in last and "Close Tabs Below" not in last and "Move Tab Up" in last
    assert "Reset tab name" not in last and "Reset active pane name" not in last
    first = titles(inst, win["tab"])
    assert "Move Tab Up" not in first and "Move Tab Down" in first
    assert "Copy pull request link" not in titles(inst, tab), "no pull request for a branch without one"


@pytest.mark.req("S-4")
def test_the_copy_items_and_color_dots(inst, win, tmp_path):
    repo = git_repo(tmp_path / "menucopy", "copy-branch")
    _, tab = new_tab(inst, win, "--cwd", str(repo))
    inst.cli("tab", "rename", tab, "copied-title")
    wait_until(lambda: "Copy branch" in titles(inst, tab), 10, message="Copy branch")
    assert perform(inst, tab, "Copy branch")["copied"] == "copy-branch"
    assert perform(inst, tab, "Copy tab title")["copied"] == "copied-title"
    assert os.path.realpath(perform(inst, tab, "Copy working directory")["copied"]) == os.path.realpath(repo)
    dots = [i for i in menu(inst, tab) if i["path"].startswith("Tab Color > ")]
    assert [d["title"] for d in dots] == ["Default (no color)", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan"]
    assert [d["checked"] for d in dots] == [True] + [False] * 6
    perform(inst, tab, "Tab Color > Magenta")
    assert tab_of(inst, tab)["color"] == "magenta"
    assert [d["checked"] for d in menu(inst, tab) if d["path"].startswith("Tab Color > ")][5]
    # Picking the tab's color again clears it, as Warp's toggle does; so does Default.
    perform(inst, tab, "Tab Color > Magenta")
    assert not tab_of(inst, tab).get("color")
    perform(inst, tab, "Tab Color > Cyan")
    assert tab_of(inst, tab)["color"] == "cyan"
    perform(inst, tab, "Tab Color > Default (no color)")
    assert not tab_of(inst, tab).get("color")
    inst.cli("tab", "color", tab, "cyan")
    assert tab_of(inst, tab)["color"] == "cyan", "the CLI knows Warp's colors too"


@pytest.mark.req("S-4")
def test_copy_pull_request_link_asks_gh_for_the_branch(fresh, tmp_path):
    gh = tmp_path / "fake-gh"
    gh.write_text("#!/bin/sh\n"
                  "if [ \"$1 $2 $3\" = \"pr view pr-branch\" ]; then echo https://github.com/o/r/pull/7; exit 0; fi\n"
                  "exit 1\n")
    gh.chmod(0o755)
    other = fresh(prefix="acc-gh-", env={"UMI_GH_BIN": str(gh)})
    created = other.json("window", "new")
    with_pr = git_repo(tmp_path / "withpr", "pr-branch")
    without = git_repo(tmp_path / "withoutpr", "no-pr-branch")
    pane = other.cli("tab", "new", "--window", created["window"], "--cwd", str(with_pr)).stdout.strip()
    tab = other.json("pane", "info", pane)["tab"]
    pane2 = other.cli("tab", "new", "--window", created["window"], "--cwd", str(without)).stdout.strip()
    tab2 = other.json("pane", "info", pane2)["tab"]
    wait_until(lambda: "Copy pull request link" in titles(other, tab), 15, message="the PR item")
    order = titles(other, tab)
    assert order.index("Copy working directory") + 1 == order.index("Copy pull request link")
    assert perform(other, tab, "Copy pull request link")["copied"] == "https://github.com/o/r/pull/7"
    wait_until(lambda: "Copy branch" in titles(other, tab2), 10, message="the other tab's branch")
    time.sleep(2)
    assert "Copy pull request link" not in titles(other, tab2), "hidden when the branch has no PR"


@pytest.mark.req("S-4")
def test_renames_from_the_menu_happen_in_the_row(inst, win):
    pane, tab = new_tab(inst, win)
    perform(inst, tab, "Rename tab")
    state = sidebar(inst, win["window"])
    assert state["renaming"] == {"tab": tab} and state["visible"] is True
    sidebar(inst, win["window"], rename_text="  in-row  ")
    assert tab_of(inst, tab)["name"] == "in-row"
    assert "renaming" not in sidebar(inst, win["window"])
    perform(inst, tab, "Rename active pane")
    assert sidebar(inst, win["window"])["renaming"] == {"tab": tab, "pane": pane}
    sidebar(inst, win["window"], rename_text="pane-in-row")
    assert inst.json("pane", "info", pane)["name"] == "pane-in-row"
    perform(inst, tab, "Reset active pane name")
    assert not inst.json("pane", "info", pane).get("name")
    perform(inst, tab, "Reset tab name")
    assert not tab_of(inst, tab).get("name")
    # A hidden sidebar comes back for the rename.
    inst.cli("sidebar", "off", "--window", win["window"])
    perform(inst, tab, "Rename tab")
    assert sidebar(inst, win["window"])["visible"] is True
    sidebar(inst, win["window"], rename_cancel=True)


# ---- S-14: tab groups ----------------------------------------------------------------------------

def groups(inst, window, **params):
    return inst.rpc("debug.ui.groups", window=window, **params)


def group_perform(inst, window, group, title):
    return inst.rpc("debug.ui.group.perform", window=window, group=group, title=title)


@pytest.mark.req("S-14", "S-4")
def test_new_group_with_tab_names_it_in_place_and_keeps_its_tabs_together(inst, win):
    _, t2 = new_tab(inst, win)
    _, t3 = new_tab(inst, win)
    _, t4 = new_tab(inst, win)
    t1 = win["tab"]
    perform(inst, t2, "New group with tab")
    state = groups(inst, win["window"])
    assert len(state["groups"]) == 1
    group = state["groups"][0]
    assert group["name"] == "New Group" and group["tabs"] == [t2]
    assert sidebar(inst, win["window"])["renaming"] == {"group": group["id"]}, "named in place right away"
    sidebar(inst, win["window"], rename_text="Backend")
    assert groups(inst, win["window"])["groups"][0]["name"] == "Backend"
    assert tab_of(inst, t2)["group"] == "Backend", "ls says which group a tab is in"
    # Move to group: the tab joins the end of the group, next to its other tabs.
    perform(inst, t4, "Move to group > Backend")
    assert tab_ids(inst, win["window"]) == [t1, t2, t4, t3]
    assert groups(inst, win["window"])["entries"] == [t1, "group:" + group["id"], "  " + t2, "  " + t4, t3]
    assert row(inst, win["window"], t4)["group"] == "Backend"
    # The row menu's group items, as Warp's.
    assert "Remove from group" in titles(inst, t4) and "New group with tab" in titles(inst, t4)
    assert "Move to group" not in titles(inst, t4), "no other group to move to"
    assert "Remove from group" not in titles(inst, t3)
    # Moving a member away from the others brings it back next to them.
    inst.cli("tab", "move", t2, "--index", "4")
    wait_until(lambda: groups(inst, win["window"])["groups"][0]["tabs"] in ([t4, t2], [t2, t4]) and
               abs(tab_ids(inst, win["window"]).index(t2) - tab_ids(inst, win["window"]).index(t4)) == 1, 5,
               message="the group's tabs together again")
    # Remove from group: the tab goes right after the group.
    perform(inst, t2, "Remove from group")
    assert groups(inst, win["window"])["groups"][0]["tabs"] == [t4]
    assert "New group with tab" not in titles(inst, t4), "the only tab of its group"
    # Pinning takes a tab out of its group.
    inst.cli("tab", "pin", t4)
    wait_until(lambda: groups(inst, win["window"])["groups"] == [], 5, message="the empty group went")
    inst.cli("tab", "unpin", t4)


@pytest.mark.req("S-14")
def test_a_collapsed_group_hides_its_tabs(inst, win):
    _, t2 = new_tab(inst, win)
    _, t3 = new_tab(inst, win)
    perform(inst, t2, "New group with tab")
    sidebar(inst, win["window"], rename_text="Folded")
    perform(inst, t3, "Move to group > Folded")
    gid = groups(inst, win["window"])["groups"][0]["id"]
    groups(inst, win["window"], toggle=gid)
    state = groups(inst, win["window"])
    assert state["groups"][0]["collapsed"] is True
    assert state["entries"] == [win["tab"], "group:" + gid]
    assert not row(inst, win["window"], t2)["shown"] and not row(inst, win["window"], t3)["shown"]
    # A search shows the matches inside; the group's name matches all its tabs.
    assert sidebar(inst, win["window"], query="folded")["matching"] == [t2, t3]
    sidebar(inst, win["window"], query="")
    # Renaming a hidden tab opens its group.
    perform(inst, t3, "Rename tab")
    assert groups(inst, win["window"])["groups"][0]["collapsed"] is False
    sidebar(inst, win["window"], rename_cancel=True)


@pytest.mark.req("S-14")
def test_the_group_header_menu(inst, win):
    _, t2 = new_tab(inst, win)
    _, t3 = new_tab(inst, win)
    perform(inst, t2, "New group with tab")
    sidebar(inst, win["window"], rename_text="Menu group")
    gid = groups(inst, win["window"])["groups"][0]["id"]
    items = [i["title"] for i in inst.rpc("debug.ui.group.menu", window=win["window"], group=gid)["items"]
             if " > " not in i["path"]]
    assert items == ["Ungroup tabs", "New tab in group", "Rename", "Close all tabs in group", "Close other tabs",
                     "Tab Color"]
    group_perform(inst, win["window"], gid, "Tab Color > Green")
    assert groups(inst, win["window"])["groups"][0]["color"] == "green"
    group_perform(inst, win["window"], gid, "New tab in group")
    members = groups(inst, win["window"])["groups"][0]["tabs"]
    assert len(members) == 2 and members[0] == t2 and selected(inst, win["window"]) == members[1]
    assert tab_ids(inst, win["window"]).index(members[1]) == tab_ids(inst, win["window"]).index(t2) + 1
    group_perform(inst, win["window"], gid, "Rename")
    assert sidebar(inst, win["window"])["renaming"] == {"group": gid}
    sidebar(inst, win["window"], rename_text="")
    assert groups(inst, win["window"])["groups"][0]["name"] == "New Group", "an empty name goes back to the default"
    group_perform(inst, win["window"], gid, "Ungroup tabs")
    assert groups(inst, win["window"])["groups"] == []
    assert not tab_of(inst, t2).get("group")
    assert t3 in tab_ids(inst, win["window"])


@pytest.mark.req("S-14", "L-13")
def test_moving_a_tab_up_or_down_keeps_groups_whole(inst, win):
    """As Warp's can_move_tab and move_tab: a grouped tab moves only within its group, and an
    ungrouped tab next to a group hops over the whole group in one step (one undo step)."""
    t1 = win["tab"]
    _, t2 = new_tab(inst, win)
    _, t3 = new_tab(inst, win)
    _, t4 = new_tab(inst, win)
    perform(inst, t2, "New group with tab")
    sidebar(inst, win["window"], rename_text="Fence")
    perform(inst, t3, "Move to group > Fence")
    order = lambda: tab_ids(inst, win["window"])  # noqa: E731
    assert order() == [t1, t2, t3, t4]
    # A group's last tab can't leave it downwards, its first can't leave it upwards.
    assert "Move Tab Down" not in titles(inst, t3) and "Move Tab Up" in titles(inst, t3)
    assert "Move Tab Up" not in titles(inst, t2) and "Move Tab Down" in titles(inst, t2)
    assert inst.cli("tab", "move", t3, "--down", "--no-focus", check=False).returncode != 0
    # The tabs around the group hop over all of it.
    assert "Move Tab Up" in titles(inst, t4) and "Move Tab Down" in titles(inst, t1)
    perform(inst, t4, "Move Tab Up")
    assert order() == [t1, t4, t2, t3]
    assert inst.rpc("debug.undo")["undo"] == "Move Tab Up"
    time.sleep(0.5)
    assert order() == [t1, t4, t2, t3], "the group's normalizing didn't move anything back"
    assert [g["tabs"] for g in groups(inst, win["window"])["groups"]] == [[t2, t3]]
    perform(inst, t4, "Move Tab Down")
    assert order() == [t1, t2, t3, t4]
    inst.cli("tab", "move", t1, "--down", "--no-focus")
    assert order() == [t2, t3, t1, t4]
    inst.rpc("debug.menu.perform", title="Undo")
    wait_until(lambda: order() == [t1, t2, t3, t4], 5, message="undo put the tab back above the group")
    # Inside the group: an ordinary swap that stays.
    perform(inst, t2, "Move Tab Down")
    time.sleep(0.5)
    assert order() == [t1, t3, t2, t4]
    assert groups(inst, win["window"])["groups"][0]["tabs"] == [t3, t2]


@pytest.mark.req("S-14", "M-3", "L-20")
def test_undo_and_reopen_bring_a_tab_back_into_its_group(inst, win):
    """A grouped tab taken out of its window (moved to a new window, closed) leaves its group, and
    the group goes when it was the last tab. Undo and reopen bring the tab back into that group."""
    p2, t2 = new_tab(inst, win)
    ready(inst, p2)
    perform(inst, t2, "New group with tab")
    sidebar(inst, win["window"], rename_text="Kept group")
    gid = groups(inst, win["window"])["groups"][0]["id"]
    expected = [(gid, "Kept group", [t2])]

    def state():
        return [(g["id"], g["name"], g["tabs"]) for g in groups(inst, win["window"])["groups"]]

    perform(inst, t2, "Move Tab to New Window")
    wait_until(lambda: state() == [], 5, message="the group went with its only tab")
    assert inst.rpc("debug.undo")["undo"] == "Move Tab"
    inst.rpc("debug.menu.perform", title="Undo")
    wait_until(lambda: t2 in tab_ids(inst, win["window"]), 5, message="undo brought the tab back")
    wait_until(lambda: state() == expected, 5, message="undo of the move brought the group back")
    assert tab_of(inst, t2)["group"] == "Kept group"

    inst.cli("tab", "close", t2)
    wait_until(lambda: state() == [], 5, message="the group went with its closed tab")
    inst.rpc("debug.menu.perform", title="Undo")
    wait_until(lambda: t2 in tab_ids(inst, win["window"]), 5, message="undo reopened the tab")
    wait_until(lambda: state() == expected, 5, message="undo of the close brought the group back")

    group_perform(inst, win["window"], gid, "Close all tabs in group")
    wait_until(lambda: t2 not in tab_ids(inst, win["window"]) and state() == [], 5, message="closed with its group")
    assert inst.json("reopen")["tab"] == t2
    wait_until(lambda: state() == expected, 5, message="reopen brought the group back")


@pytest.mark.req("S-14", "R-3")
def test_groups_are_restored_with_the_layout(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-groups-", restore=True)
    created = other.json("window", "new", "--name", "grouped")
    pane = other.cli("tab", "new", "--window", created["window"]).stdout.strip()
    tab = other.json("pane", "info", pane)["tab"]
    other.rpc("debug.ui.menu.perform", tab=tab, title="New group with tab")
    other.rpc("debug.ui.sidebar", window=created["window"], rename_text="Kept")
    gid = other.rpc("debug.ui.groups", window=created["window"])["groups"][0]["id"]
    other.rpc("debug.ui.groups", window=created["window"], toggle=gid)
    time.sleep(0.6)
    other.quit_app()
    other.start_app()
    restored = [w for w in other.tree()["windows"] if any(t["id"] == tab for t in w["tabs"])]
    assert restored, "the grouped tab came back"
    state = other.rpc("debug.ui.groups", window=restored[0]["id"])
    assert [(g["name"], g["collapsed"], g["tabs"]) for g in state["groups"]] == [("Kept", True, [tab])]


# ---- With real key presses (accessibility) --------------------------------------------------------

KEYCODES = {"]": 30, "[": 33, "\\": 42, "b": 11, "f": 3, "r": 15, "tab": 48, "return": 36, "esc": 53}


def press(ui, key, *mods):
    flags = 0
    for mod in mods:
        flags |= {"cmd": ui.CMD, "shift": ui.SHIFT, "ctrl": ui.CTRL, "option": ui.OPT}[mod]
    ui.key(KEYCODES[key], flags)
    time.sleep(0.4)


def front(inst, win, ui, pane=None):
    inst.cli("window", "focus", win["window"])
    if pane:
        inst.cli("pane", "focus", pane)
    ui.activate()
    time.sleep(0.3)


@pytest.mark.req("S-2")
def test_cmd_b_and_cmd_backslash_toggle_the_front_windows_sidebar_ui(inst, win, ui):
    other = inst.json("window", "new")["window"]
    front(inst, win, ui, win["pane"])
    for key in ("b", "\\"):
        assert inst.json("sidebar", "status", "--window", win["window"])["visible"] is True
        press(ui, key, "cmd")
        wait_until(lambda: inst.json("sidebar", "status", "--window", win["window"])["visible"] is False, 5,
                   message=f"⌘{key} hid the sidebar")
        assert inst.json("sidebar", "status", "--window", other)["visible"] is True, "only the front window's"
        press(ui, key, "cmd")
        wait_until(lambda: inst.json("sidebar", "status", "--window", win["window"])["visible"] is True, 5,
                   message=f"⌘{key} showed it again")
    assert ui.shortcut("cmd+\\") is not None, "⌘\\ is a menu item"


@pytest.mark.req("S-13")
def test_search_field_keys_ui(inst, win, ui, tmp_path):
    """⌥⌘F puts the cursor in "Search tabs..."; with a query ⌃Tab, ⇧⌘] and ⇧⌘[ go through the
    matching tabs only; Esc clears the query and gives the keyboard back to the pane."""
    _, a = new_tab(inst, win, "--name", "keysearch-a")
    _, skip = new_tab(inst, win, "--name", "unrelated")
    _, b = new_tab(inst, win, "--name", "keysearch-b")
    _, c = new_tab(inst, win, "--name", "keysearch-c")
    front(inst, win, ui, win["pane"])
    press(ui, "f", "cmd", "option")
    field = ui.focused_input(5)
    assert field is not None, "⌥⌘F focused a text field"
    wait_until(lambda: sidebar(inst, win["window"])["search_focused"], 5, message="the search field has focus")
    ui.enter_text("keysearch", field)
    wait_until(lambda: sidebar(inst, win["window"])["matching"] == [a, b, c], 5, message="the query took")
    press(ui, "tab", "ctrl")
    wait_until(lambda: selected(inst, win["window"]) == a, 5, message="⌃Tab to the first match")
    press(ui, "]", "cmd", "shift")
    wait_until(lambda: selected(inst, win["window"]) == b, 5, message="⇧⌘] skips the tab that doesn't match")
    press(ui, "tab", "ctrl")
    wait_until(lambda: selected(inst, win["window"]) == c, 5, message="⌃Tab to the next match")
    press(ui, "tab", "ctrl")
    wait_until(lambda: selected(inst, win["window"]) == a, 5, message="wraps to the first match")
    press(ui, "[", "cmd", "shift")
    wait_until(lambda: selected(inst, win["window"]) == c, 5, message="⇧⌘[ to the previous match")
    assert skip not in [selected(inst, win["window"])]
    # Esc in the field: the query goes and the pane has the keyboard again.
    press(ui, "f", "cmd", "option")
    wait_until(lambda: sidebar(inst, win["window"])["search_focused"], 5, message="focused again")
    press(ui, "esc")
    wait_until(lambda: sidebar(inst, win["window"])["query"] == "", 5, message="Esc cleared the query")
    wait_until(lambda: not sidebar(inst, win["window"])["search_focused"], 5, message="the field let go")
    # Without a query, ⇧⌘] is the next tab in order again.
    inst.cli("tab", "focus", a)
    press(ui, "]", "cmd", "shift")
    wait_until(lambda: selected(inst, win["window"]) == skip, 5, message="⇧⌘] to the next tab in order")


@pytest.mark.req("S-13")
def test_search_from_a_hidden_sidebar_or_files_mode_ui(inst, win, ui):
    """⌥⌘F shows a hidden sidebar in Tabs mode with the cursor in "Search tabs..."; Esc gives the
    keyboard back to the pane that had it. In Files mode the query (which can't be seen there)
    doesn't filter ⌃Tab; back in Tabs mode it does again."""
    _, a = new_tab(inst, win, "--name", "modesearch-a")
    _, skip = new_tab(inst, win, "--name", "unrelated-m")
    _, b = new_tab(inst, win, "--name", "modesearch-b")
    front(inst, win, ui, win["pane"])
    try:
        inst.cli("sidebar", "files", "--window", win["window"])
        inst.cli("sidebar", "off", "--window", win["window"])
        wait_until(lambda: sidebar(inst, win["window"])["key_pane"] == win["pane"], 5, message="the pane has the keys")
        press(ui, "f", "cmd", "option")
        wait_until(lambda: sidebar(inst, win["window"])["search_focused"], 5, message="⌥⌘F focused the field")
        status = inst.json("sidebar", "status", "--window", win["window"])
        assert status["visible"] is True and status["mode"] == "tabs", status
        field = ui.focused_input(5)
        assert field is not None, "the cursor is in the field"
        ui.enter_text("modesearch", field)
        wait_until(lambda: sidebar(inst, win["window"])["matching"] == [a, b], 5, message="the query took")
        press(ui, "esc")
        wait_until(lambda: not sidebar(inst, win["window"])["search_focused"], 5, message="the field let go")
        wait_until(lambda: sidebar(inst, win["window"])["key_pane"] == win["pane"], 5,
                   message="Esc gave the keyboard back to the pane that had it")
        assert sidebar(inst, win["window"])["query"] == ""

        # A query left in the field while the sidebar shows Files doesn't filter ⌃Tab.
        sidebar(inst, win["window"], query="modesearch")
        inst.cli("tab", "focus", a)
        inst.cli("sidebar", "files", "--window", win["window"])
        front(inst, win, ui)
        press(ui, "tab", "ctrl")
        wait_until(lambda: selected(inst, win["window"]) == skip, 5, message="⌃Tab to the next tab in order")
        inst.cli("sidebar", "tabs", "--window", win["window"])
        inst.cli("tab", "focus", a)
        front(inst, win, ui)
        press(ui, "tab", "ctrl")
        wait_until(lambda: selected(inst, win["window"]) == b, 5, message="⌃Tab to the next match in Tabs mode")
    finally:
        sidebar(inst, win["window"], query="")
        inst.cli("sidebar", "tabs", "--window", win["window"])
        inst.cli("sidebar", "on", "--window", win["window"])


@pytest.mark.req("S-13")
def test_no_match_says_so_ui(inst, win, ui):
    front(inst, win, ui, win["pane"])
    try:
        sidebar(inst, win["window"], query="zz-nothing-matches")
        wait_until(lambda: "No tabs match your search." in ui.texts(), 5, message="the empty-state text")
    finally:
        sidebar(inst, win["window"], query="")


@pytest.mark.req("S-4")
def test_rename_keys_edit_in_the_row_ui(inst, win, ui):
    front(inst, win, ui, win["pane"])
    press(ui, "r", "cmd", "ctrl")
    wait_until(lambda: sidebar(inst, win["window"]).get("renaming") == {"tab": win["tab"]}, 5,
               message="⌃⌘R renames the tab in its row")
    field = ui.focused_input(5)
    assert field is not None, "the row's field has the cursor"
    ui.enter_text("typed-in-row", field, replace=True)
    press(ui, "return")
    wait_until(lambda: tab_of(inst, win["tab"]).get("name") == "typed-in-row", 5, message="Return named the tab")
    # Esc leaves the name as it was.
    press(ui, "r", "cmd", "ctrl")
    field = ui.focused_input(5)
    ui.enter_text("discarded", field, replace=True)
    press(ui, "esc")
    wait_until(lambda: "renaming" not in sidebar(inst, win["window"]), 5, message="Esc ended the rename")
    assert tab_of(inst, win["tab"]).get("name") == "typed-in-row"
    # ⌃⇧⌘R: the focused pane, in its tab's row.
    press(ui, "r", "cmd", "ctrl", "shift")
    wait_until(lambda: sidebar(inst, win["window"]).get("renaming") == {"tab": win["tab"], "pane": win["pane"]}, 5,
               message="⌃⇧⌘R renames the pane in the row")
    field = ui.focused_input(5)
    ui.enter_text("pane-typed", field, replace=True)
    press(ui, "return")
    wait_until(lambda: inst.json("pane", "info", win["pane"]).get("name") == "pane-typed", 5, message="the pane's name")
    inst.cli("tab", "rename", win["tab"], "")
    inst.cli("pane", "rename", win["pane"], "")


@pytest.mark.req("S-3")
def test_holding_cmd_shows_the_tab_keys_ui(inst, win, ui):
    import Quartz
    new_tab(inst, win)
    front(inst, win, ui, win["pane"])

    def flags(value):
        event = Quartz.CGEventCreateKeyboardEvent(None, 55, value != 0)
        Quartz.CGEventSetType(event, Quartz.kCGEventFlagsChanged)
        Quartz.CGEventSetFlags(event, value)
        Quartz.CGEventPostToPid(ui.pid, event)

    try:
        flags(ui.CMD)
        time.sleep(0.3)
        assert not sidebar(inst, win["window"])["hints"], "not before 750 ms"
        wait_until(lambda: sidebar(inst, win["window"])["hints"], 3, message="hints while ⌘ is held")
        assert row(inst, win["window"], win["tab"]).get("hint") == "⌘1"
    finally:
        flags(0)
    wait_until(lambda: not sidebar(inst, win["window"])["hints"], 3, message="hints gone when ⌘ is let go")


@pytest.mark.req("S-4")
def test_the_row_menu_opens_with_warps_items_and_color_dots_ui(inst, win, ui):
    from test_umi_panes_ui import _frame, _right_click, _row_element
    _, t2 = new_tab(inst, win, "--name", "menu-middle")
    new_tab(inst, win, "--name", "menu-last")
    front(inst, win, ui, win["pane"])
    element = wait_until(lambda: _row_element(ui, "menu-middle"), 5, message="the row")
    _right_click(_frame(ui, element))
    menus = wait_until(lambda: ui.find_all(lambda e: ui.role(e) == "AXMenu"), 3, message="the row menu")
    texts = [t for m in menus for t in ui.texts(m)]
    ui.key(ui.ESCAPE)
    wait_until(lambda: not ui.find_all(lambda e: ui.role(e) == "AXMenu"), 3, message="Escape closed the menu")
    wanted = ["Pin tab", "Copy tab title", "Rename tab", "Rename active pane", "Move Tab Down", "Move Tab Up",
              "Close tab", "Close other tabs", "Close Tabs Below", "Default (no color)", "Red", "Cyan",
              "Move Tab to New Window"]
    missing = [t for t in wanted if t not in texts]
    assert not missing, f"the row menu lacks {missing} (it has {texts})"
    positions = [texts.index(t) for t in wanted if t in texts]
    assert positions == sorted(positions), f"not in Warp's order: {texts}"


@pytest.mark.req("S-14")
def test_tab_groups_from_the_keyboard_ui(inst, win, ui):
    """The Window menu's Tab Groups items (also in ⌘P's palette): a group named by typing, then
    collapsed and expanded."""
    _, t2 = new_tab(inst, win)
    inst.cli("tab", "focus", t2)
    front(inst, win, ui)
    ui.choose(ui.menu_item("New Group with Tab"))
    wait_until(lambda: "group" in sidebar(inst, win["window"]).get("renaming", {}), 5, message="the group's name field")
    field = ui.focused_input(5)
    assert field is not None, "the cursor is in the group's name"
    ui.enter_text("Typed group", field, replace=True)
    press(ui, "return")
    wait_until(lambda: [g["name"] for g in groups(inst, win["window"])["groups"]] == ["Typed group"], 5,
               message="the group named")
    ui.choose(ui.menu_item("Collapse or Expand Tab Group"))
    wait_until(lambda: groups(inst, win["window"])["groups"][0]["collapsed"], 5, message="collapsed")
    assert ui.find(lambda e: ui.label(e) == "Group: Typed group") is not None, "the header is on screen"
    ui.choose(ui.menu_item("Collapse or Expand Tab Group"))
    wait_until(lambda: not groups(inst, win["window"])["groups"][0]["collapsed"], 5, message="expanded")
    ui.choose(ui.menu_item("Ungroup Tabs"))
    wait_until(lambda: groups(inst, win["window"])["groups"] == [], 5, message="ungrouped")
