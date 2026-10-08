"""Resumption, redirect, worker reports, turns the agent starts itself, startup reports and cut-off
turns (SPEC MA-24 to MA-29, R-10), against the fake harnesses."""

import json
import os
import random
import re
import shutil
import tempfile
import time

import pytest

from harness import alive, wait_until
from test_managed import KINDS, delivered_once, nonce, receipts_with, started  # noqa: F401 (fixture)

pytestmark = [pytest.mark.managed, pytest.mark.harness]

MODEL = {"claude": "haiku", "codex": "gpt-5.1-codex-mini"}
HARNESS_ARGS = {"claude": ["--add-dir", "/tmp"], "codex": ["-c", "model_verbosity=low"]}


def settings_args(kind, value):
    return ["--model", MODEL[kind], "--effort", "low", "--full-access", "--env", f"ACC_VALUE={value}",
            "--", *HARNESS_ARGS[kind]]


def state(inst, sid):
    inst.send(sid, "STATE")
    code, out = inst.wait(sid, timeout=90)
    assert out["status"] == "DONE", out
    return json.loads(out["reply"])


def assert_same_settings(inst, sid, kind, value, cwd, when):
    got = state(inst, sid)
    assert got["model"] == MODEL[kind], f"{when}: model {got['model']}"
    assert got["effort"] == "low", f"{when}: effort {got['effort']}"
    assert got["full_access"] is True, f"{when}: full access lost"
    assert os.path.realpath(got["cwd"]) == os.path.realpath(cwd), f"{when}: cwd {got['cwd']}"
    joined = " ".join(got["argv"])
    assert all(a in joined for a in HARNESS_ARGS[kind]), f"{when}: harness arguments lost: {got['argv']}"
    inst.send(sid, "PRINTENV ACC_VALUE")
    assert inst.wait(sid)[1]["reply"] == value, f"{when}: environment lost"


def harness_id(inst, sid):
    return wait_until(lambda: inst.info(sid).get("harness_id"), 20, message="the harness's session id")


def session_receipts(inst, hid, since=0.0):
    return [r for r in inst.receipts() if r["session"] == hid and r["ts"] > since]


# ---- MA-24: send and it runs ---------------------------------------------------------------------

@pytest.mark.req("MA-24", "MA-3", "MA-23")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
def test_every_resume_keeps_context_and_settings(fresh, kind):
    other = fresh(prefix="acc-ma24-")
    value = "v-" + nonce()
    word = "w-" + nonce()
    sid = other.start_agent(kind, None, *settings_args(kind, value))
    other.send(sid, f"ECHO remember {word}")
    assert other.wait(sid)[1]["status"] == "DONE"

    def stopped():
        other.cli("agent", "stop", sid, timeout=60)
        wait_until(lambda: other.info(sid)["status"] in ("exited", "error"), 30, message="stopped")

    def crashed():
        other.send(sid, "CRASH")
        wait_until(lambda: other.info(sid)["status"] in ("error", "exited"), 30, message="the crash noticed")

    def product_killed():
        other.kill_everything()
        other.start_app()

    def app_quit():
        other.quit_app()
        other.start_app()

    for when, event in (("after stop", stopped), ("after a harness crash", crashed),
                        ("after the product was killed", product_killed), ("after the app quit", app_quit)):
        event()
        n = nonce()
        t0 = time.time()
        other.send(sid, f"ECHO back {n}")
        delivered_once(other, n, timeout=30)
        assert time.time() - t0 < 15, f"{when}: the message took {time.time() - t0:.0f} s to reach the agent"
        assert other.wait(sid)[1]["status"] == "DONE"
        other.send(sid, "RECALL")
        code, out = other.wait(sid)
        assert word in out["reply"], f"{when}: context lost: {out['reply']}"
        assert_same_settings(other, sid, kind, value, other.work, when)


def conversation_store(inst, kind, hid):
    if kind == "claude":
        return os.path.join(inst.fake_dir, "claude", f"{hid}.json")
    return os.path.join(inst.fake_dir, "codex", "threads", f"{hid}.json")


@pytest.mark.req("MA-24", "MA-4")
@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("gone", ["folder", "conversation"])
def test_a_send_that_cannot_resume_fails_at_once_and_never_starts_fresh(inst, started, kind, gone, tmp_path):
    cwd = str(tmp_path / f"project-{nonce()}")
    os.makedirs(cwd)
    sid = started(kind, f"ECHO remember {nonce()}", cwd=cwd)
    assert inst.wait(sid)[1]["status"] == "DONE"
    hid = harness_id(inst, sid)
    inst.cli("agent", "stop", sid, timeout=60)
    wait_until(lambda: inst.info(sid)["status"] in ("exited", "error"), 30, message="stopped")
    if gone == "folder":
        shutil.rmtree(cwd)
    else:
        store = conversation_store(inst, kind, hid)
        assert os.path.exists(store), "the fake keeps its conversations where fakes/README.md says"
        os.remove(store)
    n = nonce()
    t0 = time.time()
    proc = inst.cli("--json", "agent", "send", sid, f"ECHO after {n}", check=False)
    if proc.returncode == 0:
        message = json.loads(proc.stdout)["message"]["id"]
        code, out = inst.wait(sid, "--message", message, timeout=30)
        assert code == 3 and out["status"] in ("FAILED", "ERROR", "EXITED"), out
        reason = out.get("error") or inst.info(sid).get("error") or ""
    else:
        reason = proc.stderr
    assert time.time() - t0 < 20, "the failure was reported at once"
    assert reason.strip(), "the failure says why"
    time.sleep(3)
    assert not receipts_with(inst, n), "the message went to a fresh conversation"


# ---- MA-25: redirect -----------------------------------------------------------------------------

def redirect(inst, sid, text, *extra):
    return inst.json("agent", "send", sid, "--interrupt", *extra, text)["message"]["id"]


@pytest.mark.req("MA-25", "MA-8", "MA-4")
@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("drop", [False, True])
def test_redirect_goes_next(inst, started, kind, drop):
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    hid = harness_id(inst, sid)
    a, b, c = nonce(), nonce(), nonce()
    ma = inst.send(sid, f"SLEEP 30 {a}")
    delivered_once(inst, a, timeout=15)
    mb = inst.send(sid, f"ECHO queued {b}")
    time.sleep(0.5)
    before = time.time()
    delivered_before = {r["text"] for r in session_receipts(inst, hid)}
    mc = redirect(inst, sid, f"ECHO redirect {c}", *(["--drop-queued"] if drop else []))
    code, out = inst.wait(sid, "--message", mc, timeout=60)
    assert out["status"] == "DONE" and c in out["reply"], out
    assert inst.wait(sid, "--message", ma, timeout=30)[1]["status"] == "INTERRUPTED"
    first_new = min(session_receipts(inst, hid, before), key=lambda r: r["ts"])
    assert c in first_new["text"], f"the redirect was not the next thing the agent saw: {first_new['text']}"
    b_was_queued = not any(b in t for t in delivered_before)
    if drop and b_was_queued:
        code, out = inst.wait(sid, "--message", mb, timeout=30)
        assert (code, out["status"]) == (3, "CANCELLED"), out
        time.sleep(2)
        assert not receipts_with(inst, b), "a dropped message was delivered"
    else:
        assert inst.wait(sid, "--message", mb, timeout=60)[1]["status"] == "DONE"
        delivered_once(inst, b)
    delivered_once(inst, c)


@pytest.mark.req("MA-25", "MA-4")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
def test_a_redirect_as_the_turn_ends_never_interrupts_the_new_message(inst, started, kind):
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    rng = random.Random(7)
    for _ in range(8):
        x, y = nonce(), nonce()
        inst.send(sid, f"SLEEP 1 {x}")
        time.sleep(rng.uniform(0.6, 1.6))
        my = redirect(inst, sid, f"ECHO redirect {y}")
        code, out = inst.wait(sid, "--message", my, timeout=60)
        assert out["status"] == "DONE" and y in out["reply"], f"the redirect's own turn was hit: {out}"
        delivered_once(inst, y)


@pytest.mark.req("MA-25")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
def test_a_redirect_gets_through_a_hung_turn(inst, started, kind):
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    h, n = nonce(), nonce()
    inst.send(sid, f"HANG {h}")
    delivered_once(inst, h, timeout=15)
    mn = redirect(inst, sid, f"ECHO after the hang {n}")
    code, out = inst.wait(sid, "--message", mn, timeout=120)
    assert out["status"] == "DONE" and n in out["reply"], out
    delivered_once(inst, n)


# ---- MA-26: worker reports -----------------------------------------------------------------------

@pytest.mark.req("MA-26")
@pytest.mark.parametrize("kind", KINDS)
def test_workers_report_and_supervisors_wait_for_reports(inst, started, kind):
    cli = inst.target.cli_name
    sid = started(kind, "ECHO warm-up")
    inst.wait(sid)
    n1 = nonce()
    inst.send(sid, f"RUN {cli} agent report done all-good-{n1}")
    code, out = inst.wait(sid)
    assert out["status"] == "DONE" and out["reply"].startswith("exit=0"), out
    report = inst.info(sid)["report"]
    assert report["verdict"] == "done" and n1 in report["summary"] and report["at"]
    listed = next(s for s in inst.agents() if s["id"] == sid)
    assert listed["report"]["verdict"] == "done"

    # A report counts only if it came after the latest message.
    inst.send(sid, f"ECHO next {nonce()}")
    inst.wait(sid)
    proc = inst.cli("--json", "agent", "wait", sid, "--report", "--timeout", "3", check=False, timeout=60)
    assert proc.returncode == 124, proc.stdout + proc.stderr

    for verdict, exit_code in (("blocked", 2), ("failed", 3), ("done", 0)):
        n = nonce()
        inst.send(sid, f"RUN {cli} agent report {verdict} summary-{n}")
        proc = inst.cli("--json", "agent", "wait", sid, "--report", "--timeout", "60", check=False, timeout=120)
        assert proc.returncode == exit_code, proc.stdout + proc.stderr
        got = json.loads(proc.stdout)
        assert got["report"]["verdict"] == verdict and n in got["report"]["summary"]
        assert got["session"]["status"], "the wait also says what the harness says"
        inst.wait(sid)


@pytest.mark.req("MA-26")
def test_the_help_explains_idle(inst):
    for args in (("agent", "wait", "--help"), ("agent", "report", "--help")):
        proc = inst.cli(*args, check=False)
        text = (proc.stdout + proc.stderr).lower()
        assert "idle" in text and "report" in text, f"`{' '.join(args)}` doesn't explain idle vs. a report"


# ---- MA-28: turns the agent starts itself --------------------------------------------------------

def self_turns(inst):
    path = os.path.join(inst.fake_dir, "self_turns.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


@pytest.mark.req("MA-28", "MA-7", "MA-4", "MA-26")
def test_turns_the_agent_starts_itself(inst, started):
    """Claude Code starts a turn by itself when a background command finishes (C11wake). Codex is not
    known to; extend this to Codex if it does."""
    sid = started("claude", "ECHO warm-up")
    inst.wait(sid)
    w = nonce()
    m1 = inst.send(sid, f"WAKE 4 {w}")
    code, out = inst.wait(sid, "--message", m1)
    assert out["status"] == "DONE" and out["reply"] == "started", out
    assert inst.info(sid).get("background_tasks") == 1, "a background task still running is shown"

    seen = set()
    deadline = time.time() + 15
    while time.time() < deadline and not any(w in t.get("text", "") for t in self_turns(inst)):
        seen.add(inst.info(sid)["status"])
        time.sleep(0.1)
    assert any(w in t["text"] for t in self_turns(inst)), "the fake started its own turn"
    while time.time() < deadline and inst.info(sid)["status"] != "idle":
        seen.add(inst.info(sid)["status"])
        time.sleep(0.1)
    assert "working" in seen, f"the session never showed working during the turn it started itself: {seen}"
    wait_until(lambda: inst.info(sid)["status"] == "idle", 15, message="idle again")
    assert inst.read_reply(sid, m1) == "started", "the self-started turn's reply was taken as the message's"
    assert any(f"woke: {w}" in (i.get("text") or "") for i in inst.transcript(sid)), "the turn is in the transcript"
    assert not inst.info(sid).get("background_tasks"), "no background task is left"

    # A message sent while the agent runs a turn of its own gets its own reply, exactly once.
    w2, d = nonce(), nonce()
    inst.send(sid, f"WAKE 2 {w2}")
    inst.wait(sid)
    wait_until(lambda: any(w2 in t["text"] for t in self_turns(inst)), 10, message="the second self-started turn")
    md = inst.send(sid, f"ECHO during {d}")
    code, out = inst.wait(sid, "--message", md, timeout=60)
    assert out["status"] == "DONE" and d in out["reply"] and "woke" not in out["reply"], out
    delivered_once(inst, d)


# ---- MA-29: what a worker loaded -----------------------------------------------------------------

@pytest.mark.req("MA-29")
@pytest.mark.parametrize("kind", KINDS)
def test_what_failed_to_load_is_shown(inst, started, kind):
    sid = started(kind, "ECHO hi", env={"FAKE_MCP": "probe-auth:needs-auth,probe-ok:connected"})
    proc = inst.cli("agent", "wait", sid, "--timeout", "60", check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "probe-auth" in proc.stdout + proc.stderr, "`agent wait` warns about the server that needs auth"
    startup = inst.info(sid)["startup"]
    names = {s["name"] for s in startup.get("mcp_servers", [])}
    assert {"probe-auth", "probe-ok"} <= names, startup
    flags = " ".join(startup["flags"])
    assert "probe-auth" in flags and "probe-ok" not in flags, startup
    first = startup["at"]
    inst.cli("agent", "stop", sid, timeout=60)
    wait_until(lambda: inst.info(sid)["status"] in ("exited", "error"), 30, message="stopped")
    inst.send(sid, "ECHO again")
    inst.wait(sid)
    assert inst.info(sid)["startup"]["at"] != first, "the report is refreshed when the session resumes"


# ---- R-10: cut-off turns continue ----------------------------------------------------------------

@pytest.mark.req("R-10", "MA-24", "MA-4")
@pytest.mark.slow
@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("how", ["product killed", "quit"])
def test_cut_off_turns_continue_by_themselves(fresh, kind, how):
    other = fresh(prefix="acc-r10-")
    sid = other.start_agent(kind, "ECHO warm-up")
    other.wait(sid)
    hid = harness_id(other, sid)
    c = nonce()
    mc = other.send(sid, f"SLEEP {30 if how == 'product killed' else 8} {c}")
    delivered_once(other, c, timeout=15)
    wait_until(lambda: other.info(sid)["status"] == "working", 10, message="working")
    cut = time.time()
    harness_pid = receipts_with(other, c)[0]["pid"]
    if how == "product killed":
        other.kill_everything()
    else:
        other.quit_gracefully(timeout=60)
    survived = alive(harness_pid)   # a design may keep harnesses running while the app is gone
    other.start_app()
    code, out = other.wait(sid, "--message", mc, timeout=120)
    assert out["status"] == "DONE" and out.get("reply"), f"the cut-off message didn't end with a reply: {out}"
    delivered_once(other, c)
    if how == "product killed" and not survived:
        notes = [r for r in session_receipts(other, hid, cut) if c not in r["text"]]
        assert notes, "the session didn't continue by itself"
        note = notes[0]["text"]
        assert len(note) > 40 and re.search(r"\d{1,2}:\d{2}", note), f"the note doesn't say when: {note!r}"
