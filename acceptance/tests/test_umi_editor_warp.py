"""The file editor as Warp's (SPEC E-4, E-21 to E-24): the code view, find and replace, the editor's
keys, the header menu and the chips. Keys are pressed as a person would; what they did is read back
from the files, the CLI, the accessibility tree and Umi's internal `debug.ui.editor`."""

import os
import subprocess
import time

import pytest

from harness import wait_until
from test_umi_blocks import load_png

pytestmark = pytest.mark.editor

# Key codes (Carbon) and modifier flags (CGEventFlags).
K_G, K_F, K_SLASH, K_S, K_RETURN, K_ESC = 5, 3, 44, 1, 36, 53
CMD, SHIFT, CTRL, OPT = 1 << 20, 1 << 17, 1 << 18, 1 << 19


def open_file(inst, win, path):
    """Open a file beside the window's terminal; its pane's id."""
    out = inst.json("edit", str(path), "--pane", win["pane"])
    return out["documents"][0]["pane"]


def ed(inst, pane, **params):
    return inst.rpc("debug.ui.editor", pane=pane, **params)


def text_of(inst, pane):
    return inst.rpc("debug.editor.type", pane=pane, path=ed(inst, pane)["path"])["text"]


def set_text(inst, pane, text):
    """Replace the document's text (as edits would)."""
    inst.rpc("debug.editor.type", pane=pane, path=ed(inst, pane)["path"], text=text, replace=True)


def type_into_focused(ui, text):
    """Select what the focused field holds and type over it, key by key."""
    ui.key(0, CMD)   # ⌘A
    ui.type_text(text)
    time.sleep(0.3)


def focus(inst, ui, pane):
    inst.cli("pane", "focus", pane)
    ui.activate()
    wait_until(lambda: ed(inst, pane)["editor_focused"], 5, message="the editor has keyboard focus")


def open_menu_titles(ui):
    """The titles of the open pop-up menu's items, in order ([] when none is open)."""
    menus = ui.find_all(lambda e: ui.role(e) == "AXMenu")
    return [ui.label(i) for m in menus for i in (ui.attr(m, "AXChildren") or [])
            if ui.role(i) == "AXMenuItem" and ui.label(i)]


def open_menu_item(ui, title):
    for m in ui.find_all(lambda e: ui.role(e) == "AXMenu"):
        for i in ui.attr(m, "AXChildren") or []:
            if ui.label(i) == title:
                return i
    raise AssertionError(f"no open menu item {title!r}")


def pbpaste():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def frame(ui, element):
    """(x, y, width, height) in screen points, top-left origin."""
    import ApplicationServices as AX  # noqa: N812
    p = AX.AXValueGetValue(ui.attr(element, "AXPosition"), AX.kAXValueCGPointType, None)[1]
    z = AX.AXValueGetValue(ui.attr(element, "AXSize"), AX.kAXValueCGSizeType, None)[1]
    return p.x, p.y, z.width, z.height


def right_click(rect):
    """A real right-click in the middle of rect."""
    import Quartz
    x, y, w, h = rect
    point = (x + w / 2, y + h / 2)
    for kind in (Quartz.kCGEventMouseMoved, Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp):
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, kind, point, Quartz.kCGMouseButtonRight))
        time.sleep(0.1)


def window_of(ui, element):
    while element is not None and ui.role(element) != "AXWindow":
        element = ui.attr(element, "AXParent")
    return element


def editor_group(ui, name):
    """The file pane ("Editor") whose header shows this file's name."""
    for group in ui.find_all(lambda e: ui.label(e) == "Editor"):
        if header_title(ui, name, group) is not None:
            return group
    return None


def header_title(ui, name, root=None):
    if root is None:
        root = editor_group(ui, name)
    return ui.find(lambda e: ui.role(e) == "AXStaticText" and name in (ui.label(e), ui.value(e)), root)


def caret_to_start(inst, ui, pane):
    """Put the caret at the start of the text with ⌘↑."""
    ui.key(126, CMD)
    wait_until(lambda: ed(inst, pane)["selection"] == [0, 0], 5, message="the caret at the start")


@pytest.fixture
def code(tmp_path):
    path = tmp_path / "sample.py"
    path.write_text("def f():\n    return 'a'  # note\n\nfoo = 1\nFoo = 2\nfoo2 = 3\n")
    return path


@pytest.mark.req("E-21")
def test_code_view_has_the_terminal_font_line_numbers_and_no_wrap(inst, win, code):
    pane = open_file(inst, win, code)
    state = wait_until(lambda: (s := ed(inst, pane)) and "wraps" in s and s, 10, message="the code view")
    assert state["wraps"] is False, "long lines scroll sideways"
    assert state["line_numbers"] is True and state["gutter_width"] == 94
    assert state["font_size"] == 13, f"the terminal's size (Umi's default 13): {state['font_size']}"
    assert not state["font_family"].startswith("."), f"the terminal's font, not the system's: {state['font_family']}"
    assert state["line_count"] == 7 and state["current_line"] == 1


@pytest.mark.req("E-21")
def test_syntax_colors_come_from_the_terminal_palette(inst, win, code):
    pane = open_file(inst, win, code)
    state = wait_until(lambda: (s := ed(inst, pane)).get("highlighted") and s, 10, message="syntax colors")
    palette = state["palette"]
    assert state["language"] == "python"
    assert ed(inst, pane, line=1, column=1)["color_at"] == palette[5], "keywords are magenta"
    assert ed(inst, pane, line=1, column=5)["color_at"] == palette[4], "function names are blue"
    assert ed(inst, pane, line=2, column=12)["color_at"] == palette[2], "strings are green"
    assert ed(inst, pane, line=2, column=18)["color_at"] == palette[3], "comments are yellow"
    assert ed(inst, pane, line=4, column=1)["color_at"] == state["text_color"], "plain names keep the text color"


@pytest.mark.req("E-21")
def test_marks_show_changes_against_the_last_commit(inst, win, tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    path = repo / "list.txt"
    path.write_text("a\nb\nc\nd\ne\n")
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    for args in (["init", "-q"], ["add", "."], ["commit", "-qm", "base"]):
        subprocess.run(["git", "-C", str(repo), *args], check=True, env=env)
    pane = open_file(inst, win, path)
    time.sleep(1)
    assert ed(inst, pane)["diff_marks"] == {}, "an unchanged file has no marks"
    # "a" changed, "c" removed (marked on the line after), "f" added.
    set_text(inst, pane, "A\nb\nd\ne\nf\n")
    marks = wait_until(lambda: (m := ed(inst, pane)["diff_marks"]) and m, 10, message="marks")
    assert marks == {"1": "changed", "3": "removed", "5": "added"}, marks


@pytest.mark.req("E-23")
def test_ctrl_g_goes_to_a_line_and_column(inst, win, code, ui):
    pane = open_file(inst, win, code)
    focus(inst, ui, pane)
    assert ui.menu_item("Go to Line") is not None, "Go to Line… is a menu item"
    ui.key(K_G, CTRL)
    wait_until(lambda: ed(inst, pane)["go_to_line"]["focused"], 5, message="⌃G opens Go to line, focused")
    assert "Go to line" in ui.all_text()
    type_into_focused(ui, "abc")
    ui.key(K_RETURN)
    wait_until(lambda: ed(inst, pane)["go_to_line"]["error"] == "Please enter a valid line number", 5,
               message="Warp's message for a bad line")
    type_into_focused(ui, "4:3")
    ui.key(K_RETURN)
    state = wait_until(lambda: (s := ed(inst, pane))["current_line"] == 4 and s, 5, message="on line 4")
    assert state["selection"] == [len("def f():\n    return 'a'  # note\n\n") + 2, 0], "column 3"
    assert not state["go_to_line"]["open"] and state["editor_focused"]
    ui.key(K_G, CTRL)
    wait_until(lambda: ed(inst, pane)["go_to_line"]["focused"], 5, message="open again")
    ui.key(K_ESC)
    wait_until(lambda: not ed(inst, pane)["go_to_line"]["open"], 5, message="Esc closes it")
    assert ed(inst, pane)["editor_focused"]


@pytest.mark.req("E-23")
def test_ctrl_g_still_reaches_a_terminal(inst, win, ui):
    inst.cli("pane", "focus", win["pane"])
    ui.activate()
    inst.type_line(win["pane"], "cat -v")
    time.sleep(0.8)
    ui.key(K_G, CTRL)
    ui.key(K_RETURN)
    wait_until(lambda: "^G" in inst.screen(win["pane"]), 5, message="⌃G reached the terminal")
    ui.key(8, CTRL)   # ⌃C
    time.sleep(0.3)


@pytest.mark.req("E-22")
def test_cmd_f_opens_the_editors_own_find(inst, win, code, ui):
    pane = open_file(inst, win, code)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    ui.key(K_F, CMD)
    wait_until(lambda: ed(inst, pane)["find"]["focused"], 5, message="⌘F opens the editor's find, focused")
    field = ui.focused_input()
    assert field is not None and ui.label(field) == "Find"
    type_into_focused(ui, "foo")
    find = wait_until(lambda: (f := ed(inst, pane)["find"])["matches"] == 3 and f, 5, message="three matches")
    assert find["count"] == "1/3"
    ui.key(K_RETURN)
    wait_until(lambda: ed(inst, pane)["find"]["count"] == "2/3", 5, message="Enter goes to the next match")
    ui.key(K_RETURN, SHIFT)
    wait_until(lambda: ed(inst, pane)["find"]["count"] == "1/3", 5, message="Shift-Enter goes back")
    ui.key(K_G, CMD)
    wait_until(lambda: ed(inst, pane)["find"]["count"] == "2/3", 5, message="⌘G goes to the next match")
    ui.key(K_G, CMD | SHIFT)
    wait_until(lambda: ed(inst, pane)["find"]["count"] == "1/3", 5, message="⇧⌘G goes back")
    ui.key(K_G, CMD | SHIFT)
    wait_until(lambda: ed(inst, pane)["find"]["count"] == "3/3", 5, message="and wraps around")
    state = ed(inst, pane)
    start = "def f():\n    return 'a'  # note\n\nfoo = 1\nFoo = 2\n"
    assert state["selection"] == [len(start), 0], "the caret is at the match's start, as Warp puts it"
    # Case-sensitive and regex toggles.
    ui.press(ui.button("Case sensitive search"))
    wait_until(lambda: ed(inst, pane)["find"]["matches"] == 2, 5, message="case-sensitive: two matches")
    ui.press(ui.button("Regex toggle"))
    ui.focus(field)
    type_into_focused(ui, r"fo+\d")
    wait_until(lambda: ed(inst, pane)["find"]["matches"] == 1, 5, message="regex: one match")
    ui.focus(field)
    ui.key(K_ESC)
    state = wait_until(lambda: (s := ed(inst, pane)) and not s["find"]["open"] and s, 5, message="Esc closes the bar")
    assert state["editor_focused"], "back to the text"


@pytest.mark.req("E-22")
def test_cmd_f_in_a_terminal_still_searches_the_terminal(inst, win, ui):
    inst.cli("pane", "focus", win["pane"])
    ui.activate()

    def fields():
        return ui.find_all(lambda e: ui.role(e) == "AXTextField")

    before = len(fields())
    ui.key(K_F, CMD)
    wait_until(lambda: len(fields()) > before, 5, message="⌘F opens the terminal's search field")
    ui.key(K_ESC)
    wait_until(lambda: len(fields()) == before, 5, message="Esc closes it")


@pytest.mark.req("E-22")
def test_replace_one_replace_all_and_preserve_case(inst, win, tmp_path, ui):
    path = tmp_path / "words.txt"
    path.write_text("foo Foo FOO foo\n")
    pane = open_file(inst, win, path)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    assert ui.menu_item("Find and Replace") is not None
    ui.key(K_F, CMD | OPT)
    wait_until(lambda: ed(inst, pane)["find"]["replace_open"], 5, message="⌥⌘F opens the replace row")
    wait_until(lambda: (f := ui.focused()) is not None and ui.label(f) == "Replace", 5,
               message="the replacement is focused")
    find_field = ui.find(lambda e: ui.role(e) == "AXTextField" and ui.label(e) == "Find")
    ui.focus(find_field)
    type_into_focused(ui, "foo")
    wait_until(lambda: ed(inst, pane)["find"]["matches"] == 4, 5, message="four matches, any case")
    replace_field = ui.find(lambda e: ui.role(e) == "AXTextField" and ui.label(e) == "Replace")
    ui.focus(replace_field)
    type_into_focused(ui, "bar")
    ui.key(K_RETURN)
    wait_until(lambda: text_of(inst, pane).startswith("bar Foo"), 5, message="Enter replaces the selected match")
    ui.press(ui.button("Preserve case"))
    ui.press(ui.button("Replace all"))
    wait_until(lambda: text_of(inst, pane) == "bar Bar BAR bar\n", 5, message="Replace all keeps each match's case")
    ui.key(K_ESC)
    focus(inst, ui, pane)
    ui.key(6, CMD)   # ⌘Z: Replace all is one undo step
    wait_until(lambda: text_of(inst, pane) == "bar Foo FOO foo\n", 5, message="one undo step")


@pytest.mark.req("E-23")
def test_cmd_slash_toggles_comments_by_language(inst, win, tmp_path, ui):
    path = tmp_path / "code.py"
    path.write_text("    x = 1\n    y = 2\n")
    pane = open_file(inst, win, path)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    ui.key(K_SLASH, CMD)
    wait_until(lambda: text_of(inst, pane) == "    # x = 1\n    y = 2\n", 5, message="⌘/ comments the line")
    ui.key(0, CMD)   # ⌘A
    ui.key(K_SLASH, CMD)
    wait_until(lambda: text_of(inst, pane) == "    # # x = 1\n    # y = 2\n", 5,
               message="not every line was commented: all get the prefix")
    ui.key(K_SLASH, CMD)
    wait_until(lambda: text_of(inst, pane) == "    # x = 1\n    y = 2\n", 5, message="all commented: uncomment")
    swift = tmp_path / "code.swift"
    swift.write_text("let a = 1\n")
    other = open_file(inst, win, swift)
    focus(inst, ui, other)
    caret_to_start(inst, ui, other)
    ui.key(K_SLASH, CMD)
    wait_until(lambda: text_of(inst, other) == "// let a = 1\n", 5, message="Swift's prefix")


@pytest.mark.req("E-23")
def test_save_shows_a_toast_and_save_as_moves_the_pane_to_the_new_file(inst, win, tmp_path, ui):
    path = tmp_path / "draft.txt"
    path.write_text("first\n")
    pane = open_file(inst, win, path)
    set_text(inst, pane, "second\n")
    focus(inst, ui, pane)
    ui.key(K_S, CMD)
    wait_until(lambda: path.read_text() == "second\n", 5, message="⌘S saved")
    state = ed(inst, pane)
    assert state["toast"] == "File saved." and state["toast_showing"]
    assert "File saved." in ui.all_text()
    wait_until(lambda: not ed(inst, pane)["toast_showing"], 8, message="the toast goes after 4 s")
    # ⇧⌘S: the save panel, a new name, Return.
    set_text(inst, pane, "third\n")
    focus(inst, ui, pane)
    ui.key(K_S, CMD | SHIFT)
    name_field = wait_until(lambda: ui.find(lambda e: ui.role(e) == "AXTextField" and ui.value(e) == "draft.txt"),
                            10, message="the save panel")
    ui.enter_text("final.txt", element=name_field, replace=True)
    ui.press(wait_until(lambda: ui.button("Save"), 5, message="the panel's Save button"))
    final = tmp_path / "final.txt"
    wait_until(lambda: final.exists() and final.read_text() == "third\n", 10, message="saved under the new name")
    assert path.read_text() == "second\n", "the old file keeps what it had"
    wait_until(lambda: os.path.realpath(ed(inst, pane)["path"]) == os.path.realpath(final), 5,
               message="the pane shows the new file")
    assert not ed(inst, pane)["dirty"]


@pytest.mark.req("E-4")
def test_disk_change_banner_uses_warps_words(inst, win, tmp_path, ui):
    path = tmp_path / "conflict.txt"
    path.write_text("disk one\n")
    pane = open_file(inst, win, path)
    set_text(inst, pane, "mine\n")
    time.sleep(0.5)
    path.write_text("disk two\n")
    wait_until(lambda: ed(inst, pane)["changed_on_disk"], 10, message="the disk changed under edits")
    wait_until(lambda: "This file has saved changes that are not reflected here." in ui.all_text(), 5,
               message="Warp's wording")
    assert ui.button("Discard this version") is not None
    ui.press(ui.button("Overwrite"))
    wait_until(lambda: path.read_text() == "mine\n", 5, message="Overwrite saves the edits over the disk")
    assert not ed(inst, pane)["changed_on_disk"]
    set_text(inst, pane, "mine again\n")
    time.sleep(0.5)
    path.write_text("disk three\n")
    wait_until(lambda: ui.button("Discard this version") is not None, 10, message="the banner again")
    ui.press(ui.button("Discard this version"))
    wait_until(lambda: text_of(inst, pane) == "disk three\n", 5, message="Discard takes the disk's file")
    assert not ed(inst, pane)["dirty"]


@pytest.mark.req("E-24")
def test_header_menu_has_warps_items(inst, win, code, ui):
    pane = open_file(inst, win, code)
    menu = ed(inst, pane)["menu"]
    assert [m["title"] for m in menu] == ["Maximize pane", "Copy file path", "Reveal in Finder"], \
        "Warp's code view menu (Close saved has no meaning with one file per pane)"
    assert all(m["enabled"] for m in menu)
    ed(inst, pane, menu_item="Maximize pane")
    found = inst.find_pane(pane)
    assert found[2]["zoomed"], "Maximize pane zooms it"
    assert ed(inst, pane)["menu"][0]["title"] == "Minimize pane"
    ed(inst, pane, menu_item="Minimize pane")
    assert not inst.find_pane(pane)[2]["zoomed"]
    # The ⋯ button opens the same items; Copy file path puts the path on the pasteboard.
    focus(inst, ui, pane)
    ui.press(ui.find(lambda e: ui.label(e) == "More actions"))
    titles = wait_until(lambda: open_menu_titles(ui), 3, message="the ⋯ menu")
    assert titles == ["Maximize pane", "Copy file path", "Reveal in Finder"], titles
    subprocess.run(["pbcopy"], input=b"before", check=True)
    ui.press(open_menu_item(ui, "Copy file path"))
    wait_until(lambda: os.path.realpath(pbpaste()) == os.path.realpath(code), 5, message="the path on the pasteboard")
    # A right-click on the header opens it too.
    right_click(frame(ui, header_title(ui, code.name)))
    titles = wait_until(lambda: open_menu_titles(ui), 3, message="the header's right-click menu")
    ui.key(K_ESC)
    wait_until(lambda: not open_menu_titles(ui), 3, message="Esc closes the menu")
    assert titles == ["Maximize pane", "Copy file path", "Reveal in Finder"], titles


@pytest.mark.req("E-24")
def test_preview_menu_has_warps_rendered_markdown_items(inst, win, tmp_path, ui):
    path = tmp_path / "notes.md"
    path.write_text("# Notes\n\nfirst\n")
    pane = open_file(inst, win, path)
    state = wait_until(lambda: (s := ed(inst, pane))["mode"] == "preview" and s, 5, message="Markdown opens in preview")
    assert [m["title"] for m in state["menu"]] == ["Maximize pane", "Refresh file", "Open in editor", "Copy file path"]
    # Refresh file asks first when there are unsaved edits.
    set_text(inst, pane, "unsaved\n")
    ed(inst, pane, menu_item="Refresh file")
    ui.press(wait_until(lambda: ui.button("Reload"), 5, message="Refresh asks first"))
    wait_until(lambda: text_of(inst, pane) == path.read_text(), 5, message="refreshed from disk")
    # Open in editor shows the source; there the menu offers the Markdown preview back.
    ed(inst, pane, menu_item="Open in editor")
    state = wait_until(lambda: (s := ed(inst, pane))["mode"] == "source" and s, 5, message="the source view")
    assert [m["title"] for m in state["menu"]] == ["Maximize pane", "Copy file path", "Reveal in Finder",
                                                   "View Markdown preview"]
    focus(inst, ui, pane)
    ui.press(ui.find(lambda e: ui.label(e) == "More actions"))
    wait_until(lambda: "View Markdown preview" in open_menu_titles(ui), 3, message="the ⋯ menu")
    ui.press(open_menu_item(ui, "View Markdown preview"))
    wait_until(lambda: ed(inst, pane)["mode"] == "preview", 5, message="back to the preview")


@pytest.mark.req("E-24")
def test_header_shows_the_unsaved_dot_and_chips_show_type_icons(inst, win, tmp_path, ui):
    long_name = "a-file-with-a-rather-long-name-to-see-the-chip-width-limit-in-action.swift"
    first = tmp_path / long_name
    first.write_text("let a = 1\n")
    second = tmp_path / "second.py"
    second.write_text("b = 2\n")
    one = open_file(inst, win, first)
    two = open_file(inst, win, second)
    inst.rpc("debug.ui.split.drop", pane=two, target=one, zone="center")
    def chip(name):
        strip = ui.find(lambda e: ui.label(e) == "Stacked panes")
        return strip and ui.find(lambda e: ui.label(e) == name and ui.role(e) != "AXStaticText", strip)

    first_chip = wait_until(lambda: chip(long_name), 5, message="the long file's chip")
    wait_until(lambda: chip("second.py"), 5, message="the second file's chip")
    assert ui.attr(first_chip, "AXValue") in (None, ""), "a saved file's chip has no dot"
    set_text(inst, two, "b = 3\n")
    wait_until(lambda: ui.attr(chip("second.py"), "AXValue") == "Unsaved changes", 5,
               message="the unsaved dot in the chip itself")
    x, y, width, height = frame(ui, first_chip)
    assert 200 < width <= 300.5, f"a long name widens the chip past Warp's old 200, up to 300: {width}"
    # The type icon: colored pixels where the chip's icon sits (8 points in, 14 wide), in a screenshot.
    shot = tmp_path / "chips.png"
    inst.cli("screenshot", "--window", win["window"], str(shot))
    w, h, buf = load_png(shot)
    wx, wy, ww, wh = frame(ui, window_of(ui, first_chip))
    scale = w / ww
    colored = 0
    for px in range(int((x - wx + 8) * scale), int((x - wx + 22) * scale)):
        for py in range(int((y - wy + 4) * scale), int((y - wy + height - 4) * scale)):
            r, g, b = buf[(py * w + px) * 4:(py * w + px) * 4 + 3]
            colored += max(r, g, b) - min(r, g, b) > 60
    assert colored > 20, f"the chip draws a colored type icon: {colored} colored pixels"


# ---- Review fixes (2026-11-05) ---------------------------------------------------------------------

def screenshot_of(inst, ui, win, element, path):
    """A window screenshot, and a function giving the color at a screen point."""
    inst.cli("screenshot", "--window", win["window"], str(path))
    w, h, buf = load_png(path)
    wx, wy, ww, wh = frame(ui, window_of(ui, element))
    scale = w / ww
    assert abs(h / scale - wh) < 2, f"the screenshot is the window: {w}x{h} at {scale} vs {ww}x{wh}"

    def px(x, y):
        i = (int((y - wy) * scale) * w + int((x - wx) * scale)) * 4
        return tuple(buf[i:i + 3])
    return scale, px


def gutter_rows(px, scroll, scale, lines):
    """The background, and the screen y of each line number's middle (top to bottom), from the ink
    in the gutter."""
    x, y, _, _ = scroll
    bg = px(x + 47, y + 3)
    rows, run = [], []
    yy = y
    while yy < y + 400 and len(rows) < lines:
        ink = any(max(abs(a - b) for a, b in zip(px(xx, yy), bg)) > 40 for xx in range(int(x + 20), int(x + 80)))
        if ink:
            run.append(yy)
        elif run:
            rows.append((run[0] + run[-1]) / 2)
            run = []
        yy += 1 / scale
    return bg, rows


def code_scroll(ui, name):
    group = editor_group(ui, name)
    return frame(ui, ui.find(lambda e: ui.role(e) == "AXScrollArea", group))


@pytest.mark.req("E-22")
def test_cmd_g_with_the_bar_closed_goes_to_the_nearest_match(inst, win, code, ui):
    pane = open_file(inst, win, code)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    ui.key(K_F, CMD)
    wait_until(lambda: ed(inst, pane)["find"]["focused"], 5, message="find open")
    type_into_focused(ui, "foo")
    wait_until(lambda: ed(inst, pane)["find"]["matches"] == 3, 5, message="three matches")
    ui.key(K_ESC)
    wait_until(lambda: not ed(inst, pane)["find"]["open"], 5, message="closed, the query kept")
    caret_to_start(inst, ui, pane)
    ui.key(K_G, CMD)
    state = wait_until(lambda: (s := ed(inst, pane))["find"]["open"] and s, 5, message="⌘G opens the bar")
    assert state["find"]["count"] == "1/3", f"the first match after the caret, not the second: {state['find']}"
    assert state["selection"] == [len("def f():\n    return 'a'  # note\n\n"), 0]
    ui.key(K_ESC)
    wait_until(lambda: not ed(inst, pane)["find"]["open"], 5, message="closed")
    ui.key(125, CMD)   # ⌘↓: the caret at the end
    ui.key(K_G, CMD | SHIFT)
    wait_until(lambda: (f := ed(inst, pane)["find"])["open"] and f["count"] == "3/3", 5,
               message="⇧⌘G: the last match before the caret")
    ui.key(K_ESC)


@pytest.mark.req("E-22")
def test_regex_replace_expands_templates_with_lookarounds(inst, win, tmp_path, ui):
    path = tmp_path / "look.txt"
    path.write_text("ab cb ab\n")
    pane = open_file(inst, win, path)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    ui.key(K_F, CMD | OPT)
    wait_until(lambda: ed(inst, pane)["find"]["replace_open"], 5, message="the replace row")
    ui.press(ui.button("Regex toggle"))
    ui.focus(ui.find(lambda e: ui.role(e) == "AXTextField" and ui.label(e) == "Find"))
    type_into_focused(ui, "(?<=a)b")
    wait_until(lambda: ed(inst, pane)["find"]["matches"] == 2, 5, message="two b's after an a")
    ui.focus(ui.find(lambda e: ui.role(e) == "AXTextField" and ui.label(e) == "Replace"))
    type_into_focused(ui, "[$0]")
    ui.press(ui.button("Replace all"))
    wait_until(lambda: text_of(inst, pane) == "a[b] cb a[b]\n", 5, message="the template expanded, not '$0'")
    ui.key(K_ESC)


@pytest.mark.req("E-22")
def test_cmd_f_in_a_preview_finds_in_the_source(inst, win, tmp_path, ui):
    # A JSON preview: a Markdown preview has its own find bar (MD-4, test_markdown_warp.py).
    path = tmp_path / "find.json"
    path.write_text('{"title": "some words and more words"}\n')
    pane = open_file(inst, win, path)
    wait_until(lambda: ed(inst, pane)["mode"] == "preview", 5, message="JSON opens in preview")
    inst.cli("pane", "focus", pane)
    ui.activate()
    wait_until(lambda: inst.find_pane(pane)[2]["focused"], 5, message="the preview's pane focused")
    time.sleep(0.5)
    ui.key(K_F, CMD)
    wait_until(lambda: (s := ed(inst, pane))["mode"] == "source" and s.get("find", {}).get("focused"), 5,
               message="⌘F shows the source with the find bar focused")
    type_into_focused(ui, "words")
    wait_until(lambda: ed(inst, pane)["find"]["count"] == "1/2", 5, message="two matches")
    ui.key(K_ESC)


@pytest.mark.req("E-4")
def test_undo_after_discarding_keeps_the_disk_text(inst, win, tmp_path, ui):
    path = tmp_path / "undo.txt"
    path.write_text("disk one\n")
    pane = open_file(inst, win, path)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    ui.type_text("typed ")
    wait_until(lambda: ed(inst, pane)["dirty"], 5, message="edited by typing")
    time.sleep(0.5)
    path.write_text("disk two is longer than the first\n")
    ui.press(wait_until(lambda: ui.button("Discard this version"), 10, message="the banner"))
    wait_until(lambda: text_of(inst, pane) == path.read_text(), 5, message="the disk's text")
    focus(inst, ui, pane)
    ui.key(6, CMD)   # ⌘Z
    time.sleep(0.8)
    assert inst.app_running(), "⌘Z after a discard doesn't crash the app"
    assert text_of(inst, pane) == path.read_text(), "nothing from before the discard comes back"
    assert not ed(inst, pane)["dirty"]


@pytest.mark.req("E-23", "E-9")
def test_save_as_onto_a_file_open_in_another_pane(inst, win, tmp_path):
    a = tmp_path / "a.txt"
    b = tmp_path / "b.txt"
    a.write_text("a one\n")
    b.write_text("b one\n")
    pa = open_file(inst, win, a)
    pb = open_file(inst, win, b)
    set_text(inst, pb, "b unsaved\n")
    set_text(inst, pa, "from a\n")
    with pytest.raises(AssertionError, match="unsaved changes"):
        ed(inst, pa, save_as=str(b))
    assert b.read_text() == "b one\n" and text_of(inst, pb) == "b unsaved\n", "the other pane's edits are kept"
    set_text(inst, pb, "b one\n")
    assert not ed(inst, pb)["dirty"]
    ed(inst, pa, save_as=str(b))
    assert b.read_text() == "from a\n" and a.read_text() == "a one\n"
    wait_until(lambda: text_of(inst, pb) == "from a\n", 5, message="the open pane shows what was saved")
    wait_until(lambda: inst.find_pane(pa) is None, 5, message="the saving pane closed")
    assert inst.find_pane(pb)[2]["focused"], "the file's pane is focused"
    files = [p.get("file") for w in inst.tree()["windows"] for t in w["tabs"] for p in t["panes"]]
    assert sum(1 for f in files if f and os.path.realpath(f) == os.path.realpath(b)) == 1, "one pane shows b.txt"


@pytest.mark.req("E-23")
def test_copy_cut_paste_undo_and_redo_in_the_text(inst, win, code, ui):
    original = code.read_text()
    pane = open_file(inst, win, code)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    ui.key(124, CMD | SHIFT)   # ⇧⌘→: select the first line
    wait_until(lambda: ed(inst, pane)["selection"] == [0, 8], 5, message="the first line selected")
    subprocess.run(["pbcopy"], input=b"before", check=True)
    ui.key(8, CMD)   # ⌘C
    wait_until(lambda: pbpaste() == "def f():", 5, message="⌘C copies the selection")
    ui.key(125, CMD)   # ⌘↓
    ui.key(9, CMD)   # ⌘V
    wait_until(lambda: text_of(inst, pane) == original + "def f():", 5, message="⌘V pastes it")
    ui.key(6, CMD)   # ⌘Z
    wait_until(lambda: text_of(inst, pane) == original, 5, message="⌘Z undoes the paste")
    ui.key(6, CMD | SHIFT)   # ⇧⌘Z
    wait_until(lambda: text_of(inst, pane) == original + "def f():", 5, message="⇧⌘Z redoes it")
    caret_to_start(inst, ui, pane)
    ui.key(124, CMD | SHIFT)
    wait_until(lambda: ed(inst, pane)["selection"] == [0, 8], 5, message="the first line selected")
    ui.key(7, CMD)   # ⌘X
    wait_until(lambda: text_of(inst, pane).startswith("\n    return"), 5, message="⌘X cuts the selection")
    assert pbpaste() == "def f():"


@pytest.mark.req("E-21")
def test_right_click_in_the_text_offers_cut_copy_paste(inst, win, code, ui):
    pane = open_file(inst, win, code)
    focus(inst, ui, pane)
    x, y, w, h = code_scroll(ui, code.name)
    right_click((x + 120, y + 12, 40, 8))
    titles = wait_until(lambda: open_menu_titles(ui), 3, message="the text's menu")
    ui.key(K_ESC)
    wait_until(lambda: not open_menu_titles(ui), 3, message="Esc closes it")
    assert titles == ["Cut", "Copy", "Paste"], titles


@pytest.mark.req("E-21")
def test_code_view_follows_the_configured_font(fresh, tmp_path):
    config = tmp_path / "xdg" / "umi"
    config.mkdir(parents=True)
    (config / "config").write_text("font-family = Menlo\nfont-size = 15\n")
    other = fresh(prefix="acc-editor-font-", env={"XDG_CONFIG_HOME": str(tmp_path / "xdg")})
    created = other.json("window", "new", "--name", "font")
    wait_until(lambda: other.cli("read", "--pane", created["pane"], check=False).stdout.strip() != "", 20,
               message="the shell prompt")
    path = tmp_path / "f.py"
    path.write_text("x = 1\n")
    pane = other.json("edit", str(path), "--pane", created["pane"])["documents"][0]["pane"]
    state = wait_until(lambda: (s := ed(other, pane)) and "font_family" in s and s, 10, message="the code view")
    assert state["font_family"] == "Menlo" and state["font_size"] == 15, state


@pytest.mark.req("E-21")
def test_line_numbers_and_the_current_line_are_drawn_as_warps(inst, win, code, ui, tmp_path):
    pane = open_file(inst, win, code)
    focus(inst, ui, pane)
    caret_to_start(inst, ui, pane)
    time.sleep(0.5)
    scroll = code_scroll(ui, code.name)
    scale, px = screenshot_of(inst, ui, win, editor_group(ui, code.name), tmp_path / "lines.png")
    bg, rows = gutter_rows(px, scroll, scale, 4)
    assert len(rows) >= 4, f"line numbers in the gutter: {rows}"
    x, _, w, _ = scroll

    def peak(row):
        return max(max(px(xx / scale, row + dy / scale)) for xx in range(int((x + 20) * scale), int((x + 80) * scale))
                   for dy in range(-6, 7))
    current, other = peak(rows[0]) - max(bg), peak(rows[2]) - max(bg)
    assert 1.3 < current / other < 1.7, f"line 1's number at 90%, line 3's at 60%: {current} vs {other}"
    # The caret's line has the surface color (10%) behind it, out to the right; other lines don't.
    right = x + w - 30
    line1 = max(abs(a - b) for a, b in zip(px(right, rows[0]), bg))
    line3 = max(abs(a - b) for a, b in zip(px(right, rows[2]), bg))
    assert 12 <= line1 <= 36 and line3 <= 4, f"current line {line1}, other {line3} away from the background"


@pytest.mark.req("E-21")
def test_marks_are_drawn_in_the_palette_colors(inst, win, tmp_path, ui):
    repo = tmp_path / "repo"
    repo.mkdir()
    path = repo / "marks.txt"
    path.write_text("a\nb\nc\nd\ne\n")
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    for args in (["init", "-q"], ["add", "."], ["commit", "-qm", "base"]):
        subprocess.run(["git", "-C", str(repo), *args], check=True, env=env)
    pane = open_file(inst, win, path)
    time.sleep(1)
    set_text(inst, pane, "A\nb\nd\ne\nf\n")
    wait_until(lambda: ed(inst, pane)["diff_marks"] == {"1": "changed", "3": "removed", "5": "added"}, 10,
               message="marks")
    palette = ed(inst, pane)["palette"]
    focus(inst, ui, pane)
    ui.key(125, CMD)   # the caret off line 1
    time.sleep(0.5)
    scroll = code_scroll(ui, path.name)
    scale, px = screenshot_of(inst, ui, win, editor_group(ui, path.name), tmp_path / "marks.png")
    _, rows = gutter_rows(px, scroll, scale, 5)
    assert len(rows) >= 5, rows
    x = scroll[0] + 1.5

    def near(color, hex_color):
        want = tuple(int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
        return max(abs(a - b) for a, b in zip(color, want)) <= 20

    assert near(px(x, rows[0]), palette[3]), f"changed: yellow {palette[3]}, drawn {px(x, rows[0])}"
    assert near(px(x, rows[4]), palette[2]), f"added: green {palette[2]}, drawn {px(x, rows[4])}"
    line_height = rows[1] - rows[0]
    removed_top = rows[2] - line_height / 2 + 1.5
    assert near(px(x, removed_top), palette[1]), f"removed: red {palette[1]}, drawn {px(x, removed_top)}"


@pytest.mark.req("E-24")
def test_header_shows_folder_and_name_left_aligned_and_keeps_the_name_whole(inst, win, tmp_path, ui):
    """Alejo's choice of 2026-11-07: the type icon, then "folder / name" left-aligned after the grip,
    Preview / Source on the right; in a pane of ordinary width the whole name shows (the centred
    name between two fixed side areas used to shrink to "fr")."""
    from test_umi_panes_ui import split
    folder = tmp_path / "notes"
    folder.mkdir()
    path = folder / "frontier.md"
    path.write_text("# Frontier\n\nNotes.\n")
    pane = open_file(inst, win, path)
    group = wait_until(lambda: editor_group(ui, path.name), 5, message="the file pane")
    gx, gy, gw, _ = frame(ui, group)
    name = header_title(ui, path.name, group)
    nx, ny, nw, nh = frame(ui, name)
    parent = ui.find(lambda e: ui.role(e) == "AXStaticText"
                     and any((t or "").startswith("notes") for t in (ui.label(e), ui.value(e))), group)
    assert parent is not None, f"the parent folder's name is in the header: {ui.texts(group)[:12]}"
    fx, fy, fw, _ = frame(ui, parent)
    assert ny - gy < 30 and fy - gy < 30, "both in the header row"
    assert fx < nx, "the folder comes before the name"
    assert fx - gx < 64, f"left-aligned after the grip and the icon: {fx - gx} points in"
    preview, source = ui.button("Preview", group), ui.button("Source", group)
    assert preview is not None and source is not None, "the switch says Preview / Source"
    assert frame(ui, preview)[0] > nx + nw, "the switch is right of the name"
    # An ordinary narrower pane: the name keeps its full width.
    split(inst, "right", pane)
    wait_until(lambda: frame(ui, editor_group(ui, path.name))[2] < gw * 0.75, 5, message="the file pane narrower")
    group = editor_group(ui, path.name)
    narrow = frame(ui, group)[2]
    assert narrow >= 300, f"the check needs an ordinary pane width, got {narrow}"
    assert abs(frame(ui, header_title(ui, path.name, group))[2] - nw) <= 1, \
        f"the whole name shows in a {narrow}-point pane: {frame(ui, header_title(ui, path.name, group))[2]} vs {nw}"
