#!/usr/bin/env python3
"""Checks file panes (track a: web/views/file.js, markdown.js, views/comments.js) against a running
UmiNext started with UMI_NEXT_DEBUG=1, through the debug socket: keys go in with NSApp.sendEvent,
so it types nothing on screen and runs with UMI_NEXT_OFFSCREEN=1 without the screen lock.
Start the app with UMI_NEXT_TEST_OPEN_LOG=FILE so web links are logged instead of opened.

  file_test.py STATE_DIR SCRATCH_DIR OPEN_LOG

SCRATCH_DIR is emptied and filled with the documents it opens.
"""
import json, os, shutil, socket, struct, subprocess, sys, time, zlib

state, scratch, open_log = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
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
        raise RuntimeError(r["error"] + "\n" + js)
    return r["result"]


def J(js):
    return json.loads(ev(f"JSON.stringify({js})"))


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        fails.append(name)


def wait(js, timeout=4):
    t = time.time()
    while time.time() - t < timeout:
        try:
            if ev(f"!!({js})") in (True, 1, "1", "true"):
                return True
        except RuntimeError:
            pass
        time.sleep(0.1)
    return False


def key(k, *mods):
    # With shift, the character as typed (as a real key event carries it).
    D({"cmd": "shortcut", "key": k, "mods": list(mods)})
    time.sleep(0.25)


def typ(text):
    D({"cmd": "keys", "text": text})
    time.sleep(0.25)


V = "Umi.views.file.get(Umi.model.activeTab().focused)"


def vs():
    return J(f"{V} && {V}.state()")


def open_file(path, **kw):
    args = json.dumps({"path": path, **kw})
    ev(f"Umi.app.run('openFile', {args}); 1")
    wait(f"{V} && {V}.path === {json.dumps(path)} && ({V}.cm || {V}.error)")
    time.sleep(0.4)


def close_all():
    ev("for (const [id, v] of Umi.views.file.views) { v.discarded = true; Umi.app.update(() => Umi.model.removePane(id)); } 1")
    time.sleep(0.3)


def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


shutil.rmtree(scratch, ignore_errors=True)
os.makedirs(scratch + "/sub")
open(scratch + "/dot.png", "wb").write(png(40, 20, (25, 170, 216)))
plan = scratch + "/plan.md"
open(plan, "w").write("""---
title: Plan
---
# Plan

We will ship the **new parser** on Friday. See [other](sub/other.md) and [below](#details) and [web](https://example.com/x).

- [ ] write tests
- [x] port parser

![dot](dot.png)

<img src="dot.png" alt="raw" onerror="document.title='pwned'"><script>document.title='pwned'</script>

```python
def hello():
    return "hi"
```

```sh
echo from-the-preview
```

```mermaid
graph LR
  A --> B
```

## Details

Find me twice: needle and needle.

## Details
""")
open(scratch + "/sub/other.md", "w").write("# Other\n")
code = scratch + "/code.swift"
open(code, "w").write("let x = 1\nfunc f() -> String { \"s\" }\n")
os.makedirs(scratch + "/adir")
open(scratch + "/bin.dat", "wb").write(b"\xff\xfe\x00\x81")
if os.path.exists(open_log):
    os.remove(open_log)
check("app ready", D({"cmd": "state"}).get("webReady") is True)
close_all()

# ---- Markdown preview (E-1, E-7, MD-1..MD-4) ----
open_file(plan)
st = vs()
check("Markdown opens rendered", st and st["mode"] == "rendered" and not st["dirty"], st)
wait(f"{V}.page && {V}.page.state().mermaid.diagrams === 1", 8)
ps = J(f"{V}.page.state()")
check("code blocks: highlighted, labelled, Copy, Run for shell", ps["highlighted"] == 2 and ps["labels"] == ["Python", "Shell", "Mermaid"]
      and ps["copy_buttons"] == 3 and ps["run_buttons"] == 1, ps)
check("Mermaid draws its diagram", ps["mermaid"]["diagrams"] == 1 and not ps["mermaid"]["errors"], ps["mermaid"])
check("repeated headings get distinct anchors", ps["headings"] == ["plan", "details", "details-1"], ps["headings"])
wait(f"{V}.page.state().images.every(i => i.loaded)")
ps = J(f"{V}.page.state()")
check("local images (Markdown and raw HTML) display", len(ps["images"]) == 2 and all(i["loaded"] and i["data"] for i in ps["images"]), ps["images"])
F = f"{V}.frame.contentDocument"
check("the document's scripts and handlers never run", ev("document.title") != "pwned" and ev(f"{F}.title") != "pwned"
      and J(f"{F}.querySelectorAll('script, [onerror]').length") == 0)
check("front matter shows as a table", J(f"{F}.querySelector('table.front-matter th').textContent") == "title")
check("task list checkboxes", J(f"[...{F}.querySelectorAll('li.task input')].map(i => i.checked)") == [False, True])

# Links: #anchor scrolls, web links go to the browser, relative ones open the file.
ev(f"{F}.querySelector('a[href=\"#details\"]').click(); 1")
check("#anchor scrolls the preview", wait(f"{V}.frame.contentWindow.scrollY > 0"))
ev(f"{F}.querySelector('a[href^=\"https\"]').click(); 1")
time.sleep(0.4)
check("web links open in the browser", os.path.exists(open_log) and "https://example.com/x" in open(open_log).read())
plan_pane = ev("Umi.model.activeTab().focused")
ev(f"{F}.querySelector('a[href=\"sub/other.md\"]').click(); 1")
check("relative links open the file in a pane to the right", wait(f"{V} && {V}.path === {json.dumps(scratch + '/sub/other.md')}"))
ev(f"Umi.app.update(() => Umi.model.focusPane({json.dumps(plan_pane)})); 1")
ev(f"Umi.app.run('openFile', {{path: {json.dumps(plan)}}}); 1")
check("opening an open file focuses its pane, no second pane",
      ev("Umi.model.activeTab().focused") == plan_pane and J("Umi.model.panesOf(Umi.model.activeTab().root).filter(p => p.path).length") == 2)

# Find (MD-4) by keys.
ev(f"{V}.focus(); 1")
key("f", "cmd")
check("⌘F opens the preview's find bar", J(f"{V}.page.state().find.open"))
ev(f"{V}.page.typeInFind('needle'); 1")
fs = J(f"{V}.page.state().find")
check("find counts matches", fs["count"] == 2 and fs["label"] == "1/2", fs)
key("g", "cmd")
check("⌘G goes to the next match", J(f"{V}.page.state().find.label") == "2/2")
key("G", "cmd", "shift")
check("⇧⌘G goes back", J(f"{V}.page.state().find.label") == "1/2")
ev(f"{V}.page.closeFind(); 1")

# Rendered / Raw (E-2).
ev(f"{V}.focus(); 1")
key("e", "cmd")
check("⌘E switches to Raw", vs()["mode"] == "raw")
key("M", "cmd", "shift")
check("⇧⌘M switches back to Rendered", vs()["mode"] == "rendered")

# Run in terminal (MD-2): the command goes to the tab's terminal input, not run.
term = J("Umi.model.panesOf(Umi.model.activeTab().root).find(p => p.view === 'terminal')?.id || null")
if term:
    ev(f"{F}.querySelector('.umi-run').click(); 1")
    time.sleep(0.8)
    scr = D({"cmd": "screen", "pane": ev("Umi.model.panesOf(Umi.model.activeTab().root).find(p => p.view === 'terminal').id")}).get("text", "")
    check("Run in terminal types the command into the tab's terminal", "echo from-the-preview" in scr and ev("Umi.model.activeTab().focused") == ev("Umi.model.panesOf(Umi.model.activeTab().root).find(p => p.view === 'terminal').id"), scr[-300:])
    ev(f"Umi.app.update(() => Umi.model.focusPane({json.dumps(plan_pane)})); 1")
else:
    check("Run in terminal (needs a terminal in the tab)", False, "no terminal pane")

# ---- Comments (E-11) ----
M = f"{V}.margin"
check("select text offers Comment", ev(f"{M}.selectText('new parser')") in (True, 1, "1", "true"))
ev(f"{M}.clickAdd(); {M}.type('Why Friday?'); {M}.submit(); 1")
time.sleep(0.8)
txt = open(plan).read()
check("a comment goes into the file at once", "**{==new parser==}{>>Why Friday?<<}{#c1}**" in txt and "umi-body: \"Why Friday?\"" in txt, txt[-300:])
ms = J(f"{M}.state()")
check("the margin shows the thread, selected", [c["id"] for c in ms["cards"]] == ["c1"] and ms["selected"] == "c1", ms)
# An agent replies by writing the file: the preview follows.
new = J(f"UmiComments.reply({json.dumps(txt)}, 'c1', 'Because the train leaves.', 'AI').text")
open(plan, "w").write(new)
check("an agent's reply shows in the margin", wait(f"{M}.state().cards.some(c => c.text.includes('Because the train leaves.'))"))
ev(f"{M}.select('c1'); 1")
time.sleep(0.2)
ev(f"{M}.click('.umi-card.umi-selected .umi-resolve'); 1")
time.sleep(0.8)
check("resolve writes status: resolved", "status: resolved" in open(plan).read())
check("a resolved comment's card hides", J(f"{M}.state().cards.length") == 0)
ev("window.__done = null; window.addEventListener('umi:commentsDone', e => window.__done = e.detail, {once: true}); 1")
ev(f"{M}.click('.umi-done'); 1")
time.sleep(0.3)
check("Done reports the review", J("window.__done") == {"path": plan, "open": 0}, J("window.__done"))

# ---- Source (E-21..E-23), save (E-3), disk changes (E-4) ----
open_file(code, line=2, col=6)
st = vs()
check("a line:col opens the source with the caret there", st["mode"] == "raw" and st["caret"] == len("let x = 1\n") + 5, st)
typ("XY")
check("typing edits the text and marks it unsaved", vs()["dirty"] and "func XYf()" in vs()["text"])
check("the pane's header shows the dot", J("document.querySelector('#panes .pane-head.dirty') !== null"))
key("s", "cmd")
time.sleep(0.4)
st = vs()
check("⌘S saves with Warp's toast", not st["dirty"] and "func XYf()" in open(code).read() and "File saved." in st["toast"], st)
key("/", "cmd")
check("⌘/ comments the line with the language's prefix", wait(f"{V}.text.includes('// func XYf()')"), vs()["text"])
key("z", "cmd")
key("g", "ctrl")
check("⌃G opens Go to line", J(f"!!{V}.root.querySelector('.cm-panel input')"))
# The debug socket's Escape has no keyCode, which CodeMirror's panels read: send theirs.
ev(f"{V}.root.querySelector('.cm-panel input').dispatchEvent(new KeyboardEvent('keydown', {{key: 'Escape', keyCode: 27, bubbles: true}})); 1")
check("Escape closes it", wait(f"!{V}.root.querySelector('.cm-panel input')"))
ev(f"{V}.focus(); 1")
open(code, "a").write("// outside\n")
check("an unmodified file reloads after a disk change", wait(f"{V}.text.endsWith('// outside\\n') && !{V}.state().dirty"), vs())
typ("Q")
open(code, "a").write("// again\n")
check("a modified file shows Warp's conflict bar", wait(f"{V}.state().conflict"), vs())
check("…with Warp's words", "This file has saved changes that are not reflected here." in vs()["bars"])
ev("[...document.querySelectorAll('.fv-bar button')].find(b => b.textContent === 'Overwrite').click(); 1")
time.sleep(0.5)
check("Overwrite saves the edits over it", not vs()["conflict"] and "Q" in open(code).read() and "// again" not in open(code).read(), open(code).read())
os.remove(code)
check("a deleted file says so", wait(f"{V}.state().missing"))
open(code, "w").write("recreated\n")
check("a file deleted and recreated is picked up again", wait(f"{V}.text === 'recreated\\n' && !{V}.state().missing"))

# Drafts survive a reload of the web layer; ⌘W asks first.
typ("D")
time.sleep(0.5)
D({"cmd": "reloadWeb"})
time.sleep(0.5)
wait("Umi.views && Umi.views.file && Umi.views.file.views.size > 0", 8)
time.sleep(1)
ev(f"Umi.app.run('openFile', {{path: {json.dumps(code)}}}); 1")
wait(f"{V} && {V}.cm")
check("unsaved edits survive a reload of the web layer", vs()["dirty"] and vs()["text"].startswith("D"), vs())
ev(f"{V}.focus(); 1")
key("w", "cmd")
check("⌘W on unsaved edits asks first", vs()["confirmClose"] and "Save changes to code.swift before closing?" in vs()["bars"], vs())
typ("\x1b")
check("Escape cancels closing", not vs()["confirmClose"] and vs()["path"] == code)
key("w", "cmd")
ev("[...document.querySelectorAll('.fv-bar button')].find(b => b.textContent === \"Don't Save\").click(); 1")
time.sleep(0.5)
check("Don't Save closes and drops the draft", not J(f"Umi.model.panesOf(Umi.model.activeTab().root).some(p => p.path === {json.dumps(code)})")
      and J("JSON.stringify(Umi.state.layout.meta.drafts || {})") == "{}" and open(code).read() == "recreated\n")

# ⇧⌘S: Save As; the pane then shows the new file, the old one is left as it was.
open_file(code)
ev(f"{V}.focus(); 1")
typ("S")
key("S", "cmd", "shift")
check("⇧⌘S asks for a name", J("!!document.querySelector('.fv-saveas input')"))
copy = scratch + "/copy.swift"
ev(f"{V}.submitSaveAs({json.dumps(copy)}); 1")
time.sleep(0.8)
check("Save As writes the new file and the pane shows it", os.path.exists(copy) and open(copy).read().startswith("S")
      and vs()["path"] == copy and not vs()["dirty"] and open(code).read() == "recreated\n", vs())
ev(f"{V}.startSaveAs(); {V}.submitSaveAs({json.dumps(plan)}); 1")
time.sleep(0.5)
check("Save As never replaces an existing file", "already exists" in J("document.querySelector('.fv-saveas .fv-err')?.textContent || ''"))
ev(f"{V}.saveAs = null; {V}.paint(); 1")

# A comment from the source while there are unsaved edits: the file gets the comment, the edits stay unsaved.
open_file(plan, mode="raw")
ev(f"{V}.cm.dispatch({{changes: {{from: 0, insert: 'Intro.\\n\\n'}}}}); 1")
pos = J(f"{V}.text.indexOf('Friday.')")
ev(f"{V}.cm.dispatch({{selection: {{anchor: {pos}, head: {pos + 6}}}}}); {V}.focus(); 1")
# ⌥⌘M itself: file_keys_test.py (the debug socket's ⌥⌘ keys never reach the page).
ev(f"{V}.startComment(); 1")
check("a comment on the source selection asks for its text", J(f"!!{V}.bars.querySelector('textarea')"))
ev(f"{V}.submitAsk('Which Friday?'); 1")
time.sleep(0.8)
disk = open(plan).read()
st = vs()
check("the comment is written to the file; unsaved edits stay unsaved",
      "{==Friday==}{>>Which Friday?<<}" in disk and not disk.startswith("Intro.") and st["dirty"] and st["text"].startswith("Intro.")
      and "{==Friday==}{>>Which Friday?<<}" in st["text"], (disk[:200], st["text"][:200]))

# ---- Refusals (E-6) ----
open_file(scratch + "/adir")
check("a folder is refused with a message", "is a folder" in (vs() or {}).get("error", "") if vs() else False, vs())
open_file(scratch + "/bin.dat")
check("a binary file is refused with a message", "UTF-8" in (vs() or {}).get("error", ""), vs())


# ---- JSON tree and CSV / TSV table (E-1) ----
open(scratch + "/data.json", "w").write('{"zeta": 1, "alpha": [true, null, "s"], "deep": {"a": {"b": {"c": {"d": 1}}}}, "empty": {}}\n')
open_file(scratch + "/data.json")
FD = f"{V}.frame.contentDocument"
wait(f"{V}.mode === 'rendered' && {FD}.querySelector('.umi-json')")
check("JSON opens as a tree (Rendered)", J(f"{V}.mode") == "rendered" and J(f"!!{FD}.querySelector('.umi-json details')"), vs())
check("its keys keep the file's order", J(f"[...{FD}.querySelector('.umi-json > details > ul').children].map((li) => li.querySelector('.k').textContent)") == ["zeta", "alpha", "deep", "empty"],
      J(f"[...{FD}.querySelectorAll('.umi-json .k')].map((k) => k.textContent)"))
check("objects and arrays fold: open to depth 3, deeper ones closed with a count",
      J(f"[...{FD}.querySelectorAll('.umi-json details')].map((d) => d.open)") == [True, True, True, True, False, False]
      and "1 key" in J(f"[...{FD}.querySelectorAll('.umi-json details')].pop().querySelector('summary').textContent"),
      J(f"[...{FD}.querySelectorAll('.umi-json details')].map((d) => d.open)"))
check("the header has Rendered / Raw", J(f"!!{V}.root.querySelector('.fv-mode')"))
key("e", "cmd")
check("⌘E shows its source", J(f"{V}.mode") == "raw")
ev(f"{V}.cm.dispatch({{changes: {{from: 0, to: 1, insert: '['}}}}); {V}.setMode('rendered'); 1")
wait(f"{FD}.querySelector('.umi-data-err')")
check("broken JSON says why instead of a tree", "Can't show a tree" in J(f"{FD}.querySelector('.umi-data-err')?.textContent || ''"))
close_all()
open(scratch + "/table.csv", "w").write('name,count,note\nb,10,"x, ""y"""\na,2.5,\nc,,z\n')
open_file(scratch + "/table.csv")
wait(f"{V}.mode === 'rendered' && {FD}.querySelector('table.umi-grid')")
rows = J(f"[...{FD}.querySelectorAll('table.umi-grid tr')].map((r) => [...r.children].map((c) => c.textContent))")
check("CSV opens as a table with row numbers and quoted cells", rows == [["", "name", "count", "note"], ["1", "b", "10", 'x, "y"'], ["2", "a", "2.5", ""], ["3", "c", "", "z"]], rows)
check("its header stays in view and numbers align right",
      J(f"getComputedStyle({FD}.querySelector('table.umi-grid th')).position") == "sticky"
      and J(f"[...{FD}.querySelectorAll('table.umi-grid tbody tr:first-child td')].map((c) => c.classList.contains('num'))") == [False, False, True, False])
check("the count above it", "3 rows × 3 columns" in J(f"{FD}.body.textContent"))
close_all()
open(scratch + "/t.tsv", "w").write("a\tb\n1\t2\n")
open_file(scratch + "/t.tsv")
wait(f"{FD}.querySelector('table.umi-grid')")
check("TSV opens as a table", J(f"[...{FD}.querySelectorAll('table.umi-grid td:not(.rn)')].map((c) => c.textContent)") == ["1", "2"])
close_all()

# ---- Git marks in the gutter (E-21) ----
repo = scratch + "/repo"
os.makedirs(repo)
g = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True)
g("init", "-q")
open(repo + "/code.txt", "w").write("one\ntwo\nthree\nfour\nfive\n")
g("add", "code.txt")
g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
open(repo + "/code.txt", "w").write("one\nTWO\nthree\nnew\nfour\n")
open_file(repo + "/code.txt")
wait(f"{V}.state().marks && Object.keys({V}.state().marks).length")
check("lines changed since the commit are marked: changed, added, removed",
      J(f"{V}.state().marks") == {"1": "changed", "3": "added", "5": "removed"}, J(f"{V}.state().marks"))
check("the gutter draws them at its left edge", sorted(J(f"{V}.state().gutterMarks") or []) == ["added", "changed", "removed"]
      and J(f"(() => {{ const m = {V}.cm.dom.querySelector('.cm-git-mark'), g = {V}.cm.dom.querySelector('.cm-gutters'); return Math.round(m.getBoundingClientRect().left - g.getBoundingClientRect().left); }})()") == 0,
      J(f"{V}.state().gutterMarks"))
ev(f"{V}.cm.dispatch({{changes: {{from: 0, to: 3, insert: 'ONE'}}}}); 1")
wait(f"{V}.state().marks['0'] === 'changed'")
check("an edit is marked as it is typed", J(f"{V}.state().marks['0']") == "changed")
ev(f"{V}.cm.dispatch({{changes: {{from: 0, to: {V}.cm.state.doc.length, insert: 'one\\ntwo\\nthree\\nfour\\nfive\\n'}}}}); 1")
wait(f"Object.keys({V}.state().marks).length === 0")
check("text back as committed: no marks", J(f"{V}.state().marks") == {})
close_all()
open(scratch + "/untracked.txt", "w").write("a\n")
open_file(scratch + "/untracked.txt")
time.sleep(0.6)
check("a file outside git has no marks", not J(f"{V}.state().gutterMarks"))
close_all()

# ---- The pane header's file-type icon; ⋯ and the preview's right-click menus (E-24) ----
def menu(expr, title=None):
    ev("""window.__menu = null; (() => { const orig = Umi.bridge.request;
      Umi.bridge.request = function (op, args, onEvent) {
        if (op !== 'menu') return orig.call(Umi.bridge, op, args, onEvent);
        Umi.bridge.request = orig;
        window.__menu = args.items.map((it) => (it.separator ? null : it.title));
        const i = args.items.findIndex((it) => it.title === %s);
        return Promise.resolve({index: i < 0 ? null : i});
      }; })(); %s; 1""" % (json.dumps(title), expr))
    wait("window.__menu", 3)
    return J("window.__menu")


open_file(plan)
pid = J("Umi.model.activeTab().focused")
icon = J(f"document.querySelector('#panes .pane-head[data-pane=\"{pid}\"] img.file-icon')?.getAttribute('src') || null")
check("a file pane's header shows the file's type icon (the explorer's)", icon == J("Umi.icons.file('plan.md')") == "icons/markdown.svg", icon)
ev(f"Umi.app.run('openFile', {{path: {json.dumps(scratch + '/data.json')}}}); 1")
time.sleep(0.5)
jid = J("Umi.model.activeTab().focused")
check("…a JSON file's its own", J(f"document.querySelector('#panes .pane-head[data-pane=\"{jid}\"] img.file-icon')?.getAttribute('src')") == "icons/json.svg")
ev(f"Umi.app.update(() => Umi.model.removePane({json.dumps(jid)})); 1")
ev(f"Umi.app.update(() => Umi.model.focusPane({json.dumps(pid)})); 1")
open_file(plan)
ev(f"{V}.setMode('rendered'); 1")
time.sleep(0.4)
m = menu(f"{V}.menu(new MouseEvent('click'))")
check("⋯ in the preview: Maximize pane, Refresh file, Open in editor, Copy file path",
      m == ["Maximize pane", None, "Refresh file", "Open in editor", None, "Copy file path"], m)
menu(f"{V}.menu(new MouseEvent('click'))", "Maximize pane")
time.sleep(0.3)
check("Maximize pane zooms the file pane", J("Umi.model.activeTab().zoomed") == pid)
m = menu(f"{V}.menu(new MouseEvent('click'))", "Minimize pane")
time.sleep(0.3)
check("…and says Minimize pane while zoomed, which unzooms", m[0] == "Minimize pane" and not J("!!Umi.model.activeTab().zoomed"), m)
ev(f"{V}.setMode('raw'); 1")
m = menu(f"{V}.menu(new MouseEvent('click'))")
check("⋯ in the source: Maximize pane, Copy file path, Reveal in Finder, View Markdown preview",
      m == ["Maximize pane", None, "Copy file path", "Reveal in Finder", "View Markdown preview"], m)
ev(f"{V}.setMode('rendered'); 1")
time.sleep(0.4)
m = menu(f"{V}.menu(new MouseEvent('contextmenu'), true)")
check("the preview's right-click: Copy file path, Split right / down, Maximize, Close",
      m == ["Copy file path", None, "Split pane right", "Split pane down", None, "Maximize pane", "Close pane"], m)
n = J("Umi.model.paneIds(Umi.model.activeTab().root).length")
menu(f"{V}.menu(new MouseEvent('contextmenu'), true)", "Split pane right")
time.sleep(0.4)
check("Split pane right splits the file pane into the picker", J("Umi.model.paneIds(Umi.model.activeTab().root).length") == n + 1
      and J("Umi.model.focusedPane().view") == "picker")
picker = J("Umi.model.activeTab().focused")
ev(f"Umi.app.update(() => Umi.model.removePane({json.dumps(picker)})); 1")
time.sleep(0.5)  # native reports the terminal it focused once the picker left
ev(f"Umi.app.update(() => Umi.model.focusPane({json.dumps(pid)})); 1")
wait(f"{V} && {V}.path === {json.dumps(plan)}")
menu(f"{V}.menu(new MouseEvent('contextmenu'), true)", "Close pane")
time.sleep(0.4)
check("Close pane closes it", not J(f"!!Umi.model.findPane({json.dumps(pid)})"))

close_all()
print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
