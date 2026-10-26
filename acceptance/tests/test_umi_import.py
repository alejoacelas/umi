"""Umi was called Tern before 0.6.0. Its first launch copies Tern's state (windows, tabs, panes, the
sidebar, shortcuts, agent sessions) when it has none of its own, and never changes Tern's folder.

Tern's state directory has the format this build writes, so these tests make a "Tern" by running an
isolated instance and point the instance under test at it with UMI_IMPORT_STATE_DIR (an isolated
instance copies nothing otherwise; the user's own copy reads ~/Library/Application Support/Tern).
"""

import hashlib
import json
import os
import time
import uuid

import pytest

from harness import descendants, ps_rows, read_jsonl, wait_until

pytestmark = pytest.mark.robustness


def snapshot(folder):
    """Every file under folder (but the fakes' own), with its contents' hash."""
    out = {}
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in ("fake-agent", "work")]
        for name in files:
            path = os.path.join(root, name)
            with open(path, "rb") as f:
                out[os.path.relpath(path, folder)] = hashlib.sha256(f.read()).hexdigest()
    return out


def importing(fresh, tern, **kwargs):
    """An instance whose state directory doesn't exist yet and that copies from `tern`'s."""
    umi = fresh(start_app=False, prefix="acc-import-", env={"UMI_IMPORT_STATE_DIR": tern.dir}, **kwargs)
    state = os.path.join(umi.dir, "state")
    umi.env[umi.target.env_names["state_dir"]] = state
    return umi, state


def tabs(inst):
    return [t for w in inst.tree()["windows"] for t in w["tabs"]]


@pytest.mark.req("R-11")
@pytest.mark.harness
def test_first_launch_copies_terns_tabs_and_sessions(target, fresh):
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    tern = fresh(prefix="acc-tern-", restore=True)
    pane = tern.cli("tab", "new", "--name", "from-tern").stdout.strip()
    tab = tern.json("pane", "info", pane)["tab"]
    tern.cli("tab", "pin", tab)
    tern.cli("split", "right", "--pane", pane)
    marker = uuid.uuid4().hex[:8]
    sid = tern.start_agent("claude", f"ECHO hello {marker}")
    assert tern.wait(sid)[1]["status"] == "DONE"
    tern.quit_gracefully()
    before = snapshot(tern.dir)

    umi, state = importing(fresh, tern, restore=True)
    umi.start_app()
    copied = [t for t in tabs(umi) if t.get("name") == "from-tern"]
    assert copied and copied[0]["pinned"], "Tern's named, pinned tab is there"
    assert len(copied[0]["panes"]) == 2, "with its split"
    assert any(s["id"] == sid for s in umi.agents()), "Tern's session is listed"
    assert marker in json.dumps(umi.transcript(sid)), "with its transcript"
    with open(os.path.join(state, "imported-from-tern.json")) as f:
        note = json.load(f)
    assert note["tern_running"] is False and "sessions" in note["copied"]
    assert snapshot(tern.dir) == before, "Tern's folder is left exactly as it was"

    # Copied once: what changes in Umi afterwards stays.
    umi.cli("tab", "rename", copied[0]["id"], "renamed-in-umi")
    umi.quit_gracefully()
    umi.start_app()
    names = [t.get("name") for t in tabs(umi)]
    assert "renamed-in-umi" in names and "from-tern" not in names


@pytest.mark.req("R-11")
@pytest.mark.harness
def test_a_session_tern_is_still_running_is_copied_stopped(fresh):
    """Tern can run next to Umi. A turn Tern is in the middle of stays Tern's: Umi's copy doesn't
    deliver the message again or start a second process on the conversation."""
    tern = fresh(prefix="acc-tern-run-")
    marker = uuid.uuid4().hex[:8]
    sid = tern.start_agent("claude", "ECHO warm-up")
    tern.wait(sid)
    mid = tern.send(sid, f"SLEEP 8 {marker}")
    receipts = os.path.join(tern.fake_dir, "receipts.jsonl")
    wait_until(lambda: any(marker in r.get("text", "") for r in read_jsonl(receipts)), 20,
               message="Tern's turn to start")

    umi, state = importing(fresh, tern)
    umi.start_app()
    with open(os.path.join(state, "imported-from-tern.json")) as f:
        assert json.load(f)["tern_running"] is True
    info = umi.info(sid)
    assert info["status"] not in ("running", "starting"), info
    code, out = umi.wait(sid, "--message", mid, timeout=10)
    assert out["status"] == "INTERRUPTED", out

    # Tern finishes its turn; the message reached the agent once, and only Tern's process ran it.
    code, out = tern.wait(sid, "--message", mid, timeout=60)
    assert out["status"] == "DONE", out
    time.sleep(2)
    assert sum(marker in r.get("text", "") for r in read_jsonl(receipts)) == 1
    assert not tern.violations(), tern.violations()
    children = set(descendants(umi.app_pid))
    assert not [cmd for pid, _, _, cmd in ps_rows() if pid in children and "fake_claude" in cmd], \
        "Umi started no harness for Tern's session"


@pytest.mark.req("R-11")
def test_nothing_is_copied_when_umi_has_state_of_its_own(fresh):
    tern = fresh(prefix="acc-tern-has-")
    tern.cli("tab", "new", "--name", "only-in-tern")
    tern.quit_app()
    umi = fresh(prefix="acc-import-has-", env={"UMI_IMPORT_STATE_DIR": tern.dir})
    assert not os.path.exists(os.path.join(umi.dir, "imported-from-tern.json"))
    assert "only-in-tern" not in [t.get("name") for t in tabs(umi)]
