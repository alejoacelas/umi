"""Warp's look for the terminal itself (Warp parity, 2026-11-05; SPEC S-5, S-10 to S-12):
Warp's Dark colors, its selection and contrast rule, Hack 13 with rows 1.2x the font size, Warp's
padding (none for full-screen programs), its rounded 3-point bar cursor, its scrollbar and silent
bell; blocks that count Ctrl-C and SIGPIPE as success, show no running time before a second and carry
Warp's header (environments, user@host over SSH, git branch); the folder box showing the folder alone,
cut at 40 characters.

Read through the app's `debug.terminal` (the renderer's report: font, cells, cursor, padding, blocks;
the scrollbar and the bell's effects), `debug.blocks`, and screenshots (`umi screenshot`).
"""

import os
import re
import subprocess
import time
import uuid

import pytest

from harness import wait_until
from test_umi_blocks import Shot, active, blocks, load_png, run, shell_folder

pytestmark = pytest.mark.layout


def terminal(inst, pane):
    return inst.rpc("debug.terminal", pane=pane)


def near(color, want, by):
    return all(abs(a - b) <= by for a, b in zip(color, want))


def pane_top(shot, inst, win):
    """Where the pane's top is in the screenshot, in pixels (the pane ends at the window's bottom)."""
    frame = inst.json("pane", "info", win["pane"])["frame"]
    return int(round(shot.h - frame["height"] * shot.scale))


def row_y(shot, inst, win, b, row):
    """The screenshot's pixel row through the middle of viewport row `row` as drawn."""
    cell_h = b["cell_pt"][1]
    return pane_top(shot, inst, win) + int((b["padding_pt"]["top"] + (row + b["drawn_offset_rows"] + 0.5) * cell_h) * shot.scale)


def output_row(b, command):
    """The viewport row of the first line a one-row command printed (its block: two spacers, the
    header, the command)."""
    block = next(x for x in reversed(b["blocks"]) if x["command"] == command)
    return block["first"] + 4


def cat_file(inst, pane, tmp_path, name, data):
    """Print `data` (bytes with escapes) with a short command, from the test's folder."""
    (tmp_path / name).write_bytes(data)
    run(inst, pane, f"cd '{tmp_path}'")
    return run(inst, pane, f"cat {name}")


# ---- S-5: colors -----------------------------------------------------------------------------------

@pytest.mark.req("S-5")
def test_the_background_is_warps_dark_050505(inst, win, tmp_path):
    pane = win["pane"]
    active(inst, pane)
    shot = Shot(inst, win, tmp_path / "bg.png")
    assert near(shot.bg, (5, 5, 5), 2), f"the background is Warp's #050505: {shot.bg}"


@pytest.mark.req("S-5")
def test_selection_is_warps_blue_over_the_text_which_keeps_its_colors(inst, win, tmp_path):
    """Warp lays rgba(118,167,250,0.40) over the selected cells and keeps each cell's text color: over
    #050505 that is #324667, and red text stays red."""
    pane = win["pane"]
    active(inst, pane)
    block = cat_file(inst, pane, tmp_path, "red", b"\x1b[31m" + b"R" * 30 + b"\x1b[0m\n")
    # Ghostty's select_all (⌘A), run on the pane wherever focus is.
    assert inst.rpc("debug.terminal.action", pane=pane, action="select_all")["ok"]
    wait_until(lambda: "R" * 30 in (inst.rpc("debug.selection", pane=pane).get("text") or ""), 5, message="a selection")
    time.sleep(0.5)
    shot = Shot(inst, win, tmp_path / "selected.png")
    b = blocks(inst, pane)
    # Selected empty cells right of the text (the rows from the first printed one down; the blank
    # rows above the pane's first output aren't part of the screen's text).
    x = shot.left + int((shot.w - shot.left) * 0.85)
    samples = [shot.px(x, y) for y in range(0, shot.h, 3)]
    blue = [c for c in samples if near(c, (50, 70, 103), 6)]
    assert len(blue) * 3 > 4 * b["cell_pt"][1] * shot.scale, f"rows selected in #324667: {len(blue)} samples"
    assert not any(near(c, (0x24, 0x43, 0x5c), 6) for c in samples), "not the old solid #24435c"
    # The red text keeps its color under the selection.
    b = blocks(inst, pane)
    y = row_y(shot, inst, win, b, output_row(b, "cat red"))
    pad = b["padding_pt"]["left"] * shot.scale
    cell_w = b["cell_pt"][0] * shot.scale
    reds = [shot.px(int(shot.left + pad + cell_w * i / 4), yy) for i in range(4, 100) for yy in range(y - 4, y + 5)]
    assert any(c[0] > 150 and c[0] - c[1] > 60 for c in reds), "the selected text stays red"
    assert block["state"] == "done"


@pytest.mark.req("S-5")
def test_minimum_contrast_raises_named_colors_only(inst, win, tmp_path):
    """Warp's default: text in a named color (here palette 0, #616161, about 3.3:1 on #050505) is moved
    toward white just enough for 4.5:1 (about #767676, not white); the same gray given as RGB, and a
    like gray from the 256-color table (index 59, #5F5F5F), keep their colors."""
    pane = win["pane"]
    active(inst, pane)
    line = (b"\x1b[30m" + b"N" * 20 + b"\x1b[0m" + b" " * 10 + b"\x1b[38;2;97;97;97m" + b"N" * 20 + b"\x1b[0m"
            + b" " * 10 + b"\x1b[38;5;59m" + b"N" * 20 + b"\x1b[0m\n")
    cat_file(inst, pane, tmp_path, "gray", line)
    time.sleep(0.5)
    shot = Shot(inst, win, tmp_path / "contrast.png")
    b = blocks(inst, pane)
    y = row_y(shot, inst, win, b, output_row(b, "cat gray"))
    pad = b["padding_pt"]["left"] * shot.scale
    cell_w = b["cell_pt"][0] * shot.scale

    def brightest(c0, c1):
        return max(max(shot.px(int(shot.left + pad + cell_w * c0 + dx), yy))
                   for dx in range(0, int(cell_w * (c1 - c0))) for yy in range(y - 6, y + 7))
    named, rgb, table = brightest(1, 19), brightest(31, 49), brightest(61, 79)
    assert rgb > 40, f"the RGB gray is drawn ({rgb})"
    assert named > rgb + 12, f"the named gray is raised ({named}) and the RGB one isn't ({rgb})"
    assert named < 170, f"only as far as 4.5:1 needs, not to white ({named})"
    assert 40 < table < rgb + 8, f"the 256-color gray #5F5F5F keeps its color ({table}; RGB #616161: {rgb})"


# ---- S-5: font, rows and padding --------------------------------------------------------------------

@pytest.mark.req("S-5")
def test_the_font_is_hack_13_with_rows_1_2_times_its_size(inst, win):
    pane = win["pane"]
    active(inst, pane)
    t = terminal(inst, pane)
    assert "Hack" in t["font"], t["font"]
    assert t["font_pt"] == 13, t
    # 1.2 x 13 = 15.6 points; rows come in whole pixels.
    assert 15.3 <= t["cell_pt"][1] <= 15.9, t["cell_pt"]


@pytest.mark.req("S-5")
def test_a_font_family_in_the_config_replaces_hack(fresh, tmp_path):
    config = tmp_path / "xdg" / "umi"
    config.mkdir(parents=True)
    (config / "config").write_text("font-family = Menlo\n")
    other = fresh(prefix="acc-font-", env={"XDG_CONFIG_HOME": str(tmp_path / "xdg")})
    pane = other.json("window", "new", "--name", "font")["pane"]
    active(other, pane)
    assert "Menlo" in terminal(other, pane)["font"]


@pytest.mark.req("S-5")
def test_padding_is_16_either_side_and_20_below_the_prompt(inst, win):
    pane = win["pane"]
    active(inst, pane)
    t = terminal(inst, pane)
    pad = t["padding_pt"]
    assert abs(pad["left"] - 16) < 0.6, pad
    assert abs(pad["bottom"] - 20) < 0.6, pad
    # What doesn't divide into rows and columns goes above the first row and right of the last column.
    assert 10 - 0.6 <= pad["top"] < 10 + t["cell_pt"][1], pad
    assert 16 - 0.6 <= pad["right"] < 16 + t["cell_pt"][0], pad


@pytest.mark.req("S-5", "S-12")
def test_full_screen_programs_get_the_pane_without_padding(inst, win):
    pane = win["pane"]
    active(inst, pane)
    before = terminal(inst, pane)
    inst.cli("send", "--pane", pane, "-e", "printf '\\033[?1049h'; sleep 5; printf '\\033[?1049l'")
    full = wait_until(lambda: (lambda t: t if t["screen"] == "alternate" and t["padding_pt"]["left"] < 0.6 else None)(
        terminal(inst, pane)), 10, message="the full-screen program without padding")
    # As in Warp, the grid starts at the pane's top left corner; what doesn't divide into rows and
    # columns stays below and right of it.
    assert full["padding_pt"]["top"] < 0.6, full["padding_pt"]
    assert full["padding_pt"]["bottom"] < full["cell_pt"][1], full["padding_pt"]
    assert full["padding_pt"]["right"] < full["cell_pt"][0], full["padding_pt"]
    assert full["cols"] >= before["cols"] + 3 and full["rows"] >= before["rows"] + 1, (before["cols"], full["cols"])
    back = wait_until(lambda: (lambda t: t if t["screen"] == "primary" and abs(t["padding_pt"]["left"] - 16) < 0.6 else None)(
        terminal(inst, pane)), 15, message="the padding back after the program")
    assert back["cols"] == before["cols"] and back["rows"] == before["rows"], (before["cols"], back["cols"])


def _unpadded(inst, pane):
    t = terminal(inst, pane)
    return t if t["screen"] == "alternate" and t["padding_pt"]["left"] < 0.6 else None


def _padded(inst, pane):
    t = terminal(inst, pane)
    return t if t["screen"] == "primary" and abs(t["padding_pt"]["left"] - 16) < 0.6 else None


@pytest.mark.req("S-5", "S-12")
@pytest.mark.parametrize("how", ["ris", "reset_action"])
def test_a_reset_on_the_alternate_screen_brings_the_padding_back(inst, win, how):
    """A full-screen program that crashed leaves the alternate screen on; `reset` (RIS, `\\ec`) or
    Reset Terminal returns to the shell's screen, and its padding."""
    pane = win["pane"]
    active(inst, pane)
    before = terminal(inst, pane)
    if how == "ris":
        inst.cli("send", "--pane", pane, "-e", "printf '\\033[?1049h'; sleep 2; printf '\\033c'")
        wait_until(lambda: _unpadded(inst, pane), 10, message="the full-screen program without padding")
    else:
        inst.cli("send", "--pane", pane, "-e", "printf '\\033[?1049h'; sleep 60")
        wait_until(lambda: _unpadded(inst, pane), 10, message="the full-screen program without padding")
        assert inst.rpc("debug.terminal.action", pane=pane, action="reset")["ok"]
    # (The padding is set at once; the terminal takes its new size on its own thread.)
    back = wait_until(lambda: (lambda t: t if t and (t["cols"], t["rows"]) == (before["cols"], before["rows"]) else None)(
        _padded(inst, pane)), 10, message="the padding and the shell's size back after the reset")
    assert abs(back["padding_pt"]["bottom"] - 20) < 0.6, back["padding_pt"]
    if how == "reset_action":
        inst.cli("keys", "--pane", pane, "ctrl+c")


@pytest.mark.req("S-5", "S-12")
def test_turning_the_option_on_while_a_full_screen_program_runs_brings_the_padding_back(fresh, tmp_path):
    """window-padding-alternate-screen = true, set in the config and reloaded while the program runs,
    takes effect at once."""
    config = tmp_path / "xdg" / "umi"
    config.mkdir(parents=True)
    (config / "config").write_text("window-padding-alternate-screen = false\n")
    other = fresh(prefix="acc-altpad-", env={"XDG_CONFIG_HOME": str(tmp_path / "xdg")})
    pane = other.json("window", "new", "--name", "altpad")["pane"]
    active(other, pane)
    other.cli("send", "--pane", pane, "-e", "printf '\\033[?1049h'; sleep 60")
    wait_until(lambda: _unpadded(other, pane), 10, message="the full-screen program without padding")
    (config / "config").write_text("window-padding-alternate-screen = true\n")
    assert other.rpc("debug.terminal.action", pane=pane, action="reload_config")["ok"]
    padded = wait_until(lambda: (lambda t: t if t["screen"] == "alternate" and abs(t["padding_pt"]["left"] - 16) < 0.6
                                 else None)(terminal(other, pane)), 10, message="the padding back on the alternate screen")
    assert padded["padding_pt"]["top"] >= 0.6, padded["padding_pt"]
    other.cli("keys", "--pane", pane, "ctrl+c")


# ---- S-5: the cursor --------------------------------------------------------------------------------

@pytest.mark.req("S-5")
def test_the_cursor_is_a_3_point_bar_as_tall_as_a_row(inst, win):
    pane = win["pane"]
    active(inst, pane)
    t = terminal(inst, pane)
    assert abs(t["cursor_pt"][0] - 3) < 0.01, t["cursor_pt"]
    assert abs(t["cursor_pt"][1] - t["cell_pt"][1]) < 1, (t["cursor_pt"], t["cell_pt"])


@pytest.mark.req("S-5")
def test_the_cursor_is_cyan_with_round_ends_ui(inst, win, ui, tmp_path):
    """The bar cursor in Warp's accent (#19AAD8), 3 points wide, its ends rounded: its first and last
    pixel rows are narrower than its middle."""
    pane = win["pane"]
    active(inst, pane)
    inst.cli("window", "focus", win["window"])
    ui.activate()
    time.sleep(0.5)
    cyan = (0x19, 0xAA, 0xD8)
    found = None
    b = blocks(inst, pane)
    for i in range(12):  # the cursor blinks
        shot = Shot(inst, win, tmp_path / f"cursor{i}.png")
        # At the start of the empty command line: the pane's left columns, its lower part.
        x1 = shot.left + int((b["padding_pt"]["left"] + 4 * b["cell_pt"][0]) * shot.scale)
        pixels = [(x, y) for y in range(int(shot.h * 0.5), shot.h) for x in range(shot.left, x1)
                  if near(shot.px(x, y), cyan, 40)]
        if len(pixels) > 20:
            found = (shot, pixels)
            break
        time.sleep(0.25)
    assert found, "the cursor is drawn in #19AAD8"
    shot, pixels = found
    ys = sorted({y for _, y in pixels})
    xs = sorted({x for x, _ in pixels})
    height, width = ys[-1] - ys[0] + 1, xs[-1] - xs[0] + 1
    assert abs(width - 3 * shot.scale) <= 2, f"3 points wide: {width} px at {shot.scale}x"
    assert abs(height - b["cell_pt"][1] * shot.scale) <= 3, f"a row tall: {height} px"
    widths = {y: sum(1 for _, yy in pixels if yy == y) for y in ys}
    middle = widths[ys[len(ys) // 2]]
    assert widths[ys[0]] < middle and widths[ys[-1]] < middle, f"round ends: {widths[ys[0]]}, {middle}, {widths[ys[-1]]}"


# ---- S-5: scrollbar and bell ---------------------------------------------------------------------------

@pytest.mark.req("S-5")
def test_the_scrollbar_is_warps_thumb_without_a_track(inst, win, tmp_path):
    """With scrollback, scrolled up a page: the scrollbar as AppKit draws it (`debug.terminal.scroller`;
    the window's screenshot draws the terminal over it) is an overlay scroller showing one rounded
    thumb 8 points wide, 2 points in from the pane's right edge, white at 40% over #050505 (#696969),
    and nothing above or below it (no track)."""
    pane = win["pane"]
    active(inst, pane)
    run(inst, pane, "seq 1 400")
    assert inst.rpc("debug.terminal.action", pane=pane, action="scroll_page_up")["ok"]
    s = wait_until(lambda: (lambda x: x if x["value"] < 0.99 else None)(terminal(inst, pane)["scroller"]), 5,
                   message="the view scrolled up")
    assert s["class"] == "UmiScroller", s
    assert s["style"] == "overlay" and s["hidden"] is False, s
    assert 0 < s["knob_proportion"] < 1, s
    assert s["ink"] == [1, 1, 1], "the text color on the dark background"
    assert s["thumb_attached"] is True, s
    thumb = (0x69, 0x69, 0x69)
    bg = (5, 5, 5)
    # The image as on screen: the thumb fades out a second after scrolling, so scroll and take it
    # at once (again if it was taken mid-fade).
    for attempt in range(3):
        if attempt:
            inst.rpc("debug.terminal.action", pane=pane, action="scroll_page_down")
            inst.rpc("debug.terminal.action", pane=pane, action="scroll_page_up")
        info = inst.rpc("debug.terminal.scroller", pane=pane, path=str(tmp_path / "scroller.png"))
        w, h, buf = load_png(tmp_path / "scroller.png")
        scale = w / info["width_pt"]

        def px(x, y):
            i = (y * w + x) * 4
            return tuple(buf[i:i + 3])
        # The thumb's column: its middle, 6 points in from the right edge.
        cx = w - int(6 * scale)
        lit = [y for y in range(h) if near(px(cx, y), thumb, 12)]
        if lit:
            break
    assert lit, f"a #696969 thumb: column {[px(cx, y) for y in range(0, h, max(1, h // 8))]}"
    top, bottom = min(lit), max(lit)
    assert len(lit) == bottom - top + 1, "one thumb"
    assert bottom - top + 1 >= 20 * scale, f"a thumb, not a speck: {bottom - top + 1} px"
    # No track: the column above and below the thumb is the background.
    outside = [y for y in range(h) if y < top - 2 * scale or y > bottom + 2 * scale]
    assert outside, "the thumb doesn't fill the scrollbar"
    assert all(near(px(cx, y), bg, 3) for y in outside), "no track above or below the thumb"
    # 8 points wide, 2 points from the right edge.
    mid = (top + bottom) // 2
    row = [x for x in range(w) if near(px(x, mid), thumb, 12)]
    assert abs(len(row) - 8 * scale) <= 1, f"8 points wide: {len(row)} px at {scale}x"
    assert abs((w - 1 - max(row)) - 2 * scale) <= 1, f"2 points from the edge: {w - 1 - max(row)} px"
    assert all(near(px(x, mid), bg, 3) for x in range(max(row) + 1, w)), "nothing right of the thumb"
    # Round ends: the thumb's first pixel row is narrower than its middle.
    end = [x for x in range(w) if not near(px(x, top), bg, 8)]
    assert len(end) < len(row), f"round ends: {len(end)} px at the top, {len(row)} in the middle"


@pytest.mark.req("S-5")
def test_the_bell_is_silent(inst, win):
    pane = win["pane"]
    active(inst, pane)
    bell = terminal(inst, pane)["bell"]
    assert not any(bell.values()), f"no sound, Dock bounce, badge, title mark or border: {bell}"
    run(inst, pane, "printf '\\a'")
    time.sleep(1)
    assert inst.rpc("debug.dock_badge")["badge"] == "", "no Dock badge"


# ---- S-10: blocks ----------------------------------------------------------------------------------------

@pytest.mark.req("S-10")
def test_ctrl_c_and_sigpipe_count_as_success_as_in_warp(inst, win):
    pane = win["pane"]
    active(inst, pane)
    assert run(inst, pane, "sh -c 'exit 130'")["failed"] is False
    assert run(inst, pane, "sh -c 'kill -PIPE $$'")["failed"] is False
    inst.cli("send", "--pane", pane, "-e", "sleep 30")
    wait_until(lambda: blocks(inst, pane)["blocks"][-1]["state"] == "running", 10, message="sleep to run")
    inst.cli("keys", "--pane", pane, "ctrl+c")
    stopped = wait_until(lambda: next((x for x in blocks(inst, pane)["blocks"]
                                       if x["command"] == "sleep 30" and x["state"] == "done"), None), 10,
                         message="the stopped command's block")
    assert stopped["failed"] is False, stopped
    assert run(inst, pane, "sh -c 'exit 2'")["failed"] is True, "other errors still mark the block"


@pytest.mark.req("S-10")
def test_a_running_command_shows_no_time_before_a_second(inst, win):
    pane = win["pane"]
    active(inst, pane)
    inst.cli("send", "--pane", pane, "-e", "sleep 3")
    sent = time.monotonic()
    early = []
    while time.monotonic() - sent < 0.8:
        last = blocks(inst, pane)["blocks"][-1]
        if last["state"] == "running" and time.monotonic() - sent < 0.8:
            early.append(last)
        time.sleep(0.05)
    assert early, "the block was seen running in its first second"
    assert all(x["ms"] is None and "duration" not in x for x in early), early
    later = wait_until(lambda: (lambda x: x if x["state"] == "running" and x["ms"] is not None else None)(
        blocks(inst, pane)["blocks"][-1]), 5, message="the time after a second")
    assert later["ms"] >= 1000 and later["duration"] in ("(1s)", "(2s)"), later


def _git(*args, cwd):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True,
                   capture_output=True)


@pytest.mark.req("S-10")
def test_the_header_adds_the_git_branch_as_warp(inst, win, tmp_path):
    pane = win["pane"]
    active(inst, pane)
    repo = tmp_path / "repo"
    repo.mkdir()
    _git("init", "-q", "-b", "feature-x", cwd=repo)
    run(inst, pane, f"cd '{repo}'")
    block = run(inst, pane, "true")
    assert block["header"].endswith("repo"), block
    assert block["header_line"] == block["header"] + " git:(feature-x)", block
    # Not on a branch: the commit.
    _git("commit", "-q", "--allow-empty", "-m", "one", cwd=repo)
    _git("checkout", "-q", "--detach", cwd=repo)
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    run(inst, pane, "true")
    detached = run(inst, pane, ": detached")
    assert detached["header_line"] == detached["header"] + f" git:({commit})", detached
    # Outside a repository: the folder alone.
    run(inst, pane, "cd /usr/bin")
    plain = run(inst, pane, ": plain")
    assert plain["header_line"] == plain["header"] == "/usr/bin", plain


@pytest.mark.req("S-10")
def test_a_branch_name_is_shown_and_never_run_with_prompt_subst(inst, win, tmp_path):
    """oh-my-zsh and powerlevel10k turn on prompt_subst, which runs `$(...)` in the prompt each time zsh
    draws it: a branch named `$(touch${IFS}pwned)` is shown as it is and runs nothing."""
    pane = win["pane"]
    active(inst, pane)
    repo = tmp_path / "repo"
    repo.mkdir()
    branch = "$(touch${IFS}pwned)`touch${IFS}tick`"
    _git("init", "-q", "-b", branch, cwd=repo)
    run(inst, pane, "setopt prompt_subst")
    run(inst, pane, f"cd '{repo}'")
    block = run(inst, pane, ": subst")
    after = run(inst, pane, ": again")
    assert not (repo / "pwned").exists() and not (repo / "tick").exists(), "the branch's name ran"
    for x in (block, after):
        assert x["header_line"] == x["header"] + f" git:({branch})", x
    run(inst, pane, "unsetopt prompt_subst")
    plain = run(inst, pane, ": plain")
    assert plain["header_line"] == plain["header"] + f" git:({branch})", plain


@pytest.mark.req("S-10")
def test_the_header_adds_conda_venv_and_user_at_host_over_ssh(inst, win):
    pane = win["pane"]
    active(inst, pane)
    run(inst, pane, "cd /usr/bin")
    marker = uuid.uuid4().hex[:6]
    inst.cli("send", "--pane", pane, "-e", f"print -P 'U{marker}=%n@%m'")
    who = wait_until(lambda: re.search(rf"^U{marker}=(\S+)$", inst.cli("read", "--pane", pane).stdout, re.M), 10,
                     message="user@host").group(1)
    run(inst, pane, "export CONDA_DEFAULT_ENV=base VIRTUAL_ENV=/opt/envs/myenv SSH_CONNECTION='10.0.0.1 5000 10.0.0.2 22'")
    block = run(inst, pane, ": remote")
    assert block["header_line"] == f"(base) (myenv) {who}:/usr/bin", block
    assert block["header"] == "/usr/bin", "the folder alone"
    run(inst, pane, "unset CONDA_DEFAULT_ENV VIRTUAL_ENV SSH_CONNECTION")
    assert run(inst, pane, ": local")["header_line"] == "/usr/bin"


# ---- S-11: the folder box ------------------------------------------------------------------------------

@pytest.mark.req("S-11")
def test_the_box_shows_the_folder_alone_cut_at_40_characters(inst, win, tmp_path):
    """The prompt's row holds the whole header line (the folder and ` git:(…)`), but the box shows only
    the folder, its last 39 characters after an ellipsis when it is longer than 40 (Warp's chip)."""
    pane = win["pane"]
    b = active(inst, pane)
    deep = tmp_path / "a-folder-name-long-enough" / "to-pass-forty-characters"
    deep.mkdir(parents=True)
    _git("init", "-q", "-b", "main", cwd=deep)
    run(inst, pane, f"cd '{deep}'")
    b = active(inst, pane)
    prompt = b["blocks"][-1]
    assert prompt["header_line"] == prompt["header"] + " git:(main)", prompt
    assert len(prompt["header"]) > 50, f"the pane is wide enough for a long folder: {prompt['header']!r}"
    time.sleep(0.5)
    shot = Shot(inst, win, tmp_path / "box.png")
    y = row_y(shot, inst, win, b, prompt["first"] + 2)
    cell_w = b["cell_pt"][0] * shot.scale
    pad = b["padding_pt"]["left"] * shot.scale
    ink = [x for x in range(shot.left, shot.w - 2) for yy in range(y - 5, y + 6) if shot.differs(shot.px(x, yy), 60)]
    assert ink, "the box's text is drawn on the prompt's folder row"
    right = (max(ink) - shot.left - pad) / cell_w
    # The box: border, padding, icon (1.5 cells) and gap, then 40 characters.
    assert 38 < right < 46, f"the box's text ends after 40 characters ({right:.1f} cells), not after the whole line"


@pytest.mark.req("S-11")
def test_the_box_text_is_bold(inst, win, tmp_path):
    """The folder in the box is drawn heavier than the same folder in a block's header once the
    command ran (regular weight): more of its pixels are over half the row's brightest."""
    pane = win["pane"]
    active(inst, pane)
    folder = "/tmp/" + "W" * 30
    os.makedirs(folder, exist_ok=True)
    run(inst, pane, f"cd {folder}")
    ran = run(inst, pane, ": weight")
    b = active(inst, pane)
    prompt = b["blocks"][-1]
    assert prompt["header"] == folder and ran["header"] == folder, (prompt, ran)
    time.sleep(0.5)
    shot = Shot(inst, win, tmp_path / "weight.png")
    cell_w = b["cell_pt"][0] * shot.scale
    pad = b["padding_pt"]["left"] * shot.scale
    dx = b["box_text_dx_pt"] * shot.scale

    def heavy(row, shift):
        """Pixels over half the brightest of the W's (columns 6 to 34) on viewport row `row`."""
        y = row_y(shot, inst, win, b, row)
        x0, x1 = int(shot.left + pad + shift + cell_w * 6), int(shot.left + pad + shift + cell_w * 34)
        pixels = [max(shot.px(x, yy)) for x in range(x0, x1) for yy in range(y - 6, y + 7)]
        top = max(pixels)
        assert top > 60, f"text on row {row}"
        return sum(1 for v in pixels if v > (top + 5) / 2)
    box, header = heavy(prompt["first"] + 2, dx), heavy(ran["first"] + 2, 0)
    assert box > header * 1.1, f"the box's text drawn bold: {box} heavy pixels against {header} in the header"
