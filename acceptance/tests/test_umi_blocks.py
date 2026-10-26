"""Warp's look for terminals (SPEC S-9 to S-12): the prompt at the bottom, each command and its output as
a block (the folder it ran in and how long it took, the command in bold, its output, a line between
blocks; failed commands marked as Warp marks them), the folder box at the prompt; full-screen programs,
other shells and programs reading the pane unaffected.

What the renderer draws is read two ways: the app's internal `debug.blocks` method (how far the view is
moved down as last drawn, each row's part in a block, each block's folder, command, state and duration),
and screenshots (`umi screenshot`), whose pixels are checked for the view sitting at the bottom, the
lines between blocks and the tint and bar of a failed command. The look itself is judged in the written
checks (CHECKS.md, S-9 to S-11) against the user's Warp screenshot.
"""

import os
import re
import subprocess
import time
import uuid

import pytest

from harness import login_env, wait_until

pytestmark = pytest.mark.layout


# ---- helpers ------------------------------------------------------------------------------------

def blocks(inst, pane):
    return inst.rpc("debug.blocks", pane=pane)


def active(inst, pane, timeout=20):
    """The pane's prompt is ready: its last block is the one being typed at. The blocks."""
    def ready():
        b = blocks(inst, pane)
        return b if b.get("blocks") and b["blocks"][-1]["state"] == "active" else None
    return wait_until(ready, timeout, message="the prompt")


def run(inst, pane, command, timeout=30):
    """Type a command, wait for it to finish (a new prompt). Its block."""
    inst.cli("send", "--pane", pane, "-e", command)

    def done():
        b = blocks(inst, pane)
        if not b.get("blocks") or b["blocks"][-1]["state"] != "active":
            return None
        # A command longer than the pane wraps: its rows are joined with newlines.
        return next((x for x in reversed(b["blocks"])
                     if x["command"].replace("\n", "") == command and x["state"] == "done"), None)
    return wait_until(done, timeout, message=f"`{command}` to finish")


def drawn_at_the_bottom(b):
    """The view as drawn ends at the cursor's row (or a used row below it)."""
    return b["on"] and b["drawn_offset_rows"] == b["offset_rows"] and b["cursor_row"] is not None \
        and b["cursor_row"] + b["offset_rows"] <= b["rows"] - 1


def shell_folder(inst, pane):
    """The folder as zsh's prompt shows it (`%~`)."""
    marker = uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", pane, "-e", f"print -P 'F{marker}:%~'")
    text = wait_until(lambda: re.search(rf"^F{marker}:(.*)$", inst.cli("read", "--pane", pane).stdout, re.M), 10,
                      message="the folder")
    return text.group(1).strip()


def load_png(path):
    """(width, height, RGBA bytes, top row first) of a PNG."""
    import Quartz
    from Foundation import NSURL
    source = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(path)), None)
    image = Quartz.CGImageSourceCreateImageAtIndex(source, 0, None)
    w, h = Quartz.CGImageGetWidth(image), Quartz.CGImageGetHeight(image)
    buf = bytearray(w * h * 4)
    space = Quartz.CGColorSpaceCreateWithName(Quartz.kCGColorSpaceSRGB)
    ctx = Quartz.CGBitmapContextCreate(buf, w, h, 8, w * 4, space, Quartz.kCGImageAlphaPremultipliedLast)
    Quartz.CGContextDrawImage(ctx, Quartz.CGRectMake(0, 0, w, h), image)
    return w, h, buf


class Shot:
    """A window's screenshot, and where its terminal area is (right of the sidebar)."""

    def __init__(self, inst, win, path):
        inst.cli("screenshot", "--window", win["window"], str(path))
        self.w, self.h, self.buf = load_png(path)
        sidebar = float(inst.cli("sidebar", "width", "--window", win["window"]).stdout.split()[0])
        if not inst.json("sidebar", "status", "--window", win["window"])["visible"]:
            sidebar = 0
        frame = inst.json("pane", "info", win["pane"])["frame"]
        self.scale = self.w / (sidebar + frame["width"])
        self.left = int(round(sidebar * self.scale))
        self.bg = self.px(self.w - 3, self.h // 2)

    def px(self, x, y):
        i = (y * self.w + x) * 4
        return tuple(self.buf[i:i + 3])

    def differs(self, color, by):
        return max(abs(a - b) for a, b in zip(color, self.bg)) > by

    def ink_rows(self, x0=None, x1=None, by=60, step=2):
        """Rows of the terminal area with text on them (pixels far from the background)."""
        x0 = self.left + int(10 * self.scale) if x0 is None else x0
        x1 = self.w - int(10 * self.scale) if x1 is None else x1
        return [y for y in range(self.h)
                if any(self.differs(self.px(x, y), by) for x in range(x0, x1, step))]

    def row_color(self, y, x0, x1):
        """The average color of row y between x0 and x1."""
        n = max(1, x1 - x0)
        total = [0, 0, 0]
        for x in range(x0, x1):
            for i, c in enumerate(self.px(x, y)):
                total[i] += c
        return tuple(t / n for t in total)


# ---- S-9: at the bottom --------------------------------------------------------------------------

@pytest.mark.req("S-9")
def test_the_prompt_sits_at_the_bottom_from_the_start(inst, win, tmp_path):
    b = active(inst, win["pane"])
    assert b["on"], b
    wait_until(lambda: drawn_at_the_bottom(blocks(inst, win["pane"])), 10, message="the view drawn at the bottom")
    b = blocks(inst, win["pane"])
    assert b["offset_rows"] > b["rows"] // 2, f"a fresh pane's few rows are moved to the bottom: {b}"
    # The prompt's row is the last row shown.
    assert b["cursor_row"] + b["offset_rows"] == b["rows"] - 1, b
    # And so it looks: the terminal area's text is all in its lower part, down to the bottom.
    shot = Shot(inst, win, tmp_path / "fresh.png")
    ink = shot.ink_rows()
    assert ink, "the screenshot shows the prompt"
    assert min(ink) > shot.h * 0.5, f"text in the upper half of a fresh pane (rows {min(ink)}..{max(ink)} of {shot.h})"
    assert max(ink) > shot.h * 0.85, f"the prompt isn't at the bottom (last text row {max(ink)} of {shot.h})"


@pytest.mark.req("S-9")
def test_output_builds_upward_above_the_prompt(inst, win):
    pane = win["pane"]
    active(inst, pane)
    before = blocks(inst, pane)["offset_rows"]
    run(inst, pane, "printf 'one\\ntwo\\nthree\\n'")
    b = blocks(inst, pane)
    # A block of three lines and the new prompt: everything moved up by that much, the prompt stays
    # on the last row.
    assert b["offset_rows"] < before, (before, b)
    assert b["cursor_row"] + b["offset_rows"] == b["rows"] - 1, b
    assert drawn_at_the_bottom(b)
    # Once the screen is full, nothing is moved: it's the usual terminal.
    run(inst, pane, "seq 1 200")
    b = blocks(inst, pane)
    assert b["offset_rows"] == 0 and b["cursor_row"] == b["rows"] - 1, b


@pytest.mark.req("S-9")
def test_it_stays_at_the_bottom_after_clear_and_cmd_k(inst, win):
    pane = win["pane"]
    active(inst, pane)
    run(inst, pane, "seq 1 200")
    assert blocks(inst, pane)["offset_rows"] == 0
    # `clear`.
    inst.cli("send", "--pane", pane, "-e", "clear")
    wait_until(lambda: (lambda b: b["offset_rows"] > b["rows"] // 2 and drawn_at_the_bottom(b))(blocks(inst, pane)),
               10, message="the prompt at the bottom after clear")
    b = blocks(inst, pane)
    assert b["cursor_row"] + b["offset_rows"] == b["rows"] - 1, b
    # ⌘K (Ghostty's clear_screen), with the terminal focused.
    run(inst, pane, "seq 1 200")
    assert blocks(inst, pane)["offset_rows"] == 0
    inst.cli("pane", "focus", pane)
    inst.rpc("debug.key", window=win["window"], keys="cmd+k")
    wait_until(lambda: (lambda b: b["offset_rows"] > b["rows"] // 2 and drawn_at_the_bottom(b))(blocks(inst, pane)),
               10, message="the prompt at the bottom after ⌘K")
    b = blocks(inst, pane)
    assert b["cursor_row"] + b["offset_rows"] == b["rows"] - 1, b
    assert "seq 1 200" not in inst.cli("read", "--pane", pane, "--scrollback").stdout, "⌘K cleared the pane"


@pytest.mark.req("S-9")
def test_a_list_below_the_prompt_is_shown(inst, win):
    """zsh lists completions below the command line: the view moves up to show them."""
    pane = win["pane"]
    active(inst, pane)
    inst.cli("send", "--pane", pane, "ls /usr/")
    inst.cli("keys", "--pane", pane, "tab")
    time.sleep(0.3)
    inst.cli("keys", "--pane", pane, "tab")

    def listed():
        b = blocks(inst, pane)
        screen = inst.cli("read", "--pane", pane).stdout
        return b if "bin/" in screen and "share/" in screen and b["offset_rows"] + b["cursor_row"] < b["rows"] - 1 else None
    b = wait_until(listed, 10, message="the completion list below the prompt")
    # The last row with the list is the last row shown.
    last_used = b["rows"] - 1 - b["offset_rows"]
    lines = inst.cli("read", "--pane", pane).stdout.split("\n")
    assert "share/" in "".join(lines[b["cursor_row"]:last_used + 1]), (b, lines[b["cursor_row"]:last_used + 2])
    inst.cli("keys", "--pane", pane, "ctrl+c")


# ---- S-10: blocks ---------------------------------------------------------------------------------

@pytest.mark.req("S-10")
def test_each_command_is_a_block_with_its_folder_its_duration_and_its_output(inst, win):
    pane = win["pane"]
    active(inst, pane)
    folder = shell_folder(inst, pane)
    marker = uuid.uuid4().hex[:6]
    block = run(inst, pane, f"echo out-{marker}")
    assert block["header"] == folder, block
    assert block["failed"] is False and block["ms"] is not None and block["ms"] < 5000, block
    assert re.fullmatch(r"\((\d+\.?\d*s|\d+m \d+\.\d\ds|\d+h( \d+m)? \d+s)\)", block["duration"]), block
    # Its rows: two spacers (the line between blocks), the folder, the command, its output.
    b = blocks(inst, pane)
    index = next(i for i, x in enumerate(b["blocks"]) if x["command"] == f"echo out-{marker}")
    first = b["blocks"][index]["first"]
    assert b["roles"][first:first + 5] == ["spacer_top", "spacer", "header", "command", "output"], b["roles"][first:first + 6]
    lines = inst.cli("read", "--pane", pane).stdout.split("\n")
    assert lines[first + 4] == f"out-{marker}", lines[first:first + 6]

    # How long it took, as Warp writes it.
    slow = run(inst, pane, "sleep 1.2")
    assert 1150 <= slow["ms"] < 4000, slow
    assert re.fullmatch(r"\(1\.\d{1,3}s\)", slow["duration"]), slow

    # Another folder.
    moved = run(inst, pane, "cd /usr/bin")
    assert moved["header"] == folder, "a block's folder is the one it ran in"
    after = run(inst, pane, "true")
    assert after["header"] == "/usr/bin", after


@pytest.mark.req("S-10")
def test_a_running_command_shows_how_long_it_has_run(inst, win):
    pane = win["pane"]
    active(inst, pane)
    inst.cli("send", "--pane", pane, "-e", "sleep 4")

    def running(at_least):
        def check():
            x = blocks(inst, pane)["blocks"][-1]
            return x if x["state"] == "running" and x["ms"] is not None and x["ms"] >= at_least else None
        return check
    first = wait_until(running(1000), 10, message="the running block's time")
    assert first["duration"] in ("(1s)", "(2s)"), first
    later = wait_until(running(2000), 10, message="the time to go on")
    assert later["duration"] in ("(2s)", "(3s)"), later
    done = wait_until(lambda: next((x for x in blocks(inst, pane)["blocks"] if x["command"] == "sleep 4" and x["state"] == "done"), None),
                      10, message="the command to finish")
    assert 3900 <= done["ms"] < 8000, done


@pytest.mark.req("S-10")
def test_a_failed_command_is_marked_as_warp_marks_it(inst, win, tmp_path):
    """Warp marks a command that exited with an error: the theme's red at 10% over the block, and a
    5-point red bar along the pane's left edge. Commands that succeed aren't marked."""
    pane = win["pane"]
    active(inst, pane)
    good = run(inst, pane, "true")
    assert good["failed"] is False
    bad = run(inst, pane, "sh -c 'exit 3'")
    assert bad["failed"] is True and bad["state"] == "done", bad
    run(inst, pane, "echo after")

    shot = Shot(inst, win, tmp_path / "failed.png")
    # The reddish band at the far right (beyond any text), and the bar at the pane's left edge.
    x0, x1 = int(shot.w * 0.8), shot.w - 4
    lean = shot.bg[0] - shot.bg[1]
    red = lambda c: c[0] - shot.bg[0] > 6 and c[0] - c[1] > lean + 6
    band = [y for y in range(shot.h) if red(shot.row_color(y, x0, x1))]
    assert band, "no tinted block"
    top, end = min(band), max(band)
    assert len(band) == end - top + 1, "one tinted band"
    cell = shot.h / (blocks(inst, pane)["rows"] + 2)
    assert end - top > 3 * cell, f"the tint covers the block, its paddings included ({top}..{end}, cell ~{cell:.0f})"
    middle = (top + end) // 2
    bar = shot.px(shot.left + max(1, int(2 * shot.scale)), middle)
    assert bar[0] > 150 and bar[0] - bar[1] > 60, f"a red bar at the pane's left edge: {bar}"
    beside = shot.px(shot.left + int(9 * shot.scale), middle)
    assert beside[0] < bar[0] - 60, f"the bar is narrow (5 points): {beside} vs {bar}"
    # Only that block: the rows above and below it aren't tinted.
    assert not red(shot.row_color(max(0, top - 6), x0, x1))
    assert not red(shot.row_color(min(shot.h - 1, end + 6), x0, x1))


@pytest.mark.req("S-10")
def test_a_line_between_blocks(inst, win, tmp_path):
    """Each block has a thin line along its top (the foreground at 10%), across the pane."""
    pane = win["pane"]
    active(inst, pane)
    for word in ("alpha", "beta", "gamma"):
        run(inst, pane, f"echo {word}")
    b = blocks(inst, pane)
    visible_blocks = [x for x in b["blocks"] if x["first"] + 1 >= 0]
    shot = Shot(inst, win, tmp_path / "lines.png")
    x0, x1 = int(shot.w * 0.75), shot.w - 4
    lines = []
    for y in range(shot.h):
        c = shot.row_color(y, x0, x1)
        lift = sum(c) / 3 - sum(shot.bg) / 3
        if 4 < lift < 60:
            if not lines or y - lines[-1][-1] > 1:
                lines.append([y])
            else:
                lines[-1].append(y)
    thin = [rows for rows in lines if len(rows) <= max(2, int(shot.scale))]
    assert len(thin) >= len(visible_blocks), f"{len(thin)} lines for {len(visible_blocks)} blocks: {lines}"


@pytest.mark.req("S-10")
def test_the_command_of_a_block_that_ran_is_bold(inst, win, tmp_path):
    """The same command line is drawn heavier once it ran than while it's typed (bold is also judged
    in the written check)."""
    pane = win["pane"]
    active(inst, pane)
    command = ": " + "W" * 30

    def lit(shot):
        """Lit pixels of the densest text band of the terminal area's left half (the W's)."""
        x0, x1 = shot.left + int(10 * shot.scale), shot.left + (shot.w - shot.left) // 2
        density = [sum(1 for x in range(x0, x1, 2) if shot.differs(shot.px(x, y), 150)) for y in range(shot.h)]
        best = max(range(shot.h), key=lambda y: density[y])
        half = int(6 * shot.scale)
        return sum(density[max(0, best - half):best + half])

    inst.cli("send", "--pane", pane, command)
    time.sleep(0.8)
    typed = lit(Shot(inst, win, tmp_path / "typed.png"))
    inst.cli("keys", "--pane", pane, "enter")
    wait_until(lambda: blocks(inst, pane)["blocks"][-1]["state"] == "active" and
               any(x["command"] == command and x["state"] == "done" for x in blocks(inst, pane)["blocks"]), 10,
               message="the command to run")
    ran = lit(Shot(inst, win, tmp_path / "ran.png"))
    assert ran > typed * 1.1, f"the command drawn bold: {ran} lit pixels against {typed} when typed"


# ---- S-11: the folder box -------------------------------------------------------------------------

@pytest.mark.req("S-10", "S-11")
def test_blocks_report_wide_and_combined_characters_as_typed(inst, win, tmp_path):
    """Review round 8: the app's report of a block's folder and command (what these tests read) turned a
    wide character's second cell into a space and dropped the rest of a grapheme."""
    pane = win["pane"]
    active(inst, pane)
    folder = tmp_path / "日本語-é"
    folder.mkdir()
    run(inst, pane, f"cd '{folder}'")
    command = "echo 日本 é"
    block = run(inst, pane, command)
    assert block["command"] == command, block
    assert active(inst, pane)["blocks"][-1]["header"].endswith("日本語-é")


@pytest.mark.req("S-11")
def test_the_folder_box_shows_the_current_folder(inst, win):
    pane = win["pane"]
    b = active(inst, pane)
    folder = shell_folder(inst, pane)
    prompt = active(inst, pane)["blocks"][-1]
    assert prompt["header"] == folder and prompt["state"] == "active", prompt
    assert prompt["ms"] is None, "the prompt has no duration"
    run(inst, pane, "cd /usr/share")
    prompt = active(inst, pane)["blocks"][-1]
    assert prompt["header"] == "/usr/share", prompt
    run(inst, pane, "cd ~")
    assert active(inst, pane)["blocks"][-1]["header"] == "~"
    assert b["on"]


@pytest.mark.req("S-11")
def test_a_long_folder_is_shortened_to_fit_the_box(inst, win, tmp_path):
    """Review round 2: a folder as long as the pane ran past its edge once the box's icon moved it
    right. zsh shortens it from the left, as Warp's box does (`…/rest`), leaving room for the icon."""
    pane = win["pane"]
    b = active(inst, pane)
    deep = tmp_path
    while len(str(deep)) < b["cols"] + 20:
        deep = deep / "a-rather-long-folder-name"
    deep.mkdir(parents=True)
    run(inst, pane, f"cd '{deep}'")
    prompt = active(inst, pane)["blocks"][-1]
    header = prompt["header"]
    assert header.startswith("…") and str(deep).endswith(header[1:]), header
    assert len(header) <= b["cols"] - 4, (len(header), b["cols"])


@pytest.mark.req("S-11")
def test_the_folder_is_shortened_again_when_the_pane_narrows(inst, win, tmp_path):
    """Review round 5: the folder's width was worked out when the prompt was made, so a pane made
    narrower afterwards cut it off again. zsh works it out each time it draws the prompt."""
    pane = win["pane"]
    other = inst.cli("split", "right", "--pane", pane).stdout.strip()
    time.sleep(1)
    b = active(inst, pane)
    deep = tmp_path / "folder-name"
    while len(str(deep)) < b["cols"] - 6:
        deep = deep / "folder-name"
    deep.mkdir(parents=True, exist_ok=True)
    run(inst, pane, f"cd '{deep}'")
    before = active(inst, pane)
    assert len(before["blocks"][-1]["header"]) > before["cols"] - 30, before["blocks"][-1]
    for _ in range(4):
        inst.cli("pane", "resize", pane, "left", "10")
    wait_until(lambda: blocks(inst, pane)["cols"] < before["cols"] - 10, 10, message="the narrower pane")

    def fits():
        b = blocks(inst, pane)
        header = b["blocks"][-1]["header"] if b["blocks"] else ""
        return b if header.startswith("…") and len(header) <= b["cols"] - 4 else None
    wait_until(fits, 10, message="the folder shortened to the new width")
    inst.cli("pane", "close", other)


# ---- S-12: where it applies ----------------------------------------------------------------------

@pytest.mark.req("S-12")
def test_full_screen_programs_take_the_whole_pane(inst, win, tmp_path):
    pane = win["pane"]
    active(inst, pane)
    marker = uuid.uuid4().hex[:6]
    # The alternate screen (as vim or a full-screen agent interface uses it), text at its top-left.
    inst.cli("send", "--pane", pane, "-e",
             f"printf '\\033[?1049h\\033[H\\033[2JFULL-{marker}'; sleep 6; printf '\\033[?1049l'")
    wait_until(lambda: f"FULL-{marker}" in inst.cli("read", "--pane", pane).stdout and
               not blocks(inst, pane)["on"], 10, message="the full-screen program")
    b = blocks(inst, pane)
    assert b["offset_rows"] == 0 and b["drawn_offset_rows"] == 0 and b["blocks"] == [], b
    assert set(b["roles"]) == {"none"}
    shot = Shot(inst, win, tmp_path / "full.png")
    ink = shot.ink_rows()
    assert ink and min(ink) < shot.h * 0.15, f"the program's text is at the top (first text row {min(ink)} of {shot.h})"
    assert max(ink) < shot.h * 0.2, "nothing else is drawn (no blocks, no folder box)"
    # Back: blocks again, at the bottom.
    wait_until(lambda: blocks(inst, pane)["on"] and drawn_at_the_bottom(blocks(inst, pane)), 15,
               message="the blocks back after the program")


@pytest.mark.req("S-12")
def test_other_shells_keep_the_usual_look(inst, win):
    """bash (with Ghostty's integration, as Umi starts it) marks its prompts without Umi's marker: no
    blocks, nothing moved."""
    pane = inst.cli("split", "right", "--pane", win["pane"], "--cmd", "/bin/bash -l").stdout.strip()
    wait_until(lambda: "$" in inst.cli("read", "--pane", pane).stdout, 20, message="bash's prompt")
    inst.cli("send", "--pane", pane, "-e", "echo from-bash")
    wait_until(lambda: inst.cli("read", "--pane", pane).stdout.count("from-bash") >= 2, 10, message="bash's output")
    b = blocks(inst, pane)
    assert not b["on"] and b["offset_rows"] == 0 and b["drawn_offset_rows"] == 0 and b["blocks"] == [], b
    lines = inst.cli("read", "--pane", pane).stdout.strip().split("\n")
    assert lines[0].strip(), "bash's text starts at the top"


@pytest.mark.req("S-12")
def test_readers_see_what_the_shell_and_programs_printed(inst, win):
    """`read` shows the rows as the shell printed them (its folder line, the command, the output),
    nothing Umi draws (durations, the folder box's icon); `wait --pattern` matches output only."""
    pane = win["pane"]
    active(inst, pane)
    folder = shell_folder(inst, pane)
    marker = uuid.uuid4().hex[:6]
    run(inst, pane, f"echo seen-{marker}")
    text = inst.cli("read", "--pane", pane).stdout
    lines = text.split("\n")
    i = lines.index(f"echo seen-{marker}")
    assert lines[i - 1] == folder and lines[i + 1] == f"seen-{marker}", lines[i - 3:i + 3]
    assert not re.search(r"\(\d+(\.\d+)?s\)", text), "a duration Umi drew is in the text"
    assert not any(0xE000 <= ord(ch) <= 0xF8FF for ch in text), "the folder icon is in the text"
    # wait --pattern: the folder line (prompt) and the typed command don't match, the output does.
    proc = inst.cli("wait", "--pane", pane, "--pattern", "^" + re.escape(folder) + "$", "--timeout", "1", check=False)
    assert proc.returncode == 124, "the folder line is the prompt, not output"
    marker2 = uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", pane, "-e", f"sleep 1; echo got-{marker2}")
    found = inst.cli("wait", "--pane", pane, "--pattern", f"got-{marker2}", "--timeout", "15")
    assert found.returncode == 0


@pytest.mark.req("S-12")
def test_empty_enters_leave_the_shells_prompts_as_they_were(inst, win):
    """Review round 1: an Enter on an empty line (or Ctrl-C) runs no command, and the continuation prompt
    (PS2) gained another pair of marks with every such prompt. zsh's prompts stay the same however many
    there are."""
    pane = win["pane"]
    active(inst, pane)

    def ps2_length():
        marker = uuid.uuid4().hex[:6]
        inst.cli("send", "--pane", pane, "-e", f"echo L{marker}=${{#PS2}}")
        found = wait_until(lambda: re.search(rf"^L{marker}=(\d+)$", inst.cli("read", "--pane", pane).stdout, re.M),
                           10, message="PS2's length")
        return int(found.group(1))
    before = ps2_length()
    for _ in range(5):
        inst.cli("keys", "--pane", pane, "enter")
        time.sleep(0.2)
    inst.cli("keys", "--pane", pane, "ctrl+c")
    time.sleep(0.3)
    assert ps2_length() == before


@pytest.mark.req("S-9")
def test_the_top_padding_extends_again_once_the_view_fills(fresh, tmp_path):
    """Review round 9: with `window-padding-color = extend-always`, the top padding stopped taking the
    first row's background while the view was moved down, and didn't again once output filled the pane
    without scrolling (a redraw of some rows only)."""
    config = tmp_path / "xdg" / "ghostty"
    config.mkdir(parents=True)
    (config / "config").write_text("window-padding-color = extend-always\nwindow-padding-y = 30\n")
    other = fresh(prefix="acc-extend-", env={"XDG_CONFIG_HOME": str(tmp_path / "xdg")})
    created = other.json("window", "new", "--name", "extend")
    pane = created["pane"]
    active(other, pane)
    other.cli("sidebar", "off")
    # Red rows down to the last one, the cursor on it: nothing scrolls, nothing is moved down.
    other.cli("send", "--pane", pane, "-e",
              "clear; for i in $(seq 2 $LINES); do printf '\\033[41m\\033[K\\033[0m\\n'; done; "
              "printf '\\033[41m\\033[K\\033[0m'; sleep 8")
    wait_until(lambda: (lambda b: b["offset_rows"] == 0 and b["drawn_offset_rows"] == 0)(blocks(other, pane)), 10,
               message="the pane filled")
    time.sleep(1)
    other.cli("screenshot", "--window", created["window"], str(tmp_path / "extend.png"))
    w, h, buf = load_png(tmp_path / "extend.png")
    px = lambda x, y: tuple(buf[(y * w + x) * 4:(y * w + x) * 4 + 3])
    red = lambda c: c[0] > 120 and c[1] < 90 and c[2] < 90
    x = w // 2
    reds = [y for y in range(h) if red(px(x, y))]
    assert reds, "the red rows are drawn"
    # extend-always extends the edge rows' red into the padding above and below: the red covers the
    # pane's whole height (its top padding is 30 points).
    frame = other.json("pane", "info", pane)["frame"]
    scale = w / frame["width"]
    assert len(reds) >= frame["height"] * scale - 4, (len(reds), frame["height"] * scale)
    other.cli("sidebar", "on")


@pytest.mark.req("S-12")
def test_it_can_be_turned_off(fresh, tmp_path):
    """`shell-integration-features = no-umi-blocks` in the user's Ghostty config: zsh's own prompt, at the
    top, no blocks."""
    config = tmp_path / "xdg" / "ghostty"
    config.mkdir(parents=True)
    (config / "config").write_text("shell-integration-features = no-umi-blocks\n")
    other = fresh(prefix="acc-noblocks-", env={"XDG_CONFIG_HOME": str(tmp_path / "xdg")})
    pane = other.json("window", "new", "--name", "no-blocks")["pane"]
    wait_until(lambda: other.cli("read", "--pane", pane).stdout.strip(), 20, message="the prompt")
    other.cli("send", "--pane", pane, "-e", "echo plain-look")
    wait_until(lambda: other.cli("read", "--pane", pane).stdout.count("plain-look") >= 2, 10, message="the output")
    b = blocks(other, pane)
    assert not b["on"] and b["offset_rows"] == 0 and b["drawn_offset_rows"] == 0 and b["blocks"] == [], b
    assert "umi-blocks" not in other.cli("read", "--pane", pane).stdout


@pytest.mark.req("S-12")
def test_zsh_integration_sourced_by_hand_gets_the_look(fresh, tmp_path):
    """Review round 3: with `shell-integration = none`, sourcing Ghostty's zsh integration by hand (as its
    documentation describes) printed Umi's block prompt but the terminal never drew the blocks."""
    config = tmp_path / "xdg" / "ghostty"
    config.mkdir(parents=True)
    (config / "config").write_text("shell-integration = none\n")
    other = fresh(prefix="acc-manual-", env={"XDG_CONFIG_HOME": str(tmp_path / "xdg")})
    pane = other.json("window", "new", "--name", "manual")["pane"]
    wait_until(lambda: other.cli("read", "--pane", pane).stdout.strip(), 20, message="the prompt")
    assert not blocks(other, pane)["blocks"], "no integration yet"
    other.cli("send", "--pane", pane, "-e",
              'source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"')
    b = wait_until(lambda: (lambda x: x if x["on"] and x["blocks"] and x["blocks"][-1]["state"] == "active" else None)(
        blocks(other, pane)), 20, message="the block prompt, drawn")
    assert drawn_at_the_bottom(b) or wait_until(lambda: drawn_at_the_bottom(blocks(other, pane)), 10)


@pytest.mark.req("S-10")
def test_a_nested_shell_leaves_its_parent_block_to_finish(inst, win):
    """Review round 4: a zsh started from the prompt that loads Umi's integration shows block prompts of
    its own; the command that started it lost its block then, and never got its duration or its failure
    mark when the nested shell exited."""
    pane = win["pane"]
    active(inst, pane)
    inst.cli("send", "--pane", pane, "-e", "zsh -i")
    time.sleep(1.5)
    inst.cli("send", "--pane", pane, "-e", 'source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"')
    wait_until(lambda: blocks(inst, pane)["blocks"][-1]["state"] == "active" and
               any(x["command"] == "zsh -i" and x["state"] == "running" for x in blocks(inst, pane)["blocks"]),
               15, message="the nested shell's own block prompt")
    run(inst, pane, "echo inside")
    inst.cli("keys", "--pane", pane, "enter")
    time.sleep(0.5)
    inst.cli("send", "--pane", pane, "-e", "exit 3")
    outer = wait_until(lambda: next((x for x in blocks(inst, pane)["blocks"]
                                     if x["command"] == "zsh -i" and x["state"] == "done"), None),
                       15, message="the outer command's block to finish")
    assert outer["failed"] is True and outer["ms"] >= 1000, outer


@pytest.mark.req("S-12")
def test_only_inside_umi(inst, win):
    """The prompt is Umi's only in Umi's terminals: zsh started elsewhere (here, outside the app, with
    the user's own startup files) prints the user's own prompt, without Umi's block marker."""
    env = dict(login_env())
    env.pop("GHOSTTY_SHELL_FEATURES", None)
    env.pop("GHOSTTY_RESOURCES_DIR", None)
    out = subprocess.run(["script", "-q", "/dev/null", "/bin/zsh", "-i", "-c", "print -rn -- ${(V)PS1}; exit"],
                         env=env, capture_output=True, timeout=30, stdin=subprocess.DEVNULL).stdout.decode(errors="replace")
    assert "umi=1" not in out
    # Inside Umi, the shell gets the feature and its prompt carries the marker.
    marker = uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", win["pane"], "-e", f"echo F{marker}=$GHOSTTY_SHELL_FEATURES")
    features = wait_until(lambda: re.search(rf"^F{marker}=(\S*)$", inst.cli("read", "--pane", win["pane"]).stdout, re.M), 10,
                          message="the features")
    assert "umi-blocks" in features.group(1).split(",")


# ---- With the real mouse (accessibility; takes over the mouse) -----------------------------------

def _double_click(point):
    import Quartz
    def post(kind, clicks):
        event = Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventSetIntegerValueField(event, Quartz.kCGMouseEventClickState, clicks)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    post(Quartz.kCGEventMouseMoved, 0)
    time.sleep(0.2)
    for clicks in (1, 2):
        post(Quartz.kCGEventLeftMouseDown, clicks)
        time.sleep(0.03)
        post(Quartz.kCGEventLeftMouseUp, clicks)
        time.sleep(0.05)
    time.sleep(0.4)


def _drag(start, end, steps=12):
    import Quartz
    def post(kind, point):
        event = Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    post(Quartz.kCGEventMouseMoved, start)
    time.sleep(0.2)
    post(Quartz.kCGEventLeftMouseDown, start)
    time.sleep(0.1)
    for i in range(1, steps + 1):
        post(Quartz.kCGEventLeftMouseDragged, (start[0] + (end[0] - start[0]) * i / steps, start[1]))
        time.sleep(0.02)
    post(Quartz.kCGEventLeftMouseUp, end)
    time.sleep(0.4)


def _frame(ui, element):
    import ApplicationServices as AX  # noqa: N812
    p = AX.AXValueGetValue(ui.attr(element, "AXPosition"), AX.kAXValueCGPointType, None)[1]
    s = AX.AXValueGetValue(ui.attr(element, "AXSize"), AX.kAXValueCGSizeType, None)[1]
    return p.x, p.y, s.width, s.height


@pytest.mark.req("S-9")
def test_the_mouse_selects_what_is_drawn_where_it_points_ui(inst, win, ui):
    """With the view moved down, a double-click on a word selects that word: the mouse maps to the rows
    as drawn, not as they'd be without the move."""
    pane = win["pane"]
    active(inst, pane)
    marker = uuid.uuid4().hex[:6]
    run(inst, pane, f"echo pick-{marker}")
    b = blocks(inst, pane)
    assert b["offset_rows"] > 3, "the view is moved down"
    row = inst.cli("read", "--pane", pane).stdout.split("\n").index(f"pick-{marker}")
    inst.cli("window", "focus", win["window"])
    ui.activate()
    area = wait_until(lambda: ui.text_area(f"pick-{marker}"), 10, message="the terminal in the accessibility tree")
    x, y, _, _ = _frame(ui, area)
    cell_w, cell_h = b["cell_pt"]
    point = (x + b["padding_pt"]["left"] + 3.5 * cell_w,
             y + b["padding_pt"]["top"] + (row + b["drawn_offset_rows"] + 0.5) * cell_h)
    _double_click(point)
    selected = wait_until(lambda: inst.rpc("debug.selection", pane=pane).get("text"), 5, message="a selection")
    assert selected.strip() == f"pick-{marker}", f"selected {selected!r}"

    # Review round 1: a block's command is drawn a little above its row (Warp's spacing). A
    # double-click on the upper part of the drawn word selects the command, not the folder above it.
    lines = inst.cli("read", "--pane", pane).stdout.split("\n")
    command_row = lines.index(f"echo pick-{marker}")
    point = (x + b["padding_pt"]["left"] + 1.5 * cell_w,
             y + b["padding_pt"]["top"] + (command_row + b["drawn_offset_rows"] - 0.12) * cell_h)
    _double_click(point)
    selected = wait_until(lambda: inst.rpc("debug.selection", pane=pane).get("text"), 5, message="a selection")
    assert selected.strip() == "echo", f"selected {selected!r}"

    # The folder box's text is drawn right of its cells (after the icon): a double-click on the drawn
    # folder name selects it.
    inst.cli("send", "--pane", pane, "-e", "cd /usr/share")
    wait_until(lambda: active(inst, pane)["blocks"][-1]["header"] == "/usr/share", 10, message="the prompt in /usr/share")
    b = blocks(inst, pane)
    header_row = b["blocks"][-1]["first"] + 2
    box_text_dx = b["box_text_dx_pt"]  # the border, padding, icon and gap: the last letters are past column 9
    assert box_text_dx > cell_w
    point = (x + b["padding_pt"]["left"] + box_text_dx + 9.5 * cell_w,
             y + b["padding_pt"]["top"] + (header_row + b["drawn_offset_rows"] + 0.5) * cell_h)
    _double_click(point)
    selected = wait_until(lambda: inst.rpc("debug.selection", pane=pane).get("text"), 5, message="a selection")
    assert "share" in selected, f"selected {selected!r}"

    # Review round 6: a drag across the box's text, from the left part of its first letter to the right
    # part of its last, selects all of it (the half-cell thresholds follow the drawn text too).
    dx = b["box_text_dx_pt"]
    left = x + b["padding_pt"]["left"] + dx + 0.2 * cell_w
    right = x + b["padding_pt"]["left"] + dx + (len("/usr/share") - 0.2) * cell_w
    row_y = y + b["padding_pt"]["top"] + (header_row + b["drawn_offset_rows"] + 0.5) * cell_h
    _drag((left, row_y), (right, row_y))
    selected = wait_until(lambda: inst.rpc("debug.selection", pane=pane).get("text"), 5, message="a selection")
    assert selected.strip() == "/usr/share", f"selected {selected!r}"
