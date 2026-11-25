#!/usr/bin/env python3
"""Check picker creation, agent /rename, Umi Rename and clean exit with real agent CLIs.

Run on the test Mac with both agents logged in and Umi's hook plugins enabled:
  lockf -k ~/umi-screen.lock python3 session_name_sync_test.py TEST.app --cwd PROJECT
The app uses its own state folder. No prompts are sent to a model.
Each agent's history keeps the named test sessions. Unnamed tests append a title fixture only to their newly created thread.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

from debugsock import Debug, poll


def claude_live_name(thread, transcript):
    # --name is visible before the first turn, when Claude has only its live-session registry.
    projects = next((p for p in transcript.parents if p.name == "projects"), None)
    if projects:
        for path in (projects.parent / "sessions").glob("*.json"):
            try:
                row = json.loads(path.read_bytes())
            except (OSError, ValueError):
                continue
            if row.get("sessionId") == thread:
                return row.get("name")


def saved_title(kind, thread, transcript):
    if kind == "claude":
        path = transcript
        def title(row):
            return row.get("customTitle") if row.get("sessionId") == thread and row.get("type") == "custom-title" else None
    else:
        home = next((p.parent for p in transcript.parents if p.name == "sessions"),
                    Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")))
        path = home / "session_index.jsonl"
        def title(row):
            return row.get("thread_name") if row.get("id") == thread else None
    if path.is_file():
        for line in reversed(path.read_text().splitlines()):
            try:
                value = title(json.loads(line))
            except json.JSONDecodeError:
                continue  # An agent may still be appending the last line.
            if value is not None:
                return value


def check(args, state):
    bins = args.app / "Contents/MacOS"
    env = dict(os.environ, UMI_NEXT_STATE_DIR=str(state), UMI_NEXT_DEBUG="1", UMI_NEXT_OFFSCREEN="0",
               UMI_NEXT_WEB_DIR=str(Path(__file__).resolve().parents[1] / "web"))
    assert not any(env.get(f"UMI_NEXT_{kind.upper()}_CMD") for kind in args.agents), "Use the built-in launch commands"
    debug = Debug(state, timeout=60, show_js=True)
    J = debug.J
    def cli(*words):
        return subprocess.check_output([bins / "umi-next", *words], text=True, env=env, timeout=60)
    def wait(fn, what, seconds=90):
        return poll(fn, seconds, every=.25, swallow=(FileNotFoundError,), what=what)
    def fill(selector, value):
        debug.ev(f"""(() => {{
          const input = document.querySelector({json.dumps(selector)});
          input.focus(); input.value = {json.dumps(value)};
          input.dispatchEvent(new Event('input', {{bubbles: true}}));
        }})(); 1""")
    def press(selector, key):
        debug.ev(f"""(() => {{
          const input = document.querySelector({json.dumps(selector)});
          input.focus();
          input.dispatchEvent(new KeyboardEvent('keydown', {{key: {json.dumps(key)}, bubbles:true, cancelable:true}}));
        }})(); 1""")

    picker = ".slot.picker .picker-name"
    def exercise(kind, unnamed_cwd=None):
        name = f"Umi {kind} {uuid.uuid4().hex[:8]}"
        cli("tab", "new", "--cwd", str(args.cwd))
        wait(lambda: J("!!Umi.model.sessionOf(Umi.model.activeTab().focused)"), "initial shell")
        debug({"cmd": "shortcut", "key": "d", "mods": ["cmd"]})
        wait(lambda: J("!!document.querySelector('.slot.picker .picker-name')"), "⌘D picker")
        destination = unnamed_cwd or args.cwd
        if unnamed_cwd:
            press(picker, "/")
        else:
            fill(picker, name)
            if kind == "codex":
                press(picker, "Tab")
            press(picker, "Enter")
        wait(lambda: J("document.querySelector('.slot.picker')?.dataset.mode === 'folder'"), "folder chooser")
        selected = "document.querySelector('.slot.picker .picker-row.sel')"
        wait(lambda: J(f"{selected}?.title === {json.dumps(str(args.cwd))}"), "current folder selected first")
        assert J(f"{selected} === document.querySelector('.slot.picker .picker-row')")
        if unnamed_cwd:
            fill(picker, str(destination) + "/")
            wait(lambda: J(f"{selected}?.title === {json.dumps(str(destination))}"), "other folder selected")
        press(picker, "Enter")
        wait(lambda: J("document.querySelector('.slot.picker')?.dataset.mode === 'new'"), "ready to start")
        assert J("document.querySelector('.slot.picker .picker-name').value") == ("" if unnamed_cwd else name)
        if kind == "codex" and unnamed_cwd:
            press(picker, "Tab")
        press(picker, "Enter")
        pane = wait(lambda: J("Umi.model.focusedPane()?.view==='terminal' ? Umi.model.activeTab().focused : null"),
                    "terminal pane")
        sid = wait(lambda: J(f"Umi.model.sessionOf('{pane}') || null"), "daemon session")
        def live():
            return J(f"Umi.state.live['{sid}'] || null") or {}
        def header():
            return J(f"""document.querySelector('.pane-head[data-pane="{pane}"] .label')?.textContent || null""")
        def started():
            screen = cli("read", "--pane", pane)
            ready = "bypass permissions on" in screen if kind == "claude" else "Ask Codex" in screen
            if kind == "codex" and "esc skip" in screen and "Update now" in screen:
                cli("keys", "--pane", pane, "esc")
                return None
            agent = live().get("agent", {})
            if ready and agent.get("agentSession"):
                return agent
            if kind == "claude" and ("Yes, I trust" in screen or "Yes, I accept" in screen):
                cli("keys", "--pane", pane, "down", "enter")
                time.sleep(.5)
        # A cold Codex app-server can use its full 120 s startup deadline before the TUI opens.
        agent = wait(started, f"{kind} prompt and thread ID", seconds=180 if kind == "codex" else 90)
        thread = agent["agentSession"]
        transcript = Path(agent.get("transcript") or "")
        assert Path(live()["cwd"]).resolve() == destination.resolve()
        if unnamed_cwd:
            generated = name + " generated"
            if kind == "claude":
                assert transcript.name == thread + ".jsonl" and not saved_title(kind, thread, transcript)
                assert "--name" not in live()["command"], "Umi passed an explicit name on a blank launch"
                record = {"type": "ai-title", "sessionId": thread, "aiTitle": generated}
                # Claude creates the project's transcript directory on the first turn.
                transcript.parent.mkdir(parents=True, exist_ok=True)
                target = transcript
            else:
                # UmiLaunch associates the TUI with the new thread even when its server hasn't emitted a hook.
                target = Path(agent["codexHome"]) / "session_index.jsonl"
                if target.exists():
                    with target.open() as index:
                        assert not any(row.get("id") == thread and row.get("thread_name")
                                       for row in map(json.loads, index))
                record = {"id": thread, "thread_name": generated, "updated_at": "2026-11-25T12:00:00Z"}
            with target.open("a") as f:
                f.write(json.dumps(record) + "\n")
            wait(lambda: header() == generated, f"{kind} native title in the unnamed pane")
            cli("send", "--pane", pane, "--enter", "/exit")
            wait(lambda: not live().get("alive"), f"{kind} exit")
            print(f"PASS {kind} unnamed launch in selected folder and native title fixture in the pane", flush=True)
            return
        def matches(expected):
            return header() == expected and saved_title(kind, thread, transcript) == expected
        def created():
            native = claude_live_name(thread, transcript) if kind == "claude" else saved_title(kind, thread, transcript)
            return header() == name and native == name
        wait(created, f"{kind} picker name in pane header and agent")

        def umi_rename(new_name):
            debug.ev("Umi.app.update(() => Umi.actions.renameSession()); 1")
            wait(lambda: J("!!document.querySelector('.palette-ask input')"), "Rename panel")
            fill(".palette-ask input", new_name)
            press(".palette-ask input", "Enter")
            wait(lambda: matches(new_name), f"Umi Rename in {kind} history")
        if kind == "claude":
            # A new Claude often has no transcript yet; create the first explicit record.
            umi_rename(name + " first")
        renamed = name + " agent"
        cli("send", "--pane", pane, "--enter", "/rename " + renamed)
        wait(lambda: matches(renamed), f"{kind} /rename in pane header and agent history")

        renamed = name + " app"
        umi_rename(renamed)
        # Both sessions still exist. The shell now has the agent's original launch name.
        shifted = json.loads(cli("--json", "split", "right", "--pane", pane, "--name", name + " shell", "--cmd", "/bin/zsh"))["pane"]
        wait(lambda: J(f"Umi.model.sessionOf('{shifted}') || null"), "new shell")
        cli("pane", "rename", shifted, name)
        cli("pane", "focus", pane)
        cli("pane", "focus", name)
        assert J("Umi.model.activeTab().focused") == shifted, "CLI resolved a stale launch name"

        cli("send", "--pane", pane, "--enter", "/exit")
        wait(lambda: not live().get("alive"), f"{kind} exit")
        assert saved_title(kind, thread, transcript) == renamed, f"{kind} exit reverted Umi Rename"
        print(f"PASS {kind} picker creation, /rename, Umi Rename and clean exit", flush=True)

    with (state / "app.log").open("w") as log:
        app = subprocess.Popen([bins / "UmiNext"], env=env, stdout=log, stderr=log)
        try:
            wait(lambda: debug({"cmd": "state"}).get("webReady"), "test app")
            debug({"cmd": "activate"})
            with tempfile.TemporaryDirectory(prefix="umi-picker-", dir=Path.home()) as alternate:
                for kind in args.agents:
                    exercise(kind)
                    exercise(kind, Path(alternate))
        finally:
            app.terminate()
            app.wait(timeout=15)
            subprocess.run([bins / "umi-next-ctl", "daemon-stop", "--force"], env=env, capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--agents", nargs="+", choices=["claude", "codex"], default=["claude", "codex"])
    args = parser.parse_args()
    args.app = args.app.resolve()
    args.cwd = args.cwd.resolve()
    with (args.app / "Contents/Info.plist").open("rb") as f:
        if not plistlib.load(f)["UmiNextStateName"].startswith("Umi-next-test-"):
            parser.error("use a test app built with --test")
    with tempfile.TemporaryDirectory(prefix="umi-name-sync-", dir="/tmp") as tmp:
        check(args, Path(tmp))
