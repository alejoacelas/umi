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


def pytest_configure(config):
    config._req_results = {}
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


@pytest.fixture(scope="session")
def ui(inst):
    if not UI.available():
        pytest.skip("this process has no Accessibility permission (System Settings → Privacy → Accessibility)")
    return UI(inst.app_pid)


def pytest_collection_modifyitems(config, items):
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


def pytest_sessionfinish(session, exitstatus):
    results = session.config._req_results
    spec = open(os.path.join(ROOT, "SPEC.md")).read()
    reqs = re.findall(r"\*\*([A-Z]+-\d+) \[([AW+]+)\]\*\*", spec)
    tiers = spec_priorities(spec)
    lines = ["# Requirement traceability", "",
             "| Requirement | Tier | Kind | Status | Tests |", "|---|---|---|---|---|"]
    for req, kind in reqs:
        tests = results.get(req, [])
        if tests:
            statuses = {s for _, s in tests}
            status = ("FAIL" if statuses & {"failed", "error"} else
                      "pass" if "passed" in statuses else "skipped")
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
