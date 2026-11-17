# Samples a pane's screen through the debug socket every 10 ms for N s; prints the longest time
# the screen went without changing, and when.
import json, os, socket, sys, time
state = os.path.expanduser("~/umi-next-ui-state")
pane, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
def D(cmd):
    s = socket.socket(socket.AF_UNIX); s.connect(state + "/debug.sock")
    s.sendall(json.dumps(cmd).encode() + b"\n"); b = b""
    while True:
        d = s.recv(1 << 20)
        if not d: break
        b += d
    return json.loads(b)
t0 = time.time(); last = None; changes = []; maxcall = 0
while time.time() - t0 < secs:
    a = time.time(); txt = D({"cmd": "screen", "pane": pane}).get("text"); b = time.time()
    maxcall = max(maxcall, b - a)
    if txt != last: changes.append(b); last = txt
    time.sleep(0.01)
gaps = [(y - x, x) for x, y in zip(changes, changes[1:])]
g = max(gaps) if gaps else (0, 0)
json.dump({"changes": len(changes), "maxGapMs": round(g[0] * 1000), "maxGapAt": g[1], "maxCallMs": round(maxcall * 1000), "t0": t0}, open(out, "w"))
