"""Extra evidence for the written checks (Tern, phase 1), where run_checks.py's setup can't show a
criterion: Files mode on a repository with nested folders (S-2), Markdown images and the E-7 page
rules (E-1, E-7), and the "changed on disk" notice on an edited document (E-4, which run_checks
only reaches through the accessibility tree).

    uv run python checks/tern_extra_evidence.py

Writes results/checks/extra-*.png. Uses an isolated instance and Tern's `screenshot` command.
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
sys.path.insert(0, os.path.join(HERE, "..", "..", "app", "macos", "TernTests"))

from harness import Instance, Target, wait_until  # noqa: E402
from verify_ui_paths import Control  # noqa: E402

MARKDOWN = """# Images and page rules

A local image: ![dot](img/dot.png)

A remote badge inside a link: [![badge](https://img.shields.io/badge/tern-0.1-blue)](https://example.com)

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
    inst = Instance(Target(os.path.join(HERE, "..", "targets", "tern.json")), prefix="acc-extra-")
    inst.start_app()
    base = os.path.realpath(tempfile.mkdtemp(prefix="tern-evidence-"))
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


if __name__ == "__main__":
    main()
