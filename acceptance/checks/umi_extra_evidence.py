"""Extra evidence for the written checks (Umi, phase 1), where run_checks.py's setup can't show a
criterion: Files mode on a repository with nested folders (S-2), Markdown images and the E-7 page
rules (E-1, E-7), and the "changed on disk" notice on an edited document (E-4, which run_checks
only reaches through the accessibility tree). After phase 2: the update question in the sidebar
(I-4, P-2), on an installed release-stamped old build pointed at a local feed.

    uv run python checks/umi_extra_evidence.py [--only update]

Writes results/checks/extra-*.png. Uses an isolated instance and Umi's `screenshot` command.
"""

import os
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "results", "checks")
sys.path.insert(0, os.path.join(HERE, "..", "tests"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "app", "macos", "UmiTests"))

from harness import Instance, Target, wait_until  # noqa: E402
from verify_ui_paths import Control  # noqa: E402

MARKDOWN = """# Images and page rules

A local image: ![dot](img/dot.png)

A remote badge inside a link: [![badge](https://img.shields.io/badge/umi-0.1-blue)](https://example.com)

A raw HTML image: <img src="img/dot.png" width="40" alt="raw">

## Tables

| a | b |
|---|---|
| 1 | 2 |

## Tables

The same heading again: its anchor is `tables-1`.

<script>document.body.innerHTML = "SCRIPT RAN";</script>
"""


def png(color=(0, 170, 200), size=24):
    row = b"\x00" + bytes(color) * size
    raw = row * size

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def shot(inst, window, name):
    path = os.path.join(OUT, f"extra-{name}.png")
    inst.cli("screenshot", "--window", window, path)
    print(path)


def main():
    inst = Instance(Target(os.path.join(HERE, "..", "targets", "umi.json")), prefix="acc-extra-")
    inst.start_app()
    base = os.path.realpath(tempfile.mkdtemp(prefix="umi-evidence-"))
    try:
        ctl = Control(inst)

        # S-2: Files mode on a repository with nested folders.
        repo = os.path.join(base, "sample-repo")
        for rel, text in {"src/app/main.swift": "print(1)\n", "src/app/views/Sidebar.swift": "\n",
                          "docs/guide.md": "# Guide\n", "tests/test_main.py": "\n", "README.md": "# Sample\n"}.items():
            os.makedirs(os.path.dirname(os.path.join(repo, rel)), exist_ok=True)
            with open(os.path.join(repo, rel), "w") as f:
                f.write(text)
        subprocess.run(["git", "init", "-q", repo], check=True)
        w = inst.json("window", "new", "--name", "files", "--cwd", repo)
        wait_until(lambda: inst.cli("read", "--pane", w["pane"], check=False).stdout.strip() != "", 20)
        inst.cli("sidebar", "files")
        time.sleep(1.5)
        shot(inst, w["window"], "S-2-files-nested")
        inst.cli("sidebar", "tabs")
        inst.cli("window", "close", w["window"], check=False)

        # E-1 / E-7: images, repeated headings, a script that must not run.
        docs = os.path.join(base, "docs")
        os.makedirs(os.path.join(docs, "img"))
        with open(os.path.join(docs, "img", "dot.png"), "wb") as f:
            f.write(png())
        page = os.path.join(docs, "images.md")
        with open(page, "w") as f:
            f.write(MARKDOWN)
        w = inst.json("window", "new", "--name", "markdown", "--cwd", docs)
        inst.cli("edit", page, "--pane", w["pane"])
        time.sleep(4)
        shot(inst, w["window"], "E-1-E-7-images")

        # E-4: an edited document whose file changes on disk.
        notes = os.path.join(docs, "notes.txt")
        with open(notes, "w") as f:
            f.write("plain text notes\n")
        inst.cli("edit", notes, "--pane", w["pane"])
        ctl.call("debug.editor.type", pane=w["pane"], path=notes, text=" (edited, unsaved)")
        time.sleep(0.5)
        with open(notes, "w") as f:
            f.write("changed on disk while edited\n")
        wait_until(lambda: ctl.call("debug.editor.type", pane=w["pane"], path=notes)["changed_on_disk"], 10,
                   message="the disk change")
        time.sleep(1)
        shot(inst, w["window"], "E-4-disk-changed")
    finally:
        inst.cleanup()


def agents_and_ui_evidence():
    """After the agent-sessions run: sidebar rows with agent marks and their order (S-3, S-7), a
    wider sidebar (S-8), the palettes (L-14, L-15, L-16), and a session live in one pane next to
    another's read-only view (AG-5, AG-6)."""
    inst = Instance(Target(os.path.join(HERE, "..", "targets", "umi.json")), prefix="acc-extra-ui-")
    inst.start_app()
    base = os.path.realpath(tempfile.mkdtemp(prefix="umi-evidence-ui-"))
    try:
        ctl = Control(inst)
        repo = os.path.join(base, "web-app")
        os.makedirs(os.path.join(repo, "src"))
        for rel in ("README.md", "src/server.py", "src/routes.py", "notes.md"):
            with open(os.path.join(repo, rel), "w") as f:
                f.write("# " + rel + "\n")
        subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
        subprocess.run(["git", "-C", repo, "add", "."], check=True)
        subprocess.run(["git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], check=True)
        w = inst.json("window", "new", "--name", "evidence", "--cwd", repo)
        wait_until(lambda: inst.cli("read", "--pane", w["pane"], check=False).stdout.strip() != "", 20)
        inst.cli("tab", "pin", w["tab"])
        inst.cli("send", "--pane", w["pane"], "-e", "git log --oneline | head -3")
        env = ["--env", "FAKE_AGENT_DIR=" + inst.fake_dir, "--env", "CLAUDE_CONFIG_DIR=" + inst.claude_config]
        done = inst.json("agent", "start", "claude", "--cwd", repo, *env, "--name", "fix-login-test",
                         "--tab", "--window", w["window"], "ECHO fixed the login test")["session"]["id"]
        asks = inst.json("agent", "start", "claude", "--cwd", repo, *env, "--name", "add-rate-limits",
                         "--tab", "--window", w["window"], "ASK_PERMISSION")["session"]["id"]
        busy = inst.json("agent", "start", "codex", "--cwd", repo, *env, "--name", "review-api",
                         "--tab", "--window", w["window"], "--full-access", "SLEEP 60")["session"]["id"]
        inst.json("tab", "new", "--window", w["window"], "--cwd", base, "--no-focus")
        inst.cli("tab", "focus", w["tab"])
        inst.wait(done)
        inst.wait(asks)
        time.sleep(3)
        shot(inst, w["window"], "S-3-S-7-agent-rows")
        inst.cli("sidebar", "width", "340", "--window", w["window"])
        time.sleep(1)
        shot(inst, w["window"], "S-8-wider-sidebar")
        inst.cli("sidebar", "width", "252", "--window", w["window"])
        inst.cli("window", "focus", w["window"])
        for title, name, mode in (("Command Palette…", "L-14-command-palette", "commands"),
                                  ("Go to Pane…", "L-15-pane-palette", "panes"),
                                  ("Open Quickly…", "L-16-quick-open", "files")):
            try:
                ctl.call("debug.menu.perform", title=title)
                time.sleep(1.5)
                state = ctl.call("debug.palette", window=w["window"], mode=mode)
                print(name, "presented:", state.get("presented"), "entries:", len(state.get("entries", [])))
                shot(inst, w["window"], name)
            except Exception as e:  # noqa: BLE001
                print("couldn't open", title, e)
            try:
                ctl.call("debug.palette.close", window=w["window"])
            except Exception:  # noqa: BLE001
                pass
            time.sleep(0.5)
        # L-14 again, typed into: the CLI's own entries, each with its `umi …` line.
        try:
            state = ctl.call("debug.palette", window=w["window"], mode="commands", query="agent")
            print("L-14-command-palette-cli entries:", [e.get("title") for e in state.get("entries", [])][:8])
            time.sleep(1)
            shot(inst, w["window"], "L-14-command-palette-cli")
            ctl.call("debug.palette.close", window=w["window"])
        except Exception as e:  # noqa: BLE001
            print("couldn't type into the command palette", e)
        # AG-5 / AG-6: one session live in a pane, another read-only beside it.
        lw = inst.json("window", "new", "--name", "live-and-read-only", "--cwd", repo)
        wait_until(lambda: inst.cli("read", "--pane", lw["pane"], check=False).stdout.strip() != "", 20)
        # Out of their tabs first (a session already shown would just be focused there).
        inst.cli("agent", "hide", done, check=False)
        inst.cli("agent", "hide", asks, check=False)
        time.sleep(1)
        inst.json("agent", "open", done, "--split", "right", "--pane", lw["pane"])
        live_pane = inst.json("agent", "open", asks, "--split", "down", "--pane", lw["pane"], "--live")["pane"]
        wait_until(lambda: inst.json("agent", "info", asks)["location"] == "live", 30, message="live")
        time.sleep(3)
        shot(inst, lw["window"], "AG-5-AG-6-live-and-read-only")
        for sid in (done, asks, busy):
            inst.cli("agent", "stop", sid, check=False)
    finally:
        inst.cleanup()


def update_evidence():
    """I-4: the question a background check raises (nothing downloaded), then the staged update."""
    import shutil
    import threading
    from functools import partial
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    from test_install import make_release, run_installer

    target = Target(os.path.join(HERE, "..", "targets", "umi.json"))
    base = os.path.realpath(tempfile.mkdtemp(prefix="umi-evidence-update-"))
    root = os.path.join(base, "www")
    os.makedirs(os.path.join(root, "feed"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=root))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    make_release(target, "0.0.1", os.path.join(root, "old"), url + "old/")
    make_release(target, "999.0.0", os.path.join(root, "new"), url + "new/")
    shutil.copy(os.path.join(root, "new", "appcast.json"), os.path.join(root, "feed", "appcast.json"))
    env = {"UMI_FEED_URL": url + "feed/appcast.json", "UMI_UPDATE_CHECK_SECONDS": "2"}
    holder = Instance(target, prefix="acc-extra-update-", env=env)
    dest = os.path.join(base, "Applications", "Umi.app")
    proc = run_installer(target, os.path.join(root, "old", "Umi.app"), dest, os.path.join(base, "bin"), holder.env)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    inst = Instance(Target.from_installed(target, dest), state_dir=holder.dir, env=env)
    try:
        inst.start_app()
        w = inst.json("window", "new", "--name", "work")
        inst.cli("tab", "new", "--window", w["window"], "--name", "notes")
        inst.cli("sidebar", "on")
        wait_until(lambda: inst.json("update", "--status")["state"] == "asking", 30, message="the question")
        time.sleep(1.5)
        shot(inst, w["window"], "I-4-update-question")
        print(inst.cli("update", "--status").stdout.strip())
        inst.cli("update", timeout=600)
        wait_until(lambda: inst.json("update", "--status")["state"] == "ready", 60, message="staged")
        time.sleep(1.5)
        shot(inst, w["window"], "I-4-update-ready")
        print(inst.cli("update", "--status").stdout.strip())
    finally:
        subprocess.run(["pkill", "-TERM", "-f", f"{dest}/Contents/MacOS/"], capture_output=True)
        time.sleep(1)
        inst.cleanup()
        server.shutdown()
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--only", "ui"]:
        agents_and_ui_evidence()
        sys.exit(0)
    if sys.argv[1:] == ["--only", "update"]:
        update_evidence()
    else:
        main()
        update_evidence()
