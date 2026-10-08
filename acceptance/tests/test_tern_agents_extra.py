"""Extra tests for risks of this build's managed-agent design (phase 2).

Tern holds its own queue and hands one message at a time to a harness it owns; it finds a
session's processes by an environment tag; it decides after a crash which messages a harness
really received; and Codex's background terminals report after their turn ended. These tests
check the outcomes those choices put at risk. Black-box like the rest of the suite.
"""

import json
import os
import subprocess
import time
import uuid

import pytest

from harness import alive, wait_until
from test_managed import delivered_once, receipts_with, started  # noqa: F401 (fixture)

pytestmark = [pytest.mark.managed, pytest.mark.harness]


def nonce():
    return uuid.uuid4().hex[:10]


def self_turns(inst):
    path = os.path.join(inst.fake_dir, "self_turns.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


@pytest.mark.req("MA-26", "MA-28", "MA-7", "MA-4")
def test_codex_background_task_is_counted_and_never_a_turn(inst, started):
    """Codex runs a long command as a background terminal: its item is still open when the turn
    completes, and its completion arrives later as an item of the finished turn (X15wake). It is a
    background task, not a turn, and messages sent meanwhile get their own replies."""
    n = nonce()
    sid = started("codex", f"BACKGROUND 4 {n}")
    code, out = inst.wait(sid)
    assert (code, out["status"], out["reply"]) == (0, "DONE", "started"), out
    info = inst.info(sid)
    assert info["status"] == "idle", "a background command isn't a running turn"
    assert info.get("background_tasks") == 1, info
    d = nonce()
    md = inst.send(sid, f"ECHO meanwhile {d}")
    code, out = inst.wait(sid, "--message", md)
    assert out["status"] == "DONE" and out["reply"] == f"ECHO meanwhile {d}", out
    delivered_once(inst, d)
    wait_until(lambda: not inst.info(sid).get("background_tasks"), 15, message="the background task finished")
    tools = [i for i in inst.transcript(sid) if i["kind"] == "tool" and "sleep 4" in (i.get("detail") or "")]
    assert tools and tools[0]["state"] == "done", tools
    assert inst.info(sid)["status"] == "idle"
    assert inst.read_reply(sid, md) == f"ECHO meanwhile {d}"


@pytest.mark.req("MA-4", "R-2")
@pytest.mark.slow
def test_a_message_the_product_died_while_handing_over_is_delivered_once(fresh):
    """The product is killed after Codex accepted a turn but before the model took its input
    (FAKE_INPUT_DELAY): after the restart the message must reach the model exactly once, not
    zero times (taken as cut off) and not twice."""
    other = fresh(prefix="acc-x-handover-")
    sid = other.start_agent("codex", None, env={"FAKE_INPUT_DELAY": "4"})
    other.wait(sid)
    n = nonce()
    message = other.send(sid, f"ECHO handed over {n}")
    time.sleep(1.0)
    assert not receipts_with(other, n), "the fake delays the input"
    other.kill_everything()
    other.start_app()
    code, out = other.wait(sid, "--message", message, timeout=60)
    assert out["status"] == "DONE" and out["reply"] == f"ECHO handed over {n}", out
    delivered_once(other, n)


@pytest.mark.req("MA-24", "MA-3")
@pytest.mark.parametrize("kind", ["claude", "codex"])
def test_a_session_that_never_got_a_message_resumes_after_stop(inst, started, kind):
    """Started without a prompt, stopped before any message: the harness has no conversation to
    resume yet, and the next message must still run."""
    sid = started(kind, None)
    inst.wait(sid)
    inst.cli("agent", "stop", sid)
    wait_until(lambda: inst.info(sid)["status"] == "exited", 15, message="stopped")
    n = nonce()
    message = inst.send(sid, f"ECHO first after stop {n}")
    code, out = inst.wait(sid, "--message", message)
    assert out["status"] == "DONE", out
    delivered_once(inst, n)
    inst.send(sid, "RECALL")
    assert n in inst.wait(sid)[1]["reply"]


@pytest.mark.req("MA-5", "R-3", "R-10")
@pytest.mark.slow
def test_wait_keeps_waiting_across_an_app_restart(fresh):
    """A supervisor blocked in `agent wait` while the app quits and comes back gets the reply of
    the continued turn, not a dropped connection."""
    other = fresh(prefix="acc-x-wait-")
    sid = other.start_agent("claude", "ECHO warm-up")
    other.wait(sid)
    n = nonce()
    message = other.send(sid, f"SLEEP 6 {n}")
    delivered_once(other, n, timeout=15)
    proc = subprocess.Popen([other.target.cli_path, "--json", "agent", "wait", sid, "--message", message,
                             "--timeout", "120"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            env=other.env, cwd=other.work)
    time.sleep(1)
    other.quit_gracefully(timeout=60)
    time.sleep(1)
    other.start_app()
    out, err = proc.communicate(timeout=150)
    assert proc.returncode == 0, (out, err)
    assert json.loads(out)["status"] == "DONE"
    delivered_once(other, n)


@pytest.mark.req("R-10", "MA-28")
@pytest.mark.slow
def test_a_cut_off_turn_the_agent_started_itself_continues(fresh):
    """A turn Claude started by itself is running when the product is killed: after the restart
    the session continues (a note is delivered) and ends idle."""
    other = fresh(prefix="acc-x-wake-")
    sid = other.start_agent("claude", "ECHO warm-up", env={"FAKE_WAKE_TURN_SECS": "20"})
    other.wait(sid)
    w = nonce()
    other.send(sid, f"WAKE 1 {w}")
    other.wait(sid)
    wait_until(lambda: any(w in t["text"] for t in self_turns(other)), 15, message="the self-started turn began")
    wait_until(lambda: other.info(sid)["status"] == "working", 10, message="working on its own")
    hid = other.info(sid)["harness_id"]
    cut = time.time()
    other.kill_everything()
    other.start_app()
    wait_until(lambda: [r for r in other.receipts() if r["session"] == hid and r["ts"] > cut], 30,
               message="the session continued by itself")
    note = [r for r in other.receipts() if r["session"] == hid and r["ts"] > cut][0]["text"]
    assert "cut off" in note, note
    wait_until(lambda: other.info(sid)["status"] == "idle", 30, message="idle after the continuation")


@pytest.mark.req("MA-9", "R-1")
def test_stopping_a_session_that_is_still_starting(inst, started):
    """`agent stop` while the harness is still starting leaves nothing running and the session
    resumable."""
    sid = started("codex", "ECHO slow", env={"FAKE_SLOW_START": "3"})
    inst.cli("agent", "stop", sid, timeout=60)
    assert inst.info(sid)["status"] in ("exited", "error")
    time.sleep(4)
    assert inst.info(sid)["live"] is False, "a stopped session didn't start up afterwards"
    n = nonce()
    message = inst.send(sid, f"ECHO again {n}")
    assert inst.wait(sid, "--message", message)[1]["status"] == "DONE"


@pytest.mark.req("MA-10", "MA-24")
def test_a_missing_harness_fails_clearly(fresh):
    """A harness that isn't installed: the message fails with the reason, never pending."""
    other = fresh(prefix="acc-x-missing-", env={"TERN_CLAUDE_BIN": "/nonexistent/claude"})
    sid = other.start_agent("claude", "ECHO hi")
    code, out = other.wait(sid, timeout=30)
    assert code == 3 and out["status"] == "ERROR", out
    assert (out.get("error") or "").strip(), out
    assert other.info(sid)["status"] == "error"


@pytest.mark.req("MA-18", "R-7")
def test_tern_inside_an_agent_is_this_builds_cli(inst, started):
    """`tern` on an agent's PATH is the CLI of the app that started it, ahead of any other `tern`
    on the login PATH (an older install would not know the newer commands)."""
    cli = inst.target.cli_name
    sid = started("claude", f"RUN command -v {cli}")
    code, out = inst.wait(sid)
    assert out["reply"].startswith("exit=0"), out
    found = out["reply"].splitlines()[1].strip()
    assert os.path.realpath(found) == os.path.realpath(inst.target.cli_path), found


@pytest.mark.req("MA-25", "MA-28")
def test_a_redirect_during_a_turn_the_agent_started_itself(inst, started):
    """A redirect while Claude runs a turn of its own interrupts that turn and goes next."""
    sid = started("claude", "ECHO warm-up", env={"FAKE_WAKE_TURN_SECS": "30"})
    inst.wait(sid)
    w = nonce()
    inst.send(sid, f"WAKE 1 {w}")
    inst.wait(sid)
    wait_until(lambda: inst.info(sid)["status"] == "working", 15, message="working on its own")
    r = nonce()
    message = inst.json("agent", "send", sid, "--interrupt", f"ECHO redirected {r}")["message"]["id"]
    code, out = inst.wait(sid, "--message", message, timeout=30)
    assert out["status"] == "DONE" and out["reply"] == f"ECHO redirected {r}", out
    delivered_once(inst, r)


@pytest.mark.req("MA-19")
def test_watching_a_finished_turn_notifies_at_once(inst, started):
    """A supervisor that starts watching after the worker finished must not sleep forever."""
    boss = started("claude", "ECHO boss")
    inst.wait(boss)
    worker_name = "w-" + nonce()
    worker = started("codex", "ECHO done already", name=worker_name)
    inst.wait(worker)
    harness = inst.info(boss)["harness_id"]
    inst.cli("agent", "watch", worker, "--notify", boss)
    got = wait_until(lambda: [x for x in inst.receipts() if x["session"] == harness and worker_name in x["text"]],
                     20, message="the supervisor is told at once")
    assert len(got) == 1


@pytest.mark.req("R-10")
def test_installing_an_update_now_asks_before_cutting_turns_off(inst, started):
    """"An update installs while turns are running only if the user agrees": `update --now`
    refuses while a turn runs, and says how to agree."""
    sid = started("claude", "SLEEP 20")
    wait_until(lambda: inst.info(sid)["status"] == "working", 10, message="working")
    proc = inst.cli("update", "--now", check=False, timeout=60)
    assert proc.returncode != 0 and "--force" in proc.stderr, proc.stdout + proc.stderr
    assert inst.info(sid)["status"] == "working", "the turn keeps running"
    assert inst.app_running()
