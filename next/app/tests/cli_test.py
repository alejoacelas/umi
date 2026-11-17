#!/usr/bin/env python3
"""Every `umi-next` command against a running test copy of UmiNext.

  cli_test.py APP [SCRATCH]

APP is a UmiNext.app started with UMI_NEXT_DEBUG=1 (its CLI is APP/Contents/MacOS/umi-next; the
debug socket checks what the page did). It types nothing into windows, so it runs with
UMI_NEXT_OFFSCREEN=1 and no screen. Start the app with UMI_NEXT_FOCUS_ASSUME_ACTIVE=1 for the
focus-log checks (an offscreen window is never active). It leaves the layout as it found it,
apart from the sessions it ends. SCRATCH (default: a temp folder) holds the Markdown files.
"""
import json, os, plistlib, re, socket, subprocess, sys, tempfile, time

app = os.path.abspath(sys.argv[1])
scratch = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="umi-next-cli-")
os.makedirs(scratch, exist_ok=True)
CLI = os.path.join(app, "Contents/MacOS/umi-next")
info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
STATE = os.path.expanduser("~/Library/Application Support/" + info["UmiNextStateName"])
ENV = {k: v for k, v in os.environ.items() if not k.startswith("UMI_")}
failures = []


def run(*args, env=None, input=None, ok=True, code=None):
    p = subprocess.run([CLI, *args], capture_output=True, text=True, env={**ENV, **(env or {})}, input=input, timeout=60)
    want = code if code is not None else (0 if ok else None)
    if want is not None and p.returncode != want:
        raise AssertionError(f"umi-next {' '.join(args)} → {p.returncode} (wanted {want}): {p.stderr.strip()}")
    return p


def j(*args, **kw):
    return json.loads(run("--json", *args, **kw).stdout)


def debug(js):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.path.join(STATE, "debug.sock"))
    s.sendall(json.dumps({"cmd": "eval", "js": js}).encode() + b"\n")
    buf = b""
    while (d := s.recv(65536)):
        buf += d
    return json.loads(buf)["result"]


def until(fn, secs=8, what="condition"):
    t = time.time()
    while time.time() - t < secs:
        v = fn()
        if v:
            return v
        time.sleep(0.1)
    raise AssertionError("timed out waiting for " + what)


def check(name, fn):
    try:
        fn()
        print("ok  ", name)
    except Exception as e:  # noqa: BLE001
        failures.append(name)
        print("FAIL", name, "—", e)


def ls():
    return j("ls")


def tabs():
    return ls()["windows"][0]["tabs"]


def pane(pid):
    for t in tabs():
        for p in t["panes"]:
            if p["id"] == pid:
                return {**p, "tab": t["id"]}
    return None


def session_pane(sid):
    for t in tabs():
        for p in t["panes"]:
            if p.get("session") == sid:
                return {**p, "tab": t["id"]}
    return None


def screen(sid):
    return run("read", "--pane", sid).stdout


start = ls()
start_tab, start_pane = start["current_tab"], start["current_pane"]
made = {}


def t_help():
    assert "split" in run("help").stdout
    h = j("help")
    assert h["cli"] == "umi-next" and any(c["usage"].startswith("edit ") for c in h["commands"])
    assert "isn't in Umi next" in run("window", "ls", ok=False, code=1).stderr
    assert run("frobnicate", ok=False, code=1).stderr.startswith("umi-next: ")


def t_ls():
    r = ls()
    w = r["windows"][0]
    assert r["current_tab"] == w["selected_tab"]
    t = w["tabs"][0]
    for k in ("id", "index", "title", "selected", "focused_pane", "panes", "hidden"):
        assert k in t, k
    p = t["panes"][0]
    for k in ("id", "kind", "cwd", "focused", "zoomed", "hidden", "indicator", "session"):
        assert k in p, k
    assert "sessions" in r


def t_tab_new():
    r = j("tab", "new", "cli-tab", "--cmd", "cat", "--name", "catter", "--cwd", scratch)
    made["tab"], made["cat_pane"], made["cat"] = r["tab"], r["pane"], r["session"]
    assert r["session"], r
    t = next(t for t in tabs() if t["id"] == r["tab"])
    assert t["name"] == "cli-tab" and t["selected"]
    assert t["panes"][0]["name"] == "catter" and t["panes"][0]["cwd"] == scratch
    s = next(s for s in ls()["sessions"] if s["id"] == r["session"])
    assert s["by"] == "cli", s  # started by the CLI: out of the user's session lists
    assert debug(f"Umi.model.userStarted(Umi.state.live['{r['session']}'])") in (False, 0, "0", "false"), "picker would list it"


def t_split():
    before = ls()["current_pane"]
    r = j("split", "right", "--cmd", "/bin/sh", "--name", "shell-1", "--no-focus")
    made["sh_pane"], made["sh"] = r["pane"], r["session"]
    assert r["session"] and r["tab"] == made["tab"], r
    assert ls()["current_pane"] == before, "--no-focus moved focus"
    r2 = j("split", "down")  # no --cmd: the picker, as ⌘D
    assert pane(r2["pane"])["kind"] == "picker"
    assert ls()["current_pane"] == r2["pane"]
    run("pane", "close", r2["pane"])
    assert pane(r2["pane"]) is None
    assert "unknown direction" in run("split", "sideways", ok=False, code=1).stderr


def t_send_read_wait():
    sid = made["sh"]
    run("send", "--pane", sid, "--enter", "echo hello-$((40+2))")
    assert run("wait", "--pane", sid, "--pattern", r"^hello-\d+$", "--timeout", "5").stdout.strip() == "hello-42"
    assert "hello-42" in screen(sid)
    last = run("read", "--pane", sid, "--lines", "1").stdout
    assert len(last.strip().splitlines()) == 1
    assert run("wait", "--pane", sid, "--pattern", "never-printed", "--timeout", "1", ok=False, code=124)
    run("wait", "--pane", sid, "--idle", "0.5", "--timeout", "5")
    # By name, by id prefix, piped stdin.
    run("send", "--pane", "shell-1", input="echo piped-ok\n")
    run("wait", "--pane", sid[:5], "--pattern", "^piped-ok$", "--timeout", "5")
    assert "scrollback" in run("read", "--pane", sid, "--scrollback", ok=False, code=1).stderr


def t_keys():
    sid = made["cat"]
    run("send", "--pane", sid, "abc")
    run("keys", "--pane", sid, "backspace", "X", "enter")
    until(lambda: "abX" in screen(sid), what="cat echoing abX")
    run("keys", "--pane", sid, "up", "shift+tab", "esc", "ctrl+u")
    assert "unknown key" in run("keys", "--pane", sid, "nosuchkey", ok=False, code=1).stderr


def t_caller():
    # Inside a session, PANE defaults to the session's own pane (UMI_NEXT_SESSION_ID); the session
    # has this app's CLI in UMI_NEXT_CLI.
    sid, out = made["sh"], os.path.join(scratch, "caller.json")
    run("send", "--pane", sid, "--enter", f"\"$UMI_NEXT_CLI\" --json pane info > {out}; echo caller-done")
    run("wait", "--pane", sid, "--pattern", "^caller-done$", "--timeout", "10")
    r = json.load(open(out))
    assert r["session"] == sid and r["id"] == made["sh_pane"], r
    r = j("pane", "info", env={"UMI_NEXT_SESSION_ID": made["cat"]})
    assert r["session"] == made["cat"]


def t_pane_ops():
    a, b = made["cat_pane"], made["sh_pane"]
    run("pane", "rename", made["sh"], "shell-renamed")
    assert pane(b)["name"] == "shell-renamed"
    run("pane", "rename", made["sh"], "shell-1")
    run("pane", "focus", b)
    assert ls()["current_pane"] == b
    run("pane", "swap", a, b)
    t = next(t for t in tabs() if t["id"] == made["tab"])
    assert [p["id"] for p in t["panes"]] == [b, a], t["panes"]
    w0 = pane(b)["frame"]["width"]
    run("pane", "resize", b, "right", "10")
    assert pane(b)["frame"]["width"] > w0 + 20, (w0, pane(b)["frame"])
    run("pane", "swap", a, b)
    # Close keeps the session; show brings it back; move --new-tab gives it a tab.
    r = j("pane", "close", a)
    assert r["session"] == made["cat"] and session_pane(made["cat"]) is None
    assert any(s["id"] == made["cat"] and s["pane"] is None for s in ls()["sessions"])
    j("pane", "show", made["cat"])
    p = until(lambda: session_pane(made["cat"]), what="the session back on show")
    assert p["tab"] == ls()["current_tab"] and ls()["current_pane"] == b, "show took focus"
    made["cat_pane"] = p["id"]
    r = j("pane", "move", made["cat_pane"], "--new-tab")
    made["cat_tab"] = r["tab"]
    assert r["tab"] != made["tab"] and ls()["current_tab"] == r["tab"]
    assert "--new-tab" in run("pane", "move", made["cat_pane"], "--to", b, ok=False, code=1).stderr
    assert "no pane or session" in run("pane", "focus", "zzzz-none", ok=False, code=1).stderr


def t_tabs():
    n = len(tabs())
    run("tab", "rename", made["tab"], "renamed")
    assert next(t for t in tabs() if t["id"] == made["tab"])["title"] == "renamed"
    run("tab", "focus", "renamed")
    assert ls()["current_tab"] == made["tab"]
    run("tab", "focus", "#1")
    assert ls()["current_tab"] == tabs()[0]["id"]
    r1 = j("tab", "next")
    assert r1["index"] == 2 % n + 0 or r1["index"] >= 1
    r2 = j("tab", "prev")
    assert r2["index"] == 1
    i = next(t["index"] for t in tabs() if t["id"] == made["tab"])
    j("tab", "move", made["tab"], "--down" if i < n else "--up")
    i2 = next(t["index"] for t in tabs() if t["id"] == made["tab"])
    assert abs(i2 - i) == 1
    assert run("tab", "move", tabs()[0]["id"], "--up", ok=False, code=1)
    run("tab", "close", made["cat_tab"])
    assert all(t["id"] != made["cat_tab"] for t in tabs())
    assert any(s["id"] == made["cat"] for s in ls()["sessions"]), "tab close ended its session"


def t_sidebar_shortcuts_go_notify():
    assert j("sidebar", "off")["visible"] is False
    assert j("sidebar", "toggle")["visible"] is True
    assert j("sidebar", "status")["mode"] == "tabs"
    s = j("shortcuts")
    assert any(x["id"] == "splitRight" and x["keys"] == ["cmd+d"] for x in s["shortcuts"])
    # Nothing waits for the user in a fresh test copy.
    g = run("go", "--next", "jump", ok=False)
    assert g.returncode == 0 or "nothing in jump" in g.stderr
    r = run("notify", "cli test", "body", ok=False)
    assert r.returncode == 0 or "notify isn't in Umi next yet" in r.stderr, r.stderr


def t_edit():
    doc = os.path.join(scratch, "doc.md")
    open(doc, "w").write("# Doc\n\nSome words.\n")
    has_editor = debug("!!Umi.actions.openFile") in (True, 1, "1", "true")
    run("tab", "focus", made["tab"])
    before = ls()["current_pane"]
    if not has_editor:
        assert "editor isn't in Umi next yet" in run("edit", doc, ok=False, code=1).stderr
        print("     (no openFile yet: edit, editor checked for their refusal only)")
        return
    r = j("edit", doc, "--source")
    d = r["documents"][0]
    assert d["path"] == os.path.realpath(doc) and d["mode"] == "source", r
    assert ls()["current_pane"] == before, "edit took focus"
    e = j("editor", "ls")
    assert any(x["path"] == d["path"] for x in e["documents"]), e
    assert j("editor", "mode", "preview", doc)["mode"] == "preview"
    j("editor", "close", doc)
    assert not j("editor", "ls")["documents"]
    assert "web pages" in run("edit", "https://example.com", ok=False, code=1).stderr


def t_comments():
    f = os.path.join(scratch, "review.md")
    open(f, "w").write("# Review\n\nThe quick brown fox.\n\n`brown` in code.\n\nAnother brown thing.\n")
    assert run("comments", "add", f, "--on", "brown", "--nth", "2", "Why brown?").stdout.strip() == "added c1"
    assert "{==brown==}{>>Why brown?<<}{#c1}" in open(f).read().split("Another")[1]
    run("comments", "reply", f, "c1", "Because.", "--by", "Tester")
    run("comments", "edit", f, "c1", "Why brown, really?")
    c = j("comments", f)["comments"]
    assert c[0]["body"] == "Why brown, really?" and c[0]["replies"][0]["by"] == "Tester" and c[0]["line"] == 7, c
    run("comments", "resolve", f, "c1", "--note", "explained")
    assert j("comments", f)["comments"] == []
    assert j("comments", "ls", f, "--all")["comments"][0]["resolved_note"] == "explained"
    run("comments", "reopen", f, "c1")
    run("comments", "delete", f, "c1")
    assert "{==" not in open(f).read() and j("comments", "ls", f, "--all")["comments"] == []
    assert "isn't in the text" in run("comments", "add", f, "--on", "zebra", "x", ok=False, code=1).stderr
    # wait: 124 on timeout; answered by the editor's Done, also across a web layer reload.
    run("comments", "wait", f, "--timeout", "1", ok=False, code=124)
    p = subprocess.Popen([CLI, "--json", "comments", "wait", f, "--timeout", "20"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=ENV)
    real = os.path.realpath(f)
    until(lambda: debug("Umi.cli.waiting().length") in (1, "1"), what="the wait to reach the page")
    debug("window.__beforeReload = 1")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.path.join(STATE, "debug.sock"))
    s.sendall(b'{"cmd": "reloadWeb"}\n')
    s.recv(100)
    until(lambda: debug("typeof window.__beforeReload") == "undefined" and debug("Umi.cli.waiting().length") in (1, "1"),
          what="the wait to come back after the reload")
    debug(f"Umi.cli.commentsDone({json.dumps(real)})")
    out, err = p.communicate(timeout=10)
    assert p.returncode == 0 and json.loads(out)["path"] == real, (p.returncode, out, err)


def t_focus_log():
    if debug("1") is None:
        raise AssertionError("no debug socket")
    folder = os.path.join(STATE, "logs/focus")
    r = j("focus-log", "--since", "10m")
    open_ = [s for s in r["stretches"] if s.get("open")]
    if not open_:
        print("     (no open stretch: start the app with UMI_NEXT_FOCUS_ASSUME_ACTIVE=1 to check the focus log)")
        return
    cur = open_[-1]
    for k in ("pane", "start", "end", "start_ts", "end_ts", "seconds", "title", "kind", "cwd", "attributes", "tab", "window"):
        assert k in cur, k
    # Moving focus ends the stretch: it is written to today's file.
    other = next(t["id"] for t in tabs() if t["id"] != ls()["current_tab"])
    run("tab", "focus", other)
    day = time.strftime("%Y-%m-%d")
    until(lambda: os.path.exists(os.path.join(folder, day + ".jsonl")), what="today's focus file")
    lines = [json.loads(x) for x in open(os.path.join(folder, day + ".jsonl"))]
    assert any(x["pane"] == cur["pane"] for x in lines), lines[-3:]
    g = j("focus-log", "--since", "10m", "--by", "session")
    assert g["total_seconds"] >= 0 and "groups" in g


def t_exit():
    run("pane", "exit", made["sh"])
    until(lambda: all(s["id"] != made["sh"] for s in ls()["sessions"]), what="the shell session to end")
    run("pane", "exit", made["cat"])
    until(lambda: all(s["id"] != made["cat"] for s in ls()["sessions"]), what="cat to end")


for name, fn in [("help", t_help), ("ls", t_ls), ("tab new", t_tab_new), ("split", t_split),
                 ("send, read, wait", t_send_read_wait), ("keys", t_keys), ("caller defaults", t_caller),
                 ("pane commands", t_pane_ops), ("tab commands", t_tabs),
                 ("sidebar, shortcuts, go, notify", t_sidebar_shortcuts_go_notify), ("edit, editor", t_edit),
                 ("comments", t_comments), ("focus log", t_focus_log), ("pane exit", t_exit)]:
    check(name, fn)

# Back to where it started.
for t in tabs():
    if t["id"] == made.get("tab"):
        run("tab", "close", t["id"], ok=False)
run("tab", "focus", start_tab, ok=False)
print("\n" + ("all passed" if not failures else f"{len(failures)} failed: {', '.join(failures)}"))
sys.exit(1 if failures else 0)
