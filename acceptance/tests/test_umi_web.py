"""Web panes (SPEC E-12): pages from the origins in `umi-web-origin` open inside Umi.

A local HTTP server stands in for the agent server. Its pages report what the tests need in their
titles (Umi reports a web pane's page title in `ls`). Links that leave the origin would open the
default browser; `UMI_TEST_BROWSER_LOG` makes the app write them to a file instead.

A ⌘-click is driven through the internal `debug.ui.open_url`, which runs what the terminal's
open-URL action runs; `test_cmd_click_on_a_link_opens_a_web_pane_ui` does it with the real mouse.
"""

import http.server
import os
import threading
import time

import pytest

from harness import wait_until
from test_umi_blocks import load_png
from test_umi_panes_ui import ready, rpc, split, tab_of

pytestmark = pytest.mark.editor

PAGES = {
    "/doc": "<title>Desk doc</title><body style='background:#d01010'><h1>Desk doc</h1></body>",
    # A new random number each time the page loads: the same title means it didn't reload.
    "/load": "<script>document.title = 'Load ' + Math.random().toString(36).slice(2)</script>",
    # A draft kept in local storage, as the agent server's page keeps unsaved text.
    "/draft": "<script>if (!localStorage.getItem('draft'))"
              " localStorage.setItem('draft', Math.random().toString(36).slice(2));"
              " document.title = 'Draft ' + localStorage.getItem('draft')</script>",
    "/hop": "<title>Hop</title><script>setTimeout(() => location.href = '/landed', 200)</script>",
    "/landed": "<title>Landed</title>",
    "/away": "<title>Away</title><script>setTimeout(() => location.href = '{other}/elsewhere', 200)</script>",
}


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = PAGES.get(self.path.split("?")[0])
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = body.replace("{other}", self.server.other).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


@pytest.fixture
def site():
    """The stand-in origin, http://127.0.0.1:PORT. (http://localhost:PORT is another origin.)"""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    port = server.server_address[1]
    server.other = f"http://localhost:{port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{port}"
    server.shutdown()


@pytest.fixture
def web(fresh, site, tmp_path):
    """An instance whose config lists the site as a web origin, and its first window's pane."""
    config = tmp_path / "xdg" / "umi"
    config.mkdir(parents=True)
    (config / "config").write_text(f"umi-web-origin = {site}\n")
    log = tmp_path / "browser.log"
    other = fresh(prefix="acc-web-", restore=True,
                  env={"XDG_CONFIG_HOME": str(tmp_path / "xdg"), "UMI_TEST_BROWSER_LOG": str(log)})
    created = other.json("window", "new", "--name", "web")
    ready(other, created["pane"])
    return {"inst": other, "site": site, "log": log, **created}


def pane(inst, pane_id):
    for w in inst.tree()["windows"]:
        for t in w["tabs"]:
            for p in t["panes"]:
                if p["id"] == pane_id:
                    return {**p, "tab": t["id"], "window": w["id"]}
    return None


def web_panes(inst):
    return [p for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"] if p.get("url")]


def titled(inst, pane_id, prefix, timeout=15):
    return wait_until(lambda: (lambda p: p and p.get("title", "").startswith(prefix) and p["title"])(pane(inst, pane_id)),
                      timeout, message=f"the page titled {prefix}…")


@pytest.mark.req("E-12", "E-9")
def test_edit_url_opens_a_listed_origin_in_a_web_pane_beside_the_caller(web):
    inst, site, a = web["inst"], web["site"], web["pane"]
    url = site + "/doc"
    opened = inst.json("edit", url, "--pane", a)
    page = opened["pages"][0]
    assert page["url"] == url
    order = [p["id"] for p in tab_of(inst, web["tab"])["panes"]]
    assert order == [a, page["pane"]], "the page opens to the right of the pane"
    assert titled(inst, page["pane"], "Desk doc")
    assert pane(inst, page["pane"])["url"] == url
    # Opened again: shown where it is, no second pane.
    inst.cli("edit", url, "--pane", a)
    assert len(web_panes(inst)) == 1
    # Another origin is refused and opens nothing.
    refused = inst.cli("edit", "http://localhost:9/x", "--pane", a, check=False)
    assert refused.returncode == 1 and "umi-web-origin" in refused.stderr
    assert len(web_panes(inst)) == 1
    # Not a document of the editor.
    assert inst.json("editor", "ls", "--tab", web["tab"])["documents"] == []


@pytest.mark.req("E-12")
def test_a_link_from_a_listed_origin_opened_in_a_terminal_opens_a_web_pane(web):
    inst, site, a = web["inst"], web["site"], web["pane"]
    assert rpc(inst, "debug.ui.open_url", pane=a, url=site + "/doc")["web_pane"] is True
    page = wait_until(lambda: web_panes(inst), 10, message="a web pane")[0]
    assert pane(inst, page["id"])["tab"] == web["tab"]
    assert inst.tree()["current_pane"] == page["id"], "the page takes focus"
    # A link from anywhere else is left to the browser, as before.
    assert rpc(inst, "debug.ui.open_url", pane=a, url="http://localhost:9/x")["web_pane"] is False
    assert rpc(inst, "debug.ui.open_url", pane=a, url="https://example.com/")["web_pane"] is False
    assert len(web_panes(inst)) == 1


@pytest.mark.req("E-12")
def test_navigation_stays_on_the_origin_and_other_origins_go_to_the_browser(web):
    inst, site, a, log = web["inst"], web["site"], web["pane"], web["log"]
    hop = inst.json("edit", site + "/hop", "--pane", a)["pages"][0]["pane"]
    titled(inst, hop, "Landed")
    assert pane(inst, hop)["url"] == site + "/landed"
    away = inst.json("edit", site + "/away", "--pane", a)["pages"][0]["pane"]
    other = site.replace("127.0.0.1", "localhost") + "/elsewhere"
    wait_until(lambda: log.exists() and other in log.read_text(), 10, message="the other origin sent to the browser")
    time.sleep(0.5)
    assert pane(inst, away)["url"] == site + "/away" and pane(inst, away)["title"] == "Away"


@pytest.mark.req("E-12", "E-1", "M-7")
def test_a_web_pane_moves_and_stacks_without_reloading(web):
    inst, site, a = web["inst"], web["site"], web["pane"]
    page = inst.json("edit", site + "/load", "--pane", a)["pages"][0]["pane"]
    title = titled(inst, page, "Load ")
    inst.cli("pane", "move", page, "--new-tab")
    moved = pane(inst, page)
    assert moved["tab"] != web["tab"]
    b = split(inst, "right", a)
    rpc(inst, "debug.ui.split.drop", pane=page, target=b, zone="center")
    assert pane(inst, page)["stack"] == [b, page]
    time.sleep(1)
    assert pane(inst, page)["title"] == title, "the page didn't load again"
    inst.cli("pane", "close", page)
    wait_until(lambda: not web_panes(inst), 10, message="the web pane closed")


@pytest.mark.req("E-12", "I-4")
def test_a_web_pane_is_restored_by_url_with_its_drafts_and_counts_as_quiet(web):
    inst, site, a = web["inst"], web["site"], web["pane"]
    url = site + "/draft"
    page = inst.json("edit", url, "--pane", a)["pages"][0]["pane"]
    draft = titled(inst, page, "Draft ")
    status = inst.json("update", "--status")
    waiting = status.get("quiet", {}).get("waiting_for", [])
    assert not [w for w in waiting if w.get("pane") == page], waiting
    time.sleep(1)
    inst.quit_gracefully(timeout=60)
    inst.start_app()
    restored = wait_until(lambda: [p for p in web_panes(inst) if p["url"] == url], 20, message="the web pane restored")[0]
    assert titled(inst, restored["id"], "Draft ") == draft, "the page's local storage survived the relaunch"


@pytest.mark.req("E-12", "T-7")
def test_a_screenshot_shows_the_page(web, tmp_path):
    inst, site, a = web["inst"], web["site"], web["pane"]
    page = inst.json("edit", site + "/doc", "--pane", a)["pages"][0]["pane"]
    titled(inst, page, "Desk doc")
    time.sleep(1)
    out = tmp_path / "web.png"
    inst.cli("screenshot", "--window", web["window"], str(out))
    w, h, buf = load_png(out)
    red = sum(1 for i in range(0, w * h * 4, 4 * 7) if buf[i] > 150 and buf[i + 1] < 60 and buf[i + 2] < 60)
    assert red / (w * h / 7) > 0.2, "the page's red background fills its pane in the screenshot"


@pytest.mark.req("E-12")
@pytest.mark.ui
def test_cmd_click_on_a_link_opens_a_web_pane_ui(web):
    """The real mouse: ⌘-click on a URL printed in a terminal pane."""
    import Quartz
    from harness import UI
    if not UI.available():
        pytest.skip("this process has no Accessibility permission")
    inst, site, a = web["inst"], web["site"], web["pane"]
    ui = UI(inst.app_pid)
    url = site + "/doc?" + "x" * 40
    # Every row shows the URL, so a click anywhere on the left of the pane lands on it.
    inst.cli("send", "--pane", a, "-e", f"clear; for i in $(seq 1 $((LINES+2))); do echo {url}; done; sleep 60")
    time.sleep(1.5)
    inst.cli("window", "focus", web["window"])
    ui.activate()
    area = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Terminal pane"), 5, message="the pane")
    from test_umi_panes_ui import _frame
    x, y, w, h = _frame(ui, area)
    point = (x + 60, y + h / 2)
    cmd = Quartz.kCGEventFlagMaskCommand

    def post(kind):
        event = Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventSetFlags(event, cmd)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.15)

    post(Quartz.kCGEventMouseMoved)
    time.sleep(0.3)
    post(Quartz.kCGEventLeftMouseDown)
    post(Quartz.kCGEventLeftMouseUp)
    page = wait_until(lambda: web_panes(inst), 10, message="a web pane from the ⌘-click")[0]
    assert page["url"] == url
    assert not web["log"].exists() or url not in web["log"].read_text()
