"""Pane data (SPEC D-1 to D-8; CLI.md "Attributes", "Events and logs"): attributes on panes, tabs and
windows, the ones Umi keeps, `agent.*` written through `pane set`, events carrying their cause, the
activity log and the focus log.

Looking and the focus log need the app in front; `debug.ui.assume_active` counts it as active (and
the screen as unlocked) with its current window as key. `debug.update.input` stands for the user
typing or clicking; `debug.focus_log` shortens the focus log's 3-minute idle limit.
"""

import datetime
import json
import os
import re
import select
import subprocess
import time

import pytest

from harness import wait_until
from test_umi_panes_ui import new_tab, rpc, split

pytestmark = pytest.mark.layout

ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?([+-]\d\d:\d\d|Z)$")


def parse_iso(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def in_pane(inst, pane):
    """The environment of a `umi` run inside `pane` (its UMI_PANE_ID and UMI_INSTANCE)."""
    return {"UMI_PANE_ID": pane, "UMI_INSTANCE": inst.instance_id()}


def tab_json(inst, tab_id):
    return next(t for w in inst.tree()["windows"] for t in w["tabs"] if t["id"] == tab_id)


def window_json(inst, window_id):
    return next(w for w in inst.tree()["windows"] if w["id"] == window_id)


class Events:
    """`<cli> events …` running in the background, read as JSON lines."""

    def __init__(self, inst, *args):
        self.proc = subprocess.Popen([inst.target.cli_path, "events", *args], stdout=subprocess.PIPE, env=inst.env)
        self.seen, self.buffer = [], b""
        time.sleep(0.5)

    def until(self, predicate, timeout=10):
        deadline = time.time() + timeout
        fd = self.proc.stdout.fileno()
        while time.time() < deadline:
            found = [e for e in self.seen if predicate(e)]
            if found:
                return found
            ready, _, _ = select.select([fd], [], [], 0.3)
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                self.buffer += chunk
                *lines, self.buffer = self.buffer.split(b"\n")
                self.seen += [json.loads(line) for line in lines if line.strip()]
        raise AssertionError(f"no such event; saw {[e.get('event') for e in self.seen]}")

    def close(self):
        self.proc.terminate()
        self.proc.wait(5)


@pytest.fixture
def active(inst):
    rpc(inst, "debug.ui.assume_active", on=True)
    yield
    rpc(inst, "debug.ui.assume_active", on=False)


# ---- D-1: attributes on panes, tabs and windows ---------------------------------------------------

@pytest.mark.req("D-1", "L-7")
def test_pane_set_get_and_unset(inst, win):
    pane = win["pane"]
    out = inst.json("pane", "set", pane, "priority=high", "status=reviewing PR", "note=")
    assert out["panes"] == [pane] and out["set"] == {"priority": "high", "status": "reviewing PR", "note": ""}, out
    attributes = inst.attributes(pane)
    assert (attributes["priority"], attributes["status"], attributes["note"]) == ("high", "reviewing PR", ""), attributes
    assert inst.cli("pane", "get", pane, "priority").stdout == "high\n"
    got = inst.json("pane", "get", pane)
    assert got["pane"] == pane and got["attributes"]["status"] == "reviewing PR", got
    # Text without keys: key=value lines.
    assert "priority=high" in inst.cli("pane", "get", pane).stdout.splitlines()
    out = inst.json("pane", "unset", pane, "priority", "never-set")
    assert out["panes"] == [pane]
    assert "priority" not in inst.attributes(pane) and inst.attributes(pane)["status"] == "reviewing PR"


@pytest.mark.req("D-1", "P-4")
def test_pane_set_inside_a_pane_defaults_to_that_pane(inst, win):
    other = split(inst, "right", win["pane"], "--no-focus")
    inst.cli("pane", "set", "project=impact-ops", env=in_pane(inst, other))
    assert inst.attributes(other)["project"] == "impact-ops"
    assert "project" not in inst.attributes(win["pane"])
    # A leading word that names a pane is the pane, also for unset and get.
    inst.cli("pane", "set", other, "x=1")
    assert inst.cli("pane", "get", other, "x").stdout == "1\n"
    inst.cli("pane", "unset", other, "x")
    assert "x" not in inst.attributes(other)


@pytest.mark.req("D-1")
def test_tab_and_window_attributes(inst, win):
    out = inst.json("tab", "set", win["tab"], "project=impact-ops")
    assert out["tabs"] == [win["tab"]], out
    assert tab_json(inst, win["tab"])["attributes"]["project"] == "impact-ops"
    out = inst.json("window", "set", win["window"], "desk=left")
    assert out["windows"] == [win["window"]], out
    assert window_json(inst, win["window"])["attributes"] == {"desk": "left"}
    assert inst.cli("window", "get", win["window"], "desk").stdout == "left\n"
    inst.cli("tab", "unset", win["tab"], "project")
    inst.cli("window", "unset", win["window"], "desk")
    assert "project" not in tab_json(inst, win["tab"])["attributes"]
    assert window_json(inst, win["window"])["attributes"] == {}


@pytest.mark.req("D-1", "T-4")
def test_each_attribute_change_is_an_event(inst, win):
    pane = win["pane"]
    events = Events(inst, "--filter", "pane.changed", "--filter", "tab.changed", "--filter", "window.changed")
    try:
        inst.cli("pane", "set", pane, "priority=high")
        inst.cli("pane", "set", pane, "priority=low")
        inst.cli("pane", "unset", pane, "priority")
        inst.cli("tab", "set", win["tab"], "project=x")
        inst.cli("window", "set", win["window"], "desk=left")
        changes = events.until(lambda e: e["event"] == "window.changed")
        mine = [(e["event"], e["data"]["key"], e["data"].get("old"), e["data"].get("new")) for e in events.seen
                if e["data"].get("pane") == pane or e["data"].get("tab") == win["tab"]
                or e["data"].get("window") == win["window"]]
        assert mine == [("pane.changed", "priority", None, "high"), ("pane.changed", "priority", "high", "low"),
                        ("pane.changed", "priority", "low", None), ("tab.changed", "project", None, "x"),
                        ("window.changed", "desk", None, "left")], (mine, changes)
        # Setting a value it already has changes nothing.
        inst.cli("pane", "set", pane, "same=1")
        inst.cli("pane", "set", pane, "same=1")
        inst.cli("pane", "set", pane, "marker=1")
        events.until(lambda e: e["data"].get("key") == "marker")
        assert len([e for e in events.seen if e["data"].get("key") == "same"]) == 1
    finally:
        events.close()


@pytest.mark.req("D-1", "R-3")
def test_attributes_come_back_after_a_restart(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-d1r-", restore=True)
    pane = other.cli("tab", "new", "--name", "kept-attrs").stdout.strip()
    info = other.json("pane", "info", pane)
    other.cli("pane", "set", pane, "priority=high", "role=manager")
    other.cli("tab", "set", info["tab"], "project=impact-ops")
    other.cli("window", "set", info["window"], "desk=left")
    time.sleep(1)
    other.quit_app()
    other.start_app()
    assert other.attributes(pane)["priority"] == "high" and other.attributes(pane)["role"] == "manager"
    window, tab, _ = other.find_pane(pane)
    assert tab["attributes"]["project"] == "impact-ops"
    assert window["attributes"]["desk"] == "left"


# ---- D-2: Umi's own keys can't be set ---------------------------------------------------------------

@pytest.mark.req("D-2")
@pytest.mark.parametrize("key", ["cwd", "seen_at", "changed_at", "kind", "focused", "hidden", "idle_for", "visible_count"])
def test_read_only_keys_fail_and_change_nothing(inst, win, key):
    pane = win["pane"]
    proc = inst.cli("pane", "set", pane, "ok=1", f"{key}=x", check=False)
    assert proc.returncode == 1 and proc.stderr.startswith("umi: ") and key in proc.stderr, proc
    assert "ok" not in inst.attributes(pane), "a failed set changed something"
    assert inst.attributes(pane).get(key) != "x"
    assert inst.cli("tab", "set", win["tab"], f"{key}=x", check=False).returncode == 1


@pytest.mark.req("D-2")
def test_bad_keys_and_targets_fail(inst, win):
    for words in (["bad key=1"], ["=1"], ["noequals"], []):
        proc = inst.cli("pane", "set", win["pane"], *words, check=False)
        assert proc.returncode == 1 and proc.stderr.startswith("umi: "), (words, proc)
    assert inst.cli("pane", "set", "no-such-pane-zz", "a=1", check=False).returncode == 1
    assert inst.cli("pane", "unset", win["pane"], check=False).returncode == 1


# ---- D-3: single holders ----------------------------------------------------------------------------

@pytest.mark.req("D-3")
def test_role_moves_between_panes(inst, win):
    a = win["pane"]
    b = split(inst, "right", a, "--no-focus")
    events = Events(inst, "--filter", "pane.changed")
    try:
        inst.cli("pane", "set", a, "role=manager")
        inst.cli("pane", "set", b, "role=manager")
        assert inst.attributes(b)["role"] == "manager"
        assert "role" not in inst.attributes(a)
        took = events.until(lambda e: e["data"]["pane"] == a and e["data"]["key"] == "role" and e["data"]["new"] is None)
        assert took[0]["data"]["old"] == "manager"
        # Other values have holders of their own.
        inst.cli("pane", "set", a, "role=reviewer")
        assert (inst.attributes(a)["role"], inst.attributes(b)["role"]) == ("reviewer", "manager")
    finally:
        events.close()
        inst.cli("pane", "unset", b, "role", check=False)
        inst.cli("pane", "unset", a, "role", check=False)


@pytest.mark.req("D-3", "E-10")
def test_the_docs_tab_is_the_tab_with_role_docs(inst, win, tmp_path):
    _, second = new_tab(inst, win)
    inst.cli("tab", "set", win["tab"], "role=docs")
    assert tab_json(inst, win["tab"])["docs"] is True
    inst.cli("tab", "set", second, "role=docs")
    assert tab_json(inst, second)["docs"] is True and tab_json(inst, second)["attributes"]["role"] == "docs"
    assert tab_json(inst, win["tab"])["docs"] is False and "role" not in tab_json(inst, win["tab"])["attributes"]
    # Markdown opened from outside Umi goes to that tab.
    doc = tmp_path / "notes.md"
    doc.write_text("# Notes\n")
    opened = rpc(inst, "debug.ui.open_file", path=str(doc))
    assert opened["tab"] == second, opened


# ---- D-4: what Umi keeps ----------------------------------------------------------------------------

@pytest.mark.req("D-4")
def test_umi_keeps_read_only_attributes(inst, win, tmp_path):
    pane = win["pane"]
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "trunk-d4", str(repo)], check=True)
    inst.type_line(pane, f"cd '{repo}'")
    attributes = wait_until(lambda: (a := inst.attributes(pane)).get("branch") == "trunk-d4" and a, 15,
                            message="the branch of the pane's folder")
    assert os.path.realpath(attributes["cwd"]) == os.path.realpath(str(repo))
    assert (attributes["kind"], attributes["hidden"], attributes["in_drawer"]) == ("terminal", "false", "false")
    assert attributes["focused"] == "true"
    assert re.fullmatch(r"\d+s", attributes["idle_for"]), attributes
    found = inst.find_pane(pane)[2]
    assert (found["kind"], found["hidden"], found["in_drawer"]) == ("terminal", False, False)
    assert found["indicator"] == "none"
    # idle_for counts from the last output.
    time.sleep(3)
    assert int(inst.attributes(pane)["idle_for"][:-1]) >= 2
    inst.type_line(pane, "echo hello-d4")
    wait_until(lambda: int(inst.attributes(pane)["idle_for"][:-1]) <= 1, 5, message="idle_for back near 0")
    # The command it runs.
    inst.type_line(pane, "sleep 4")
    wait_until(lambda: inst.attributes(pane).get("command", "").startswith("sleep 4"), 5, message="command")
    # A tab counts the panes it shows.
    assert tab_json(inst, win["tab"])["attributes"]["visible_count"] == "1"
    other = split(inst, "right", pane, "--no-focus")
    assert tab_json(inst, win["tab"])["attributes"]["visible_count"] == "2"
    assert inst.attributes(other)["focused"] == "false"


@pytest.mark.req("D-4", "S-3")
def test_seen_at_and_changed_at(inst, win, active):
    pane = win["pane"]
    other = split(inst, "right", pane, "--no-focus")
    try:
        inst.hook(other, "SessionStart")
        inst.cli("pane", "focus", pane)
        wait_until(lambda: rpc(inst, "debug.ui.attention")["looked_at"] == pane, 5, message="looking at the pane")
        # The pane looked at is seen now, whatever it runs.
        seen = parse_iso(inst.attributes(pane)["seen_at"])
        assert abs(seen - time.time()) < 3
        inst.hook(other, "UserPromptSubmit", prompt="a task")
        inst.hook(other, "Stop", last_assistant_message="done")
        attributes = inst.attributes(other)
        for key in ("changed_at", "status_since"):
            assert ISO.match(attributes[key]), attributes
        # Unseen is changed_at > seen_at, and the indicator says so.
        assert parse_iso(attributes["changed_at"]) > parse_iso(attributes.get("seen_at", "1970-01-01T00:00:00Z"))
        assert inst.find_pane(other)[2]["indicator"] == "finished"
        inst.cli("pane", "focus", other)
        wait_until(lambda: parse_iso(inst.attributes(other)["seen_at"]) >= parse_iso(inst.attributes(other)["changed_at"]),
                   5, message="seen after a look")
        wait_until(lambda: inst.find_pane(other)[2]["indicator"] == "none", 5, message="the indicator clears")
    finally:
        inst.hook(other, "SessionEnd")


# ---- D-5: agent.* through pane set -----------------------------------------------------------------

@pytest.mark.req("D-5", "AG-18")
def test_agent_attributes_can_be_written(inst, win):
    pane = win["pane"]
    proc = inst.cli("pane", "set", pane, "agent.status=working", check=False)
    assert proc.returncode == 1 and "agent.kind" in proc.stderr, proc
    assert "agent.status" not in inst.attributes(pane)
    assert inst.cli("pane", "set", pane, "agent.kind=claude", "agent.status=busy", check=False).returncode == 1
    try:
        inst.cli("pane", "set", pane, "agent.kind=claude", "agent.status=needs_input", "agent.title=a script's agent")
        attributes = inst.attributes(pane)
        assert (attributes["agent.kind"], attributes["agent.status"], attributes["agent.title"]) == \
            ("claude", "needs_input", "a script's agent"), attributes
        # It counts as any agent does: the Dock badge counts it.
        wait_until(lambda: rpc(inst, "debug.dock_badge")["badge"] == "1", 5, message="the Dock badge")
        before = attributes["changed_at"]
        time.sleep(1.1)
        inst.cli("pane", "set", pane, "agent.status=idle", "agent.done=true")
        attributes = inst.attributes(pane)
        assert (attributes["agent.status"], attributes["agent.done"]) == ("idle", "true")
        assert parse_iso(attributes["changed_at"]) > parse_iso(before)
        assert inst.cli("pane", "unset", pane, "agent.status", check=False).returncode == 1
        # The next hook event overwrites them.
        inst.hook(pane, "UserPromptSubmit", prompt="from the hook")
        assert inst.attributes(pane)["agent.status"] == "working"
    finally:
        inst.cli("pane", "unset", pane, "agent.kind")
    assert not [k for k in inst.attributes(pane) if k.startswith("agent.")], inst.attributes(pane)


# ---- D-6: events carry their cause -----------------------------------------------------------------

@pytest.mark.req("D-6", "T-4")
def test_events_carry_when_and_why(inst, win):
    pane = win["pane"]
    events = Events(inst, "--pane", pane)
    try:
        inst.cli("pane", "set", pane, "from=outside")
        inst.cli("pane", "set", "from=inside", env=in_pane(inst, pane))
        inst.hook(pane, "SessionStart")
        changed = events.until(lambda e: e["data"].get("key") == "agent.status")
        outside = next(e for e in events.seen if e["data"].get("new") == "outside")
        inside = next(e for e in events.seen if e["data"].get("new") == "inside")
        assert ISO.match(outside["at"]), outside
        assert outside["cause"]["kind"] == "cli" and outside["cause"]["command"] == f"umi pane set {pane} from=outside"
        assert "pane" not in outside["cause"]
        assert inside["cause"] == {"kind": "cli", "command": "umi pane set from=inside", "pane": pane}, inside
        assert changed[0]["cause"]["kind"] == "hook", changed
        for event in events.seen:
            assert set(event) >= {"event", "at", "cause", "data"} and event["cause"]["kind"], event
    finally:
        events.close()
        inst.hook(pane, "SessionEnd")


@pytest.mark.req("D-6")
def test_a_key_the_palette_and_umi_cause_events(inst, win):
    pane = win["pane"]
    split(inst, "right", pane)
    events = Events(inst)
    try:
        # A key: ⌃⌘T moves the focused pane to a new tab.
        rpc(inst, "debug.key", window=win["window"], keys="ctrl+cmd+t")
        moved = events.until(lambda e: e["event"] == "pane.moved")
        assert moved[0]["cause"] == {"kind": "key", "key": "ctrl+cmd+t"}, moved
        # The palette: what its command does is caused by the palette.
        rpc(inst, "debug.palette.perform", window=win["window"], title="Set Pane Attribute…", answers=["via=palette"])
        set_ = events.until(lambda e: e["event"] == "pane.changed" and e["data"].get("key") == "via")
        assert set_[0]["cause"]["kind"] == "palette" and "pane set" in set_[0]["cause"]["command"], set_
        # A command the palette runs gets UMI_CAUSE: its own umi calls are recorded with that cause.
        inst.cli("pane", "set", pane, "via=script", env=dict(in_pane(inst, pane), UMI_CAUSE="palette"))
        script = events.until(lambda e: e["data"].get("new") == "script")
        assert script[0]["cause"]["kind"] == "palette"
        inst.cli("pane", "set", pane, "via=bound", env=dict(in_pane(inst, pane), UMI_CAUSE="key:ctrl+cmd+y"))
        bound = events.until(lambda e: e["data"].get("new") == "bound")
        assert (bound[0]["cause"]["kind"], bound[0]["cause"]["key"]) == ("key", "ctrl+cmd+y")
    finally:
        events.close()
        rpc(inst, "debug.palette.close", window=win["window"])


# ---- D-7: the activity log --------------------------------------------------------------------------

@pytest.mark.req("D-7")
def test_the_activity_log(inst, win):
    pane = win["pane"]
    start = time.time()
    inst.cli("pane", "set", pane, "step=one")
    other = split(inst, "right", pane, "--no-focus")
    inst.cli("pane", "move", other, "--new-tab", "--no-focus")
    inst.cli("pane", "set", pane, "step=two")
    log = wait_until(lambda: (l := inst.json("log", "--since", "1m", "--pane", pane)["events"])
                     and any(e["data"].get("new") == "two" for e in l) and l, 5, message="the log")
    steps = [e["data"]["new"] for e in log if e["event"] == "pane.changed" and e["data"]["key"] == "step"]
    assert steps == ["one", "two"], log
    assert all(e["data"].get("pane") == pane for e in log)
    stamps = [parse_iso(e["at"]) for e in log]
    assert stamps == sorted(stamps) and stamps[0] >= start - 1
    # Moves say from where to where.
    moved = [e for e in inst.json("log", "--since", "1m", "--filter", "pane.moved")["events"] if e["data"]["pane"] == other]
    assert len(moved) == 1, moved
    data = moved[0]["data"]
    assert data["from"]["tab"] == win["tab"] and data["from"]["window"] == win["window"] and data["from"]["index"] == 2
    assert data["to"]["tab"] != win["tab"] and data["to"]["index"] == 1
    # Filters and times.
    created = inst.json("log", "--since", "1m", "--filter", "pane.created")["events"]
    assert any(e["data"]["pane"] == other for e in created) and all(e["event"] == "pane.created" for e in created)
    assert inst.json("log", "--since", "1m", "--until", "2h", "--pane", pane)["events"] == []
    assert "pane.changed" in inst.cli("log", "--since", "1m", "--pane", pane).stdout
    assert inst.cli("log", "--since", "yesterday-ish", check=False).returncode == 1


@pytest.mark.req("D-7", "T-4")
def test_events_since_replays_the_log_then_streams(inst, win):
    pane = win["pane"]
    inst.cli("pane", "set", pane, "before=1")
    events = Events(inst, "--pane", pane, "--since", "1m")
    try:
        events.until(lambda e: e["data"].get("key") == "before")
        inst.cli("pane", "set", pane, "after=1")
        events.until(lambda e: e["data"].get("key") == "after")
    finally:
        events.close()


@pytest.mark.req("D-7", "R-3")
def test_the_activity_log_outlives_a_restart(fresh):
    other = fresh(prefix="acc-d7-")
    pane = other.json("window", "new")["pane"]
    other.cli("pane", "set", pane, "kept=yes")
    time.sleep(0.5)
    other.quit_app()
    other.start_app()
    log = other.json("log", "--since", "10m", "--filter", "pane.changed", "--pane", pane)["events"]
    assert [e["data"]["new"] for e in log if e["data"]["key"] == "kept"] == ["yes"], log


# ---- D-8: the focus log -----------------------------------------------------------------------------

def stretches(inst, pane):
    return inst.json("focus-log", "--since", "10m", "--pane", pane)["stretches"]


@pytest.mark.req("D-8")
def test_the_focus_log_records_stretches_of_focus(inst, win, active):
    a = win["pane"]
    b = split(inst, "right", a, "--no-focus")
    inst.cli("pane", "set", a, "priority=high")
    try:
        rpc(inst, "debug.update.input")
        inst.cli("pane", "focus", a)
        time.sleep(1.5)
        inst.cli("pane", "focus", b)
        rpc(inst, "debug.update.input")
        mine = wait_until(lambda: [s for s in stretches(inst, a) if not s.get("open")], 5, message="a's stretch")
        stretch = mine[-1]
        assert stretch["seconds"] >= 1.2, stretch
        assert (stretch["tab"], stretch["window"], stretch["kind"]) == (win["tab"], win["window"], "terminal")
        assert stretch["attributes"]["priority"] == "high" and stretch["cwd"] and "title" in stretch
        assert parse_iso(stretch["end"]) - parse_iso(stretch["start"]) == pytest.approx(stretch["seconds"], abs=0.2)
        # The stretch going on now is listed, ending now.
        now = stretches(inst, b)
        assert now and now[-1].get("open") is True, now
        # Text for people.
        assert b[:8] in inst.cli("focus-log", "--since", "10m").stdout
    finally:
        inst.cli("pane", "focus", a)


@pytest.mark.req("D-8")
def test_a_stretch_ends_when_the_user_stops_or_the_screen_locks(inst, win, active):
    pane = win["pane"]
    try:
        rpc(inst, "debug.focus_log", idle_after=2)
        rpc(inst, "debug.update.input")
        inst.cli("pane", "focus", pane)
        wait_until(lambda: (s := stretches(inst, pane)) and s[-1].get("open"), 5, message="a stretch")
        # Nobody types or clicks: it ends when the idle limit passed, not when Umi noticed.
        wait_until(lambda: not stretches(inst, pane)[-1].get("open"), 12, message="the stretch to end")
        assert stretches(inst, pane)[-1]["seconds"] <= 3.5, stretches(inst, pane)[-1]
        rpc(inst, "debug.focus_log", idle_after=180)
        rpc(inst, "debug.update.input")
        wait_until(lambda: stretches(inst, pane)[-1].get("open"), 8, message="a new stretch after typing")
        rpc(inst, "debug.focus_log", locked=True)
        assert not stretches(inst, pane)[-1].get("open")
        rpc(inst, "debug.focus_log", locked=False)
        assert stretches(inst, pane)[-1].get("open")
    finally:
        rpc(inst, "debug.focus_log", idle_after=180, locked=False)
