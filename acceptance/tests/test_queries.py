"""Queries, named lists, `go`, slots, key bindings and palette commands (SPEC Q-1 to Q-8, L-4, L-12;
CLI.md "Selectors", "Queries", "Lists and `go`", "Configuration").

Agents are stood in with `pane set agent.kind=… agent.status=…` (D-5). Config tests run in an
instance of their own whose `$XDG_CONFIG_HOME` is a temporary folder: Umi reads the file again when
it changes, so each test writes the lines it needs. Keys are pressed with `debug.key` (inside the app),
the palette with `debug.palette` and `debug.palette.perform`.
"""

import json
import os
import stat
import time

import pytest

from harness import Instance, wait_until
from test_umi_panes_ui import rpc, split

pytestmark = pytest.mark.layout


def tab_new(inst, win, *extra):
    pane = inst.cli("tab", "new", "--window", win["window"], "--no-focus", *extra).stdout.strip()
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="the shell")
    return pane


def where(inst, query):
    return [p["id"] for p in inst.json("ls", "--where", query)["panes"]]


def agent(inst, pane, status, **extra):
    inst.cli("pane", "set", pane, "agent.kind=claude", f"agent.status={status}", *[f"{k}={v}" for k, v in extra.items()])


def no_agents(inst):
    """Only this test's agents: earlier tests in the shared instance may have left theirs."""
    for pane in rpc(inst, "debug.ui.attention")["panes"]:
        inst.cli("pane", "unset", pane, "agent.kind", check=False)


# ---- Q-1: queries in selectors and ls --where -------------------------------------------------------

@pytest.mark.req("Q-1", "L-4")
def test_a_query_picks_panes_by_their_attributes(inst, win):
    a, b = win["pane"], split(inst, "right", win["pane"], "--no-focus")
    c = tab_new(inst, win)
    inst.cli("pane", "set", a, "qt=1", "rank=10")
    inst.cli("pane", "set", b, "qt=1", "rank=9", "pinned=true")
    inst.cli("pane", "set", c, "qt=2", "rank=100")
    # ls order: tabs in sidebar order, panes in layout order.
    assert where(inst, "qt") == [a, b, c]
    assert where(inst, "qt=1") == [a, b]
    assert where(inst, "qt and rank > 9") == [a, c]             # numbers compare as numbers
    assert where(inst, "qt=1 or qt=2 and rank<50") == [a, b]    # and binds tighter than or
    assert where(inst, "qt and not pinned") == [a, c]
    assert where(inst, "qt | sort -rank") == [c, a, b]
    assert where(inst, "qt | sort rank | limit 2") == [b, a]
    assert where(inst, "qt=2 then qt") == [c, a, b]
    assert where(inst, "qt=\"1\"") == [a, b]
    # Each match comes with its tab and window.
    panes = inst.json("ls", "--where", "qt=2")["panes"]
    assert panes[0]["tab"] and panes[0]["window"] == win["window"] and panes[0]["attributes"]["qt"] == "2"
    # Nothing matching is an empty list for ls.
    assert inst.json("ls", "--where", "qt=nope") == {"panes": []}


@pytest.mark.req("Q-1")
def test_durations_and_times_compare_as_such(inst, win):
    pane = win["pane"]
    inst.cli("pane", "set", pane, "qd=1", "agent.kind=claude", "agent.status=idle")
    try:
        assert pane in where(inst, "qd and status_since > 10m")    # changed just now: newer
        assert pane not in where(inst, "qd and status_since < 10m")
        time.sleep(2.5)
        assert pane in where(inst, "qd and idle_for > 1s")
        assert pane not in where(inst, "qd and idle_for > 1h")
    finally:
        inst.cli("pane", "unset", pane, "agent.kind", "qd")


@pytest.mark.req("Q-1")
def test_commands_that_change_panes_act_on_every_match(inst, win):
    a, b = win["pane"], split(inst, "right", win["pane"], "--no-focus")
    inst.cli("pane", "set", a, "grp=x")
    inst.cli("pane", "set", b, "grp=x")
    out = inst.json("pane", "set", "--pane", "grp=x", "seen=yes")
    assert sorted(out["panes"]) == sorted([a, b]), out
    assert inst.attributes(a)["seen"] == "yes" and inst.attributes(b)["seen"] == "yes"
    # A first word that is a query and not KEY=VALUE is the target.
    out = inst.json("pane", "set", "(grp=x)", "more=1")
    assert sorted(out["panes"]) == sorted([a, b]), out
    inst.cli("pane", "unset", "grp=x", "seen", "more")
    assert "seen" not in inst.attributes(a) and "more" not in inst.attributes(b)
    # One-pane commands take the first match.
    assert inst.json("pane", "info", "grp=x | sort -seen")["id"] in (a, b)
    assert inst.json("pane", "get", "grp=x")["pane"] == a
    # pane close closes every match.
    c = tab_new(inst, win)
    d = split(inst, "right", c, "--no-focus")
    inst.cli("pane", "set", c, "doomed=1")
    inst.cli("pane", "set", d, "doomed=1")
    inst.cli("pane", "close", "doomed=1")
    wait_until(lambda: where(inst, "doomed") == [], 10, message="both closed")


@pytest.mark.req("Q-1")
def test_pane_move_moves_every_match_in_order(inst, win):
    c = tab_new(inst, win)
    d = split(inst, "right", c, "--no-focus")
    inst.cli("pane", "set", d, "mv=1", "ord=1")
    inst.cli("pane", "set", c, "mv=1", "ord=2")
    home = inst.json("pane", "info", win["pane"])["tab"]
    out = inst.json("pane", "move", "mv | sort ord", "--tab", home, "--no-focus")
    assert out["panes"] == [d, c], out
    assert {inst.json("pane", "info", p)["tab"] for p in (c, d)} == {home}
    # To a new tab: the first opens it, the next joins it.
    out = inst.json("pane", "move", "mv | sort ord", "--new-tab", "--no-focus")
    tabs = {inst.json("pane", "info", p)["tab"] for p in (c, d)}
    assert out["panes"] == [d, c] and len(tabs) == 1 and tabs != {home}, (out, tabs)
    inst.cli("pane", "close", "mv=1")


@pytest.mark.req("Q-1", "L-4")
def test_tab_close_closes_every_tab_holding_a_match(inst, win):
    c, d = tab_new(inst, win), tab_new(inst, win)
    inst.cli("pane", "set", c, "tc=1")
    inst.cli("pane", "set", d, "tc=1")
    tabs = {inst.json("pane", "info", p)["tab"] for p in (c, d)}
    out = inst.json("tab", "close", "tc=1")
    assert set(out["tabs"]) == tabs and len(tabs) == 2, out
    wait_until(lambda: where(inst, "tc") == [], 10, message="both tabs closed")
    assert inst.json("pane", "info", win["pane"])["window"] == win["window"]


@pytest.mark.req("Q-1", "L-4")
def test_a_tab_or_window_query_picks_the_one_holding_a_match(inst, win):
    c = tab_new(inst, win)
    inst.cli("pane", "set", c, "tabq=here")
    tab = inst.json("pane", "info", c)["tab"]
    # A KEY=VALUE first word is a pair (set's words), so the query goes in --tab.
    out = inst.json("tab", "set", "--tab", "tabq=here", "picked=1")
    assert out["tabs"] == [tab], out
    inst.cli("tab", "focus", "tabq=here")
    assert inst.tree()["current_tab"] == tab
    assert inst.json("window", "get", "tabq=here")["window"] == win["window"]


@pytest.mark.req("Q-1")
def test_bad_queries_fail_and_change_nothing(inst, win):
    for query, position in (("a=", "3"), ("(a=1", "5"), ("a=1 | sort", "11"), ("a ! b", "3")):
        proc = inst.cli("ls", "--where", query, check=False)
        assert proc.returncode == 1 and proc.stderr.startswith("umi: ") and position in proc.stderr, (query, proc.stderr)
    proc = inst.cli("pane", "set", "--pane", "nothing=matches-this", "x=1", check=False)
    assert proc.returncode == 1 and "no pane matches" in proc.stderr, proc.stderr
    proc = inst.cli("ls", "--where", "@no-such-list", check=False)
    assert proc.returncode == 1 and "no-such-list" in proc.stderr


# ---- Q-8: keys are never panes; UMI_PANE ------------------------------------------------------------

@pytest.mark.req("Q-8", "D-1")
def test_a_key_is_never_read_as_a_pane(inst, win):
    """Step 2's review: `pane get a` read `a` as a pane whose id started with "a"."""
    pane = win["pane"]
    other = split(inst, "right", pane, "--no-focus")
    inst.cli("pane", "set", other, "k=v")
    prefix = other[:4]
    env = {"UMI_PANE": pane, "UMI_INSTANCE": inst.instance_id()}
    # A unique id prefix as the first word is a key: the calling pane's (none), not the other pane's.
    got = inst.json("pane", "get", prefix, env=env)
    assert got["pane"] == pane and got["attributes"] == {}, got
    inst.cli("pane", "set", pane, f"{prefix}=mine", env=env)
    inst.cli("pane", "unset", prefix, env=env)
    assert prefix not in inst.attributes(pane) and inst.attributes(other)["k"] == "v"
    # A full id, `.`, a name or a query still is the pane.
    assert inst.json("pane", "get", other, "k", env=env)["attributes"] == {"k": "v"}
    inst.cli("pane", "rename", other, "q8-named")
    assert inst.json("pane", "get", "q8-named", "k", env=env)["attributes"] == {"k": "v"}
    assert inst.json("pane", "get", "k=v", "k", env=env)["pane"] == other


@pytest.mark.req("Q-8")
def test_panes_have_umi_pane_and_jump_is_gone(inst, win):
    pane = win["pane"]
    inst.cli("send", "--pane", pane, "--enter", "echo \"P=$UMI_PANE OLD=${UMI_PANE_ID:-none}\"")
    wait_until(lambda: f"P={pane} OLD=none" in inst.screen(pane), 10, message="the variables")
    proc = inst.cli("jump", check=False)
    assert proc.returncode == 1 and "go --next jump" in proc.stderr


# ---- Q-2: named lists -------------------------------------------------------------------------------

@pytest.mark.req("Q-2")
def test_umis_lists(inst, win):
    no_agents(inst)
    lists = {item["name"]: item for item in inst.json("list", "ls")["lists"]}
    assert {"needs-you", "unseen", "jump", "manager"} <= set(lists), lists
    assert lists["needs-you"]["query"] == "agent.status=needs_input | sort status_since"
    assert lists["jump"]["query"] == "@needs-you then @unseen" and lists["jump"]["default"] is True
    pane = win["pane"]
    agent(inst, pane, "needs_input")
    try:
        lists = {item["name"]: item for item in inst.json("list", "ls")["lists"]}
        assert lists["needs-you"]["count"] == 1
        assert [p["id"] for p in inst.json("list", "show", "needs-you")["panes"]] == [pane]
        assert where(inst, "@needs-you") == [pane]
        assert inst.cli("list", "show", "nope", check=False).returncode == 1
    finally:
        inst.cli("pane", "unset", pane, "agent.kind")


# ---- Q-3 and L-12: go -------------------------------------------------------------------------------

@pytest.mark.req("Q-3", "L-12")
def test_go_walks_a_list_and_comes_back(inst, win):
    no_agents(inst)
    home = win["pane"]
    first, second = tab_new(inst, win), tab_new(inst, win)
    inst.cli("pane", "set", first, "walk=1", "order=1")
    inst.cli("pane", "set", second, "walk=1", "order=2")
    inst.cli("pane", "focus", home)
    out = inst.json("go", "walk | sort order")
    assert out["pane"] == first and out["tab"] and out["window"] == win["window"]
    assert inst.tree()["current_pane"] == first
    inst.cli("pane", "focus", home)
    # --next starts a new walk (focus moved) and goes on through the list, wrapping round.
    assert inst.json("go", "--next", "walk | sort order")["pane"] == first
    assert inst.json("go", "--next", "walk | sort order")["pane"] == second
    assert inst.json("go", "--next", "walk | sort order")["pane"] == first
    assert inst.json("go", "--back")["pane"] == home
    assert inst.tree()["current_pane"] == home
    assert inst.cli("go", "--back", check=False).returncode == 1
    proc = inst.cli("go", "walk=none", check=False)
    assert proc.returncode == 1 and "nothing in" in proc.stderr
    assert inst.tree()["current_pane"] == home, "an empty list moved focus"


@pytest.mark.req("Q-3", "L-12")
def test_ctrl_cmd_j_and_k_run_go_next_jump_and_go_back(inst, win):
    no_agents(inst)
    home = win["pane"]
    # The finished pane shares a tab with the asking one and was focused there last: going to the
    # asking pane must not count as looking at it.
    done = tab_new(inst, win)
    asking = split(inst, "right", done, "--no-focus")
    rpc(inst, "debug.ui.assume_active", on=True)
    inst.cli("pane", "focus", home)
    agent(inst, done, "working")
    agent(inst, done, "idle")             # finished, not looked at
    agent(inst, asking, "needs_input")
    try:
        inst.cli("pane", "focus", home)
        rpc(inst, "debug.key", window=win["window"], keys="ctrl+cmd+j")
        assert inst.tree()["current_pane"] == asking
        rpc(inst, "debug.key", window=win["window"], keys="ctrl+cmd+j")
        assert inst.tree()["current_pane"] == done
        rpc(inst, "debug.key", window=win["window"], keys="ctrl+cmd+k")
        assert inst.tree()["current_pane"] == home
        # What ⌃⌘J did is caused by the key.
        focused = [e for e in inst.json("log", "--since", "1m", "--filter", "pane.focused")["events"]
                   if e["data"]["pane"] == asking]
        assert focused and focused[-1]["cause"] == {"kind": "key", "key": "ctrl+cmd+j"}, focused[-1:]
    finally:
        rpc(inst, "debug.ui.assume_active", on=False)
        for pane in (asking, done):
            inst.cli("pane", "unset", pane, "agent.kind")


# ---- Q-4 to Q-6: the config ----------------------------------------------------------------------

@pytest.fixture(scope="module")
def configured(target, tmp_path_factory):
    """An instance of its own whose config file the tests write."""
    xdg = str(tmp_path_factory.mktemp("xdg"))
    os.makedirs(os.path.join(xdg, "umi", "commands"))
    # Umi's own lines are in the file from the start, when Ghostty loads it.
    with open(os.path.join(xdg, "umi", "config"), "w") as f:
        f.write('font-size = 13\nlist.early = a=1\nslot.badge = @needs-you\nkey.ctrl+cmd+y = ls\n'
                'command."Early" = true\n')
    instance = Instance(target, prefix="acc-queries-", env={"XDG_CONFIG_HOME": xdg})
    instance.start_app()
    instance.xdg = xdg
    created = instance.json("window", "new", "--name", "queries")
    pane = created["pane"]
    wait_until(lambda: instance.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="the shell")
    instance.win = {"pane": pane, "tab": created["tab"], "window": created["window"]}
    yield instance
    instance.cleanup()


def write_config(inst, text):
    path = os.path.join(inst.xdg, "umi", "config")
    with open(path, "w") as f:
        f.write(text)
    # A changed file is read again within half a second; make sure the time stamp moved.
    os.utime(path, (time.time() + 1, time.time() + 1))
    time.sleep(1.2)


@pytest.mark.req("Q-2", "Q-4")
def test_the_config_redefines_lists_and_slots(configured):
    inst = configured
    write_config(inst, "\n".join([
        "# Ghostty settings and Umi's own lines share the file.",
        "font-size = 13",
        "list.mine = owner=me | sort -prio",
        "list.needs-you = agent.status=needs_input or owner=me",
        "slot.badge = @mine",
        "slot.landing = owner=me",
        "slot.landing.after = 5m",
        "slot.sidebar.line2 = owner {owner}",
        "slot.no-such-slot = x",
        "list.broken = a=",
        "",
    ]))
    lists = {item["name"]: item for item in inst.json("list", "ls")["lists"]}
    assert lists["mine"]["query"] == "owner=me | sort -prio" and lists["mine"]["default"] is False
    assert lists["needs-you"]["default"] is False
    assert "error" in lists["broken"] and lists["broken"]["count"] == 0
    problems = inst.json("list", "ls")["problems"]
    assert any("no-such-slot" in p for p in problems), problems
    slots = {s["name"]: s for s in inst.json("slot", "ls")["slots"]}
    assert {"jump", "badge", "landing", "landing.after", "tab.summary", "sidebar.line2", "strip.make-room",
            "indicator.working", "indicator.needs_you", "indicator.finished", "done-check"} <= set(slots)
    assert slots["badge"] == dict(slots["badge"], value="@mine", default=False)
    assert slots["done-check"]["value"] == "^Status: done" and slots["done-check"]["default"] is True
    pane = inst.win["pane"]
    # A list keeps its own order: in `list show`, `go`, and alone in a part of a query.
    second = inst.cli("split", "right", "--pane", pane, "--no-focus").stdout.strip()
    inst.cli("pane", "set", second, "owner=me", "prio=9")
    inst.cli("pane", "set", pane, "owner=me", "prio=1")
    assert [p["id"] for p in inst.json("list", "show", "mine")["panes"]] == [second, pane]
    assert where(inst, "@mine") == [second, pane] and where(inst, "@mine then owner") == [second, pane]
    assert inst.json("go", "mine")["pane"] == second
    inst.cli("pane", "close", second)
    # The badge counts the slot's matches.
    wait_until(lambda: inst.rpc("debug.dock_badge")["badge"] == "1", 5, message="the badge counts @mine")
    inst.cli("pane", "unset", pane, "owner")
    wait_until(lambda: inst.rpc("debug.dock_badge")["badge"] == "", 5, message="the badge clears")
    # The sidebar's second line follows the template.
    inst.cli("pane", "set", pane, "owner=me")
    row = next(r for r in rpc(inst, "debug.ui.rows", window=inst.win["window"])["rows"] if r["tab"] == inst.win["tab"])
    assert row["line2"] == "owner me", row
    # Landing: coming back after 5 minutes away focuses the slot's first pane; less than that, nothing.
    other = inst.cli("tab", "new", "--window", inst.win["window"]).stdout.strip()
    assert inst.tree()["current_pane"] == other
    assert rpc(inst, "debug.landing", away=60)["pane"] is None
    assert inst.tree()["current_pane"] == other
    assert rpc(inst, "debug.landing", away=400)["pane"] == pane
    assert inst.tree()["current_pane"] == pane
    focused = [e for e in inst.json("log", "--since", "1m", "--filter", "pane.focused")["events"] if e["data"]["pane"] == pane]
    assert focused[-1]["cause"]["kind"] == "config", focused[-1]
    inst.cli("pane", "close", other)
    inst.cli("pane", "unset", pane, "owner", "prio")
    # Ghostty took the file (as it was at launch, with Umi's lines) without complaining.
    assert rpc(inst, "debug.config_errors")["errors"] == []
    write_config(inst, "")
    assert {s["name"]: s for s in inst.json("slot", "ls")["slots"]}["badge"]["default"] is True


@pytest.mark.req("Q-4", "AG-18")
def test_done_check_is_a_slot(configured):
    inst = configured
    pane = inst.win["pane"]
    write_config(inst, "slot.done-check = ^ALL DONE\n")
    try:
        inst.hook(pane, "SessionStart")
        inst.hook(pane, "UserPromptSubmit", prompt="task")
        inst.hook(pane, "Stop", last_assistant_message="Worked on it.\nStatus: done")
        assert inst.attributes(pane)["agent.done"] == "false"
        inst.hook(pane, "UserPromptSubmit", prompt="task")
        inst.hook(pane, "Stop", last_assistant_message="Worked on it.\nALL DONE here")
        assert inst.attributes(pane)["agent.done"] == "true"
    finally:
        inst.hook(pane, "SessionEnd")
        inst.cli("pane", "unset", pane, "agent.kind", check=False)
        write_config(inst, "")


@pytest.mark.req("Q-5", "D-6")
def test_a_key_binding_runs_its_command(configured):
    inst = configured
    pane, window = inst.win["pane"], inst.win["window"]
    write_config(inst, "\n".join([
        "key.ctrl+cmd+y = pane set bound=yes",
        # Over Umi's own ⌃⌘J.
        "key.ctrl+cmd+j = @flagged",
        "list.flagged = flag",
        "",
    ]))
    inst.cli("pane", "focus", pane)
    rpc(inst, "debug.key", window=window, keys="ctrl+cmd+y")
    wait_until(lambda: inst.attributes(pane).get("bound") == "yes", 10, message="the bound command ran in the pane")
    change = [e for e in inst.json("log", "--since", "1m", "--filter", "pane.changed")["events"] if e["data"]["key"] == "bound"]
    assert change[-1]["cause"]["kind"] == "key" and change[-1]["cause"]["key"] == "ctrl+cmd+y", change[-1]
    listed = [s for s in inst.json("shortcuts")["shortcuts"] if s.get("source") == "config"]
    assert {s["keys"][0] for s in listed} == {"ctrl+cmd+y", "ctrl+cmd+j"}, listed
    flagged = inst.cli("tab", "new", "--window", window, "--no-focus").stdout.strip()
    inst.cli("pane", "set", flagged, "flag=1")
    rpc(inst, "debug.key", window=window, keys="ctrl+cmd+j")
    wait_until(lambda: inst.tree()["current_pane"] == flagged, 10, message="⌃⌘J went to the config's list")
    inst.cli("pane", "close", flagged)
    inst.cli("pane", "unset", pane, "bound")
    write_config(inst, "")


@pytest.mark.req("Q-6")
def test_palette_commands_from_the_config_and_the_commands_folder(configured):
    inst = configured
    pane, window = inst.win["pane"], inst.win["window"]
    script = os.path.join(inst.xdg, "umi", "commands", "show-context.sh")
    with open(script, "w") as f:
        f.write('#!/bin/sh\necho "pane=$UMI_PANE tab=$UMI_TAB window=$UMI_WINDOW cause=$UMI_CAUSE dir=$(pwd)"\n'
                '"$UMI_CLI" pane set ran=script\n')
    os.chmod(script, os.stat(script).st_mode | stat.S_IEXEC)
    write_config(inst, 'command."Say Hello" = echo hello from $UMI_STATE_DIR\n'
                       'command."Fail Loudly" = echo broken >&2; exit 3\n'
                       'key.ctrl+cmd+e = "Say Hello"\n')
    commands = {c["title"]: c for c in inst.json("command", "ls")["commands"]}
    assert commands["Show context"]["path"] == script
    assert commands["Say Hello"]["line"].startswith("echo hello") and commands["Say Hello"]["keys"] == ["ctrl+cmd+e"]
    out = inst.cli("command", "run", "Show context", "--pane", pane).stdout
    info = inst.json("pane", "info", pane)
    assert f"pane={pane} tab={info['tab']} window={window} cause=palette" in out, out
    assert inst.attributes(pane)["ran"] == "script"
    assert inst.cli("command", "run", "Say Hello").stdout.strip() == "hello from " + inst.dir
    proc = inst.cli("command", "run", "Fail Loudly", check=False)
    assert proc.returncode == 1 and "broken" in proc.stderr
    # In the palette (⌘P).
    entries = rpc(inst, "debug.palette", window=window, query="Say Hello")["entries"]
    assert any(e["title"] == "Say Hello" for e in entries), entries
    result = rpc(inst, "debug.palette.perform", window=window, title="Say Hello")
    assert "hello from" in json.dumps(result), result
    rpc(inst, "debug.palette.close", window=window)
    inst.cli("pane", "unset", pane, "ran")
    os.remove(script)
    write_config(inst, "")


# ---- Q-7: wait --attr ---------------------------------------------------------------------------------

@pytest.mark.req("Q-7")
def test_wait_attr_waits_until_the_pane_matches(inst, win):
    import subprocess
    import threading
    pane = win["pane"]
    proc = inst.cli("wait", "--pane", pane, "--attr", "never=1", "--timeout", "1", check=False)
    assert proc.returncode == 124
    threading.Timer(1.0, lambda: inst.cli("pane", "set", pane, "ready=yes")).start()
    started = time.time()
    out = inst.json("wait", "--pane", pane, "--attr", "ready=yes", "--timeout", "15")
    assert out["pane"] == pane and out["attributes"]["ready"] == "yes" and time.time() - started >= 0.9
    inst.cli("pane", "unset", pane, "ready")
