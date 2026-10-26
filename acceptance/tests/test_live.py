"""Sessions in panes: the read-only view and the agents' own interfaces (SPEC AG-2, AG-5 to AG-9,
AG-18, AG-19), against the fake harnesses' TUI ("live") modes.

"Live" is the agent's own interface running in a pane on the session's conversation. With the fakes it
is their line-oriented TUI (fakes/README.md): `umi read --pane P` shows it and `umi send --pane P
--enter TEXT` types into it, as a person would. The read-only view is read and pressed through Umi's
internal `debug.agent.pane` / `debug.agent.press` methods (the same code its buttons run), so these
tests need no accessibility permission; the few `ui` tests that need the real keyboard say so.

Every test also checks that no conversation ever ran in two processes at once (the fakes log that to
`violations.log`).
"""

import glob
import json
import os
import pwd
import subprocess
import threading
import time

import pytest

from harness import FAKE_CLAUDE, FAKE_CODEX, alive, frontmost_pid, wait_until
from test_sessions import delivered_once, fake_args, nonce, receipts_with, status, wait_status

pytestmark = [pytest.mark.live, pytest.mark.harness]

KINDS = ["claude", "codex"]
BANNER = {"claude": "Fake Claude Code", "codex": "Fake Codex"}
USER = {"claude": "> ", "codex": "› "}       # how each fake's TUI shows a user message
REPLY = {"claude": "⏺ ", "codex": "• "}      # ... and a reply
ASKING_MODE = {"claude": "default", "codex": "on-request"}
PERMISSION_TRIGGER = {"claude": "ASK_PERMISSION", "codex": "ASK_APPROVAL"}


# ---- helpers ---------------------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def one_process_per_conversation(inst):
    """No conversation ever runs in two agent processes at once (a headless one and a live one)."""
    before = len(inst.violations())
    yield
    after = inst.violations()
    assert len(after) == before, f"two processes ran one conversation: {after[before:]}"


@pytest.fixture
def shown(inst):
    """Start sessions with a placement (or headless, then shown); all stopped afterwards."""
    ids = []

    def start(kind, prompt, *placement, env=None, name=None, inst_=None):
        target = inst_ or inst
        args = ["agent", "start", kind, "--cwd", target.work, *fake_args(target), "--name", name or f"{kind}-{nonce()}"]
        for key, value in (env or {}).items():
            args += ["--env", f"{key}={value}"]
        if prompt is not None:
            args.append(prompt)
        result = target.json(*args, *placement)
        ids.append((target, result["session"]["id"]))
        return result["session"]["id"], result.get("pane")

    start.ids = ids
    yield start
    for target, sid in ids:
        target.cli("agent", "stop", sid, check=False, timeout=60)


def screen(inst, pane):
    return inst.screen(pane, scrollback=True)


def wait_screen(inst, pane, *texts, timeout=20):
    return wait_until(lambda: all(t in screen(inst, pane) for t in texts) and screen(inst, pane), timeout,
                      message=f"the pane to show {texts}")


def wait_live(inst, sid, kind, timeout=30):
    """The session is live: listed so, and its own interface runs in its pane. Its pane."""
    wait_until(lambda: inst.info(sid)["location"] == "live", timeout, message="the session to be live")
    pane = inst.info(sid)["pane"]
    wait_screen(inst, pane, BANNER[kind], timeout=timeout)
    wait_until(lambda: inst.session_view(pane)["showing"] == "live", 10, message="the pane to show the interface")
    return pane


def wait_view(inst, pane, timeout=20):
    """The pane shows the session's read-only view."""
    return wait_until(lambda: (lambda v: v if v.get("showing") == "agent" else None)(inst.session_view(pane)),
                      timeout, message="the read-only view")


def interface_pid(inst, marker):
    """The process (the agent's own interface) that received the message carrying `marker`."""
    return wait_until(lambda: (receipts_with(inst, marker) or [{}])[0].get("pid"), 15, message="its process")


def focus_state(inst, window):
    w = next(x for x in inst.tree()["windows"] if x["id"] == window)
    tab = next(t for t in w["tabs"] if t["id"] == w["selected_tab"])
    return w["selected_tab"], tab["focused_pane"]


def go_live(inst, shown, win, kind, prompt=None, env=None, name=None):
    """An interactive launch in a split next to the test's pane, live once its first turn is done."""
    n = nonce()
    sid, pane = shown(kind, prompt or f"ECHO hello {n}", "--split", "right", "--pane", win["pane"], env=env, name=name)
    assert inst.wait(sid)[1]["status"] == "DONE"
    assert wait_live(inst, sid, kind) == pane
    return sid, pane


# ---- AG-2: sessions the user will interact with -----------------------------------------------------

@pytest.mark.req("AG-2", "AG-5", "AG-11")
@pytest.mark.parametrize("kind", KINDS)
def test_an_interactive_launch_goes_live_after_its_first_turn(inst, win, shown, kind):
    n = nonce()
    inst.cli("pane", "focus", win["pane"])
    focus = focus_state(inst, win["window"])
    sid, pane = shown(kind, f"SLEEP 3 {n}", "--split", "right", "--pane", win["pane"])
    assert pane and inst.find_pane(pane)[1]["id"] == win["tab"]
    # Meanwhile the place shows the read-only view, and the turn runs headless.
    view = wait_view(inst, pane)
    assert view["session"] == sid
    wait_until(lambda: f"SLEEP 3 {n}" in inst.session_view(pane).get("transcript", ""), 10,
               message="the view to show the prompt")
    info = inst.info(sid)
    if info.get("last_message", {}).get("state") != "done":
        assert info["location"] == "pane" and info["pane"] == pane and info["status"] in ("starting", "working"), info
    # The interface comes only after the first turn: whenever it is on screen, that turn has ended.
    # ("starting" also covers opening the interface once the turn is over, so the status alone
    # can't say which side of the turn's end the screen was read on.)
    if BANNER[kind] in screen(inst, pane):
        after = inst.info(sid)
        assert after.get("last_message", {}).get("state") == "done", \
            f"the interface ran before the first turn finished: {after}"
    code, out = inst.wait(sid)
    assert (code, out["status"]) == (0, "DONE"), out
    # Then it's resumed live in that place, on the same conversation.
    assert wait_live(inst, sid, kind) == pane
    hid = inst.info(sid)["harness_id"]
    text = wait_screen(inst, pane, hid, f"{USER[kind]}SLEEP 3 {n}", f"ok: SLEEP 3 {n}")
    assert text.count(BANNER[kind]) == 1
    delivered_once(inst, n)
    # The interface draws its screen before its own SessionStart hook reaches Umi (the hook runs
    # `umi agent hook`, a process of its own): until then the session is still opening its interface.
    info = wait_until(lambda: (lambda i: i if (i["location"], i["status"]) == ("live", "idle") else None)(inst.info(sid)),
                      15, message="the live session to report idle")
    assert info["activity"] == "idle", info
    assert focus_state(inst, win["window"]) == focus, "the user's focus moved"


@pytest.mark.req("AG-2")
def test_placements(inst, win, shown):
    a, pa = shown("codex", "ECHO tab", "--tab", "--window", win["window"])
    w, t, _ = inst.find_pane(pa)
    assert w["id"] == win["window"] and t["id"] != win["tab"] and len(t["panes"]) == 1
    b, pb = shown("claude", "ECHO split", "--split", "down", "--pane", win["pane"])
    assert inst.find_pane(pb)[1]["id"] == win["tab"]
    before = {x["id"] for x in inst.tree()["windows"]}
    c, pc = shown("codex", "ECHO window", "--new-window")
    w, _, _ = inst.find_pane(pc)
    assert w["id"] not in before and len(w["tabs"]) == 1
    for sid, pane, kind in ((a, pa, "codex"), (b, pb, "claude"), (c, pc, "codex")):
        assert inst.wait(sid)[1]["status"] == "DONE"
        assert wait_live(inst, sid, kind) == pane


@pytest.mark.req("AG-2", "L-8")
def test_the_users_focus_moves_only_when_asked(inst, win, shown):
    inst.cli("pane", "focus", win["pane"])
    time.sleep(0.5)
    front_before = frontmost_pid()
    samples, stop = [], threading.Event()

    def sample():
        while not stop.is_set():
            try:
                samples.append(focus_state(inst, win["window"]))
            except Exception:  # noqa: BLE001
                pass

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    time.sleep(0.3)
    a, _ = shown("claude", "ECHO quietly", "--tab", "--window", win["window"])
    b, _ = shown("codex", "ECHO quietly beside", "--split", "right", "--pane", win["pane"])
    for sid, kind in ((a, "claude"), (b, "codex")):
        inst.wait(sid)
        wait_live(inst, sid, kind)
    time.sleep(1.0)
    stop.set()
    thread.join(5)
    moved = [s for s in samples if s != (win["tab"], win["pane"])]
    assert samples and not moved, f"a launch without --focus moved the user's focus: {moved[:3]}"
    if front_before is not None and front_before != inst.app_pid:
        assert frontmost_pid() == front_before, "a launch without --focus brought the app to the front"
    # --focus switches to it.
    c, pc = shown("codex", "ECHO here", "--tab", "--window", win["window"], "--focus")
    wait_until(lambda: inst.json("ls")["current_pane"] == pc, 10, message="--focus to switch to the new pane")


@pytest.mark.req("AG-2")
@pytest.mark.parametrize("kind", KINDS)
def test_the_claude_and_codex_shortcuts_give_the_user_a_session(inst, win, shown, kind):
    """`umi claude "TASK"` / `umi codex "TASK"`: the task headless in a new tab, switched to, then live
    there; without a task, live at once."""
    n = nonce()
    inst.cli("pane", "focus", win["pane"])
    result = inst.json(kind, f"ECHO shortcut {n}", "--cwd", inst.work, *fake_args(inst))
    sid, pane = result["session"]["id"], result["pane"]
    shown.ids.append((inst, sid))
    assert inst.find_pane(pane)[1]["id"] != win["tab"], "a new tab"
    wait_until(lambda: inst.json("ls")["current_pane"] == pane, 10, message="switched to")
    assert inst.wait(sid)[1]["status"] == "DONE"
    wait_live(inst, sid, kind)
    wait_screen(inst, pane, f"ECHO shortcut {n}")
    result = inst.json(kind, "--cwd", inst.work, *fake_args(inst))
    bare, bare_pane = result["session"]["id"], result["pane"]
    shown.ids.append((inst, bare))
    assert wait_live(inst, bare, kind) == bare_pane
    m = nonce()
    inst.type_line(bare_pane, f"ECHO typed {m}")
    delivered_once(inst, m, timeout=15)


@pytest.mark.req("AG-1", "AG-2")
@pytest.mark.parametrize("flags", [["--tab"], ["--split"], ["--split", "down"], ["--new-window"], ["--focus"]])
def test_placement_options_never_swallow_the_prompt(inst, shown, flags):
    n = nonce()
    sid, pane = shown("codex", f"ECHO placed {n}", *flags)
    assert pane, f"{flags} didn't show the session"
    code, out = inst.wait(sid)
    assert (out["status"], out["reply"]) == ("DONE", f"ECHO placed {n}"), out
    win = inst.find_pane(pane)[0]["id"]
    if flags == ["--new-window"]:
        inst.cli("window", "close", win, check=False)


@pytest.mark.req("AG-1", "AG-2")
def test_any_placement_option_shows_the_session_and_none_shows_nothing(inst, win, shown):
    """`--focus` alone or `--window W` alone asks for a pane (a new tab); no option at all, or
    `--background`, shows nothing."""
    inst.cli("pane", "focus", win["pane"])
    focused, pane = shown("codex", "ECHO focused", "--focus")
    assert pane and inst.find_pane(pane)[1]["id"] != win["tab"]
    wait_until(lambda: inst.json("ls")["current_pane"] == pane, 10, message="--focus to switch to it")
    inst.cli("pane", "focus", win["pane"])
    placed, pane = shown("codex", "ECHO placed", "--window", win["window"])
    assert pane and inst.find_pane(pane)[0]["id"] == win["window"]
    time.sleep(0.5)
    assert inst.json("ls")["current_pane"] == win["pane"]
    for options in ([], ["--background"]):
        hidden, pane = shown("codex", "ECHO hidden", *options)
        assert inst.wait(hidden)[1]["status"] == "DONE"
        assert pane is None and not inst.session_panes(hidden)


@pytest.mark.req("AG-2", "AG-3", "L-4")
def test_a_placement_that_names_nothing_fails_and_starts_nothing(inst):
    name = "bad-place-" + nonce()
    proc = inst.cli("agent", "start", "claude", "--split", "--pane", "no-such-pane-" + nonce(), "--name", name,
                    *fake_args(inst), "ECHO hi", check=False)
    assert proc.returncode == 1 and proc.stderr.strip(), proc.stdout + proc.stderr
    assert not [s for s in inst.agents() if s["name"] == name], "a session started anyway"


# ---- AG-5: the read-only view ----------------------------------------------------------------------

@pytest.mark.req("AG-5", "AG-14")
@pytest.mark.parametrize("kind", KINDS)
def test_a_headless_session_appears_only_when_asked(inst, win, shown, kind):
    n = nonce()
    sid, pane = shown(kind, f"SLEEP 1 {n}")
    assert pane is None and not inst.session_panes(sid)
    assert inst.wait(sid)[1]["status"] == "DONE"
    assert not inst.session_panes(sid), "a headless session appeared by itself"
    inst.cli("pane", "focus", win["pane"])
    before = inst.json("ls")
    opened = inst.json("agent", "open", sid, "--window", win["window"])
    pane = opened["pane"]
    after = inst.json("ls")
    assert (after["current_tab"], after["current_pane"]) == (before["current_tab"], before["current_pane"]), \
        "`agent open` moved the focus"
    assert inst.find_pane(pane)[1]["id"] != win["tab"], "a new tab by default"
    inst.cli("pane", "focus", pane)            # the user goes to look at it
    view = wait_view(inst, pane)
    assert view["session"] == sid
    transcript = wait_until(lambda: (lambda t: t if f"ok: SLEEP 1 {n}" in t else None)(
        inst.session_view(pane).get("transcript", "")), 10, message="the view to show the conversation")
    assert f"SLEEP 1 {n}" in transcript, "both sides of the conversation"
    assert "sleep 1" in transcript.lower(), "tool activity"
    # The view as it is now (the first look can come before its controls are built).
    assert "Take Over" in inst.session_view(pane).get("buttons", [])
    info = inst.info(sid)
    assert (info["location"], info["pane"]) == ("pane", pane), info
    assert BANNER[kind] not in screen(inst, pane), "showing a session isn't taking it over"
    # Showing it again focuses the pane it's in.
    again = inst.json("agent", "open", sid, "--focus")
    assert again["pane"] == pane and len(inst.session_panes(sid)) == 1
    wait_until(lambda: inst.json("ls")["current_pane"] == pane, 5, message="the existing pane focused")


@pytest.mark.req("AG-5", "AG-17", "AG-13")
@pytest.mark.parametrize("kind", KINDS)
def test_the_view_shows_requests_and_answers_them(inst, win, shown, kind):
    sid, _ = shown(kind, "ASK_QUESTIONS", "--permission-mode", ASKING_MODE[kind])
    assert inst.wait(sid)[0] == 2
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_view(inst, pane)

    def shown_text():
        view = inst.session_view(pane)
        return " ".join(view.get("texts", [])) + view.get("transcript", "")
    wait_until(lambda: "Favorite color?" in shown_text() and "Which size?" in shown_text(), 10,
               message="the view to show both questions")
    view = inst.session_view(pane)
    # Claude's second question has options; Codex's takes free text (fakes/README.md, ASK_QUESTIONS).
    options = {"red", "blue", "S", "L"} if kind == "claude" else {"red", "blue"}
    assert options | {"Answer"} <= set(view.get("buttons", [])), view.get("buttons")
    inst.press(pane, "blue", field_text="L")   # types L into the answer fields, then picks "blue" for the first
    inst.press(pane, "Answer")
    code, out = inst.wait(sid)
    expected = ("answers: Favorite color?=blue; Which size?=L" if kind == "claude"
                else "answers: q_color=blue; q_size=L")
    assert (out["status"], out["reply"]) == ("DONE", expected), out
    inst.send(sid, PERMISSION_TRIGGER[kind])
    assert inst.wait(sid)[0] == 2
    wait_until(lambda: "Allow" in inst.session_view(pane).get("buttons", []), 10, message="the approval in the view")
    texts = " ".join(inst.session_view(pane).get("texts", []))
    assert "fake_" in texts, f"the view says exactly what would be allowed: {texts}"
    inst.press(pane, "Allow")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE" and ("allowed" if kind == "claude" else "accepted") in out["reply"], out
    assert inst.info(sid)["location"] == "pane", "answering in the view doesn't take the session over"


@pytest.mark.req("AG-5", "AG-8")
def test_a_reopened_view_shows_everything_in_order(inst, win, shown):
    secrets = ["s1-" + nonce(), "s2-" + nonce(), "s3-" + nonce()]
    sid, _ = shown("claude", "PRINTENV ACC_S1",
                   env={"ACC_S1": secrets[0], "ACC_S2": secrets[1], "ACC_S3": secrets[2]})
    inst.wait(sid)
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_view(inst, pane)
    inst.cli("agent", "hide", sid)
    wait_until(lambda: not inst.session_panes(sid), 5, message="hidden")
    for name in ("ACC_S2", "ACC_S3"):
        inst.send(sid, f"PRINTENV {name}")
        inst.wait(sid)
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]

    def ordered():
        text = inst.session_view(pane).get("transcript", "")
        positions = [text.find(s) for s in secrets]
        return all(p >= 0 for p in positions) and positions == sorted(positions)
    wait_until(ordered, 15, message="every reply shown, in order")


@pytest.mark.req("AG-5", "AG-8")
def test_closing_a_views_pane_leaves_the_session(inst, win, shown):
    sid, _ = shown("claude", "ECHO shown")
    inst.wait(sid)
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_view(inst, pane)
    inst.cli("pane", "close", pane)
    wait_until(lambda: not inst.session_panes(sid), 5, message="closed")
    info = inst.info(sid)
    assert info["status"] == "idle" and info["location"] == "background", info
    n = nonce()
    inst.send(sid, f"ECHO while hidden {n}")
    assert inst.wait(sid)[1]["reply"] == f"ECHO while hidden {n}"
    again = inst.json("agent", "open", sid, "--split", "down", "--pane", win["pane"])["pane"]
    assert inst.find_pane(again)[1]["id"] == win["tab"]
    wait_until(lambda: f"ECHO while hidden {n}" in inst.session_view(again).get("transcript", ""), 10,
               message="the view to show what happened meanwhile")


@pytest.mark.req("AG-5", "AG-2", "M-1")
@pytest.mark.parametrize("live", [False, True], ids=["view", "live"])
def test_a_sessions_pane_behaves_like_any_pane(inst, win, shown, live):
    """Split next to it, focus, zoom, swap, move to a new tab, a new window and back: the pane keeps
    showing the session (read-only, or its live interface), and the session never notices."""
    if live:
        sid, agent = go_live(inst, shown, win, "codex")
    else:
        sid, _ = shown("codex", "ECHO in a pane")
        inst.wait(sid)
        agent = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
        wait_view(inst, agent)
    _, tab, _ = inst.find_pane(agent)
    assert tab["id"] == win["tab"] and len(tab["panes"]) == 2
    new = inst.cli("split", "down", "--pane", agent).stdout.strip()
    assert not inst.json("pane", "info", new).get("agent"), "a split next to it is a plain terminal"
    marker = "PLAIN-" + nonce()
    inst.cli("send", "--pane", new, "-e", f"echo {marker}")
    inst.cli("wait", "--pane", new, "--pattern", f"^{marker}", "--timeout", "10")
    inst.cli("pane", "focus", agent)
    wait_until(lambda: inst.find_pane(agent)[1]["focused_pane"] == agent, 5, message="focused")
    inst.cli("pane", "zoom", agent)
    assert inst.json("pane", "info", agent)["zoomed"]
    inst.cli("pane", "zoom", agent)
    inst.cli("pane", "swap", agent, win["pane"])
    inst.cli("pane", "move", agent, "--new-tab")
    wait_until(lambda: inst.find_pane(agent)[1]["id"] != win["tab"], 5, message="moved to a new tab")
    inst.cli("pane", "move", agent, "--new-window")
    wait_until(lambda: inst.find_pane(agent)[0]["id"] != win["window"], 5, message="moved to a new window")
    inst.cli("pane", "move", agent, "--to", win["pane"], "--dir", "right")
    assert inst.find_pane(agent)[1]["id"] == win["tab"]
    assert [p["id"] for p in inst.session_panes(sid)] == [agent]
    assert inst.info(sid)["pane"] == agent
    assert inst.session_view(agent)["showing"] == ("live" if live else "agent")
    n = nonce()
    inst.send(sid, f"ECHO after moves {n}")
    assert inst.wait(sid)[1]["reply"] == f"ECHO after moves {n}"
    if live:
        wait_screen(inst, agent, f"• ECHO after moves {n}")
        assert screen(inst, agent).count(BANNER["codex"]) == 1, "the moves restarted the interface"


# ---- AG-6: take over -------------------------------------------------------------------------------

@pytest.mark.req("AG-6", "AG-11")
@pytest.mark.parametrize("kind", KINDS)
def test_take_over_an_idle_session(inst, win, shown, kind):
    n = nonce()
    sid, _ = shown(kind, f"ECHO before {n}")
    inst.wait(sid)
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_view(inst, pane)
    t0 = time.time()
    inst.press(pane, "Take Over")
    assert wait_live(inst, sid, kind, timeout=15) == pane
    assert time.time() - t0 < 10, f"taking over took {time.time() - t0:.0f} s"
    wait_screen(inst, pane, f"{USER[kind]}ECHO before {n}", inst.info(sid)["harness_id"])
    delivered_once(inst, n)
    m = nonce()
    inst.type_line(pane, f"ECHO typed {m}")
    delivered_once(inst, m, timeout=15)
    wait_screen(inst, pane, f"{REPLY[kind]}ECHO typed {m}")


@pytest.mark.req("AG-6", "AG-11", "AG-12")
@pytest.mark.parametrize("kind", KINDS)
def test_take_over_during_a_running_turn(inst, win, shown, kind):
    """Codex's interface continues the running turn; Claude Code's turn is interrupted. Either way
    nothing waits for the turn to end."""
    n = nonce()
    sid, _ = shown(kind, f"SLEEP {30 if kind == 'claude' else 8} {n}")
    first = inst.info(sid)["last_message"]["id"]
    delivered_once(inst, n, timeout=15)
    wait_status(inst, sid, "working")
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_view(inst, pane)
    t0 = time.time()
    inst.press(pane, "Take Over")
    assert wait_live(inst, sid, kind, timeout=15) == pane
    assert time.time() - t0 < 10, f"taking over waited {time.time() - t0:.0f} s"
    if kind == "claude":
        code, out = inst.wait(sid, "--message", first, timeout=15)
        assert (code, out["status"]) == (3, "INTERRUPTED"), out
    else:
        assert inst.info(sid)["status"] == "working", "the running turn goes on in the interface"
        code, out = inst.wait(sid, "--message", first, timeout=30)
        assert (code, out["status"], out["reply"]) == (0, "DONE", f"ok: SLEEP 8 {n}"), out
        wait_screen(inst, pane, f"{REPLY[kind]}ok: SLEEP 8 {n}")
    delivered_once(inst, n)
    assert inst.info(sid)["location"] == "live"


@pytest.mark.req("AG-6")
@pytest.mark.parametrize("kind", KINDS)
def test_open_live_takes_over_at_once(inst, win, shown, kind):
    sid, _ = shown(kind, "ECHO first")
    inst.wait(sid)
    opened = inst.json("agent", "open", sid, "--live", "--split", "right", "--pane", win["pane"])
    assert wait_live(inst, sid, kind, timeout=15) == opened["pane"]


@pytest.mark.req("AG-6", "AG-20")
def test_attach_outside_a_pane_says_what_to_do(inst, shown):
    sid, _ = shown("claude", "ECHO hi")
    inst.wait(sid)
    proc = inst.cli("agent", "attach", sid, check=False)
    assert proc.returncode != 0 and "agent open" in proc.stderr, proc.stdout + proc.stderr
    assert inst.info(sid)["location"] == "background"


# ---- AG-7: back to headless ------------------------------------------------------------------------

@pytest.mark.req("AG-7", "AG-11", "AG-14")
@pytest.mark.parametrize("kind", KINDS)
def test_quitting_the_interface_hands_the_session_back(inst, win, shown, kind):
    sid, pane = go_live(inst, shown, win, kind)
    n = nonce()
    inst.type_line(pane, f"ECHO typed {n}")
    delivered_once(inst, n, timeout=15)
    wait_screen(inst, pane, f"{REPLY[kind]}ECHO typed {n}")
    inst.type_line(pane, "/exit")
    wait_until(lambda: inst.info(sid)["location"] == "pane", 15, message="the session headless again")
    view = wait_view(inst, pane)
    assert view["session"] == sid
    wait_until(lambda: f"ECHO typed {n}" in inst.session_view(pane).get("transcript", ""), 10,
               message="the view to have what was said live")
    assert status(inst, sid) == "idle", "headless again, done for now (as AG-8 says: \"headless and idle\")"
    texts = [i.get("text") or "" for i in inst.transcript(sid)]
    assert any(f"ECHO typed {n}" == t for t in texts), "the live turn is in the transcript"
    # Headless again, with its whole conversation.
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE" and f"ECHO typed {n}" in out["reply"], out
    delivered_once(inst, n)


@pytest.mark.req("AG-6", "AG-7")
@pytest.mark.parametrize("kind", KINDS)
def test_take_over_as_soon_as_the_view_is_back(inst, win, shown, kind):
    """The Take Over button works whenever the view shows it, also right after the interface quit (its
    process may still be exiting, and the pane's shell not back at its prompt yet)."""
    sid, pane = go_live(inst, shown, win, kind)
    inst.type_line(pane, "/exit")
    wait_view(inst, pane)
    inst.press(pane, "Take Over")
    assert wait_live(inst, sid, kind, timeout=15) == pane


@pytest.mark.req("AG-7", "AG-22")
@pytest.mark.slow
def test_sessions_cut_off_by_a_quit_come_back_in_their_place(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-ag7-", restore=True)
    live = other.json("agent", "start", "claude", "--cwd", other.work, *fake_args(other), "--tab",
                      "ECHO live one")
    live_id, live_pane = live["session"]["id"], live["pane"]
    other.wait(live_id)
    wait_live(other, live_id, "claude")
    viewed = other.start_agent("codex", "ECHO viewed one")
    other.wait(viewed)
    view_pane = other.json("agent", "open", viewed)["pane"]
    wait_view(other, view_pane)
    other.quit_gracefully(timeout=60)
    other.start_app()
    wait_until(lambda: other.session_panes(live_id) and other.session_panes(viewed), 30,
               message="both sessions back in panes")
    pane = wait_live(other, live_id, "claude", timeout=60)
    wait_screen(other, pane, "> ECHO live one")
    back = other.session_panes(viewed)[0]["id"]
    wait_view(other, back)
    assert other.info(viewed)["location"] == "pane"
    assert not other.violations()


# ---- AG-8: remove from a pane ----------------------------------------------------------------------

@pytest.mark.req("AG-8", "AG-14")
@pytest.mark.parametrize("kind", KINDS)
def test_hide_removes_the_view_and_the_session_keeps_running(inst, win, shown, kind):
    n = nonce()
    sid, _ = shown(kind, f"SLEEP 4 {n}")
    delivered_once(inst, n, timeout=15)
    pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]
    wait_view(inst, pane)
    inst.cli("agent", "hide", sid)
    wait_until(lambda: not inst.find_pane(pane), 5, message="the pane to go away")
    assert not inst.session_panes(sid)
    info = inst.info(sid)
    assert info["status"] == "working" and info["location"] == "background", info
    code, out = inst.wait(sid, timeout=30)
    assert (code, out["reply"]) == (0, f"ok: SLEEP 4 {n}"), out
    time.sleep(1)
    assert not inst.session_panes(sid), "a hidden session came back by itself"


@pytest.mark.req("AG-8", "AG-13", "AG-21")
def test_hide_a_live_claude_with_a_running_turn(inst, win, shown):
    """"A live interface keeps running out of sight until its turn and any background work end; then
    the session is headless and idle.\""""
    sid, pane = go_live(inst, shown, win, "claude")
    n = nonce()
    inst.type_line(pane, f"SLEEP 5 {n}")
    pid = interface_pid(inst, n)
    wait_status(inst, sid, "working")
    tabs_before = {t["id"] for w in inst.tree()["windows"] for t in w["tabs"]}
    inst.cli("agent", "hide", sid)
    wait_until(lambda: not inst.find_pane(pane), 5, message="the pane to go away")
    assert not inst.session_panes(sid)
    assert {t["id"] for w in inst.tree()["windows"] for t in w["tabs"]} <= tabs_before, "it went somewhere else"
    assert alive(pid), "the interface was stopped instead of finishing its turn"
    assert status(inst, sid) == "working"
    wait_until(lambda: not alive(pid), 20, message="the interface to end once its turn is done")
    wait_until(lambda: status(inst, sid) != "working", 10, message="the session to be done")
    assert status(inst, sid) == "idle", f"\"then the session is headless and idle\": {inst.info(sid)}"
    info = inst.info(sid)
    assert info["location"] == "background", info
    assert any(f"ok: SLEEP 5 {n}" == (i.get("text") or "") for i in inst.transcript(sid)), "the turn finished"
    delivered_once(inst, n)
    m = nonce()
    inst.send(sid, f"ECHO later {m}")
    assert inst.wait(sid)[1]["reply"] == f"ECHO later {m}"
    assert not inst.session_panes(sid)


@pytest.mark.req("AG-8")
def test_hide_a_live_codex_with_a_running_turn(inst, win, shown):
    sid, pane = go_live(inst, shown, win, "codex")
    n = nonce()
    inst.type_line(pane, f"SLEEP 4 {n}")
    delivered_once(inst, n, timeout=15)
    wait_status(inst, sid, "working")
    inst.cli("agent", "hide", sid)
    wait_until(lambda: not inst.find_pane(pane), 5, message="the pane to go away")
    assert status(inst, sid) == "working", "the turn keeps running"
    wait_status(inst, sid, "idle", 20)
    assert any(f"ok: SLEEP 4 {n}" == (i.get("text") or "") for i in inst.transcript(sid)), "the turn finished"
    assert inst.info(sid)["location"] == "background"


# ---- AG-9: messages reach live sessions ------------------------------------------------------------

@pytest.mark.req("AG-9", "AG-11")
def test_a_message_to_live_claude_runs_headless_and_comes_back_live(inst, win, shown):
    sid, pane = go_live(inst, shown, win, "claude")
    n = nonce()
    t0 = time.time()
    message = inst.send(sid, f"SLEEP 2 {n}")
    assert time.time() - t0 < 3, "`agent send` answers at once"
    # It runs headless meanwhile, and the pane shows the read-only view.
    wait_view(inst, pane, timeout=15)
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert (code, out["reply"]) == (0, f"ok: SLEEP 2 {n}"), out
    delivered_once(inst, n)
    # Then it's live again, in the same pane, with the message in its conversation.
    assert wait_live(inst, sid, "claude") == pane
    wait_screen(inst, pane, f"> SLEEP 2 {n}", f"ok: SLEEP 2 {n}")
    m = nonce()
    inst.type_line(pane, f"ECHO after {m}")
    delivered_once(inst, m, timeout=15)


@pytest.mark.req("AG-9", "AG-11", "AG-14")
def test_a_message_to_live_claude_waits_for_its_running_turn(inst, win, shown):
    sid, pane = go_live(inst, shown, win, "claude")
    a, b = nonce(), nonce()
    inst.type_line(pane, f"SLEEP 4 {a}")
    first = delivered_once(inst, a, timeout=15)
    wait_status(inst, sid, "working")
    message = inst.send(sid, f"ECHO waiting {b}")
    info = inst.info(sid)
    assert [m["id"] for m in info.get("waiting", [])] == [message], f"`agent info` lists the waiting message: {info}"
    assert (info.get("waiting_reason") or "").strip(), "and says why it waits"
    listed = next(s for s in inst.agents() if s["id"] == sid)
    assert listed.get("waiting") and listed.get("waiting_reason"), listed
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert (code, out["reply"]) == (0, f"ECHO waiting {b}"), out
    second = delivered_once(inst, b)
    assert second["ts"] >= first["ts"] + 4, "the message reached the agent before the live turn ended"
    assert wait_live(inst, sid, "claude") == pane


@pytest.mark.req("AG-9", "AG-11")
def test_a_message_to_live_claude_waits_while_something_is_typed_in_it(inst, win, shown):
    """"When its interface is idle and the user has nothing typed in it." Text put on its prompt line
    (here with `umi send` and no Enter) must survive: the message waits instead."""
    sid, pane = go_live(inst, shown, win, "claude")
    draft = "draft-" + nonce()
    inst.cli("send", "--pane", pane, draft)
    wait_screen(inst, pane, f"> {draft}")
    n = nonce()
    message = inst.send(sid, f"ECHO held {n}")
    time.sleep(5)
    assert not receipts_with(inst, n), "the interface was ended under the user's typing"
    assert f"> {draft}" in inst.screen(pane), "what the user typed is gone"
    info = inst.info(sid)
    assert [m["id"] for m in info.get("waiting", [])] == [message] and (info.get("waiting_reason") or "").strip(), info
    inst.cli("keys", "--pane", pane, "ctrl+u")   # the user clears the line
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert (code, out["reply"]) == (0, f"ECHO held {n}"), out
    delivered_once(inst, n)


@pytest.mark.req("AG-9", "AG-10", "AG-11")
def test_a_message_to_live_codex_goes_through_at_once(inst, win, shown):
    sid, pane = go_live(inst, shown, win, "codex")
    n = nonce()
    t0 = time.time()
    message = inst.send(sid, f"ECHO direct {n}")
    receipt = delivered_once(inst, n, timeout=10)
    assert receipt["ts"] - t0 < 5, "the message waited"
    code, out = inst.wait(sid, "--message", message)
    assert (code, out["reply"]) == (0, f"ECHO direct {n}"), out
    wait_screen(inst, pane, f"› ECHO direct {n}", f"• ECHO direct {n}")
    assert inst.info(sid)["location"] == "live"
    assert screen(inst, pane).count(BANNER["codex"]) == 1, "the interface was restarted"
    # While a turn typed in the interface runs, a message steers it.
    a, b = nonce(), nonce()
    inst.type_line(pane, f"SLEEP 3 {a}")
    first = delivered_once(inst, a, timeout=15)
    wait_status(inst, sid, "working")
    message = inst.send(sid, f"ECHO steer {b}")
    code, out = inst.wait(sid, "--message", message, timeout=30)
    assert out["status"] == "DONE" and f"ECHO steer {b}" in out["reply"], out
    second = delivered_once(inst, b)
    assert second["turn"] == first["turn"], "the message didn't steer the running turn"
    assert inst.info(sid)["location"] == "live"


@pytest.mark.req("AG-15", "AG-9")
@pytest.mark.parametrize("kind", KINDS)
def test_stop_closes_a_live_interface(inst, win, shown, kind):
    sid, pane = go_live(inst, shown, win, kind)
    n = nonce()
    inst.type_line(pane, f"SLEEP 30 {n}")
    pid = interface_pid(inst, n) if kind == "claude" else None
    wait_status(inst, sid, "working")
    inst.cli("agent", "stop", sid, timeout=60)
    wait_status(inst, sid, "stopped", 15)
    if pid:
        wait_until(lambda: not alive(pid), 15, message="the interface process to end")
    wait_until(lambda: inst.info(sid)["location"] != "live", 15, message="the interface to close")
    inst.send(sid, "RECALL")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE" and f"SLEEP 30 {n}" in out["reply"], "the conversation stays resumable"


# ---- AG-18: Umi's plugins report what agents typed in a pane do ------------------------------------

PLUGIN = {"claude": "Contents/Resources/agent-plugins/claude", "codex": "Contents/Resources/agent-plugins/codex"}


def login_fake_dir():
    """Where a fake keeps its state when FAKE_AGENT_DIR isn't set, in the environment the product gives
    agents (the login shell's, whose TMPDIR is the user's temporary folder). A session found through
    the hooks is resumed headless in that environment, so the agent typed in the pane must keep its
    state there too: as the real `claude` keeps its conversations in ~/.claude wherever it runs."""
    user = pwd.getpwuid(os.getuid())
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    env = {"HOME": user.pw_dir, "USER": user.pw_name, "LOGNAME": user.pw_name, "SHELL": user.pw_shell,
           "TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": tmp}
    out = subprocess.run([user.pw_shell, "-l", "-i", "-c", "printf '\\n__TMP__%s' \"$TMPDIR\""], env=env,
                         capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL).stdout
    tmp = out.rsplit("__TMP__", 1)[-1].strip() or tmp
    return os.path.join(os.path.abspath(tmp), "fake-agent")


@pytest.mark.req("AG-18", "AG-13", "AG-14", "AG-10")
@pytest.mark.parametrize("kind", KINDS)
def test_an_agent_typed_in_a_pane_becomes_a_known_session(inst, win, kind):
    root = login_fake_dir()
    fake = {"claude": FAKE_CLAUDE, "codex": FAKE_CODEX}[kind]
    plugin = os.path.join(inst.target.app, PLUGIN[kind])
    dirs_var = "FAKE_CLAUDE_PLUGIN_DIRS" if kind == "claude" else "FAKE_CODEX_PLUGIN_DIRS"
    pane = win["pane"]
    known = {s["id"] for s in inst.agents()}
    # The user has Umi's plugin installed (`agent plugins install`) and types the agent's command.
    inst.type_line(pane, f"FAKE_AGENT_DIR='{root}' {dirs_var}='{plugin}' '{fake}'")
    session = wait_until(lambda: next((s for s in inst.agents() if s["id"] not in known), None), 20,
                         message="the typed agent to become a session Umi knows")
    sid = session["id"]
    hid = session.get("harness_id")
    try:
        wait_screen(inst, pane, BANNER[kind])
        info = inst.info(sid)
        assert (info["kind"], info["origin"], info["location"], info.get("pane")) == (kind, "typed", "live", pane), info
        assert info["status"] == "idle"
        n = nonce()
        inst.type_line(pane, f"SLEEP 2 {n}")
        wait_status(inst, sid, "working", 10)
        wait_status(inst, sid, "idle", 15)
        texts = [(i["kind"], i.get("text") or "") for i in inst.transcript(sid)]
        assert ("user", f"SLEEP 2 {n}") in texts and ("assistant", f"ok: SLEEP 2 {n}") in texts, texts
        assert any(k == "tool" for k, _ in texts), texts
        assert next(s for s in inst.agents() if s["id"] == sid)["status"] == "idle"
        inst.type_line(pane, "/exit")
        wait_until(lambda: inst.info(sid)["location"] != "live", 15, message="the interface's end to be noticed")
        assert inst.info(sid)["status"] in ("idle", "stopped"), inst.info(sid)
        # A session Umi knows: a message resumes its conversation.
        inst.send(sid, "RECALL")
        code, out = inst.wait(sid, timeout=60)
        assert out["status"] == "DONE" and f"SLEEP 2 {n}" in out["reply"], out
    finally:
        inst.cli("agent", "stop", sid, check=False, timeout=60)
        hid = hid or inst.info(sid).get("harness_id")
        for path in glob.glob(os.path.join(root, "claude", f"{hid}.*")) + \
                glob.glob(os.path.join(root, "codex", "threads", f"{hid}.*")):
            os.remove(path)


@pytest.mark.req("AG-18")
@pytest.mark.parametrize("kind", KINDS)
def test_the_plugins_hooks_are_silent_outside_umi(inst, kind, tmp_path):
    """Outside the product (another terminal, no app running, or a session Umi runs headless) Umi's
    hook prints nothing and does nothing."""
    script = os.path.join(inst.target.app, PLUGIN[kind], "hooks", "umi-hook.sh")
    assert os.access(script, os.X_OK), script
    hid = "00000000-0000-4000-8000-" + nonce() + "00"
    payload = json.dumps({"session_id": hid, "cwd": str(tmp_path), "hook_event_name": "SessionStart",
                          "transcript_path": str(tmp_path / "t.jsonl"), "source": "startup"})
    stopped_dir = str(tmp_path / "no-app")
    os.makedirs(stopped_dir)
    base = {k: v for k, v in inst.env.items() if not k.startswith("UMI_")}
    cli = inst.target.cli_path
    environments = {
        "another terminal": base,
        "a terminal of an app that isn't running": dict(base, UMI_CLI=cli, UMI_STATE_DIR=stopped_dir),
        "a session Umi runs headless": dict(base, UMI_CLI=cli, UMI_STATE_DIR=inst.dir, UMI_HEADLESS="1"),
        "Umi, but no pane of it": dict(base, UMI_CLI=cli, UMI_STATE_DIR=inst.dir),
    }
    before = {s["id"] for s in inst.agents()}
    for where, env in environments.items():
        for event in ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"):
            t0 = time.time()
            proc = subprocess.run([script, kind, event], input=payload, capture_output=True, text=True, env=env,
                                  timeout=30, cwd=str(tmp_path))
            assert (proc.returncode, proc.stdout, proc.stderr) == (0, "", ""), (where, event, proc)
            assert time.time() - t0 < 5, f"{where}: the hook made the agent wait"
        # The CLI the hook runs is silent too, whatever it's given.
        proc = subprocess.run([cli, "agent", "hook", "Stop", "--agent", kind, "--pid", "1"], input="not json",
                              capture_output=True, text=True, env=env, timeout=30)
        assert (proc.returncode, proc.stdout, proc.stderr) == (0, "", ""), (where, proc)
    assert {s["id"] for s in inst.agents()} == before, "a hook from outside a pane created a session"
    assert not any(s.get("harness_id") == hid for s in inst.agents())


# ---- AG-19: live status is truthful ----------------------------------------------------------------

@pytest.mark.req("AG-19", "AG-13")
def test_live_claude_status_is_truthful(inst, win, shown):
    sid, pane = go_live(inst, shown, win, "claude")
    n = nonce()
    inst.type_line(pane, f"SLEEP 3 {n}")
    wait_status(inst, sid, "working", 10)
    wait_status(inst, sid, "idle", 15)
    # A turn's end with background work still pending isn't "finished".
    w = nonce()
    inst.type_line(pane, f"WAKE 3 {w}")
    wait_screen(inst, pane, "⏺ started")
    time.sleep(0.5)
    seen = set()
    while not any(w in t["text"] for t in inst.self_turns()):
        seen.add(status(inst, sid))
        time.sleep(0.1)
    assert seen == {"working"}, f"with background work pending, the status was {seen}"
    wait_screen(inst, pane, f"woke: {w}")
    wait_status(inst, sid, "idle", 10)
    # Waiting on a permission prompt is needs_input.
    inst.type_line(pane, "ASK_PERMISSION")
    wait_screen(inst, pane, "Do you want to proceed?")
    wait_status(inst, sid, "needs_input", 10)
    inst.type_line(pane, "y")
    wait_screen(inst, pane, "permission allowed")
    wait_status(inst, sid, "idle", 10)
    # An interrupted turn doesn't stay "working".
    x = nonce()
    inst.type_line(pane, f"SLEEP 60 {x}")
    wait_status(inst, sid, "working", 10)
    inst.cli("keys", "--pane", pane, "esc")
    wait_screen(inst, pane, "Interrupted")
    wait_status(inst, sid, "idle", 10)


@pytest.mark.req("AG-19", "AG-13")
def test_live_codex_status_is_truthful(inst, win, shown):
    sid, pane = go_live(inst, shown, win, "codex")
    n = nonce()
    inst.type_line(pane, f"SLEEP 3 {n}")
    wait_status(inst, sid, "working", 10)
    wait_status(inst, sid, "idle", 15)
    inst.type_line(pane, "ASK_APPROVAL")
    wait_screen(inst, pane, "Allow command?")
    wait_status(inst, sid, "needs_input", 10)
    inst.type_line(pane, "y")
    wait_screen(inst, pane, "approval accepted")
    wait_status(inst, sid, "idle", 10)
    x = nonce()
    inst.type_line(pane, f"SLEEP 60 {x}")
    wait_status(inst, sid, "working", 10)
    inst.cli("keys", "--pane", pane, "esc")
    wait_screen(inst, pane, "interrupted")
    wait_status(inst, sid, "idle", 10)


# ---- through the accessibility tree (need the Accessibility permission; they take the keyboard) --------

@pytest.mark.req("AG-5")
def test_background_sessions_are_in_the_window_menu(inst, win, shown, ui):
    """Window > Agent Sessions lists sessions no pane shows, with their status; choosing one shows it in
    a pane and focuses it."""
    name = f"menu-{nonce()}"
    sid, _ = shown("codex", "ECHO listed", name=name)
    assert inst.wait(sid)[1]["status"] == "DONE"
    assert not inst.session_panes(sid)
    item = wait_until(lambda: ui.menu_item(f"{name} — "), 10, message="the session in Window > Agent Sessions")
    assert ui.label(item) == f"{name} — idle", ui.label(item)
    ui.choose(item)
    pane = wait_until(lambda: inst.session_panes(sid), 10, message="shown")[0]
    wait_until(lambda: inst.json("ls")["current_pane"] == pane["id"], 5, message="and focused")


@pytest.mark.req("AG-9")
def test_a_message_to_live_claude_waits_while_the_user_types_in_it(inst, win, shown, ui):
    """The same as the `umi send` draft test above, with the keyboard."""
    sid, pane = go_live(inst, shown, win, "claude")
    inst.cli("pane", "focus", pane)
    ui.activate()
    draft = "kb" + nonce()
    ui.type_text(draft)
    wait_screen(inst, pane, f"> {draft}")
    n = nonce()
    message = inst.send(sid, f"ECHO held {n}")
    time.sleep(5)
    assert not receipts_with(inst, n), "the interface was ended under the user's typing"
    assert f"> {draft}" in inst.screen(pane)
    for _ in draft:
        ui.key(51)                                  # backspace: the user deletes what they typed
    code, out = inst.wait(sid, "--message", message, timeout=60)
    assert (code, out["reply"]) == (0, f"ECHO held {n}"), out
