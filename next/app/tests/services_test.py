#!/usr/bin/env python3
"""Checks web/fs.js against a running UmiNext started with UMI_NEXT_DEBUG=1: every call goes
from the page through the bridge to Services.swift and back.

  services_test.py STATE_DIR SCRATCH_DIR

SCRATCH_DIR is made into a small git repository (and a folder outside git) to work on.
"""
import json, os, socket, subprocess, sys, time

state, scratch = sys.argv[1], os.path.abspath(sys.argv[2])
fails = []


def D(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.connect(state + "/debug.sock")
    s.sendall(json.dumps(cmd).encode() + b"\n")
    b = b""
    while True:
        d = s.recv(1 << 20)
        if not d:
            break
        b += d
    return json.loads(b)


def ev(js):
    r = D({"cmd": "eval", "js": js})
    if r.get("error"):
        raise RuntimeError(r["error"])
    return r["result"]


n = [0]


def call(expr, timeout=10):
    """Runs a JS expression giving a promise; returns its value, or {'err': code, 'msg': …}."""
    n[0] += 1
    k = f"k{n[0]}"
    ev(f"window.__r = window.__r || {{}}; Promise.resolve().then(() => {expr}).then("
       f"v => window.__r.{k} = JSON.stringify({{ok: v}}), e => window.__r.{k} = JSON.stringify({{err: e.code, msg: e.message}})); 1")
    t = time.time()
    while time.time() - t < timeout:
        v = ev(f"window.__r.{k} || ''")
        if v:
            d = json.loads(v)
            return d["ok"] if "ok" in d else d
        time.sleep(0.05)
    return {"err": "timeout"}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        fails.append(name)


subprocess.run(["rm", "-rf", scratch], check=True)
repo, plain = scratch + "/repo", scratch + "/plain"
os.makedirs(repo + "/src/deep")
os.makedirs(plain + "/sub")
sh = lambda *a: subprocess.run(a, cwd=repo, check=True, capture_output=True)
sh("git", "init", "-q")
open(repo + "/.gitignore", "w").write("ignored.txt\nbuild/\n")
open(repo + "/README.md", "w").write("# Repo\nneedle one\n")
open(repo + "/src/main.swift", "w").write("let x = 1 // needle two\nlet café = \"needle\"\n")
open(repo + "/src/deep/QuickOpenTarget.js", "w").write("x\n")
open(repo + "/ignored.txt", "w").write("needle ignored\n")
open(repo + "/.hidden", "w").write("h\n")
os.makedirs(repo + "/build")
sh("git", "add", ".gitignore", "README.md", "src/main.swift")
sh("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
open(plain + "/a.txt", "w").write("a\n")
open(plain + "/sub/b.txt", "w").write("b\n")

ev("window.__r = {}; 1")
check("bridge ready", ev("typeof Umi.fs.read") == "function")
root = ev("Umi.fs.root()")
check("root() is a folder", isinstance(root, str) and root.startswith("/"), root)
check("resolve relative", ev(f"Umi.fs.resolve('src/../a.md', '{repo}')") == repo + "/a.md")

# read / write / conflict
f = repo + "/notes.md"
r = call(f"Umi.fs.write('{f}', 'one\\n', {{version: null}})")
check("write new (version null)", isinstance(r, dict) and r.get("version", "").startswith("sha256:"), r)
r2 = call(f"Umi.fs.write('{f}', 'again\\n', {{version: null}})")
check("version null refuses an existing file", r2.get("err") == "conflict", r2)
rd = call(f"Umi.fs.read('{f}')")
check("read back", rd.get("text") == "one\n" and rd.get("version") == r["version"], rd)
w = call(f"Umi.fs.write('{f}', 'two\\n', {{version: '{rd['version']}'}})")
check("write with current version", "version" in w and open(f).read() == "two\n", w)
stale = call(f"Umi.fs.write('{f}', 'three\\n', {{version: '{rd['version']}'}})")
check("write with stale version is a conflict", stale.get("err") == "conflict" and open(f).read() == "two\n", stale)
open(f, "w").write("changed outside\n")
c2 = call(f"Umi.fs.write('{f}', 'four\\n', {{version: '{w['version']}'}})")
check("outside change is a conflict", c2.get("err") == "conflict", c2)
check("force write without version", "version" in call(f"Umi.fs.write('{f}', 'five\\n')") and open(f).read() == "five\n")
os.chmod(f, 0o755)
os.symlink("notes.md", repo + "/link.md")
call(f"Umi.fs.write('{repo}/link.md', 'via link\\n')")
check("write keeps a symlink and permissions",
      os.path.islink(repo + "/link.md") and open(f).read() == "via link\n" and (os.stat(f).st_mode & 0o777) == 0o755)
check("no temp files left", not [x for x in os.listdir(repo) if "umi-next-" in x], os.listdir(repo))
check("read missing → notFound", call(f"Umi.fs.read('{repo}/nope')").get("err") == "notFound")
check("read folder → isDir", call(f"Umi.fs.read('{repo}/src')").get("err") == "isDir")
open(repo + "/bin.dat", "wb").write(b"\xff\xfe\x00\x81")
check("read binary → binary", call(f"Umi.fs.read('{repo}/bin.dat')").get("err") == "binary")
check("unicode round trip", call(f"Umi.fs.write('{repo}/u.md', 'café ✓ 🎉\\n').then(() => Umi.fs.read('{repo}/u.md')).then(r => r.text)") == "café ✓ 🎉\n")

# list
ls = call(f"Umi.fs.list('{repo}')")
names = [e["name"] for e in ls.get("entries", [])]
check("list: folders first, ignored and hidden left out",
      names[:1] == ["src"] and "ignored.txt" not in names and ".hidden" not in names and "build" not in names and ls.get("git") is True, names)
ls2 = call(f"Umi.fs.list('{repo}', {{hidden: true, ignored: true}})")
by = {e["name"]: e for e in ls2.get("entries", [])}
check("list with hidden+ignored marks them", by.get("ignored.txt", {}).get("ignored") is True and by.get(".hidden", {}).get("hidden") is True
      and by.get("build", {}).get("kind") == "dir" and ".git" not in by and by.get("link.md", {}).get("link") is True, list(by))
check("list outside git", [e["name"] for e in call(f"Umi.fs.list('{plain}')").get("entries", [])] == ["sub", "a.txt"])

# files + fuzzy
fl = call(f"Umi.fs.files('{repo}')")
check("files from git: tracked + untracked, not ignored", fl.get("source") == "git" and "src/deep/QuickOpenTarget.js" in fl["files"]
      and "README.md" in fl["files"] and "ignored.txt" not in fl["files"], fl)
fw = call(f"Umi.fs.files('{plain}')")
check("files by walk outside git", fw.get("source") == "walk" and sorted(fw["files"]) == ["a.txt", "sub/b.txt"], fw)
fz = call(f"Umi.fs.files('{repo}').then(r => Umi.fs.fuzzy('qot', r.files, 3))")
check("fuzzy ranks the file-name match first", fz and fz[0]["path"] == "src/deep/QuickOpenTarget.js", fz)

# search
ev("window.__m = []")
s = call(f"Umi.fs.search('needle', {{root: '{repo}'}}, (b) => window.__m.push(...b)).done")
m = json.loads(ev("JSON.stringify(window.__m)"))
paths = sorted({x["path"] for x in m})
check("search finds matches (lines), skips ignored", s.get("count") == 3 and paths == ["README.md", "src/main.swift"], (s, paths))
cafe = [x for x in m if "café" in x["text"]]
check("search ranges are JS string indexes", cafe and cafe[0]["text"][cafe[0]["ranges"][0][0]:cafe[0]["ranges"][0][1]] == "needle", cafe)
s2 = call(f"Umi.fs.search('NEEDLE', {{root: '{repo}', caseSensitive: true}}).done")
check("case-sensitive search", s2.get("count") == 0, s2)
s3 = call(f"Umi.fs.search('needle (one|two)', {{root: '{repo}', regex: true}}).done")
check("regex search", s3.get("count") == 2, s3)
s4 = call(f"Umi.fs.search('needle', {{root: '{repo}', glob: ['*.md']}}).done")
check("glob", s4.get("count") == 1, s4)
s5 = call(f"Umi.fs.search('(', {{root: '{repo}', regex: true}}).done")
check("bad regex → searchFailed", s5.get("err") == "searchFailed", s5)
s6 = call(f"Umi.fs.search('e', {{root: '{repo}', maxResults: 2}}).done")
check("maxResults truncates", s6.get("count") == 2 and s6.get("truncated") is True, s6)
home = os.path.expanduser("~")
t = time.time()
s7 = call(f"(() => {{ const h = Umi.fs.search('the', {{root: '{home}', hidden: true, ignored: true, maxResults: 10000000}}); setTimeout(() => h.cancel(), 150); return h.done; }})()", timeout=20)
check("cancel ends a long search", s7.get("cancelled") is True and time.time() - t < 5, s7)

# watch
ev("window.__w = []")
ev(f"window.__wh = Umi.fs.watch('{repo}', (d) => window.__w.push(...d.changes)); 1")
time.sleep(0.3)
open(repo + "/src/new.txt", "w").write("x\n")
os.remove(repo + "/README.md")
time.sleep(0.6)
wch = json.loads(ev("JSON.stringify(window.__w)"))
got = {c["path"]: c for c in wch}
check("watch reports a new file and a removed one", repo + "/src/new.txt" in got and got.get(repo + "/README.md", {}).get("exists") is False, wch)
check("watch leaves out .git", not any("/.git/" in c["path"] for c in wch), wch)
ev("window.__wh.close(); window.__w = []; 1")
ev(f"window.__fh = Umi.fs.watch('{repo}/src/main.swift', (d) => window.__w.push(...d.changes)); 1")
time.sleep(0.3)
open(repo + "/src/main.swift", "a").write("// more\n")
open(repo + "/src/other.txt", "w").write("x\n")
time.sleep(0.6)
wf = json.loads(ev("JSON.stringify(window.__w)"))
check("file watch sees only that file", {c["path"] for c in wf} == {repo + "/src/main.swift"}, wf)
closed = call("window.__fh.close().then(() => window.__fh.done)")
check("watch close ends it", closed.get("cancelled") is True, closed)
ev("window.__w = []")
open(repo + "/src/main.swift", "a").write("// after close\n")
time.sleep(0.5)
check("no events after close", json.loads(ev("JSON.stringify(window.__w.filter(c => c.path.endsWith('main.swift')))")) == [])

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
