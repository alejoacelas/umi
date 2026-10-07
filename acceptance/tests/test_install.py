"""Identity, single instance, installation and upgrades (SPEC P-1, P-3, I-1, I-2, R-8)."""

import os
import plistlib
import shutil
import subprocess
import tempfile
import time

import pytest

from harness import login_which, Target, wait_until

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


@pytest.mark.req("R-8")
@pytest.mark.slow
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
