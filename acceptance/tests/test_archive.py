"""The archive (SPEC AR-1 to AR-6; design/archive.md; CLI.md "Tabs" and "Events").

Each window has an archive at the top of its sidebar: the Archived row ("Archived · N"), shown only
while the window has an archived tab, closed by default; open, it lists the archived tabs under it in
the box a tab group uses, in the order they were archived. Archived tabs keep running. `archived=true`
is a tab attribute queries see as `tab.archived`. Keys are pressed with `debug.key` (inside the app)
and menus run with `debug.menu.perform` / `debug.ui.menu.perform`; `debug.ui.archive` and
`debug.ui.rows` report what the sidebar draws. The `_ui` tests use real keys and clicks and need an
unlocked screen.
"""

import time
import uuid

import pytest

from harness import wait_until
from test_hidden_panes import events_since, iso_now
from test_umi_panes_ui import ready, rpc, tab_of, tab_ids

pytestmark = pytest.mark.layout


# ---- helpers ---------------------------------------------------------------------------------------

def new_tab(inst, win, *extra):
    pane = inst.cli("tab", "new", "--window", win["window"], "--no-focus", *extra).stdout.strip()
    return inst.json("pane", "info", pane)["tab"]


def window_json(inst, win):
    return next(w for w in inst.tree()["windows"] if w["id"] == win["window"])


def archive(inst, win):
    return rpc(inst, "debug.ui.archive", window=win["window"])


def rows(inst, win):
    return {r["tab"]: r for r in rpc(inst, "debug.ui.rows", window=win["window"])["rows"]}


def listed(inst, win):
    """The tabs the sidebar lists outside the archive, in order (its entries, groups' headers left out)."""
    return [e.strip() for e in rpc(inst, "debug.ui.groups", window=win["window"])["entries"] if not e.startswith("group:")]


def selected(inst, win):
    return window_json(inst, win)["selected_tab"]


def key(inst, win, keys):
    return rpc(inst, "debug.key", window=win["window"], keys=keys, focus="none")


def menu_item(inst, title):
    return next((i for i in rpc(inst, "debug.menu")["items"] if i["title"] == title), None)


def row_titles(inst, tab):
    return [i["title"] for i in rpc(inst, "debug.ui.menu", tab=tab)["items"] if " > " not in i["path"]]


@pytest.fixture
def four(inst, win):
    """The test's window with four tabs: A (the window's own, selected), B, C, D."""
    a = win["tab"]
    b, c, d = (new_tab(inst, win) for _ in range(3))
    inst.cli("tab", "focus", a)
    assert tab_ids(inst, win["window"]) == [a, b, c, d]
    return a, b, c, d


# ---- AR-1: the Archived row --------------------------------------------------------------------------

@pytest.mark.req("AR-1", "AR-2")
def test_archiving_puts_a_tab_under_the_archived_row_and_it_keeps_running(inst, win, four):
    a, b, c, d = four
    assert archive(inst, win) == {"shown": False, "open": False, "count": 0, "tabs": []}, "no row without an archived tab"
    pane_c = tab_of(inst, c)["panes"][0]["id"]
    start = iso_now()
    inst.cli("tab", "archive", c)
    arc = archive(inst, win)
    assert arc["shown"] and arc["count"] == 1 and arc["tabs"] == [c] and arc["title"] == "Archived · 1", arc
    assert not arc["open"], "closed by default"
    # Out of the sidebar's list, its row not shown while the archive is closed.
    assert listed(inst, win) == [a, b, d]
    r = rows(inst, win)
    assert r[c]["archived"] and not r[c]["shown"] and r[a]["shown"], r[c]
    # Its attribute, in `ls` and its tab JSON.
    t = tab_of(inst, c)
    assert t["archived"] is True and t["attributes"]["archived"] == "true", t
    assert tab_of(inst, a)["attributes"]["archived"] == "false"
    assert window_json(inst, win)["archive"] == {"open": False, "tabs": [c]}
    # It keeps running.
    marker = "STILL-" + uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", pane_c, "-e", f"echo {marker}")
    inst.cli("wait", "--pane", pane_c, "--pattern", f"^{marker}", "--timeout", "10")
    # The event, recorded in the activity log.
    ev = events_since(inst, start, "tab.archived")
    assert ev and ev[-1]["data"]["tab"] == c and ev[-1]["data"]["window"] == win["window"], ev
    # Latest last; the count follows.
    inst.cli("tab", "archive", b)
    arc = archive(inst, win)
    assert arc["tabs"] == [c, b] and arc["title"] == "Archived · 2"
    assert listed(inst, win) == [a, d]
    inst.cli("tab", "unarchive", c)
    inst.cli("tab", "unarchive", b)
    assert archive(inst, win)["shown"] is False, "the row goes with the last archived tab"


@pytest.mark.req("AR-1")
def test_a_click_opens_the_archive_in_place_and_each_window_remembers_its_own(inst, win, four):
    a, b, c, d = four
    other = inst.json("window", "new")
    other_win = {"window": other["window"]}
    other_tab = inst.json("pane", "info", other["pane"])["tab"]
    inst.cli("tab", "new", "--window", other["window"], "--no-focus")
    inst.cli("tab", "archive", c)
    inst.cli("tab", "archive", other_tab)
    # A click on the row opens it: its tabs listed (shown) under it.
    assert rpc(inst, "debug.ui.archive", window=win["window"], toggle=True)["open"] is True
    assert rows(inst, win)[c]["shown"] is True
    assert window_json(inst, win)["archive"]["open"] is True
    # The other window's archive stays closed.
    assert archive(inst, other_win)["open"] is False
    # A second click closes it.
    assert rpc(inst, "debug.ui.archive", window=win["window"], toggle=True)["open"] is False
    assert rows(inst, win)[c]["shown"] is False
    rpc(inst, "debug.ui.archive", window=win["window"], toggle=True)
    inst.cli("tab", "unarchive", c)
    assert archive(inst, win)["shown"] is False


@pytest.mark.req("AR-1")
def test_the_archived_row_shows_no_indicator(inst, win, four):
    """No mark and no `tab.summary` from the tabs inside: the row's text is only "Archived · N"."""
    a, b, c, d = four
    pane_c = tab_of(inst, c)["panes"][0]["id"]
    inst.cli("tab", "archive", c)
    try:
        rpc(inst, "debug.attention.set", pane=pane_c, title="waiting-agent", mark="needs_you", stopped_ago=5)
        rpc(inst, "debug.ui.archive", window=win["window"], toggle=True)
        r = rows(inst, win)[c]
        assert r["mark"] == "needs_you", "the tab's own row, open, looks like any row"
        arc = archive(inst, win)
        assert arc["title"] == "Archived · 1" and set(arc) == {"shown", "open", "count", "tabs", "title"}, arc
    finally:
        rpc(inst, "debug.attention.set", pane=pane_c, clear=True)
        rpc(inst, "debug.ui.archive", window=win["window"], toggle=True)
        inst.cli("tab", "unarchive", c)


@pytest.mark.req("AR-1")
def test_a_search_lists_the_archived_tabs_that_match(inst, win, four):
    a, b, c, d = four
    inst.cli("tab", "rename", c, "needle-archived")
    inst.cli("tab", "rename", d, "needle-active")
    inst.cli("tab", "archive", c)
    try:
        rpc(inst, "debug.ui.sidebar", window=win["window"], query="needle")
        r = rows(inst, win)
        assert r[c]["shown"] and r[d]["shown"] and not r[a]["shown"], "the archived match shows, the archive closed or not"
        rpc(inst, "debug.ui.sidebar", window=win["window"], query="needle-active")
        assert not rows(inst, win)[c]["shown"]
    finally:
        rpc(inst, "debug.ui.sidebar", window=win["window"], query="")
        inst.cli("tab", "unarchive", c)


# ---- AR-2: archiving and bringing back ----------------------------------------------------------------

@pytest.mark.req("AR-2")
def test_archiving_the_selected_tab_selects_what_closing_it_would(inst, win, four):
    a, b, c, d = four
    inst.cli("tab", "focus", b)
    inst.cli("tab", "archive", b)
    assert selected(inst, win) == c, "the tab below, as after closing it"
    inst.cli("tab", "focus", d)
    inst.cli("tab", "archive", d)
    assert selected(inst, win) == c, "the last tab: the one above"
    # Archiving a tab that isn't selected leaves the selection alone.
    inst.cli("tab", "archive", a)
    assert selected(inst, win) == c
    for t in (a, b, d):
        inst.cli("tab", "unarchive", t)


@pytest.mark.req("AR-2")
def test_archiving_unpins_and_ungroups_and_unarchiving_goes_to_the_top_of_the_unpinned_tabs(inst, win, four):
    a, b, c, d = four
    inst.cli("tab", "pin", d)
    assert tab_ids(inst, win["window"])[0] == d
    rpc(inst, "debug.ui.menu.perform", tab=b, title="New group with tab")
    rpc(inst, "debug.ui.sidebar", window=win["window"], rename_cancel=True)
    rpc(inst, "debug.ui.menu.perform", tab=c, title="Move to group > New Group")
    assert tab_of(inst, c).get("group") == "New Group"
    start = iso_now()
    inst.cli("tab", "archive", d)
    inst.cli("tab", "archive", c)
    assert tab_of(inst, d)["pinned"] is False and "group" not in tab_of(inst, c)
    assert events_since(inst, start, "tab.unpinned")[-1]["data"]["tab"] == d
    assert events_since(inst, start, "tab.ungrouped")[-1]["data"]["tab"] == c
    # Bringing back restores neither: each goes to the top of the unpinned tabs.
    inst.cli("tab", "pin", a)
    inst.cli("tab", "unarchive", d)
    assert tab_ids(inst, win["window"])[:2] == [a, d] and not tab_of(inst, d)["pinned"]
    inst.cli("tab", "unarchive", c)
    assert tab_ids(inst, win["window"])[:3] == [a, c, d] and "group" not in tab_of(inst, c)
    ev = events_since(inst, start, "tab.unarchived")
    assert [e["data"]["tab"] for e in ev][-2:] == [d, c] and "by_condition" not in ev[-1]["data"]
    inst.cli("tab", "unpin", a)


@pytest.mark.req("AR-2")
def test_selecting_an_archived_tab_shows_it_and_leaves_it_in_the_archive(inst, win, four):
    a, b, c, d = four
    pane_c = tab_of(inst, c)["panes"][0]["id"]
    inst.cli("tab", "archive", c)
    inst.cli("tab", "focus", c)
    assert selected(inst, win) == c and tab_of(inst, c)["archived"] is True
    assert archive(inst, win)["tabs"] == [c]
    inst.cli("tab", "focus", a)
    # A pane of it focused (as ⌃⌘J landing on it) shows it too, still archived.
    inst.cli("pane", "focus", pane_c)
    assert selected(inst, win) == c and tab_of(inst, c)["archived"] is True
    inst.cli("tab", "unarchive", c)
    assert selected(inst, win) == c, "bringing back doesn't move the selection"


@pytest.mark.req("AR-2", "L-9")
def test_ctrl_cmd_a_archives_the_current_tab_and_brings_an_archived_one_back(inst, win, four):
    a, b, c, d = four
    inst.cli("tab", "focus", b)
    key(inst, win, "ctrl+cmd+a")
    assert tab_of(inst, b)["archived"] is True and selected(inst, win) == c
    inst.cli("tab", "focus", b)
    key(inst, win, "ctrl+cmd+a")
    assert tab_of(inst, b)["archived"] is False and tab_ids(inst, win["window"])[0] == b
    # Both are Window menu items on ⌃⌘A; the one that applies is enabled.
    archive_item, unarchive_item = menu_item(inst, "Archive Tab"), menu_item(inst, "Unarchive Tab")
    assert archive_item["menu"] == unarchive_item["menu"] == "Window", archive_item
    assert (archive_item["key"], archive_item["modifiers"]) == ("a", ["ctrl", "cmd"])
    assert (unarchive_item["key"], unarchive_item["modifiers"]) == ("a", ["ctrl", "cmd"])
    assert archive_item["enabled"] and not unarchive_item["enabled"]


@pytest.mark.req("AR-2")
def test_the_row_menu_and_the_window_menu_archive_unarchive_and_show_archived(inst, win, four):
    a, b, c, d = four
    assert "Archive Tab" in row_titles(inst, c) and "Unarchive Tab" not in row_titles(inst, c)
    rpc(inst, "debug.ui.menu.perform", tab=c, title="Archive Tab")
    assert tab_of(inst, c)["archived"] is True
    # An archived tab's menu brings it back; it is neither pinned nor grouped, so offers neither.
    t = row_titles(inst, c)
    assert "Unarchive Tab" in t and "Archive Tab" not in t and "Pin tab" not in t and "New group with tab" not in t, t
    rpc(inst, "debug.ui.menu.perform", tab=c, title="Unarchive Tab")
    assert tab_of(inst, c)["archived"] is False
    # Window ▸ Archive Tab, Show Archived (opens the archive and selects its first tab), Unarchive Tab.
    inst.cli("window", "focus", win["window"])
    inst.cli("tab", "focus", d)
    rpc(inst, "debug.menu.perform", title="Archive Tab")
    inst.cli("tab", "focus", a)
    rpc(inst, "debug.menu.perform", title="Archive Tab")
    assert archive(inst, win)["tabs"] == [d, a]
    assert menu_item(inst, "Show Archived")["enabled"]
    rpc(inst, "debug.menu.perform", title="Show Archived")
    assert archive(inst, win)["open"] is True and selected(inst, win) == d
    rpc(inst, "debug.menu.perform", title="Unarchive Tab")
    assert tab_of(inst, d)["archived"] is False
    inst.cli("tab", "unarchive", a)
    # The palette lists the three.
    titles = [e["title"] for e in rpc(inst, "debug.palette", window=win["window"], mode="commands", query="archiv")["entries"]]
    assert {"Archive Tab", "Unarchive Tab", "Show Archived"} <= set(titles), [t for t in titles if "rchiv" in t]


@pytest.mark.req("AR-2", "L-13")
def test_moving_the_first_tab_up_archives_it_and_moving_an_archived_tab_down_brings_it_back(inst, win, four):
    """The Archived row is the last place above the first tab (⌃⇧↑ / Move Tab Up, `tab move --up`)."""
    a, b, c, d = four
    inst.cli("tab", "focus", a)
    key(inst, win, "ctrl+shift+up")
    assert tab_of(inst, a)["archived"] is True and selected(inst, win) == b
    inst.cli("tab", "focus", a)
    key(inst, win, "ctrl+shift+down")
    assert tab_of(inst, a)["archived"] is False and tab_ids(inst, win["window"])[0] == a
    inst.cli("tab", "move", a, "--up")
    assert tab_of(inst, a)["archived"] is True
    inst.cli("tab", "move", a, "--down")
    assert tab_of(inst, a)["archived"] is False
    # A tab below the first only moves up among the tabs, and the row menu's moves stay among them.
    inst.cli("tab", "move", b, "--up")
    assert tab_ids(inst, win["window"])[:2] == [b, a] and not tab_of(inst, b)["archived"]
    assert "Move Tab Up" not in row_titles(inst, b)


@pytest.mark.req("AR-2", "S-4")
def test_close_other_tabs_leaves_the_archive_alone(inst, win, four):
    a, b, c, d = four
    # Until a shell shows its prompt and runs nothing, closing its tab asks first; a dialog left open
    # would hold up every later test of the shared instance.
    ready(inst, *(tab_of(inst, t)["panes"][0]["id"] for t in (b, d)))
    wait_until(lambda: not next(w for w in rpc(inst, "debug.confirm")["windows"]
                                if w["window"] == win["window"])["needs_confirmation"], 20,
               message="no pane of the window runs a program")
    inst.cli("tab", "archive", c)
    inst.cli("tab", "focus", a)
    rpc(inst, "debug.ui.menu.perform", tab=a, title="Close other tabs")
    wait_until(lambda: tab_ids(inst, win["window"]) == [a, c], 10, message="b and d closed, the archived c kept")
    inst.cli("tab", "unarchive", c)


# ---- AR-3: the keys skip archived tabs -------------------------------------------------------------------

@pytest.mark.req("AR-3", "L-11")
def test_tab_keys_skip_archived_tabs(inst, win, four):
    a, b, c, d = four
    inst.cli("tab", "archive", b)
    inst.cli("tab", "focus", a)
    key(inst, win, "cmd+shift+]")
    assert selected(inst, win) == c, "⇧⌘] skipped b"
    key(inst, win, "cmd+shift+[")
    assert selected(inst, win) == a
    key(inst, win, "cmd+shift+[")
    assert selected(inst, win) == d, "wrapping, among the tabs out of the archive"
    assert inst.cli("tab", "next").stdout.strip() == a
    key(inst, win, "cmd+2")
    assert selected(inst, win) == c, "⌘2 is the second tab out of the archive"
    key(inst, win, "cmd+9")
    assert selected(inst, win) == d
    # The ⌘ hints number the same tabs; the archived one has none.
    rpc(inst, "debug.ui.sidebar", window=win["window"], command_held=True)
    try:
        r = rows(inst, win)
        assert [r[t].get("hint") for t in (a, c, d)] == ["⌘1", "⌘2", "⌘3"] and "hint" not in r[b], r
    finally:
        rpc(inst, "debug.ui.sidebar", window=win["window"], command_held=False)
    # From an archived tab, ⇧⌘] goes to the first tab.
    inst.cli("tab", "focus", b)
    key(inst, win, "cmd+shift+]")
    assert selected(inst, win) == a
    inst.cli("tab", "unarchive", b)


@pytest.mark.req("AR-3", "AR-4", "L-12")
def test_the_default_jump_list_leaves_out_panes_in_archived_tabs(inst, win, four):
    a, b, c, d = four
    pane_b, pane_c = (tab_of(inst, t)["panes"][0]["id"] for t in (b, c))
    try:
        for pane in (pane_b, pane_c):
            rpc(inst, "debug.attention.set", pane=pane, title="waiting", mark="needs_you", stopped_ago=5)
        inst.cli("tab", "archive", b)
        jump = inst.json("ls", "--where", "@jump")["panes"]
        ids = [p["id"] for p in jump]
        assert pane_c in ids and pane_b not in ids, ids
        assert pane_b in [p["id"] for p in inst.json("ls", "--where", "@needs-you")["panes"]], "still needs you"
        lists = {l["name"]: l for l in inst.json("list", "ls")["lists"]}
        assert "tab.archived!=true" in lists["jump"]["query"] and lists["jump"]["default"] is True
    finally:
        for pane in (pane_b, pane_c):
            rpc(inst, "debug.attention.set", pane=pane, clear=True)
        inst.cli("tab", "unarchive", b)


# ---- AR-4: an attribute queries see ------------------------------------------------------------------------

@pytest.mark.req("AR-4")
def test_tab_archived_is_a_tab_attribute_queries_see(inst, win, four):
    a, b, c, d = four
    pane_c = tab_of(inst, c)["panes"][0]["id"]
    inst.cli("tab", "archive", c)
    found = [p["id"] for p in inst.json("ls", "--where", "tab.archived=true")["panes"]]
    assert found == [pane_c], found
    assert pane_c not in [p["id"] for p in inst.json("ls", "--where", "tab.archived=false")["panes"]]
    assert inst.cli("tab", "get", "--tab", c, "archived").stdout.strip() == "true"
    # Other tab attributes read the same way.
    inst.cli("tab", "set", "--tab", c, "project=umi")
    assert [p["id"] for p in inst.json("ls", "--where", "tab.project=umi")["panes"]] == [pane_c]
    # `tab set archived=…` archives and brings back, as the commands do.
    inst.cli("tab", "set", "--tab", c, "archived=false")
    assert tab_of(inst, c)["archived"] is False
    inst.cli("tab", "set", "--tab", d, "archived=true")
    assert tab_of(inst, d)["archived"] is True
    inst.cli("tab", "unset", "--tab", d, "archived")
    assert tab_of(inst, d)["archived"] is False
    assert inst.cli("tab", "set", "--tab", d, "archived=maybe", check=False).returncode == 1
    # A pane can't take a `tab.` key: it names its tab's attribute.
    assert inst.cli("pane", "set", pane_c, "tab.project=x", check=False).returncode == 1
    # A query names every tab holding a match.
    inst.cli("tab", "set", "--tab", b, "project=umi")
    out = inst.json("tab", "archive", "tab.project=umi")
    assert sorted(out["tabs"]) == sorted([b, c]) and sorted(archive(inst, win)["tabs"]) == sorted([b, c])
    inst.json("tab", "unarchive", "tab.archived=true")
    assert archive(inst, win)["shown"] is False
    for t in (b, c):
        inst.cli("tab", "unset", "--tab", t, "project")


@pytest.mark.req("AR-5")
def test_archive_until_a_condition_brings_the_tab_back_by_itself(inst, win, four):
    a, b, c, d = four
    pane_c = tab_of(inst, c)["panes"][0]["id"]
    second = inst.cli("split", "right", "--pane", pane_c, "--no-focus").stdout.strip()
    start = iso_now()
    inst.cli("tab", "archive", c, "--until", "owner=me")
    assert tab_of(inst, c)["archive_until"] == [{"query": "owner=me"}]
    inst.cli("pane", "set", pane_c, "owner=you")
    time.sleep(0.5)
    assert tab_of(inst, c)["archived"] is True, "not yet"
    # A query about any of the tab's panes: the second one.
    inst.cli("pane", "set", second, "owner=me")
    wait_until(lambda: not tab_of(inst, c)["archived"], 5, message="back once the condition held")
    assert tab_ids(inst, win["window"])[0] == c
    assert "archive_until" not in tab_of(inst, c), "coming back clears its conditions"
    ev = events_since(inst, start, "tab.unarchived")[-1]
    assert ev["data"]["tab"] == c and ev["data"].get("by_condition") is True and ev["cause"]["kind"] == "config"
    # A duration, or a query: the first to hold wins.
    inst.cli("tab", "archive", c, "--until", "2s", "--until", "owner=nobody")
    assert len(tab_of(inst, c)["archive_until"]) == 2
    wait_until(lambda: not tab_of(inst, c)["archived"], 6, message="back after 2 s")
    # Unarchived by hand, its conditions go.
    inst.cli("tab", "archive", c, "--until", "owner=me2")
    inst.cli("tab", "unarchive", c)
    assert "archive_until" not in tab_of(inst, c)
    inst.cli("pane", "set", pane_c, "owner=me2")
    time.sleep(0.5)
    assert not tab_of(inst, c)["archived"]
    # A condition that doesn't parse is refused, and nothing is archived.
    assert inst.cli("tab", "archive", c, "--until", "owner=(", check=False).returncode == 1
    assert not tab_of(inst, c)["archived"]
    for p in (pane_c, second):
        inst.cli("pane", "unset", p, "owner")


# ---- AR-6: across a relaunch -------------------------------------------------------------------------------

@pytest.mark.req("AR-6", "R-3")
def test_archived_tabs_their_order_the_open_archive_and_conditions_come_back_after_a_relaunch(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-archive-", restore=True)
    made = other.json("window", "new")
    window = made["window"]
    first = other.json("pane", "info", made["pane"])["tab"]
    panes = [other.cli("tab", "new", "--window", window, "--no-focus").stdout.strip() for _ in range(3)]
    t1, t2, t3 = (other.json("pane", "info", p)["tab"] for p in panes)
    other.cli("tab", "archive", t2)
    other.cli("tab", "archive", t1, "--until", "owner=me")
    other.rpc("debug.ui.archive", window=window, toggle=True)
    time.sleep(1.5)
    other.quit_gracefully()
    other.start_app()
    wait_until(lambda: other.tree()["windows"], 20, message="the window came back")
    w = next(x for x in other.tree()["windows"] if x["archive"]["tabs"])
    assert w["archive"] == {"open": True, "tabs": [t2, t1]}, w["archive"]
    assert [t["id"] for t in w["tabs"] if not t["archived"]] == [first, t3]
    t1_json = next(t for t in w["tabs"] if t["id"] == t1)
    assert t1_json["archive_until"] == [{"query": "owner=me"}]
    other.cli("pane", "set", panes[0], "owner=me")
    wait_until(lambda: not next(t for x in other.tree()["windows"] for t in x["tabs"] if t["id"] == t1)["archived"], 5,
               message="the condition still works")


# ---- with real keys and clicks (an unlocked screen) ---------------------------------------------------------

@pytest.mark.req("AR-1", "AR-2")
def test_real_ctrl_cmd_a_and_clicks_on_the_archived_row_ui(inst, win, ui, four):
    from test_umi_panes_ui import _frame
    from test_umi_sidebar_warp import click, front
    a, b, c, d = four
    rpc(inst, "sidebar", window=win["window"], visible=True, mode="tabs")
    inst.cli("tab", "rename", c, "to-archive")
    inst.cli("tab", "pin", a)
    pane_c = tab_of(inst, c)["panes"][0]["id"]
    front(inst, win, ui, pane_c)
    ui.key(0, ui.CTRL | ui.CMD)  # ⌃⌘A, a real key press
    wait_until(lambda: tab_of(inst, c)["archived"], 5, message="⌃⌘A archived the tab")
    row = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Archived · 1"), 5, message="the Archived row")
    assert ui.value(row) == "collapsed"
    # Above the pinned tabs.
    pinned = wait_until(lambda: ui.find(lambda e: ui.role(e) == "AXButton" and (ui.value(e) or "").find("pinned") >= 0), 5,
                        message="the pinned tab's row")
    assert _frame(ui, row)[1] < _frame(ui, pinned)[1], "the Archived row is above the pinned tabs"
    click(_frame(ui, row))
    wait_until(lambda: archive(inst, win)["open"], 5, message="a click opened the archive")
    archived_row = wait_until(lambda: ui.find(lambda e: (ui.label(e) or "").startswith("to-archive")), 5,
                              message="the archived tab's row under it")
    assert _frame(ui, archived_row)[1] > _frame(ui, row)[1]
    click(_frame(ui, archived_row))
    wait_until(lambda: selected(inst, win) == c, 5, message="a click selected the archived tab")
    assert tab_of(inst, c)["archived"] is True, "selecting it left it in the archive"
    click(_frame(ui, ui.find(lambda e: ui.label(e) == "Archived · 1")))
    wait_until(lambda: not archive(inst, win)["open"], 5, message="a second click closed it")
    ui.key(0, ui.CTRL | ui.CMD)
    wait_until(lambda: not tab_of(inst, c)["archived"], 5, message="⌃⌘A on the archived tab brought it back")
    inst.cli("tab", "unpin", a)
