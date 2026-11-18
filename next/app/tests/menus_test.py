#!/usr/bin/env python3
"""Checks the right-click menus and the shortcuts page's Ghostty section against a running UmiNext
started with UMI_NEXT_DEBUG=1: the terminal's menu (SPEC L-31, web/views/termmenu.js), a tab row's
menu (S-4, web/views/sidebar.js) and Ghostty's own keybindings on the shortcuts page (L-17). The
right-click into a terminal goes through the debug socket (NSApp.sendEvent), and the native menu
answers as if an item were chosen (a spy on the bridge's `menu`), so it types nothing on screen
and runs with UMI_NEXT_OFFSCREEN=1. It uses the clipboard (Copy, Paste, Copy branch).

  menus_test.py STATE_DIR SCRATCH_DIR [EXTRA_CONF]

SCRATCH_DIR is made into a small git repository (branch `menus-test`) for the tabs' folders.
EXTRA_CONF: the app's UMI_NEXT_TERMINAL_CONFIG, if it was started with one this test wrote
before (run once with the file missing to have it written, then restart the app with it):
`keybind = super+shift+u=scroll_to_top` and `keybind = super+shift+j=unbind`.
"""
import json, os, shutil, socket, subprocess, sys, time

state, scratch = sys.argv[1], os.path.abspath(sys.argv[2])
extra = sys.argv[3] if len(sys.argv) > 3 else None
fails = []


def D(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(30)
    s.connect(state + "/debug.sock")
    s.sendall(json.dumps(cmd).encode() + b"\n")
    b = b""
    while (d := s.recv(1 << 20)):
        b += d
    return json.loads(b)


def ev(js):
    r = D({"cmd": "eval", "js": js})
    if r.get("error"):
        raise RuntimeError(r["error"])
    return r["result"]


def J(js):
    return json.loads(ev("JSON.stringify(" + js + ")"))


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
    if not ok:
        fails.append(name)


def wait(fn, secs=5.0):
    end = time.time() + secs
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(0.1)
    return None


def pbpaste():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def spy(pick=None):
    """The next bridge `menu` request is recorded in window.__menu and answered with the item
    titled `pick` (None: dismissed)."""
    ev("""window.__menu = null; (() => { const orig = Umi.bridge.request;
      Umi.bridge.request = function (op, args, onEvent) {
        if (op !== 'menu') return orig.call(Umi.bridge, op, args, onEvent);
        Umi.bridge.request = orig;
        window.__menu = args.items.map((it) => (it.separator ? null
          : { title: it.title, key: it.key || null, enabled: it.enabled !== false, checked: !!it.checked }));
        const i = args.items.findIndex((it) => it.title === %s);
        return Promise.resolve({ index: i < 0 ? null : i });
      }; })(); 1""" % json.dumps(pick))


def titles(menu):
    return [m and m["title"] for m in menu]


# ---- setup: a git repository, a tab with two shells side by side ----
shutil.rmtree(scratch, ignore_errors=True)
os.makedirs(scratch)
for c in (["init", "-q", "-b", "menus-test"], ["commit", "-q", "--allow-empty", "-m", "start"]):
    subprocess.run(["git", "-C", scratch, "-c", "user.email=t@t", "-c", "user.name=t", *c], check=True)

start_tabs = J("Umi.state.layout.tabs.map((t) => t.id)")
ev("""(() => { const M = Umi.model, cwd = %s;
  Umi.app.update(() => {
    const t = M.addTab(M.newPane({ cwd, start: { cmd: null, name: 'menus-a', cwd } }));
    t.name = 'menus-a';
  });
})(); 1""" % json.dumps(scratch))
tab_a = J("Umi.state.layout.activeTab")
wait(lambda: J("Umi.model.sessionOf(Umi.model.activeTab().focused) || null"), 8)
ev("Umi.app.update(() => Umi.model.split('row', 'picker')); 1")
ev("""(() => { const M = Umi.model; Umi.app.update(() => M.startSession(M.activeTab().focused, { name: 'menus-b', cwd: %s })); })(); 1""" % json.dumps(scratch))
wait(lambda: J("Umi.model.paneIds(Umi.model.activeTab().root).every((id) => Umi.model.sessionOf(id))"), 8)
pane_a, pane_b = J("Umi.model.paneIds(Umi.model.activeTab().root)")
time.sleep(1.5)  # the shells' prompts


def screen(pane):
    return D({"cmd": "screen", "pane": pane}).get("text", "")


def send(pane, text):
    ev("Umi.bridge.request('sendText', {session: Umi.model.sessionOf(%s), text: %s}); 1" % (json.dumps(pane), json.dumps(text)))


def right_click(pane, pick=None):
    """Right-clicks the middle of the pane's terminal; returns the menu shown (None: no menu)."""
    spy(pick)
    r = J("Umi.views.panes.slotRects()[%s]" % json.dumps(pane))
    D({"cmd": "click", "x": r["x"] + r["w"] / 2, "y": r["y"] + r["h"] / 2, "button": "right"})
    return wait(lambda: J("window.__menu"), 3)


check("setup: two shells side by side", pane_a and pane_b and J("Umi.state.panes[%s] && 1" % json.dumps(pane_b)) == 1,
      J("Umi.model.activeTab()"))

# ---- the terminal's menu (L-31) ----
ev("Umi.bridge.request('clipboard', {text: 'echo pasted-$((6*7))'}); 1")
time.sleep(0.3)
m = right_click(pane_a)
want = ["Paste", None, "Clear", None, "Split Pane Right", "Split Pane Down", "Maximize Pane", "Close Pane", None,
        "Reset Terminal", "Terminal Read-only", None, "Change Tab Title...", "Change Terminal Title..."]
check("terminal menu: Umi's items in Umi's order (no selection, in a split)", m and titles(m) == want, m and titles(m))
keys = {i["title"]: i["key"] for i in (m or []) if i}
check("terminal menu: each item shows its key",
      keys.get("Paste") == "cmd+v" and keys.get("Clear") == "cmd+k" and keys.get("Split Pane Right") == "cmd+d"
      and keys.get("Split Pane Down") == "cmd+shift+d" and keys.get("Maximize Pane") == "cmd+shift+enter"
      and keys.get("Close Pane") == "cmd+w" and keys.get("Change Tab Title...") == "ctrl+cmd+r"
      and keys.get("Change Terminal Title...") == "ctrl+shift+cmd+r", keys)
check("terminal menu: Paste is on with text on the clipboard", m and m[0]["enabled"], m and m[0])

ev("Umi.app.update(() => Umi.model.focusPane(%s)); 1" % json.dumps(pane_b))
right_click(pane_a, "Paste")
check("Paste types the clipboard into the pane right-clicked (not the focused one)",
      wait(lambda: "echo pasted-$((6*7))" in screen(pane_a), 3) and "pasted" not in screen(pane_b), screen(pane_a)[-300:])
send(pane_a, "\r")
check("… and the shell ran it", wait(lambda: "pasted-42" in screen(pane_a).replace("echo pasted-$((6*7))", ""), 3))
check("Paste leaves the focus where it was", J("Umi.model.activeTab().focused") == pane_b)

ev("Umi.bridge.request('clipboard', {text: ''}); 1")
time.sleep(0.3)
m = right_click(pane_a)
check("Paste is greyed with nothing to paste", m and m[0]["title"] == "Paste" and not m[0]["enabled"], m and m[0])

send(pane_a, "seq 101 104\r")
wait(lambda: "104" in screen(pane_a), 3)
right_click(pane_a, "Clear")
check("Clear clears the screen", wait(lambda: "103" not in screen(pane_a), 3), screen(pane_a)[-200:])

# Text selected before the right-click: Copy first, no Paste or Clear.
send(pane_a, "echo menus-copy-me\r")
wait(lambda: screen(pane_a).count("menus-copy-me") >= 2, 3)
ev("Umi.app.update(() => Umi.model.focusPane(%s)); 1" % json.dumps(pane_a))
time.sleep(0.3)
D({"cmd": "shortcut", "key": "a", "mods": ["cmd"]})  # Ghostty's ⌘A: select all
time.sleep(0.3)
m = right_click(pane_a, "Copy")
check("with text selected: Copy, then the pane's items (no Paste or Clear)",
      m and titles(m)[:3] == ["Copy", None, "Split Pane Right"] and "Paste" not in titles(m), m and titles(m))
check("Copy copies the selection", wait(lambda: "menus-copy-me" in pbpaste(), 2), pbpaste()[:200])
D({"cmd": "shortcut", "key": "escape", "mods": []})
send(pane_a, "\u0015clear\r")
time.sleep(0.5)

# A full-screen program (the alternate screen): no Paste or Clear.
send(pane_a, "printf '\\033[?1049hfull screen'; sleep 3; printf '\\033[?1049l'\r")
wait(lambda: "full screen" in screen(pane_a) and "printf" not in screen(pane_a), 3)
m = right_click(pane_a)
check("in a full-screen program: no Paste or Clear", m and "Paste" not in titles(m) and "Clear" not in titles(m)
      and titles(m)[0] == "Split Pane Right", m and titles(m))
time.sleep(3)

# A program that reads the mouse gets the right-click: no menu.
send(pane_a, "printf '\\033[?1000h'; sleep 2; printf '\\033[?1000l'\r")
time.sleep(0.5)
check("a program reading the mouse gets the right-click (no menu)", right_click(pane_a) is None)
time.sleep(2)

# Read-only: checked once on; keys stop reaching the program.
right_click(pane_a, "Terminal Read-only")
time.sleep(0.3)
m = right_click(pane_a)
ro = next((i for i in m or [] if i and i["title"] == "Terminal Read-only"), None)
check("Terminal Read-only is checked when on", ro and ro["checked"], ro)
right_click(pane_a, "Terminal Read-only")
time.sleep(0.3)
m = right_click(pane_a)
ro = next((i for i in m or [] if i and i["title"] == "Terminal Read-only"), None)
check("… and unchecked when off again", ro and not ro["checked"], ro)

send(pane_a, "echo before-reset\r")
wait(lambda: "before-reset" in screen(pane_a).split("echo before-reset")[-1], 3)
right_click(pane_a, "Reset Terminal")
check("Reset Terminal resets (clears) the terminal", wait(lambda: "before-reset" not in screen(pane_a), 3), screen(pane_a)[-200:])

ev("Umi.app.update(() => Umi.model.focusPane(%s)); 1" % json.dumps(pane_b))
right_click(pane_a, "Maximize Pane")
check("Maximize Pane zooms the pane right-clicked", J("Umi.model.activeTab().zoomed") == pane_a, J("Umi.model.activeTab()"))
m = right_click(pane_a, "Minimize Pane")
check("… whose menu then says Minimize Pane, which unzooms", m and "Minimize Pane" in titles(m) and not J("Umi.model.activeTab().zoomed || null"))

right_click(pane_a, "Change Tab Title...")
check("Change Tab Title... renames the tab in its row", J("Umi.state.ui.editingTab") == tab_a)
ev("Umi.app.update(() => { Umi.state.ui.editingTab = null; Umi.state.ui.tabDraft = null; }); 1")
right_click(pane_a, "Change Terminal Title...")
check("Change Terminal Title... renames the pane's session",
      J("[Umi.state.ui.panel?.mode, Umi.state.ui.panel?.sid]") == ["rename", J("Umi.model.sessionOf(%s)" % json.dumps(pane_a))])
ev("Umi.app.update(() => Umi.model.closePanel()); 1")

ev("Umi.app.update(() => Umi.model.focusPane(%s)); 1" % json.dumps(pane_b))
right_click(pane_a, "Split Pane Down")
ids = J("Umi.model.paneIds(Umi.model.activeTab().root)")
new = [i for i in ids if i not in (pane_a, pane_b)]
check("Split Pane Down splits the pane right-clicked into the picker, focused",
      len(new) == 1 and J("Umi.model.activeTab().focused") == new[0] and J("Umi.model.findPane(%s).node.view" % json.dumps(new[0])) == "picker"
      and J("Umi.model.activeTab().root.a.type") == "split", J("Umi.model.activeTab().root"))
ev("Umi.app.update(() => Umi.model.removePane(%s)); 1" % json.dumps(new[0]))
right_click(pane_a, "Split Pane Right")
new = [i for i in J("Umi.model.paneIds(Umi.model.activeTab().root)") if i not in (pane_a, pane_b)]
check("Split Pane Right splits it to the right", len(new) == 1 and J("Umi.model.paneIds(Umi.model.activeTab().root)") == [pane_a, new[0], pane_b])
ev("Umi.app.update(() => Umi.model.removePane(%s)); 1" % json.dumps(new[0]))

sid_b = J("Umi.model.sessionOf(%s)" % json.dumps(pane_b))
right_click(pane_b, "Close Pane")
check("Close Pane closes the pane right-clicked, as ⌘W", wait(lambda: J("Umi.model.paneIds(Umi.model.activeTab().root)") == [pane_a], 3))
m = right_click(pane_a)
check("outside a split: no Maximize or Close Pane", m and "Close Pane" not in titles(m) and "Maximize Pane" not in titles(m), m and titles(m))

# ---- cleanup: the tabs and sessions this made ----
ev("""(() => { const keep = new Set(%s);
  for (const t of Umi.state.layout.tabs.filter((t) => !keep.has(t.id)))
    for (const id of Umi.model.paneIds(t.root)) { const s = Umi.model.sessionOf(id); if (s) Umi.bridge.post({ type: 'exitSession', session: s }); }
  Umi.app.update(() => { for (const t of Umi.state.layout.tabs.filter((t) => !keep.has(t.id))) Umi.model.paneIds(t.root).forEach((id) => Umi.model.removePane(id)); });
})(); 1""" % json.dumps(start_tabs))

print(f"\n{len(fails)} failed" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
