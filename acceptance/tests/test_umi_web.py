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
    # A page that speaks to Umi as the agent server's file page does: it tells Umi its path, mode
    # and GitHub link, and switches when Umi calls window.umiPage.setMode. Its title reports what
    # it saw: whether Umi marked it as hosted, and its mode.
    "/hosted": "<title>Hosted</title><script>"
               "const hosted = window.umiHosted === true;"
               "let mode = 'preview';"
               "function tell() {"
               "  document.title = 'Hosted ' + mode + (hosted ? ' in umi' : '');"
               "  if (hosted) webkit.messageHandlers.umi.postMessage({path: 'desk/notes/AGENTS.md', mode: mode,"
               "    hasModes: true, github: 'https://github.com/alejoacelas/desk/blob/main/notes/AGENTS.md', dirty: false});"
               "}"
               "window.umiPage = {setMode: m => { mode = m; tell(); }};"
               "tell();</script>",
    # Messages of the wrong shape, then one asking Umi to open somewhere other than GitHub: all ignored.
    "/malformed": "<title>Malformed</title><script>"
                  "const post = m => webkit.messageHandlers.umi.postMessage(m);"
                  "post('desk/AGENTS.md'); post({path: 42, mode: 'preview', hasModes: true, dirty: false});"
                  "post({path: 'a/b.md', mode: 'edit', hasModes: true, dirty: false});"
                  "post({path: 'a/b.md', mode: 'preview', hasModes: 1, dirty: false});"
                  "post({path: 'a/b.md', mode: 'preview', hasModes: true, dirty: false, github: 'https://evil.example/x'});"
                  "post({path: 'a/b.md', mode: 'preview', hasModes: true, dirty: false, github: 'http://github.com/x'});"
                  "document.title = 'Malformed sent';</script>",
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
def test_cmd_click_on_a_link_opens_a_web_pane_ui(web, ui):
    """The real mouse: ⌘-click on a URL printed in a terminal pane. (The `ui` fixture checks the
    Accessibility permission and that the screen is unlocked; this drives its own instance.)"""
    import Quartz
    from harness import UI
    if not UI.available():
        pytest.skip("this process has no Accessibility permission")
    inst, site, a = web["inst"], web["site"], web["pane"]
    ui = UI(inst.app_pid)
    url = site + "/doc?" + "x" * 40
    # Every row shows the URL, so a click anywhere on the left of the pane lands on it.
    inst.cli("send", "--pane", a, "-e", f"clear; for i in $(seq 1 $((LINES+2))); do echo '{url}'; done; sleep 60")
    time.sleep(1.5)
    inst.cli("window", "focus", web["window"])
    ui.activate()
    area = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Terminal pane"), 5, message="the pane")
    from test_umi_panes_ui import _frame
    x, y, w, h = _frame(ui, area)
    point = (x + 60, y + h / 2)
    cmd = Quartz.kCGEventFlagMaskCommand
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)

    def mouse(kind, flags=0):
        event = Quartz.CGEventCreateMouseEvent(source, kind, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventSetFlags(event, flags)
        if kind != Quartz.kCGEventMouseMoved:
            Quartz.CGEventSetIntegerValueField(event, Quartz.kCGMouseEventClickState, 1)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.2)

    def command_key(down):
        event = Quartz.CGEventCreateKeyboardEvent(source, 55, down)
        Quartz.CGEventSetFlags(event, cmd if down else 0)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.2)

    # A plain click puts the pane in focus; then ⌘ goes down, the pointer moves onto the link
    # (the terminal underlines it) and clicks.
    mouse(Quartz.kCGEventMouseMoved)
    mouse(Quartz.kCGEventLeftMouseDown)
    mouse(Quartz.kCGEventLeftMouseUp)
    time.sleep(0.5)
    command_key(True)
    point = (point[0] + 5, point[1])
    mouse(Quartz.kCGEventMouseMoved, cmd)
    time.sleep(0.5)
    mouse(Quartz.kCGEventLeftMouseDown, cmd)
    mouse(Quartz.kCGEventLeftMouseUp, cmd)
    command_key(False)
    try:
        page = wait_until(lambda: web_panes(inst), 10, message="a web pane from the ⌘-click")[0]
    except AssertionError:
        inst.cli("screenshot", "--window", web["window"], os.path.join(inst.dir, "cmd-click.png"), check=False)
        raise AssertionError(f"no web pane after a ⌘-click at {point} in the pane at {(x, y, w, h)}; "
                             f"screenshot in {inst.dir}; the pane shows:\n{inst.screen(a)[-600:]}")
    assert page["url"] == url
    assert not web["log"].exists() or url not in web["log"].read_text()


def web_header(inst, pane_id, **params):
    return inst.rpc("debug.ui.web", pane=pane_id, **params)


@pytest.mark.req("E-12", "E-24", "E-2")
def test_a_hosted_page_shows_its_path_and_switch_in_umis_header(web):
    """The agent server's file page in Umi (2026-11-07): Umi marks it as hosted, its path and
    Preview / Source move into Umi's header, and Umi's switch drives the page's."""
    inst, site, a, log = web["inst"], web["site"], web["pane"], web["log"]
    page = inst.json("edit", site + "/hosted", "--pane", a)["pages"][0]["pane"]
    titled(inst, page, "Hosted preview in umi")
    state = wait_until(lambda: web_header(inst, page)["hosted"], 10, message="the page's state reached Umi")
    assert state == {"path": "desk/notes/AGENTS.md", "mode": "preview", "has_modes": True,
                     "github": "https://github.com/alejoacelas/desk/blob/main/notes/AGENTS.md", "dirty": False}
    header = web_header(inst, page)["header"]
    assert (header["folder"], header["name"]) == ("notes", "AGENTS.md"), header
    assert header["switch"] and header["github"], header
    web_header(inst, page, mode="source")
    titled(inst, page, "Hosted source in umi")
    wait_until(lambda: web_header(inst, page)["hosted"]["mode"] == "source", 5, message="Umi's switch follows")
    web_header(inst, page, toggle=True)   # ⌘E's action
    titled(inst, page, "Hosted preview in umi")
    web_header(inst, page, github=True)
    github = "https://github.com/alejoacelas/desk/blob/main/notes/AGENTS.md"
    wait_until(lambda: log.exists() and github in log.read_text(), 5, message="GitHub opened in the browser")
    assert pane(inst, page)["url"] == site + "/hosted", "the pane itself stays on the page"


@pytest.mark.req("E-12")
def test_malformed_messages_from_a_page_are_ignored(web):
    inst, site, a, log = web["inst"], web["site"], web["pane"], web["log"]
    page = inst.json("edit", site + "/malformed", "--pane", a)["pages"][0]["pane"]
    titled(inst, page, "Malformed sent")
    time.sleep(0.5)
    out = web_header(inst, page, github=True, mode="source")
    assert out["hosted"] is None, out
    assert out["header"]["name"] == "Malformed sent" and not out["header"]["switch"], "the bar shows the title"
    assert not log.exists() or "evil.example" not in log.read_text()
    # A page that says nothing keeps today's bar: its title.
    plain = inst.json("edit", site + "/doc", "--pane", a)["pages"][0]["pane"]
    titled(inst, plain, "Desk doc")
    assert web_header(inst, plain)["hosted"] is None


@pytest.mark.req("E-12", "E-2")
@pytest.mark.ui
def test_a_hosted_pages_switch_in_umis_header_ui(web, ui):
    """The real switch: Preview / Source buttons in the web pane's header, pressed through the
    accessibility tree."""
    from harness import UI
    if not UI.available():
        pytest.skip("this process has no Accessibility permission")
    inst, site, a = web["inst"], web["site"], web["pane"]
    ui = UI(inst.app_pid)
    page = inst.json("edit", site + "/hosted", "--pane", a)["pages"][0]["pane"]
    titled(inst, page, "Hosted preview in umi")
    wait_until(lambda: web_header(inst, page)["hosted"], 10, message="the page's state reached Umi")
    area = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Web page"), 5, message="the web pane")
    source = wait_until(lambda: ui.button("Source", area), 5, message="Source in the header")
    assert ui.button("Preview", area) is not None and ui.button("GitHub", area) is not None
    assert ui.find(lambda e: ui.role(e) == "AXStaticText" and "AGENTS.md" in (ui.label(e), ui.value(e)), area) is not None
    ui.press(source)
    titled(inst, page, "Hosted source in umi")


@pytest.mark.req("E-12", "E-24", "M-7")
@pytest.mark.ui
def test_a_stacked_web_pane_shows_its_controls_in_the_stacks_row_ui(web):
    """In a stack (2026-11-07, "S1") a web pane draws no header of its own: the stack's row holds the
    chips (the page's tooltip is its address) and the page's switch, GitHub, Reload, Open in
    Browser and ✕, whose ✕ closes the page."""
    from harness import UI
    from test_umi_editor_warp import frame
    if not UI.available():
        pytest.skip("this process has no Accessibility permission")
    inst, site, a = web["inst"], web["site"], web["pane"]
    ui = UI(inst.app_pid)
    page = inst.json("edit", site + "/hosted", "--pane", a)["pages"][0]["pane"]
    titled(inst, page, "Hosted preview in umi")
    wait_until(lambda: web_header(inst, page)["hosted"], 10, message="the page's state reached Umi")
    rpc(inst, "debug.ui.split.drop", pane=page, target=a, zone="center")
    wait_until(lambda: pane(inst, page).get("shown", True) and pane(inst, a).get("shown") is False, 5,
               message="the page on show in a's place")
    inst.cli("window", "focus", web["window"])
    strip = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Stacked panes"), 5, message="the stack's row")
    area = wait_until(lambda: ui.find(lambda e: ui.label(e) == "Web page"), 5, message="the web pane")
    sx, sy, sw, sh = frame(ui, strip)
    assert sh == pytest.approx(30, abs=1), f"one 30-point row: {sh}"
    assert frame(ui, area)[1] - (sy + sh) == pytest.approx(0, abs=1), "the page starts right under the row"
    for label in ("Reload", "Open in Browser", "GitHub", "Preview", "Source"):
        assert ui.button(label, area) is None, f"no {label} in the page's own area"
        assert ui.button(label, strip) is not None, f"{label} in the row: {ui.texts(strip)}"
    title = pane(inst, page)["title"]
    chip = ui.find(lambda e: ui.label(e) == title and ui.role(e) != "AXStaticText", strip)
    assert chip is not None, ui.texts(strip)
    assert ui.attr(chip, "AXHelp") == site + "/hosted", ui.attr(chip, "AXHelp")
    assert frame(ui, ui.button("Reload", strip))[0] > frame(ui, chip)[0] + frame(ui, chip)[2], "controls right of the chips"
    closes = ui.find_all(lambda e: ui.label(e) == f"Close {title}", strip)
    ui.press(max(closes, key=lambda e: frame(ui, e)[0]))
    wait_until(lambda: pane(inst, page) is None, 5, message="the row's ✕ closed the page")
    assert pane(inst, a).get("shown", True) and not pane(inst, a).get("stack")
