# Runs on mac-air-2: edit web/style.css and time until the running page shows the new colour.
import json, os, sys, time, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debugsock import Debug  # noqa: E402

state = os.path.expanduser("~/umi-next-ui-state")
D = Debug(state)
css = os.path.expanduser("~/umi-next-ui/next/app/web/style.css")
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
