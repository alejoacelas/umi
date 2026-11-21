#!/usr/bin/env python3
"""Checks track (b) — the project explorer, quick open (⌘O), global search and "Search tabs..." —
against a running UmiNext started with UMI_NEXT_DEBUG=1. Keys go through the debug socket as
NSEvents (the same path as typed keys after the HID tap), so it can run with UMI_NEXT_OFFSCREEN=1
and without the screen lock. The explorer's right-click menu is answered by a spy on the bridge's
`menu`, as if an item were chosen. It uses the clipboard (Copy Path) and moves one scratch file to
the Trash (Delete).

  files_test.py STATE_DIR SCRATCH_DIR [BIG_REPO]

SCRATCH_DIR is made into a small git repository to work on. BIG_REPO (optional) is a large
repository for streaming, cancel and the 20,000-line cap. Opening a file is checked against the
`Umi.actions.openFile` contract (a spy replaces it), so it doesn't depend on track (a).
"""
import atexit, json, os, subprocess, sys, time

state, scratch = sys.argv[1], os.path.abspath(sys.argv[2])
big = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else None
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debugsock import Checks, Debug, poll  # noqa: E402

D = Debug(state, show_js=True)
ev, J = D.ev, D.J
check = Checks()
fails = check.fails


def key(k, *mods):
    D({"cmd": "shortcut", "key": k, "mods": list(mods)})
    time.sleep(0.12)


def typ(text):
    D({"cmd": "keys", "text": text})
    time.sleep(0.15)


ESC, ENTER = "\u001b", "\r"


def until(js, timeout=8, every=0.1):
    return poll(lambda: J(js), timeout, every)


# ---- a small repository ----
subprocess.run(["rm", "-rf", scratch], check=True)
os.makedirs(scratch + "/src")
os.makedirs(scratch + "/docs/deep")
sh = lambda *a: subprocess.run(a, cwd=scratch, check=True, capture_output=True)
sh("git", "init", "-q")
w = lambda p, t: open(os.path.join(scratch, p), "w").write(t)
w(".gitignore", "ignored.txt\n")
w("README.md", "# Repo\nneedle one\n")
w("src/a.js", "const x = 1; // needle two\n    let y = 'needle needle';\n")
w("docs/deep/target.md", "deep\n")
w("ignored.txt", "needle ignored\n")
w(".hidden", "needle hidden\n")
w(".DS_Store", "x")
sh("git", "add", ".")
sh("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")

# A fresh page: nothing kept from an earlier run.
D({"cmd": "reloadWeb"})
time.sleep(1)
until("typeof Umi !== 'undefined' && !!Umi.state.layout && !!Umi.views.modes", 10)
# At the end, whatever happened: the tabs and shells this made are closed.
start = D.layout_ids()
atexit.register(lambda: D.close_new(start["tabs"], start["panes"]))
ev("window.__realOpenFile = Umi.actions.openFile; window.__opened = []; Umi.actions.openFile = (a) => { window.__opened.push(a); }; Umi.actions.openFile.spy = true; 1")
# As a first run: the layout keeps the sidebar's mode, dotfiles and recent files.
ev("Umi.app.update(() => { const L = Umi.state.layout; L.sidebarMode = 'tabs'; L.hideDotfiles = false; L.meta.recentFiles = []; }); 1")


def open_tab(folder):
    ev(f"Umi.app.update(() => {{ Umi.model.addTab(Umi.model.newPane({{cwd: {json.dumps(folder)}}})); Umi.state.ui.editingTab = null; }}); 1")
    return until(f"Umi.views.modes.root() === {json.dumps(folder)}", 10)


check("a tab in the repository: its root is the repository", open_tab(scratch), J("Umi.views.modes.root()"))
rel = lambda p: p[len(scratch) + 1:] if p.startswith(scratch + "/") else ("." if p == scratch else p)


def rows():
    return J("Umi.views.explorer.debug()")


def names():
    return [rel(r["path"]) if "path" in r else "<new>" for r in rows()["rows"]]


# ---- explorer ----
key("e", "cmd", "shift")
check("⇧⌘E shows Files", J("Umi.views.modes.mode()") == "files")
check("⇧⌘E gives the tree the keys", J("[Umi.state.ui.sidebarFocus, Umi.state.ui.keys, document.activeElement.classList.contains('ft-list')]") == ["files", "web", True])
until("Umi.views.explorer.debug().rows.length > 3")
n = names()
check("root row first, folders first, dotfiles first", n[:5] == [".", "docs", "src", ".gitignore", ".hidden"], n)
check(".git and .DS_Store never listed", ".git" not in n and ".DS_Store" not in n, n)
ign = [r for r in rows()["rows"] if r.get("path", "").endswith("ignored.txt")]
check("ignored files listed and marked", ign and ign[0]["ignored"], ign)
check("ignored row drawn italic", J("[...document.querySelectorAll('#explorer .ft-row.ignored .name')].map(e => getComputedStyle(e).fontStyle)") == ["italic"])

key("down"); key("down"); key("down")
check("↓ moves the selection", rel(rows()["selected"] or "") == "src", rows()["selected"])
key("right")
until("Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/a.js'))", 4)
check("→ opens the folder", "src/a.js" in names(), names())
key("down")
check("↓ into the folder", rel(rows()["selected"] or "") == "src/a.js")
key("left")
check("← on a file goes to its folder", rel(rows()["selected"] or "") == "src")
key("left")
check("← closes the folder", "src/a.js" not in names())
typ(ENTER)
until("Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/a.js'))", 4)
check("Enter opens/closes a folder", "src/a.js" in names())

key(".", "cmd", "shift")
check("⇧⌘> hides dotfiles", ".hidden" not in names() and ".gitignore" not in names(), names())
check("⇧⌘> keeps the keys in the tree", J("Umi.state.ui.sidebarFocus") == "files")
key(".", "cmd", "shift")
check("⇧⌘> shows them again", ".hidden" in names())

# Live updates: files made, removed and renamed on disk show without a refresh.
w("src/new.txt", "x")
check("a new file on disk appears", until("Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/new.txt'))", 5))
os.makedirs(scratch + "/src/made")
check("a new folder appears", until("Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/made') && r.dir)", 5))
os.rename(scratch + "/src/new.txt", scratch + "/src/renamed.txt")
check("a rename on disk shows", until("Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/renamed.txt')) && !Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/new.txt'))", 5))
os.remove(scratch + "/src/renamed.txt")
check("a removed file goes", until("!Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/renamed.txt'))", 5))
w("src/later.txt", "x")
until("Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/later.txt'))", 5)
w(".gitignore", "ignored.txt\nsrc/later.txt\n")
check(".gitignore change re-marks ignored", until("Umi.views.explorer.debug().rows.some(r => r.path && r.path.endsWith('/src/later.txt') && r.ignored)", 5))
w(".gitignore", "ignored.txt\n")
os.remove(scratch + "/src/later.txt")

# Opening a file: Enter on README.md runs openFile with its absolute path.
for _ in range(40):
    if rel(rows()["selected"] or "") == "README.md":
        break
    key("down")
typ(ENTER)
op = until("window.__opened.length && window.__opened[window.__opened.length - 1]", 4)
check("Enter opens a file through Umi.actions.openFile", op and op.get("path") == scratch + "/README.md", op)
check("an opened file is a recent file", J("Umi.state.layout.meta.recentFiles[0]") == scratch + "/README.md")

# New File and Rename edit the name in the row.
key("e", "cmd", "shift")
check("⇧⌘E again: back to Tabs and the pane", J("[Umi.views.modes.mode(), Umi.state.ui.sidebarFocus, Umi.state.ui.keys]") == ["tabs", None, "terminal"])
key("1", "ctrl")
check("⌃1 shows Files too", J("[Umi.views.modes.mode(), Umi.state.ui.sidebarFocus]") == ["files", "files"])
ev(f"Umi.views.explorer.startNew({json.dumps(scratch + '/docs')}); 1")
time.sleep(0.3)
check("New File: a name field in the folder", "<new>" in names() and J("document.activeElement.tagName") == "INPUT")
typ("fresh.md" + ENTER)
check("New File makes the file", until(f"!!Umi.views.explorer.debug().rows.find(r => r.path === {json.dumps(scratch + '/docs/fresh.md')})", 5) and os.path.exists(scratch + "/docs/fresh.md"))
check("New File opens it", until(f"window.__opened.some(a => a.path === {json.dumps(scratch + '/docs/fresh.md')})", 4))
ev(f"Umi.app.update(() => {{ Umi.state.ui.sidebarFocus = 'files'; }}); Umi.views.explorer.startRename({json.dumps(scratch + '/docs/fresh.md')}); 1")
time.sleep(0.3)
check("Rename selects the name without its extension", J("[document.activeElement.value, document.activeElement.selectionStart, document.activeElement.selectionEnd]") == ["fresh.md", 0, 5])
typ("renamed" + ENTER)
check("Rename renames on disk", until(f"!!Umi.views.explorer.debug().rows.find(r => r.path === {json.dumps(scratch + '/docs/renamed.md')})", 5) and os.path.exists(scratch + "/docs/renamed.md"))
ev(f"Umi.views.explorer.startRename({json.dumps(scratch + '/docs/renamed.md')}); 1")
time.sleep(0.2)
typ(ESC)
check("Esc cancels a rename", os.path.exists(scratch + "/docs/renamed.md") and J("document.activeElement.classList.contains('ft-list')"))
ev(f"Umi.views.explorer.trash({json.dumps(scratch + '/docs/renamed.md')}); 1")
check("Delete moves to the Trash", until(f"!Umi.views.explorer.debug().rows.find(r => r.path === {json.dumps(scratch + '/docs/renamed.md')})", 5) and not os.path.exists(scratch + "/docs/renamed.md"))
typ(ESC)
check("Esc gives the keys back to the pane", J("[Umi.state.ui.sidebarFocus, Umi.state.ui.keys]") == [None, "terminal"])

# ---- the right-click menu: its items, and what each does (the native menu answers as if chosen) ----
def menu(path, title=None):
    """Right-clicks the row of `path`; picks `title`. Returns the menu's titles (None: a separator)."""
    D.spy_menu(title, """[...document.querySelectorAll('#explorer .ft-row')].find((r) => r.title === %s)
        .dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 60, clientY: 60 }))""" % json.dumps(path))
    m = until("window.__menu", 3)
    return m and [it and it["title"] + ("" if it["enabled"] else " (off)") for it in m]


def screen():
    pane = J("Umi.model.activeTab().focused")
    return D({"cmd": "screen", "pane": pane}).get("text", "")


def clear_prompt():
    ev("Umi.bridge.request('sendText', {session: Umi.model.sessionOf(Umi.model.activeTab().focused), text: '\\u0015'}); 1")
    time.sleep(0.5)


key("1", "ctrl")
if J("Umi.views.modes.mode()") != "files":
    key("1", "ctrl")
ev(f"Umi.views.explorer.show({json.dumps(scratch + '/src/a.js')}); 1")
time.sleep(0.5)
m = menu(scratch + "/src")
check("folder menu: Umi's items in Umi's order", m == ["New File", None, "cd to Directory", "Open in New Tab", "Reveal in Finder", "Rename", "Delete",
                                                    None, "Insert Path in Terminal", None, "Copy Path", "Copy Relative Path"], m)
m = menu(scratch + "/src/a.js")
check("file menu: Umi's items", m == ["Open in New Pane", "Open in New Tab", "Open with Default App", "Reveal in Finder", "Rename", "Delete",
                                      None, "Insert Path in Terminal", None, "Copy Path", "Copy Relative Path"], m)
m = menu(scratch)
check("root: no Rename or Delete", m and "Rename" not in m and "Delete" not in m, m)
menu(scratch + "/src/a.js", "Copy Path")
time.sleep(0.3)
check("Copy Path", subprocess.run(["pbpaste"], capture_output=True, text=True).stdout == scratch + "/src/a.js")
menu(scratch + "/src/a.js", "Copy Relative Path")
time.sleep(0.3)
check("Copy Relative Path", subprocess.run(["pbpaste"], capture_output=True, text=True).stdout == "src/a.js")
menu(scratch + "/src/a.js", "Insert Path in Terminal")
time.sleep(0.8)
check("Insert Path in Terminal types the path at the prompt", (scratch + "/src/a.js ") in screen(), screen()[-300:])
clear_prompt()
menu(scratch + "/src", "cd to Directory")
time.sleep(0.8)
sc = screen()
check("cd to Directory types `cd FOLDER`, not run, and the terminal gets the keys",
      ("cd " + scratch + "/src") in sc and J("[Umi.state.ui.sidebarFocus, Umi.state.ui.keys]") == [None, "terminal"], sc[-300:])
clear_prompt()
tabs, home_tab = J("[Umi.state.layout.tabs.length, Umi.state.layout.activeTab]")
menu(scratch + "/docs", "Open in New Tab")
check("Open in New Tab (folder): a terminal tab there", until(f"Umi.state.layout.tabs.length === {tabs + 1} && Umi.model.focusedPane().cwd === {json.dumps(scratch + '/docs')}", 3))
ev("Umi.app.update(() => { Umi.state.ui.editingTab = null; Umi.actions.closeTab(); Umi.state.layout.activeTab = %s; }); 1" % json.dumps(home_tab))
time.sleep(0.5)

# ---- quick open ----
key("o", "cmd")
check("⌘O opens quick open", J("Umi.state.ui.panel && Umi.state.ui.panel.name") == "quickOpen")
check("quick open has the keys", J("[Umi.state.ui.keys, document.activeElement.closest('#panel') != null]") == ["web", True])
items = until("Umi.views.quickOpen.debug().count && Umi.views.quickOpen.debug().items", 5)
check("empty query: recent file first", items and items[0] == "README.md", items)
check("tracked + untracked-not-ignored listed, ignored not", "ignored.txt" not in J("Umi.views.quickOpen.debug().items") and J("Umi.views.quickOpen.debug().count") >= 4)
cover = J("Umi.views.panel.coverRect()")
check("panel sits at the top of the panes, 640 wide", cover and abs(cover["y"] - 117) < 2 and abs(cover["w"] - 640) < 2, cover)
typ("trgt")
items = J("Umi.views.quickOpen.debug().items")
check("fuzzy: 'trgt' finds docs/deep/target.md first", items and items[0] == "docs/deep/target.md", items)
typ(ENTER)
op = until("window.__opened[window.__opened.length - 1]", 3)
check("Enter opens it", op and op.get("path") == scratch + "/docs/deep/target.md", op)
check("panel closed after opening", J("Umi.state.ui.panel") is None)
key("o", "cmd")
until("Umi.views.quickOpen.debug().count", 5)
check("most recent first", J("Umi.views.quickOpen.debug().items.slice(0, 2)") == ["docs/deep/target.md", "README.md"])
typ("a.js:2:5" + ENTER)
op = until("window.__opened[window.__opened.length - 1]", 3)
check("path:line:col opens at that place", op and op.get("path") == scratch + "/src/a.js" and op.get("line") == 2 and op.get("col") == 5, op)
key("o", "cmd")
until("Umi.views.quickOpen.debug().count", 5)
typ("zz/made.txt")
items = J("Umi.views.quickOpen.debug().items")
check("no match: Create a file named…", items and items[0] == {"create": scratch + "/zz/made.txt"}, items)
typ(ENTER)
check("Create makes the file and its folders", until(f"window.__opened.some(a => a.path === {json.dumps(scratch + '/zz/made.txt')})", 4) and os.path.exists(scratch + "/zz/made.txt"))
key("o", "cmd")
typ(ESC)
check("Esc closes quick open", J("Umi.state.ui.panel") is None and J("Umi.state.ui.keys") == "terminal")

# Files changed against HEAD rank above the rest, after the recent ones (L-16, as Umi's).
os.makedirs(scratch + "/lib", exist_ok=True)
w("lib/qa.txt", "a\n")
w("lib/qb.txt", "b\n")
sh("git", "add", "lib")
sh("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "lib")
w("lib/qb.txt", "b changed\n")
key("o", "cmd")
items = until("Umi.views.quickOpen.debug().count && Umi.views.quickOpen.debug().items", 5)
check("empty query: recent files, then changed ones, then the rest",
      items and "lib/qb.txt" in items and "lib/qa.txt" in items and items.index("lib/qb.txt") < items.index("lib/qa.txt")
      and all(not x.startswith("lib/") for x in items[:items.index("lib/qb.txt")]), items)
typ("q.txt")
items = J("Umi.views.quickOpen.debug().items")
check("a changed file ranks above an equal match", items[:2] == ["lib/qb.txt", "lib/qa.txt"], items)
typ(ESC)
sh("git", "checkout", "-q", "lib/qb.txt")
key("o", "cmd")
until("Umi.views.quickOpen.debug().count", 5)
typ("q.txt")
items = J("Umi.views.quickOpen.debug().items")
check("…and back in path order once committed", items[:2] == ["lib/qa.txt", "lib/qb.txt"], items)
typ(ESC)

# ---- global search ----
key("f", "cmd", "shift")
check("⇧⌘F shows Search with the query focused", J("[Umi.views.modes.mode(), Umi.state.ui.sidebarFocus, document.activeElement.getAttribute('aria-label')]") == ["search", "search", "Search in files"])
typ("needle")
s = until("!Umi.views.search.debug().searching && Umi.views.search.debug().count && Umi.views.search.debug()", 5)
check("results grouped by file, ignored left out, dotfiles in", s and s["files"] == 3 and s["count"] == 4, s)
check("summary line", s and s["message"] == "4 results in 3 files", s and s["message"])
check("no capped note under the cap", J("getComputedStyle(document.querySelector('#search .sq-capped')).display") == "none")
check("one row per line (two matches on a line: one row)", s and sum(1 for r in s["rows"] if r.get("path") == "src/a.js") == 2)
check("leading spaces dropped", s and any(r.get("text") == "let y = 'needle needle';" for r in s["rows"]), s and s["rows"])
check("matches highlighted", J("document.querySelectorAll('#search mark').length") >= 4)
key("down")
v = J("[Umi.state.ui.sidebarFocus, document.activeElement.classList.contains('sr-list'), Umi.views.search.debug().selected, Umi.views.search.debug().rows[0]?.file ?? null]")
check("↓ into the results, first row selected", v[3] is not None and v[:3] == ["results", True, v[3]], v)
first = J("Umi.views.search.debug().rows[0].file")
key("left")
check("← folds a file", J("Umi.views.search.debug().rows.filter(r => r.path === %s).length" % json.dumps(first)) == 0)
key("right")
check("→ unfolds it", J("Umi.views.search.debug().rows.filter(r => r.path === %s).length" % json.dumps(first)) > 0)
while True:
    sel = J("Umi.views.search.debug().selected")
    if sel and sel.startswith("src/a.js\u0000"):
        break
    key("down")
    if J("Umi.views.search.debug().selected") == sel:
        break
key("down")
typ(ENTER)
op = until("window.__opened[window.__opened.length - 1]", 3)
check("Enter opens the file at the match's line and column", op and op.get("path") == scratch + "/src/a.js" and op.get("line") == 2 and op.get("col") == 14, op)
key("f", "cmd", "shift")
check("⇧⌘F again selects the query", J("[document.activeElement.selectionStart, document.activeElement.selectionEnd]") == [0, 6])
ev("Umi.views.search.set({query: 'needle (one|two)', regex: true}); 1")
s = until("!Umi.views.search.debug().searching && Umi.views.search.debug().searched !== null && Umi.views.search.debug()", 5)
check("regex toggle", s and s["count"] == 2, s)
ev("Umi.views.search.set({query: 'needle(?= two)', regex: true}); 1")
s = until("!Umi.views.search.debug().searching && Umi.views.search.debug()", 5)
check("Perl-style regex (lookahead)", s and s["count"] == 1, s)
ev("Umi.views.search.set({query: '(', regex: true}); 1")
s = until("!Umi.views.search.debug().searching && Umi.views.search.debug()", 5)
check("a bad regex shows rg's error", s and s["error"] and s["error"].startswith("rg:") and "parenthesis" in s["error"], s and s["error"])
ev("Umi.views.search.set({query: 'NEEDLE', regex: false, caseSensitive: true}); 1")
s = until("!Umi.views.search.debug().searching && Umi.views.search.debug()", 5)
check("case toggle", s and s["count"] == 0 and s["message"] == "No results found. Review your gitignore files.", s)
ev("Umi.views.search.set({caseSensitive: false}); 1")
typ(ESC)
check("Esc gives the keys back to the pane", J("[Umi.state.ui.sidebarFocus, Umi.state.ui.keys]") == [None, "terminal"])
key("3", "ctrl")
check("⌃3 hides Search when shown", J("Umi.views.modes.mode()") == "tabs")
key("3", "ctrl")
check("⌃3 shows it", J("[Umi.views.modes.mode(), Umi.state.ui.sidebarFocus]") == ["search", "search"])
typ(ESC)

# ---- Search tabs... ----
key("f", "cmd", "opt")
check("⌥⌘F focuses Search tabs", J("[Umi.views.modes.mode(), document.activeElement.getAttribute('aria-label')]") == ["tabs", "Search tabs"])
typ("zzzz")
check("a query hides the tabs it doesn't match", J("document.querySelectorAll('#tabs .tab').length") == 0)
typ(ESC)
check("Esc clears it and gives the keys back", J("[document.querySelectorAll('#tabs .tab').length > 0, Umi.state.ui.keys]") == [True, "terminal"])

# ---- with track (a)'s real file panes: opening shows the file, and the tree follows it ----
if J("!!window.__realOpenFile && !window.__realOpenFile.spy"):
    ev("Umi.actions.openFile = window.__realOpenFile; 1")
    key("e", "cmd", "shift")
    if J("Umi.views.modes.mode()") != "files":
        key("e", "cmd", "shift")
    ev(f"Umi.app.update(() => Umi.model.focusPane(Umi.model.activeTab().focused)); 1")
    key("o", "cmd")
    until("Umi.views.quickOpen.debug().count", 5)
    typ("target.md" + ENTER)
    tgt = scratch + "/docs/deep/target.md"
    check("quick open opens a real file pane", until(f"Umi.model.focusedPane().view === 'file' && Umi.model.focusedPane().path === {json.dumps(tgt)}", 5))
    check("the explorer opens its folders and selects it", until(f"Umi.views.explorer.debug().selected === {json.dumps(tgt)}", 5), rows()["selected"])
    ev("Umi.app.update(() => Umi.model.removePane(Umi.model.activeTab().focused)); 1")

# ---- a big repository: streaming, cancel, the cap, quick open's speed ----
if big:
    check("a tab in the big repository", open_tab(big), J("Umi.views.modes.root()"))
    key("o", "cmd")
    t = time.time()
    n = until("Umi.views.quickOpen.debug().count", 10, 0.02)
    print(f"     quick open indexed {n} files in {time.time() - t:.2f}s")
    t = time.time()
    typ("termwin")
    print(f"     typed and ranked in {time.time() - t:.2f}s: {J('Umi.views.quickOpen.debug().items.slice(0, 3)')}")
    typ(ESC)
    key("f", "cmd", "shift")
    ev("Umi.views.search.set({query: 'e', regex: false}); 1")
    seen_partial = False
    t = time.time()
    while time.time() - t < 20:
        s = J("Umi.views.search.debug()")
        if s["searching"] and s["count"] > 0:
            seen_partial = True
        if not s["searching"]:
            break
        time.sleep(0.03)
    check("results stream in before the search ends", seen_partial)
    check("capped at 20,000 lines with Warp's note", s["count"] == 20000 and s["capped"] and J("!document.querySelector('#search .sq-capped').hidden"), s["count"])
    ev("Umi.views.search.set({query: 'func ', regex: false}); 1")
    time.sleep(0.15)
    ev("Umi.views.search.set({query: 'zq' + 'xq' + Date.now(), regex: false}); 1")  # built here: in no file
    s = until("!Umi.views.search.debug().searching && Umi.views.search.debug()", 20)
    check("a new query cancels the running one (no old results mixed in)", s and s["count"] == 0, s and s["count"])
    typ(ESC)

print("\n%d failed" % len(fails) if fails else "\nall passed")
sys.exit(1 if fails else 0)
