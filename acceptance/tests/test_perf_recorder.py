"""The hang recorder (app UmiPerf): a main-thread block of 250 ms or more is written to
`<state dir>/logs/perf/<day>.jsonl` with the stack that held it, a freeze still going after 2 s is
written before it ends, and a slow control request is named. Driven by the internal `debug.hang`
method, which blocks the main thread for `ms` milliseconds."""

import glob
import json
import os
import threading

from harness import wait_until


def records(inst):
    out = []
    for path in sorted(glob.glob(os.path.join(inst.dir, "logs", "perf", "*.jsonl"))):
        with open(path) as f:
            out += [json.loads(line) for line in f if line.strip()]
    return out


def hangs(inst, seen):
    return [r for r in records(inst) if r.get("kind") == "hang" and r["id"] not in seen]


def frames(record):
    return "\n".join(frame for stack in record["stacks"] for frame in stack["frames"])


def test_hang_is_recorded_with_its_stack(inst):
    seen = {r["id"] for r in hangs(inst, set())}
    inst.rpc("debug.hang", ms=700)
    # Other hangs (such as one during launch) may be written meanwhile: find the one debug.hang made.
    found = wait_until(lambda: [r for r in hangs(inst, seen) if not r.get("ongoing") and "usleep" in frames(r)], 5,
                       message="a hang record")
    hang = found[-1]
    assert 600 <= hang["duration_ms"] <= 1500, hang["duration_ms"]
    assert hang["samples"] >= 5
    assert "UmiRPC" in frames(hang) and "usleep" in frames(hang), frames(hang)

    slow = [r for r in records(inst) if r.get("kind") == "slow" and r.get("detail") == "debug.hang"]
    assert slow and slow[-1]["name"] == "rpc" and slow[-1]["duration_ms"] >= 600


def test_freeze_is_recorded_while_it_lasts(inst):
    seen = {r["id"] for r in hangs(inst, set())}
    thread = threading.Thread(target=lambda: inst.rpc("debug.hang", ms=4000))
    thread.start()
    try:
        ongoing = wait_until(lambda: [r for r in hangs(inst, seen) if r.get("ongoing") and "usleep" in frames(r)], 3.5,
                             message="an ongoing hang record before the freeze ends")
        assert ongoing[0]["duration_ms"] >= 2000
        assert "usleep" in frames(ongoing[0])
    finally:
        thread.join()
    final = wait_until(lambda: [r for r in hangs(inst, seen) if not r.get("ongoing") and r["id"] == ongoing[0]["id"]], 5,
                       message="the final hang record")
    assert final[-1]["id"] == ongoing[0]["id"]
    assert final[-1]["duration_ms"] >= 3900


def test_short_blocks_are_not_hangs(inst):
    seen = {r["id"] for r in hangs(inst, set())}
    for _ in range(5):
        inst.rpc("debug.hang", ms=100)
    inst.rpc("debug.hang", ms=0)
    assert not [r for r in hangs(inst, seen) if "usleep" in frames(r)]
