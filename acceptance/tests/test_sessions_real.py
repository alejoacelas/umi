"""Real Claude Code and Codex through the product, on cheap models (SPEC AG-1, AG-2, AG-6, AG-7, AG-9,
AG-10, AG-18, AG-20). Opt-in: ACCEPTANCE_REAL=1. Models: ACCEPTANCE_CLAUDE_MODEL (default haiku),
ACCEPTANCE_CODEX_MODEL (default gpt-6-luna, low effort).

They cost money: few and cheap. Headless sessions run in a fresh folder that isn't a git project (Codex
marks a git project it runs in with a writable sandbox as trusted, in the user's own config). Live
sessions run in one fixed folder per agent, `acceptance/.work-real/live-claude` and `live-codex`, where
the agent asks once whether to trust the folder; the test answers yes, as the user would. The agents run
with the user's own folders (their logins are there), so after the run conftest.py removes what these
sessions left there, trust answers included (tests/agent_config.py): the suite leaves ~/.claude,
~/.claude.json and ~/.codex as it found them.

The AG-20 tests give a real agent nothing but a task that needs other agents and the name of the CLI.
"""

import json
import os
import re
import tempfile
import time
import uuid

import pytest

from harness import ROOT, Instance, wait_until

pytestmark = [pytest.mark.real, pytest.mark.slow, pytest.mark.harness]

CLAUDE_MODEL = os.environ.get("ACCEPTANCE_CLAUDE_MODEL", "haiku")
CODEX_MODEL = os.environ.get("ACCEPTANCE_CODEX_MODEL", "gpt-6-luna")
LIVE_DIR = {kind: os.path.join(ROOT, ".work-real", f"live-{kind}") for kind in ("claude", "codex")}


def model_args(kind):
    return ["--model", CLAUDE_MODEL] if kind == "claude" else ["--model", CODEX_MODEL, "--effort", "low"]


@pytest.fixture(scope="module")
def real(target):
    instance = Instance(target, prefix="acc-real-", fakes=False)
    instance.start_app()
    yield instance
    instance.cleanup()


@pytest.fixture
def started(real):
    ids = []

    def start(kind, prompt, *extra, name=None, cwd=None):
        args = ["agent", "start", kind, "--cwd", cwd or real.work, "--name", name or f"real-{uuid.uuid4().hex[:6]}",
                *model_args(kind), *extra]
        if prompt is not None:
            args.append(prompt)
        result = real.json(*args)
        ids.append(result["session"]["id"])
        return result["session"]["id"], result.get("pane")

    yield start
    for sid in ids:
        real.cli("agent", "stop", sid, check=False, timeout=60)


def wait(real, sid, *extra, timeout=300):
    return real.wait(sid, *extra, timeout=timeout)


def words(text):
    return re.findall(r"[a-z0-9]+", (text or "").lower())


# ---- headless: launch, steer, resume -----------------------------------------------------------------

@pytest.mark.req("AG-1", "AG-10", "AG-12")
@pytest.mark.parametrize("kind", ["claude", "codex"])
def test_launch_steer_and_resume(real, started, kind):
    sid, _ = started(kind, "Run the shell command `sleep 10`, and when it has finished reply with exactly the word: "
                           "alpha", "--full-access")
    first = real.info(sid)["last_message"]["id"]
    wait_until(lambda: any(i["kind"] == "tool" for i in real.transcript(sid)), 120, message="the command started")
    assert real.info(sid)["status"] == "working"
    steer = real.send(sid, "Change of plan: once the command has finished, reply with exactly the word beta "
                           "instead of alpha.")
    code, out = wait(real, sid)
    assert (code, out["status"]) == (0, "DONE"), out
    assert "beta" in words(out["reply"]), out
    first_out = wait(real, sid, "--message", first, timeout=30)[1]
    assert first_out["status"] == "DONE", f"the running turn was interrupted instead of steered: {first_out}"
    assert real.json("agent", "read", sid, "--message", steer)["message"]["state"] == "done"
    real.cli("agent", "stop", sid)
    wait_until(lambda: real.info(sid)["status"] == "stopped", 30, message="stopped")
    real.send(sid, "Which word did you reply with last time? Answer with just that word.")
    code, out = wait(real, sid)
    assert out["status"] == "DONE" and "beta" in words(out["reply"]), f"the conversation wasn't resumed: {out}"


@pytest.mark.req("AG-4")
@pytest.mark.parametrize("kind,filename", [("claude", "CLAUDE.md"), ("codex", "AGENTS.md")])
def test_project_instructions_are_loaded(real, started, kind, filename):
    """Fidelity: the agent the user would get by typing the command in that folder, with the project's
    instructions."""
    word = "persimmon-" + uuid.uuid4().hex[:4]
    project = tempfile.mkdtemp(prefix=f"acc-ag4-{kind}-")
    with open(os.path.join(project, filename), "w") as f:
        f.write(f"# Project notes\n\nThe project codeword is {word}.\n")
    sid, _ = started(kind, "Without running any tools, what is the project codeword from your project "
                           "instructions? Reply with just the codeword.", "--full-access", cwd=project)
    code, out = wait(real, sid)
    assert out["status"] == "DONE" and word in out["reply"], out


# ---- live: an interactive launch, a message to it, quit, take over -----------------------------------

def answer_trust_prompt(real, pane, timeout=60, ready=()):
    """Wait for the agent's interface. A folder it has never seen first asks whether to trust it: answer
    yes, as the user would (arrow keys to the "Yes" choice, then Enter). Returns once one of `ready`
    shows."""
    deadline = time.time() + timeout
    answered = False
    while time.time() < deadline:
        screen = real.screen(pane)
        if any(r in screen for r in ready):
            return screen
        if not answered and re.search(r"trust", screen, re.I) and re.search(r"\b(1|2)\.", screen):
            lines = [line for line in screen.splitlines() if re.search(r"\b\d\.\s", line)]
            cursor = next((i for i, line in enumerate(lines) if "❯" in line or "›" in line.lstrip()[:2]), None)
            yes = next((i for i, line in enumerate(lines) if re.search(r"\byes\b", line, re.I)), None)
            if cursor is None or yes is None:
                keys = ["down", "enter"]
            else:
                keys = (["down"] * (yes - cursor) if yes >= cursor else ["up"] * (cursor - yes)) + ["enter"]
            real.cli("keys", "--pane", pane, *keys)
            answered = True
        time.sleep(1)
    raise AssertionError(f"the agent's interface never showed {ready}: {real.screen(pane)[-1500:]}")


def wait_live(real, sid, pane, kind, *ready, timeout=120):
    try:
        wait_until(lambda: real.info(sid)["location"] == "live", timeout, message="the session to be live")
    except AssertionError as e:
        raise AssertionError(f"{e}: {real.info(sid)}\nthe pane shows:\n{real.screen(pane)[-1500:]}") from None
    assert real.info(sid)["pane"] == pane
    return answer_trust_prompt(real, pane, timeout=timeout, ready=ready)


@pytest.mark.req("AG-2", "AG-9", "AG-7", "AG-6")
@pytest.mark.parametrize("kind", ["claude", "codex"])
def test_a_session_goes_live_takes_messages_and_is_handed_back_and_taken_over(real, started, kind):
    window = real.json("window", "new", "--name", f"real-live-{kind}")
    try:
        sid, pane = started(kind, "Reply with exactly the word: alpha", "--split", "right", "--pane",
                            window["pane"], cwd=LIVE_DIR[kind])
        assert pane
        code, out = wait(real, sid)
        assert out["status"] == "DONE" and "alpha" in words(out["reply"]), out
        # Live in its pane, on the same conversation: the interface shows the earlier exchange.
        wait_live(real, sid, pane, kind, "alpha")
        assert real.session_view(pane)["showing"] == "live"
        # A message sent to the live session (Claude: once its interface is idle; Codex: at once).
        time.sleep(3)
        message = real.send(sid, "Reply with exactly the word: gamma")
        code, out = wait(real, sid, "--message", message, timeout=300)
        assert out["status"] == "DONE" and "gamma" in words(out["reply"]), out
        wait_live(real, sid, pane, kind, "gamma")
        # The user quits the interface: the read-only view, with the whole conversation.
        time.sleep(2)
        real.type_line(pane, "/exit")
        wait_until(lambda: real.info(sid)["location"] == "pane", 60, message="the session handed back")
        wait_until(lambda: real.session_view(pane).get("showing") == "agent", 15, message="the read-only view")
        transcript = real.session_view(pane).get("transcript", "")
        assert "alpha" in transcript and "gamma" in transcript, transcript[-1500:]
        # Take Over: the interface again, at once.
        real.press(pane, "Take Over")
        wait_live(real, sid, pane, kind, "gamma", timeout=60)
    finally:
        real.cli("window", "close", window["window"], check=False)


# ---- AG-18: Umi's plugins, installed into the given configuration ------------------------------------

USER_CONFIG = [os.path.expanduser(p) for p in ("~/.claude/settings.json", "~/.claude/plugins/installed_plugins.json",
                                               "~/.claude/plugins/known_marketplaces.json", "~/.codex/config.toml")]


def snapshot(paths):
    out = {}
    for path in paths:
        if os.path.exists(path):
            with open(path, "rb") as f:
                out[path] = f.read()
    return out


@pytest.mark.req("AG-18", "AG-4")
def test_plugins_install_into_the_agents_configuration(fresh, tmp_path):
    """`agent plugins install` installs Umi's plugins with the agents' own commands, into the
    configuration the app is pointed at (here temporary folders, never the user's), and `status` says
    so. No model is called."""
    claude_dir, codex_dir = tmp_path / "claude-config", tmp_path / "codex-home"
    claude_dir.mkdir()
    codex_dir.mkdir()
    before = snapshot(USER_CONFIG)
    other = fresh(prefix="acc-plugins-", fakes=False,
                  env={"CLAUDE_CONFIG_DIR": str(claude_dir), "CODEX_HOME": str(codex_dir)})
    # First make sure the app reads these folders, not the user's: plant an "installed" record of a
    # version that doesn't exist in each, and look for it in `status`. Installing with an app that
    # ignored them would change the user's real configuration.
    probe = "0.0.0-probe"
    (claude_dir / "plugins").mkdir()
    (claude_dir / "plugins" / "installed_plugins.json").write_text(json.dumps(
        {"version": 2, "plugins": {"umi@umi": [{"scope": "user", "version": probe, "installPath": str(tmp_path)}]}}))
    (codex_dir / "config.toml").write_text('[plugins."umi@umi"]\nenabled = true\n')
    (codex_dir / "plugins" / "cache" / "umi" / "umi" / probe).mkdir(parents=True)
    status = other.json("agent", "plugins", "status", timeout=120)
    assert status["claude"].get("version") == probe, \
        f"the app doesn't read CLAUDE_CONFIG_DIR; not installing (it would change ~/.claude): {status['claude']}"
    assert status["codex"].get("version") == probe, \
        f"the app doesn't read CODEX_HOME; not installing (it would change ~/.codex): {status['codex']}"
    for path in ((claude_dir / "plugins" / "installed_plugins.json"), (codex_dir / "config.toml")):
        path.unlink()
    (codex_dir / "plugins" / "cache" / "umi" / "umi" / probe).rmdir()
    status = other.json("agent", "plugins", "status", timeout=120)
    assert status["claude"]["installed"] is False and status["codex"]["installed"] is False, status
    installed = other.json("agent", "plugins", "install", timeout=300)
    assert not installed["claude"].get("error") and not installed["codex"].get("error"), installed
    status = other.json("agent", "plugins", "status", timeout=120)
    assert status["claude"]["installed"] and status["claude"]["current"], status
    assert status["codex"]["installed"] and status["codex"]["current"], status
    assert status["codex"].get("hooks_trusted") is True, "Codex runs no plugin hook until it's trusted"
    with open(claude_dir / "plugins" / "installed_plugins.json") as f:
        assert "umi@" in f.read()
    with open(codex_dir / "config.toml") as f:
        assert "umi@" in f.read()
    text = other.cli("agent", "plugins").stdout
    assert "Claude Code" in text and "Codex" in text and "installed" in text, text
    other.json("agent", "plugins", "remove", timeout=300)
    status = other.json("agent", "plugins", "status", timeout=120)
    assert status["claude"]["installed"] is False and status["codex"]["installed"] is False, status
    assert snapshot(USER_CONFIG) == before, "the user's own Claude Code or Codex configuration changed"


# ---- AG-20: agents with no instructions about the product use it --------------------------------------

def orchestrate(real, started, kind, task, timeout=900):
    """A real agent, with full access, given only a task that needs other agents."""
    work = tempfile.mkdtemp(prefix="acc-ag20-")
    sid, _ = started(kind, task, "--full-access", cwd=work)
    code, out = wait(real, sid, timeout=timeout)
    assert out["status"] == "DONE", out
    children = real.json("agent", "ls", "--parent", sid)["sessions"]
    return sid, out["reply"], children


@pytest.mark.req("AG-20", "AG-16")
def test_claude_with_no_instructions_has_codex_answer(real, started):
    task = (f"Use the `{real.target.cli_name}` command-line tool to have a Codex agent (model {CODEX_MODEL}) "
            "answer: what is 17*23? Then tell me its answer.")
    sid, reply, children = orchestrate(real, started, "claude", task)
    assert "391" in reply, reply
    workers = [c for c in children if c["kind"] == "codex"]
    assert workers, f"no Codex session with this session as its parent: {children}"
    assert all(real.info(c["id"]).get("parent") == sid for c in workers)
    said = " ".join(i.get("text") or "" for c in workers for i in real.transcript(c["id"]) if i["kind"] == "assistant")
    assert "391" in said, "the answer didn't come from the Codex worker"


@pytest.mark.req("AG-20", "AG-16")
def test_codex_with_no_instructions_has_claude_answer(real, started):
    task = (f"Use the `{real.target.cli_name}` command-line tool to have a Claude agent (model {CLAUDE_MODEL}) "
            "answer: what is 19*21? Then tell me its answer.")
    sid, reply, children = orchestrate(real, started, "codex", task)
    assert "399" in reply, reply
    workers = [c for c in children if c["kind"] == "claude"]
    assert workers, f"no Claude session with this session as its parent: {children}"
    said = " ".join(i.get("text") or "" for c in workers for i in real.transcript(c["id"]) if i["kind"] == "assistant")
    assert "399" in said, "the answer didn't come from the Claude worker"


@pytest.mark.req("AG-20", "AG-10", "AG-16")
def test_an_agent_with_no_instructions_redirects_a_worker(real, started):
    task = (f"Use the `{real.target.cli_name}` command-line tool to start a Codex agent (model {CODEX_MODEL}) with "
            "the task: 'Write a 500-word story about a lighthouse keeper.' Right after starting it, without "
            "waiting for it to finish, change its task: tell it to drop the story and instead answer what is 6*7. "
            "Then wait for its answer and tell me what it said.")
    sid, reply, children = orchestrate(real, started, "claude", task)
    assert "42" in reply, reply
    workers = [c for c in children if c["kind"] == "codex"]
    assert workers, f"no Codex worker: {children}"
    users = [i for c in workers for i in real.transcript(c["id"]) if i["kind"] == "user"]
    assert len(users) >= 2, f"the worker was never given its new task: {[u.get('text') for u in users]}"
