"""Check, without the accessibility tree, the behaviors the acceptance suite checks through it.

The suite's UI tests (L-9 shortcuts, M-3 undo, E-2..E-5 editor) need an unlocked screen. This
script drives the same paths through Tern's internal `debug.*` control methods: it lists and
performs menu items (as choosing them does) and types into editor documents (as the text view
does). It reuses the suite's black-box harness for isolated instances.

    cd acceptance && uv run python ../app/macos/TernTests/verify_ui_paths.py
"""

import json
import os
import socket
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ACCEPTANCE = os.path.join(HERE, "..", "..", "..", "acceptance")
sys.path.insert(0, os.path.join(ACCEPTANCE, "tests"))

from harness import Instance, Target, wait_until  # noqa: E402

results = []


def soon(predicate, timeout):
    """The predicate's value once true, or False after the timeout (without raising)."""
    try:
        return wait_until(predicate, timeout)
    except AssertionError:
        return False


def check(name, condition, detail=""):
    results.append((name, bool(condition), detail))
    print(("PASS " if condition else "FAIL ") + name + (f" ({detail})" if detail and not condition else ""))


class Control:
    """A raw client for the instance's socket (for the internal debug methods)."""

    def __init__(self, inst):
        out = inst.json("ping")
        self.path = None
        with open(os.path.join(inst.dir, "instance.json")) as f:
            self.path = json.load(f)["socket"]

    def call(self, method, **params):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.path)
        s.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        reply = json.loads(data)
        if "error" in reply:
            raise RuntimeError(reply["error"]["message"])
        return reply["result"]


def main():
    target = Target(os.path.join(ACCEPTANCE, "targets", "tern.json"))
    inst = Instance(target, prefix="acc-verify-")
    inst.start_app()
    try:
        ctl = Control(inst)
        win = inst.json("window", "new", "--name", "verify")
        wait_until(lambda: inst.cli("read", "--pane", win["pane"], check=False).stdout.strip() != "", 20)
        time.sleep(0.5)

        # L-9: every shortcut is a menu item with that key equivalent, one item each.
        items = ctl.call("debug.menu")["items"]
        wanted = {
            ("b", ("cmd",)): "toggle the sidebar", ("e", ("shift", "cmd")): "project explorer",
            ("o", ("cmd",)): "open a file", ("m", ("shift", "cmd")): "Markdown preview",
            ("t", ("ctrl", "cmd")): "pane to new tab", ("n", ("ctrl", "cmd")): "pane to new window",
            ("left", ("ctrl", "cmd")): "pane to previous tab", ("right", ("ctrl", "cmd")): "pane to next tab",
            ("n", ("ctrl", "shift", "cmd")): "tab to new window", ("p", ("ctrl", "cmd")): "pin",
            ("r", ("ctrl", "cmd")): "rename tab", ("r", ("ctrl", "shift", "cmd")): "rename pane",
        }
        titles = {}
        for (key, mods), what in wanted.items():
            matches = [i for i in items if i["key"].lower() == key and tuple(i["modifiers"]) == mods]
            check(f"L-9 menu item for {'+'.join(mods)}+{key} ({what})", len(matches) == 1,
                  f"found {[m['title'] for m in matches]}")
            if matches:
                titles[(key, mods)] = matches[0]["title"]
        check("L-9 one item per shortcut", len(set(titles.values())) == len(titles))

        # ⌘B through the menu toggles the sidebar.
        before = inst.json("sidebar", "status")["visible"]
        ctl.call("debug.menu.perform", title=titles[("b", ("cmd",))])
        check("⌘B toggles the sidebar", inst.json("sidebar", "status")["visible"] != before)
        ctl.call("debug.menu.perform", title=titles[("b", ("cmd",))])

        # M-3: undo and redo of a move, with focus restored.
        right = inst.json("pane", "info", inst.cli("split", "right", "--pane", win["pane"]).stdout.strip())["id"]
        inst.cli("pane", "focus", win["pane"])
        inst.cli("pane", "move", right, "--new-tab")
        moved_tab = inst.find_pane(right)[1]["id"]
        check("M-3 the move happened", moved_tab != win["tab"])
        inst.cli("pane", "focus", win["pane"])
        time.sleep(0.4)
        ctl.call("debug.menu.perform", title="Undo")
        ok = soon(lambda: inst.find_pane(right) and inst.find_pane(right)[1]["id"] == win["tab"], 5)
        w = next(w for w in inst.tree()["windows"] if w["id"] == win["window"])
        tab = next(t for t in w["tabs"] if t["id"] == win["tab"])
        check("M-3 undo puts the pane back", bool(ok) and len(w["tabs"]) == 1)
        check("M-3 after undo the tab's focused pane is what it was", tab["focused_pane"] == win["pane"],
              tab["focused_pane"])
        ctl.call("debug.menu.perform", title="Redo")
        wait_until(lambda: inst.find_pane(right)[1]["id"] != win["tab"], 5, message="redo")
        check("M-3 redo moves it again", inst.find_pane(right)[1]["id"] != win["tab"])
        marker = "REDO-%d" % time.time()
        inst.cli("send", "--pane", right, "-e", f"echo {marker}")
        check("M-3 the moved program still runs",
              inst.cli("wait", "--pane", right, "--pattern", f"^{marker}", "--timeout", "10", check=False).returncode == 0)

        # M-3 across windows: undo a move into another window; both windows come back as they were.
        a = inst.json("window", "new", "--name", "undo-a")
        b = inst.json("window", "new", "--name", "undo-b")
        wait_until(lambda: inst.cli("read", "--pane", b["pane"], check=False).stdout.strip() != "", 20)
        a2 = inst.json("pane", "info", inst.cli("split", "right", "--pane", a["pane"]).stdout.strip())["id"]
        time.sleep(0.4)
        inst.cli("pane", "move", a2, "--window", b["window"], "--dir", "right")
        time.sleep(0.4)
        ctl.call("debug.menu.perform", title="Undo")
        time.sleep(0.6)
        wa = next((w for w in inst.tree()["windows"] if w["id"] == a["window"]), None)
        wb = next((w for w in inst.tree()["windows"] if w["id"] == b["window"]), None)
        check("M-3 undo of a cross-window move restores the source window",
              wa is not None and sorted(p["id"] for p in wa["tabs"][0]["panes"]) == sorted([a["pane"], a2]),
              str(wa and [p["id"][:8] for p in wa["tabs"][0]["panes"]]))
        check("M-3 undo of a cross-window move restores the destination window",
              wb is not None and [p["id"] for p in wb["tabs"][0]["panes"]] == [b["pane"]])
        inst.cli("window", "close", a["window"], check=False)
        inst.cli("window", "close", b["window"], check=False)

        # E-3: dirty documents aren't closed silently; ⌘S saves.
        tmp = tempfile.mkdtemp(prefix="verify-editor-")
        txt = os.path.join(tmp, "notes.txt")
        with open(txt, "w") as f:
            f.write("plain notes\n")
        inst.cli("edit", txt, "--pane", win["pane"])
        doc = ctl.call("debug.editor.type", pane=win["pane"], path=txt, text="edited text", replace=True)
        check("E-3 typing makes the document dirty", doc["dirty"])
        proc = inst.cli("editor", "close", txt, "--pane", win["pane"], check=False)
        check("E-3 closing a dirty document is refused", proc.returncode != 0 and proc.stderr.strip())
        inst.cli("pane", "focus", win["pane"])
        ctl.call("debug.editor.focus", tab=win["tab"])
        time.sleep(0.3)
        save_title = next(i["title"] for i in items if i["key"] == "s" and i["modifiers"] == ["cmd"])
        ctl.call("debug.menu.perform", title=save_title)
        wait_until(lambda: open(txt).read().startswith("edited text"), 5, message="saved")
        check("E-3 ⌘S saves", open(txt).read() == "edited text")
        ctl.call("debug.editor.type", pane=win["pane"], path=txt, text=" more")
        inst.cli("editor", "close", txt, "--force", "--pane", win["pane"])
        check("E-3 --force discards", open(txt).read() == "edited text")

        # E-4: following the disk.
        with open(txt, "w") as f:
            f.write("plain notes\n")
        inst.cli("edit", txt, "--pane", win["pane"])
        with open(txt, "w") as f:
            f.write("changed on disk\n")
        ok = wait_until(lambda: ctl.call("debug.editor.type", pane=win["pane"], path=txt)["text"] == "changed on disk\n",
                        10, message="reload")
        check("E-4 an unmodified document reloads", ok)
        os.remove(txt)
        time.sleep(1)
        with open(txt, "w") as f:
            f.write("recreated\n")
        ok = wait_until(lambda: ctl.call("debug.editor.type", pane=win["pane"], path=txt)["text"] == "recreated\n",
                        10, message="recreated")
        check("E-4 a deleted and recreated file is picked up", ok)

        # A reload shorter than where the cursor was keeps the app running (AppKit throws if the
        # restored selection is empty).
        with open(txt, "w") as f:
            f.write("a much longer line of text than the reload will have\n")
        soon(lambda: ctl.call("debug.editor.type", pane=win["pane"], path=txt)["text"].startswith("a much"), 10)
        ctl.call("debug.editor.focus", tab=win["tab"], select_end=True)
        time.sleep(0.3)
        with open(txt, "w") as f:
            f.write("short\n")
        ok = soon(lambda: ctl.call("debug.editor.type", pane=win["pane"], path=txt)["text"] == "short\n", 10)
        check("E-4 a reload shorter than the cursor position doesn't crash", ok and inst.app_running())
        with open(txt, "w") as f:
            f.write("recreated\n")
        soon(lambda: ctl.call("debug.editor.type", pane=win["pane"], path=txt)["text"] == "recreated\n", 10)
        ctl.call("debug.editor.type", pane=win["pane"], path=txt, text=" (unsaved)")
        with open(txt, "w") as f:
            f.write("disk changed under edits\n")
        ok = wait_until(lambda: ctl.call("debug.editor.type", pane=win["pane"], path=txt)["changed_on_disk"], 10,
                        message="changed on disk flag")
        check("E-4 a modified document shows the disk changed", ok)
        inst.cli("editor", "close", txt, "--force", "--pane", win["pane"])

        # E-5: encodings.
        latin = os.path.join(tmp, "latin1.txt")
        with open(latin, "wb") as f:
            f.write("café crème\n".encode("latin-1"))
        inst.cli("edit", latin, "--pane", win["pane"])
        ctl.call("debug.editor.type", pane=win["pane"], path=latin, text="déjà vu\n", replace=True)
        ctl.call("debug.editor.focus", tab=win["tab"])
        ctl.call("debug.menu.perform", title=save_title)
        time.sleep(1)
        check("E-5 a Latin-1 file is saved in Latin-1", open(latin, "rb").read() == "déjà vu\n".encode("latin-1"))
        ctl.call("debug.editor.type", pane=win["pane"], path=latin, text="emoji 🎉\n", replace=True)
        ctl.call("debug.menu.perform", title=save_title)
        time.sleep(1)
        doc = ctl.call("debug.editor.type", pane=win["pane"], path=latin)
        check("E-5 text Latin-1 can't hold is refused, file intact",
              open(latin, "rb").read() == "déjà vu\n".encode("latin-1") and doc["dirty"] and doc["error"],
              doc.get("error"))
        inst.cli("editor", "close", latin, "--force", "--pane", win["pane"])

        # E-2: ⇧⌘M through the menu toggles a Markdown document.
        md = os.path.join(tmp, "README.md")
        with open(md, "w") as f:
            f.write("# Title\n")
        inst.cli("edit", md, "--pane", win["pane"])
        inst.cli("pane", "focus", win["pane"])
        m_title = titles[("m", ("shift", "cmd"))]
        ctl.call("debug.menu.perform", title=m_title)
        mode = next(d for d in inst.json("editor", "ls", "--pane", win["pane"])["documents"] if d["path"].endswith("README.md"))["mode"]
        check("E-2 ⇧⌘M toggles preview to source", mode == "source", mode)

        # Undo and redo of moving a tab's only pane keep the tab's unsaved editor documents.
        solo = inst.json("window", "new", "--name", "undo-editor")
        wait_until(lambda: inst.cli("read", "--pane", solo["pane"], check=False).stdout.strip() != "", 20)
        moved = os.path.join(tmp, "moved.txt")
        with open(moved, "w") as f:
            f.write("on disk\n")
        inst.cli("edit", moved, "--pane", solo["pane"])
        ctl.call("debug.editor.type", pane=solo["pane"], path=moved, text="unsaved edit\n", replace=True)

        def moved_doc():
            try:
                doc = ctl.call("debug.editor.type", pane=solo["pane"], path=moved)
            except RuntimeError:
                return None
            return doc if os.path.basename(doc["path"]) == "moved.txt" else None

        inst.cli("pane", "move", solo["pane"], "--new-tab")
        time.sleep(0.4)
        ctl.call("debug.menu.perform", title="Undo")
        time.sleep(0.6)
        doc = moved_doc()
        check("undo of a move keeps the tab's unsaved document", doc and doc["dirty"] and doc["text"] == "unsaved edit\n",
              str(doc and doc["text"]))
        ctl.call("debug.menu.perform", title="Redo")
        time.sleep(0.6)
        doc = moved_doc()
        check("redo of a move keeps the tab's unsaved document", doc and doc["dirty"] and doc["text"] == "unsaved edit\n",
              str(doc and doc["text"]))
        check("the file on disk wasn't touched", open(moved).read() == "on disk\n")
        inst.cli("editor", "close", moved, "--force", "--pane", solo["pane"])

        # Closing a pane in a hidden tab can be undone, with its program still running.
        h = inst.json("window", "new", "--name", "undo-hidden")
        wait_until(lambda: inst.cli("read", "--pane", h["pane"], check=False).stdout.strip() != "", 20)
        h2 = inst.json("pane", "info", inst.cli("split", "right", "--pane", h["pane"]).stdout.strip())["id"]
        wait_until(lambda: inst.cli("read", "--pane", h2, check=False).stdout.strip() != "", 20)
        inst.json("tab", "new", "--window", h["window"])
        time.sleep(0.4)
        inst.cli("pane", "close", h2)
        time.sleep(0.4)
        check("closing a pane in a hidden tab removes it", not inst.find_pane(h2))
        ctl.call("debug.menu.perform", title="Undo")
        ok = soon(lambda: bool(inst.find_pane(h2)), 5)
        check("undo brings back a pane closed in a hidden tab", ok and inst.find_pane(h2)[1]["id"] == h["tab"])
        marker = "HIDDEN-%d" % time.time()
        inst.cli("send", "--pane", h2, "-e", f"echo {marker}", check=False)
        check("the restored hidden pane's program still runs",
              inst.cli("wait", "--pane", h2, "--pattern", f"^{marker}", "--timeout", "10", check=False).returncode == 0)

        # Undoing New Tab leaves Redo, which opens the tab again.
        def tab_count():
            return len(next(w for w in inst.tree()["windows"] if w["id"] == h["window"])["tabs"])

        before = tab_count()
        inst.json("tab", "new", "--window", h["window"])
        time.sleep(0.4)
        ctl.call("debug.menu.perform", title="Undo")
        time.sleep(0.4)
        state = ctl.call("debug.undo")
        check("undoing New Tab closes it and leaves Redo", tab_count() == before and state["can_redo"]
              and state["redo"] == "New Tab", str(state))
        ctl.call("debug.menu.perform", title="Redo")
        time.sleep(0.4)
        check("redoing New Tab opens it again", tab_count() == before + 1)

        # Undo and Redo of a split made in a hidden tab bring the same pane back.
        hidden_tab = h["tab"]
        s = inst.cli("split", "down", "--pane", h["pane"], "--no-focus").stdout.strip()
        s_id = inst.json("pane", "info", s)["id"]
        time.sleep(0.4)
        ctl.call("debug.menu.perform", title="Undo")
        time.sleep(0.4)
        check("undo of a split removes the new pane", not inst.find_pane(s_id))
        ctl.call("debug.menu.perform", title="Redo")
        ok = soon(lambda: bool(inst.find_pane(s_id)), 5)
        check("redo of a split brings the same pane back", ok and inst.find_pane(s_id)[1]["id"] == hidden_tab)

        # A program running in a hidden tab makes closing the window (and quitting) ask first.
        q = inst.json("window", "new", "--name", "confirm")
        wait_until(lambda: inst.cli("read", "--pane", q["pane"], check=False).stdout.strip() != "", 20)
        busy = inst.json("tab", "new", "--window", q["window"])
        wait_until(lambda: inst.cli("read", "--pane", busy["pane"], check=False).stdout.strip() != "", 20)
        time.sleep(0.5)
        inst.cli("send", "--pane", busy["pane"], "-e", "sleep 90")
        inst.cli("tab", "focus", q["tab"])

        def needs_confirmation():
            return next(w for w in ctl.call("debug.confirm")["windows"] if w["window"] == q["window"])["needs_confirmation"]

        ok = soon(needs_confirmation, 10)
        check("a program in a hidden tab makes closing the window ask", ok)
        inst.cli("keys", "--pane", busy["pane"], "ctrl+c", check=False)
    finally:
        inst.cleanup()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
