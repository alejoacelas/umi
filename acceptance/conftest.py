import os
import re
import sys
import time

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tests"))
from harness import ROOT, Instance, Target, UI, wait_until  # noqa: E402


def pytest_addoption(parser):
    parser.addoption("--target", default=os.environ.get("ACCEPTANCE_TARGET"),
                     help="target file (targets/<name>.json); or set ACCEPTANCE_TARGET")
    parser.addoption("--req", default=None, help="comma-separated requirement ids: run only their tests")
    parser.addoption("--phase", default=os.environ.get("ACCEPTANCE_PHASE", "all"), choices=["1", "all"],
                     help="1: phase 1 (the app), leaving out tests that need managed agents (SPEC, Delivery "
                          "phases); all: everything (default)")


def pytest_configure(config):
    config._req_results = {}
    config._deferred = set()
    config._partial = bool(config.args and [a for a in config.args if a.rstrip("/") not in ("tests", ".")])


def pytest_deselected(items):
    if items:
        items[0].config._partial = True


@pytest.fixture(scope="session")
def target(request):
    path = request.config.getoption("--target")
    if not path:
        pytest.exit("pass --target targets/<name>.json (or set ACCEPTANCE_TARGET)", returncode=4)
    return Target(path)


@pytest.fixture(scope="session")
def inst(target):
    """One isolated instance with the app running, shared by most tests."""
    instance = Instance(target, prefix="acc-main-")
    instance.start_app()
    yield instance
    instance.cleanup()


@pytest.fixture
def fresh(target):
    """Make extra isolated instances (cleaned up after the test)."""
    made = []

    def make(start_app=True, **kwargs):
        instance = Instance(target, **kwargs)
        made.append(instance)
        if start_app:
            instance.start_app()
        return instance

    yield make
    for instance in made:
        instance.cleanup()


@pytest.fixture
def win(inst, request):
    """A fresh window for the test; every window the test creates is closed afterwards."""
    before = {w["id"] for w in inst.tree()["windows"]}
    created = inst.json("window", "new", "--name", "t-" + request.node.name[:40])
    pane = created["pane"]
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20,
               message="the shell prompt")
    time.sleep(0.3)
    found = inst.find_pane(pane)
    info = {"pane": found[2]["id"], "tab": found[1]["id"], "window": found[0]["id"]}
    yield info
    for w in inst.tree()["windows"]:
        if w["id"] not in before:
            inst.cli("window", "close", w["id"], check=False)
    time.sleep(0.2)


@pytest.fixture(scope="session", autouse=True)
def users_agent_folders():
    """Real-agent tests run the user's own Claude Code and Codex: leave ~/.claude, ~/.claude.json and
    ~/.codex as the suite found them (tests/agent_config.py). What was removed goes to
    results/agent-folders-cleanup.txt."""
    if not os.environ.get("ACCEPTANCE_REAL"):
        yield
        return
    from agent_config import Snapshot
    snapshot = Snapshot().take()
    yield
    removed = snapshot.clean()
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    with open(os.path.join(ROOT, "results", "agent-folders-cleanup.txt"), "w") as f:
        f.write("\n".join(removed) + ("\n" if removed else ""))


def screen_locked():
    """True while the login session's screen is locked. macOS then resolves every window's
    accessibility element to the application itself, so UI tests can't see anything (and a
    tree walk loops through the menu bar forever)."""
    try:
        import Quartz
        session = Quartz.CGSessionCopyCurrentDictionary() or {}
        return bool(session.get("CGSSessionScreenIsLocked", False))
    except Exception:  # noqa: BLE001
        return False


@pytest.fixture(scope="session")
def ui(inst):
    if not UI.available():
        pytest.skip("this process has no Accessibility permission (System Settings → Privacy → Accessibility)")
    if screen_locked():
        pytest.skip("the screen is locked, so the accessibility tree is unavailable (unlock it to run UI tests)")
    return UI(inst.app_pid)


def pytest_collection_modifyitems(config, items):
    if config.getoption("--phase") == "1":
        # Phase 1 leaves out tests that need managed agents. Not a "partial" run: the report is the
        # phase's full report, with those requirements marked deferred.
        kept = [item for item in items if not item.get_closest_marker("harness")]
        for item in items:
            if item.get_closest_marker("harness"):
                config._deferred.update(r for m in item.iter_markers("req") for r in m.args)
        items[:] = kept
    wanted = config.getoption("--req")
    if wanted:
        ids = {r.strip() for r in wanted.split(",") if r.strip()}
        keep, drop = [], []
        for item in items:
            reqs = {r for m in item.iter_markers("req") for r in m.args}
            (keep if reqs & ids else drop).append(item)
        if drop:
            config.hook.pytest_deselected(items=drop)
        items[:] = keep
    real = os.environ.get("ACCEPTANCE_REAL")
    for item in items:
        if "ui" in getattr(item, "fixturenames", ()):
            item.add_marker(pytest.mark.ui)
        if item.get_closest_marker("real") and not real:
            item.add_marker(pytest.mark.skip(reason="set ACCEPTANCE_REAL=1 to run real Claude Code / Codex"))


# --- requirement traceability -------------------------------------------------------------------

@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    reqs = []
    for mark in item.iter_markers("req"):
        reqs.extend(mark.args)
    if not reqs:
        return
    results = item.config._req_results
    status = None
    if report.when == "call":
        status = "passed" if report.passed else ("skipped" if report.skipped else "failed")
    elif report.when == "setup" and (report.failed or report.skipped):
        status = "skipped" if report.skipped else "error"
    if status:
        for req in reqs:
            results.setdefault(req, []).append((item.nodeid, status))


def spec_priorities(spec):
    """{requirement id: tier} from the "Requirements: …" lines of SPEC.md's Priorities section."""
    tiers = {}
    section = spec.split("## Priorities", 1)[1].split("\n## ", 1)[0]
    for block in section.split("\n### ")[1:]:
        tier = block.split(":", 1)[0].split("\n", 1)[0].strip()
        match = re.search(r"Requirements: (.+?)\.\n", block, re.S)
        if not match:
            continue
        for part in re.split(r",\s*", match.group(1).replace("\n", " ")):
            rng = re.match(r"([A-Z]+)-(\d+) to [A-Z]+-(\d+)", part.strip())
            if rng:
                for n in range(int(rng.group(2)), int(rng.group(3)) + 1):
                    tiers[f"{rng.group(1)}-{n}"] = tier
            elif part.strip():
                tiers[part.strip()] = tier
    return tiers


def phase_two(spec):
    """Requirement ids listed on SPEC.md's "Phase 2 requirements: …" line."""
    match = re.search(r"Phase 2 requirements: (.+?)\.\n", spec, re.S)
    ids = set()
    for part in re.split(r",\s*", match.group(1).replace("\n", " ")) if match else []:
        rng = re.match(r"([A-Z]+)-(\d+) to [A-Z]+-(\d+)", part.strip())
        if rng:
            ids.update(f"{rng.group(1)}-{n}" for n in range(int(rng.group(2)), int(rng.group(3)) + 1))
        elif part.strip():
            ids.add(part.strip())
    return ids


def pytest_sessionfinish(session, exitstatus):
    results = session.config._req_results
    spec = open(os.path.join(ROOT, "SPEC.md")).read()
    reqs = re.findall(r"\*\*([A-Z]+-\d+) \[([AW+]+)\]\*\*", spec)
    tiers = spec_priorities(spec)
    phase1 = session.config.getoption("--phase") == "1"
    deferred = (session.config._deferred | phase_two(spec)) if phase1 else set()
    lines = ["# Requirement traceability" + (" (phase 1)" if phase1 else ""), "",
             "| Requirement | Tier | Kind | Status | Tests |", "|---|---|---|---|---|"]
    for req, kind in reqs:
        tests = results.get(req, [])
        if tests:
            statuses = {s for _, s in tests}
            status = ("FAIL" if statuses & {"failed", "error"} else
                      "pass" if "passed" in statuses else "skipped")
        elif req in deferred:
            status = "deferred (phase 2)"
        else:
            status = "written check" if kind == "W" else ("not run" if "A" in kind else "")
        names = ", ".join(sorted({t.split("::")[-1] for t, _ in tests}))
        lines.append(f"| {req} | {tiers.get(req, '?')} | {kind} | {status} | {names} |")
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    # Only a full run rewrites the report; a selective run (-k, -m, --req, paths) gets its own file.
    name = "traceability-partial.md" if session.config._partial else "traceability.md"
    if session.config._partial:
        lines[0] += " (partial run: only the selected tests ran)"
    with open(os.path.join(ROOT, "results", name), "w") as f:
        f.write("\n".join(lines) + "\n")
