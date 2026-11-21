# Key-to-screen latency: sends one key through the app's event path (debug `keys`, NSApp.sendEvent)
# and polls the focused pane's screen until it shows; n samples at a shell prompt.
import os, sys, time, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debugsock import Debug  # noqa: E402

state = sys.argv[1]; n = int(sys.argv[2])
D = Debug(state)
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
