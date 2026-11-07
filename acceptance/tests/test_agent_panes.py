"""Agents in panes (SPEC AG-18, AG-19; design/primitives.md, "Agent hook plugin"): Claude Code and Codex
run in Umi's panes, typed by the user; Umi's plugin runs `<cli> hook EVENT` from their hooks, which
writes `agent.*` on the pane (`ls --json`'s `attributes`). Umi runs no agents of its own.

Agents are the fakes' interactive ("TUI") modes, typed into a pane's shell with Umi's bundled plugin
(fakes/README.md). `Instance.hook` runs `<cli> hook` as the plugin does from inside a pane, for the
cases a fake can't produce on demand.
"""

import json
import os
import select
import subprocess
import time
import uuid

import pytest

from harness import FAKE_CLAUDE, FAKE_CODEX, wait_until

pytestmark = [pytest.mark.agents]

KINDS = ["claude", "codex"]
BANNER = {"claude": "Fake Claude Code", "codex": "Fake Codex"}
REPLY = {"claude": "⏺ ", "codex": "• "}


def nonce():
    return uuid.uuid4().hex[:8]


def screen(inst, pane):
    return inst.screen(pane, scrollback=True)


def wait_screen(inst, pane, *texts, timeout=20):
    return wait_until(lambda: all(t in screen(inst, pane) for t in texts) and screen(inst, pane), timeout,
                      message=f"the pane to show {texts}")


def agent_processes(fake):
    """(pid, argv words) of every running copy of a fake agent."""
    out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if fake in command:
            found.append((int(pid), command.split()))
    return found


@pytest.fixture
def pane(inst, win):
    """A pane at its shell's prompt; whatever agent was typed in it is ended afterwards."""
    yield win["pane"]
    if inst.agent_status(win["pane"]) not in (None, "stopped"):
        inst.type_line(win["pane"], "/exit")
        wait_until(lambda: inst.agent_status(win["pane"]) in (None, "stopped"), 15, message="the agent to end")


# ---- AG-18: the hooks write agent.* on the agent's pane -------------------------------------------

@pytest.mark.req("AG-18", "L-7")
@pytest.mark.parametrize("kind", KINDS)
def test_an_agent_typed_in_a_pane_writes_its_state_on_the_pane(inst, pane, kind):
    attributes = inst.type_agent(pane, kind)
    wait_screen(inst, pane, BANNER[kind])
    assert attributes["agent.status"] == "idle", attributes
    assert attributes.get("agent.session"), "its harness's session id"
    found = inst.find_pane(pane)[2]
    assert "agent" not in found and "showing" not in found, "the old session fields are gone"
    n = nonce()
    inst.type_line(pane, f"SLEEP 2 {n}")
    inst.wait_agent_status(pane, "working", 10)
    inst.wait_agent_status(pane, "idle", 15)
    attributes = inst.attributes(pane)
    assert attributes["agent.title"] == f"SLEEP 2 {n}", attributes
    assert attributes["agent.summary"] == f"ok: SLEEP 2 {n}", attributes
    assert attributes["agent.done"] == "false", attributes
    # The pane's events say so.
    inst.type_line(pane, "/exit")
    inst.wait_agent_status(pane, "stopped", 15)
    # The next agent in the pane overwrites agent.*.
    again = inst.type_agent(pane, kind)
    wait_until(lambda: inst.agent_status(pane) == "idle", 15, message="the next agent")
    assert inst.attributes(pane).get("agent.title") is None, again


@pytest.mark.req("AG-18", "T-4")
def test_agent_status_changes_are_pane_changed_events(inst, pane):
    events = subprocess.Popen([inst.target.cli_path, "events", "--filter", "pane.changed", "--pane", pane],
                              stdout=subprocess.PIPE, text=True, env=inst.env)
    try:
        time.sleep(0.5)
        inst.hook(pane, "SessionStart")
        inst.hook(pane, "UserPromptSubmit", prompt="hello")
        inst.hook(pane, "Stop", last_assistant_message="hi")
        seen = []
        deadline = time.time() + 10
        while time.time() < deadline and len(seen) < 3:
            ready, _, _ = select.select([events.stdout], [], [], 0.5)
            line = events.stdout.readline() if ready else ""
            if line:
                seen.append(json.loads(line))
        data = [e["data"] for e in seen]
        assert [(d["key"], d.get("old"), d["new"]) for d in data] == [("agent.status", None, "idle"),
                                                                      ("agent.status", "idle", "working"),
                                                                      ("agent.status", "working", "idle")], data
        assert all(d["pane"] == pane for d in data)
    finally:
        events.terminate()
        inst.hook(pane, "SessionEnd")


@pytest.mark.req("AG-18")
def test_agent_done_reads_the_replys_last_line(inst, pane):
    """`agent.done` is set at the end of each turn: true when the reply's last line starts with
    `Status: done` (the `done-check` slot's default)."""
    inst.hook(pane, "UserPromptSubmit", prompt="fix it")
    inst.hook(pane, "Stop", last_assistant_message="Fixed the bug.\n\nStatus: done")
    attributes = inst.attributes(pane)
    assert (attributes["agent.done"], attributes["agent.summary"]) == ("true", "Fixed the bug."), attributes
    inst.hook(pane, "UserPromptSubmit", prompt="and the docs")
    inst.hook(pane, "Stop", last_assistant_message="Docs need your call.\nStatus: waiting on you: approve")
    assert inst.attributes(pane)["agent.done"] == "false"
    inst.hook(pane, "SessionEnd")
    assert inst.agent_status(pane) == "stopped"


@pytest.mark.req("AG-18")
@pytest.mark.parametrize("kind", KINDS)
def test_the_plugins_hooks_are_silent_outside_umi(inst, kind, tmp_path):
    """Outside the product (another terminal, a terminal of an app that isn't running, Umi without a
    pane) Umi's hook prints nothing and does nothing."""
    script = os.path.join(inst.plugin(kind), "hooks", "umi-hook.sh")
    assert os.access(script, os.X_OK), script
    payload = json.dumps({"session_id": "00000000-0000-4000-8000-" + nonce() + "0000", "cwd": str(tmp_path),
                          "hook_event_name": "SessionStart", "source": "startup"})
    stopped_dir = str(tmp_path / "no-app")
    os.makedirs(stopped_dir)
    base = {k: v for k, v in inst.env.items() if not k.startswith("UMI_")}
    cli = inst.target.cli_path
    environments = {
        "another terminal": base,
        "a terminal of an app that isn't running": dict(base, UMI_CLI=cli, UMI_STATE_DIR=stopped_dir, UMI_PANE_ID="x"),
        "Umi, but no pane of it": dict(base, UMI_CLI=cli, UMI_STATE_DIR=inst.dir),
        "a pane of another run": dict(base, UMI_CLI=cli, UMI_STATE_DIR=inst.dir, UMI_PANE_ID="00000000",
                                      UMI_INSTANCE="nope:nope"),
    }
    before = {p["id"]: p.get("attributes") for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"]}
    for where, env in environments.items():
        for event in ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"):
            t0 = time.time()
            proc = subprocess.run([script, kind, event], input=payload, capture_output=True, text=True, env=env,
                                  timeout=30, cwd=str(tmp_path))
            assert (proc.returncode, proc.stdout, proc.stderr) == (0, "", ""), (where, event, proc)
            assert time.time() - t0 < 5, f"{where}: the hook made the agent wait"
        # The CLI the hook runs is silent too, whatever it's given.
        proc = subprocess.run([cli, "hook", "Stop", "--agent", kind, "--pid", "1"], input="not json",
                              capture_output=True, text=True, env=env, timeout=30)
        assert (proc.returncode, proc.stdout, proc.stderr) == (0, "", ""), (where, proc)
    after = {p["id"]: p.get("attributes") for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"]}
    assert after == before, "a hook from outside a pane changed a pane"


@pytest.mark.req("AG-18", "R-4")
@pytest.mark.parametrize("kind", KINDS)
def test_hooks_run_from_a_plugin_folder_whose_path_has_spaces(inst, pane, kind, tmp_path):
    """Review round 2 (0.6.2): the hooks' command quotes the plugin's folder."""
    import shutil
    copy = tmp_path / "plugin folder with spaces" / kind
    shutil.copytree(inst.plugin(kind), copy)
    attributes = inst.type_agent(pane, kind, plugin_dirs=[str(copy)])
    assert attributes["agent.status"] == "idle"


@pytest.mark.req("AG-18")
def test_a_claude_run_once_by_a_script_is_not_the_panes_agent(inst, pane):
    """`claude -p` run by a script in a pane is a one-off, not an agent in the pane."""
    root = inst.fake_dir
    inst.type_line(pane, f"FAKE_AGENT_DIR='{root}' FAKE_CLAUDE_PLUGIN_DIRS='{inst.plugin('claude')}' '{FAKE_CLAUDE}' "
                         f"-p --input-format stream-json --output-format stream-json --verbose < /dev/null; echo DONE-{nonce()}")
    time.sleep(3)
    assert "agent.kind" not in inst.attributes(pane), inst.attributes(pane)


@pytest.mark.req("AG-18", "I-2")
def test_the_plugins_command(inst):
    """`<cli> plugins` reports Umi's plugin in each agent (CLI.md, "Agent hooks")."""
    status = inst.json("plugins")
    for kind in KINDS:
        info = status[kind]
        assert {"installed", "current", "agent_installed"} <= set(info), info
    assert inst.cli("plugins", "frobnicate", check=False).returncode == 1


@pytest.mark.req("AG-18")
def test_a_plugin_installed_from_another_copy_of_umi_is_not_current(inst):
    """Found while updating this Mac's copy to 0.4.0: Codex's Umi plugin had been installed from a
    development build of the same plugin version, and the installed app took it as current, so its
    marketplace kept pointing at that build."""
    home = os.path.join(inst.fake_dir, "codex-home")
    os.makedirs(os.path.join(home, "plugins", "cache", "umi", "umi", "1.1.0"), exist_ok=True)
    with open(os.path.join(home, "config.toml"), "w") as f:
        f.write('[marketplaces.umi]\nsource_type = "local"\nsource = "/somewhere/else/Umi.app/Contents/Resources/agent-plugins"\n\n'
                '[plugins."umi@umi"]\nenabled = true\n\n'
                '[hooks.state."umi@umi:hooks/hooks.json:stop:0:0"]\ntrusted_hash = "x"\n')
    status = inst.json("plugins")
    codex = status.get("codex") or {}
    assert codex.get("installed") and codex.get("current") is False, status


@pytest.mark.req("AG-18")
def test_a_disabled_claude_plugin_is_not_current(inst):
    """Found while updating this Mac's copy: Claude Code had Umi's plugin installed but disabled (its
    settings had been rewritten), and Umi took it as current, so it reported nothing."""
    config = inst.claude_config
    os.makedirs(os.path.join(config, "plugins"), exist_ok=True)
    with open(os.path.join(config, "plugins", "installed_plugins.json"), "w") as f:
        json.dump({"version": 2, "plugins": {"umi@umi": [{"scope": "user", "version": "1.1.0"}]}}, f)
    with open(os.path.join(config, "settings.json"), "w") as f:
        json.dump({"enabledPlugins": {}}, f)
    claude = inst.json("plugins").get("claude") or {}
    assert claude.get("installed") and claude.get("enabled") is False and claude.get("current") is False, claude
    assert "disabled" in inst.cli("plugins").stdout


# ---- AG-19: the status stays truthful -------------------------------------------------------------

@pytest.mark.req("AG-19")
def test_claudes_status_is_truthful(inst, pane):
    inst.type_agent(pane, "claude")
    wait_screen(inst, pane, BANNER["claude"])
    n = nonce()
    inst.type_line(pane, f"SLEEP 3 {n}")
    inst.wait_agent_status(pane, "working", 10)
    inst.wait_agent_status(pane, "idle", 15)
    # A turn's end with background work still pending isn't "finished".
    w = nonce()
    inst.type_line(pane, f"WAKE 3 {w}")
    wait_screen(inst, pane, "⏺ started")
    time.sleep(0.5)
    seen = set()
    while f"woke: {w}" not in screen(inst, pane):
        seen.add(inst.agent_status(pane))
        time.sleep(0.1)
    assert seen == {"working"}, f"with background work pending, agent.status was {seen}"
    inst.wait_agent_status(pane, "idle", 10)
    # Waiting on a permission prompt is needs_input.
    inst.type_line(pane, "ASK_PERMISSION")
    wait_screen(inst, pane, "Do you want to proceed?")
    inst.wait_agent_status(pane, "needs_input", 10)
    inst.type_line(pane, "y")
    wait_screen(inst, pane, "permission allowed")
    inst.wait_agent_status(pane, "idle", 10)
    # An interrupted turn doesn't stay "working".
    inst.type_line(pane, f"SLEEP 60 {nonce()}")
    inst.wait_agent_status(pane, "working", 10)
    inst.cli("keys", "--pane", pane, "esc")
    wait_screen(inst, pane, "Interrupted")
    inst.wait_agent_status(pane, "idle", 10)


@pytest.mark.req("AG-19")
def test_codexs_status_is_truthful(inst, pane):
    inst.type_agent(pane, "codex", args="-a on-request")
    wait_screen(inst, pane, BANNER["codex"])
    inst.type_line(pane, f"SLEEP 3 {nonce()}")
    inst.wait_agent_status(pane, "working", 10)
    inst.wait_agent_status(pane, "idle", 15)
    inst.type_line(pane, "ASK_APPROVAL")
    wait_screen(inst, pane, "Allow command?")
    inst.wait_agent_status(pane, "needs_input", 10)
    inst.type_line(pane, "y")
    wait_screen(inst, pane, "approval accepted")
    inst.wait_agent_status(pane, "idle", 10)
    inst.type_line(pane, f"SLEEP 60 {nonce()}")
    inst.wait_agent_status(pane, "working", 10)
    inst.cli("keys", "--pane", pane, "esc")
    wait_screen(inst, pane, "interrupted")
    inst.wait_agent_status(pane, "idle", 10)


@pytest.mark.req("AG-19")
def test_a_failed_turn_is_an_error_not_done(inst, pane):
    inst.type_agent(pane, "claude")
    inst.type_line(pane, "FAIL")
    inst.wait_agent_status(pane, "error", 15)
    inst.type_line(pane, f"ECHO again {nonce()}")
    inst.wait_agent_status(pane, "idle", 15)


@pytest.mark.req("AG-19")
def test_an_agent_that_exits_without_saying_so_is_stopped(inst, pane):
    """An agent whose process ends with no SessionEnd hook (it crashed, or was killed) is stopped once
    its pane's shell is back at its prompt."""
    inst.type_agent(pane, "claude")
    wait_screen(inst, pane, BANNER["claude"])
    # The fake keeps its process id next to its conversation (fakes/README.md).
    session = inst.attributes(pane)["agent.session"]
    path = os.path.join(inst.fake_dir, "claude", f"{session}.pid")
    pid = int(wait_until(lambda: os.path.exists(path) and open(path).read().strip(), 10, message="its pid file"))
    os.kill(pid, 9)
    inst.wait_agent_status(pane, "stopped", 15)


# ---- After a relaunch: agents come back in their panes --------------------------------------------

def relaunch_instance(fresh, kind):
    """An instance that restores its windows, whose panes' shells reach the fake agents' state and
    Umi's plugin as the user's own `claude` and `codex` do."""
    probe = fresh(prefix="acc-restart-", restore=True, start_app=False)
    var = "FAKE_CLAUDE_PLUGIN_DIRS" if kind == "claude" else "FAKE_CODEX_PLUGIN_DIRS"
    probe.env.update({"FAKE_AGENT_DIR": probe.fake_dir, var: probe.plugin(kind)})
    probe.start_app()
    return probe


@pytest.mark.req("AG-18", "R-3", "I-4")
@pytest.mark.slow
def test_a_claude_typed_with_flags_comes_back_after_a_quit(target, fresh):
    """A `claude` typed in a pane with flags comes back after the app quits (as after an update or a
    crash): Umi types it again in its pane, on the same conversation, with the same flags, without its
    first prompt."""
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = relaunch_instance(fresh, "claude")
    pane = other.json("window", "new", "--cwd", other.work)["pane"]
    wait_until(lambda: other.screen(pane).strip(), 20, message="the shell")
    time.sleep(0.5)
    word = nonce()
    other.type_agent(pane, "claude", args=f"--add-dir '{other.work}' --dangerously-skip-permissions "
                                          f"--model fake-model-x 'ECHO first {word}'")
    wait_screen(other, pane, f"{REPLY['claude']}ECHO first {word}")
    other.wait_agent_status(pane, "idle", 15)
    session = other.attributes(pane)["agent.session"]
    title = other.attributes(pane)["agent.title"]

    other.quit_gracefully(timeout=60)
    assert not [p for p, argv in agent_processes(FAKE_CLAUDE) if session in " ".join(argv)], "it ended with the app"
    other.start_app()
    wait_until(lambda: other.find_pane(pane), 30, message="its pane back")
    wait_until(lambda: [p for p, argv in agent_processes(FAKE_CLAUDE) if session in " ".join(argv)], 30,
               message="the agent typed again")
    argv = next(argv for p, argv in agent_processes(FAKE_CLAUDE) if session in " ".join(argv))
    assert argv[argv.index("--resume") + 1] == session, argv
    assert "--dangerously-skip-permissions" in argv and argv[argv.index("--model") + 1] == "fake-model-x", argv
    assert "--add-dir" in argv and other.work in argv, argv
    assert not any(f"first {word}" in a for a in argv), f"the first prompt was given again: {argv}"
    other.wait_agent_status(pane, "idle", 20)
    assert other.attributes(pane)["agent.session"] == session
    assert other.attributes(pane)["agent.title"] == title
    other.type_line(pane, "RECALL")
    wait_screen(other, pane, f"history: ECHO first {word}")
    other.type_line(pane, "/exit")
    other.wait_agent_status(pane, "stopped", 15)


@pytest.mark.req("AG-18", "R-3")
@pytest.mark.slow
def test_a_codex_comes_back_after_a_crash_and_a_stopped_one_doesnt(target, fresh):
    """After every process of the app is killed, a Codex that ran in a pane comes back there on its
    thread; a pane whose agent had exited before gets nothing typed."""
    if not target.restoration_safe:
        pytest.skip("needs a restoration-safe build (TEST_INTERFACE.md, capability 5)")
    other = relaunch_instance(fresh, "codex")
    pane = other.json("window", "new", "--cwd", other.work)["pane"]
    wait_until(lambda: other.screen(pane).strip(), 20, message="the shell")
    quiet = other.json("split", "right", "--pane", pane, "--cwd", other.work)["pane"]
    wait_until(lambda: other.screen(quiet).strip(), 20, message="the second shell")
    time.sleep(0.5)
    other.type_agent(pane, "codex", args="-m fake-codex-model")
    other.type_line(pane, f"ECHO remember {nonce()}")
    other.wait_agent_status(pane, "idle", 15)
    other.type_agent(quiet, "codex")
    other.type_line(quiet, "/exit")
    other.wait_agent_status(quiet, "stopped", 15)
    thread = other.attributes(pane)["agent.session"]
    time.sleep(1.5)     # the layout is saved soon after a change
    other.kill_everything()
    for pid, argv in agent_processes(FAKE_CODEX):
        if thread in " ".join(argv):
            os.kill(pid, 9)
    other.start_app()
    wait_until(lambda: [p for p, argv in agent_processes(FAKE_CODEX) if thread in " ".join(argv)], 30,
               message="Codex typed again on its thread")
    argv = next(argv for p, argv in agent_processes(FAKE_CODEX) if thread in " ".join(argv))
    assert argv[argv.index("resume") + 1] == thread and argv[argv.index("-m") + 1] == "fake-codex-model", argv
    other.wait_agent_status(pane, "idle", 20)
    time.sleep(2)
    assert other.agent_status(quiet) in (None, "stopped"), other.attributes(quiet)
    assert "Fake Codex" not in other.screen(quiet), "nothing was typed in the pane whose agent had exited"
    other.type_line(pane, "/exit")


# ---- S-3: no desktop notifications from agents ----------------------------------------------------

@pytest.mark.req("S-3")
def test_an_agents_own_desktop_notifications_are_dropped(inst, pane):
    """Claude Code and Codex post OSC 9 / 777 notifications; a pane running an agent drops them, as
    Warp does for agents its plugin reports. Once the agent stops, the shell's are Ghostty's again."""
    def counts():
        return inst.rpc("debug.ui.notifications")
    before = counts()
    inst.hook(pane, "SessionStart")
    inst.hook(pane, "UserPromptSubmit", prompt="notify")
    try:
        inst.cli("send", "--pane", pane, "-e", "printf '\\033]9;umi agent says hi\\007'; echo OSC9-SENT")
        wait_until(lambda: counts()["dropped"] == before["dropped"] + 1, 10, message="the OSC 9 is dropped")
        time.sleep(1.2)   # Ghostty lets one notification through per second
        inst.cli("send", "--pane", pane, "-e", "printf '\\033]777;notify;Title;Body\\007'; echo OSC777-SENT")
        wait_until(lambda: counts()["dropped"] == before["dropped"] + 2, 10, message="the OSC 777 is dropped")
    finally:
        inst.hook(pane, "SessionEnd")
    time.sleep(1.2)
    inst.cli("send", "--pane", pane, "-e", "printf '\\033]9;after the agent\\007'; echo OSC9-AFTER")
    inst.cli("wait", "--pane", pane, "--pattern", "^OSC9-AFTER", "--timeout", "10")
    wait_until(lambda: counts()["passed"] == before["passed"] + 1, 5, message="let through once the agent stopped")
    assert counts()["dropped"] == before["dropped"] + 2


# ---- What left: Umi-run sessions -------------------------------------------------------------------

@pytest.mark.req("AG-18")
def test_umi_runs_no_agents_of_its_own(inst):
    """design/cli.md, "Removed": every `agent …` command and the `claude`/`codex` shortcuts. An old
    `agent` command says what to do instead."""
    for args in (["agent", "start", "claude", "hi"], ["agent", "ls"], ["agent", "send", "x", "y"]):
        proc = inst.cli(*args, check=False)
        assert proc.returncode == 1 and "removed" in proc.stderr and "plugins" in proc.stderr, (args, proc)
    for kind in KINDS:
        assert inst.cli(kind, "do something", check=False).returncode == 1
    usages = {c["usage"].split()[0] for c in inst.json("help", "--json")["commands"]}
    assert "agent" not in usages and "claude" not in usages and {"hook", "plugins"} <= usages, usages
