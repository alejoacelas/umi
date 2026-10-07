"""Real Claude Code and Codex on cheap models (SPEC MA-22, MA-23 and the core loop). Opt-in:
ACCEPTANCE_REAL=1. Models: ACCEPTANCE_CLAUDE_MODEL (default haiku), ACCEPTANCE_CODEX_MODEL."""

import os
import subprocess
import uuid

import pytest

from harness import Instance, wait_until

pytestmark = [pytest.mark.real, pytest.mark.managed, pytest.mark.slow]

CLAUDE_MODEL = os.environ.get("ACCEPTANCE_CLAUDE_MODEL", "haiku")
CODEX_MODEL = os.environ.get("ACCEPTANCE_CODEX_MODEL", "gpt-6-luna")


@pytest.fixture(scope="module")
def real(target):
    instance = Instance(target, prefix="acc-real-", fakes=False)
    subprocess.run(["git", "init", "-q", instance.work], check=True)
    instance.start_app()
    yield instance
    instance.cleanup()


def start(real, kind, prompt, *extra, name=None):
    model = CLAUDE_MODEL if kind == "claude" else CODEX_MODEL
    args = ["agent", "start", kind, "--background", "--cwd", real.work, "--name", name or f"real-{uuid.uuid4().hex[:6]}",
            "--model", model]
    if kind == "codex":
        args += ["--effort", "low"]
    return real.json(*args, *extra, prompt)["session"]["id"]


def wait(real, sid, *extra, timeout=300):
    return real.wait(sid, *extra, timeout=timeout)


@pytest.mark.req("MA-22", "MA-3", "MA-5", "MA-9")
@pytest.mark.parametrize("kind", ["claude", "codex"])
def test_lifecycle(real, kind):
    sid = start(real, kind, "Run the shell command `sleep 6` and then reply with exactly the word: alpha", "--full-access")
    first = real.info(sid)["last_message"]["id"]
    wait_until(lambda: real.info(sid)["status"] == "working", 90, message="working")
    second = real.send(sid, "After that, also reply with exactly the word: beta")
    code, out = wait(real, sid, "--message", second)
    assert out["status"] == "DONE" and "beta" in out["reply"].lower(), out
    assert wait(real, sid, "--message", first)[1]["status"] == "DONE"
    real.cli("agent", "stop", sid)
    wait_until(lambda: real.info(sid)["status"] == "exited", 30, message="exited")
    real.send(sid, "Earlier I asked you to reply with two words. What was the second one? Answer with just that word.")
    code, out = wait(real, sid)
    assert out["status"] == "DONE" and "beta" in out["reply"].lower(), out
    real.cli("agent", "stop", sid)


@pytest.mark.req("MA-22", "MA-8")
def test_interrupt(real):
    sid = start(real, "claude", "Run the shell command `sleep 60` and then reply with: finished", "--full-access")
    wait_until(lambda: any(i["kind"] == "tool" for i in real.transcript(sid)), 120, message="the tool started")
    real.cli("agent", "interrupt", sid)
    code, out = wait(real, sid, timeout=60)
    assert out["status"] == "INTERRUPTED", out
    real.send(sid, "Reply with exactly the word: resumed")
    code, out = wait(real, sid)
    assert out["status"] == "DONE" and "resumed" in out["reply"].lower(), out
    real.cli("agent", "stop", sid)


@pytest.mark.req("MA-22", "MA-14")
@pytest.mark.parametrize("kind,mode", [("claude", "default"), ("codex", "untrusted")])
def test_approval(real, kind, mode):
    name = f"approved-{kind}.txt"
    prompt = (f"Create the file {name} containing hi by running the shell command `echo hi > {name}`. "
              "Then reply with exactly: written")
    sid = start(real, kind, prompt, "--permission-mode", mode)
    code, out = wait(real, sid)
    assert (code, out["status"]) == (2, "NEEDS_INPUT"), out
    assert not os.path.exists(os.path.join(real.work, name))
    while out["status"] == "NEEDS_INPUT":
        real.cli("agent", "approve", sid)
        code, out = wait(real, sid)
    assert out["status"] == "DONE", out
    assert os.path.exists(os.path.join(real.work, name))
    real.cli("agent", "stop", sid)


@pytest.mark.req("MA-22", "MA-18", "MA-12")
def test_cross_agent_orchestration(real):
    cli = real.target.cli_name
    sub = "sub-" + uuid.uuid4().hex[:6]
    prompt = (f"You are testing our team's agent orchestration CLI, `{cli}`. Delegate a small question to a Codex "
              "worker by running this command in the shell (it waits for the worker and prints DONE and its answer):\n"
              f"{cli} agent start codex --model {CODEX_MODEL} --effort low --name {sub} --background --wait "
              "--timeout 200 'What is 17 + 25? Answer with just the number.'\n"
              "Then tell me the number the worker answered.")
    sid = start(real, "claude", prompt, "--full-access")
    code, out = wait(real, sid, timeout=420)
    assert out["status"] == "DONE" and "42" in out["reply"], out
    info = real.info(sub)
    assert info["kind"] == "codex" and info.get("parent") == sid
    real.cli("agent", "stop", sid)
    real.cli("agent", "stop", sub)


@pytest.mark.req("MA-23")
@pytest.mark.parametrize("kind,filename", [("claude", "CLAUDE.md"), ("codex", "AGENTS.md")])
def test_project_instructions_are_loaded(real, kind, filename, tmp_path):
    word = "persimmon-" + uuid.uuid4().hex[:4]
    project = tmp_path / f"proj-{kind}"
    project.mkdir()
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    (project / filename).write_text(f"# Project notes\n\nThe project codeword is {word}.\n")
    model = CLAUDE_MODEL if kind == "claude" else CODEX_MODEL
    extra = ["--effort", "low"] if kind == "codex" else []
    sid = real.json("agent", "start", kind, "--background", "--cwd", str(project), "--model", model, *extra,
                    "--full-access", "Without running any tools, what is the project codeword from your project "
                    "instructions? Reply with just the codeword.")["session"]["id"]
    code, out = wait(real, sid)
    assert out["status"] == "DONE" and word in out["reply"], out
    real.cli("agent", "stop", sid)


@pytest.mark.req("MA-23")
def test_project_skill_is_available(real, tmp_path):
    word = "tangelo-" + uuid.uuid4().hex[:4]
    project = tmp_path / "proj-skill"
    skill = project / ".claude" / "skills" / "codeword"
    skill.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    (skill / "SKILL.md").write_text(f"---\nname: codeword\ndescription: Tells the secret codeword when asked for "
                                    f"the codeword.\n---\n\nThe codeword is {word}.\n")
    sid = real.json("agent", "start", "claude", "--background", "--cwd", str(project), "--model", CLAUDE_MODEL,
                    "--full-access", "Use your codeword skill and reply with just the codeword.")["session"]["id"]
    code, out = wait(real, sid)
    assert out["status"] == "DONE" and word in out["reply"], out
    real.cli("agent", "stop", sid)


@pytest.mark.req("MA-21", "IA-4")
def test_user_codex_and_claude_config_untouched(real):
    watched = [os.path.expanduser(p) for p in ("~/.codex/config.toml", "~/.claude/settings.json")]
    before = {p: open(p, "rb").read() for p in watched if os.path.exists(p)}
    sid = start(real, "codex", "Reply with exactly: ok", "--full-access")
    wait(real, sid)
    real.cli("agent", "stop", sid)
    after = {p: open(p, "rb").read() for p in watched if os.path.exists(p)}
    assert before == after


@pytest.mark.req("MA-15", "MA-22")
def test_a_question_in_full_access_never_leaves_the_session_stuck(real):
    """The orchestrator runs workers in full access; a worker that asks the user something must show
    up as needing input (or not ask at all), never hang silently."""
    sid = start(real, "claude", "Use your AskUserQuestion tool to ask me one question: do I prefer red or blue "
                "(those two options). Then reply with exactly the color I chose.", "--full-access")
    code, out = wait(real, sid, timeout=180)
    assert out["status"] in ("NEEDS_INPUT", "DONE"), out
    if out["status"] == "NEEDS_INPUT":
        real.cli("agent", "answer", sid, "blue")
        code, out = wait(real, sid)
        assert out["status"] == "DONE" and "blue" in out["reply"].lower(), out
    real.cli("agent", "stop", sid)
