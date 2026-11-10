"""Reproduce Umi stalling while files churn under the project explorer's root, and measure it.

What happened (Umi 0.12.0): with the explorer rooted at a repository, an agent ran a Zig build in
a git-ignored `.zig-cache` inside a worktree under `.worktrees/` (about 150 file events a second)
just after `git worktree add` wrote some 6,500 files. Umi sat at 70-100% CPU and stuttered; its
main thread was inside the explorer's FSEvents handler, reading and sorting folders.

This script does the same to an isolated instance (its own UMI_STATE_DIR, as the acceptance
harness makes them; it never touches the user's Umi):

1. makes a git repository of ~6,500 tracked files (30 folders of 200, plus 200 at the top) whose
   .gitignore ignores `.worktrees/` and `.zig-cache/`;
2. starts the app, opens a tab in the repository, shows the explorer there and opens ten folders
   with the keyboard (~2,200 rows), then leaves the explorer shown or hides it (`--explorer`);
3. runs `git worktree add .worktrees/wt` and, for `--seconds`, a Zig-cache-like churn inside the
   new worktree (`.worktrees/wt/.zig-cache`: new folders of a few files, temp files renamed into
   place, old folders deleted);
4. meanwhile measures the app: CPU time used (whole process, during the churn and in the
   10 seconds after it), a 5-second `sample` of the main thread (how busy it is, and how much of
   that is the explorer), and the round trip of `umi ls` (served on the main thread) every 0.2 s;
5. with the explorer shown, also checks that it stays current: a file made at the repository's top
   during the churn must show up in the explorer, and the time it takes is reported.

Usage (from acceptance/):

    uv run python perf/explorer_churn.py --app ../app/macos/build/ReleaseLocal/Umi.app --explorer hidden
    uv run python perf/explorer_churn.py --app /path/to/other/Umi.app --explorer shown --json out.json

Run it under the screen lock on the test Mac (`lockf -k ~/umi-screen.lock …`), as AGENTS.md says,
so no other run shares the machine.
"""

import argparse
import json
import os
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tests"))

from harness import Instance, Target, wait_until  # noqa: E402

DEFAULT_TARGET = os.path.join(os.path.dirname(HERE), "targets", "umi.json")


# ---- the repository ------------------------------------------------------------------------------

def make_repo(base, folders=30, per_folder=200, top=200):
    repo = os.path.realpath(os.path.join(base, "repo"))
    os.makedirs(repo)
    with open(os.path.join(repo, ".gitignore"), "w") as f:
        f.write(".worktrees/\n.zig-cache/\nzig-out/\n")
    for i in range(folders):
        d = os.path.join(repo, f"pkg{i:02d}")
        os.makedirs(d)
        for j in range(per_folder):
            with open(os.path.join(d, f"file{j:03d}.zig"), "w") as f:
                f.write(f"// {i} {j}\nconst x = {j};\n")
    for j in range(top):
        with open(os.path.join(repo, f"top{j:03d}.md"), "w") as f:
            f.write(f"# {j}\n")
    git = ["git", "-C", repo, "-c", "user.name=perf", "-c", "user.email=perf@example.invalid"]
    subprocess.run(git + ["init", "-q", "-b", "main"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "init"], check=True)
    return repo, folders * per_folder + top + 1


# ---- the churn ---------------------------------------------------------------------------------

def churn(cache, seconds, rate, stop):
    """A Zig-cache-like load: `rate` new folders a second, each with a few files written through a
    renamed temp file; folders older than ~2 s are deleted. Returns the number of operations."""
    os.makedirs(os.path.join(cache, "tmp"), exist_ok=True)
    os.makedirs(os.path.join(cache, "o"), exist_ok=True)
    os.makedirs(os.path.join(cache, "h"), exist_ok=True)
    made = []
    ops = 0
    end = time.time() + seconds
    interval = 1.0 / rate
    nxt = time.time()
    while time.time() < end and not stop.is_set():
        name = "%016x" % random.getrandbits(64)
        d = os.path.join(cache, "o", name)
        os.makedirs(d)
        for k in range(3):
            tmp = os.path.join(cache, "tmp", f"{name}-{k}")
            with open(tmp, "w") as f:
                f.write("x" * 256)
            os.rename(tmp, os.path.join(d, f"out{k}.o"))
            ops += 2
        with open(os.path.join(cache, "h", name[:2] + ".txt"), "a") as f:
            f.write(name + "\n")
        made.append((time.time(), d))
        while made and made[0][0] < time.time() - 2:
            shutil.rmtree(made.pop(0)[1], ignore_errors=True)
            ops += 1
        ops += 2
        nxt += interval
        delay = nxt - time.time()
        if delay > 0:
            time.sleep(delay)
    return ops


# ---- measuring the app -----------------------------------------------------------------------

def cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = [float(p) for p in out.replace("-", ":").split(":")]
    total = 0.0
    for p in parts:
        total = total * 60 + p
    return total


def ping(inst, stop, out, interval=0.2):
    """Time `umi ls` round trips until `stop` is set."""
    while not stop.is_set():
        t = time.time()
        proc = inst.cli("ls", check=False, timeout=120)
        out.append((t, time.time() - t, proc.returncode))
        stop.wait(interval)


def parse_sample(path):
    """Main-thread numbers from `sample` output: total samples, idle ones (waiting in the run loop's
    mach_msg), and samples inside the explorer's code."""
    with open(path, errors="replace") as f:
        text = f.read()
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l), None)
    if start is None:
        return None
    total = int(re.search(r"(\d+)\s+Thread_", lines[start]).group(1))
    indent = len(lines[start]) - len(lines[start].lstrip())
    section = []
    for line in lines[start + 1:]:
        if not line.strip():
            break
        stripped = line.lstrip(" +!:|")
        if re.match(r"\d+\s+Thread_", stripped) and (len(line) - len(line.lstrip())) <= indent:
            break
        section.append(line)

    def count(line):
        m = re.search(r"[+!:| ]\s*(\d+)\s", line)
        return int(m.group(1)) if m else 0

    def depth(line):
        m = re.match(r"^([\s+!:|]*)\d", line)
        return len(m.group(1)) if m else 0

    # Idle: leaf mach_msg2_trap frames under __CFRunLoopServiceMachPort.
    idle = sum(count(l) for l in section if "mach_msg2_trap" in l)

    # Explorer: the outermost frames of UmiFileTreeModel / UmiFileNode / UmiFSWatcher (not nested).
    explorer = 0
    top_depth = None
    for line in section:
        d = depth(line)
        if top_depth is not None and d <= top_depth:
            top_depth = None
        if top_depth is None and re.search(r"UmiFileTreeModel|UmiFileNode|UmiFSWatcher", line):
            explorer += count(line)
            top_depth = d
    return {"main_samples": total, "main_idle": idle, "main_busy_pct": round(100 * (total - idle) / max(total, 1), 1),
            "main_explorer_pct": round(100 * explorer / max(total, 1), 1)}


# ---- the run -----------------------------------------------------------------------------------

def press(inst, window, keys, focus="none"):
    inst.rpc("debug.key", window=window, keys=keys, focus=focus)


def files(inst, window, update=False):
    return inst.rpc("debug.ui.files", window=window, update=update)


def run(app, explorer, seconds, rate, keep):
    base = tempfile.mkdtemp(prefix="umi-perf-")
    target = Target(DEFAULT_TARGET)
    target = Target.from_installed(target, os.path.realpath(app))
    result = {"app": os.path.realpath(app), "explorer": explorer, "seconds": seconds, "rate": rate}
    print(f"making the repository in {base} …", flush=True)
    repo, tracked = make_repo(base)
    result["tracked_files"] = tracked
    inst = Instance(target, prefix="umi-perf-state-")
    try:
        inst.start_app()
        pid = inst.app_pid
        created = inst.json("window", "new", "--name", "perf")
        window = created["window"]
        pane = inst.cli("tab", "new", "--window", window, "--cwd", repo).stdout.strip()
        wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="the prompt")
        # Show the explorer by key (it takes keyboard focus), then open ten folders: the tenth
        # first, then each one above it.
        inst.cli("sidebar", "tabs")
        press(inst, window, "ctrl+1", focus="terminal")
        wait_until(lambda: os.path.realpath(files(inst, window, update=True)["root"] or "/x") == repo, 15,
                   message="the explorer shows the repository")
        wait_until(lambda: files(inst, window)["focused"], 5, message="the explorer has keyboard focus")
        for _ in range(1 + 10):
            press(inst, window, "down")
        press(inst, window, "right")
        for _ in range(9):
            press(inst, window, "up")
            press(inst, window, "right")
        state = files(inst, window)
        result["rows_before"] = len(state["rows"])
        result["expanded_folders"] = sum(1 for r in state["rows"] if r["dir"] and r["expanded"])
        if explorer == "hidden":
            inst.cli("sidebar", "tabs")
        time.sleep(2)

        # Idle CPU, before any churn.
        c0, t0 = cpu_seconds(pid), time.time()
        time.sleep(5)
        result["cpu_idle_pct"] = round(100 * (cpu_seconds(pid) - c0) / (time.time() - t0), 1)

        stop = threading.Event()
        pings = []
        pinger = threading.Thread(target=ping, args=(inst, stop, pings), daemon=True)
        c_start, t_start = cpu_seconds(pid), time.time()
        pinger.start()
        print("git worktree add …", flush=True)
        wt = os.path.join(repo, ".worktrees", "wt")
        subprocess.run(["git", "-C", repo, "worktree", "add", "-q", "-b", "wt", wt], check=True)
        result["worktree_add_s"] = round(time.time() - t_start, 2)
        churn_out = {}
        churner = threading.Thread(target=lambda: churn_out.update(
            ops=churn(os.path.join(wt, ".zig-cache"), seconds, rate, threading.Event())), daemon=True)
        churner.start()

        # A 5-second sample of the app a few seconds in.
        time.sleep(3)
        sample_path = os.path.join(base, "sample.txt")
        subprocess.run(["sample", str(pid), "5", "-mayDie", "-file", sample_path],
                       capture_output=True, timeout=120)
        result.update(parse_sample(sample_path) or {})
        result["sample_file"] = sample_path

        # With the explorer shown it must stay current: a new file at the top shows up.
        if explorer == "shown":
            fresh = os.path.join(repo, "fresh-during-churn.md")
            t = time.time()
            with open(fresh, "w") as f:
                f.write("new\n")
            try:
                wait_until(lambda: any(os.path.realpath(r["path"]) == fresh for r in files(inst, window)["rows"]),
                           60, interval=0.05, message="the new file in the explorer")
                result["new_file_shown_after_s"] = round(time.time() - t, 2)
            except AssertionError:
                result["new_file_shown_after_s"] = None

        churner.join()
        c_end, t_end = cpu_seconds(pid), time.time()
        result["churn_ops"] = churn_out.get("ops")
        result["churn_window_s"] = round(t_end - t_start, 1)
        result["cpu_during_churn_pct"] = round(100 * (c_end - c_start) / (t_end - t_start), 1)
        time.sleep(10)
        result["cpu_10s_after_pct"] = round(100 * (cpu_seconds(pid) - c_end) / (time.time() - t_end), 1)
        stop.set()
        pinger.join()

        during = [d for t, d, rc in pings if t_start <= t <= t_end]
        result["ls_round_trips"] = len(during)
        if during:
            during.sort()
            result["ls_median_ms"] = round(1000 * statistics.median(during), 1)
            result["ls_p95_ms"] = round(1000 * during[int(0.95 * (len(during) - 1))], 1)
            result["ls_max_ms"] = round(1000 * during[-1], 1)
        result["ls_failures"] = sum(1 for _, _, rc in pings if rc != 0)
        state = files(inst, window)
        result["rows_after"] = len(state["rows"])
    finally:
        inst.cleanup()
        if not keep:
            shutil.rmtree(base, ignore_errors=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the Umi.app to measure")
    parser.add_argument("--explorer", choices=["shown", "hidden"], required=True)
    parser.add_argument("--seconds", type=float, default=30, help="how long the churn runs")
    parser.add_argument("--rate", type=float, default=150, help="new cache folders a second")
    parser.add_argument("--json", help="also write the result here")
    parser.add_argument("--keep", action="store_true", help="keep the repository and the sample")
    args = parser.parse_args()
    result = run(args.app, args.explorer, args.seconds, args.rate, args.keep)
    print(json.dumps(result, indent=2))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(result, f, indent=2)


if __name__ == "__main__":
    main()
