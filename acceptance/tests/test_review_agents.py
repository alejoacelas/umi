"""Regression tests for what the adversarial review of the agent-sessions work found (BRIEF-agents.md §3).

Each test names the round and the finding. Fakes only (no model is called).
"""

import glob
import json
import os
import shutil
import subprocess
import time
import uuid

import pytest

from harness import FAKE_CLAUDE, wait_until
from test_live import PLUGIN, login_fake_dir

pytestmark = pytest.mark.sessions

BANNER = "Fake Claude Code"


def nonce():
    return uuid.uuid4().hex[:8]


def fake_args(inst):
    return ["--env", "FAKE_AGENT_DIR=" + inst.fake_dir, "--env", "CLAUDE_CONFIG_DIR=" + inst.claude_config]


def wait_live(inst, sid, timeout=30):
    wait_until(lambda: inst.info(sid)["location"] == "live", timeout, message=f"the session to be live: {inst.info(sid)}")
    pane = inst.info(sid)["pane"]
    wait_until(lambda: BANNER in inst.screen(pane), timeout, message="the interface in its pane")
    return pane


def menu_item(inst, title):
    return next((i for i in inst.rpc("debug.menu")["items"] if i["title"] == title), None)


# ---- round 1 -------------------------------------------------------------------------------------

@pytest.mark.req("AG-6")
def test_take_over_while_the_headless_process_is_still_launching(fresh):
    """Round 1, P1: Take Over reaching a Claude session whose headless process is still being launched
    cancelled the launch and never answered `agent attach`. It must go live at once."""
    inst = fresh(prefix="acc-rv-", env={"TERN_TEST_LAUNCH_DELAY": "4"})
    w = inst.json("window", "new", "--cwd", inst.work)
    wait_until(lambda: inst.screen(w["pane"]).strip(), 20, message="the shell")
    n = nonce()
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), f"ECHO first {n}")["session"]["id"]
    assert inst.info(sid)["status"] == "starting"
    began = time.time()
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", w["pane"], "--live")["pane"]
    assert wait_live(inst, sid, timeout=20) == pane
    assert time.time() - began < 15, "taking over waited for the launch instead of cancelling it"
    # The message it was launched for isn't lost: it reaches the agent once, through the interface
    # being taken back while idle, and the session comes back live.
    code, out = inst.wait(sid, timeout=60)
    assert (code, out["status"]) == (0, "DONE") and f"ECHO first {n}" in out["reply"], out
    assert not inst.violations()


@pytest.mark.req("AG-6")
def test_attach_for_a_session_live_elsewhere_leaves_the_pane_as_it_was(inst, win):
    """Round 1, P2: `agent attach S` run in a second pane, for a session live in another, failed but left
    the second pane covered by the session's read-only view."""
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--name", f"elsewhere-{nonce()}",
                    "--split", "right", "--pane", win["pane"], "ECHO hello")["session"]["id"]
    live_pane = wait_live(inst, sid)
    inst.cli("send", "--pane", win["pane"], "-e", f'"$TERN_CLI" agent attach {sid}')
    wait_until(lambda: "already live" in inst.screen(win["pane"]), 15, message="attach says the session is live elsewhere")
    time.sleep(0.5)
    view = inst.session_view(win["pane"])
    assert view.get("showing") == "terminal" and not view.get("session"), view
    assert inst.info(sid)["location"] == "live" and inst.info(sid)["pane"] == live_pane


@pytest.mark.req("AG-6", "AG-2")
def test_a_session_whose_name_has_quotes_goes_live(inst, win):
    """Round 1, P2: the attach line typed into the pane quoted the session's name without escaping an
    apostrophe, so a name like "worker's task" left the shell waiting for a closing quote."""
    name = f"worker's task {nonce()}"
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--name", name,
                    "--split", "right", "--pane", win["pane"], "ECHO quoted")["session"]["id"]
    pane = wait_live(inst, sid)
    assert "quote>" not in inst.screen(pane)


@pytest.mark.req("L-17")
def test_a_key_freed_from_one_action_and_given_to_another_stays_bound(inst, win):
    """Round 1, P2: bindings were written action by action in alphabetical order, so clearing Paste (⌘V)
    and giving ⌘V to Copy wrote `super+v=copy_to_clipboard` before `super+v=unbind`."""
    try:
        inst.cli("shortcuts", "clear", "ghostty:paste_from_clipboard")
        inst.cli("shortcuts", "set", "ghostty:copy_to_clipboard", "cmd+v")
        conf = open(os.path.join(inst.dir, "keybindings.conf")).read().splitlines()
        bind = conf.index("keybind = super+v=copy_to_clipboard")
        unbinds = [i for i, line in enumerate(conf) if line.endswith("=unbind")]
        assert unbinds and max(unbinds) < bind, conf
        wait_until(lambda: (lambda i: i and i["key"] == "v" and i["modifiers"] == ["cmd"])(menu_item(inst, "Copy")), 5,
                   message="Copy is on ⌘V")
    finally:
        inst.cli("shortcuts", "reset")


@pytest.mark.req("L-14")
def test_a_command_cancelled_by_opening_another_palette_leaves_that_palette_alone(inst, win):
    """Round 1, P2: opening another palette while a command ran killed the command, but its completion
    then replaced the new palette with its output (or closed it)."""
    query = f"tern wait --pane {win['pane']} --pattern never-{nonce()} --timeout 20"
    inst.rpc("debug.palette", window=win["window"], mode="commands", query=query)
    started = inst.rpc("debug.palette.perform", window=win["window"], title="Run " + query, timeout=1)
    assert started.get("step") == "running", started
    inst.rpc("debug.palette", window=win["window"], mode="panes")
    time.sleep(2)   # the killed command has ended and its completion has run
    state = inst.rpc("debug.palette.state", window=win["window"])
    try:
        assert state["presented"] and state["mode"] == "panes" and state["step"] == "list", state
        assert state["entries"] and not state["output"], state
    finally:
        inst.rpc("debug.palette.close", window=win["window"])


# ---- round 2 -------------------------------------------------------------------------------------

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


@pytest.mark.req("AG-8", "AG-9")
def test_a_live_session_hidden_mid_turn_ends_and_then_delivers_what_waited(inst, win):
    """Round 2, P1: a live Claude session removed from its pane while working, with a message waiting
    for it, stayed parked for ever: its interface was only ended once nothing waited."""
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--split", "right",
                    "--pane", win["pane"], "ECHO hi")["session"]["id"]
    pane = wait_live(inst, sid)
    n = nonce()
    inst.type_line(pane, f"SLEEP 4 {n}")
    wait_until(lambda: inst.info(sid)["status"] == "working", 10, message="the typed turn runs")
    message = inst.send(sid, f"ECHO after {n}")
    inst.cli("agent", "hide", sid)
    code, out = inst.wait(sid, "--message", message, timeout=40)
    assert (code, out["status"], out.get("reply")) == (0, "DONE", f"ECHO after {n}"), out
    wait_until(lambda: inst.info(sid)["location"] == "background", 10, message="no pane any more")
    assert not inst.session_panes(sid)
    assert not inst.violations()


@pytest.mark.req("AG-8", "AG-11", "AG-18")
def test_a_typed_agent_hidden_mid_turn_is_ended_when_its_turn_ends(inst, win):
    """Round 2, P1: for an agent typed in a pane (its process knows its pane, not a session id), the pane
    was forgotten before its interface was ended, so the process was never found: it kept running while
    the session counted as headless, and a message could start a second process on the conversation."""
    root = login_fake_dir()
    plugin = os.path.join(inst.target.app, PLUGIN["claude"])
    pane = inst.cli("split", "right", "--pane", win["pane"], "--cwd", inst.work).stdout.strip()
    wait_until(lambda: inst.screen(pane).strip(), 20, message="the shell")
    known = {s["id"] for s in inst.agents()}
    inst.type_line(pane, f"FAKE_AGENT_DIR='{root}' FAKE_CLAUDE_PLUGIN_DIRS='{plugin}' '{FAKE_CLAUDE}'")
    session = wait_until(lambda: next((s for s in inst.agents() if s["id"] not in known), None), 20,
                         message="the typed agent to become a session Tern knows")
    sid, hid = session["id"], session.get("harness_id")
    try:
        wait_until(lambda: BANNER in inst.screen(pane), 20, message="its interface")
        n = nonce()
        inst.type_line(pane, f"SLEEP 3 {n}")
        wait_until(lambda: inst.info(sid)["status"] == "working", 10, message="the typed turn runs")
        pid = wait_until(lambda: next((r.get("pid") for r in read_receipts(root) if n in (r.get("text") or "")), None),
                         15, message="its process")
        inst.cli("agent", "hide", sid)
        wait_until(lambda: not alive(pid), 20, message="the interface process to end once its turn ended")
        wait_until(lambda: inst.info(sid)["location"] != "live", 10, message="the session to be headless")
        inst.send(sid, "RECALL")
        code, out = inst.wait(sid, timeout=60)
        assert out["status"] == "DONE" and f"SLEEP 3 {n}" in out["reply"], out
        assert not inst.violations()
    finally:
        inst.cli("agent", "stop", sid, check=False, timeout=60)
        hid = hid or inst.info(sid).get("harness_id")
        for path in glob.glob(os.path.join(root, "claude", f"{hid}.*")):
            os.remove(path)


def read_receipts(root):
    path = os.path.join(root, "receipts.jsonl")
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


@pytest.mark.req("AG-8", "E-3")
def test_hiding_the_last_pane_of_a_tab_keeps_its_editors_edits(inst, win):
    """Round 2, P1: a working live session removed from the only pane of its tab took the tab away, and
    with it the tab's editor and its unsaved edits."""
    started = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--tab", "--window",
                        win["window"], "ECHO hi")
    sid = started["session"]["id"]
    pane = wait_live(inst, sid)
    path = os.path.join(inst.work, f"notes-{nonce()}.md")
    with open(path, "w") as f:
        f.write("# notes\n")
    inst.cli("edit", path, "--source", "--pane", pane)
    inst.rpc("debug.editor.type", pane=pane, path=path, text="kept line\n")
    assert any(d["dirty"] for d in inst.json("editor", "ls", "--pane", pane)["documents"])
    inst.type_line(pane, f"SLEEP 3 {nonce()}")
    wait_until(lambda: inst.info(sid)["status"] == "working", 10, message="the typed turn runs")
    inst.cli("agent", "hide", sid)
    wait_until(lambda: not inst.find_pane(pane), 10, message="the pane out of sight")
    recovery = os.path.join(inst.dir, "recovery")
    wait_until(lambda: "kept line" in open(path).read()
               or any("kept line" in open(f).read() for f in glob.glob(os.path.join(recovery, "*"))), 10,
               message="the edits saved or kept as a recovery copy")


@pytest.mark.req("L-17")
def test_a_key_given_to_a_second_terminal_action_leaves_the_first(inst, win):
    """Round 2, P2: giving a terminal action a key another terminal action had been given kept both
    bindings, and the alphabetically later one won."""
    try:
        inst.cli("shortcuts", "set", "ghostty:paste_from_clipboard", "ctrl+cmd+y")
        inst.cli("shortcuts", "set", "ghostty:copy_to_clipboard", "ctrl+cmd+y")
        conf = open(os.path.join(inst.dir, "keybindings.conf")).read()
        assert "=copy_to_clipboard" in conf and "ctrl+super+y=paste_from_clipboard" not in conf, conf
        entries = {e["id"]: e for e in inst.json("shortcuts")["shortcuts"]}
        wait_until(lambda: "ctrl+super+y" in {e["id"]: e for e in inst.json("shortcuts")["shortcuts"]}
                   ["ghostty:copy_to_clipboard"]["keys"], 5, message="Copy has the key")
        assert "ctrl+super+y" not in {e["id"]: e for e in inst.json("shortcuts")["shortcuts"]}[
            "ghostty:paste_from_clipboard"]["keys"], entries
    finally:
        inst.cli("shortcuts", "reset")


@pytest.mark.req("L-17")
def test_resetting_a_shortcut_takes_its_key_back(inst, win):
    """Round 2, P2: resetting one shortcut restored its default key without taking that key from the item
    that had been given it meanwhile, so two items had the same key."""
    try:
        inst.cli("shortcuts", "set", "tab.next", "cmd+p")
        assert menu_item(inst, "Command Palette…")["key"] == ""
        inst.cli("shortcuts", "reset", "view.palette")
        palette, nxt = menu_item(inst, "Command Palette…"), menu_item(inst, "Show Next Tab")
        assert (palette["key"], palette["modifiers"]) == ("p", ["cmd"]), palette
        assert not (nxt["key"] == "p" and nxt["modifiers"] == ["cmd"]), nxt
    finally:
        inst.cli("shortcuts", "reset")


@pytest.mark.req("AG-18")
@pytest.mark.parametrize("kind", ["claude", "codex"])
def test_hooks_run_from_a_plugin_folder_whose_path_has_spaces(inst, kind, tmp_path):
    """Round 2, P2: the hook commands didn't quote the plugin's folder, so a folder with a space in its
    path split the command and no hook ran."""
    root = tmp_path / "plugin copy" / kind
    shutil.copytree(os.path.join(inst.target.app, PLUGIN[kind]), root)
    calls = tmp_path / "calls.txt"
    cli = tmp_path / "fake tern"
    cli.write_text(f"#!/bin/sh\necho \"$@\" >> '{calls}'\n")
    cli.chmod(0o755)
    variable = "CLAUDE_PLUGIN_ROOT" if kind == "claude" else "PLUGIN_ROOT"
    hooks = json.load(open(root / "hooks" / "hooks.json"))["hooks"]
    env = {k: v for k, v in os.environ.items() if not k.startswith("TERN_")}
    env.update({"TERN_CLI": str(cli), "TERN_STATE_DIR": str(tmp_path), variable: str(root)})
    events = []
    for event, groups in hooks.items():
        for group in groups:
            for hook in group["hooks"]:
                command = hook["command"].replace("${" + variable + "}", str(root))
                subprocess.run(["/bin/sh", "-c", command], input=b"{}", env=env, timeout=10, check=True)
                events.append(event)
    ran = calls.read_text().splitlines() if calls.exists() else []
    assert len(ran) == len(events) and all(f"agent hook {e} --agent {kind}" in line for e, line in zip(events, ran)), ran


# ---- round 3 -------------------------------------------------------------------------------------

@pytest.mark.req("AG-23", "AG-15")
def test_a_codex_server_that_stops_reading_blocks_no_other_session(inst, win):
    """Round 3, P1: messages were written to Codex's socket on the queue every session shares; a server
    that stopped reading (here: hung) with a large message waiting blocked every agent command."""
    stuck = inst.start_agent("codex", f"HANG {nonce()}", name=f"stuck-{nonce()}")
    wait_until(lambda: inst.info(stuck)["status"] == "working", 15, message="the turn hangs")
    big = "ECHO " + ("x" * 1024 * 1024)
    began = time.time()
    inst.cli("agent", "send", stuck, "-", stdin=big, timeout=30)
    assert time.time() - began < 10, "sending to a server that doesn't read held the caller"
    began = time.time()
    inst.agents()
    assert time.time() - began < 5, "`agent ls` waited on another session's socket"
    other = inst.start_agent("claude", f"ECHO meanwhile {nonce()}")
    code, out = inst.wait(other, timeout=30)
    assert out["status"] == "DONE", out
    inst.cli("agent", "stop", stuck, timeout=60)
    wait_until(lambda: inst.info(stuck)["status"] == "stopped", 30, message="the stuck session stops")


@pytest.mark.req("AG-22", "I-4")
def test_an_update_now_counts_work_in_a_live_interface(fresh):
    """Round 3, P2: installing an update now (it restarts the app) checked only headless turns; work in
    a Claude interface Tern shows live was cut off without asking for --force."""
    inst = fresh(prefix="acc-rv-update-")
    win = inst.json("window", "new", "--cwd", inst.work)
    wait_until(lambda: inst.screen(win["pane"]).strip(), 20, message="the shell")
    assert "turn" not in inst.cli("update", "--now", check=False, timeout=30).stderr, "nothing runs yet"
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--split", "right",
                    "--pane", win["pane"], "ECHO hi")["session"]["id"]
    pane = wait_live(inst, sid)
    inst.type_line(pane, f"SLEEP 8 {nonce()}")
    wait_until(lambda: inst.info(sid)["status"] == "working", 10, message="the typed turn runs")
    refused = inst.cli("update", "--now", check=False, timeout=30)
    assert refused.returncode != 0 and "1 managed-agent turn is running" in refused.stderr, (refused.returncode, refused.stderr)


@pytest.mark.req("S-3", "L-12")
def test_a_session_waiting_for_the_user_stays_reachable_after_its_pane_closes(inst, win):
    """Round 3, P2: closing the pane that showed a session waiting for approval left its mark on the
    closed pane: the Dock badge kept a stale count and ⌃⌘J (`jump`) couldn't reach the session."""
    sid = inst.start_agent("claude", "ASK_PERMISSION")
    wait_until(lambda: inst.info(sid)["status"] == "needs_input", 15, message="it asks")
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_until(lambda: (inst.rpc("debug.ui.attention")["panes"].get(pane) or {}).get("mark") == "needs_you", 10,
               message="the pane shows that it needs the user")
    inst.cli("pane", "close", pane)
    wait_until(lambda: pane not in inst.rpc("debug.ui.attention")["panes"], 10, message="the closed pane's mark goes")
    assert inst.rpc("debug.ui.attention")["needing_you"] >= 1
    jumped = inst.json("jump")
    shown = inst.session_panes(sid)
    assert jumped.get("session") == sid or (shown and jumped.get("pane") in [p["id"] for p in shown]), (jumped, shown)
    inst.cli("agent", "stop", sid, check=False)


@pytest.mark.req("L-14", "L-2")
def test_rename_tab_from_the_palette_with_an_empty_name_clears_it(inst, win):
    """Round 3, P2: the palette's Rename Tab says an empty name names the tab after its folder, but an
    empty answer was refused (and would have been dropped from the command line)."""
    inst.cli("tab", "rename", win["tab"], "named-for-now")
    inst.cli("pane", "focus", win["pane"])
    inst.rpc("debug.palette", window=win["window"], mode="commands", query="rename tab")
    result = inst.rpc("debug.palette.perform", window=win["window"], title="Rename Tab…", answers=[""])
    assert not result.get("failed"), result
    tab = next(t for w in inst.tree()["windows"] for t in w["tabs"] if t["id"] == win["tab"])
    assert not tab.get("name"), tab
    inst.rpc("debug.palette.close", window=win["window"])


@pytest.mark.req("AG-23", "T-5")
def test_a_large_message_is_quick_to_send_and_list(inst, win):
    """Found while testing round 3: a 4 MB message took 17 s to send and made `agent ls` take 14 s, because
    the control connection looked for the end of a request from its start again after every read."""
    sid = inst.start_agent("codex", f"ECHO warm {nonce()}")
    inst.wait(sid)
    big = "ECHO " + ("x" * 4 * 1024 * 1024)
    began = time.time()
    message = inst.cli("agent", "send", sid, "-", stdin=big, timeout=60).stdout.strip()
    assert time.time() - began < 5, f"sending 4 MB took {time.time() - began:.1f} s"
    began = time.time()
    inst.agents()
    assert time.time() - began < 5, f"`agent ls` took {time.time() - began:.1f} s"
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert out["status"] == "DONE" and len(out["reply"]) == len(big), (out["status"], len(out.get("reply") or ""))


# ---- round 4 -------------------------------------------------------------------------------------

def tab_frames(inst, tab_id):
    for w in inst.tree()["windows"]:
        for t in w["tabs"]:
            if t["id"] == tab_id:
                return {p["id"]: p["frame"] for p in t["panes"]}
    return {}


@pytest.mark.req("AG-11", "AG-6", "L-20")
def test_a_live_pane_closed_then_shown_elsewhere_leaves_one_interface(inst, win):
    """Round 4, P1: a closed pane's program is kept for 60 s so ⇧⌘T can bring it back. Showing its live
    session in another pane meanwhile moved the session there with its interface still running in the
    closed pane, and Take Over started a second interface on the same conversation."""
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--split", "right",
                    "--pane", win["pane"], "ECHO hi")["session"]["id"]
    old = wait_live(inst, sid)
    n = nonce()
    inst.type_line(old, f"ECHO marker {n}")
    pid = wait_until(lambda: next((r.get("pid") for r in inst.receipts() if n in (r.get("text") or "")), None), 15,
                     message="the interface's process")
    inst.cli("pane", "close", old)
    wait_until(lambda: not inst.find_pane(old), 5, message="the pane closes")
    assert alive(pid), "a closed pane's program is kept for reopening"
    pane = inst.json("agent", "open", sid, "--split", "down", "--pane", win["pane"], "--live")["pane"]
    wait_until(lambda: not alive(pid), 15, message="the interface left in the closed pane to end")
    assert wait_live(inst, sid) == pane
    assert not inst.violations()


@pytest.mark.req("AG-9")
def test_a_draft_deleted_with_backspace_lets_a_waiting_message_go(inst, win):
    """Round 4, P2: every key counted as typed text, so text typed and then deleted with Backspace kept
    holding messages back."""
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--split", "right",
                    "--pane", win["pane"], "ECHO hi")["session"]["id"]
    pane = wait_live(inst, sid)
    inst.cli("send", "--pane", pane, "abc")
    n = nonce()
    message = inst.send(sid, f"ECHO after the draft {n}")
    time.sleep(4)
    assert not [r for r in inst.receipts() if n in (r.get("text") or "")], "delivered under the draft"
    inst.cli("keys", "--pane", pane, "backspace", "backspace", "backspace")
    code, out = inst.wait(sid, "--message", message, timeout=40)
    assert (code, out.get("reply")) == (0, f"ECHO after the draft {n}"), out


@pytest.mark.req("AG-9")
def test_ctrl_c_on_an_idle_prompt_lets_a_waiting_message_go(inst, win):
    """Round 4, P2: Ctrl-C at an idle prompt cleared the draft but nothing then delivered the message
    that waited for it."""
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--split", "right",
                    "--pane", win["pane"], "ECHO hi")["session"]["id"]
    pane = wait_live(inst, sid)
    inst.cli("send", "--pane", pane, "half a thought")
    n = nonce()
    message = inst.send(sid, f"ECHO after ctrl-c {n}")
    time.sleep(4)
    assert not [r for r in inst.receipts() if n in (r.get("text") or "")], "delivered under the draft"
    inst.cli("keys", "--pane", pane, "ctrl+c")
    code, out = inst.wait(sid, "--message", message, timeout=40)
    assert (code, out.get("reply")) == (0, f"ECHO after ctrl-c {n}"), out


@pytest.mark.req("L-20", "L-19")
def test_reopening_a_pane_keeps_a_resize_made_after_the_close(inst, win):
    """Round 4, P2: reopening a pane restored the whole tab as it was before the close when its
    structure hadn't changed, undoing a resize made since."""
    a = win["pane"]
    b = inst.cli("split", "right", "--pane", a).stdout.strip()
    c = inst.cli("split", "right", "--pane", b).stdout.strip()
    inst.cli("pane", "close", b)
    wait_until(lambda: not inst.find_pane(b), 5, message="closed")
    inst.cli("pane", "resize", a, "right", "20")
    resized = tab_frames(inst, win["tab"])
    share = resized[a]["width"] / (resized[a]["width"] + resized[c]["width"])
    assert share > 0.55, resized
    inst.json("reopen")
    after = tab_frames(inst, win["tab"])
    assert set(after) == {a, b, c}
    assert after[a]["width"] / after[c]["width"] > 1.1, f"the resize was undone: {after}"


# ---- found while running the suite with the screen locked ---------------------------------------

@pytest.mark.req("AG-23", "R-6", "L-8")
def test_many_windows_opened_while_the_screen_is_locked_leave_the_app_responsive(fresh):
    """With the screen locked (or the display asleep) AppKit's window-opening animation never ends, and
    each window opened then kept a worker thread waiting for ever. After 64 of them the shared thread
    pool was gone and every agent command stalled. (On an unlocked screen this passes either way.)"""
    inst = fresh(prefix="acc-rv-windows-")
    for _ in range(70):
        w = inst.json("window", "new")
        inst.cli("window", "close", w["window"])
    sid = inst.start_agent("claude", f"ECHO still answering {nonce()}")
    code, out = inst.wait(sid, timeout=30)
    assert out["status"] == "DONE", out


# ---- round 5 -------------------------------------------------------------------------------------

def live_claude(inst, win, *extra):
    sid = inst.json("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), *extra, "--split", "right",
                    "--pane", win["pane"], "ECHO hi")["session"]["id"]
    return sid, wait_live(inst, sid)


@pytest.mark.req("AG-11", "AG-10")
def test_resume_of_a_live_session_starts_no_second_process(inst, win):
    """Round 5, P1: `agent resume` launched the headless process directly, beside a Claude interface that
    owned the conversation."""
    sid, pane = live_claude(inst, win)
    inst.cli("agent", "resume", sid)
    time.sleep(3)
    assert inst.info(sid)["location"] == "live" and not inst.violations()
    n = nonce()
    inst.cli("agent", "resume", sid, f"ECHO resumed {n}")
    wait_until(lambda: [r for r in inst.receipts() if n in (r.get("text") or "")], 30, message="the message delivered")
    wait_live(inst, sid)
    assert len([r for r in inst.receipts() if n in (r.get("text") or "")]) == 1
    assert not inst.violations()


@pytest.mark.req("AG-15")
def test_removing_a_working_live_session_needs_force(inst, win):
    """Round 5, P2: `agent rm` checked only Tern's headless process, so a Claude interface at work was
    removed (and ended) without --force."""
    sid, pane = live_claude(inst, win)
    inst.type_line(pane, f"SLEEP 20 {nonce()}")
    wait_until(lambda: inst.info(sid)["status"] == "working", 10, message="the typed turn runs")
    refused = inst.cli("agent", "rm", sid, check=False)
    assert refused.returncode != 0 and "--force" in refused.stderr, refused.stderr
    assert inst.info(sid)["status"] == "working"
    inst.cli("agent", "rm", sid, "--force")


@pytest.mark.req("AG-15", "AG-16")
def test_a_live_sessions_name_is_not_taken_by_another(inst, win):
    """Round 5, P2: a name was reserved only for sessions starting or working, so an idle Claude interface
    lost its name to a new session, and commands by name reached the newcomer."""
    name = f"keeper-{nonce()}"
    sid, pane = live_claude(inst, win, "--name", name)
    clash = inst.cli("agent", "start", "claude", "--cwd", inst.work, *fake_args(inst), "--name", name, "ECHO x",
                     check=False)
    assert clash.returncode != 0 and name in clash.stderr, clash.stderr
    assert inst.info(name)["id"] == sid


@pytest.mark.req("AG-6", "AG-5")
def test_a_take_over_that_fails_leaves_the_read_only_view(inst, win):
    """Round 5, P2: when the session couldn't go live (its Codex wouldn't start), the pane kept the mark
    Take Over had set and showed a bare shell instead of the session with its Take Over button."""
    sid = inst.json("agent", "start", "codex", "--cwd", inst.work, *fake_args(inst), "ECHO first", "--",
                    "--listen", "stdio://")["session"]["id"]
    wait_until(lambda: inst.info(sid)["status"] == "error", 30, message="Codex fails to start")
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_until(lambda: inst.session_view(pane).get("showing") == "agent", 10, message="the read-only view")
    inst.json("agent", "open", sid, "--live")
    wait_until(lambda: "couldn't start" in inst.screen(pane).lower() or "error" in inst.screen(pane).lower(), 70,
               message="the attach command reports the failure")
    view = wait_until(lambda: (lambda v: v if v.get("showing") == "agent" and "Take Over" in v.get("buttons", []) else None)(
        inst.session_view(pane)), 10, message="the read-only view with its Take Over button again")
    assert view["session"] == sid


# ---- round 6 -------------------------------------------------------------------------------------

@pytest.mark.req("AG-11", "AG-22")
def test_a_steered_claude_message_the_crash_kept_from_claude_is_sent_again(fresh):
    """Round 6, P1: after a crash of the product, a message written to Claude while it worked (steered,
    not yet taken in) was counted as delivered without looking at Claude's transcript, so it was never
    delivered."""
    other = fresh(prefix="acc-rv-steer-crash-")
    sid = other.start_agent("claude", f"SLEEP 8 {nonce()}")
    wait_until(lambda: [i for i in other.transcript(sid) if i["kind"] == "tool"], 15, message="the tool runs")
    n = nonce()
    message = other.send(sid, f"ECHO steered {n}")
    time.sleep(1)
    assert not [r for r in other.receipts() if n in (r.get("text") or "")], "taken in before the tool step ended"
    other.kill_everything()
    other.start_app()
    wait_until(lambda: [r for r in other.receipts() if n in (r.get("text") or "")], 60, message="the message delivered")
    code, out = other.wait(sid, "--message", message, timeout=60)
    assert out["status"] == "DONE", out
    assert len([r for r in other.receipts() if n in (r.get("text") or "")]) == 1


@pytest.mark.req("AG-22", "AG-7")
def test_a_turn_running_in_the_interface_continues_after_a_quit(target, fresh):
    """Round 6, P1: a turn the user started in Claude's own interface wasn't recorded, so a quit cut it
    off for good (headless turns continue by themselves after the restart)."""
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build")
    other = fresh(prefix="acc-rv-live-quit-", restore=True)
    sid = other.json("agent", "start", "claude", "--cwd", other.work, *fake_args(other), "--tab", "ECHO hi")["session"]["id"]
    pane = wait_live(other, sid)
    other.type_line(pane, f"SLEEP 30 {nonce()}")
    wait_until(lambda: other.info(sid)["status"] == "working", 10, message="the typed turn runs")
    other.quit_gracefully(timeout=60)
    other.start_app()
    wait_until(lambda: [r for r in other.receipts() if "previous turn was cut off" in (r.get("text") or "")], 60,
               message="the cut-off turn continues")
    assert not other.violations()


@pytest.mark.req("AG-15", "AG-18")
def test_stopping_a_typed_agent_ends_what_it_started(inst, win):
    """Round 6, P1: stopping an agent typed in a pane ended only its process; what it had started (here a
    detached child that ignores SIGTERM) carries no session id and kept running."""
    root = login_fake_dir()
    plugin = os.path.join(inst.target.app, PLUGIN["claude"])
    pane = inst.cli("split", "right", "--pane", win["pane"], "--cwd", inst.work).stdout.strip()
    wait_until(lambda: inst.screen(pane).strip(), 20, message="the shell")
    known = {s["id"] for s in inst.agents()}
    inst.type_line(pane, f"FAKE_AGENT_DIR='{root}' FAKE_CLAUDE_PLUGIN_DIRS='{plugin}' '{FAKE_CLAUDE}'")
    session = wait_until(lambda: next((s for s in inst.agents() if s["id"] not in known), None), 20,
                         message="the typed agent to become a session Tern knows")
    sid, hid = session["id"], session.get("harness_id")
    stubborn_file = os.path.join(root, "stubborn.pid")
    if os.path.exists(stubborn_file):
        os.remove(stubborn_file)
    try:
        wait_until(lambda: BANNER in inst.screen(pane), 20, message="its interface")
        inst.type_line(pane, "SPAWN_STUBBORN")
        stubborn = wait_until(lambda: os.path.exists(stubborn_file) and int(open(stubborn_file).read().strip() or 0), 15,
                              message="the detached child")
        assert alive(stubborn)
        inst.cli("agent", "stop", sid, timeout=60)
        wait_until(lambda: not alive(stubborn), 15, message="what the agent started to end with it")
    finally:
        if os.path.exists(stubborn_file):
            try:
                os.kill(int(open(stubborn_file).read().strip()), 9)
            except (OSError, ValueError):
                pass
        hid = hid or inst.info(sid).get("harness_id")
        for path in glob.glob(os.path.join(root, "claude", f"{hid}.*")):
            os.remove(path)


@pytest.mark.req("AG-12", "AG-19")
def test_a_failed_turn_in_the_interface_is_not_reported_done(inst, win):
    """Round 6, P2: when a turn in Claude's own interface failed (StopFailure), `agent wait` said DONE with
    the reply of an earlier turn."""
    sid, pane = live_claude(inst, win)
    inst.type_line(pane, f"FAIL {nonce()}")
    wait_until(lambda: inst.info(sid)["status"] == "idle" and any(i["kind"] == "error" for i in inst.transcript(sid)), 15,
               message="the failed turn ends")
    code, out = inst.wait(sid, timeout=20)
    assert (code, out["status"]) == (3, "FAILED") and out.get("error"), (code, out)
    inst.type_line(pane, f"ECHO fine again {nonce()}")
    wait_until(lambda: any(i["kind"] == "assistant" and "fine again" in (i.get("text") or "") for i in inst.transcript(sid)),
               15, message="the next turn")
    code, out = inst.wait(sid, timeout=20)
    assert (code, out["status"]) == (0, "DONE"), out
