#!/usr/bin/env python3
"""File panes by real key events (through the HID tap, `key` built from key.swift; the caller
needs Accessibility), for keys the debug socket can't send as a keyboard does: ⌥⌘ combinations
(none reach the page that way), Escape in CodeMirror's panels (it reads keyCode), plus typing,
⌘S, ⌘E, ⇧⌘M, ⌘W, and the Edit menu's keys (⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z) in the source and in a field. Run under `lockf -k ~/umi-screen.lock` against a UmiNext started with
UMI_NEXT_DEBUG=1 on screen. Before every key it checks this UmiNext is frontmost, else it stops.

  file_keys_test.py STATE_DIR KEY_BIN SCRATCH_DIR
"""
import json, os, shutil, socket, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from front import bring_to_front  # noqa: E402

state, key_bin, scratch = sys.argv[1], sys.argv[2], os.path.abspath(sys.argv[3])
fails = []
CODES = {"s": 1, "e": 14, "m": 46, "w": 13, "g": 5, "a": 0, "r": 15, "z": 6, "escape": 53, "x": 7, "v": 9, "c": 8,
         "end": 119}


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


def J(js):
    r = D({"cmd": "eval", "js": f"JSON.stringify({js})"})
    if r.get("error"):
        raise RuntimeError(r["error"])
    return json.loads(r["result"])


def key(k, *mods):
    if not D({"cmd": "state"}).get("active"):
        sys.exit("FAIL this UmiNext lost the front; stopped before sending keys elsewhere")
    subprocess.run([key_bin, str(CODES[k]), *mods], check=True)
    time.sleep(0.35)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        fails.append(name)


V = "Umi.views.file.get(Umi.model.activeTab().focused)"
shutil.rmtree(scratch, ignore_errors=True)
os.makedirs(scratch)
doc = scratch + "/keys.md"
open(doc, "w").write("# Keys\n\nComment on these words please.\n")
D({"cmd": "eval", "js": "for (const [id, v] of Umi.views.file.views) { v.discarded = true; Umi.app.update(() => Umi.model.removePane(id)); } 1"})
D({"cmd": "eval", "js": f"Umi.app.run('openFile', {{path: {json.dumps(doc)}, mode: 'raw'}}); 1"})
time.sleep(1)
if not bring_to_front(D):
    sys.exit("FAIL couldn't bring this UmiNext to the front")
D({"cmd": "eval", "js": f"{V}.focus(); 1"})
time.sleep(0.3)

key("r")
key("a")
check("typed letters reach the source", J(f"{V}.text").startswith("ra# Keys"), J(f"{V}.text")[:20])
key("s", "cmd")
check("⌘S saves", open(doc).read().startswith("ra# Keys") and "File saved." in J(f"{V}.state().toast"))
key("g", "ctrl")
check("⌃G opens Go to line", J(f"!!{V}.root.querySelector('.cm-panel input')"))
key("escape")
check("Escape closes it and gives the text the keys back", not J(f"!!{V}.root.querySelector('.cm-panel input')") and J(f"{V}.state().focused"))
pos = J(f"{V}.text.indexOf('these words')")
D({"cmd": "eval", "js": f"{V}.cm.dispatch({{selection: {{anchor: {pos}, head: {pos + 11}}}}}); 1"})
key("m", "cmd", "opt")
check("⌥⌘M in the source asks for a comment", J(f"!!{V}.bars.querySelector('textarea')"))
key("escape")
check("Escape drops it", not J(f"!!{V}.bars.querySelector('textarea')"))
key("e", "cmd")
check("⌘E shows Rendered", J(f"{V}.mode") == "rendered")
time.sleep(0.5)
key("m", "cmd", "shift")
check("⇧⌘M (from the preview) shows Raw", J(f"{V}.mode") == "raw")
key("e", "cmd")
time.sleep(0.5)
D({"cmd": "eval", "js": f"{V}.margin.selectText('these words'); 1"})
key("m", "cmd", "opt")
check("⌥⌘M in the preview opens the compose card", J(f"{V}.margin.state().composing"))
key("escape")
D({"cmd": "eval", "js": f"{V}.setMode('raw'); 1"})
key("x")
key("w", "cmd")
check("⌘W on unsaved edits asks first", J(f"{V}.state().confirmClose"))
key("escape")
check("Escape keeps the pane", not J(f"{V}.state().confirmClose") and J(f"{V}.path") == doc)
key("z", "cmd")
check("⌘Z undoes in the source", not J(f"{V}.state().dirty"), J(f"{V}.text")[:20])


def clipboard():
    D({"cmd": "eval", "js": "window.__clip = null; Umi.bridge.request('clipboard', {}).then((r) => { window.__clip = r.text; }); 1"})
    time.sleep(0.3)
    return J("window.__clip")


# The Edit menu: ⌘X cuts, ⌘V pastes, ⌘Z / ⇧⌘Z in the source (CodeMirror) and in a plain field.
D({"cmd": "eval", "js": f"{V}.focus(true); 1"})
pos = J(f"{V}.text.indexOf('these ')")
D({"cmd": "eval", "js": f"{V}.cm.dispatch({{selection: {{anchor: {pos}, head: {pos + 6}}}}}); 1"})
key("x", "cmd")
time.sleep(0.6)
check("⌘X cuts the selection in the source", "these " not in J(f"{V}.text") and clipboard() == "these ", (J(f"{V}.text"), clipboard()))
D({"cmd": "eval", "js": f"{V}.cm.dispatch({{selection: {{anchor: {V}.cm.state.doc.length}}}}); 1"})
key("v", "cmd")
time.sleep(0.6)
check("⌘V pastes it", J(f"{V}.text").endswith("these "), J(f"{V}.text")[-20:])
key("z", "cmd")
time.sleep(0.6)
key("z", "cmd")
check("⌘Z twice undoes the paste and the cut", not J(f"{V}.state().dirty"), J(f"{V}.text"))
key("z", "cmd", "shift")
check("⇧⌘Z redoes the cut", "these " not in J(f"{V}.text"))
key("z", "cmd")
check("⌘Z undoes it again", not J(f"{V}.state().dirty"))
key("s", "cmd", "shift")
time.sleep(0.3)
field = f"{V}.bars.querySelector('.fv-saveas input')"
check("⇧⌘S opens the Save As field with the keys", J(f"document.activeElement === {field}"))
key("a", "cmd")
key("c", "cmd")
check("⌘A ⌘C in a field copy its text", clipboard() == doc, clipboard())
key("x", "cmd")
check("⌘X cuts in a field", J(f"{field}.value") == "", J(f"{field}.value"))
key("z", "cmd")
check("⌘Z undoes in a field (the Edit menu's Undo)", J(f"{field}.value") == doc, J(f"{field}.value"))
key("z", "cmd", "shift")
check("⇧⌘Z redoes in a field", J(f"{field}.value") == "", J(f"{field}.value"))
key("v", "cmd")
check("⌘V pastes in a field", J(f"{field}.value") == doc, J(f"{field}.value"))
key("escape")
check("Escape closes Save As", not J(f"!!{field}"))
key("w", "cmd")
check("⌘W on a saved file closes it", not J(f"Umi.model.panesOf(Umi.model.activeTab().root).some(p => p.path === {json.dumps(doc)})"))

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
