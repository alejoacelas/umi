"""Performance stress test for Umi: push an isolated instance hard and measure hangs, hitches,
CPU, memory and how fast the control server answers.

Run from `acceptance/` (see perf/README.md):

    uv run python perf/umi_perf.py [--app PATH/Umi.app] [--scenarios a,b] [--soak HOURS]

Everything goes through the `umi` CLI and the fake agents, against an instance with its own
UMI_STATE_DIR (tests/harness.py), so the user's Umi is never touched. Results go to
`logs/perf/<time>/` at the repository root (ignored by git): summary.md, summary.json and the raw data.
"""

import argparse
import concurrent.futures
import ctypes
import datetime
import json
import os
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ACCEPTANCE = os.path.dirname(HERE)
REPO = os.path.dirname(ACCEPTANCE)
sys.path.insert(0, os.path.join(ACCEPTANCE, "tests"))

import harness  # noqa: E402

SCENARIOS = ["panes", "agents", "queries", "flood", "paste", "markdown", "switch", "idle", "close"]
# Scenarios recorded with the Time Profiler (stacks); the others get Hangs, Hitches and signposts only,
# so the profiler's own sampling doesn't count against idle CPU.
LIGHT_TRACE = {"idle"}


def now():
    return time.time()


def iso(t):
    return datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="milliseconds")


# ---------------------------------------------------------------------------------------------
# Process metrics without touching the process (proc_pid_rusage, proc_pidinfo)

_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = _Timebase()
_libc.mach_timebase_info(ctypes.byref(_tb))
_TICK_NS = _tb.numer / _tb.denom


def rusage(pid):
    """{cpu_s, footprint_mb, resident_mb, wakeups, threads} for a process, or None when it's gone.
    cpu_s and wakeups (idle + interrupt wakeups) are cumulative."""
    buf = (ctypes.c_uint64 * 64)()
    if _libc.proc_pid_rusage(int(pid), 4, ctypes.byref(buf)) != 0:   # RUSAGE_INFO_V4
        return None
    v = list(buf)[2:]   # after the 16-byte uuid
    out = {"cpu_s": (v[0] + v[1]) * _TICK_NS / 1e9, "wakeups": v[2] + v[3],
           "resident_mb": v[6] / 1048576, "footprint_mb": v[7] / 1048576}
    info = (ctypes.c_uint8 * 96)()
    if _libc.proc_pidinfo(int(pid), 4, ctypes.c_uint64(0), ctypes.byref(info), 96) == 96:   # PROC_PIDTASKINFO
        out["threads"] = int.from_bytes(bytes(info[84:88]), "little")
    return out


def responsible_pid(pid):
    try:
        return _libc.responsibility_get_pid_responsible_for_pid(int(pid))
    except AttributeError:
        return None


def webkit_children(app_pid):
    """WebKit helper processes (the editor's web views) that macOS counts as the app's."""
    out = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and "com.apple.WebKit" in parts[1] and responsible_pid(int(parts[0])) == app_pid:
            pids.append(int(parts[0]))
    return pids


def screen_locked():
    try:
        import Quartz
        d = Quartz.CGSessionCopyCurrentDictionary() or {}
        return bool(d.get("CGSSessionScreenIsLocked", False))
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------------------------------------
# xctrace: one recording per scenario, attached to the app


class Trace:
    FULL = ["--template", "Time Profiler", "--instrument", "Hangs", "--instrument", "Hitches",
            "--instrument", "os_signpost"]
    LIGHT = ["--instrument", "Hangs", "--instrument", "Hitches", "--instrument", "os_signpost"]

    def __init__(self, path, pid, light, log):
        self.path, self.pid, self.light, self.log = path, pid, light, log
        self.proc = None
        self.lines = []
        self.started = threading.Event()
        self.started_at = None

    def start(self):
        args = ["xctrace", "record", *(self.LIGHT if self.light else self.FULL), "--attach", str(self.pid),
                "--output", self.path, "--no-prompt"]
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     start_new_session=True)

        def read():
            for line in self.proc.stdout:
                self.lines.append(line.rstrip())
                if "Ctrl-C to stop" in line:
                    self.started_at = now()
                    self.started.set()
            self.started.set()
        threading.Thread(target=read, daemon=True).start()
        if not self.started.wait(90) or self.started_at is None:
            self.log(f"xctrace didn't start: {' | '.join(self.lines[-5:])}")
            self.stop()
            return False
        time.sleep(1)   # instruments settle after the banner
        return True

    def stop(self):
        if self.proc is None or self.proc.poll() is not None:
            return
        self.proc.send_signal(signal.SIGINT)
        try:
            self.proc.wait(600)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.log("xctrace didn't finish saving in 10 minutes; killed")


def xml_rows(path):
    """Rows of an `xctrace export --xpath` table as lists of resolved values, with the column
    mnemonics. Values: (text, fmt) for plain cells, fmt for threads and processes, [(frame, binary)]
    for backtraces (innermost first)."""
    cache = {}
    columns = []

    def val(el):
        ref = el.get("ref")
        if ref is not None:
            return cache.get(ref)
        kids = [val(c) for c in el]   # registers ids nested anywhere below
        tag = el.tag
        if tag == "backtrace":
            v = [k for c, k in zip(el, kids) if c.tag == "frame"]
        elif tag == "tagged-backtrace":
            v = next((k for c, k in zip(el, kids) if c.tag == "backtrace"), [])
        elif tag == "frame":
            binary = next((k for c, k in zip(el, kids) if c.tag == "binary"), "")
            v = (el.get("name") or el.get("addr") or "?", binary or "")
        elif tag == "binary":
            v = el.get("name") or ""
        elif tag in ("thread", "process"):
            v = el.get("fmt") or ""
        else:
            v = (el.text, el.get("fmt"))
        if el.get("id") is not None:
            cache[el.get("id")] = v
        return v

    for _, el in ET.iterparse(path, events=("end",)):
        if el.tag == "mnemonic":
            columns.append(el.text)
        elif el.tag == "row":
            yield columns, [val(c) for c in el]
            el.clear()


def num(cell):
    if isinstance(cell, tuple) and cell[0] not in (None, ""):
        try:
            return float(cell[0])
        except ValueError:
            return None
    return None


def text(cell):
    if isinstance(cell, tuple):
        return cell[1] or cell[0] or ""
    return cell if isinstance(cell, str) else ""


def export_table(trace, schema, out):
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    with open(out, "w") as f:
        proc = subprocess.run(["xctrace", "export", "--input", trace, "--xpath", xpath], stdout=f,
                              stderr=subprocess.PIPE, text=True, timeout=1800)
    return proc.returncode == 0 and os.path.getsize(out) > 0


def summarize_trace(trace, app_pid, out_dir, name, binary):
    """Export the trace's tables and boil them down: hangs, hitches, signpost intervals, and the
    main thread's heaviest functions overall and inside each hang."""
    res = {"trace": trace}
    base = os.path.join(out_dir, "traces", name)
    pid_tag = f"pid: {app_pid}"

    hangs = []
    if export_table(trace, "potential-hangs", base + ".hangs.xml"):
        for cols, row in xml_rows(base + ".hangs.xml"):
            r = dict(zip(cols, row))
            if str(app_pid) not in text(r.get("process", "")):
                continue
            hangs.append({"start_ns": num(r.get("start")), "ms": round((num(r.get("duration")) or 0) / 1e6, 1),
                          "type": text(r.get("hang-type")), "thread": text(r.get("thread"))})
    res["hangs"] = hangs

    hitches = []
    if export_table(trace, "hitches", base + ".hitches.xml"):
        for cols, row in xml_rows(base + ".hitches.xml"):
            r = dict(zip(cols, row))
            if str(app_pid) not in text(r.get("process", "")):
                continue
            hitches.append({"start_ns": num(r.get("start")), "ms": round((num(r.get("duration")) or 0) / 1e6, 1),
                            "issue": text(r.get("narrative-description"))})
    res["hitches"] = hitches

    signposts = {}
    if export_table(trace, "os-signpost-interval", base + ".signposts.xml"):
        for cols, row in xml_rows(base + ".signposts.xml"):
            r = dict(zip(cols, row))
            if text(r.get("subsystem")) != "dev.umi.app":
                continue
            key = f"{text(r.get('category'))}/{text(r.get('name'))}"
            ms = (num(r.get("duration")) or 0) / 1e6
            s = signposts.setdefault(key, {"count": 0, "total_ms": 0.0, "max_ms": 0.0})
            s["count"] += 1
            s["total_ms"] = round(s["total_ms"] + ms, 1)
            s["max_ms"] = round(max(s["max_ms"], ms), 1)
    res["signposts"] = signposts

    tp = base + ".time-profile.xml"
    if export_table(trace, "time-profile", tp) and os.path.getsize(tp) > 300:
        res["profile"] = profile_summary(tp, pid_tag, binary, [(h["start_ns"], h["ms"]) for h in hangs])
        for i, h in enumerate(hangs):
            h["top_frames"] = res["profile"]["in_hangs"][i] if i < len(res["profile"]["in_hangs"]) else []
        del res["profile"]["in_hangs"]
    for path in (base + ".hangs.xml", base + ".hitches.xml", base + ".signposts.xml"):
        if os.path.exists(path) and os.path.getsize(path) < 2000:   # empty tables: keep the folder readable
            os.remove(path)
    return res


def profile_summary(path, pid_tag, binary, hang_windows, top=15):
    """Main-thread samples of the app: total, heaviest leaf functions, heaviest of Umi's own
    functions (inclusive), and per hang the heaviest of Umi's own functions inside it."""
    leaf, own, total_ms = {}, {}, 0.0
    per_hang = [dict() for _ in hang_windows]
    for cols, row in xml_rows(path):
        r = dict(zip(cols, row))
        thread = text(r.get("thread", ""))
        if pid_tag not in thread or "Main Thread" not in thread:
            continue
        w = (num(r.get("weight")) or 1e6) / 1e6
        total_ms += w
        stack = r.get("stack")
        if not isinstance(stack, list):   # <sentinel/>: no backtrace for this sample
            stack = []
        if stack and stack[0]:
            leaf[stack[0][0]] = leaf.get(stack[0][0], 0) + w
        mine = []
        for fname, b in (f for f in stack if f):
            if b == binary and fname not in mine and fname not in ("main", "<deduplicated_symbol>"):
                mine.append(fname)
        for fname in mine:
            own[fname] = own.get(fname, 0) + w
        t = num(r.get("time"))
        if t is not None:
            for i, (start, ms) in enumerate(hang_windows):
                if start is not None and start <= t <= start + ms * 1e6:
                    for fname in mine[:40]:
                        per_hang[i][fname] = per_hang[i].get(fname, 0) + w

    def top_of(d, n=top):
        return [{"ms": round(v, 1), "function": k} for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:n]]
    return {"main_thread_ms": round(total_ms, 1), "top_leaf": top_of(leaf), "top_umi": top_of(own),
            "in_hangs": [top_of(d, 8) for d in per_hang]}


# ---------------------------------------------------------------------------------------------
# The run


class Perf:
    def __init__(self, args):
        self.args = args
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.out = os.path.abspath(args.out or os.path.join(REPO, "logs", "perf", stamp))
        os.makedirs(os.path.join(self.out, "traces"), exist_ok=True)
        target_file = os.path.join(ACCEPTANCE, "targets", "umi.json")
        target = harness.Target(target_file)
        if args.app:
            target = harness.Target.from_installed(target, os.path.abspath(args.app))
        self.target = target
        self.inst = harness.Instance(target, prefix="perf-")
        self.lock = threading.Lock()
        self.calls = open(os.path.join(self.out, "cli.jsonl"), "a")
        self.samples_f = open(os.path.join(self.out, "samples.jsonl"), "a")
        self.logf = open(os.path.join(self.out, "run.log"), "a")
        self.samples = []
        self.call_rows = []
        self.scenario = "setup"
        self.probe_interval = 0.5
        self.stop_flag = threading.Event()
        self.results = []
        self.recorder_offsets = {}
        self.anchor = None
        self.panes, self.tabs, self.agent_panes = [], [], []
        self.files = os.path.join(self.inst.dir, "perf-files")
        os.makedirs(self.files, exist_ok=True)

    # -- logging and timed CLI calls

    def log(self, msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} [{self.scenario}] {msg}"
        print(line, flush=True)
        self.logf.write(line + "\n")
        self.logf.flush()

    def record_call(self, kind, cmd, start, ms, rc):
        row = {"t": round(start, 3), "scenario": self.scenario, "kind": kind, "cmd": cmd, "ms": round(ms, 1), "rc": rc}
        with self.lock:
            self.call_rows.append(row)
            self.calls.write(json.dumps(row) + "\n")

    def cli(self, *args, stdin=None, env=None, timeout=120, kind="call", check=True):
        start = now()
        try:
            proc = self.inst.cli(*args, check=False, stdin=stdin, env=env, timeout=timeout)
            rc = proc.returncode
        except subprocess.TimeoutExpired:
            self.record_call(kind, " ".join(a for a in args if len(a) < 80)[:160], start, (now() - start) * 1000, 124)
            raise
        self.record_call(kind, " ".join(a for a in args if len(a) < 80)[:160], start, (now() - start) * 1000, rc)
        if check and rc != 0:
            raise harness.CLIError(f"umi {' '.join(args)[:200]} exited {rc}: {proc.stderr.strip()[:400]}")
        return proc

    def json(self, *args, **kw):
        return json.loads(self.cli("--json", *args, **kw).stdout)

    # -- background sampling

    def sampler(self):
        pid = self.inst.app_pid
        webkit, next_webkit = [], 0
        while not self.stop_flag.is_set():
            t = now()
            r = rusage(pid)
            if r is None:
                self.log("the app is gone")
                return
            if t >= next_webkit:
                webkit = webkit_children(pid)
                next_webkit = t + 5
            wk = [x for x in (rusage(p) for p in webkit) if x]
            row = {"t": round(t, 3), "scenario": self.scenario, **{k: round(v, 3) for k, v in r.items()},
                   "webkit_mb": round(sum(x["footprint_mb"] for x in wk), 1),
                   "webkit_cpu_s": round(sum(x["cpu_s"] for x in wk), 3), "load1": round(os.getloadavg()[0], 2)}
            with self.lock:
                self.samples.append(row)
                self.samples_f.write(json.dumps(row) + "\n")
                self.samples_f.flush()
            self.stop_flag.wait(1.0)

    def prober(self):
        """A cheap request every few hundred ms: a slow answer means the main thread was busy."""
        while not self.stop_flag.is_set():
            if self.anchor:
                try:
                    self.cli("pane", "get", self.anchor, "focused", kind="probe", timeout=60, check=False)
                except subprocess.TimeoutExpired:
                    pass
            self.stop_flag.wait(self.probe_interval)

    # -- the app's own recorder (<state>/logs/perf/<day>.jsonl)

    def recorder_new(self):
        folder = os.path.join(self.inst.dir, "logs", "perf")
        out = []
        if not os.path.isdir(folder):
            return out
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(folder, name)
            off = self.recorder_offsets.get(path, 0)
            with open(path) as f:
                f.seek(off)
                data = f.read()
            end = data.rfind("\n") + 1
            self.recorder_offsets[path] = off + len(data[:end].encode())
            for line in data[:end].splitlines():
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        return out

    # -- scenarios

    def wait_prompt(self, pane, timeout=30):
        harness.wait_until(lambda: self.cli("read", "--pane", pane, check=False, kind="setup").stdout.strip() != "",
                           timeout, interval=0.3, message=f"a prompt in {pane}")

    def scenario_panes(self):
        """~30 terminal panes: 10 tabs of 3 (the tab's limit), each with a shell."""
        n_tabs = self.args.tabs
        for i in range(n_tabs):
            created = self.json("tab", "new", "--window", self.window, "--cwd", self.inst.work, "--name", f"perf {i + 1}")
            tab, first = created["tab"], created["pane"]
            self.tabs.append(tab)
            panes = [first]
            for _ in range(2):
                panes.append(self.json("split", "right", "--pane", panes[-1], "--cwd", self.inst.work)["pane"])
            self.panes.extend(panes)
        for p in self.panes:
            self.wait_prompt(p)
        self.log(f"{len(self.panes)} panes in {len(self.tabs)} tabs")
        return {"panes": len(self.panes), "tabs": len(self.tabs)}

    def scenario_agents(self):
        """Fake Claude Code and Codex typed in panes, sent a prompt every second or so, plus every
        other pane's hooks driven straight through `umi hook` as fast as 8 workers go, with three
        `umi events` followers attached."""
        secs = self.args.agent_secs
        typed = self.panes[: self.args.typed_agents]
        for i, pane in enumerate(typed):
            kind = "claude" if i % 2 == 0 else "codex"
            args = "--dangerously-skip-permissions" if kind == "claude" else "--yolo"
            self.inst.type_agent(pane, kind, args=args)
            self.agent_panes.append((pane, kind))
        synthetic = [p for p in self.panes if p not in typed]
        followers = []
        for i in range(3):
            f = open(os.path.join(self.out, f"events-{i}.jsonl"), "w")
            followers.append((subprocess.Popen([self.target.cli_path, "events"], env=self.inst.env, stdout=f,
                                               stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL), f))
        instance = self.inst.instance_id()
        deadline = now() + secs
        counts = {"hooks": 0, "prompts": 0}

        def hook(pane, event, i, **payload):
            payload.update(hook_event_name=event, session_id=f"00000000-0000-4000-8000-{i:012d}",
                           cwd=self.inst.work)
            env = {"UMI_PANE": pane, "UMI_INSTANCE": instance, "UMI_CLI": self.target.cli_path}
            self.cli("hook", event, "--agent", "claude" if i % 3 else "codex", stdin=json.dumps(payload),
                     env=env, kind="hook", check=False)
            with self.lock:
                counts["hooks"] += 1

        def hook_worker(my_panes, w):
            rnd = random.Random(w)
            for pane in my_panes:
                hook(pane, "SessionStart", self.panes.index(pane), source="startup")
            turn = 0
            while now() < deadline:
                for pane in my_panes:
                    i = self.panes.index(pane)
                    turn += 1
                    hook(pane, "UserPromptSubmit", i, prompt=f"task {turn}: refactor the thing")
                    hook(pane, "PreToolUse", i, tool_name="Bash", tool_input={"command": "ls"}, tool_use_id=f"t{turn}")
                    hook(pane, "PostToolUse", i, tool_name="Bash", tool_input={"command": "ls"}, tool_use_id=f"t{turn}",
                         tool_response="ok")
                    if rnd.random() < 0.3:
                        hook(pane, "Notification", i, notification_type="permission_prompt",
                             message="Claude needs your permission to use Bash")
                    done = "Status: done" if rnd.random() < 0.5 else "Status: waiting on you: check"
                    hook(pane, "Stop", i, last_assistant_message=f"Turn {turn} finished.\n{done}")
                    if now() >= deadline:
                        break

        def prompt_worker(pane, kind):
            n = 0
            while now() < deadline:
                n += 1
                self.cli("send", "--pane", pane, "--enter", f"SLEEP 0.4 step {n}", kind="prompt", check=False)
                with self.lock:
                    counts["prompts"] += 1
                time.sleep(1.0)

        workers = 8
        with concurrent.futures.ThreadPoolExecutor(workers + len(typed)) as pool:
            futures = [pool.submit(hook_worker, synthetic[w::workers], w) for w in range(workers) if synthetic[w::workers]]
            futures += [pool.submit(prompt_worker, p, k) for p, k in self.agent_panes]
            for fut in futures:
                fut.result()
        time.sleep(3)
        lines = 0
        for proc, f in followers:
            proc.terminate()
            proc.wait(10)
            f.close()
            with open(f.name) as g:
                lines += sum(1 for _ in g)
        self.log(f"{counts['hooks']} hook calls, {counts['prompts']} prompts typed, {lines} events streamed to 3 followers")
        return {"hook_calls": counts["hooks"], "hooks_per_s": round(counts["hooks"] / secs, 1),
                "prompts": counts["prompts"], "events_streamed": lines, "typed_agents": len(typed)}

    def scenario_queries(self):
        """What managers and scripts do: `pane set` on every pane (sidebar line 2 changes), `ls`,
        queries, lists, and `update --status` (which scans every process)."""
        secs = self.args.query_secs
        deadline = now() + secs
        n = 0
        while now() < deadline:
            n += 1
            pane = self.panes[n % len(self.panes)]
            self.cli("pane", "set", pane, f"note=step {n}", f"progress={n % 100}", kind="set")
            if n % 5 == 0:
                self.cli("--json", "ls", kind="ls")
            if n % 7 == 0:
                self.cli("--json", "ls", "--where", "agent.status=working or progress>50", kind="ls-where")
            if n % 11 == 0:
                self.cli("--json", "list", "show", "jump", kind="list")
            if n % 23 == 0:
                self.cli("--json", "update", "--status", kind="update-status", check=False)
        return {"rounds": n}

    def scenario_flood(self):
        """Output floods: one pane prints ~160 MB, then six panes print ~40 MB each at once."""
        def run(panes, lines):
            marks = []
            for i, pane in enumerate(panes):
                mark = os.path.join(self.files, f"flood-{pane[:8]}-{now():.0f}.done")
                line = "flood \\033[32mgreen\\033[0m " + "x" * 60
                self.cli("send", "--pane", pane, "--enter",
                         f"yes $'{line}' | head -n {lines}; touch '{mark}'", kind="send")
                marks.append(mark)
            start = now()
            harness.wait_until(lambda: all(os.path.exists(m) for m in marks), 600, interval=0.25,
                               message="the floods to finish")
            return round(now() - start, 1)
        # The selected tab's panes are on show; floods there render as well as parse.
        tab = self.tabs[-1]
        self.cli("tab", "focus", tab)
        on_show = self.panes[-3:]
        one = run(on_show[:1], 2_000_000)
        six = run(on_show + self.panes[-6:-3], 500_000)
        self.log(f"one pane 2M lines in {one}s; six panes 0.5M lines each in {six}s")
        return {"one_pane_2M_lines_s": one, "six_panes_0_5M_lines_s": six}

    def scenario_paste(self):
        """A 1 MB paste (`umi send -`, which pastes) into a pane running `cat > file`."""
        pane = self.panes[-1]
        target = os.path.join(self.files, "paste.txt")
        self.cli("send", "--pane", pane, "--enter", f"clear; stty -echo; cat > '{target}'; stty echo", kind="send")
        harness.wait_until(lambda: os.path.exists(target), 10, message="cat to start")
        block = "".join(f"{i:06d} " + "p" * 92 + "\n" for i in range(10486))   # 1 MiB
        start = now()
        self.cli("send", "--pane", pane, "-", stdin=block, kind="paste", timeout=300)
        sent = now() - start
        try:
            harness.wait_until(lambda: os.path.getsize(target) >= len(block) - 200, 300, interval=0.25,
                               message="the paste to arrive")
            arrived = round(now() - start, 1)
        except AssertionError:
            arrived = None
        self.cli("keys", "--pane", pane, "ctrl+d")
        size = os.path.getsize(target)
        self.log(f"paste: CLI answered in {sent:.1f}s, {size} of {len(block)} bytes arrived after {arrived}s")
        return {"paste_bytes": len(block), "cli_answer_s": round(sent, 1), "arrived_s": arrived, "arrived_bytes": size}

    def scenario_markdown(self):
        """A ~5 MB Markdown file in the editor: open it, switch source/preview, type into it."""
        path = os.path.join(self.files, "big.md")
        write_markdown(path, 5 * 1024 * 1024)
        tab = self.tabs[0]
        self.cli("tab", "focus", tab)
        start = now()
        self.cli("edit", path, "--tab", tab, timeout=300)
        opened = now() - start
        harness.wait_until(lambda: any(d["path"].endswith("big.md") for d in self.json("editor", "ls", "--tab", tab)["documents"]),
                           60, interval=0.5, message="the document listed")
        listed = now() - start
        time.sleep(10)
        modes = {}
        for mode in ("source", "preview", "source", "preview"):
            t = now()
            self.cli("editor", "mode", mode, path, timeout=300)
            modes.setdefault(mode, []).append(round(now() - t, 2))
            time.sleep(5)
        typed = []
        for i in range(10):
            t = now()
            self.inst.rpc("debug.editor.type", tab=tab, path=path, text=f"typed line {i}\n")
            typed.append((now() - t) * 1000)
            self.record_call("editor-type", "debug.editor.type", t, typed[-1], 0)
            time.sleep(0.2)
        time.sleep(5)
        self.log(f"markdown: edit answered {opened:.1f}s, listed {listed:.1f}s, modes {modes}, typing max {max(typed):.0f} ms")
        return {"file_mb": round(os.path.getsize(path) / 1048576, 1), "edit_answer_s": round(opened, 2),
                "listed_s": round(listed, 2), "mode_switch_s": modes, "type_ms_max": round(max(typed), 1),
                "type_ms_median": round(statistics.median(typed), 1)}

    def scenario_switch(self):
        """Tabs and panes switched back to back: `tab next`, `pane focus`, `go`, sidebar modes."""
        secs = self.args.switch_secs
        deadline = now() + secs
        rnd = random.Random(7)
        n = 0
        while now() < deadline:
            n += 1
            r = n % 4
            if r == 0:
                self.cli("tab", "next", "--window", self.window, kind="tab-next")
            elif r == 1:
                self.cli("pane", "focus", rnd.choice(self.panes), kind="pane-focus")
            elif r == 2:
                self.cli("go", "note", kind="go", check=False)
            else:
                self.cli("tab", "focus", rnd.choice(self.tabs), kind="tab-focus")
            if n % 50 == 0:
                self.cli("sidebar", "files", "--window", self.window, kind="sidebar")
                self.cli("sidebar", "tabs", "--window", self.window, kind="sidebar")
        return {"switches": n}

    def scenario_idle(self):
        """Everything open (panes, agents, the big document), nobody doing anything."""
        self.probe_interval = 5.0
        try:
            time.sleep(self.args.idle_secs)
        finally:
            self.probe_interval = 0.5
        return {"seconds": self.args.idle_secs}

    def scenario_close(self):
        """Close every tab the run opened (and the agents and the document in them)."""
        for tab in self.tabs:
            self.cli("tab", "close", tab, check=False)
        n = len(self.tabs)
        self.tabs, self.panes, self.agent_panes = [], [], []
        time.sleep(10)
        return {"tabs_closed": n}

    # -- running

    def run_scenario(self, name, iteration=None):
        label = name if iteration is None else f"{name}#{iteration}"
        if name not in ("panes", "close") and not self.panes:
            self.log(f"skipping {name}: no panes (run `panes` first)")
            return
        self.scenario = label
        self.recorder_new()   # skip records from before this scenario
        trace = None
        if self.args.trace and not (self.args.soak and not self.args.soak_trace):
            path = os.path.join(self.out, "traces", f"{label.replace('#', '-')}.trace")
            trace = Trace(path, self.inst.app_pid, name in LIGHT_TRACE, self.log)
            if not trace.start():
                trace = None
        self.log("start")
        start = now()
        error = None
        try:
            extra = getattr(self, f"scenario_{name}")() or {}
        except Exception as e:  # noqa: BLE001
            error = f"{type(e).__name__}: {e}"
            extra = {}
            self.log(f"failed: {error}")
        end = now()
        if trace:
            trace.stop()
        recorder = self.recorder_new()
        self.results.append({"scenario": label, "start": start, "end": end, "extra": extra, "error": error,
                             "trace": trace.path if trace and os.path.exists(trace.path) else None,
                             "recorder": recorder})
        self.log(f"done in {end - start:.0f}s")
        self.scenario = "between"

    def main(self):
        a = self.args
        self.log(f"app {self.target.app}, state {self.inst.dir}, results {self.out}")
        meta = {"app": self.target.app, "app_pid": None, "started": iso(now()), "screen_locked": screen_locked(),
                "host": os.uname().nodename, "load_at_start": os.getloadavg(),
                "git": subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True,
                                      text=True).stdout.strip(), "args": vars(a)}
        info = self.target.info
        meta["app_version"] = info.get("CFBundleShortVersionString")
        top = subprocess.run(["ps", "-Ao", "pcpu=,comm=", "-r"], capture_output=True, text=True).stdout.splitlines()[:6]
        meta["busiest_at_start"] = [l.strip() for l in top]
        self.meta = meta
        self.inst.start_app()
        self.meta["app_pid"] = self.inst.app_pid
        created = self.json("window", "new", "--cwd", self.inst.work)
        self.window, self.anchor = created["window"], created["pane"]
        self.wait_prompt(self.anchor)
        threads = [threading.Thread(target=self.sampler, daemon=True), threading.Thread(target=self.prober, daemon=True)]
        for t in threads:
            t.start()
        time.sleep(5)
        self.scenario = "baseline"
        self.recorder_new()
        b0 = now()
        time.sleep(15)
        self.results.append({"scenario": "baseline", "start": b0, "end": now(), "extra": {"note": "one window, one shell"},
                             "error": None, "trace": None, "recorder": self.recorder_new()})
        try:
            if a.soak:
                stop_at = now() + a.soak * 3600
                i = 0
                while now() < stop_at:
                    i += 1
                    for name in a.scenarios:
                        self.run_scenario(name, i)
                        if now() >= stop_at:
                            break
                    if "close" not in a.scenarios:
                        self.run_scenario("close", i)
            else:
                for name in a.scenarios:
                    self.run_scenario(name)
        finally:
            self.stop_flag.set()
            for t in threads:
                t.join(10)
            self.finish()

    def finish(self):
        self.scenario = "finish"
        if self.inst.app_running():
            self.inst.quit_app()
        else:
            self.log("the app was not running at the end (crashed?)")
        for name in ("app.log",):
            src = os.path.join(self.inst.dir, name)
            if os.path.exists(src):
                shutil.copy(src, os.path.join(self.out, name))
        rec_dir = os.path.join(self.inst.dir, "logs", "perf")
        if os.path.isdir(rec_dir):
            shutil.copytree(rec_dir, os.path.join(self.out, "recorder"), dirs_exist_ok=True)
        binary = os.path.basename(self.target.executable)
        for r in self.results:
            if r.get("trace"):
                self.log(f"exporting {os.path.basename(r['trace'])}")
                try:
                    r["xctrace"] = summarize_trace(r["trace"], self.inst.app_pid, self.out,
                                                   os.path.basename(r["trace"])[:-6], binary)
                except Exception as e:  # noqa: BLE001
                    r["xctrace"] = {"error": f"{type(e).__name__}: {e}"}
                    self.log(f"export failed: {e}")
        write_summary(self)
        if not self.args.keep_state:
            shutil.rmtree(self.inst.dir, ignore_errors=True)
        self.log(f"summary: {os.path.join(self.out, 'summary.md')}")


def write_markdown(path, size):
    rnd = random.Random(1)
    words = "agent pane terminal sidebar render layout status buffer window editor preview source".split()
    parts, total, n = [], 0, 0
    while total < size:
        n += 1
        block = [f"## Section {n}\n\n"]
        block.append(" ".join(rnd.choice(words) for _ in range(120)) + " **bold** and `code` and [a link](https://example.com).\n\n")
        block.append("".join(f"- item {i}: " + " ".join(rnd.choice(words) for _ in range(8)) + "\n" for i in range(6)) + "\n")
        if n % 3 == 0:
            block.append("```python\n" + "".join(f"def f{i}(x):\n    return x * {i}\n" for i in range(8)) + "```\n\n")
        if n % 5 == 0:
            block.append("| a | b | c |\n|---|---|---|\n" + "".join(f"| {i} | {rnd.choice(words)} | {i * 3} |\n" for i in range(8)) + "\n")
        chunk = "".join(block)
        parts.append(chunk)
        total += len(chunk)
    with open(path, "w") as f:
        f.write("# Big document\n\n" + "".join(parts))


# ---------------------------------------------------------------------------------------------
# Summary


def pct(values, q):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def scenario_stats(perf, r):
    s, e = r["start"], r["end"]
    samples = [x for x in perf.samples if s - 1.01 <= x["t"] <= e + 0.01]
    out = {"seconds": round(e - s, 1)}
    if len(samples) >= 2:
        a, b = samples[0], samples[-1]
        dt = b["t"] - a["t"]
        out["cpu_avg"] = round((b["cpu_s"] - a["cpu_s"]) / dt * 100, 1) if dt > 0 else None
        steps = [(y["cpu_s"] - x["cpu_s"]) / (y["t"] - x["t"]) * 100 for x, y in zip(samples, samples[1:]) if y["t"] > x["t"]]
        out["cpu_max"] = round(max(steps), 1) if steps else None
        out["wakeups_per_s"] = round((b["wakeups"] - a["wakeups"]) / dt, 1) if dt > 0 else None
        out["mem_start"] = round(a["footprint_mb"], 1)
        out["mem_end"] = round(b["footprint_mb"], 1)
        out["mem_peak"] = round(max(x["footprint_mb"] for x in samples), 1)
        out["webkit_end"] = b.get("webkit_mb")
        out["threads_end"] = b.get("threads")
        out["load1_avg"] = round(statistics.mean(x["load1"] for x in samples), 1)
    calls = [c for c in perf.call_rows if c["scenario"] == r["scenario"]]
    probes = [c["ms"] for c in calls if c["kind"] == "probe"]
    if probes:
        out["probe_p50"] = round(pct(probes, 0.5))
        out["probe_p95"] = round(pct(probes, 0.95))
        out["probe_max"] = round(max(probes))
        out["probes_over_250"] = sum(1 for p in probes if p >= 250)
    others = [c for c in calls if c["kind"] != "probe"]
    if others:
        worst = max(others, key=lambda c: c["ms"])
        out["slowest_call"] = {"ms": round(worst["ms"]), "cmd": worst["cmd"][:80]}
        by_kind = {}
        for c in others:
            by_kind.setdefault(c["kind"], []).append(c["ms"])
        out["calls"] = {k: {"n": len(v), "p50": round(pct(v, 0.5)), "p95": round(pct(v, 0.95)), "max": round(max(v))}
                        for k, v in sorted(by_kind.items())}
    rec = r.get("recorder") or []
    hangs = {}
    for h in (x for x in rec if x.get("kind") == "hang"):
        key = h.get("id")
        hangs[key] = max(hangs.get(key, 0), h.get("duration_ms") or 0)
    out["rec_hangs"] = len(hangs)
    out["rec_hang_max"] = round(max(hangs.values())) if hangs else None
    slow = {}
    for x in (x for x in rec if x.get("kind") == "slow"):
        d = slow.setdefault(x.get("name"), {"n": 0, "max_ms": 0})
        d["n"] += 1
        d["max_ms"] = max(d["max_ms"], round(x.get("duration_ms") or 0))
    out["rec_slow"] = slow
    xt = r.get("xctrace") or {}
    if "hangs" in xt:
        out["xc_hangs"] = len(xt["hangs"])
        out["xc_hang_max"] = max((h["ms"] for h in xt["hangs"]), default=None)
        out["xc_hitches"] = len(xt.get("hitches", []))
        out["xc_hitch_max"] = max((h["ms"] for h in xt.get("hitches", [])), default=None)
    return out


def fmt(v, unit=""):
    if v is None:
        return "–"
    return f"{v}{unit}"


def write_summary(perf):
    rows = []
    for r in perf.results:
        st = scenario_stats(perf, r)
        rows.append({"scenario": r["scenario"], "stats": st, "extra": r["extra"], "error": r["error"],
                     "xctrace": r.get("xctrace"), "recorder_records": len(r.get("recorder") or [])})
    with open(os.path.join(perf.out, "summary.json"), "w") as f:
        json.dump({"meta": perf.meta, "scenarios": rows}, f, indent=1, default=str)
    with open(os.path.join(perf.out, "recorder.jsonl"), "w") as f:
        for r in perf.results:
            for rec in r.get("recorder") or []:
                f.write(json.dumps({"scenario": r["scenario"], **rec}) + "\n")

    m = perf.meta
    L = [f"# Umi performance run {m['started'][:16]}", "",
         f"- App: `{m['app']}` (version {m.get('app_version')}, repo at `{m['git']}`), host {m['host']}",
         f"- Screen locked at start: {m['screen_locked']}; load average at start: "
         f"{', '.join(f'{x:.1f}' for x in m['load_at_start'])}",
         f"- Raw data: `{perf.out}`", "",
         "Hangs: `xctrace` (Instruments' Hangs, ≥250 ms on the main thread) / the app's recorder "
         "(`logs/perf`, by hang id). CPU is the app process only (% of one core). Memory is phys_footprint "
         "in MB (what Activity Monitor shows). Probe: `umi pane get` every 0.5 s (5 s while idle); its time "
         "includes starting the CLI process.", "",
         "| Scenario | s | Hangs xctrace (n / max ms) | Hangs recorder (n / max ms) | Hitches (n / max ms) | CPU avg / max % | Wakeups/s | Mem start → end (peak) MB | WebKit MB | Probe p50 / p95 / max ms | Slowest CLI call |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        s = row["stats"]
        slow = s.get("slowest_call")
        L.append("| {sc} | {sec} | {xh} | {rh} | {hi} | {cpu} | {wk} | {mem} | {webkit} | {probe} | {slow} |".format(
            sc=row["scenario"] + (" (failed)" if row["error"] else ""), sec=s["seconds"],
            xh=f"{s['xc_hangs']} / {fmt(s['xc_hang_max'])}" if "xc_hangs" in s else "–",
            rh=f"{s['rec_hangs']} / {fmt(s['rec_hang_max'])}",
            hi=f"{s['xc_hitches']} / {fmt(s['xc_hitch_max'])}" if "xc_hitches" in s else "–",
            cpu=f"{fmt(s.get('cpu_avg'))} / {fmt(s.get('cpu_max'))}", wk=fmt(s.get("wakeups_per_s")),
            mem=f"{fmt(s.get('mem_start'))} → {fmt(s.get('mem_end'))} ({fmt(s.get('mem_peak'))})",
            webkit=fmt(s.get("webkit_end")),
            probe=f"{fmt(s.get('probe_p50'))} / {fmt(s.get('probe_p95'))} / {fmt(s.get('probe_max'))}",
            slow=f"{slow['ms']} ms `{slow['cmd']}`" if slow else "–"))
    L += ["", "## Per scenario", ""]
    for row in rows:
        s, xt = row["stats"], row["xctrace"] or {}
        L.append(f"### {row['scenario']}")
        L.append("")
        if row["error"]:
            L.append(f"- Failed: `{row['error']}`")
        if row["extra"]:
            L.append(f"- Measured: {json.dumps(row['extra'])}")
        if s.get("calls"):
            L.append("- CLI calls (n, p50 / p95 / max ms): " + "; ".join(
                f"`{k}` {v['n']}, {v['p50']} / {v['p95']} / {v['max']}" for k, v in s["calls"].items()))
        if s.get("rec_slow"):
            L.append("- Recorder, slow main-thread operations (n, max ms): " + "; ".join(
                f"`{k}` {v['n']}, {v['max_ms']}" for k, v in sorted(s["rec_slow"].items(), key=lambda kv: -kv[1]["max_ms"])))
        if xt.get("error"):
            L.append(f"- xctrace export failed: {xt['error']}")
        for h in sorted(xt.get("hangs", []), key=lambda h: -h["ms"])[:5]:
            frames = ", ".join(f"`{f['function'][:70]}` {f['ms']}" for f in (h.get("top_frames") or [])[:4])
            L.append(f"- Hang {h['ms']} ms ({h['type']}): {frames or 'no Umi frames sampled'}")
        prof = xt.get("profile")
        if prof:
            L.append(f"- Main thread busy {prof['main_thread_ms']} ms. Heaviest Umi functions (inclusive ms): " +
                     ", ".join(f"`{f['function'][:70]}` {f['ms']}" for f in prof["top_umi"][:6]))
            L.append("- Heaviest leaf functions: " + ", ".join(f"`{f['function'][:60]}` {f['ms']}" for f in prof["top_leaf"][:6]))
        if xt.get("signposts"):
            L.append("- Signposts (n, total / max ms): " + "; ".join(
                f"`{k}` {v['count']}, {v['total_ms']} / {v['max_ms']}" for k, v in sorted(xt["signposts"].items(), key=lambda kv: -kv[1]["total_ms"])[:8]))
        L.append("")
    with open(os.path.join(perf.out, "summary.md"), "w") as f:
        f.write("\n".join(L) + "\n")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", help="Umi.app to test (default: the suite's target, app/macos/build/ReleaseLocal/Umi.app)")
    p.add_argument("--scenarios", default=",".join(SCENARIOS),
                   help=f"comma-separated, in order (default: {','.join(SCENARIOS)})")
    p.add_argument("--soak", type=float, default=0, help="loop the scenarios for this many hours")
    p.add_argument("--soak-trace", action="store_true", help="record xctrace in soak mode too (big files)")
    p.add_argument("--no-trace", dest="trace", action="store_false", help="skip xctrace")
    p.add_argument("--tabs", type=int, default=10, help="tabs to open, three panes each (default 10)")
    p.add_argument("--typed-agents", type=int, default=8, help="fake agents typed into panes (default 8)")
    p.add_argument("--agent-secs", type=int, default=60)
    p.add_argument("--query-secs", type=int, default=45)
    p.add_argument("--switch-secs", type=int, default=45)
    p.add_argument("--idle-secs", type=int, default=180)
    p.add_argument("--out", help="results folder (default: logs/perf/<time> at the repository root)")
    p.add_argument("--keep-state", action="store_true", help="keep the instance's state folder")
    a = p.parse_args()
    a.scenarios = [s.strip() for s in a.scenarios.split(",") if s.strip()]
    unknown = [s for s in a.scenarios if s not in SCENARIOS]
    if unknown:
        p.error(f"unknown scenarios: {unknown}")
    return a


if __name__ == "__main__":
    perf = Perf(parse_args())
    try:
        perf.main()
    except KeyboardInterrupt:
        perf.log("interrupted")
        perf.inst.quit_app()
