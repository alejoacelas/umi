"""Agents launched as typed (SPEC IA), with the real `claude` / `codex` binaries' --version, so no
model is called. Skipped when a binary isn't on the login PATH."""

import os
import shutil
import subprocess
import tempfile
import time

import pytest

from harness import login_which, wait_until

pytestmark = pytest.mark.interactive

BANNER = {"claude": r"\(Claude Code\)", "codex": r"codex-cli \d"}




def need(kind):
    if not login_which(kind):
        pytest.skip(f"{kind} is not on the login PATH")


@pytest.mark.req("IA-1", "IA-3")
@pytest.mark.parametrize("kind", ["claude", "codex"])
def test_runs_exactly_as_typed(inst, win, kind):
    need(kind)
    result = inst.json(kind, "--tab", "--window", win["window"], "--cwd", tempfile.gettempdir(), "--", "--version")
    assert result["command"] == f"{kind} --version"
    pane = result["pane"]
    inst.cli("wait", "--pane", pane, "--pattern", BANNER[kind], "--timeout", "30")
    screen = inst.cli("read", "--pane", pane, "--scrollback").stdout
    assert f"{kind} --version" in screen, "the command is typed into the pane's shell"
    # Without `--`, every argument is the agent's.
    result = inst.json(kind, "--version")
    assert result["command"] == f"{kind} --version"


@pytest.mark.req("IA-3", "L-8")
def test_placements_and_no_focus(inst, win):
    need("codex")
    before = {w["id"] for w in inst.tree()["windows"]}
    result = inst.json("codex", "--window", "--", "--version")
    w, _, _ = inst.find_pane(result["pane"])
    assert w["id"] not in before and len(w["tabs"]) == 1
    result = inst.json("codex", "--split", "down", "--pane", win["pane"], "--", "--version")
    assert inst.find_pane(result["pane"])[1]["id"] == win["tab"]
    inst.cli("pane", "focus", win["pane"])
    time.sleep(0.5)
    result = inst.json("codex", "--tab", "--window", win["window"], "--no-focus", "--", "--version")
    time.sleep(0.8)
    w, tab, _ = inst.find_pane(win["pane"])
    assert w["selected_tab"] == win["tab"] and tab["focused_pane"] == win["pane"]
    assert inst.find_pane(result["pane"])[1]["id"] != win["tab"]
    # Agent arguments that look like the product's own options are left alone.
    result = inst.json("codex", "--split", "--pane", win["pane"], "--", "--tab", "--version")
    assert result["command"] == "codex --tab --version"


@pytest.mark.req("IA-2")
def test_exit_is_noted_and_later_programs_are_not_the_agent(inst, win):
    need("claude")
    result = inst.json("claude", "--tab", "--window", win["window"], "--", "--version")
    pane = result["pane"]
    inst.cli("wait", "--pane", pane, "--pattern", BANNER["claude"], "--timeout", "30")
    wait_until(lambda: (inst.find_pane(pane)[2].get("interactive_agent") or {}).get("running") is False, 15,
               message="the agent's exit is noted")
    assert inst.find_pane(pane)[2]["interactive_agent"]["kind"] == "claude"
    inst.cli("send", "--pane", pane, "-e", "echo still-a-shell")
    inst.cli("wait", "--pane", pane, "--pattern", "^still-a-shell", "--timeout", "10")
    inst.cli("send", "--pane", pane, "-e", "sleep 3")
    time.sleep(1)
    assert inst.find_pane(pane)[2]["interactive_agent"]["running"] is False
