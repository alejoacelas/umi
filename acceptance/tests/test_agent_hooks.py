"""Claude Code and Codex report the same pane states (SPEC AG-18, AG-19; design/ideas.md, item 14).

Each state maps the same way for both agents wherever their hooks allow it. The fakes send what the
real agents sent when probed (Claude Code 2.1.319 and codex-cli 0.164.0, 2026-11-09; fakes/README.md,
"Hooks"). `Instance.hook` runs `<cli> hook` as the plugin does, for the hook inputs a fake can't
produce on demand. The `real` tests type the user's own `claude` and `codex` (ACCEPTANCE_REAL=1).
"""

import json
import os
import time
import uuid

import pytest

from harness import wait_until

pytestmark = [pytest.mark.agents]

KINDS = ["claude", "codex"]
BANNER = {"claude": "Fake Claude Code", "codex": "Fake Codex"}


def nonce():
    return uuid.uuid4().hex[:8]


def wait_screen(inst, pane, *texts, timeout=20):
    return wait_until(lambda: all(t in inst.screen(pane, scrollback=True) for t in texts), timeout,
                      message=f"the pane to show {texts}")


def start(inst, pane, kind, args=""):
    inst.type_agent(pane, kind, args=args)
    wait_screen(inst, pane, BANNER[kind])


@pytest.fixture
def pane(inst, win):
    yield win["pane"]
    if inst.agent_status(win["pane"]) not in (None, "stopped"):
        inst.type_line(win["pane"], "/exit")
        wait_until(lambda: inst.agent_status(win["pane"]) in (None, "stopped"), 15, message="the agent to end")


# ---- the same states from both agents (fakes) -----------------------------------------------------

@pytest.mark.req("AG-18", "AG-19")
@pytest.mark.parametrize("kind", KINDS)
def test_a_turn_that_ends_with_status_done_is_done(inst, pane, kind):
    """Both agents' Stop carries the last message: agent.summary is its first line, agent.done its
    last line, agent.title the first prompt and agent.session the agent's own id."""
    start(inst, pane, kind)
    prompt = "RUN printf 'All set.\\nStatus: done\\n'"
    inst.type_line(pane, prompt)
    wait_screen(inst, pane, "Status: done")
    inst.wait_agent_status(pane, "idle", 15)
    attributes = inst.attributes(pane)
    assert (attributes["agent.summary"], attributes["agent.done"]) == ("exit=0", "true"), attributes
    assert attributes["agent.title"] == prompt and attributes.get("agent.session"), attributes


@pytest.mark.req("AG-19")
@pytest.mark.parametrize("kind", KINDS)
def test_a_question_is_needs_input_until_answered(inst, pane, kind):
    """Claude Code's AskUserQuestion and Codex's request_user_input both come as PreToolUse (Claude
    Code adds a PermissionRequest for it): the agent needs you until the answer comes back."""
    start(inst, pane, kind)
    inst.type_line(pane, "ASK_QUESTIONS")
    wait_screen(inst, pane, "? Favorite color?")
    inst.wait_agent_status(pane, "needs_input", 10)
    inst.type_line(pane, "2")
    wait_screen(inst, pane, "? Which size?")
    assert inst.agent_status(pane) == "needs_input"
    inst.type_line(pane, "XL")
    inst.wait_agent_status(pane, "idle", 15)
    assert inst.attributes(pane)["agent.summary"].startswith("answers:"), inst.attributes(pane)


@pytest.mark.req("AG-19")
@pytest.mark.parametrize("kind", KINDS)
def test_a_failed_turn_is_an_error_with_its_message(inst, pane, kind):
    """Claude Code ends a failed turn with StopFailure, Codex with PostModelRequest `failed` and no
    Stop: both are `error`, agent.summary says why, agent.done is false; the next turn clears it."""
    start(inst, pane, kind)
    inst.type_line(pane, "FAIL")
    inst.wait_agent_status(pane, "error", 15)
    attributes = inst.attributes(pane)
    assert attributes["agent.done"] == "false", attributes
    expected = "API Error: 404" if kind == "claude" else "model is not supported"
    assert expected in attributes["agent.summary"], attributes
    inst.type_line(pane, f"ECHO again {nonce()}")
    inst.wait_agent_status(pane, "idle", 15)


@pytest.mark.req("AG-19")
@pytest.mark.parametrize("kind", KINDS)
def test_a_failed_command_keeps_the_turn_working(inst, pane, kind):
    """A tool that fails (Claude Code's PostToolUseFailure, Codex's PostToolUse) isn't a failed turn:
    the agent goes on and finishes."""
    start(inst, pane, kind)
    inst.type_line(pane, "RUN sleep 1; exit 3")
    inst.wait_agent_status(pane, "working", 10)
    inst.wait_agent_status(pane, "idle", 15)
    assert inst.attributes(pane)["agent.summary"] == "exit=3", inst.attributes(pane)


@pytest.mark.req("AG-19")
def test_codexs_interrupt_hook_makes_it_idle_at_once(inst, pane):
    """Codex's Interrupt hook says the turn was interrupted: idle at once, without waiting out the two
    seconds Umi gives a Claude Code turn after Esc before taking it as interrupted."""
    start(inst, pane, "codex")
    inst.type_line(pane, f"SLEEP 60 {nonce()}")
    inst.wait_agent_status(pane, "working", 10)
    time.sleep(0.5)
    inst.cli("keys", "--pane", pane, "esc")
    inst.wait_agent_status(pane, "idle", 1.5)    # Umi's own inference would take 2 s from the key
    wait_screen(inst, pane, "interrupted")


@pytest.mark.req("AG-19")
def test_a_declined_codex_approval_is_not_left_waiting(inst, pane):
    """Answering Codex's approval with "no" interrupts the turn (its Interrupt hook): the pane no longer
    needs you."""
    start(inst, pane, "codex", args="-a on-request")
    inst.type_line(pane, "ASK_APPROVAL")
    wait_screen(inst, pane, "Allow command?")
    inst.wait_agent_status(pane, "needs_input", 10)
    inst.type_line(pane, "n")
    wait_screen(inst, pane, "interrupted")
    inst.wait_agent_status(pane, "idle", 10)


@pytest.mark.req("AG-19")
def test_codex_model_requests(inst, pane):
    """A retried model request works again (PreModelRequest after a failed PostModelRequest); a
    completed or cancelled one changes nothing; a subagent's failed request isn't the pane's error."""
    def hook(event, **payload):
        inst.hook(pane, event, kind="codex", session_id="thread-1", **payload)

    hook("UserPromptSubmit", prompt="retry me")
    hook("PreModelRequest")
    assert inst.agent_status(pane) == "working"
    error = json.dumps({"type": "error", "status": 503, "error": {"message": "Service unavailable\nlater",
                                                                  "code": "server_error"}})
    hook("PostModelRequest", status="failed", error=error, token_usage=None)
    attributes = inst.attributes(pane)
    assert (attributes["agent.status"], attributes["agent.summary"]) == ("error", "Service unavailable"), attributes
    hook("PreModelRequest")
    assert inst.agent_status(pane) == "working"
    hook("PostModelRequest", status="completed", error=None)
    hook("PostModelRequest", status="cancelled", error=None)
    assert inst.agent_status(pane) == "working"
    hook("PostModelRequest", status="failed", error="stream disconnected", agent_id="sub-1", agent_type="worker")
    assert inst.agent_status(pane) == "working"
    assert inst.attributes(pane)["agent.session"] == "thread-1"
    hook("Stop", last_assistant_message="done here")
    attributes = inst.attributes(pane)
    assert (attributes["agent.status"], attributes["agent.summary"]) == ("idle", "done here"), attributes
    # A plain-text error is the summary as it is.
    hook("UserPromptSubmit", prompt="again")
    hook("PostModelRequest", status="failed", error="stream disconnected before completion")
    attributes = inst.attributes(pane)
    assert (attributes["agent.status"], attributes["agent.summary"]) == \
        ("error", "stream disconnected before completion"), attributes
    hook("SessionEnd", reason="other")


@pytest.mark.req("AG-19")
def test_claudes_question_permission_and_tool_failure(inst, pane):
    """Claude Code asks permission for its own question tool: still needs_input; a failed tool goes
    back to working."""
    inst.hook(pane, "UserPromptSubmit", prompt="ask me")
    inst.hook(pane, "PreToolUse", tool_name="AskUserQuestion")
    inst.hook(pane, "PermissionRequest", tool_name="AskUserQuestion")
    assert inst.agent_status(pane) == "needs_input"
    inst.hook(pane, "PostToolUse", tool_name="AskUserQuestion")
    assert inst.agent_status(pane) == "working"
    inst.hook(pane, "PreToolUse", tool_name="Bash")
    inst.hook(pane, "PostToolUseFailure", tool_name="Bash", error="Exit code 1", is_interrupt=False)
    assert inst.agent_status(pane) == "working"
    inst.hook(pane, "StopFailure", error="model_not_found",
              last_assistant_message="There's an issue with the selected model (x).")
    attributes = inst.attributes(pane)
    assert (attributes["agent.status"], attributes["agent.summary"], attributes["agent.done"]) == \
        ("error", "There's an issue with the selected model (x).", "false"), attributes
    # The idle prompt (a minute after a turn ends) isn't "needs you".
    inst.hook(pane, "Notification", notification_type="idle_prompt", message="Claude is waiting for your input")
    assert inst.agent_status(pane) == "error"
    inst.hook(pane, "SessionEnd", reason="prompt_input_exit")
    assert inst.agent_status(pane) == "stopped"


# ---- the real agents (ACCEPTANCE_REAL=1) ----------------------------------------------------------


def wait_status(inst, pane, status, timeout):
    """wait_agent_status, saying what the pane showed and its attributes when it times out."""
    try:
        return inst.wait_agent_status(pane, status, timeout)
    except AssertionError as error:
        raise AssertionError(f"{error}\nattributes: {inst.attributes(pane)}\n"
                             f"screen:\n{inst.screen(pane, scrollback=True)[-6000:]}")


def real_instance(fresh):
    # The user's own logins: no CLAUDE_CONFIG_DIR or CODEX_HOME of the instance's.
    return fresh(prefix="acc-real-hooks-", fakes=False)


def claude_login(inst):
    """Where Claude Code can't read its login from the keychain (a run started over SSH), the run
    passes CLAUDE_CODE_OAUTH_TOKEN. Umi keeps CLAUDE_CODE_* out of its panes, so the token goes in a
    file only this user can read, and the typed command reads it (never shown on the screen)."""
    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    if not token:
        return ""
    path = os.path.join(inst.dir, "claude-token")
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(token)
    return f"CLAUDE_CODE_OAUTH_TOKEN=\"$(cat '{path}')\" "


def real_pane(inst):
    pane = inst.json("window", "new", "--cwd", inst.work)["pane"]
    wait_until(lambda: inst.screen(pane).strip(), 20, message="the shell")
    time.sleep(0.5)
    return pane


def answer_until(inst, pane, wanted, prompts, timeout):
    """Wait for `wanted` on the screen, answering the agents' own startup dialogs (folder trust)."""
    end = time.time() + timeout
    while time.time() < end:
        text = inst.screen(pane)
        if wanted in text:
            return text
        for seen, keys in prompts:
            if seen in text:
                inst.cli("keys", "--pane", pane, *keys)
                time.sleep(1.5)
        time.sleep(0.5)
    raise AssertionError(f"{wanted!r} never showed; screen:\n{inst.screen(pane, scrollback=True)[-6000:]}")


def codex_hook_flags(plugin):
    """Umi's Codex hooks given on the command line (`-c hooks.EVENT=…`), so the test leaves the user's
    installed plugins alone."""
    with open(os.path.join(plugin, "hooks", "hooks.json")) as f:
        events = json.load(f)["hooks"]
    flags = []
    for event, groups in events.items():
        command = groups[0]["hooks"][0]["command"].replace("${PLUGIN_ROOT}", plugin)
        flags.append("-c " + "'" + 'hooks.%s=[{hooks=[{type="command",command=%s}]}]' % (event, json.dumps(command))
                     + "'")
    return " ".join(flags)


@pytest.mark.real
@pytest.mark.slow
@pytest.mark.req("AG-18", "AG-19")
def test_real_claude_code_reports_each_state(fresh):
    inst = real_instance(fresh)
    pane = real_pane(inst)
    trust = [("trust this folder", ["down", "enter"])]
    login = claude_login(inst)
    flags = f"--permission-mode default --plugin-dir '{inst.plugin('claude')}'"
    inst.type_line(pane, f"{login}claude --model haiku {flags}")
    answer_until(inst, pane, "Claude Code v", trust, 60)
    wait_status(inst, pane, "idle", 20)     # Claude Code runs SessionStart at launch
    prompt = "Reply with exactly two lines: 'All set.' then 'Status: done'"
    inst.type_line(pane, prompt)
    wait_status(inst, pane, "working", 15)
    wait_status(inst, pane, "idle", 60)
    attributes = inst.attributes(pane)
    assert attributes.get("agent.summary"), f"{attributes}\n{inst.screen(pane)}"
    assert (attributes["agent.summary"], attributes["agent.done"], attributes["agent.title"]) == \
        ("All set.", "true", prompt), attributes
    session = attributes["agent.session"]
    inst.type_line(pane, "Use the AskUserQuestion tool to ask me: red or blue? Nothing else.")
    wait_status(inst, pane, "needs_input", 60)
    inst.cli("keys", "--pane", pane, "enter")
    wait_status(inst, pane, "idle", 60)
    inst.type_line(pane, "Run the bash command: touch umi-real-hook.txt")
    wait_status(inst, pane, "needs_input", 60)
    inst.cli("keys", "--pane", pane, "enter")
    wait_status(inst, pane, "idle", 60)
    assert inst.attributes(pane)["agent.session"] == session
    inst.type_line(pane, "/exit")
    wait_status(inst, pane, "stopped", 20)
    # SessionEnd comes before Claude Code has given the terminal back: wait for its last words.
    wait_until(lambda: "Resume this session with" in inst.screen(pane), 20, message="Claude Code to exit")
    time.sleep(1)
    # A failed turn: a model that doesn't exist.
    inst.type_line(pane, f"{login}claude --model claude-nonexistent-9 {flags}")
    answer_until(inst, pane, "Claude Code v", trust, 60)
    wait_status(inst, pane, "idle", 20)
    inst.type_line(pane, "hi")
    wait_status(inst, pane, "error", 60)
    assert inst.attributes(pane)["agent.done"] == "false"
    inst.type_line(pane, "/exit")
    wait_status(inst, pane, "stopped", 20)


@pytest.mark.real
@pytest.mark.slow
@pytest.mark.req("AG-18", "AG-19")
def test_real_codex_reports_each_state(fresh):
    inst = real_instance(fresh)
    pane = real_pane(inst)
    trust = [("Trust this folder?", ["enter"])]
    flags = (f"-c model_reasoning_effort=low -c check_for_update_on_startup=false --dangerously-bypass-hook-trust "
             f"{codex_hook_flags(inst.plugin('codex'))}")
    # A read-only sandbox: any file written needs an approval.
    inst.type_line(pane, f"codex -m gpt-6-luna -a on-request -s read-only {flags}")
    answer_until(inst, pane, "? for shortcuts", trust, 60)
    # Codex reports a session only with its first prompt (item 14): nothing on the pane until then,
    # and its SessionStart (idle) comes just before the prompt's UserPromptSubmit.
    assert inst.agent_status(pane) is None, inst.attributes(pane)
    prompt = "Reply with exactly two lines: 'All set.' then 'Status: done'"
    inst.type_line(pane, prompt)
    wait_until(lambda: inst.attributes(pane).get("agent.summary"), 60,
               message="the turn's Stop (agent.summary)")
    wait_status(inst, pane, "idle", 10)
    attributes = inst.attributes(pane)
    assert attributes.get("agent.summary"), f"{attributes}\n{inst.screen(pane)}"
    assert (attributes["agent.summary"], attributes["agent.done"], attributes["agent.title"]) == \
        ("All set.", "true", prompt), attributes
    session = attributes["agent.session"]
    # A permission prompt, answered "no": Codex interrupts the turn (its Interrupt hook).
    inst.type_line(pane, "Run this shell command with escalated permissions (outside the sandbox): "
                         "touch umi-real-hook.txt")
    wait_status(inst, pane, "needs_input", 60)
    inst.cli("keys", "--pane", pane, "3")
    wait_status(inst, pane, "idle", 10)
    # An interrupt.
    inst.type_line(pane, "Write a 2000-word essay about the sea. No tools.")
    wait_status(inst, pane, "working", 30)
    time.sleep(2)
    inst.cli("keys", "--pane", pane, "esc")
    wait_status(inst, pane, "idle", 10)
    assert inst.attributes(pane)["agent.session"] == session
    inst.type_line(pane, "/exit")
    wait_status(inst, pane, "stopped", 20)
    wait_until(lambda: "To continue this session" in inst.screen(pane), 20, message="Codex to exit")
    time.sleep(1)
    # A failed turn: a model that doesn't exist.
    inst.type_line(pane, f"codex -m gpt-nonexistent-9 {flags}")
    answer_until(inst, pane, "? for shortcuts", trust, 60)
    inst.type_line(pane, "hi")
    wait_status(inst, pane, "error", 60)
    attributes = inst.attributes(pane)
    assert attributes["agent.done"] == "false" and "not supported" in attributes["agent.summary"], attributes
    inst.type_line(pane, "/exit")
    wait_status(inst, pane, "stopped", 20)
