"""Windows, tabs, panes, moving live sessions, terminal I/O and events (SPEC L, M, T, P-4)."""

import json
import os
import subprocess
import tempfile
import threading
import time
import uuid

import pytest

from harness import UI, frontmost_pid, wait_until

pytestmark = pytest.mark.layout


def type_and_wait(inst, pane, command, marker, timeout=15):
    inst.cli("send", "--pane", pane, "-e", command)
    inst.cli("wait", "--pane", pane, "--pattern", f"^{marker}", "--timeout", str(timeout))


def pane_info(inst, pane):
    return inst.json("pane", "info", pane)


def window_of(inst, window_id):
    return next(w for w in inst.tree()["windows"] if w["id"] == window_id)


# ---- L: creating and managing ------------------------------------------------------------------

@pytest.mark.req("L-1", "L-3", "L-7")
def test_split_with_name_ratio_and_cwd(inst, win):
    right = inst.cli("split", "right", "--pane", win["pane"], "--name", "editor", "--ratio", "0.3").stdout.strip()
    down = inst.cli("split", "down", "--pane", right, "--cwd", "/tmp").stdout.strip()
    _, tab, pane = inst.find_pane(pane_info(inst, "editor")["id"])
    assert pane.get("name") == "editor"
    assert len(tab["panes"]) == 3
    wait_until(lambda: pane_info(inst, down).get("cwd") in ("/tmp", "/private/tmp"), 10, message="cwd of the split")


@pytest.mark.req("L-1", "L-2")
def test_tabs_new_rename_color_focus(inst, win):
    pane = inst.cli("tab", "new", "--pane", win["pane"], "--window", win["window"], "--name", "build",
                    "--color", "blue").stdout.strip()
    tab = pane_info(inst, pane)["tab"]
    inst.cli("tab", "rename", tab, "renamed")
    inst.cli("tab", "color", tab, "green")
    _, t, _ = inst.find_pane(pane)
    assert t.get("name") == "renamed" and t.get("color") == "green"
    bad = inst.cli("tab", "color", tab, "chartreuse", check=False)
    assert bad.returncode != 0
    inst.cli("tab", "focus", tab)
    w = window_of(inst, win["window"])
    assert len(w["tabs"]) == 2 and w["selected_tab"] == tab
    inst.cli("tab", "rename", tab, "")
    _, t, _ = inst.find_pane(pane)
    assert not t.get("name")


@pytest.mark.req("L-4")
def test_selectors_and_errors_change_nothing(inst, win):
    before = inst.tree()
    for args in (["pane", "info", "zzzzzzzz"], ["split", "sideways", "--pane", win["pane"]],
                 ["tab", "focus", "no-such-tab-name"], ["window", "focus", "#99"]):
        proc = inst.cli(*args, check=False)
        assert proc.returncode != 0, args
        assert proc.stderr.strip(), f"{args}: errors are explained on stderr"
    after = inst.tree()
    assert [w["id"] for w in after["windows"]] == [w["id"] for w in before["windows"]]
    # Prefix, name, '.', '#N'
    info = pane_info(inst, win["pane"][:8])
    assert info["id"] == win["pane"]
    inst.cli("pane", "rename", win["pane"], "sel-target")
    assert pane_info(inst, "sel-target")["id"] == win["pane"]
    idx = window_of(inst, win["window"])["index"]
    inst.cli("window", "focus", f"#{idx}")


@pytest.mark.req("L-3")
def test_swap_zoom_resize_close(inst, win):
    right = inst.cli("split", "right", "--pane", win["pane"]).stdout.strip()
    right_id = pane_info(inst, right)["id"]
    inst.cli("pane", "swap", win["pane"], right)
    _, tab, _ = inst.find_pane(win["pane"])
    assert [p["id"] for p in tab["panes"]] == [right_id, win["pane"]]
    inst.cli("pane", "zoom", right)
    assert pane_info(inst, right)["zoomed"]
    inst.cli("pane", "zoom", right)
    assert not pane_info(inst, right)["zoomed"]
    inst.cli("pane", "resize", right, "left", "5")
    inst.cli("pane", "close", right)
    wait_until(lambda: inst.find_pane(right_id) is None, 5, message="pane closed")
    extra = inst.cli("tab", "new", "--window", win["window"]).stdout.strip()
    extra_info = pane_info(inst, extra)
    inst.cli("tab", "close", extra_info["tab"])
    wait_until(lambda: inst.find_pane(extra_info["id"]) is None, 5, message="tab closed")


@pytest.mark.req("L-2")
def test_pinned_tabs_come_first_and_stay_grouped(inst, win):
    a = pane_info(inst, inst.cli("tab", "new", "--window", win["window"]).stdout.strip())
    b = pane_info(inst, inst.cli("tab", "new", "--window", win["window"]).stdout.strip())
    inst.cli("tab", "pin", b["tab"])
    inst.cli("tab", "pin", a["tab"])
    w = window_of(inst, win["window"])
    assert [t["id"] for t in w["tabs"][:2]] == [b["tab"], a["tab"]], "pinned first, in pin order"
    assert all(t["pinned"] for t in w["tabs"][:2]) and not w["tabs"][2]["pinned"]
    # An unpinned tab can't be moved into the pinned group, nor a pinned one out of it.
    inst.cli("tab", "move", win["tab"], "--index", "1")
    w = window_of(inst, win["window"])
    assert [t["pinned"] for t in w["tabs"]] == [True, True, False]
    inst.cli("tab", "unpin", b["tab"])
    w = window_of(inst, win["window"])
    assert [t["id"] for t in w["tabs"] if t["pinned"]] == [a["tab"]]


@pytest.mark.req("L-5")
def test_worktree_tabs_and_splits(inst, win):
    repo = os.path.realpath(tempfile.mkdtemp(prefix="acc-repo-"))
    subprocess.run(["git", "init", "-q", repo], check=True)
    subprocess.run(["git", "-C", repo, "commit", "-q", "--allow-empty", "-m", "init"], check=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                        "GIT_COMMITTER_EMAIL": "t@t"})
    pane = inst.cli("tab", "new", "--cwd", repo, "--worktree", "feature-x").stdout.strip()
    wait_until(lambda: (pane_info(inst, pane).get("cwd") or "").endswith("feature-x"), 10, message="worktree cwd")
    wt = pane_info(inst, pane)["cwd"]
    branch = subprocess.run(["git", "-C", wt, "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
    assert branch == "feature-x"
    # The same name again reuses the worktree.
    pane2 = inst.cli("split", "right", "--pane", pane, "--worktree", "feature-x").stdout.strip()
    wait_until(lambda: pane_info(inst, pane2).get("cwd") == wt, 10, message="same worktree reused")
    # Noisy hooks don't break it.
    hook = os.path.join(repo, ".git", "hooks", "post-checkout")
    with open(hook, "w") as f:
        f.write("#!/bin/sh\necho hook noise\necho more noise >&2\n")
    os.chmod(hook, 0o755)
    pane3 = inst.cli("tab", "new", "--cwd", repo, "--worktree", "noisy").stdout.strip()
    wait_until(lambda: (pane_info(inst, pane3).get("cwd") or "").endswith("noisy"), 10, message="noisy worktree cwd")
    for p in (pane, pane3):
        inst.cli("tab", "close", pane_info(inst, p)["tab"], check=False)


@pytest.mark.req("L-6")
def test_relative_cwd_is_relative_to_the_caller(inst, win):
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="acc-rel-"))
    pane = inst.cli("split", "right", "--pane", win["pane"], "--cwd", ".", cwd=tmp).stdout.strip()
    wait_until(lambda: os.path.realpath(pane_info(inst, pane).get("cwd") or "") == tmp, 10, message="relative cwd")


@pytest.mark.req("L-8")
def test_no_focus_creation_never_changes_the_users_focus(inst, win):
    inst.cli("pane", "focus", win["pane"])
    time.sleep(0.5)
    front_before = frontmost_pid()
    samples, stop = [], threading.Event()

    def sample():
        while not stop.is_set():
            try:
                w = window_of(inst, win["window"])
                tab = next(t for t in w["tabs"] if t["selected"])
                samples.append((w["selected_tab"], tab["focused_pane"]))
            except Exception:  # noqa: BLE001
                pass

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    time.sleep(0.3)
    inst.cli("split", "right", "--pane", win["pane"], "--no-focus")
    inst.cli("tab", "new", "--window", win["window"], "--no-focus")
    inst.cli("window", "new", "--no-focus")
    time.sleep(1.0)
    stop.set()
    thread.join(5)
    moved = [s for s in samples if s != (win["tab"], win["pane"])]
    assert samples and not moved, f"focus moved during --no-focus creation: {moved[:3]}"
    if front_before is not None and front_before != inst.app_pid:
        assert frontmost_pid() == front_before, "--no-focus creation brought the app to the front"


@pytest.mark.req("L-8", "M-1")
def test_no_focus_move_keeps_selection_and_front_app(inst, win):
    right = inst.cli("split", "right", "--pane", win["pane"]).stdout.strip()
    inst.cli("pane", "focus", win["pane"])
    time.sleep(0.5)
    front_before = frontmost_pid()
    samples, stop = [], threading.Event()

    def sample():
        while not stop.is_set():
            try:
                w = window_of(inst, win["window"])
                samples.append(w["selected_tab"])
            except Exception:  # noqa: BLE001
                pass

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    time.sleep(0.2)
    inst.cli("pane", "move", right, "--new-tab", "--no-focus")
    time.sleep(1.0)
    stop.set()
    thread.join(5)
    assert set(samples) == {win["tab"]}, f"the selected tab changed during a --no-focus move: {set(samples)}"
    tab = next(t for t in window_of(inst, win["window"])["tabs"] if t["id"] == win["tab"])
    assert tab["focused_pane"] == win["pane"]
    if front_before is not None and front_before != inst.app_pid:
        assert frontmost_pid() == front_before, "a --no-focus move brought the app to the front"


# ---- M: moving live sessions ------------------------------------------------------------------

def start_counter(inst, pane):
    """A program that keeps printing, to prove a pane's process survives moves."""
    marker = "C" + uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", pane, "-e", f"i=0; while true; do echo {marker}-$i; i=$((i+1)); sleep 0.2; done")
    inst.cli("wait", "--pane", pane, "--pattern", f"{marker}-3", "--timeout", "10")
    return marker


def counter_value(inst, pane, marker):
    text = inst.cli("read", "--pane", pane, "--scrollback").stdout
    values = [int(line.split("-")[1]) for line in text.splitlines()
              if line.startswith(marker + "-") and line.split("-")[1].isdigit()]
    return max(values) if values else -1


def assert_still_counting(inst, pane, marker):
    before = counter_value(inst, pane, marker)
    wait_until(lambda: counter_value(inst, pane, marker) > before + 2, 10, message="the program keeps running")
    # Scrollback from before the move is still there.
    assert f"{marker}-0" in inst.cli("read", "--pane", pane, "--scrollback").stdout


@pytest.mark.req("M-1", "M-6")
def test_move_pane_everywhere_keeps_the_program_running(inst, win):
    marker = start_counter(inst, win["pane"])
    other_tab_pane = inst.cli("tab", "new", "--window", win["window"]).stdout.strip()
    inst.cli("split", "right", "--pane", win["pane"])
    # Next to a pane in another tab.
    inst.cli("pane", "move", win["pane"], "--to", other_tab_pane, "--dir", "down")
    assert pane_info(inst, win["pane"])["tab"] == pane_info(inst, other_tab_pane)["tab"]
    assert_still_counting(inst, win["pane"], marker)
    # Into a new tab.
    inst.cli("pane", "move", win["pane"], "--new-tab")
    assert len(inst.find_pane(win["pane"])[1]["panes"]) == 1
    assert_still_counting(inst, win["pane"], marker)
    # Into a new window: a separate window, not a tab of an existing one.
    windows_before = {w["id"] for w in inst.tree()["windows"]}
    inst.cli("pane", "move", win["pane"], "--new-window")
    w, _, _ = wait_until(lambda: inst.find_pane(win["pane"]), 5, message="moved pane")
    assert w["id"] not in windows_before and len(w["tabs"]) == 1
    assert_still_counting(inst, win["pane"], marker)
    # Into another existing window, next to its focused pane.
    inst.cli("pane", "move", win["pane"], "--window", win["window"], "--dir", "right")
    assert inst.find_pane(win["pane"])[0]["id"] == win["window"]
    assert_still_counting(inst, win["pane"], marker)
    inst.cli("keys", "--pane", win["pane"], "ctrl+c")


@pytest.mark.req("M-2")
def test_move_tabs_between_windows_keeps_programs(inst, win):
    second = pane_info(inst, inst.cli("tab", "new", "--window", win["window"]).stdout.strip())
    third = pane_info(inst, inst.cli("tab", "new", "--window", win["window"]).stdout.strip())
    marker = start_counter(inst, second["id"])
    inst.cli("tab", "move", third["tab"], "--window", win["window"], "--index", "1")
    assert window_of(inst, win["window"])["tabs"][0]["id"] == third["tab"]
    inst.cli("tab", "move", second["tab"], "--new-window")
    wait_until(lambda: inst.find_pane(second["id"])[0]["id"] != win["window"], 5, message="tab detached")
    assert_still_counting(inst, second["id"], marker)
    inst.cli("tab", "move", second["tab"], "--window", win["window"], "--index", "2")
    wait_until(lambda: inst.find_pane(second["id"])[0]["id"] == win["window"], 5, message="tab reattached")
    assert window_of(inst, win["window"])["tabs"][1]["id"] == second["tab"]
    assert_still_counting(inst, second["id"], marker)
    # Reordering without a window stays in the tab's own window.
    other = inst.json("window", "new")
    new_tab = pane_info(inst, inst.cli("tab", "new", "--pane", other["pane"]).stdout.strip())
    inst.cli("tab", "move", new_tab["tab"], "--index", "1")
    assert window_of(inst, other["window"])["tabs"][0]["id"] == new_tab["tab"]
    inst.cli("keys", "--pane", second["id"], "ctrl+c")


@pytest.mark.req("M-3")
def test_undo_redo_of_moves(inst, win, ui):
    marker = "UNDO-" + uuid.uuid4().hex[:8]
    right = pane_info(inst, inst.cli("split", "right", "--pane", win["pane"]).stdout.strip())["id"]
    type_and_wait(inst, right, f"echo {marker}", marker)
    inst.cli("pane", "focus", win["pane"])
    inst.cli("pane", "move", right, "--new-tab")
    wait_until(lambda: inst.find_pane(right)[1]["id"] != win["tab"], 5, message="moved")
    inst.cli("pane", "focus", win["pane"])
    ui.activate()
    ui.choose(ui.menu_item("Undo"))
    wait_until(lambda: inst.find_pane(right) and inst.find_pane(right)[1]["id"] == win["tab"], 5, message="undo")
    w = window_of(inst, win["window"])
    assert len(w["tabs"]) == 1
    assert sum(1 for t in w["tabs"] for p in t["panes"] if p["id"] == right) == 1
    ui.choose(ui.menu_item("Redo"))
    wait_until(lambda: inst.find_pane(right)[1]["id"] != win["tab"], 5, message="redo")
    marker2 = "REDO-" + uuid.uuid4().hex[:8]
    type_and_wait(inst, right, f"echo {marker2}", marker2)


@pytest.mark.req("M-5")
def test_detached_pane_keeps_its_size(inst, win):
    inst.cli("split", "right", "--pane", win["pane"])
    inst.cli("send", "--pane", win["pane"], "-e", "stty size")
    before = inst.cli("wait", "--pane", win["pane"], "--pattern", r"^\d+ \d+$", "--timeout", "10").stdout.strip()
    rows, cols = map(int, before.split())
    inst.cli("pane", "move", win["pane"], "--new-window")
    time.sleep(1.0)
    inst.cli("send", "--pane", win["pane"], "-e", "clear; stty size")
    after = inst.cli("wait", "--pane", win["pane"], "--pattern", r"^\d+ \d+$", "--timeout", "10").stdout.strip()
    rows2, cols2 = map(int, after.split())
    assert cols2 >= cols - 2 and rows2 >= rows - 2, f"lost size: {before} -> {after}"
    assert cols2 >= 40 and rows2 >= 10, "a window never ends up unusably small"


# ---- T: input, output, events -----------------------------------------------------------------

@pytest.mark.req("T-1", "T-2", "T-3")
def test_send_read_wait_keys(inst, win):
    marker = "IO-" + uuid.uuid4().hex[:8]
    inst.cli("send", "--pane", win["pane"], "-e", f"echo {marker}")
    matched = inst.cli("wait", "--pane", win["pane"], "--pattern", f"^{marker}$", "--timeout", "10").stdout.strip()
    assert matched == marker
    assert marker in inst.cli("read", "--pane", win["pane"], "--lines", "5").stdout
    inst.cli("send", "--pane", win["pane"], "-e", "sleep 30; echo SHOULD-NOT-PRINT")
    time.sleep(0.5)
    inst.cli("keys", "--pane", win["pane"], "ctrl+c")
    done = "AFTER-" + uuid.uuid4().hex[:6]
    type_and_wait(inst, win["pane"], f"echo {done}", done)
    assert "\nSHOULD-NOT-PRINT" not in inst.cli("read", "--pane", win["pane"], "--scrollback").stdout
    # Idle waits.
    inst.cli("wait", "--pane", win["pane"], "--idle", "1", "--timeout", "10")
    timeout = inst.cli("wait", "--pane", win["pane"], "--pattern", "^NEVER-APPEARS$", "--timeout", "1", check=False)
    assert timeout.returncode == 124


@pytest.mark.req("T-1")
def test_send_text_from_stdin_and_after_separator(inst, win):
    marker = "STDIN-" + uuid.uuid4().hex[:8]
    inst.cli("send", "--pane", win["pane"], "-e", stdin=f"echo {marker}\n")
    inst.cli("wait", "--pane", win["pane"], "--pattern", f"^{marker}", "--timeout", "10")
    inst.cli("send", "--pane", win["pane"], "-e", "--", "echo DASHDASH-$((40+2))")
    inst.cli("wait", "--pane", win["pane"], "--pattern", "^DASHDASH-42$", "--timeout", "10")


@pytest.mark.req("T-3")
def test_wait_ends_when_the_pane_closes(inst, win):
    right = inst.cli("split", "right", "--pane", win["pane"]).stdout.strip()
    result = {}

    def waiter():
        start = time.time()
        proc = inst.cli("wait", "--pane", right, "--pattern", "^NEVER$", "--timeout", "30", check=False)
        result.update(code=proc.returncode, elapsed=time.time() - start)

    thread = threading.Thread(target=waiter)
    thread.start()
    time.sleep(1)
    inst.cli("pane", "close", right)
    thread.join(20)
    assert result.get("code") not in (0, None)
    assert result["elapsed"] < 10


def follow_events(inst, *args):
    received = []
    proc = subprocess.Popen([inst.target.cli_path, "events", *args], stdout=subprocess.PIPE, text=True,
                            env=inst.env, stdin=subprocess.DEVNULL)

    def reader():
        for line in proc.stdout:
            try:
                received.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    threading.Thread(target=reader, daemon=True).start()
    time.sleep(0.6)
    return proc, received


@pytest.mark.req("T-4")
def test_event_stream_and_filters(inst, win):
    proc, received = follow_events(inst, "--filter", "pane.", "--filter", "tab.")
    try:
        right = pane_info(inst, inst.cli("split", "right", "--pane", win["pane"]).stdout.strip())["id"]
        inst.cli("tab", "rename", win["tab"], "evented")
        wait_until(lambda: any(e["event"] == "pane.created" and e["data"].get("pane") == right for e in received),
                   5, message="pane.created")
        wait_until(lambda: any(e["event"] == "tab.renamed" for e in received), 5, message="tab.renamed")
    finally:
        proc.terminate()
    inst.cli("pane", "rename", win["pane"], "evt-target")
    proc, received = follow_events(inst, "--filter", "pane.", "--pane", "evt-target")
    try:
        inst.cli("pane", "rename", win["pane"], "evt-renamed")
        wait_until(lambda: any(e["event"] == "pane.renamed" for e in received), 5, message="filtered by pane name")
        assert all(e["data"].get("pane", win["pane"]) == win["pane"] for e in received)
    finally:
        proc.terminate()


@pytest.mark.req("T-4", "L-8")
def test_selection_changes_are_events(inst, win):
    second = pane_info(inst, inst.cli("tab", "new", "--window", win["window"]).stdout.strip())
    proc, received = follow_events(inst)
    try:
        inst.cli("tab", "focus", win["tab"])
        inst.cli("tab", "focus", second["tab"])
        wait_until(lambda: any(e["event"] in ("tab.selected", "pane.focused") for e in received), 5,
                   message="a selection/focus event")
    finally:
        proc.terminate()


@pytest.mark.req("T-4", "R-6")
def test_a_stalled_event_consumer_never_stalls_the_app(inst, win):
    stalled = subprocess.Popen([inst.target.cli_path, "events"], stdout=subprocess.PIPE, env=inst.env,
                               stdin=subprocess.DEVNULL)   # never read
    try:
        deadline = time.time() + 10
        i = 0
        while time.time() < deadline:
            inst.cli("tab", "rename", win["tab"], "flood-" + "x" * 200 + str(i), timeout=10)
            i += 1
        assert i > 20, "the app kept answering while a consumer was stalled"
        assert inst.cli("ls", timeout=10).returncode == 0
    finally:
        stalled.kill()


@pytest.mark.req("T-5")
def test_concurrent_cli_calls(inst, win):
    errors = []

    def worker():
        for _ in range(5):
            proc = inst.cli("ls", check=False, timeout=60)
            if proc.returncode != 0:
                errors.append(proc.stderr)

    threads = [threading.Thread(target=worker) for _ in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(120)
    assert not any(t.is_alive() for t in threads)
    assert errors == []


@pytest.mark.req("T-6")
def test_notify(inst, win):
    inst.cli("notify", "--pane", win["pane"], "Build finished", "all green")


@pytest.mark.req("T-7")
def test_screenshot(inst, win, tmp_path):
    out = tmp_path / "shot.png"
    inst.cli("screenshot", "--window", win["window"], str(out))
    data = out.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) > 2000


# ---- P-4: inside the app's terminals -----------------------------------------------------------

@pytest.mark.req("P-4")
def test_cli_inside_panes_defaults_to_this_pane(inst, win):
    name = "from-inside-" + uuid.uuid4().hex[:4]
    cli = inst.target.cli_name
    inst.cli("send", "--pane", win["pane"], "-e", f"{cli} pane rename {name} && echo RENAMED-OK")
    inst.cli("wait", "--pane", win["pane"], "--pattern", "RENAMED-OK", "--timeout", "15")
    assert pane_info(inst, win["pane"]).get("name") == name
    # A tab created from a background window's pane lands in that window.
    other = inst.json("window", "new")
    inst.cli("pane", "focus", other["pane"])
    time.sleep(0.3)
    inst.cli("send", "--pane", win["pane"], "-e", f"{cli} tab new >/dev/null && echo TAB-OK")
    inst.cli("wait", "--pane", win["pane"], "--pattern", "TAB-OK", "--timeout", "15")
    assert len(window_of(inst, win["window"])["tabs"]) == 2
    # `window close` from inside closes the caller's own window.
    inst.cli("send", "--pane", other["pane"], "-e", f"{cli} window close")
    wait_until(lambda: not any(w["id"] == other["window"] for w in inst.tree()["windows"]), 10,
               message="the caller's window closed")
    assert any(w["id"] == win["window"] for w in inst.tree()["windows"])


SHORTCUTS = {
    "cmd+b": "toggle the sidebar", "cmd+shift+e": "show the project explorer", "cmd+o": "open a file",
    "cmd+shift+m": "toggle Markdown preview/source", "cmd+ctrl+t": "move the pane to a new tab",
    "cmd+ctrl+n": "move the pane to a new window", "cmd+ctrl+left": "move the pane into the previous tab",
    "cmd+ctrl+right": "move the pane into the next tab", "cmd+ctrl+shift+n": "move the tab to a new window",
    "cmd+ctrl+p": "pin or unpin the tab", "cmd+ctrl+r": "rename the tab", "cmd+ctrl+shift+r": "rename the pane",
    # L-9 as rewritten after the user's decisions (L-11 to L-17).
    "cmd+shift+[": "back to the tab visited before", "cmd+shift+]": "the next tab in sidebar order",
    "cmd+1": "the first tab", "cmd+8": "the eighth tab", "cmd+9": "the last tab",
    "cmd+p": "the command palette", "cmd+shift+p": "the pane palette", "cmd+,": "Settings (shortcuts)",
    "cmd+ctrl+j": "the next session that needs the user", "cmd+ctrl+k": "back from that jump",
    # L-20, AG-6, AG-8.
    "cmd+shift+t": "reopen the last closed pane, tab or window",
    "cmd+ctrl+o": "take over the focused pane's session", "cmd+ctrl+w": "remove the session from its pane",
}
AGENT_SHORTCUTS = {"cmd+ctrl+j": "jump to the agent that needs the user"}


@pytest.mark.req("L-9", "S-2")
def test_shortcuts_are_menu_items(inst, win, ui):
    """Every shortcut in L-9 is a menu item with that key equivalent. (What each one does is checked
    through the CLI equivalents here and by the written check L-9.)"""
    missing = [f"{spec} ({what})" for spec, what in SHORTCUTS.items() if ui.shortcut(spec) is None]
    assert not missing, f"shortcuts with no menu item: {missing}"
    labels = {spec: ui.label(ui.shortcut(spec)) for spec in SHORTCUTS}
    assert len(set(labels.values())) == len(labels), f"one item for two shortcuts: {labels}"


@pytest.mark.req("L-9")
@pytest.mark.harness
def test_agent_shortcuts_are_menu_items(inst, win, ui):
    shortcuts = {**SHORTCUTS, **AGENT_SHORTCUTS}
    missing = [f"{spec} ({what})" for spec, what in AGENT_SHORTCUTS.items() if ui.shortcut(spec) is None]
    assert not missing, f"shortcuts with no menu item: {missing}"
    labels = {spec: ui.label(ui.shortcut(spec)) for spec in shortcuts}
    assert len(set(labels.values())) == len(labels), f"one item for two shortcuts: {labels}"


@pytest.mark.req("S-2")
def test_sidebar_modes_from_the_cli(inst, win):
    inst.cli("sidebar", "off")
    assert inst.json("sidebar", "status")["visible"] is False
    inst.cli("sidebar", "toggle")
    assert inst.json("sidebar", "status")["visible"] is True
    inst.cli("sidebar", "files")
    assert inst.json("sidebar", "status")["mode"] == "files"
    inst.cli("sidebar", "tabs")
    assert inst.json("sidebar", "status") == {"visible": True, "mode": "tabs"} or \
        inst.json("sidebar", "status")["mode"] == "tabs"
