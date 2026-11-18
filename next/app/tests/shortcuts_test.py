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
# `click` (built from click.swift) next to `key`: real clicks for the strip checks.
click_bin = os.path.join(os.path.dirname(os.path.abspath(key_bin)), "click")
debug_events = "--debug-events" in sys.argv
here = os.path.dirname(os.path.abspath(__file__))
fails = []


def D(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(30)  # a reply that never comes fails the run instead of hanging it
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
         "left": 123, "right": 124, "down": 125, "up": 126, "space": 49, "escape": 53, "r": 15, "enter": 36, "tab": 48, "=": 24,
         "f": 3, "g": 5, "h": 4, "i": 34, "a": 0, "p": 35, "j": 38, "/": 44, "-": 27, "0": 29, ".": 47, ",": 43, "v": 9}


LETTERS = dict(zip("asdfhgzxcvbqweryt", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17]))
LETTERS.update({"o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49})


def press(k, *mods):
    if debug_events:
        if k == "escape":
            D({"cmd": "keys", "text": "\x1b"})
        else:
            D({"cmd": "shortcut", "key": {"space": " ", "enter": "\r", "tab": "\t"}.get(k, k), "mods": list(mods)})
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
if not debug_events and not bring_to_front(D):
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
press("tab", "ctrl")
check("⌃Tab next tab", ui()["tab"] == 1, ui())
press("tab", "ctrl", "shift")
check("⌃⇧Tab previous tab", ui()["tab"] == 0, ui())
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
press("[", "cmd")
check("⌘[ previous pane", ui()["focused"] != picker, ui())
press("]", "cmd")
check("⌘] next pane", ui()["focused"] == picker, ui())
press("w", "cmd")
check("⌘W closes the picker pane", ui()["panes"] == b["panes"], ui())
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
# Without the sidebar, the top bar's tab chips stay clear of the window's close/minimize/zoom buttons.
if not ui()["sidebar"]:
    check("the top bar's first chip starts right of the window buttons",
          json.loads(ev("JSON.stringify(document.querySelector('#strip .chip').getBoundingClientRect().left)")) >= 78)
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

# ---- Track (c): shortcuts page, hidden-pane strip, zoom, tabs, reopen, find, sync, UI zoom ----
def J(js):
    return json.loads(ev("JSON.stringify(" + js + ")"))


def wait(fn, secs=3.0):
    end = time.time() + secs
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    return False


def type_text(text):
    """Types into whatever has the keys (`\r` presses Enter)."""
    if debug_events:
        D({"cmd": "keys", "text": text})
    else:
        for ch in text:
            if ch == "\r":
                press("enter")
            else:
                real_key(LETTERS[ch])
    time.sleep(0.3)


def new_shell_split():
    """⌘D and a shell in the picker: the tab gets one more terminal, focused."""
    press("d", "cmd")
    ev("""(() => { const M = Umi.model; Umi.app.update(() => M.startSession(M.activeTab().focused, {name: 'sc-split'})); })(); 1""")
    wait(lambda: J("Umi.model.sessionOf(Umi.model.activeTab().focused) || null"), 5)
    time.sleep(0.8)


def visible_panes():
    return {p["id"] for p in D({"cmd": "state"})["panes"] if p["visible"]}


def tag(prefix):
    return prefix + "".join("abcdefghij"[int(c)] for c in str(int(time.time() * 1000) % 100000))


# ⌘/ opens the shortcuts page drawn from the table; search by keys and by name; Esc closes.
focus_terminal()
press("/", "cmd")
check("⌘/ opens the shortcuts page", J("!!Umi.state.layout.shortcutsPage") and ui()["keys"] == "web", ui())
labelled = J("new Set(Umi.shortcuts.table.filter((e) => e.label).map((e) => (e.group || 'Other') + '/' + e.label)).size")
check("the page lists every action in the table (one row per action)", J("document.querySelectorAll('#shortcuts .sc-row').length") == labelled)
for q, want in [("cmd shift d", "splitDown"), ("shift cmd d", "splitDown"), ("⇧⌘D", "splitDown"), ("zoom the pane", "toggleZoom")]:
    ev(f"""(() => {{ const i = document.querySelector('#shortcuts input'); i.value = {json.dumps(q)}; i.dispatchEvent(new Event('input')); }})(); 1""")
    ids = J("[...document.querySelectorAll('#shortcuts .sc-row')].map((r) => r.dataset.id)")
    check(f"page search {q!r} finds {want}", want in ids and len(ids) <= 3, ids)
press("escape")
check("Esc closes the shortcuts page", not J("!!Umi.state.layout.shortcutsPage") and ui()["keys"] == "terminal", ui())
press("/", "cmd")
press("/", "cmd")
check("⌘/ again closes it", not J("!!Umi.state.layout.shortcutsPage"))
focus_terminal()

# ⌘W closes a pane and ends its session, a shell's too: no chip, gone from the daemon.
new_shell_split()
two = ui()
sid = J("Umi.model.sessionOf(Umi.model.activeTab().focused)")
press("w", "cmd")
check("⌘W closes the pane", ui()["panes"] == two["panes"] - 1 and not J("document.querySelectorAll('#strip .chip.hidden').length"), ui())
check("⌘W ends the shell's session", wait(lambda: J(f"!Umi.state.live[{json.dumps(sid)}] || Umi.state.live[{json.dumps(sid)}].alive === false"), 5))
n_reopen = ui()["panes"]
press("t", "cmd", "shift")
time.sleep(0.8)
check("⇧⌘T can't bring back a shell ⌘W ended", ui()["panes"] == n_reopen, ui())

# ⌥⌘H hides a pane: its session gets a dim chip after the shown ones; clicking it shows it again
# at the right end, focused (through native's title-bar hit test).
new_shell_split()
two = ui()
sid = J("Umi.model.sessionOf(Umi.model.activeTab().focused)")
press("h", "cmd", "opt")
hidden = J("[...document.querySelectorAll('#strip .chip.hidden')].map((c) => c.dataset.session)")
check("⌥⌘H puts the session on a hidden chip", hidden == [sid] and ui()["panes"] == two["panes"] - 1, (hidden, sid))
check("the hidden session keeps running", J(f"Umi.state.live[{json.dumps(sid)}]?.alive !== false"))
r = J("(() => { const r = document.querySelector('#strip .chip.hidden').getBoundingClientRect(); return {x: r.left + r.width / 2, y: r.top + r.height / 2}; })()")
if debug_events:
    # A synthesized click into an inactive window does not reach the page: send the chip its mousedown.
    ev("document.querySelector('#strip .chip.hidden').dispatchEvent(new MouseEvent('mousedown', {bubbles: true})); 1")
else:
    in_front()
    subprocess.run([click_bin, str(r["x"] + D({"cmd": "state"})["contentOriginGlobal"]["x"]),
                    str(r["y"] + D({"cmd": "state"})["contentOriginGlobal"]["y"])], check=True)
time.sleep(0.6)
check("clicking the hidden chip shows it again, focused at the right end",
      J("Umi.model.sessionOf(Umi.model.activeTab().focused)") == sid
      and J("Umi.model.paneIds(Umi.model.activeTab().root).slice(-1)[0] === Umi.model.activeTab().focused")
      and not J("document.querySelectorAll('#strip .chip.hidden').length"), ui())

# ⇧⌘↩ zooms the focused pane: the other terminals leave the screen; again: back.
focus_terminal()
before = visible_panes()
press("enter", "cmd", "shift")
time.sleep(0.4)
check("⇧⌘↩ zooms the pane", J("Umi.model.activeTab().zoomed || null") == ui()["focused"] and len(visible_panes()) == 1, visible_panes())
press("enter", "cmd", "shift")
time.sleep(0.4)
check("⇧⌘↩ again unzooms", not J("Umi.model.activeTab().zoomed || null") and visible_panes() == before)

# ⌃⌘← / → move the pane within the tab; ⌃⌘T to a new tab; ⌃⌘↑ to the tab above.
order = J("Umi.model.paneIds(Umi.model.activeTab().root)")
i = order.index(ui()["focused"])
want = order[:]
want[i - 1], want[i] = want[i], want[i - 1]
press("left", "ctrl", "cmd")
check("⌃⌘← moves the pane left", J("Umi.model.paneIds(Umi.model.activeTab().root)") == want, J("Umi.model.paneIds(Umi.model.activeTab().root)"))
press("right", "ctrl", "cmd")
check("⌃⌘→ moves it back", J("Umi.model.paneIds(Umi.model.activeTab().root)") == order)
n, np = ui()["tabs"], ui()["panes"]
press("t", "ctrl", "cmd")
check("⌃⌘T moves the pane to a new tab", ui()["tabs"] == n + 1 and ui()["panes"] == 1, ui())
press("up", "ctrl", "cmd")
check("⌃⌘↑ moves it to the tab above (the empty tab closes)", ui()["tabs"] == n and ui()["panes"] == np, ui())

# Tabs: ⌃⌘P pins (pinned tabs first), ⌃⇧↑↓ move within the group, ⌃⌘A archives.
focus_terminal()
press("t", "cmd"); press("escape"); focus_terminal()
press("t", "cmd"); press("escape"); focus_terminal()
last = J("Umi.state.layout.activeTab")
press("p", "ctrl", "cmd")
check("⌃⌘P pins the tab: it goes first", J("Umi.state.layout.tabs[0].id") == last and J("!!Umi.state.layout.tabs[0].pinned"))
press("down", "ctrl", "shift")
check("⌃⇧↓ doesn't take a pinned tab past the unpinned ones", J("Umi.state.layout.tabs[0].id") == last)
press("p", "ctrl", "cmd")
check("⌃⌘P again unpins (top of the others)", J("Umi.state.layout.tabs[0].id") == last and not J("!!Umi.state.layout.tabs[0].pinned"))
press("down", "ctrl", "shift")
check("⌃⇧↓ moves the tab down", J("Umi.state.layout.tabs[1].id") == last)
press("up", "ctrl", "shift")
check("⌃⇧↑ moves it up", J("Umi.state.layout.tabs[0].id") == last)
press("a", "ctrl", "cmd")
check("⌃⌘A archives the tab and selects another",
      J(f"!!Umi.state.layout.tabs.find((t) => t.id === {json.dumps(last)}).archived")
      and J("Umi.state.layout.activeTab") != last and "Archived · 1" in (J("document.querySelector('.archive-row')?.textContent || ''")))
press("1", "cmd")
check("⌘1 skips the archived tab", J("Umi.state.layout.activeTab") != last)
ev("Umi.app.run('showArchived'); 1")
check("Show archived selects it, still archived", J("Umi.state.layout.activeTab") == last and J("Umi.model.activeTab().archived > 0"))
press("a", "ctrl", "cmd")
check("⌃⌘A on an archived tab brings it back", not J("!!Umi.model.activeTab().archived") and not J("!!document.querySelector('.archive-row')"))

# ⌥⌘W closes the tab (sessions keep running); ⇧⌘T reopens it with its sessions.
press("9", "cmd")
focus_terminal()
sids = J("Umi.model.paneIds(Umi.model.activeTab().root).map((id) => Umi.model.sessionOf(id))")
n = ui()["tabs"]
press("w", "cmd", "opt")
check("⌥⌘W closes the tab", ui()["tabs"] == n - 1)
press("t", "cmd", "shift")
time.sleep(0.8)
check("⇧⌘T reopens it with its sessions", ui()["tabs"] == n and
      J("Umi.model.paneIds(Umi.model.activeTab().root).map((id) => Umi.model.sessionOf(id))") == sids, ui())
press("1", "cmd")

# ⌥⌘H hides one pane of a split; ⇧⌘T brings that pane back in its old place and size (L-20).
focus_terminal()
if ui()["panes"] < 2:
    new_shell_split()
shape = "JSON.stringify((function f(n) { return n.type === 'pane' ? Umi.model.sessionOf(n.id) : [n.dir, Math.round(n.ratio * 1000), f(n.a), f(n.b)]; })(Umi.model.activeTab().root))"
before = J(shape)
gone = J("Umi.model.sessionOf(Umi.model.activeTab().focused)")
np = ui()["panes"]
press("h", "cmd", "opt")
check("⌥⌘H hides the pane", ui()["panes"] == np - 1 and J(f"!Umi.model.paneOfSession({json.dumps(gone)})"), ui())
press("t", "cmd", "shift")
time.sleep(0.8)
check("⇧⌘T brings that pane back in its place and size, focused", J(shape) == before
      and J("Umi.model.sessionOf(Umi.model.activeTab().focused)") == gone, (J(shape), before))

# ⇧⌘T after ⌘W closed an agent: a new session runs the agent's resume command in the old place.
# (The fake reopen entry stands in for a Claude pane; its resume command only prints.)
focus_terminal()
before = J(shape)
ev("""(() => { const M = Umi.model, t = M.activeTab(), id = t.focused;
  const root = JSON.parse(JSON.stringify(t.root));
  Umi.state.layout.reopen = [{ kind: 'pane', tab: t.id, pane: 'gone-pane', session: 'gone-session',
    resume: { cmd: 'echo resumed-agent; exec sleep 100', name: 'resumed', cwd: Umi.state.home },
    root: { type: 'split', dir: 'row', ratio: 0.5, a: root, b: { type: 'pane', id: 'gone-pane', view: 'terminal' } } }]; })(); 1""")
press("t", "cmd", "shift")
ok = wait(lambda: J("(() => { const sid = Umi.model.sessionOf(Umi.model.activeTab().focused); return !!sid && Umi.model.sessionName(sid) === 'resumed'; })()"), 8)
check("⇧⌘T after ⌘W on an agent resumes it in a new session, focused at its old place", ok
      and J("Umi.model.paneIds(Umi.model.activeTab().root).slice(-1)[0] === Umi.model.activeTab().focused"), ui())
press("w", "cmd")


# ⌘= ⌘- ⌘0 zoom the page and the terminals' text; ⌥⇧> ⌥⇧< the font size.
def cols():
    f = ui()["focused"]
    return next(p["grid"]["cols"] for p in D({"cmd": "state"})["panes"] if p["id"] == f)


focus_terminal()
c0 = cols()
press("=", "cmd")
time.sleep(0.6)
check("⌘= zooms in (110%, terminals' text too)", J("Umi.state.layout.zoom.ui") == 1.1 and cols() < c0, (J("Umi.state.layout.zoom"), cols(), c0))
press("-", "cmd")
press("-", "cmd")
time.sleep(0.6)
check("⌘- zooms out (90%)", J("Umi.state.layout.zoom.ui") == 0.9 and cols() > c0, cols())
press("0", "cmd")
time.sleep(0.6)
check("⌘0 back to 100%", J("Umi.state.layout.zoom.ui") == 1 and cols() == c0, cols())
press(".", "opt", "shift")
time.sleep(0.6)
check("⌥⇧> one point bigger", J("Umi.state.layout.zoom.font") == 1 and cols() < c0, cols())
press(",", "opt", "shift")
time.sleep(0.6)
check("⌥⇧< one point smaller", J("Umi.state.layout.zoom.font") == 0 and cols() == c0, cols())

# ⌘F finds in the terminal (Ghostty's search): count, ⌘G next, Esc closes.
focus_terminal()
word = tag("fq")
type_text("echo " + word + " " + word + "\r")
time.sleep(0.6)
press("f", "cmd")
check("⌘F opens the find bar with the keys", J("!!Umi.state.ui.find") and ui()["keys"] == "web" and not J("document.querySelector('#findbar').hidden"))
type_text(word)
wait(lambda: (J("Umi.state.ui.find.total") or 0) >= 3, 4)
f = J("Umi.state.ui.find")
check("the find bar counts the matches (the command line twice and the output)", (f.get("total") or 0) >= 3, f)
check("the count shows in the bar", " of " in J("document.querySelector('#findbar .count').textContent"))
sel0 = J("Umi.state.ui.find.selected")
press("g", "cmd")
wait(lambda: J("Umi.state.ui.find.selected") != sel0, 2)
check("⌘G selects the next match", J("Umi.state.ui.find.selected") != sel0, (sel0, J("Umi.state.ui.find")))
press("escape")
check("Esc closes the find bar; the terminal has the keys", not J("!!Umi.state.ui.find") and ui()["keys"] == "terminal", ui())

# ⌥⌘I synchronizes input across the tab's terminals; ⌥⇧⌘I stops.
focus_terminal()
if ui()["panes"] < 2:
    new_shell_split()
panes = J("Umi.model.paneIds(Umi.model.activeTab().root)")
press("i", "cmd", "opt")
check("⌥⌘I syncs the tab (link mark in its row)",
      J("Umi.arrange.isSynced(Umi.model.activeTab())") and J("!!document.querySelector('.tab.active .mark.sync')"))
mark = tag("sy")
type_text("echo " + mark + "\r")
time.sleep(0.8)
got = [mark in D({"cmd": "screen", "pane": p}).get("text", "") for p in panes]
check("typing reaches every terminal of the synced tab", len(panes) > 1 and all(got), got)
# ⌘V pastes into every synced terminal (native sends the paste to each).
mark3 = tag("sp")
ev(f"Umi.bridge.request('clipboard', {{text: {json.dumps('echo ' + mark3)}}}); 1")
time.sleep(0.3)
press("v", "cmd")
press("enter")
time.sleep(0.8)
got = [D({"cmd": "screen", "pane": p}).get("text", "").count(mark3) for p in panes]
check("⌘V pastes into every terminal of the synced tab (the command and its output)", len(panes) > 1 and all(n >= 2 for n in got), got)
press("i", "cmd", "opt", "shift")
check("⌥⇧⌘I stops syncing", not J("Umi.arrange.isSynced(Umi.model.activeTab())"))
mark2 = tag("sz")
type_text("echo " + mark2 + "\r")
time.sleep(0.8)
got = [mark2 in D({"cmd": "screen", "pane": p}).get("text", "") for p in panes]
check("after stopping, typing reaches only the focused terminal", sum(got) == 1, got)

# The pane indicator, the Dock badge and ⌃⌘J / ⌃⌘K, from a fake agent's hook file.
focus_terminal()
if ui()["panes"] < 2:
    new_shell_split()
here_sid = J("Umi.model.sessionOf(Umi.model.activeTab().focused)")
other_pane = J("Umi.model.paneIds(Umi.model.activeTab().root).find((id) => id !== Umi.model.activeTab().focused)")
other = J(f"Umi.model.sessionOf({json.dumps(other_pane)})")
agent_file = f"{state}/agents/{other}.json"


def fake_agent(event):
    with open(agent_file, "w") as f:
        json.dump({"agent": "claude", "event": event, "ts": time.time(), "input": {}}, f)


NAME_X = "document.querySelector(`#strip .chip[data-tab=\"${Umi.model.activeTab().id}\"] span:not(.pane-mark)`).getBoundingClientRect().left"
name_x = J(NAME_X)
check("an idle tab's chip has its mark, in the idle grey",
      J("(() => { const m = document.querySelector(`#strip .chip[data-tab=\"${Umi.model.activeTab().id}\"] .pane-mark`); return !!m && !m.dataset.state; })()"))
try:
    fake_agent("PermissionRequest")
    wait(lambda: J(f"Umi.views.marks.stateOf({json.dumps(other)})") == "needs", 5)
    check("a pane needing you shows the amber mark in its header",
          J(f"document.querySelector('#panes .pane-head[data-pane=\"{other_pane}\"] .pane-mark')?.dataset.state || null") == "needs")
    check("its tab's chip in the top bar shows the mark too",
          J("document.querySelector(`#strip .chip[data-tab=\"${Umi.model.activeTab().id}\"] .pane-mark`)?.dataset.state || null") == "needs")
    check("the tab's name stays put when its mark changes colour", J(NAME_X) == name_x, (J(NAME_X), name_x))
    check("no mark sits over the terminals", not J("document.querySelectorAll('#panes .slot .pane-mark').length"))
    check("the Dock badge counts it", wait(lambda: D({"cmd": "state"}).get("badge") == "1", 3), D({"cmd": "state"}).get("badge"))
    press("j", "ctrl", "cmd")
    check("⌃⌘J goes to the session waiting for you", J("Umi.model.sessionOf(Umi.model.activeTab().focused)") == other)
    press("k", "ctrl", "cmd")
    check("⌃⌘K goes back to where the walk started", J("Umi.model.sessionOf(Umi.model.activeTab().focused)") == here_sid)
    fake_agent("UserPromptSubmit")
    wait(lambda: J(f"Umi.views.marks.stateOf({json.dumps(other)})") == "working", 5)
    check("a working pane shows the working mark",
          J(f"document.querySelector('#panes .pane-head[data-pane=\"{other_pane}\"] .pane-mark')?.dataset.state || null") == "working")
    check("the badge clears", wait(lambda: D({"cmd": "state"}).get("badge") in (None, ""), 3), D({"cmd": "state"}).get("badge"))
finally:
    os.remove(agent_file)

# Dragging the sidebar's edge sets its width (180–600); the terminals move with it.
x0 = min(p["frame"]["x"] for p in D({"cmd": "state"})["panes"] if p["visible"])
ev("""(() => { const e = document.querySelector('#sidebar-edge'), r = e.getBoundingClientRect(), x = r.left + 3, y = 200;
  e.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: x, clientY: y}));
  window.dispatchEvent(new MouseEvent('mousemove', {clientX: x + 80, clientY: y}));
  window.dispatchEvent(new MouseEvent('mouseup', {clientX: x + 80, clientY: y})); })(); 1""")
time.sleep(0.5)
w = J("Umi.state.layout.sidebarWidth")
x1 = min(p["frame"]["x"] for p in D({"cmd": "state"})["panes"] if p["visible"])
check("dragging the sidebar's edge widens it and moves the terminals", w and abs((x1 - x0) - 80) < 2, (w, x0, x1))
ev("""(() => { const e = document.querySelector('#sidebar-edge'), r = e.getBoundingClientRect(), x = r.left + 3, y = 200;
  e.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: x, clientY: y}));
  window.dispatchEvent(new MouseEvent('mousemove', {clientX: x - 2000, clientY: y}));
  window.dispatchEvent(new MouseEvent('mouseup', {clientX: x - 2000, clientY: y})); })(); 1""")
time.sleep(0.3)
check("the sidebar stops at 180", J("Umi.state.layout.sidebarWidth") == 180)
ev("Umi.app.update(() => { delete Umi.state.layout.sidebarWidth; document.documentElement.style.removeProperty('--sidebar-width'); }); 1")

# Dragging a tab's row in the sidebar (a real mouse drag) moves the tab where it's dropped (M-4).
if not debug_events:
    rows = J("[...document.querySelectorAll('#tabs .tab')].filter((r) => { const t = Umi.state.layout.tabs.find((x) => x.id === r.dataset.tab); return t && !t.pinned && !t.archived; }).map((r) => { const b = r.getBoundingClientRect(); return {id: r.dataset.tab, x: b.left + b.width / 2, top: b.top, bottom: b.bottom}; })")
    if len(rows) >= 2:
        o = D({"cmd": "state"})["contentOriginGlobal"]
        a, b = rows[0], rows[1]
        in_front()
        subprocess.run([click_bin, "drag", str(o["x"] + a["x"]), str(o["y"] + (a["top"] + a["bottom"]) / 2),
                        str(o["x"] + b["x"]), str(o["y"] + b["bottom"] - 4)], check=True)
        time.sleep(0.6)
        order = J("Umi.state.layout.tabs.map((t) => t.id)")
        check("dragging a tab's row below the next one moves it there", order.index(a["id"]) == order.index(b["id"]) + 1, (a["id"], b["id"], order))
        ev(f"Umi.app.update(() => Umi.arrange.placeTab(Umi.state.layout.tabs.find((t) => t.id === {json.dumps(a['id'])}), Umi.state.layout.tabs.find((t) => t.id === {json.dumps(b['id'])}), false)); 1")
    else:
        check("dragging a tab's row: two unpinned tabs to drag between", False, rows)

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
