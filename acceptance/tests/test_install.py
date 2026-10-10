"""Identity, single instance, installation and upgrades (SPEC P-1, P-3, I-1, I-2, R-8)."""

import os
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

import pytest

from harness import Instance, login_which, Target, wait_until

pytestmark = pytest.mark.install


@pytest.mark.req("P-1")
def test_identity_is_distinct(target):
    assert target.bundle_id and target.bundle_id not in target.other_products
    names = {n.lower() for n in target.other_names}
    assert target.cli_name.lower() not in names, f"CLI name {target.cli_name} collides"
    app_name = (target.info.get("CFBundleName") or "").lower()
    assert app_name and app_name not in names, f"app name {app_name} collides"
    assert os.path.basename(target.app).lower().removesuffix(".app") not in names


@pytest.mark.req("P-3")
def test_simultaneous_launches_leave_one_instance(fresh):
    other = fresh(prefix="acc-p3-", start_app=False)
    env = dict(other.env, PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    launch = [other.target.executable, *other.target.launch_args]
    procs = [subprocess.Popen(launch, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              start_new_session=True) for _ in range(2)]
    try:
        wait_until(lambda: sum(p.poll() is None for p in procs) == 1, 30, message="exactly one instance left")
        survivor = next(p for p in procs if p.poll() is None)
        wait_until(lambda: other.cli("ls", check=False, timeout=10).returncode == 0, 30, message="it serves the CLI")
        late = subprocess.Popen(launch, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        late.wait(30)
        assert survivor.poll() is None
        assert other.cli("ls", check=False, timeout=10).returncode == 0
    finally:
        for p in procs:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(15)
                except subprocess.TimeoutExpired:
                    p.kill()


def default_markdown_app():
    try:
        import CoreServices
        return CoreServices.LSCopyDefaultRoleHandlerForContentType("net.daringfireball.markdown", 0xFFFFFFFF)
    except Exception:  # noqa: BLE001
        return "unknown"


def run_installer(target, app, dest, bindir, env):
    names = target.installer["env"]
    full = {**env, names["dest"]: dest, names["bin"]: bindir, names["no_default"]: "1", names["no_launch"]: "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    command = target.subst(target.installer["command"], app=app)
    return subprocess.run(command, capture_output=True, text=True, env=full, timeout=300, stdin=subprocess.DEVNULL)


@pytest.mark.req("I-1")
def test_installer(target, fresh, tmp_path):
    if not target.installer:
        pytest.skip("the target file has no installer")
    other = fresh(prefix="acc-i1-", start_app=False)
    package = tmp_path / "package"
    package.mkdir()
    app_copy = str(package / os.path.basename(target.app))
    subprocess.run(["ditto", target.app, app_copy], check=True)
    subprocess.run(["xattr", "-w", "com.apple.quarantine", "0083;00000000;Safari;", app_copy], check=True)
    dest = str(tmp_path / "Applications" / os.path.basename(target.app))
    bindir = str(tmp_path / "bin")
    default_before = default_markdown_app()
    proc = run_installer(target, app_copy, dest, bindir, other.env)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    with open(os.path.join(dest, "Contents", "Info.plist"), "rb") as f:
        assert plistlib.load(f)["CFBundleIdentifier"] == target.bundle_id
    xattrs = subprocess.run(["xattr", "-r", dest], capture_output=True, text=True).stdout
    assert "com.apple.quarantine" not in xattrs, "the download quarantine is cleared"
    link = os.path.join(bindir, target.cli_name)
    assert os.path.exists(link)
    assert subprocess.run([link, "doctor"], env=other.env, capture_output=True, timeout=60).returncode in (0, 1)
    assert default_markdown_app() == default_before, "asked not to change the default Markdown app"




@pytest.mark.req("I-2")
def test_doctor(inst):
    proc = inst.cli("doctor", check=False)
    report = (proc.stdout + proc.stderr).lower()
    for tool in ("claude", "codex", "git"):
        assert tool in report, f"doctor says nothing about {tool}"
    everything = all(bool(login_which(t)) for t in ("claude", "codex", "git"))
    assert (proc.returncode == 0) == everything, report


@pytest.mark.req("AG-22")
@pytest.mark.slow
@pytest.mark.harness
def test_upgrading_keeps_sessions(target, tmp_path):
    if not target.installer:
        pytest.skip("the target file has no installer")
    dest = str(tmp_path / "Applications" / os.path.basename(target.app))
    bindir = str(tmp_path / "bin")
    from harness import Instance
    holder = Instance(target, prefix="acc-r8-")       # only for its state dir and environment
    installed = None
    try:
        proc = run_installer(target, target.app, dest, bindir, holder.env)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        installed = Instance(Target.from_installed(target, dest), state_dir=holder.dir)
        installed.start_app()
        word = "upgrade-" + os.urandom(4).hex()
        sid = installed.start_agent("codex", f"ECHO remember {word}")
        installed.wait(sid)
        installed.quit_app()
        proc = run_installer(target, target.app, dest, bindir, installed.env)   # the "new build"
        assert proc.returncode == 0, proc.stderr
        installed.start_app()
        assert sid in {s["id"] for s in installed.agents()}
        installed.send(sid, "RECALL")
        code, out = installed.wait(sid)
        assert out["status"] == "DONE" and word in out["reply"], out
    finally:
        (installed or holder).cleanup()
        time.sleep(0.5)
        shutil.rmtree(tmp_path, ignore_errors=True)


# ---- P-2, I-4: updates --------------------------------------------------------------------------

GHOSTTY_FEEDS = (b"release.files.ghostty.org", b"tip.files.ghostty.org")
GHOSTTY_UPDATE_KEY = b"wsNcGf5hirwtdXMVnYoxRIX/SqZQLMOsYlD3q3imeok="   # upstream Ghostty's update-signing key


@pytest.mark.req("P-2")
def test_never_offers_another_products_updates(target):
    """A cheap static check: the app neither points at upstream Ghostty's update feeds nor trusts
    updates signed with Ghostty's key."""
    contents = os.path.join(target.app, "Contents")
    files = [os.path.join(contents, "Info.plist")]
    macos = os.path.join(contents, "MacOS")
    files += [os.path.join(macos, f) for f in os.listdir(macos)]
    for path in files:
        with open(path, "rb") as f:
            data = f.read()
        for needle in (*GHOSTTY_FEEDS, GHOSTTY_UPDATE_KEY):
            assert needle not in data, f"{os.path.relpath(path, target.app)} contains {needle.decode()}"


def bundle_version(app):
    """The installed app's version, or None while there's no app at that path (an update swaps the
    bundle in two renames, so a poll can land between them)."""
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleShortVersionString")
    except FileNotFoundError:
        return None


@pytest.fixture
def web(tmp_path):
    """A local web server for release files: (folder, base URL)."""
    root = tmp_path / "www"
    root.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield root, f"http://127.0.0.1:{server.server_address[1]}/"
    server.shutdown()


def make_release(target, version, out, base_url):
    command = target.subst(target.release["command"], version=version, out=str(out), base_url=base_url)
    proc = subprocess.run(command, capture_output=True, text=True, timeout=1200, stdin=subprocess.DEVNULL)
    assert proc.returncode == 0, proc.stdout[-2000:] + proc.stderr[-2000:]
    assert os.path.exists(os.path.join(out, target.release["feed"])), "the release has a feed"


@pytest.mark.req("I-4")
@pytest.mark.slow
def test_an_older_build_updates_itself(target, web, tmp_path):
    if not (target.release and target.installer and target.env_names.get("feed_url")):
        pytest.skip("the target file has no release command, installer or feed_url variable")
    root, base = web
    make_release(target, "0.0.1", root / "old", base + "old/")
    make_release(target, "999.0.0", root / "new", base + "new/")
    feed = {target.env_names["feed_url"]: base + "new/" + target.release["feed"]}
    holder = Instance(target, prefix="acc-i4-", env=feed)   # its state dir and environment
    dest = str(tmp_path / "Applications" / os.path.basename(target.app))
    installed = None
    try:
        proc = run_installer(target, str(root / "old" / target.release["app"]), dest, str(tmp_path / "bin"),
                             holder.env)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert bundle_version(dest) == "0.0.1"
        installed = Instance(Target.from_installed(target, dest), state_dir=holder.dir, env=feed)
        installed.start_app()
        check = installed.json("update", "--check", timeout=120)
        assert (check["installed"], check["latest"], check["update_available"]) == ("0.0.1", "999.0.0", True), check

        # A program running in a terminal while the update downloads and waits.
        pane = installed.json("window", "new")["pane"]
        installed.cli("send", "--pane", pane, "-e", "i=0; while true; do i=$((i+1)); echo tick $i; sleep 1; done")
        installed.cli("update", timeout=600)
        pid = installed.app_pid
        time.sleep(15)
        assert installed.app_running() and installed.app_pid == pid, "the app was not quit to install"
        assert bundle_version(dest) == "0.0.1", "nothing is replaced while the app runs"
        ticks = installed.cli("read", "--pane", pane, "--lines", "3").stdout
        time.sleep(3)
        assert installed.cli("read", "--pane", pane, "--lines", "3").stdout != ticks, "the terminal kept running"

        installed.quit_gracefully()
        wait_until(lambda: bundle_version(dest) == "999.0.0", 180, message="the update installed on quit")
        installed.start_app()
        after = installed.json("update", "--check", timeout=120)
        assert (after["installed"], after["update_available"]) == ("999.0.0", False), after
    finally:
        (installed or holder).cleanup()
        time.sleep(0.5)
