"""Managed sessions shown in the app (SPEC AP), checked through the CLI and the accessibility tree.

Nothing here assumes how a session's pane presents it. A follow-up is typed into the focused
pane like a person would; what the pane shows is read the way a screen reader reads it.
"""

import threading
import time
import uuid

import pytest

from harness import frontmost_pid, wait_until

pytestmark = [pytest.mark.panes, pytest.mark.harness]


def nonce():
    return uuid.uuid4().hex[:10]


@pytest.fixture
def started(inst):
    ids = []

    def start(kind, prompt, *placement, env=None, name=None):
        args = ["agent", "start", kind, "--cwd", inst.work, "--env", "FAKE_AGENT_DIR=" + inst.fake_dir,
                "--name", name or f"ap-{nonce()}"]
        for key, value in (env or {}).items():
            args += ["--env", f"{key}={value}"]
        sid = inst.json(*args, *placement, prompt)["session"]["id"]
        ids.append(sid)
        return sid

    start.ids = ids
    yield start
    for sid in ids:
        inst.cli("agent", "stop", sid, check=False, timeout=60)


def agent_panes(inst, sid):
    return [(w, t, p) for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"] if p.get("agent") == sid]


def shown_in(inst, sid, timeout=10):
    return wait_until(lambda: (agent_panes(inst, sid) or [None])[0], timeout, message=f"a pane showing {sid}")


def window_of(inst, window_id):
    return next(w for w in inst.tree()["windows"] if w["id"] == window_id)


# ---- AP-1: watching and stepping in -----------------------------------------------------------

@pytest.mark.req("AP-1", "MA-3")
@pytest.mark.parametrize("kind", ["claude", "codex"])
def test_follow_up_typed_into_the_pane(inst, win, ui, started, kind):
    secret = "reply-" + nonce()
    sid = started(kind, "ECHO hello", "--split", "right", "--pane", win["pane"], env={"ACC_AP": secret})
    assert inst.wait(sid)[1]["status"] == "DONE"
    _, _, pane = shown_in(inst, sid)
    inst.cli("pane", "focus", pane["id"])
    ui.activate()
    n = nonce()
    focused = ui.focused_input()
    if focused is None:
        pytest.skip("the focused agent pane takes no text through accessibility; see CHECKS.md AP-1")
    ui.enter_text(f"PRINTENV ACC_AP {n}", element=focused, replace=True)
    ui.key(ui.RETURN)
    wait_until(lambda: [r for r in inst.receipts() if n in r["text"]], 15, message="the typed follow-up reached the agent")
    assert len([r for r in inst.receipts() if n in r["text"]]) == 1
    code, out = inst.wait(sid)
    assert out["reply"] == secret
    wait_until(lambda: secret in ui.all_text(), 15, message="the reply is shown in the app")


@pytest.mark.req("AP-1", "MA-8")
def test_escape_in_the_pane_interrupts(inst, win, ui, started):
    sid = started("claude", "ECHO ready", "--split", "right", "--pane", win["pane"])
    inst.wait(sid)
    _, _, pane = shown_in(inst, sid)
    message = inst.send(sid, "SLEEP 30")
    wait_until(lambda: inst.info(sid)["status"] == "working", 10, message="working")
    inst.cli("pane", "focus", pane["id"])
    ui.activate()
    if ui.focused_input() is None:
        pytest.skip("the focused agent pane takes no keys through accessibility; see CHECKS.md AP-1")
    ui.key(ui.ESCAPE)
    code, out = inst.wait(sid, "--message", message, timeout=15)
    assert out["status"] == "INTERRUPTED", out
    assert inst.info(sid)["live"]


@pytest.mark.req("AP-1")
def test_pane_shows_status_and_pending_requests(inst, win, ui, started):
    sid = started("claude", "ASK_QUESTIONS", "--split", "right", "--pane", win["pane"])
    assert inst.wait(sid)[0] == 2
    shown_in(inst, sid)
    wait_until(lambda: "Favorite color?" in ui.all_text() and "Which size?" in ui.all_text(), 15,
               message="the pending questions are shown in the app")


# ---- AP-2: like any other pane ----------------------------------------------------------------

@pytest.mark.req("AP-2", "M-1")
def test_agent_pane_behaves_like_any_pane(inst, win, started):
    sid = started("codex", "ECHO in a pane", "--split", "right", "--pane", win["pane"])
    _, tab, agent = shown_in(inst, sid)
    assert tab["id"] == win["tab"] and len(tab["panes"]) == 2
    # Split next to it: the new pane is a plain terminal.
    new = inst.cli("split", "down", "--pane", agent["id"]).stdout.strip()
    assert not inst.json("pane", "info", new).get("agent")
    marker = "PLAIN-" + nonce()
    inst.cli("send", "--pane", new, "-e", f"echo {marker}")
    inst.cli("wait", "--pane", new, "--pattern", f"^{marker}", "--timeout", "10")
    inst.cli("pane", "focus", agent["id"])
    wait_until(lambda: inst.find_pane(agent["id"])[1]["focused_pane"] == agent["id"], 5, message="focused")
    inst.cli("pane", "zoom", agent["id"])
    assert inst.json("pane", "info", agent["id"])["zoomed"]
    inst.cli("pane", "zoom", agent["id"])
    inst.cli("pane", "swap", agent["id"], win["pane"])
    assert inst.json("pane", "info", agent["id"])["agent"] == sid
    inst.cli("pane", "move", agent["id"], "--new-tab")
    wait_until(lambda: inst.find_pane(agent["id"])[1]["id"] != win["tab"], 5, message="moved to a new tab")
    inst.cli("pane", "move", agent["id"], "--new-window")
    wait_until(lambda: inst.find_pane(agent["id"])[0]["id"] != win["window"], 5, message="moved to a new window")
    inst.cli("pane", "move", agent["id"], "--to", win["pane"], "--dir", "right")
    assert inst.find_pane(agent["id"])[1]["id"] == win["tab"]
    assert inst.json("pane", "info", agent["id"])["agent"] == sid
    assert len(agent_panes(inst, sid)) == 1
    # The session never noticed.
    n = nonce()
    inst.send(sid, f"ECHO after moves {n}")
    assert inst.wait(sid)[1]["reply"] == f"ECHO after moves {n}"


@pytest.mark.req("AP-2")
def test_undo_close_brings_the_agent_pane_back(inst, win, ui, started):
    sid = started("claude", "ECHO undo me", "--split", "right", "--pane", win["pane"])
    inst.wait(sid)
    _, _, pane = shown_in(inst, sid)
    inst.cli("pane", "close", pane["id"])
    wait_until(lambda: not agent_panes(inst, sid), 5, message="closed")
    inst.cli("pane", "focus", win["pane"])
    ui.activate()
    ui.choose(ui.menu_item("Undo"))
    _, tab, back = shown_in(inst, sid)
    assert tab["id"] == win["tab"]
    n = nonce()
    inst.send(sid, f"ECHO back {n}")
    assert inst.wait(sid)[1]["status"] == "DONE"


# ---- AP-3, AP-4: placement, focus, reopening --------------------------------------------------

@pytest.mark.req("AP-3")
def test_placements(inst, win, started):
    a = started("codex", "ECHO tab", "--tab", "--window", win["window"])
    w, t, _ = shown_in(inst, a)
    assert w["id"] == win["window"] and t["id"] != win["tab"] and len(t["panes"]) == 1
    b = started("codex", "ECHO split", "--split", "down", "--pane", win["pane"])
    assert shown_in(inst, b)[1]["id"] == win["tab"]
    before = {x["id"] for x in inst.tree()["windows"]}
    c = started("codex", "ECHO window", "--new-window")
    w, _, _ = shown_in(inst, c)
    assert w["id"] not in before and len(w["tabs"]) == 1
    d = started("codex", "ECHO hidden", "--background")
    inst.wait(d)
    assert not agent_panes(inst, d)


@pytest.mark.req("AP-3", "L-8")
def test_opening_without_focus_never_moves_the_users_focus(inst, win, started):
    inst.cli("pane", "focus", win["pane"])
    time.sleep(0.5)
    front_before = frontmost_pid()
    samples, stop = [], threading.Event()

    def sample():
        while not stop.is_set():
            try:
                tree = inst.tree()
                w = next(x for x in tree["windows"] if x["id"] == win["window"])
                tab = next(t for t in w["tabs"] if t["id"] == w["selected_tab"])
                samples.append((w["selected_tab"], tab["focused_pane"]))
            except Exception:  # noqa: BLE001
                pass

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    time.sleep(0.3)
    sid = started("claude", "ECHO quietly", "--tab", "--window", win["window"])
    other = started("claude", "ECHO quietly beside", "--split", "right", "--pane", win["pane"])
    shown_in(inst, sid)
    shown_in(inst, other)
    time.sleep(1.0)
    stop.set()
    thread.join(5)
    moved = [s for s in samples if s != (win["tab"], win["pane"])]
    assert samples and not moved, f"a non-focusing open moved the user's focus: {moved[:3]}"
    if front_before is not None and front_before != inst.app_pid:
        assert frontmost_pid() == front_before, "a non-focusing open brought the app to the front"


@pytest.mark.req("AP-3", "AP-4")
def test_open_focuses_an_existing_pane_and_reopens_a_closed_one(inst, win, started):
    sid = started("claude", "ECHO open me", "--split", "right", "--pane", win["pane"])
    inst.wait(sid)
    _, _, pane = shown_in(inst, sid)
    inst.cli("pane", "focus", win["pane"])
    inst.json("agent", "open", sid, "--focus")
    assert len(agent_panes(inst, sid)) == 1, "showing an open session again doesn't duplicate it"
    w, t, p = agent_panes(inst, sid)[0]
    wait_until(lambda: inst.find_pane(p["id"])[1]["focused_pane"] == p["id"], 5, message="focused instead")
    # Closing the pane leaves the session running; it can be shown again.
    inst.cli("pane", "close", p["id"])
    wait_until(lambda: not agent_panes(inst, sid), 5, message="closed")
    info = inst.info(sid)
    assert info["live"] and info["status"] == "idle"
    n = nonce()
    inst.send(sid, f"ECHO while hidden {n}")
    assert inst.wait(sid)[1]["status"] == "DONE"
    opened = inst.json("agent", "open", sid, "--split", "down", "--pane", win["pane"])
    assert opened["pane"]
    assert shown_in(inst, sid)[1]["id"] == win["tab"]


# ---- AP-5: complete after catching up ---------------------------------------------------------

@pytest.mark.req("AP-5")
def test_reopened_pane_shows_everything_in_order(inst, win, ui, started):
    secrets = ["s1-" + nonce(), "s2-" + nonce(), "s3-" + nonce()]
    sid = started("claude", "PRINTENV ACC_S1", "--split", "right", "--pane", win["pane"],
                  env={"ACC_S1": secrets[0], "ACC_S2": secrets[1], "ACC_S3": secrets[2]})
    inst.wait(sid)
    _, _, pane = shown_in(inst, sid)
    inst.cli("pane", "close", pane["id"])
    wait_until(lambda: not agent_panes(inst, sid), 5, message="closed")
    for name in ("ACC_S2", "ACC_S3"):
        inst.send(sid, f"PRINTENV {name}")
        inst.wait(sid)
    inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])
    shown_in(inst, sid)

    def ordered():
        text = ui.all_text()
        positions = [text.find(s) for s in secrets]
        return all(p >= 0 for p in positions) and positions == sorted(positions)
    wait_until(ordered, 15, message="every reply shown, in order")


@pytest.mark.req("AP-5", "R-3")
def test_pane_after_app_restart_shows_the_earlier_conversation(fresh, ui):
    other = fresh(prefix="acc-ap5-")
    secret = "before-restart-" + nonce()
    sid = other.json("agent", "start", "claude", "--cwd", other.work, "--env", "FAKE_AGENT_DIR=" + other.fake_dir,
                     "--env", f"ACC_SECRET={secret}", "--tab", "PRINTENV ACC_SECRET")["session"]["id"]
    other.wait(sid)
    other.quit_app()
    other.start_app()
    other.json("agent", "open", sid, "--focus")
    wait_until(lambda: other.find_agent_pane(sid), 10, message="shown after restart")
    from harness import UI
    view = UI(other.app_pid)
    wait_until(lambda: secret in view.all_text(), 15, message="the pre-restart reply is shown")


# ---- AP-9, AP-11 ------------------------------------------------------------------------------

@pytest.mark.req("AP-9", "S-2")
def test_no_new_agent_form_and_no_agents_section(inst, win, ui):
    inst.cli("sidebar", "on")
    inst.cli("sidebar", "tabs")
    time.sleep(0.5)
    labels = [ui.label(e).lower() for e, _ in ui.walk() if ui.role(e) in ("AXButton", "AXMenuButton", "AXLink")]
    assert not [label for label in labels if "new agent" in label], labels
    text = ui.all_text().lower()
    assert "no agents running" not in text


@pytest.mark.req("AP-11")
def test_agent_panes_come_back_after_restart(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = fresh(prefix="acc-ap11-", restore=True)
    sid = other.json("agent", "start", "codex", "--cwd", other.work, "--env", "FAKE_AGENT_DIR=" + other.fake_dir,
                     "--tab", "ECHO restore me")["session"]["id"]
    other.wait(sid)
    wait_until(lambda: other.find_agent_pane(sid), 10, message="shown")
    other.quit_app()
    other.start_app()
    wait_until(lambda: other.find_agent_pane(sid), 20, message="the agent pane came back by itself")
