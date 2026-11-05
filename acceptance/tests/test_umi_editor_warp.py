"""The file editor as Warp's (SPEC E-4, E-21 to E-24): the code view, find and replace, the editor's
keys, the header menu and the chips. Keys are pressed as a person would; what they did is read back
from the files, the CLI, the accessibility tree and Umi's internal `debug.ui.editor`."""

import os
import subprocess
import time

import pytest

from harness import wait_until

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
    state = wait_until(lambda: (s := ed(inst, pane))["highlighted"] and s, 10, message="syntax colors")
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
    assert state["selection"] == [len(start), 3], "the match is selected in the text"
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
    assert [m["title"] for m in menu] == ["Maximize pane", "Reload file", "Copy file path", "Reveal in Finder"]
    assert all(m["enabled"] for m in menu), "the file pane is in a split, so it can be maximized"
    assert ui.find(lambda e: ui.label(e) == "More actions") is not None, "the ⋯ button"
    ed(inst, pane, menu_item="Maximize pane")
    found = inst.find_pane(pane)
    assert found[2]["zoomed"], "Maximize pane zooms it"
    assert ed(inst, pane)["menu"][0]["title"] == "Minimize pane"
    ed(inst, pane, menu_item="Minimize pane")
    assert not inst.find_pane(pane)[2]["zoomed"]
    # Reload file asks first when there are unsaved edits.
    set_text(inst, pane, "unsaved\n")
    ed(inst, pane, menu_item="Reload file")
    ui.press(wait_until(lambda: ui.button("Reload"), 5, message="Reload asks first"))
    wait_until(lambda: text_of(inst, pane) == code.read_text(), 5, message="reloaded from disk")


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
    set_text(inst, two, "b = 3\n")
    wait_until(lambda: ui.find(lambda e: ui.label(e) == "Unsaved changes") is not None, 5, message="the unsaved dot")
    chip = wait_until(lambda: ui.find(lambda e: ui.label(e) == long_name and ui.role(e) != "AXStaticText"), 5,
                      message="the file's chip")
    size = ui.attr(chip, "AXSize")
    assert size is not None
    import Quartz  # noqa: F401  (pyobjc's AXValue)
    import ApplicationServices as AX
    ok, value = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)
    assert ok and value.width <= 300.5, f"chips are at most 300 wide: {value.width}"
