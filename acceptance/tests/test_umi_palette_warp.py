"""The palette and the shortcuts page as Warp's (SPEC L-14 to L-17, Warp parity, 2026-11-05).

One palette: ⌘P shows everything, a typed prefix (`files:`, `sessions:`, `actions:`,
`conversations:`, `tabs:`) filters it and shows as a word before the query, Backspace in an empty
query removes the filter, ⇧⌘P and ⌘O open it filtered to sessions and files. Empty, it shows
filter chips, Recent and Suggested. ⌘O offers to create a file nothing matches. ⌘/ opens a
searchable shortcuts page (but not in the editor's source).

What the palette shows is read through the internal `debug.palette*` and `debug.shortcuts_page`
methods; the `ui` tests press real keys and need the Accessibility permission.
"""

import os
import subprocess
import time

import pytest

from harness import wait_until

pytestmark = pytest.mark.layout


def rpc(inst, method, **params):
    return inst.rpc(method, **params)


def state(inst, win):
    return rpc(inst, "debug.palette.state", window=win["window"])


def close(inst, win):
    rpc(inst, "debug.palette.close", window=win["window"])


def page(inst, win):
    return rpc(inst, "debug.shortcuts_page", window=win["window"])


def make_repo(path):
    path.mkdir()
    (path / "src").mkdir()
    (path / "src" / "parser.py").write_text("one\ntwo\nthree\n")
    (path / "README.md").write_text("# readme\n")
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "add", "."], cwd=path, check=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], cwd=path, check=True)


def repo_pane(inst, win, tmp_path):
    repo = tmp_path / "repo"
    make_repo(repo)
    pane = inst.cli("tab", "new", "--window", win["window"], "--cwd", str(repo)).stdout.strip()
    wait_until(lambda: os.path.realpath(inst.json("pane", "info", pane)["cwd"]) == os.path.realpath(repo), 15,
               message="cwd")
    inst.cli("pane", "focus", pane)
    time.sleep(0.3)
    return repo, pane


# ---- one palette, filtered by a prefix ------------------------------------------------------------

@pytest.mark.req("L-14")
def test_a_typed_prefix_filters_the_palette_and_shows_as_its_filter_word(inst, win):
    try:
        for typed, mode, word in (("files:", "files", "files:"), ("sessions:", "panes", "sessions:"),
                                  ("actions:", "actions", "actions:"), ("tabs:", "tabs", "tabs:"),
                                  ("conversations:", "conversations", "conversations:")):
            rpc(inst, "debug.palette", window=win["window"], mode="commands", query=typed)
            s = state(inst, win)
            assert (s["mode"], s["filter"], s["query"]) == (mode, word, ""), (typed, s)
        # The rest of what was typed stays the query.
        rpc(inst, "debug.palette", window=win["window"], mode="commands", query="sessions: zz")
        s = state(inst, win)
        assert (s["mode"], s["query"]) == ("panes", "zz"), s
        # Each filter lists only its own kind of row.
        rows = rpc(inst, "debug.palette", window=win["window"], mode="commands", query="actions: split")["entries"]
        assert rows and {r["kind"] for r in rows} <= {"action", "cli"}, rows
        rows = rpc(inst, "debug.palette", window=win["window"], mode="commands", query="tabs:")["entries"]
        assert rows and {r["kind"] for r in rows} == {"tab"} and win["tab"] in [r["value"] for r in rows], rows
        rows = rpc(inst, "debug.palette", window=win["window"], mode="commands", query="sessions:")["entries"]
        assert rows and {r["kind"] for r in rows} == {"pane"}, rows
    finally:
        close(inst, win)


@pytest.mark.req("L-15", "L-16")
def test_shift_cmd_p_and_cmd_o_open_the_palette_filtered(inst, win):
    try:
        rpc(inst, "debug.palette", window=win["window"], mode="panes")
        s = state(inst, win)
        assert (s["mode"], s["filter"], s["placeholder"]) == ("panes", "sessions:", "Search sessions"), s
        rpc(inst, "debug.palette", window=win["window"], mode="files")
        s = state(inst, win)
        assert (s["mode"], s["filter"], s["placeholder"]) == ("files", "files:", "Search files"), s
        rpc(inst, "debug.palette", window=win["window"], mode="commands", query="x")
        s = state(inst, win)
        assert (s["mode"], s["filter"], s["placeholder"]) == ("commands", "", "Search for a command"), s
    finally:
        close(inst, win)


@pytest.mark.req("L-14")
def test_the_unfiltered_palette_mixes_actions_sessions_and_files(inst, win, tmp_path):
    repo, pane = repo_pane(inst, win, tmp_path)
    inst.cli("pane", "rename", pane, "parsing-pane")
    try:
        rpc(inst, "debug.palette", window=win["window"], mode="commands", query="pars")
        wait_until(lambda: any(r["kind"] == "file" for r in state(inst, win)["rows"]), 10,
                   message="files among the results")
        rows = state(inst, win)["rows"]
        kinds = [r["kind"] for r in rows]
        assert "pane" in kinds and "file" in kinds, rows
        assert any(r.get("value") == "src/parser.py" for r in rows), rows
        assert len(rows) <= 250
    finally:
        close(inst, win)


# ---- the empty palette ------------------------------------------------------------------------------

@pytest.mark.req("L-14")
def test_the_empty_palette_shows_filter_chips_recent_and_suggested(inst, win):
    other = inst.cli("split", "right", "--pane", win["pane"], "--name", "recent-pane").stdout.strip()
    other = inst.json("pane", "info", other)["id"]
    inst.cli("pane", "focus", win["pane"])
    try:
        # Choose a pane, then an action (twice, so the sidebar ends as it was).
        rpc(inst, "debug.palette", window=win["window"], mode="panes", query="recent-pane")
        rpc(inst, "debug.palette.perform", window=win["window"], title="recent-pane")
        for _ in range(2):
            rpc(inst, "debug.palette", window=win["window"], mode="commands", query="toggle sidebar")
            rpc(inst, "debug.palette.perform", window=win["window"], title="Toggle Sidebar")
        rows = rpc(inst, "debug.palette", window=win["window"], mode="commands")["entries"]
        s = state(inst, win)
        assert s["zero_state"] and s["selection"] == -1, "nothing is selected until an arrow key"
        assert s["chips"] == ["files", "actions", "sessions", "conversations"], s["chips"]
        recent = [r["title"] for r in rows if r.get("section") == "Recent"]
        suggested = [r["title"] for r in rows if r.get("section") == "Suggested"]
        assert recent[:2] == ["Toggle Sidebar", "recent-pane"] and len(recent) <= 3, recent
        assert suggested == ["Keyboard Shortcuts", "Settings…", "Show Project Explorer"], suggested
        assert [r.get("section") for r in rows] == ["Recent"] * len(recent) + ["Suggested"] * len(suggested)
    finally:
        close(inst, win)


@pytest.mark.req("L-14")
def test_an_entry_under_recent_and_suggested_has_two_distinct_rows(inst, win):
    try:
        rpc(inst, "debug.palette", window=win["window"], mode="commands", query="keyboard shortcuts")
        rpc(inst, "debug.palette.perform", window=win["window"], title="Keyboard Shortcuts")
        wait_until(lambda: page(inst, win)["shown"], 5, message="the shortcuts page opened")
        rows = rpc(inst, "debug.palette", window=win["window"], mode="commands")["entries"]
        recent = [r for r in rows if r.get("section") == "Recent"]
        suggested = [r for r in rows if r.get("section") == "Suggested"]
        # As in Warp, the entry shows in both sections; each row is still its own.
        assert recent[0]["id"] == "umi:Keyboard Shortcuts", recent
        assert "umi:Keyboard Shortcuts" in [r["id"] for r in suggested], suggested
        row_ids = [r["row_id"] for r in rows]
        assert len(row_ids) == len(set(row_ids)), row_ids
    finally:
        close(inst, win)
        if page(inst, win)["shown"]:
            key(inst, win, "cmd+/")


@pytest.mark.req("L-14", "L-16")
def test_a_file_opened_from_the_palette_shows_under_recent(inst, win, tmp_path):
    repo, pane = repo_pane(inst, win, tmp_path)
    try:
        rows = rpc(inst, "debug.palette", window=win["window"], mode="files", query="parser:2")["entries"]
        assert rows[0]["value"] == "src/parser.py", rows
        rpc(inst, "debug.palette.perform", window=win["window"], title="parser.py")
        parser = os.path.realpath(repo / "src" / "parser.py")

        def opened():
            return [os.path.realpath(d["path"]) for d in inst.json("editor", "ls", "--pane", pane)["documents"]]

        wait_until(lambda: parser in opened(), 5, message="the file opened")
        inst.cli("editor", "close", parser)
        wait_until(lambda: parser not in opened(), 5, message="the file closed")
        inst.cli("pane", "focus", pane)
        time.sleep(0.3)
        rows = rpc(inst, "debug.palette", window=win["window"], mode="commands")["entries"]
        recent = [r for r in rows if r.get("section") == "Recent"]
        assert recent and recent[0]["kind"] == "file" and recent[0]["value"] == "src/parser.py", recent
        assert recent[0]["subtitle"] == "src/parser.py:2", recent
        # Chosen from Recent, it opens again.
        result = rpc(inst, "debug.palette.perform", window=win["window"], title="parser.py")
        assert not result["presented"], result
        wait_until(lambda: parser in opened(), 5, message="Recent's file opened")
    finally:
        close(inst, win)


# ---- ⌘O --------------------------------------------------------------------------------------------

@pytest.mark.req("L-16")
def test_quick_open_offers_to_create_a_file_nothing_matches(inst, win, tmp_path):
    repo, pane = repo_pane(inst, win, tmp_path)
    try:
        rows = rpc(inst, "debug.palette", window=win["window"], mode="files", query="notes/brand_new.md")["entries"]
        assert rows[0]["title"] == "Create a file named notes/brand_new.md…", rows
        assert rows[-1]["title"] == "Browse…", rows
        result = rpc(inst, "debug.palette.perform", window=win["window"], title=rows[0]["title"])
        assert not result["presented"], result
        made = repo / "notes" / "brand_new.md"
        wait_until(made.exists, 5, message="the file made")
        docs = inst.json("editor", "ls", "--pane", pane)["documents"]
        assert any(os.path.realpath(d["path"]) == os.path.realpath(made) for d in docs), docs
        # A name that matches is opened, not made.
        rows = rpc(inst, "debug.palette", window=win["window"], mode="files", query="parser")["entries"]
        assert not any(r["kind"] == "create" for r in rows), rows
    finally:
        close(inst, win)


@pytest.mark.req("L-16")
def test_quick_open_creates_a_file_at_a_home_or_absolute_path(inst, win, tmp_path):
    import shutil
    import uuid
    repo, pane = repo_pane(inst, win, tmp_path)
    home_dir = os.path.expanduser(f"~/umi-palette-test-{uuid.uuid4().hex[:8]}")
    try:
        for typed, made in ((f"~/{os.path.basename(home_dir)}/from_home.md", os.path.join(home_dir, "from_home.md")),
                            (str(tmp_path / "elsewhere" / "absolute.md"), str(tmp_path / "elsewhere" / "absolute.md"))):
            rows = rpc(inst, "debug.palette", window=win["window"], mode="files", query=typed)["entries"]
            assert rows[0]["kind"] == "create" and rows[0]["value"] == made, (typed, rows)
            rpc(inst, "debug.palette.perform", window=win["window"], title=rows[0]["title"])
            wait_until(lambda: os.path.exists(made), 5, message=f"{typed} made at {made}")
        assert not (repo / "~").exists() and not (repo / str(tmp_path).lstrip("/")).exists()
    finally:
        close(inst, win)
        shutil.rmtree(home_dir, ignore_errors=True)


# ---- the shortcuts page -----------------------------------------------------------------------------

@pytest.mark.req("L-17")
def test_keyboard_shortcuts_is_a_menu_item_on_cmd_slash(inst, win):
    items = [i for i in rpc(inst, "debug.menu")["items"] if i["title"] == "Keyboard Shortcuts"]
    assert len(items) == 1 and items[0]["key"] == "/" and items[0]["modifiers"] == ["cmd"], items
    entries = inst.json("shortcuts")["shortcuts"]
    assert any(e["id"] == "help.shortcuts" and e["keys"] == ["cmd+/"] for e in entries), entries


def subsequence(query, text):
    """The palette's fuzzy title match: the query's characters in order."""
    it = iter(text.lower())
    return all(c in it for c in query.lower())


@pytest.mark.req("L-17")
def test_the_shortcuts_page_searches_by_keys_in_any_order(inst, win):
    def search(q):
        return rpc(inst, "debug.shortcuts_page", window=win["window"], query=q)["rows"]

    def by_keys(rows, q):
        """The rows the query found by their keys (not by their title)."""
        return [r for r in rows if not subsequence(q, r["title"])]

    def holds(row, mods, key=None):
        for spec in row["shortcuts"]:
            parts = spec.split("+")
            if set(mods) <= set(parts[:-1]) and (key is None or parts[-1] == key):
                return True
        return False

    try:
        # Modifiers in any order, written as words or symbols.
        for q in ("cmd shift p", "shift cmd p", "cmd+shift+p", "⇧⌘P", "command shift p"):
            rows = search(q)
            assert "pane.go_to" in {r["id"] for r in rows}, (q, [r["id"] for r in rows])
            assert all(holds(r, ["cmd", "shift"], "p") for r in by_keys(rows, q)), (q, rows)
        # The terminal's bindings are found by their keys too.
        rows = search("cmd c")
        assert any(r["id"].startswith("ghostty:") and holds(r, ["cmd"], "c") for r in rows), rows
        # A key matches exactly: ⌘P is not ⌘. or ⌘⇞.
        rows = search("cmd p")
        assert "view.palette" in {r["id"] for r in rows}
        assert all(holds(r, ["cmd"], "p") for r in by_keys(rows, "cmd p")), rows
        # Modifiers alone list every shortcut that holds them.
        rows = search("ctrl cmd")
        assert rows and all(holds(r, ["ctrl", "cmd"]) for r in by_keys(rows, "ctrl cmd")), rows
    finally:
        rpc(inst, "debug.shortcuts_page", window=win["window"], query="")


def key(inst, win, keys, focus="terminal"):
    """A key press delivered inside the app (through Umi's key handling, not the system's)."""
    return rpc(inst, "debug.key", window=win["window"], keys=keys, focus=focus)


@pytest.mark.req("L-14", "L-15", "L-16")
def test_cmd_p_shift_cmd_p_and_cmd_o_choose_the_filter(inst, win):
    try:
        key(inst, win, "cmd+p")
        s = state(inst, win)
        assert s["presented"] and s["mode"] == "commands" and s["zero_state"], s
        key(inst, win, "cmd+shift+p", focus="palette")
        assert (state(inst, win)["mode"], state(inst, win)["filter"]) == ("panes", "sessions:")
        key(inst, win, "cmd+o", focus="palette")
        assert (state(inst, win)["mode"], state(inst, win)["filter"]) == ("files", "files:")
    finally:
        close(inst, win)


@pytest.mark.req("L-17")
def test_cmd_slash_toggles_the_shortcuts_page_but_not_in_the_editor_source(inst, win, tmp_path):
    try:
        assert key(inst, win, "cmd+/")["handled"]
        wait_until(lambda: page(inst, win)["shown"], 5, message="⌘/ opened the page")
        rows = page(inst, win)["rows"]
        assert {"view.palette", "help.shortcuts"} <= {r["id"] for r in rows}
        assert any(r["id"].startswith("ghostty:") and r["section"] == "Terminal" for r in rows)
        key(inst, win, "cmd+/")
        wait_until(lambda: not page(inst, win)["shown"], 5, message="⌘/ closed it")
        # From the palette: the page opens and the palette closes.
        key(inst, win, "cmd+/", focus="palette")
        wait_until(lambda: page(inst, win)["shown"], 5, message="⌘/ from the palette")
        assert not state(inst, win)["presented"]
        key(inst, win, "cmd+/")
        wait_until(lambda: not page(inst, win)["shown"], 5, message="closed again")
        # In the editor's source the key is the editor's.
        doc = tmp_path / "slash.py"
        doc.write_text("x = 1\n")
        inst.cli("edit", str(doc), "--tab", win["tab"])
        inst.cli("editor", "mode", "source", "--tab", win["tab"])
        result = key(inst, win, "cmd+/", focus="editor")
        assert not result["handled"], result
        time.sleep(0.3)
        assert not page(inst, win)["shown"], "the page stays closed in the editor's source"
    finally:
        if page(inst, win)["shown"]:
            key(inst, win, "cmd+/")


# ---- keys, pressed for real -----------------------------------------------------------------------

KEYCODES = {"p": 35, "o": 31, "/": 44, "delete": 51, "down": 125, "up": 126, "return": 36, "esc": 53}


def press(ui, key, *mods):
    flags = 0
    for mod in mods:
        flags |= {"cmd": ui.CMD, "shift": ui.SHIFT, "ctrl": ui.CTRL, "option": ui.OPT}[mod]
    ui.key(KEYCODES[key], flags)
    time.sleep(0.4)


@pytest.mark.req("L-14")
def test_typing_a_prefix_filters_and_backspace_removes_the_filter_ui(inst, win, ui):
    ui.activate()
    inst.cli("pane", "focus", win["pane"])
    press(ui, "p", "cmd")
    field = ui.focused_input(5)
    assert field is not None, "the palette's field has focus"
    try:
        ui.enter_text("files:", field)
        wait_until(lambda: state(inst, win)["mode"] == "files", 5, message="files: filters to files")
        assert state(inst, win)["query"] == ""
        assert ui.find(lambda e: ui.label(e) == "Filter files:") is not None, "the filter word shows"
        press(ui, "delete")
        wait_until(lambda: state(inst, win)["mode"] == "commands", 5, message="Backspace removes the filter")
        assert state(inst, win)["presented"]
        ui.enter_text("sessions:", ui.focused_input(5))
        wait_until(lambda: state(inst, win)["mode"] == "panes", 5, message="sessions: filters to panes")
        press(ui, "esc")
        assert not state(inst, win)["presented"]
        # ⇧⌘P and ⌘O open it filtered.
        press(ui, "p", "cmd", "shift")
        wait_until(lambda: state(inst, win)["presented"], 5, message="⇧⌘P opened the palette")
        assert (state(inst, win)["mode"], state(inst, win)["filter"]) == ("panes", "sessions:")
        press(ui, "o", "cmd")
        wait_until(lambda: state(inst, win)["mode"] == "files", 5, message="⌘O switched it to files")
        assert state(inst, win)["filter"] == "files:"
        press(ui, "delete")
        wait_until(lambda: state(inst, win)["mode"] == "commands", 5, message="Backspace leaves ⌘O's filter")
    finally:
        close(inst, win)


@pytest.mark.req("L-14")
def test_the_empty_palette_selects_nothing_until_an_arrow_key_ui(inst, win, ui):
    ui.activate()
    inst.cli("pane", "focus", win["pane"])
    press(ui, "p", "cmd")
    assert ui.focused_input(5) is not None
    try:
        s = state(inst, win)
        assert s["zero_state"] and s["selection"] == -1, s
        assert ui.find(lambda e: ui.label(e) == "Filter sessions") is not None, "the chips show"
        assert ui.find(lambda e: "Suggested" in (ui.label(e), ui.value(e))) is not None, "the Suggested section shows"
        press(ui, "down")
        assert state(inst, win)["selection"] == 0
        press(ui, "esc")
        assert not state(inst, win)["presented"]
    finally:
        close(inst, win)


@pytest.mark.req("L-16")
def test_cmd_o_creates_a_file_nothing_matches_ui(inst, win, ui, tmp_path):
    repo, pane = repo_pane(inst, win, tmp_path)
    ui.activate()
    press(ui, "o", "cmd")
    field = ui.focused_input(5)
    assert field is not None
    try:
        ui.enter_text("made_by_palette.txt", field)
        wait_until(lambda: state(inst, win)["entries"][:1] == ["Create a file named made_by_palette.txt…"], 5,
                   message="the create row")
        press(ui, "return")
        wait_until((repo / "made_by_palette.txt").exists, 5, message="Return made the file")
        wait_until(lambda: any(d["path"].endswith("made_by_palette.txt")
                               for d in inst.json("editor", "ls", "--pane", pane)["documents"]), 5,
                   message="and opened it")
    finally:
        close(inst, win)


@pytest.mark.req("L-14")
def test_the_palette_has_warps_size_and_place_ui(inst, win, ui):
    import ApplicationServices as AX  # noqa: N812
    ui.activate()
    inst.cli("pane", "focus", win["pane"])
    press(ui, "p", "cmd")
    try:
        panel = ui.find(lambda e: ui.label(e) == "Palette")
        assert panel is not None

        def frame(element):
            p = AX.AXValueGetValue(ui.attr(element, "AXPosition"), AX.kAXValueCGPointType, None)[1]
            s = AX.AXValueGetValue(ui.attr(element, "AXSize"), AX.kAXValueCGSizeType, None)[1]
            return p.x, p.y, s.width, s.height

        window = ui.attr(panel, "AXWindow") or ui.windows()[0]
        wx, wy, ww, wh = frame(window)
        x, y, w, h = frame(panel)
        if ww >= 672:
            assert abs(w - 640) <= 1, (w, ww)
            assert abs((x - wx) - (ww - w) / 2) <= 2, "centered"
        assert abs((y - wy) - 117) <= 2, (y - wy)
        assert h <= 464 + 1, h
    finally:
        close(inst, win)


@pytest.mark.req("L-17")
def test_cmd_slash_opens_a_searchable_shortcuts_page_ui(inst, win, ui):
    ui.activate()
    inst.cli("pane", "focus", win["pane"])
    press(ui, "/", "cmd")
    try:
        wait_until(lambda: page(inst, win)["shown"], 5, message="⌘/ opened the page")
        assert ui.find(lambda e: ui.label(e) == "Keyboard Shortcuts" and ui.role(e) != "AXMenuItem") is not None
        rows = page(inst, win)["rows"]
        ids = {r["id"] for r in rows}
        assert {"view.palette", "help.shortcuts", "pane.go_to"} <= ids, ids
        assert any(i.startswith("ghostty:") for i in ids), "Ghostty's keybindings are listed"
        assert set(page(inst, win)["sections"]) >= {"View", "Window", "Terminal"}
        palette_row = next(r for r in rows if r["id"] == "view.palette")
        assert palette_row["keys"] == ["⌘P"], palette_row
        field = ui.focused_input(5)
        assert field is not None, "the search field has focus"
        ui.enter_text("palette", field)
        wait_until(lambda: "view.palette" in {r["id"] for r in page(inst, win)["rows"]}
                   and len(page(inst, win)["rows"]) < len(rows), 5, message="the search narrows the list")
        ui.enter_text("cmd p", field, replace=True)
        wait_until(lambda: "view.palette" in {r["id"] for r in page(inst, win)["rows"]}, 5, message="search by keys")
        press(ui, "esc")
        wait_until(lambda: not page(inst, win)["shown"], 5, message="Esc closed the page")
        press(ui, "/", "cmd")
        wait_until(lambda: page(inst, win)["shown"], 5, message="⌘/ opened it again")
        press(ui, "/", "cmd")
        wait_until(lambda: not page(inst, win)["shown"], 5, message="⌘/ closed it")
    finally:
        if page(inst, win)["shown"]:
            press(ui, "/", "cmd")


@pytest.mark.req("L-17")
def test_cmd_slash_in_the_editor_source_leaves_the_page_closed_ui(inst, win, ui, tmp_path):
    doc = tmp_path / "slash.py"
    doc.write_text("x = 1\n")
    inst.cli("edit", str(doc), "--tab", win["tab"])
    inst.cli("editor", "mode", "source", "--tab", win["tab"])
    ui.activate()
    rpc(inst, "debug.editor.focus", tab=win["tab"])
    time.sleep(0.3)
    press(ui, "/", "cmd")
    time.sleep(0.5)
    assert not page(inst, win)["shown"], "⌘/ is the editor's in its source"
    item = next(i for i in rpc(inst, "debug.menu")["items"] if i["title"] == "Keyboard Shortcuts")
    assert item["key"] == "/"
