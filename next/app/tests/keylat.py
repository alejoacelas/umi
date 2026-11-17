# Key-to-screen latency: sends one key through the app's event path (debug `keys`, NSApp.sendEvent)
# and polls the focused pane's screen until it shows; n samples at a shell prompt.
import json, os, socket, sys, time, statistics
state = sys.argv[1]; n = int(sys.argv[2])
def D(cmd):
    s = socket.socket(socket.AF_UNIX); s.connect(state + "/debug.sock")
    s.sendall(json.dumps(cmd).encode() + b"\n"); b = b""
    while True:
        d = s.recv(1 << 20)
        if not d: break
        b += d
    return json.loads(b)
def count(): return D({"cmd": "screen"})["text"].count("q")
lat = []
for i in range(n):
    before = count(); t = time.perf_counter()
    D({"cmd": "keys", "text": "q"})
    while count() == before:
        if time.perf_counter() - t > 1: break
    lat.append((time.perf_counter() - t) * 1000)
    time.sleep(0.05)
lat.sort()
print(f"n={n} median={statistics.median(lat):.1f}ms p90={lat[int(n*.9)]:.1f}ms max={lat[-1]:.1f}ms")
