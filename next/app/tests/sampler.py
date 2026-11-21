# Samples a pane's screen through the debug socket every 10 ms for N s; prints the longest time
# the screen went without changing, and when.
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debugsock import Debug  # noqa: E402

state = os.path.expanduser("~/umi-next-ui-state")
D = Debug(state)
pane, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
t0 = time.time(); last = None; changes = []; maxcall = 0
while time.time() - t0 < secs:
    a = time.time(); txt = D({"cmd": "screen", "pane": pane}).get("text"); b = time.time()
    maxcall = max(maxcall, b - a)
    if txt != last: changes.append(b); last = txt
    time.sleep(0.01)
gaps = [(y - x, x) for x, y in zip(changes, changes[1:])]
g = max(gaps) if gaps else (0, 0)
json.dump({"changes": len(changes), "maxGapMs": round(g[0] * 1000), "maxGapAt": g[1], "maxCallMs": round(maxcall * 1000), "t0": t0}, open(out, "w"))
