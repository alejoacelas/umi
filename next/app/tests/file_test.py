#!/usr/bin/env python3
"""Checks file panes (track a: web/views/file.js, markdown.js, views/comments.js) against a running
UmiNext started with UMI_NEXT_DEBUG=1, through the debug socket: keys go in with NSApp.sendEvent,
so it types nothing on screen and runs with UMI_NEXT_OFFSCREEN=1 without the screen lock.
Start the app with UMI_NEXT_TEST_OPEN_LOG=FILE so web links are logged instead of opened.

  file_test.py STATE_DIR SCRATCH_DIR OPEN_LOG

SCRATCH_DIR is emptied and filled with the documents it opens.
"""
import json, os, shutil, socket, struct, sys, time, zlib

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


def call(expr, timeout=10):
    k = "k%d" % int(time.time() * 1e6)
    ev(f"window.__r = window.__r || {{}}; Promise.resolve().then(() => {expr}).then("
       f"v => window.__r.{k} = JSON.stringify({{ok: v === undefined ? null : v}}), e => window.__r.{k} = JSON.stringify({{err: String(e && e.message || e)}})); 1")
    t = time.time()
    while time.time() - t < timeout:
        v = ev(f"window.__r.{k} || ''")
        if v:
            d = json.loads(v)
            return d["ok"] if "ok" in d else d
        time.sleep(0.05)
    return {"err": "timeout"}


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
term = J("Umi.model.panesOf(Umi.model.activeTab().root).find(p => p.view === 'terminal')?.id")
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
check("the strip chip shows the dot", J("document.querySelector('#strip .chip.dirty') !== null"))
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

close_all()
print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
