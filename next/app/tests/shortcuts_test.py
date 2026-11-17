#!/usr/bin/env python3
"""Checks the page-owned shortcut table against a running UmiNext started with UMI_NEXT_DEBUG=1,
with real key events through the HID tap (`key` and `hyper`, built from key.swift and
hyper.swift next to this file; the caller needs Accessibility), on a Mac where it may take the
screen (under `lockf -k ~/umi-screen.lock`). Also checks that keys outside the table reach the
terminal, and that a table entry added to web/shortcuts.js works after the page reloads.

  shortcuts_test.py STATE_DIR KEY_BIN HYPER_BIN [--debug-events]

--debug-events sends keys through the debug socket (NSApp.sendEvent) instead of the HID tap.
"""
import json, os, socket, subprocess, sys, time

state, key_bin, hyper_bin = sys.argv[1:4]
debug_events = "--debug-events" in sys.argv
here = os.path.dirname(os.path.abspath(__file__))
fails = []


def D(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.connect(state + "/debug.sock")
    s.sendall(json.dumps(cmd).encode() + b"\n")
    b = b""
    while True:
        d = s.recv(1 << 20)
        if not d:
            break
        b += d
    return json.loads(b)


def ev(js):
    r = D({"cmd": "eval", "js": js})
    if r.get("error"):
        raise RuntimeError(r["error"])
    return r["result"]


def ui():
    return json.loads(ev("""JSON.stringify((() => { const S = Umi.state, M = Umi.model, t = M.activeTab();
      return { tabs: S.layout.tabs.length, tab: S.layout.tabs.indexOf(t), focused: t.focused, view: M.focusedPane()?.view,
               panes: M.paneIds(t.root).length, sidebar: S.layout.sidebar !== false, panel: S.ui.panel?.name || null,
               editing: S.ui.editingTab, keys: S.ui.keys }; })())"""))


CODES = {"t": 17, "d": 2, "w": 13, "b": 11, "[": 33, "]": 30, "1": 18, "2": 19, "3": 20, "9": 25, "k": 40, "x": 7,
         "left": 123, "right": 124, "down": 125, "up": 126, "space": 49, "escape": 53, "r": 15, "enter": 36}


LETTERS = dict(zip("asdfhgzxcvbqweryt", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17]))
LETTERS.update({"o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49})


def press(k, *mods):
    if debug_events:
        if k == "escape":
            D({"cmd": "keys", "text": "\x1b"})
        else:
            D({"cmd": "shortcut", "key": {"space": " ", "enter": "\r"}.get(k, k), "mods": list(mods)})
    else:
        real_key(CODES[k], *mods)
    time.sleep(0.35)


def in_front():
    # Real events go to whatever app is in front: never send one unless it's this window.
    if not D({"cmd": "state"}).get("active"):
        sys.exit("FAIL this UmiNext lost the front; stopped before sending keys elsewhere")


def real_key(code, *mods):
    in_front()
    subprocess.run([key_bin, str(code), *mods], check=True)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  ({detail})" if not ok else ""))
    if not ok:
        fails.append(name)


def focus_terminal():
    """Leaves the focused tab's pane on a terminal with the keys (Escape out of pickers/fields)."""
    for _ in range(3):
        u = ui()
        if u["keys"] == "terminal" and u["view"] == "terminal":
            return True
        if u["view"] == "picker":
            # Start a shell in the picker: Tab twice (claude → codex → shell), Enter.
            ev("""(() => { const M = Umi.model; Umi.app.update(() => M.startSession(M.activeTab().focused, {name: 'sc-test'})); })(); 1""")
            time.sleep(1.5)
        else:
            press("escape")
    u = ui()
    return u["keys"] == "terminal"


sys.path.insert(0, here)
from front import bring_to_front
if not bring_to_front(D) and not debug_events:
    sys.exit("FAIL this UmiNext isn't in front with the keys; no real keys sent")
st = D({"cmd": "state"})
check("native learned the table", "newTab" in st.get("shortcuts", []) and "palette" in st.get("shortcuts", []), st.get("shortcuts"))
check("table saved for launch", os.path.exists(state + "/shortcuts.json"))
check("a terminal has the keys", focus_terminal(), ui())

# Typing outside the table reaches the terminal.
marker = "zq" + "".join("abcdefghij"[int(c)] for c in str(int(time.time() * 1000) % 100000))
if debug_events:
    D({"cmd": "keys", "text": "echo " + marker + "\r"})
else:
    for ch in "echo " + marker:
        real_key(LETTERS[ch])
    press("enter")
time.sleep(0.8)
check("plain keys reach the terminal", marker in D({"cmd": "screen"}).get("text", ""))

before = ui()
press("t", "cmd")
u = ui()
check("⌘T new tab (name in edit mode)", u["tabs"] == before["tabs"] + 1 and u["editing"], (before, u))
press("escape")
focus_terminal()
press("1", "cmd")
check("⌘1 first tab", ui()["tab"] == 0)
press("]", "cmd", "shift")
check("⇧⌘] next tab", ui()["tab"] == 1)
press("[", "cmd", "shift")
check("⇧⌘[ previous tab", ui()["tab"] == 0)
press("9", "cmd")
check("⌘9 last tab", ui()["tab"] == ui()["tabs"] - 1)
press("1", "cmd")
focus_terminal()

b = ui()
press("d", "cmd")
u = ui()
check("⌘D split right into the picker", u["panes"] == b["panes"] + 1 and u["view"] == "picker", u)
picker = u["focused"]
press("left", "cmd", "opt")
check("⌥⌘← focus left", ui()["focused"] != picker, ui())
press("right", "cmd", "opt")
check("⌥⌘→ focus right", ui()["focused"] == picker, ui())
press("w", "cmd")
check("⌘W hides the pane", ui()["panes"] == b["panes"], ui())
focus_terminal()
press("d", "cmd", "shift")
u = ui()
check("⇧⌘D split down into the picker", u["panes"] == b["panes"] + 1 and u["view"] == "picker", u)
down = u["focused"]
press("up", "cmd", "opt")
check("⌥⌘↑ focus up", ui()["focused"] != down)
press("down", "cmd", "opt")
check("⌥⌘↓ focus down", ui()["focused"] == down)
press("w", "cmd")
focus_terminal()

s0 = ui()["sidebar"]
press("b", "cmd")
check("⌘B toggles the sidebar", ui()["sidebar"] != s0)
press("b", "cmd")
check("⌘B again", ui()["sidebar"] == s0)

focus_terminal()
if debug_events:
    press("space", "cmd", "shift", "opt", "ctrl")
else:
    in_front()
    subprocess.run([hyper_bin, "space"], check=True)
    time.sleep(0.35)
check("Hyper+Space opens the palette", ui()["panel"] == "palette", ui())
press("escape")
check("Escape closes it", ui()["panel"] is None, ui())
if not debug_events:
    focus_terminal()
    in_front()
    subprocess.run([hyper_bin, "tap"], check=True)
    time.sleep(0.35)
    check("Hyper tap opens the palette", ui()["panel"] == "palette", ui())
    press("escape")

# ⇧⌘R reloads the page natively.
n0 = len(D({"cmd": "state"})["reloads"])
press("r", "cmd", "shift")
time.sleep(1.5)
check("⇧⌘R reloads the web layer", len(D({"cmd": "state"})["reloads"]) > n0)

# A new entry in web/shortcuts.js works after the live reload, with no rebuild.
web = D({"cmd": "state"})["webDir"]
path = web + "/shortcuts.js"
src = open(path).read()
entry = "    { id: 'testToggleSidebar', keys: 'cmd+shift+k', label: 'test', group: 'Test', action: 'toggleSidebar' },\n"
anchor = "    { id: 'reloadWeb'"
try:
    focus_terminal()
    s0 = ui()["sidebar"]
    press("k", "cmd", "shift")
    check("⇧⌘K not in the table: sidebar unchanged", ui()["sidebar"] == s0)
    open(path, "w").write(src.replace(anchor, entry + anchor, 1))
    for _ in range(40):
        time.sleep(0.25)
        st = D({"cmd": "state"})
        if "testToggleSidebar" in st.get("shortcuts", []) and st.get("webReady"):
            break
    check("native learned the edited table", "testToggleSidebar" in D({"cmd": "state"}).get("shortcuts", []))
    focus_terminal()
    press("k", "cmd", "shift")
    check("the new ⇧⌘K works", ui()["sidebar"] != s0)
    press("k", "cmd", "shift")
finally:
    open(path, "w").write(src)
for _ in range(40):
    time.sleep(0.25)
    if "testToggleSidebar" not in D({"cmd": "state"}).get("shortcuts", []):
        break
check("table restored", "testToggleSidebar" not in D({"cmd": "state"}).get("shortcuts", []))

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
