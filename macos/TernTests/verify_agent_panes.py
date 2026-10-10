"""Check, without the accessibility tree, the agent-pane paths a person uses (SPEC AG-5 to AG-9).

The UI tests need an unlocked screen. This script drives the same paths through Tern's internal
`debug.*` control methods: it reads a session's read-only view and presses its buttons (Take
Over) the way a click does, performs the Window menu's items (Take Over Session ⌃⌘O, Remove
Session from Pane ⌃⌘W) as choosing them does, and reads the sidebar's marks and the Dock badge.
Same black-box harness and fake agents as the suite.

    cd acceptance && uv run python ../app/macos/TernTests/verify_agent_panes.py
"""

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
    return uuid.uuid4().hex[:8]


def info(inst, sid):
    return inst.json("agent", "info", sid)


def main():
    target = Target(os.path.join(ACCEPTANCE, "targets", "tern.json"))
    inst = Instance(target, prefix="acc-verify-ag-")
    inst.start_app()
    try:
        ctl = Control(inst)
        win = inst.json("window", "new", "--name", "verify-ag")
        wait_until(lambda: inst.cli("read", "--pane", win["pane"], check=False).stdout.strip() != "", 20)
        ctl.call("debug.ui.assume_active", on=True)

        items = ctl.call("debug.menu")["items"]
        def item(key, mods):
            return [i for i in items if i["key"].lower() == key and tuple(i["modifiers"]) == mods]
        take = item("o", ("ctrl", "cmd"))
        remove = item("w", ("ctrl", "cmd"))
        check("AG-6 menu item ⌃⌘O (Take Over Session)", len(take) == 1 and "Take Over" in take[0]["title"],
              str([i["title"] for i in take]))
        check("AG-8 menu item ⌃⌘W (Remove Session from Pane)", len(remove) == 1 and "Remove" in remove[0]["title"],
              str([i["title"] for i in remove]))

        # AG-5: a headless session shown read-only, with its transcript and a Take Over button.
        sid = inst.start_agent("claude", "ECHO hello from the read-only view", name=f"v-{nonce()}")
        inst.wait(sid)
        opened = inst.json("agent", "open", sid, "--split", "right", "--pane", win["pane"])
        pane = opened["pane"]
        view = soon(lambda: (lambda v: v if "hello from the read-only view" in v.get("transcript", "") else None)(
            ctl.call("debug.agent.pane", pane=pane)), 10)
        check("AG-5 the read-only view shows the transcript", view)
        check("AG-5 it has a Take Over button and nothing to type into",
              view and "Take Over" in view.get("buttons", []) and not any("Message" in t for t in view.get("texts", [])),
              str(view and view.get("buttons")))
        check("AG-14 info says the session is in a pane", info(inst, sid)["location"] == "pane")
        # The split tree rebuilds when another pane is added: the view must stay in its pane.
        extra = inst.cli("split", "down", "--pane", win["pane"], "--no-focus").stdout.strip()
        time.sleep(1)
        kept = ctl.call("debug.agent.pane", pane=pane)
        check("AG-5 the read-only view stays in its pane when the window gets another split",
              kept.get("showing") == "agent" and kept.get("in_window") is True, str(kept))
        inst.cli("pane", "close", extra, check=False)

        # AG-6: Take Over → the agent's own interface in that pane, on the same conversation.
        ctl.call("debug.agent.press", pane=pane, title="Take Over")
        live = soon(lambda: info(inst, sid)["location"] == "live" and info(inst, sid)["status"] == "idle", 20)
        check("AG-6 Take Over makes the session live in its pane", live, str(info(inst, sid)))
        screen = soon(lambda: (lambda t: t if "hello from the read-only view" in t else None)(
            inst.cli("read", "--pane", pane, check=False).stdout), 10)
        check("AG-6 the interface shows the conversation so far", screen)

        # AG-9: a message to the live (idle) Claude session runs headless and the interface comes back.
        m = inst.send(sid, "ECHO sent while live")
        done = inst.cli("agent", "wait", sid, "--message", m, "--timeout", "60", check=False)
        check("AG-9 a message to a live session is answered", done.returncode == 0 and "sent while live" in done.stdout,
              done.stdout[-200:])
        check("AG-9 and the session is live again in the same pane",
              soon(lambda: info(inst, sid)["location"] == "live" and info(inst, sid).get("pane") == pane, 20),
              str(info(inst, sid)))

        # AG-8: Remove Session from Pane (the menu item, on the focused pane): the pane goes away, the
        # session stays and can be shown again.
        inst.cli("pane", "focus", pane)
        if remove:
            ctl.call("debug.menu.perform", title=remove[0]["title"])
        gone = soon(lambda: not any(p["id"] == pane for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"]), 15)
        check("AG-8 Remove Session from Pane takes the pane away", gone)
        after = info(inst, sid)
        check("AG-8 the session is still there, headless", after["location"] == "background", str(after))
        reopened = inst.json("agent", "open", sid, "--live")
        check("AG-6 `agent open --live` shows it live again",
              soon(lambda: info(inst, sid)["location"] == "live", 20), str(info(inst, sid)))
        inst.cli("agent", "hide", sid, check=False)

        # S-3 / AG-18: a session finishing while its pane isn't looked at marks its row; the Dock counts it.
        other = inst.start_agent("claude", "SLEEP 2", "--tab", "--window", win["window"], name=f"m-{nonce()}",
                                 background=False)
        inst.cli("tab", "focus", win["tab"])
        inst.wait(other)
        attention = soon(lambda: (lambda a: a if any(p.get("mark") == "finished" for p in a["panes"].values()) else None)(
            ctl.call("debug.ui.attention")), 15)
        check("S-3 a session that finished out of sight gets the finished mark", attention, str(ctl.call("debug.ui.attention")))
        check("S-3 the Dock badge doesn't count it (it counts sessions that need the user)",
              attention and attention.get("badge") in ("", None), str(attention and attention.get("badge")))
        shown = inst.find_agent_pane(other)
        if shown:
            inst.cli("pane", "focus", shown[2]["id"])
            cleared = soon(lambda: not any(p.get("mark") != "none" for p in ctl.call("debug.ui.attention")["panes"].values()), 10)
            check("S-3 looking at it clears the mark", cleared, str(ctl.call("debug.ui.attention")))
        for s in (sid, other):
            inst.cli("agent", "stop", s, check=False)
        check("no two processes ever ran one conversation", not inst.violations(), str(inst.violations()))
    finally:
        inst.cleanup()
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
