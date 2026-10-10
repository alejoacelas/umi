"""Prepare the written checks of CHECKS.md and collect evidence for them.

    uv run python checks/run_checks.py --target targets/<name>.json [--only S-1,E-1]

Launches isolated instances (fake agents), sets up each check, and saves screenshots and text to
results/checks/. Writes results/checks/REPORT.md: one section per check with its criteria (copied
from CHECKS.md), its evidence and an empty verdict line for the judge.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))

from harness import UI, Instance, Target, wait_until  # noqa: E402


def screen_locked():
    """True while the screen is locked: the accessibility tree is then unusable (see conftest.py)."""
    try:
        import Quartz
        return bool((Quartz.CGSessionCopyCurrentDictionary() or {}).get("CGSSessionScreenIsLocked", False))
    except Exception:  # noqa: BLE001
        return False

OUT = os.path.join(ROOT, "results", "checks")


def criteria():
    """{check id: its text in CHECKS.md}"""
    text = open(os.path.join(ROOT, "CHECKS.md")).read()
    found = {}
    for block in re.split(r"\n(?=\*\*[A-Z]+-\d+(?:, [A-Z]+-\d+)*: )", text):
        m = re.match(r"\*\*([A-Z]+-\d+(?:, [A-Z]+-\d+)*): ", block)
        if m:
            found[m.group(1)] = block.split("\n## ")[0].strip()
    return found


def screenshot(inst, window, name):
    """Evidence image of one window: the product's own screenshot command, else screencapture."""
    path = os.path.join(OUT, f"{name}.png")
    proc = inst.cli("screenshot", "--window", window, path, check=False, timeout=30)
    if proc.returncode == 0 and os.path.exists(path):
        return path, None
    note = f"`screenshot` failed ({proc.stderr.strip()[:120]}); fell back to screencapture"
    try:
        import Quartz
        inst.cli("window", "focus", window, check=False)
        time.sleep(0.6)
        infos = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
        mine = [w for w in infos if w.get("kCGWindowOwnerPID") == inst.app_pid and w.get("kCGWindowLayer") == 0]
        if not mine:
            return None, note + "; no on-screen window"
        wid = mine[0]["kCGWindowNumber"]
        subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), path], check=True, timeout=30)
        return path, note
    except Exception as e:  # noqa: BLE001
        return None, f"{note}; that failed too: {e}"


def run(inst, pane, text, marker=None, timeout=15):
    inst.cli("send", "--pane", pane, "-e", text)
    if marker:
        inst.cli("wait", "--pane", pane, "--pattern", marker, "--timeout", str(timeout), check=False)


def git_repo(base, name, branch):
    repo = os.path.join(base, name)
    subprocess.run(["git", "init", "-q", "-b", branch, repo], check=True)
    subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty",
                    "-m", "init"], check=True)
    return repo


MARKDOWN = """# Rendering check

Some *emphasis*, **strong**, `inline code` and a [relative link](other.md) and an [anchor](#tables).

## Lists

- one
  - nested
- [x] done task
- [ ] open task

## Tables

| Name | Value |
|------|-------|
| a    | 1     |

```python
def hello():
    return "code block"
```

![local image](img/dot.png)

[![badge](https://img.shields.io/badge/check-ok-green)](https://example.com)

<p>Inline HTML with an image: <img src="img/dot.png" alt="dot" width="24"></p>

## Tables

Repeated heading above.

<script>document.body.innerHTML = "SCRIPT RAN";</script>
"""

def png_dot(size=16, rgb=(220, 60, 60)):
    """A small solid-color PNG, written by hand (no imaging library needed)."""
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


# ---- setups ------------------------------------------------------------------------------------
# Each returns a list of (label, evidence path or text, note).

def setup_layout(inst, base):
    w = inst.json("window", "new", "--name", "check-main")
    repo = git_repo(base, "project", "feature-branch")
    inst.cli("sidebar", "on")
    inst.cli("sidebar", "tabs")
    named = inst.cli("tab", "new", "--window", w["window"], "--name", "named tab", "--cwd", repo).stdout.strip()
    wt = inst.cli("tab", "new", "--window", w["window"], "--cwd", repo, "--worktree", "check-wt").stdout.strip()
    split = inst.cli("tab", "new", "--window", w["window"], "--cwd", repo).stdout.strip()
    inst.cli("split", "right", "--pane", split)
    inst.cli("split", "down", "--pane", split)
    pinned = inst.cli("tab", "new", "--window", w["window"], "--cwd", base).stdout.strip()
    inst.cli("tab", "pin", inst.json("pane", "info", pinned)["tab"])
    for pane in (w["pane"], named, wt, split):
        run(inst, pane, "ls -la | head -5")
    run(inst, pinned, "true")
    run(inst, named, "echo hi")
    agent = None
    if PHASE != "1":
        agent = inst.json("agent", "start", "claude", "--cwd", repo, "--env", "FAKE_AGENT_DIR=" + inst.fake_dir,
                          "--tab", "--window", w["window"], "SLEEP 600")["session"]["id"]
    inst.cli("tab", "focus", inst.json("pane", "info", split)["tab"])
    time.sleep(1.5)
    shot, note = screenshot(inst, w["window"], "S-1-S-3-S-6-window")
    inst.cli("sidebar", "files")
    time.sleep(1)
    files, note2 = screenshot(inst, w["window"], "S-2-files-mode")
    inst.cli("sidebar", "tabs")
    if agent:
        inst.cli("agent", "stop", agent, check=False)
    return {"S-1": [("window", shot, note)], "S-3": [("window", shot, note)], "S-6": [("window", shot, note)],
            "S-2": [("tabs mode", shot, note), ("files mode", files, note2)]}


def setup_editor(inst, base):
    folder = os.path.join(base, "docs")
    os.makedirs(os.path.join(folder, "img"))
    with open(os.path.join(folder, "img", "dot.png"), "wb") as f:
        f.write(png_dot())
    with open(os.path.join(folder, "README.md"), "w") as f:
        f.write(MARKDOWN)
    with open(os.path.join(folder, "other.md"), "w") as f:
        f.write("# Other file\n")
    with open(os.path.join(folder, "notes.txt"), "w") as f:
        f.write("plain text notes\n")
    w = inst.json("window", "new", "--name", "check-editor", "--cwd", folder)
    inst.cli("edit", os.path.join(folder, "notes.txt"), os.path.join(folder, "README.md"), "--pane", w["pane"])
    time.sleep(2)
    preview, n1 = screenshot(inst, w["window"], "E-1-preview")
    inst.cli("editor", "mode", "source", "--pane", w["pane"], check=False)
    time.sleep(1)
    source, n2 = screenshot(inst, w["window"], "E-2-source")
    inst.cli("editor", "mode", "preview", "--pane", w["pane"], check=False)
    # E-4: modify in the editor, then on disk.
    ui = UI(inst.app_pid) if UI.available() and not screen_locked() else None
    e4 = []
    if ui:
        inst.cli("edit", os.path.join(folder, "notes.txt"), "--pane", w["pane"])
        area = ui.text_area("plain text notes")
        if area is not None and ui.editable(area):
            ui.enter_text(" (edited, unsaved)", element=area)
            time.sleep(0.5)
            with open(os.path.join(folder, "notes.txt"), "w") as f:
                f.write("changed on disk while edited\n")
            time.sleep(2)
            e4.append(("modified + disk change", *screenshot(inst, w["window"], "E-4-disk-changed")))
    if not e4:
        e4.append(("modified + disk change", None, "could not edit through accessibility; do it by hand"))
    return {"E-1": [("preview", preview, n1)], "E-2": [("preview", preview, n1), ("source", source, n2)],
            "E-7": [("preview", preview, n1)], "E-4": e4}


def setup_agents(inst, base):
    w = inst.json("window", "new", "--name", "check-agents", "--cwd", base)
    sid = inst.json("agent", "start", "claude", "--cwd", base, "--env", "FAKE_AGENT_DIR=" + inst.fake_dir,
                    "--env", "CLAUDE_CONFIG_DIR=" + os.path.join(inst.fake_dir, "claude-config"),
                    "RUN printf '# Heading\\n\\n- item **bold**\\n\\n```sh\\necho code\\n```\\n'")["session"]["id"]
    inst.wait(sid)
    inst.json("agent", "open", sid, "--split", "right", "--pane", w["pane"])
    inst.send(sid, "ASK_PERMISSION")
    inst.wait(sid)
    time.sleep(1.5)
    approval, n1 = screenshot(inst, w["window"], "AG-5-approval")
    inst.cli("agent", "approve", sid, check=False)
    inst.wait(sid)
    time.sleep(1.5)
    done, n2 = screenshot(inst, w["window"], "AG-5-finished")
    transcript = "\n".join(f"{i['kind']}: {i['text'][:100]}" for i in inst.transcript(sid))
    inst.cli("agent", "stop", sid, check=False)
    return {"AG-5": [("pending approval", approval, n1), ("finished", done, n2), ("transcript from the CLI", transcript, None)]}


def setup_theme(target, base):
    shots = []
    for name, theme in (("light", "background = #fafafa\nforeground = #202020\n"),
                        ("dark", "background = #101014\nforeground = #e0e0e0\n")):
        config = os.path.join(base, f"xdg-{name}", "ghostty")
        os.makedirs(config)
        with open(os.path.join(config, "config"), "w") as f:
            f.write(theme)
        inst = Instance(target, prefix=f"acc-check-{name}-", env={"XDG_CONFIG_HOME": os.path.dirname(config)})
        try:
            inst.start_app()
            w = inst.json("window", "new", "--name", f"theme-{name}")
            inst.cli("tab", "new", "--window", w["window"], "--name", "second tab")
            time.sleep(1.5)
            shots.append((f"{name} config", *screenshot(inst, w["window"], f"S-5-{name}")))
        finally:
            inst.cleanup()
    return {"S-5": shots}


SETUPS = [setup_layout, setup_editor, setup_agents]
PHASE = "all"
PHASE_TWO_CHECKS = ("AG-",)   # SPEC.md, Delivery phases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--only", default="")
    parser.add_argument("--phase", default="all", choices=["1", "all"],
                        help="1: phase 1 (the app); checks of managed agents are deferred")
    args = parser.parse_args()
    global PHASE
    PHASE = args.phase
    target = Target(args.target)
    os.makedirs(OUT, exist_ok=True)
    texts = criteria()
    evidence = {}
    base = os.path.realpath(tempfile.mkdtemp(prefix="acc-checks-"))
    inst = Instance(target, prefix="acc-checks-")
    try:
        inst.start_app()
        for setup in SETUPS:
            if PHASE == "1" and setup is setup_agents:
                continue
            try:
                evidence.update(setup(inst, base))
            except Exception:  # noqa: BLE001
                evidence.setdefault("_errors", []).append((setup.__name__, traceback.format_exc(), None))
    finally:
        inst.cleanup()
    try:
        evidence.update(setup_theme(target, base))
    except Exception:  # noqa: BLE001
        evidence.setdefault("_errors", []).append(("setup_theme", traceback.format_exc(), None))

    only = {x for x in args.only.split(",") if x}
    lines = [f"# Written checks: {target.name}", "",
             f"Build: `{target.app}`. Generated {time.strftime('%Y-%m-%d %H:%M')}. "
             "Judge each check against its criteria; write PASS, FAIL: … or NOT JUDGED: … on its verdict line.", ""]
    for check, text in texts.items():
        if only and check not in only:
            continue
        if PHASE == "1" and check.startswith(PHASE_TWO_CHECKS):
            lines += [f"## {check}", "", "Deferred to phase 2 (managed agents).", ""]
            continue
        lines += [f"## {check}", "", text, "", "**Evidence:**", ""]
        items = evidence.get(check, [])
        if not items:
            lines.append("- none collected: judge by hand on a running instance")
        for label, item, note in items:
            if item and isinstance(item, str) and item.endswith(".png") and os.path.exists(item):
                lines.append(f"- {label}: ![{label}]({os.path.relpath(item, OUT)})")
            elif item and isinstance(item, str) and not item.endswith(".png"):
                lines += [f"- {label}:", "", "```", item[:4000], "```"]
            else:
                lines.append(f"- {label}: (missing)")
            if note:
                lines.append(f"  - note: {note}")
        lines += ["", "**Verdict:** ", ""]
    for name, trace, _ in evidence.get("_errors", []):
        lines += [f"## Setup error in {name}", "", "```", trace[-3000:], "```", ""]
    with open(os.path.join(OUT, "REPORT.md"), "w") as f:
        f.write("\n".join(lines))
    print(os.path.join(OUT, "REPORT.md"))


if __name__ == "__main__":
    main()
