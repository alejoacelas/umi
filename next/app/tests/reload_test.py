# Runs on mac-air-2: edit web/style.css and time until the running page shows the new colour.
import json, os, socket, subprocess, sys, time, re
state = os.path.expanduser("~/umi-next-ui-state")
css = os.path.expanduser("~/umi-next-ui/next/app/web/style.css")
def D(cmd):
    s = socket.socket(socket.AF_UNIX); s.connect(state + "/debug.sock")
    s.sendall(json.dumps(cmd).encode() + b"\n"); b = b""
    while True:
        d = s.recv(65536)
        if not d: break
        b += d
    return json.loads(b)
color = sys.argv[1]  # e.g. "rgba(40, 90, 160, 0.35)"
js = "getComputedStyle(document.getElementById('sidebar')).backgroundColor"
before = D({"cmd": "state"})
views = {p["id"]: p["view"] for p in before["panes"]}
src = open(css).read()
new = re.sub(r"--sidebar: [^;]+;", f"--sidebar: {color};", src, count=1)
t0 = time.time()
open(css, "w").write(new)
try:
    seen = None
    while time.time() - t0 < 5:
        r = D({"cmd": "eval", "js": js})["result"]
        if r and r.replace(" ", "") == color.replace(" ", ""):
            seen = time.time(); break
        time.sleep(0.01)
    time.sleep(0.3)
    after = D({"cmd": "state"})
finally:
    open(css, "w").write(src)
rl = after["reloads"][-1] if after["reloads"] else {}
print(json.dumps({
  "visible_after_ms": round((seen - t0) * 1000) if seen else None,
  "fsevent_after_write_ms": round((rl.get("changedAt", 0) - t0) * 1000),
  "hello_after_write_ms": round((rl.get("helloAt", 0) - t0) * 1000),
  "rects_after_write_ms": round((rl.get("rectsAt", 0) - t0) * 1000),
  "same_terminal_views": views == {p["id"]: p["view"] for p in after["panes"]},
  "mismatches": after["mismatches"], "webErrors": after["webErrors"],
}, indent=1))
