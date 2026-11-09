"""Session links (SPEC AG-20): `umi://open?task=URL` opens a task's agent session in a new tab.

A local HTTP server stands in for the agent server and serves the tasks. The instance lists it in
`umi-web-origin`. Its ~/best is a temporary folder (`UMI_TEST_BEST_DIR`), and the programs Umi types
(`claude`, `codex`, `ssh`) come from a folder of stand-ins (`UMI_TEST_LINK_BIN`, test hook: the
panes' login shells set their own PATH). Each stand-in records its arguments and folder; `claude`
and `codex` then run the fake agents, whose hooks report them on the pane.
"""

import http.server
import json
import os
import subprocess
import threading
import time
import urllib.parse

import pytest

from harness import FAKE_CLAUDE, FAKE_CODEX, wait_until
from test_umi_panes_ui import ready, rpc

pytestmark = pytest.mark.req("AG-20")

REMOTE = "https://github.com/example/demo.git"


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        self.server.requests.append(self.path)
        path = self.path.split("?")[0]
        if path in self.server.pages:
            data = self.server.pages[path].encode()
            kind = "text/html; charset=utf-8"
        elif path.startswith("/umi/") and path.endswith(".json") and path[5:-5] in self.server.tasks:
            data = json.dumps(self.server.tasks[path[5:-5]]).encode()
            kind = "application/json"
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def _stand_in(path, name, log, then=None, env=None):
    """A program that records its arguments and folder in `log`, then runs `then` (a fake agent)."""
    lines = ["#!/usr/bin/python3", "import json, os, sys",
             f"with open({str(log)!r}, 'a') as f:",
             f"    f.write(json.dumps({{'name': {name!r}, 'argv': sys.argv[1:], 'cwd': os.getcwd()}}) + '\\n')"]
    if then:
        lines += [f"os.environ.update({json.dumps(env or {})})",
                  f"os.execv('/usr/bin/python3', ['python3', {then!r}] + sys.argv[1:])"]
    else:
        lines += ["print('stand-in ' + ' '.join(sys.argv[1:]))"]
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o755)


@pytest.fixture
def links(fresh, tmp_path):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    server.tasks, server.pages, server.requests = {}, {}, []
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    site = f"http://127.0.0.1:{port}"

    config = tmp_path / "xdg" / "umi"
    config.mkdir(parents=True)
    (config / "config").write_text(f"umi-web-origin = {site}\n")
    best, bin_dir, log = tmp_path / "best", tmp_path / "bin", tmp_path / "ran.jsonl"
    best.mkdir()
    bin_dir.mkdir()
    inst = fresh(prefix="acc-links-", start_app=False,
                 env={"XDG_CONFIG_HOME": str(tmp_path / "xdg"), "UMI_TEST_BEST_DIR": str(best),
                      "UMI_TEST_LINK_BIN": str(bin_dir), "UMI_TEST_BROWSER_LOG": str(tmp_path / "browser.log")})
    agents = {"FAKE_AGENT_DIR": inst.fake_dir, "FAKE_CLAUDE_PLUGIN_DIRS": inst.plugin("claude"),
              "FAKE_CODEX_PLUGIN_DIRS": inst.plugin("codex")}
    _stand_in(bin_dir / "claude", "claude", log, FAKE_CLAUDE, agents)
    _stand_in(bin_dir / "codex", "codex", log, FAKE_CODEX, agents)
    _stand_in(bin_dir / "ssh", "ssh", log)
    inst.start_app()
    created = inst.json("window", "new", "--name", "home")
    ready(inst, created["pane"])

    def task(id, **fields):
        server.tasks[id] = {"id": id, "title": f"Task {id}", "folder": "projects/demo", **fields}
        return "umi://open?task=" + urllib.parse.quote(f"{site}/umi/{id}.json", safe="")

    def ran(name):
        if not log.exists():
            return []
        return [r for r in map(json.loads, log.read_text().splitlines()) if r["name"] == name]

    yield {"inst": inst, "site": site, "best": best, "server": server, "task": task, "ran": ran,
           "home": created, "tmp": tmp_path}
    server.shutdown()


def checkout(folder, remote=REMOTE, branch="main"):
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", "-b", branch, str(folder)], check=True)
    subprocess.run(["git", "-C", str(folder), "remote", "add", "origin", remote], check=True)
    return folder


def tab_of(inst, pane):
    window, tab, _ = inst.find_pane(pane)
    return window, tab


def wait_ran(links, name, n=1, timeout=20):
    return wait_until(lambda: len(r := links["ran"](name)) >= n and r, timeout, message=f"{name} to run")[n - 1]


def test_a_link_opens_its_task_in_a_new_tab_in_the_checkout_with_its_remote(links):
    inst, best = links["inst"], links["best"]
    # The repository was renamed on this Mac: its remote finds it.
    folder = checkout(best / "projects" / "demo-renamed")
    checkout(best / "projects" / "demo", remote="https://github.com/example/other")
    url = links["task"]("t1abcdef", remote="git@github.com:example/demo.git", prompt="ECHO hello from the docket")
    before = inst.tree()
    out = inst.json("link", url)
    assert out["where"] == "mac" and os.path.realpath(out["folder"]) == os.path.realpath(folder), out
    window, tab = tab_of(inst, out["pane"])
    assert tab["title"] == "Task t1abcdef" and tab["selected"], tab
    assert len(window["tabs"]) == len(next(w for w in before["windows"] if w["id"] == window["id"])["tabs"]) + 1
    run = wait_ran(links, "claude")
    assert os.path.realpath(run["cwd"]) == os.path.realpath(folder), run
    assert run["argv"] == ["--dangerously-skip-permissions", "ECHO hello from the docket"], run
    # The fake agent's hooks report it on the new pane, with its first prompt.
    wait_until(lambda: inst.attributes(out["pane"]).get("agent.kind") == "claude", 20, message="the agent's hooks")
    wait_until(lambda: inst.attributes(out["pane"]).get("agent.title") == "ECHO hello from the docket", 20,
               message="the first prompt")
    inst.type_line(out["pane"], "/exit")


def test_a_multi_line_prompt_reaches_the_agent_whole(links):
    inst, best = links["inst"], links["best"]
    checkout(best / "projects" / "demo")
    prompt = "Line one with 'quotes' and $HOME and `ticks`\nline two; rm -rf /nothing\n\nlast line"
    out = inst.json("link", links["task"]("t2abcdef", remote=REMOTE, prompt=prompt))
    run = wait_ran(links, "claude")
    assert run["argv"] == ["--dangerously-skip-permissions", prompt], run
    inst.type_line(out["pane"], "/exit")


def test_resume_links_and_codex(links):
    inst, best = links["inst"], links["best"]
    checkout(best / "projects" / "demo")
    out = inst.json("link", links["task"]("t3abcdef", session="5f0c3a2e-1111-2222-3333-444455556666"))
    assert out["where"] == "mac"
    assert wait_ran(links, "claude")["argv"] == ["--dangerously-skip-permissions", "--resume",
                                                 "5f0c3a2e-1111-2222-3333-444455556666"]
    inst.cli("pane", "close", out["pane"], check=False)
    out = inst.json("link", links["task"]("t4abcdef", agent="codex", session="thread-9"))
    assert wait_ran(links, "codex")["argv"] == ["--dangerously-bypass-approvals-and-sandbox", "resume", "thread-9"]
    inst.cli("pane", "close", out["pane"], check=False)
    out = inst.json("link", links["task"]("t5abcdef", agent="codex", prompt="ECHO codex task"))
    assert wait_ran(links, "codex", 2)["argv"] == ["--dangerously-bypass-approvals-and-sandbox", "ECHO codex task"]
    inst.cli("pane", "close", out["pane"], check=False)


def test_a_branch_the_checkout_isnt_on_is_named_in_the_prompt_and_not_switched(links):
    inst, best = links["inst"], links["best"]
    folder = checkout(best / "projects" / "demo", branch="main")
    out = inst.json("link", links["task"]("t6abcdef", remote=REMOTE, branch="feature-x", prompt="ECHO fix it"))
    argv = wait_ran(links, "claude")["argv"]
    first, rest = argv[1].split("\n", 1)
    assert "feature-x" in first and "main" in first, first
    assert rest.strip() == "ECHO fix it"
    head = subprocess.run(["git", "-C", str(folder), "symbolic-ref", "--short", "HEAD"], capture_output=True, text=True)
    assert head.stdout.strip() == "main"
    inst.type_line(out["pane"], "/exit")


def test_a_task_without_a_folder_here_runs_on_the_server_and_says_so(links):
    inst = links["inst"]
    url = links["task"]("t7abcdef", folder="projects/not-here", remote="https://github.com/example/nowhere",
                        prompt="ECHO x", server={"ssh": "agent-server", "user": "agent"})
    out = inst.json("link", url)
    assert out["where"] == "server" and out["notes"], out
    run = wait_ran(links, "ssh")
    assert run["argv"] == ["-t", "agent-server", "sudo", "-iu", "agent", "umi-link", "attach", "t7abcdef"], run
    assert not links["ran"]("claude")
    wait_until(lambda: "Umi: no folder for projects/not-here" in inst.screen(out["pane"]), 10, message="the note")


def test_a_server_task_runs_over_ssh(links):
    inst, best = links["inst"], links["best"]
    checkout(best / "projects" / "demo")
    out = inst.json("link", links["task"]("t8abcdef", where="server", prompt="ECHO x",
                                          server={"ssh": "agent-server", "user": "agent"}))
    assert out["where"] == "server" and not out["notes"]
    assert wait_ran(links, "ssh")["argv"][-2:] == ["attach", "t8abcdef"]
    _, tab = tab_of(inst, out["pane"])
    assert tab["title"] == "Task t8abcdef"


def test_links_to_other_origins_and_bad_tasks_are_refused(links):
    inst, site, server = links["inst"], links["site"], links["server"]
    checkout(links["best"] / "projects" / "demo")
    count = len(inst.tree()["windows"][0]["tabs"])
    other = site.replace("127.0.0.1", "localhost")
    links["task"]("t9abcdef", prompt="ECHO x")
    bad = [
        ("umi://open?task=" + urllib.parse.quote(f"{other}/umi/t9abcdef.json", safe=""), "umi-web-origin"),
        ("umi://open?task=file%3A%2F%2F%2Fetc%2Fpasswd", "http"),
        ("umi://open", "no task"),
        ("umi://run?task=" + urllib.parse.quote(f"{site}/umi/t9abcdef.json", safe=""), "umi://open"),
        (links["task"]("tAabcdef", folder="/etc", prompt="ECHO x"), "folder"),
        (links["task"]("tBabcdef", prompt="ECHO x", session="s1"), "prompt or a session"),
        ("umi://open?task=" + urllib.parse.quote(f"{site}/umi/missing.json", safe=""), "404"),
    ]
    requested = len(server.requests)
    for url, why in bad:
        result = inst.cli("link", url, check=False)
        assert result.returncode == 1, (url, result.stdout)
        assert why in result.stderr, (url, result.stderr)
    # Only listed origins were asked for anything.
    assert all(not r.startswith("/umi/t9") for r in server.requests[requested:]), server.requests
    assert len(inst.tree()["windows"][0]["tabs"]) == count
    assert not links["ran"]("claude") and not links["ran"]("ssh")
    # Each refusal is an event with its reason.
    refused = [e for e in inst.json("log", "--filter", "link.")["events"] if e["event"] == "link.refused"]
    assert len(refused) == len(bad) and all(e["data"]["reason"] for e in refused), refused


def test_a_link_cmd_clicked_in_a_terminal_opens_the_task(links):
    inst, best = links["inst"], links["best"]
    checkout(best / "projects" / "demo")
    url = links["task"]("tCabcdef", prompt="ECHO clicked")
    assert rpc(inst, "debug.ui.open_url", pane=links["home"]["pane"], url=url)["session_link"] is True
    run = wait_ran(links, "claude")
    assert run["argv"][-1] == "ECHO clicked"
    pane = next(p for w in inst.tree()["windows"] for t in w["tabs"] if t["title"] == "Task tCabcdef" for p in t["panes"])
    inst.type_line(pane["id"], "/exit")


def test_a_link_on_a_web_page_opens_the_task_and_a_refused_one_opens_nothing(links):
    inst, site, best, server = links["inst"], links["site"], links["best"], links["server"]
    checkout(best / "projects" / "demo")
    good = links["task"]("tDabcdef", prompt="ECHO from the page")
    server.pages["/go"] = f"<title>Go</title><script>setTimeout(() => location.href = {json.dumps(good)}, 200)</script>"
    inst.cli("edit", site + "/go", "--pane", links["home"]["pane"])
    assert wait_ran(links, "claude")["argv"][-1] == "ECHO from the page"
    # A link whose task is on another origin: nothing runs, and the browser isn't asked either.
    links["task"]("tEabcdef", prompt="ECHO no")
    bad = "umi://open?task=" + urllib.parse.quote(site.replace("127.0.0.1", "localhost") + "/umi/tEabcdef.json", safe="")
    server.pages["/bad"] = f"<title>Bad</title><script>setTimeout(() => location.href = {json.dumps(bad)}, 200)</script>"
    inst.cli("edit", site + "/bad", "--pane", links["home"]["pane"])
    # The refusal is a note at the top of the window, saying why.
    wait_until(lambda: "umi-web-origin" in rpc(inst, "debug.ui.toast")["text"], 10, message="the refusal note")
    assert rpc(inst, "debug.ui.toast")["showing"] is True
    time.sleep(2)
    assert len(links["ran"]("claude")) == 1
    browser = links["tmp"] / "browser.log"
    assert not browser.exists() or "umi://" not in browser.read_text()
