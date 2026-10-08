"""Check, without the accessibility tree, the agent-pane behaviors the suite checks through it.

The AP UI tests (typing a follow-up into the pane, Esc, pending questions shown, Undo of a
closed agent pane, the transcript after reopening and after a restart) need an unlocked screen.
This script drives the same paths through Tern's internal `debug.agent.*` and `debug.menu.*`
control methods: it types into the pane's composer and presses its keys and buttons the way
the text view and buttons do, and reads what the pane shows. Same black-box harness and fakes
as the suite.

    cd acceptance && uv run python ../app/macos/TernTests/verify_agent_panes.py
"""

import json
import os
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ACCEPTANCE = os.path.join(HERE, "..", "..", "..", "acceptance")
sys.path.insert(0, os.path.join(ACCEPTANCE, "tests"))
sys.path.insert(0, HERE)

from harness import Instance, Target, wait_until  # noqa: E402
from verify_ui_paths import Control, check, results, soon  # noqa: E402


def nonce():
    return uuid.uuid4().hex[:10]


def start(inst, kind, prompt, *placement, env=None, name=None):
    args = ["agent", "start", kind, "--cwd", inst.work, "--env", "FAKE_AGENT_DIR=" + inst.fake_dir,
            "--name", name or f"v-{nonce()}"]
    for key, value in (env or {}).items():
        args += ["--env", f"{key}={value}"]
    return inst.json(*args, *placement, prompt)["session"]["id"]


def agent_pane(inst, sid):
    found = inst.find_agent_pane(sid)
    return found[2]["id"] if found else None


def receipts_with(inst, marker):
    return [r for r in inst.receipts() if marker in (r.get("text") or "")]


def main():
    target = Target(os.path.join(ACCEPTANCE, "targets", "tern.json"))
    inst = Instance(target, prefix="acc-verify-ap-")
    inst.start_app()
    try:
        ctl = Control(inst)
        win = inst.json("window", "new", "--name", "verify-ap")
        wait_until(lambda: inst.cli("read", "--pane", win["pane"], check=False).stdout.strip() != "", 20)
        time.sleep(0.5)

        def pane_state(pane):
            return ctl.call("debug.agent.pane", pane=pane)

        # L-9: ⌃⌘J is a menu item (one), and it shows and focuses the session that needs the user.
        items = ctl.call("debug.menu")["items"]
        jump = [i for i in items if i["key"].lower() == "j" and tuple(i["modifiers"]) == ("ctrl", "cmd")]
        check("L-9 menu item for ctrl+cmd+j (jump to the agent that needs the user)", len(jump) == 1,
              f"found {[m['title'] for m in jump]}")
        waiting = start(inst, "claude", "ASK_QUESTIONS", "--background")
        inst.wait(waiting)
        if jump:
            ctl.call("debug.menu.perform", title=jump[0]["title"])
            shown = soon(lambda: inst.find_agent_pane(waiting), 10)
            check("⌃⌘J shows the session that needs the user", shown)
            if shown:
                check("and focuses its pane", soon(lambda: inst.find_agent_pane(waiting)[1]["focused_pane"] ==
                                                   inst.find_agent_pane(waiting)[2]["id"], 5))
                inst.cli("pane", "close", inst.find_agent_pane(waiting)[2]["id"], check=False)
        inst.cli("agent", "stop", waiting, check=False)
        inst.cli("window", "focus", win["window"])
        inst.cli("tab", "focus", win["tab"])

        # AP-1: a follow-up typed into the pane and Enter sends it (both harnesses).
        for kind in ("claude", "codex"):
            secret = "reply-" + nonce()
            sid = start(inst, kind, "ECHO hello", "--split", "right", "--pane", win["pane"], env={"ACC_AP": secret})
            inst.wait(sid)
            pane = soon(lambda: agent_pane(inst, sid), 10)
            check(f"{kind}: the session is shown in a pane", pane)
            inst.cli("pane", "focus", pane)
            ok = soon(lambda: pane_state(pane).get("composer_focused"), 5)
            check(f"{kind}: focusing the agent pane puts the keyboard in its composer", ok)
            n = nonce()
            ctl.call("debug.agent.type", pane=pane, text=f"PRINTENV ACC_AP {n}", key="enter")
            ok = soon(lambda: receipts_with(inst, n), 15)
            check(f"{kind}: Enter in the composer sends the follow-up, once", ok and len(receipts_with(inst, n)) == 1)
            code, out = inst.wait(sid)
            check(f"{kind}: the typed follow-up got its reply", out.get("reply") == secret, out)
            ok = soon(lambda: secret in pane_state(pane).get("transcript", ""), 10)
            check(f"{kind}: the reply is shown in the pane", ok)
            check(f"{kind}: the composer is empty after sending", pane_state(pane).get("composer") == "")
            inst.cli("agent", "stop", sid, check=False)
            inst.cli("pane", "close", pane, check=False)

        # AP-1, MA-8: Esc in the pane interrupts the running turn.
        sid = start(inst, "claude", "ECHO ready", "--split", "right", "--pane", win["pane"])
        inst.wait(sid)
        pane = soon(lambda: agent_pane(inst, sid), 10)
        message = inst.send(sid, "SLEEP 30")
        soon(lambda: inst.info(sid)["status"] == "working", 10)
        inst.cli("pane", "focus", pane)
        soon(lambda: pane_state(pane).get("composer_focused"), 5)
        ctl.call("debug.agent.type", pane=pane, key="escape")
        code, out = inst.wait(sid, "--message", message, timeout=15)
        check("Esc in the pane interrupts the turn", out["status"] == "INTERRUPTED", out)
        check("the session stays alive after Esc", inst.info(sid)["live"])

        # AP-6: a draft survives switching to the terminal and back, and moving the pane.
        ctl.call("debug.agent.type", pane=pane, text="a draft not sent yet")
        menu = {i["title"] for i in ctl.call("debug.menu")["items"]}
        check("the menu has the agent pane's terminal toggle", "Toggle Agent Pane's Terminal" in menu)
        inst.cli("pane", "focus", pane)
        ctl.call("debug.menu.perform", title="Toggle Agent Pane's Terminal")
        ok = soon(lambda: pane_state(pane).get("showing") == "terminal", 5)
        check("the agent pane shows its shell", ok)
        shell_cwd = inst.json("pane", "info", pane)["cwd"]
        check("the shell is in the session's folder", os.path.realpath(shell_cwd) == os.path.realpath(inst.work), shell_cwd)
        ctl.call("debug.menu.perform", title="Toggle Agent Pane's Terminal")
        soon(lambda: pane_state(pane).get("showing") == "agent", 5)
        check("a draft survives showing the terminal and back", pane_state(pane).get("composer") == "a draft not sent yet")
        ctl.call("debug.menu.perform", title="Toggle Agent Pane's Terminal")
        soon(lambda: pane_state(pane).get("showing") == "terminal", 5)
        inst.json("agent", "open", sid, "--focus")
        check("`agent open` of a pane showing its shell shows the session again",
              soon(lambda: pane_state(pane).get("showing") == "agent", 5))
        inst.cli("pane", "move", pane, "--new-tab")
        time.sleep(1.0)
        check("a draft survives moving the pane", pane_state(pane).get("composer") == "a draft not sent yet")
        check("the moved pane still shows the session", inst.json("pane", "info", pane).get("agent") == sid)
        inst.cli("agent", "stop", sid, check=False)

        # AP-1: pending questions are shown, and answered from the pane's buttons. (Views of a
        # tab that isn't shown are built when it is, so show the window's first tab again.)
        inst.cli("tab", "focus", win["tab"])
        sid = start(inst, "claude", "ASK_QUESTIONS", "--split", "right", "--pane", win["pane"])
        code, out = inst.wait(sid)
        pane = soon(lambda: agent_pane(inst, sid), 10)
        def question_texts():
            texts = " ".join(pane_state(pane).get("texts", []))
            return texts if "Favorite color?" in texts and "Which size?" in texts else ""
        texts = soon(question_texts, 15)
        check("pending questions are shown in the pane", texts, " ".join(pane_state(pane).get("texts", [])))
        buttons = pane_state(pane).get("buttons", [])
        check("their options are buttons", "red" in buttons and "blue" in buttons and "Answer" in buttons, buttons)
        ctl.call("debug.agent.press", pane=pane, title="Answer", field_text="blue")
        code, out = inst.wait(sid)
        check("questions answered from the pane", out["status"] == "DONE" and "Favorite color?=blue" in out["reply"], out)
        inst.cli("agent", "stop", sid, check=False)

        # AP-1: an approval answered from the pane.
        sid = inst.json("agent", "start", "codex", "--cwd", inst.work, "--env", "FAKE_AGENT_DIR=" + inst.fake_dir,
                        "--permission-mode", "on-request", "--split", "right", "--pane", win["pane"],
                        "ASK_APPROVAL")["session"]["id"]
        code, out = inst.wait(sid)
        pane = soon(lambda: agent_pane(inst, sid), 10)
        ok = soon(lambda: {"Allow", "Always allow", "Deny"} <= set(pane_state(pane).get("buttons", [])), 15)
        check("an approval is shown with Allow / Always allow / Deny", ok, pane_state(pane).get("buttons"))
        ctl.call("debug.agent.press", pane=pane, title="Allow")
        code, out = inst.wait(sid)
        check("the approval was given from the pane", out["status"] == "DONE" and "accepted" in out["reply"], out)
        inst.cli("agent", "stop", sid, check=False)

        # AP-2, AP-4: closing the pane leaves the session; Undo brings the pane back.
        sid = start(inst, "claude", "ECHO undo me", "--split", "right", "--pane", win["pane"])
        inst.wait(sid)
        pane = soon(lambda: agent_pane(inst, sid), 10)
        inst.cli("pane", "close", pane)
        soon(lambda: not inst.find_agent_pane(sid), 5)
        check("closing the agent pane leaves the session running", inst.info(sid)["live"])
        inst.cli("pane", "focus", win["pane"])
        ctl.call("debug.menu.perform", title="Undo")
        back = soon(lambda: inst.find_agent_pane(sid), 5)
        check("Undo brings the agent pane back", back and back[1]["id"] == win["tab"])
        if back:
            ok = soon(lambda: "undo me" in pane_state(back[2]["id"]).get("transcript", ""), 5)
            check("and it shows the session again", ok)

        # AP-5: a pane opened again shows every turn, in order, once.
        secrets = ["s1-" + nonce(), "s2-" + nonce(), "s3-" + nonce()]
        sid = start(inst, "claude", "PRINTENV ACC_S1", "--split", "right", "--pane", win["pane"],
                    env={"ACC_S1": secrets[0], "ACC_S2": secrets[1], "ACC_S3": secrets[2]})
        inst.wait(sid)
        pane = soon(lambda: agent_pane(inst, sid), 10)
        inst.cli("pane", "close", pane)
        soon(lambda: not inst.find_agent_pane(sid), 5)
        for name in ("ACC_S2", "ACC_S3"):
            inst.send(sid, f"PRINTENV {name}")
            inst.wait(sid)
        pane = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])["pane"]

        def ordered():
            text = pane_state(pane).get("transcript", "")
            positions = [text.find(s) for s in secrets]
            return all(p >= 0 for p in positions) and positions == sorted(positions) and \
                all(text.count(s) == 1 for s in secrets)
        check("a reopened pane shows every reply in order, once each", soon(ordered, 10))
    finally:
        inst.cleanup()

    # AP-5, R-3: after a restart, the pane shows the earlier conversation.
    other = Instance(target, prefix="acc-verify-ap5-")
    other.start_app()
    try:
        ctl = Control(other)
        secret = "before-restart-" + nonce()
        sid = other.json("agent", "start", "claude", "--cwd", other.work, "--env", "FAKE_AGENT_DIR=" + other.fake_dir,
                         "--env", f"ACC_SECRET={secret}", "--tab", "PRINTENV ACC_SECRET")["session"]["id"]
        other.wait(sid)
        other.quit_app()
        other.start_app()
        ctl = Control(other)
        other.json("agent", "open", sid, "--focus")
        found = soon(lambda: other.find_agent_pane(sid), 10)
        check("the session is shown after a restart", found)
        if found:
            ok = soon(lambda: secret in ctl.call("debug.agent.pane", pane=found[2]["id"]).get("transcript", ""), 15)
            check("and its pane shows the conversation from before the restart", ok)
    finally:
        other.cleanup()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
