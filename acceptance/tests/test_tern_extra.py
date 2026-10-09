"""Extra tests for risks of this build's design that the suite didn't cover.

Tern keeps its own tabs (the panes of tabs that aren't shown keep running off screen), finds
its instance from the state directory, and remembers which run of the app a pane belongs to.
These tests check the outcomes those choices put at risk. Black-box like the rest of the suite.
"""

import json
import os
import shutil
import subprocess
import threading
import time
import uuid
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

import pytest

from harness import CLIError, Instance, Target, clean_env, frontmost_pid, login_which, wait_until

pytestmark = pytest.mark.layout


def pane_info(inst, pane):
    return inst.json("pane", "info", pane)


def window_of(inst, window_id):
    return next(w for w in inst.tree()["windows"] if w["id"] == window_id)


def activate_finder():
    subprocess.run(["osascript", "-e", 'tell application "Finder" to activate'], capture_output=True, timeout=20)
    time.sleep(1.0)


@pytest.mark.req("L-8")
def test_no_focus_creation_keeps_a_background_app_in_the_background(inst, win):
    """L-8: "If the app is in the background, it stays in the background." The suite's own L-8
    tests start with the app in front, so this puts another app in front first."""
    activate_finder()
    front = frontmost_pid()
    if front is None or front == inst.app_pid:
        pytest.skip("couldn't put another app in front")
    inst.cli("split", "right", "--pane", win["pane"], "--no-focus")
    inst.cli("tab", "new", "--window", win["window"], "--no-focus")
    created = inst.json("window", "new", "--no-focus")
    inst.cli("pane", "move", created["pane"], "--new-tab", "--window", win["window"], "--no-focus")
    time.sleep(1.0)
    assert frontmost_pid() == front, "a --no-focus command brought the app to the front"


@pytest.mark.req("R-7")
def test_a_terminal_of_an_earlier_run_never_acts_on_the_new_run(fresh):
    """R-7 for the same state directory: the app quit and started again, and a terminal (or a
    script that saved its environment) from the first run calls the CLI. The pane it names is
    gone; the CLI must fail clearly, never fall back to whatever pane is focused now."""
    a = fresh(prefix="acc-r7same-")
    pane = a.json("window", "new")["pane"]
    dump = os.path.join(a.dir, "pane-env")
    a.cli("send", "--pane", pane, "-e", f"env > '{dump}'; echo DUMPED")
    a.cli("wait", "--pane", pane, "--pattern", "^DUMPED", "--timeout", "15")
    with open(dump) as f:
        stale = dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    a.quit_app()
    a.start_app()
    current = a.json("window", "new", "--name", "second-run")["pane"]
    proc = subprocess.run([a.target.cli_path, "pane", "rename", "stale-was-here"], env=stale,
                          capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    assert proc.returncode != 0 and proc.stderr.strip(), "a stale pane fails clearly"
    names = [p.get("name") for w in a.tree()["windows"] for t in w["tabs"] for p in t["panes"]]
    assert "stale-was-here" not in names
    assert pane_info(a, current).get("name") != "stale-was-here"


@pytest.mark.req("L-3", "M-1")
def test_a_pane_that_exits_in_a_background_tab_is_removed(inst, win):
    """Panes of tabs that aren't shown keep running; when their program ends, the pane (and an
    emptied tab) goes away like a visible one would."""
    pane = inst.cli("tab", "new", "--window", win["window"], "--no-focus").stdout.strip()
    tab = pane_info(inst, pane)["tab"]
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="prompt")
    # Ghostty treats a shell that ends within abnormal-command-exit-runtime (250 ms) of starting
    # as a failed launch and keeps its message on screen; give it a normal life first.
    time.sleep(1.5)
    inst.cli("send", "--pane", pane, "-e", "exit")
    wait_until(lambda: inst.find_pane(pane) is None, 15, message="the exited pane is gone")
    assert all(t["id"] != tab for t in window_of(inst, win["window"])["tabs"]), "the emptied tab closed"
    assert window_of(inst, win["window"])["selected_tab"] == win["tab"], "the user's tab stayed selected"


@pytest.mark.req("L-3", "L-8")
def test_splitting_and_moving_in_a_background_tab_changes_no_focus(inst, win):
    other = inst.cli("tab", "new", "--window", win["window"], "--no-focus").stdout.strip()
    other_tab = pane_info(inst, other)["tab"]
    right = inst.cli("split", "right", "--pane", other, "--no-focus").stdout.strip()
    assert pane_info(inst, right)["tab"] == other_tab
    w = window_of(inst, win["window"])
    assert w["selected_tab"] == win["tab"]
    marker = "BG-" + uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", right, "-e", f"echo {marker}")
    inst.cli("wait", "--pane", right, "--pattern", f"^{marker}$", "--timeout", "15")
    inst.cli("pane", "move", right, "--to", win["pane"], "--dir", "down", "--no-focus")
    w = window_of(inst, win["window"])
    tab = next(t for t in w["tabs"] if t["id"] == win["tab"])
    assert w["selected_tab"] == win["tab"] and tab["focused_pane"] == win["pane"]
    assert marker in inst.cli("read", "--pane", right, "--scrollback").stdout


@pytest.mark.req("T-3")
def test_wait_matches_output_not_the_typed_command(inst, win):
    """T-3 waits for a pane's *output*. Text that only appears in the command line the shell
    echoes (here a no-op `:` command) is not output."""
    token = "ONLY-TYPED-" + uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", win["pane"], "-e", f": {token}")
    proc = inst.cli("wait", "--pane", win["pane"], "--pattern", token, "--timeout", "2", check=False)
    assert proc.returncode == 124, f"matched the typed command: {proc.stdout!r}"
    inst.cli("send", "--pane", win["pane"], "-e", f"echo {token}")
    assert inst.cli("wait", "--pane", win["pane"], "--pattern", token, "--timeout", "10").stdout.strip() == token


@pytest.mark.req("T-4", "M-1", "M-2")
def test_moves_are_events(inst, win):
    events = subprocess.Popen([inst.target.cli_path, "events", "--filter", "pane.moved", "--filter", "tab.moved"],
                              stdout=subprocess.PIPE, text=True, env=inst.env, stdin=subprocess.DEVNULL)
    try:
        time.sleep(0.6)
        right = inst.cli("split", "right", "--pane", win["pane"]).stdout.strip()
        inst.cli("pane", "move", right, "--new-tab", "--no-focus")
        tab = pane_info(inst, right)["tab"]
        inst.cli("tab", "move", tab, "--index", "1", "--no-focus")
        time.sleep(1.0)
    finally:
        events.terminate()
    out = events.communicate(timeout=10)[0]
    assert '"pane.moved"' in out and '"tab.moved"' in out, out


@pytest.mark.req("L-4")
def test_selectors_by_index_name_and_prefix_are_unambiguous(inst, win):
    inst.cli("tab", "rename", win["tab"], "sel-tab-" + win["tab"][:6])
    assert inst.json("tab", "focus", "sel-tab-" + win["tab"][:6])["tab"] == win["tab"]
    second = pane_info(inst, inst.cli("tab", "new", "--window", win["window"]).stdout.strip())
    inst.cli("tab", "rename", second["tab"], "sel-tab-" + win["tab"][:6])
    proc = inst.cli("tab", "focus", "sel-tab-" + win["tab"][:6], check=False)
    assert proc.returncode != 0 and "named" in proc.stderr, "two tabs with one name are ambiguous"
    assert inst.cli("tab", "focus", "#0", check=False).returncode != 0


@pytest.mark.req("P-4", "R-5")
def test_the_cli_outside_tern_ignores_another_instances_pane(fresh):
    """A shell inside instance A that points the CLI at instance B (TERN_STATE_DIR) talks to B,
    with B's defaults, not A's pane."""
    a, b = fresh(prefix="acc-x-a-"), fresh(prefix="acc-x-b-")
    a_pane = a.json("window", "new")["pane"]
    b_pane = b.json("window", "new", "--name", "b-only")["pane"]
    dump = os.path.join(a.dir, "env-a")
    a.cli("send", "--pane", a_pane, "-e", f"env > '{dump}'; echo DUMPED")
    a.cli("wait", "--pane", a_pane, "--pattern", "^DUMPED", "--timeout", "15")
    with open(dump) as f:
        env = dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    env[b.target.env_names["state_dir"]] = b.dir
    proc = subprocess.run([b.target.cli_path, "--json", "pane", "info"], env=env, capture_output=True, text=True,
                          timeout=60, stdin=subprocess.DEVNULL)
    assert proc.returncode == 0, proc.stderr
    assert a_pane not in proc.stdout, "B answered with A's pane"


@pytest.mark.req("M-1")
def test_moving_a_windows_only_pane_to_a_new_tab_keeps_it(inst):
    """The pane is the only pane of its window's only tab: moving it to a new tab of that same
    window must not close the window it is moving into."""
    created = inst.json("window", "new")
    pane = created["pane"]
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="prompt")
    inst.cli("pane", "move", pane, "--new-tab", "--no-focus")
    found = wait_until(lambda: inst.find_pane(pane), 5, message="the moved pane")
    assert found[0]["id"] == created["window"] and len(found[0]["tabs"]) == 1
    marker = "ALIVE-" + uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", pane, "-e", f"echo {marker}")
    inst.cli("wait", "--pane", pane, "--pattern", f"^{marker}$", "--timeout", "10")
    inst.cli("window", "close", created["window"])


@pytest.mark.req("E-1", "E-3", "M-1")
def test_editor_documents_follow_a_pane_out_of_its_dissolving_tab(inst, win, tmp_path):
    """A tab's editor documents belong to the tab; when its last pane moves away the tab goes,
    and its documents go with the pane rather than vanishing."""
    doc = tmp_path / "carried.md"
    doc.write_text("# carried\n")
    pane = inst.cli("tab", "new", "--window", win["window"], "--no-focus").stdout.strip()
    inst.cli("edit", str(doc), "--pane", pane)
    inst.cli("pane", "move", pane, "--to", win["pane"], "--dir", "right", "--no-focus")
    docs = inst.json("editor", "ls", "--pane", pane)["documents"]
    assert any(os.path.realpath(d["path"]) == os.path.realpath(doc) for d in docs), docs


@pytest.mark.req("IA-1", "IA-3")
def test_an_agent_launched_into_a_new_window_gets_its_command(inst, win):
    """A new window that takes focus shows on the next turn of the run loop; the agent's command
    must still be typed into its pane, and the agent noted."""
    if not login_which("claude"):
        pytest.skip("claude is not on the login PATH")
    result = inst.json("claude", "--window", "--", "--version")
    inst.cli("wait", "--pane", result["pane"], "--pattern", r"\(Claude Code\)", "--timeout", "30")
    agent = inst.find_pane(result["pane"])[2].get("interactive_agent") or {}
    assert agent.get("kind") == "claude", agent
    inst.cli("window", "close", inst.find_pane(result["pane"])[0]["id"], check=False)


@pytest.mark.req("I-4")
def test_a_feed_whose_version_isnt_a_version_is_refused(fresh, tmp_path):
    """The feed's version isn't covered by the update's signature and names a folder on disk, so
    anything but a plain dotted number is refused before it's used."""
    root = tmp_path / "www"
    root.mkdir()
    (root / "appcast.json").write_text(json.dumps({
        "product": "Tern", "version": "99/../../victim", "url": "Tern-99.zip", "size": 1,
        "sha256": "00" * 32, "signature": "AAAA",
    }))
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        a = fresh(env={"TERN_FEED_URL": f"http://127.0.0.1:{server.server_address[1]}/appcast.json"})
        proc = a.cli("update", "--check", check=False)
        assert proc.returncode != 0, proc.stdout
        assert "version" in (proc.stderr + proc.stdout), proc.stderr
    finally:
        server.shutdown()



@pytest.mark.req("T-3")
def test_wait_sees_output_that_scrolled_past_the_screen(inst, win):
    """A marker followed by more output than the screen holds still matches, whether the wait
    started before the output or just after it scrolled away."""
    pane = win["pane"]
    marker = "EARLY-" + uuid.uuid4().hex[:6]
    waiter = subprocess.Popen([inst.target.cli_path, "wait", "--pane", pane, "--pattern", f"^{marker}$",
                               "--timeout", "20"], env=inst.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, stdin=subprocess.DEVNULL)
    time.sleep(0.5)
    inst.cli("send", "--pane", pane, "-e", f"echo {marker}; seq 1 3000")
    out, err = waiter.communicate(timeout=40)
    assert waiter.returncode == 0 and out.strip() == marker, err
    marker = "LATE-" + uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", pane, "-e", f"echo {marker}; seq 1 3000")
    time.sleep(1.5)
    assert inst.cli("wait", "--pane", pane, "--pattern", f"^{marker}$", "--timeout", "10").stdout.strip() == marker


@pytest.mark.req("T-3")
def test_idle_means_no_output_not_an_unchanged_screen(inst, win):
    """A program that keeps rewriting the same text is not idle."""
    pane = win["pane"]
    inst.cli("send", "--pane", pane, "-e", "while true; do printf '\\rSAME'; sleep 0.05; done")
    time.sleep(1)
    try:
        busy = inst.cli("wait", "--pane", pane, "--idle", "0.5", "--timeout", "3", check=False)
        assert busy.returncode == 124, busy.stdout + busy.stderr
    finally:
        inst.cli("keys", "--pane", pane, "ctrl+c")
    assert inst.cli("wait", "--pane", pane, "--idle", "0.5", "--timeout", "10", check=False).returncode == 0


@pytest.mark.req("T-2")
def test_shifted_keys_type_shifted_characters(inst, win):
    pane = win["pane"]
    inst.cli("send", "--pane", pane, "-e", "cat")
    time.sleep(0.8)
    try:
        inst.cli("keys", "--pane", pane, "shift+1", "shift+2", "shift+/", "shift+9", "enter")
        assert inst.cli("wait", "--pane", pane, "--pattern", r"^!@\?\($", "--timeout", "10").stdout.strip() == "!@?("
    finally:
        inst.cli("keys", "--pane", pane, "ctrl+c")


@pytest.mark.req("P-3")
def test_core_cli_actions_run_beside_the_running_app(inst):
    """Ghostty's `+action` commands (the shell integration's `+ssh` among them) run on their own
    even while the app runs for the same state directory; they don't hand over to it."""
    proc = subprocess.run([inst.target.executable, "+version"], env=inst.env, capture_output=True, text=True,
                          timeout=60, stdin=subprocess.DEVNULL)
    assert proc.returncode == 0 and "1." in proc.stdout, proc.stdout + proc.stderr
    assert inst.app_running()


@pytest.mark.req("P-1")
def test_ssh_integration_reaches_the_renamed_executable(target):
    """With ssh-env/ssh-terminfo on, the shell integration's `ssh` wrapper calls the app's core
    executable, which Tern renamed."""
    custom = Target(target.path, dict(target.data, launch_args=list(target.launch_args)
                                      + ["--shell-integration-features=ssh-env,ssh-terminfo"]))
    inst = Instance(custom, prefix="acc-ssh-")
    inst.start_app()
    try:
        pane = inst.json("window", "new")["pane"]
        wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20, message="prompt")
        time.sleep(1)
        inst.cli("send", "--pane", pane, "-e", "whence -w ssh; ssh -V; echo SSH-DONE")
        inst.cli("wait", "--pane", pane, "--pattern", "^SSH-DONE$", "--timeout", "20")
        screen = inst.cli("read", "--pane", pane, "--scrollback").stdout
        if "ssh: function" not in screen:
            pytest.skip("the login shell isn't zsh with Ghostty's shell integration")
        assert "OpenSSH" in screen and "no such file" not in screen.lower(), screen
    finally:
        inst.cleanup()


@pytest.mark.req("I-4")
@pytest.mark.slow
def test_update_now_relaunches_the_same_instance(target, tmp_path):
    """`update --now` quits, installs and relaunches; an instance with its own state directory
    comes back as that instance, not as the default one."""
    if not (target.release and target.installer and target.env_names.get("feed_url")):
        pytest.skip("the target file has no release command, installer or feed_url variable")
    from test_install import bundle_version, make_release, run_installer

    root = tmp_path / "www"
    root.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/"
    dest = str(tmp_path / "Applications" / os.path.basename(target.app))
    installed = None
    try:
        make_release(target, "0.0.1", root / "old", base + "old/")
        make_release(target, "999.0.0", root / "new", base + "new/")
        feed = {target.env_names["feed_url"]: base + "new/" + target.release["feed"]}
        holder = Instance(target, prefix="acc-now-", env=feed)
        proc = run_installer(target, str(root / "old" / target.release["app"]), dest, str(tmp_path / "bin"),
                             holder.env)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        installed = Instance(Target.from_installed(target, dest), state_dir=holder.dir, env=feed)
        installed.start_app()
        installed.cli("update", "--now", timeout=600)
        wait_until(lambda: bundle_version(dest) == "999.0.0", 180, message="the update installed")

        def relaunched():
            try:
                return installed.json("update", "--check", timeout=60)
            except (CLIError, subprocess.TimeoutExpired):
                return None

        after = wait_until(relaunched, 60, message="the same instance relaunched")
        assert (after["installed"], after["update_available"]) == ("999.0.0", False), after
    finally:
        subprocess.run(["pkill", "-TERM", "-f", f"{dest}/Contents/MacOS/"], capture_output=True)
        time.sleep(1)
        if installed:
            installed.cleanup()
        server.shutdown()


@pytest.mark.req("L-6", "IA-3")
def test_new_tabs_start_in_the_folder_of_the_pane_they_come_from(inst, win, tmp_path):
    """A tab made from a pane that isn't the one its window has focused starts in that pane's
    folder: from inside the pane, and for `tern claude --pane`."""
    a_dir = tmp_path / "repo-a"
    b_dir = tmp_path / "repo-b"
    a_dir.mkdir()
    b_dir.mkdir()
    a = pane_info(inst, inst.cli("split", "right", "--pane", win["pane"], "--cwd", str(a_dir)).stdout.strip())["id"]
    b = pane_info(inst, inst.cli("split", "down", "--pane", win["pane"], "--cwd", str(b_dir)).stdout.strip())["id"]
    wait_until(lambda: inst.cli("read", "--pane", a, check=False).stdout.strip() != "", 20, message="prompt")
    inst.cli("pane", "focus", b)
    out = tmp_path / "out.json"
    inst.cli("send", "--pane", a, "-e", f"'{inst.target.cli_path}' --json tab new --no-focus > '{out}'")
    wait_until(lambda: out.exists() and out.read_text().strip(), 20, message="the tab made from inside pane A")
    made = json.loads(out.read_text())["pane"]
    wait_until(lambda: os.path.realpath(pane_info(inst, made)["cwd"]) == os.path.realpath(a_dir), 15,
               message="the new tab in A's folder")
    if login_which("claude"):
        result = inst.json("claude", "--tab", "--pane", a, "--no-focus", "--", "--version")
        wait_until(lambda: os.path.realpath(pane_info(inst, result["pane"])["cwd"]) == os.path.realpath(a_dir), 15,
                   message="the agent's tab in A's folder")


@pytest.mark.req("L-3")
def test_focusing_another_pane_of_a_zoomed_tab_unzooms_it(inst, win):
    """The focused pane is always one on screen."""
    other = pane_info(inst, inst.cli("split", "right", "--pane", win["pane"]).stdout.strip())["id"]
    inst.cli("pane", "zoom", win["pane"])
    assert inst.find_pane(win["pane"])[1].get("zoomed_pane") == win["pane"]
    inst.cli("pane", "focus", other)
    tab = inst.find_pane(other)[1]
    assert tab.get("zoomed_pane") is None and tab["focused_pane"] == other, tab


@pytest.mark.req("L-6", "R-3")
def test_a_panes_folder_is_right_without_shell_integration(target, tmp_path):
    """Without shell integration the shell reports no folder: a pane's folder is its program's,
    starting at the configured working-directory and following `cd`."""
    start = tmp_path / "start"
    start.mkdir()
    custom = Target(target.path, dict(target.data, launch_args=list(target.launch_args)
                                      + ["--shell-integration=none", f"--working-directory={start}"]))
    inst = Instance(custom, prefix="acc-nosi-")
    inst.start_app()
    try:
        pane = inst.json("window", "new")["pane"]
        wait_until(lambda: os.path.realpath(pane_info(inst, pane)["cwd"] or "/") == os.path.realpath(start), 20,
                   message="the configured working directory")
        inst.cli("send", "--pane", pane, "-e", "cd /usr/bin")
        wait_until(lambda: pane_info(inst, pane)["cwd"] == "/usr/bin", 10, message="the folder after cd")
    finally:
        inst.cleanup()


@pytest.mark.req("I-1", "I-5")
@pytest.mark.slow
def test_the_installer_downloads_a_release_in_a_bare_shell(target, tmp_path):
    """The one-line install downloads from the release feed in a plain shell (minimal PATH),
    with a UTF-8 locale as Terminal sets (bash 3.2 then reads `$name…` as one longer variable
    name) and with none."""
    if not (target.release and target.installer):
        pytest.skip("the target file has no release command or installer")
    from test_install import bundle_version, make_release

    root = tmp_path / "www"
    root.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/"
    try:
        make_release(target, "0.0.7", root / "rel", base + "rel/")
        installer = root / "rel" / "install.sh"
        assert installer.exists(), "the release has no install.sh"
        dest = tmp_path / "Applications" / os.path.basename(target.app)
        names = target.installer["env"]
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               names["dest"]: str(dest), names["bin"]: str(tmp_path / "bin"), names["no_default"]: "1",
               names["no_launch"]: "1", "TERN_INSTALL_FEED": base + "rel/" + target.release["feed"]}
        for locale in ({"LANG": "en_US.UTF-8"}, {}):
            shutil.rmtree(dest, ignore_errors=True)
            proc = subprocess.run(["/bin/bash", "-c", f"cat '{installer}' | bash"], env={**env, **locale},
                                  capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
            assert proc.returncode == 0, f"{locale}: " + proc.stdout + proc.stderr
            assert bundle_version(str(dest)) == "0.0.7"
    finally:
        server.shutdown()


# ---- I-4: the update question --------------------------------------------------------------------
#
# A background check that finds a newer version asks; nothing is downloaded until the answer is
# yes. These install a release-stamped old build (0.0.1) and point it at a local feed whose
# contents the test switches. Checks run every 2 s in these instances (TERN_UPDATE_CHECK_SECONDS,
# honored only with an explicit state directory).

class _LoggingHandler(SimpleHTTPRequestHandler):
    log = None

    def do_GET(self):  # noqa: N802
        self.log.append(self.path)
        super().do_GET()

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def update_releases(target, tmp_path_factory):
    """An old (0.0.1) and a new (999.0.0) release behind a local web server that logs requests.
    Yields (root, base URL, request log)."""
    if not (target.release and target.installer and target.env_names.get("feed_url")):
        pytest.skip("the target file has no release command, installer or feed_url variable")
    from test_install import make_release

    root = tmp_path_factory.mktemp("update-releases")
    log = []
    handler = type("Handler", (_LoggingHandler,), {"log": log})
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(handler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/"
    make_release(target, "0.0.1", root / "old", base + "old/")
    make_release(target, "999.0.0", root / "new", base + "new/")
    (root / "feed").mkdir()
    yield root, base, log
    server.shutdown()


def _serve_feed(root, which):
    """Point the instance's feed at a version: "old" (up to date), "new" (999.0.0) or a newer
    999.1.0 whose download would fail (it must never be requested)."""
    if which in ("old", "new"):
        shutil.copy(root / which / "appcast.json", root / "feed" / "appcast.json")
    else:
        (root / "feed" / "appcast.json").write_text(json.dumps({
            "product": "Tern", "version": which, "url": f"never/Tern-{which}.zip", "size": 1,
            "sha256": "00" * 32, "signature": "AAAA"}))


def _install_old(target, update_releases, tmp_path, later_seconds=None):
    from test_install import bundle_version, run_installer

    root, base, _ = update_releases
    _serve_feed(root, "old")
    env = {target.env_names["feed_url"]: base + "feed/appcast.json", "TERN_UPDATE_CHECK_SECONDS": "2"}
    if later_seconds:
        env["TERN_UPDATE_LATER_SECONDS"] = str(later_seconds)
    holder = Instance(target, prefix="acc-ask-", env=env)
    dest = str(tmp_path / "Applications" / os.path.basename(target.app))
    proc = run_installer(target, str(root / "old" / target.release["app"]), dest, str(tmp_path / "bin"), holder.env)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert bundle_version(dest) == "0.0.1"
    return Instance(Target.from_installed(target, dest), state_dir=holder.dir, env=env), dest


def _update_status(inst):
    return inst.json("update", "--status")


def _zip_requests(log):
    return [p for p in log if p.endswith(".zip")]


def _uninstall(installed, dest):
    subprocess.run(["pkill", "-TERM", "-f", f"{dest}/Contents/MacOS/"], capture_output=True)
    time.sleep(1)
    installed.cleanup()


@pytest.mark.req("I-4", "L-8")
@pytest.mark.slow
def test_a_background_check_asks_and_downloads_nothing_until_yes(target, update_releases, tmp_path):
    """I-4: "when a background check finds a newer version, it asks the user before downloading or
    installing anything. The question never takes focus or blocks work, and it stays available
    until answered." Then `<cli> update` counts as a yes."""
    from test_install import bundle_version

    root, base, log = update_releases
    installed, dest = _install_old(target, update_releases, tmp_path)
    try:
        installed.start_app()
        pane = installed.json("window", "new")["pane"]
        wait_until(lambda: _update_status(installed)["state"] == "up_to_date", 30, message="a first check (up to date)")
        before = installed.json("ls")
        activate_finder()
        front = frontmost_pid()
        if front is None or front == installed.app_pid:
            pytest.skip("couldn't put another app in front")
        del log[:]
        _serve_feed(root, "new")
        status = wait_until(lambda: (s := _update_status(installed))["state"] == "asking" and s, 30,
                            message="the background check asks")
        assert status.get("question") == "999.0.0" and status["latest"] == "999.0.0", status
        # It took no focus: the app that was in front stays there, and the user's pane too.
        time.sleep(1)
        assert frontmost_pid() == front, "the question brought the app to the front"
        after = installed.json("ls")
        assert (after["current_tab"], after["current_pane"]) == (before["current_tab"], before["current_pane"])
        # Work goes on, and nothing is downloaded however many checks run.
        installed.cli("send", "--pane", pane, "-e", "echo still-working")
        installed.cli("wait", "--pane", pane, "--pattern", "^still-working$", "--timeout", "10")
        time.sleep(8)
        assert not _zip_requests(log), log
        assert _update_status(installed)["state"] == "asking"
        check = installed.json("update", "--check")
        assert (check["installed"], check["latest"], check["update_available"]) == ("0.0.1", "999.0.0", True), check
        assert not _zip_requests(log), "`update --check` downloaded something"

        # Unanswered, the question survives a restart, and a quit installs nothing.
        installed.quit_gracefully()
        time.sleep(3)
        assert bundle_version(dest) == "0.0.1", "an update installed without a yes"
        installed.start_app()
        wait_until(lambda: _update_status(installed)["state"] == "asking", 30, message="asked again after the restart")
        time.sleep(4)
        assert not _zip_requests(log), log

        # `<cli> update` is a yes.
        installed.cli("update", timeout=600)
        assert _zip_requests(log), "the yes downloaded nothing"
        status = _update_status(installed)
        assert status["state"] == "ready" and status.get("ready") == "999.0.0", status
    finally:
        _uninstall(installed, dest)


@pytest.mark.req("I-4")
@pytest.mark.slow
def test_later_asks_again_later_and_skip_waits_for_a_newer_version(target, update_releases, tmp_path):
    """What a "no" or "later" means for later checks: Later hides the question for a while (also
    across a restart), then it's asked again; Skip This Version never asks about that version again,
    but a newer one is asked about. Neither downloads anything."""
    root, base, log = update_releases
    installed, dest = _install_old(target, update_releases, tmp_path, later_seconds=25)
    try:
        installed.start_app()
        wait_until(lambda: _update_status(installed)["state"] == "up_to_date", 30, message="a first check")
        del log[:]
        _serve_feed(root, "new")
        wait_until(lambda: _update_status(installed)["state"] == "asking", 30, message="asked")

        later = installed.json("update", "--later")
        answered = time.time()
        assert later["state"] == "later" and "question" not in later and later.get("later_until"), later
        time.sleep(6)
        assert _update_status(installed)["state"] == "later", "asked again right after Later"
        installed.quit_gracefully()
        installed.start_app()
        wait_until(lambda: _update_status(installed)["state"] != "unknown", 30, message="a check after the restart")
        time.sleep(2)
        status = _update_status(installed)
        assert status["state"] == "later" and "question" not in status, f"a restart asked again early: {status}"
        wait_until(lambda: _update_status(installed)["state"] == "asking", 25 - (time.time() - answered) + 20,
                   message="asked again once Later's time was up")
        assert time.time() - answered >= 24, "asked again before Later's time was up"

        skip = installed.json("update", "--skip")
        assert skip["state"] == "skipped" and skip.get("skipped") == "999.0.0", skip
        time.sleep(6)
        assert _update_status(installed)["state"] == "skipped"
        installed.quit_gracefully()
        installed.start_app()
        wait_until(lambda: _update_status(installed)["state"] != "unknown", 30, message="a check after the restart")
        time.sleep(4)
        status = _update_status(installed)
        assert status["state"] == "skipped" and "question" not in status, f"a skipped version was asked about: {status}"

        _serve_feed(root, "999.1.0")
        status = wait_until(lambda: (s := _update_status(installed))["state"] == "asking" and s, 30,
                            message="a newer version is asked about")
        assert status["question"] == "999.1.0", status
        assert not _zip_requests(log), log
    finally:
        _uninstall(installed, dest)


@pytest.mark.req("I-4")
@pytest.mark.slow
def test_update_is_a_yes_even_after_skip_and_the_yes_outlives_a_restart(target, update_releases, tmp_path):
    """`<cli> update` counts as a yes, whatever was answered before. A yes is kept: after a
    restart the same version downloads again without asking (here the first download fails)."""
    root, base, log = update_releases
    installed, dest = _install_old(target, update_releases, tmp_path)
    try:
        installed.start_app()
        wait_until(lambda: _update_status(installed)["state"] == "up_to_date", 30, message="a first check")
        _serve_feed(root, "new")
        wait_until(lambda: _update_status(installed)["state"] == "asking", 30, message="asked")
        installed.json("update", "--skip")

        # The yes, with the download made to fail (the zip moved away for a moment).
        zip_path = root / "new" / "Tern-999.0.0.zip"
        hidden = root / "new" / "hidden.zip"
        zip_path.rename(hidden)
        try:
            proc = installed.cli("update", check=False, timeout=600)
            assert proc.returncode != 0, proc.stdout
            status = _update_status(installed)
            assert status["state"] == "failed" and status.get("consent") == "999.0.0", status
        finally:
            hidden.rename(zip_path)
        installed.quit_gracefully()
        del log[:]
        installed.start_app()
        status = wait_until(lambda: (s := _update_status(installed))["state"] == "ready" and s, 60,
                            message="the yes carried on after the restart, without asking")
        assert status["ready"] == "999.0.0" and len(_zip_requests(log)) == 1, (status, log)
    finally:
        _uninstall(installed, dest)


@pytest.mark.req("I-4", "P-2")
@pytest.mark.slow
def test_the_update_question_in_the_sidebar(target, update_releases, tmp_path, ui):
    """The question as a person sees it: a notice in the sidebar with Download, Later and Skip
    This Version (no dialog). Later takes it away; "Check for Updates…" is then a yes: it downloads,
    says so, and the notice offers to install the staged update."""
    from harness import UI

    root, base, log = update_releases
    installed, dest = _install_old(target, update_releases, tmp_path)
    try:
        installed.start_app()
        installed.json("window", "new")
        installed.cli("sidebar", "on")
        wait_until(lambda: _update_status(installed)["state"] == "up_to_date", 30, message="a first check")
        del log[:]
        _serve_feed(root, "new")
        wait_until(lambda: _update_status(installed)["state"] == "asking", 30, message="asked")
        view = UI(installed.app_pid)
        for label in ("Download", "Later", "Skip This Version"):
            wait_until(lambda: view.button(label), 10, message=f"the notice's {label} button")
        assert "999.0.0 is available" in view.all_text()
        assert not [w for w in view.windows() if view.attr(w, "AXSubrole") in ("AXDialog", "AXSystemDialog")], \
            "the question is a dialog"
        view.press(view.button("Later"))
        wait_until(lambda: _update_status(installed)["state"] == "later", 10, message="Later answered")
        wait_until(lambda: view.button("Download") is None, 10, message="the notice gone")

        view.choose(view.menu_item("Check for Updates"))
        ok = wait_until(lambda: view.button("OK"), 15, message="the menu item's dialog")
        assert "Downloading Tern 999.0.0" in view.all_text(), view.all_text()
        view.press(ok)
        wait_until(lambda: _update_status(installed)["state"] == "ready", 120, message="downloaded and staged")
        assert _zip_requests(log)
        wait_until(lambda: view.button("Install Now…"), 10, message="the notice offers to install")
    finally:
        _uninstall(installed, dest)
