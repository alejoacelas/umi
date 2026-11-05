"""The project explorer and global search, as in Warp (SPEC S-2, Warp parity 2026-11-05).

The explorer shows the git root of the focused pane's folder as a tree that follows the files on
disk, takes keyboard focus when shown by key (⇧⌘E, ⌃1) and is driven with ↑↓←→ Enter; ⇧⌘>
shows or hides dotfiles; gitignored entries are marked; the right-click menu has Warp's items.
Global search (⇧⌘F, ⌃3) is the sidebar's third mode: matches grouped by file, ↑↓ ←→ Enter, case
and regex toggles.

What the tree and search show is read through Umi's internal `debug.ui.files` and
`debug.ui.search` methods; the right-click menu (a mouse gesture) is driven through
`debug.ui.files.menu.perform`, which runs the menu item's own action. Everything typed or pressed
is a real key event (`ui` tests).
"""

import json
import os
import socket
import subprocess
import time
import uuid

import pytest

from harness import wait_until

pytestmark = pytest.mark.layout

KEY = {"1": 18, "3": 20, "e": 14, "f": 3, ".": 47, "return": 36, "esc": 53,
       "left": 123, "right": 124, "down": 125, "up": 126}


# ---- helpers ------------------------------------------------------------------------------------

def rpc(inst, method, **params):
    with open(os.path.join(inst.dir, "instance.json")) as f:
        path = json.load(f)["socket"]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(60)
    s.connect(path)
    s.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    reply = json.loads(data)
    if "error" in reply and reply["error"]:
        raise AssertionError(f"{method}: {reply['error']}")
    return reply["result"]


def make_repo(base):
    """A small git repository with a .gitignore, dotfiles, a nested folder and ignored entries."""
    repo = os.path.realpath(str(base / ("repo-" + uuid.uuid4().hex[:6])))
    os.makedirs(os.path.join(repo, "src", "lib"))
    os.makedirs(os.path.join(repo, "build"))
    files = {
        ".gitignore": "build/\n*.log\n",
        ".env.example": "KEY=1\n",
        "README.md": "# Repo\n\nneedle in the readme\n",
        "notes.txt": "Needle with a capital\nanother needle here\n",
        "debug.log": "needle in an ignored file\n",
        "src/main.rs": "fn main() {\n    let needle = 1;\n}\n",
        "src/lib/util.py": "def neeedle():\n    return 'needle'\n",
        "build/out.txt": "needle in an ignored folder\n",
    }
    for name, text in files.items():
        with open(os.path.join(repo, name), "w") as f:
            f.write(text)
    subprocess.run(["git", "init", "-q", repo], check=True)
    subprocess.run(["git", "-C", repo, "add", ".gitignore", "README.md", "src"], check=True)
    return repo


def open_repo(inst, win, repo, sub=""):
    """A tab in the test's window whose shell is in the repository (or a folder in it)."""
    pane = inst.cli("tab", "new", "--window", win["window"], "--cwd", os.path.join(repo, sub)).stdout.strip()
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20,
               message="the shell prompt")
    found = inst.find_pane(pane)
    return {"pane": found[2]["id"], "tab": found[1]["id"], "window": found[0]["id"]}


def files(inst, win, update=True):
    return rpc(inst, "debug.ui.files", window=win["window"], update=update)


def show_files(inst, win, repo):
    inst.cli("sidebar", "files")
    wait_until(lambda: os.path.realpath(files(inst, win)["root"] or "/nonexistent") == repo, 10,
               message="the explorer shows the repository")
    return files(inst, win)


def row(state, path):
    return next((r for r in state["rows"] if os.path.realpath(r["path"]) == os.path.realpath(path)), None)


def names(state):
    return [(r["depth"], r["name"]) for r in state["rows"]]


def press(ui, key, *mods):
    flags = 0
    for mod in mods:
        flags |= {"cmd": ui.CMD, "shift": ui.SHIFT, "ctrl": ui.CTRL, "option": ui.OPT}[mod]
    ui.key(KEY[key], flags)
    time.sleep(0.35)


def menu(inst, win, path):
    return [i["title"] for i in rpc(inst, "debug.ui.files.menu", window=win["window"], path=path)["items"]]


def perform(inst, win, path, title):
    return rpc(inst, "debug.ui.files.menu.perform", window=win["window"], path=path, title=title)


def tab_ids(inst, window):
    return [t["id"] for w in inst.tree()["windows"] if w["id"] == window for t in w["tabs"]]


def editor_paths(inst, tab):
    return [os.path.realpath(d["path"]) for d in inst.json("editor", "ls", "--tab", tab)["documents"]]


def search(inst, win):
    return rpc(inst, "debug.ui.search", window=win["window"])


# ---- the tree -----------------------------------------------------------------------------------

@pytest.mark.req("S-2")
def test_explorer_shows_the_git_root_as_warp_does(inst, win, tmp_path):
    """The root is the git root of the pane's folder, an ordinary row; folders come first, dotfiles
    first within each group; .git is hidden; ignored entries are marked; Warp's row numbers."""
    repo = make_repo(tmp_path)
    open_repo(inst, win, repo, "src/lib")
    state = show_files(inst, win, repo)
    rows = names(state)
    assert rows[0] == (0, os.path.basename(repo)), rows
    assert state["rows"][0]["dir"] and state["rows"][0]["expanded"]
    top = [name for depth, name in rows if depth == 1]
    assert top == ["build", "src", ".env.example", ".gitignore", "debug.log", "notes.txt", "README.md"], top
    assert ".git" not in top
    wait_until(lambda: row(files(inst, win), os.path.join(repo, "build"))["ignored"], 5, message="ignored entries marked")
    state = files(inst, win)
    assert row(state, os.path.join(repo, "build"))["ignored"] is True
    assert row(state, os.path.join(repo, "debug.log"))["ignored"] is True
    assert row(state, os.path.join(repo, "src"))["ignored"] is False
    assert row(state, os.path.join(repo, "README.md"))["ignored"] is False
    assert state["style"]["font_size"] == 14 and state["style"]["indent"] == 16
    assert state["style"]["icon"] == 16 and state["style"]["row_height"] == 25
    inst.cli("sidebar", "tabs")


@pytest.mark.req("S-2")
def test_explorer_follows_the_file_system(inst, win, tmp_path):
    """New and deleted files show without a refresh (FSEvents)."""
    repo = make_repo(tmp_path)
    open_repo(inst, win, repo)
    show_files(inst, win, repo)
    made = os.path.join(repo, "fresh-" + uuid.uuid4().hex[:4] + ".rs")
    with open(made, "w") as f:
        f.write("x\n")
    wait_until(lambda: row(files(inst, win, update=False), made) is not None, 5, message="a new file shows")
    assert row(files(inst, win, update=False), made)["icon"] == "RS"
    os.remove(made)
    wait_until(lambda: row(files(inst, win, update=False), made) is None, 5, message="a deleted file goes")
    inst.cli("sidebar", "tabs")


@pytest.mark.req("S-2")
def test_explorer_menu_has_warps_items(inst, win, tmp_path):
    """The right-click menu: Warp's items with Umi's, and what each does."""
    repo = make_repo(tmp_path)
    term = open_repo(inst, win, repo)
    show_files(inst, win, repo)
    src = os.path.join(repo, "src")
    readme = os.path.join(repo, "README.md")
    assert menu(inst, win, src) == [
        "New File", "cd to Directory", "Open in New Tab", "Reveal in Finder", "Rename", "Delete",
        "Insert Path in Terminal", "Copy Path", "Copy Relative Path"]
    assert menu(inst, win, readme) == [
        "Open in Editor", "Open in New Tab", "Open with Default App", "Reveal in Finder", "Rename", "Delete",
        "Insert Path in Terminal", "Copy Path", "Copy Relative Path"]
    root_items = menu(inst, win, repo)
    assert "Rename" not in root_items and "Delete" not in root_items

    assert os.path.realpath(perform(inst, win, readme, "Copy Path")["copied"]) == os.path.realpath(readme)
    assert perform(inst, win, os.path.join(repo, "src"), "Copy Relative Path")["copied"] == "src"

    # cd to Directory types `cd <folder>` into the terminal.
    perform(inst, win, src, "cd to Directory")
    wait_until(lambda: os.path.realpath(inst.json("pane", "info", term["pane"])["cwd"] or "/") == os.path.realpath(src),
               10, message="the terminal is in src")

    # Open in New Tab: a folder as a terminal there; a file as a tab of its own.
    before = tab_ids(inst, win["window"])
    perform(inst, win, readme, "Open in New Tab")
    wait_until(lambda: len(tab_ids(inst, win["window"])) == len(before) + 1, 10, message="a tab for the file")
    new = [t for t in tab_ids(inst, win["window"]) if t not in before][0]
    assert editor_paths(inst, new) == [os.path.realpath(readme)], "the file's own tab shows it"
    perform(inst, win, src, "Open in New Tab")
    wait_until(lambda: len(tab_ids(inst, win["window"])) == len(before) + 2, 10, message="a tab for the folder")
    folder_tab = [t for t in tab_ids(inst, win["window"]) if t not in before and t != new][0]
    tab = next(t for w in inst.tree()["windows"] for t in w["tabs"] if t["id"] == folder_tab)
    wait_until(lambda: os.path.realpath(inst.json("pane", "info", tab["focused_pane"])["cwd"] or "/")
               == os.path.realpath(src), 10, message="the folder's tab is a terminal there")
    inst.cli("tab", "focus", term["tab"])

    # Delete moves to the Trash.
    doomed_name = "doomed-" + uuid.uuid4().hex[:6] + ".txt"
    doomed = os.path.join(repo, doomed_name)
    with open(doomed, "w") as f:
        f.write("bye\n")
    wait_until(lambda: row(files(inst, win, update=False), doomed) is not None, 5, message="the file shows")
    perform(inst, win, doomed, "Delete")
    assert not os.path.exists(doomed)
    trashed = os.path.expanduser("~/.Trash/" + doomed_name)
    assert os.path.exists(trashed), "it went to the Trash"
    os.remove(trashed)   # the test's own file
    wait_until(lambda: row(files(inst, win, update=False), doomed) is None, 5, message="the row goes")
    inst.cli("sidebar", "tabs")


@pytest.mark.req("S-2")
def test_explorer_reveals_the_active_file(inst, win, tmp_path):
    """A file shown in the focused pane is revealed in the tree: its folders open, it's selected."""
    repo = make_repo(tmp_path)
    term = open_repo(inst, win, repo)
    show_files(inst, win, repo)
    target = os.path.join(repo, "src", "lib", "util.py")
    assert row(files(inst, win), target) is None
    opened = inst.json("edit", target, "--pane", term["pane"])
    inst.cli("pane", "focus", opened["documents"][0]["pane"])
    wait_until(lambda: os.path.realpath(files(inst, win)["selected"] or "/") == os.path.realpath(target), 10,
               message="the file is revealed and selected")
    state = files(inst, win)
    assert row(state, os.path.join(repo, "src"))["expanded"] and row(state, os.path.join(repo, "src", "lib"))["expanded"]
    inst.cli("sidebar", "tabs")


# ---- keys (real key presses) ---------------------------------------------------------------------

@pytest.mark.req("S-2", "L-9", "L-10")
def test_explorer_keys(inst, win, ui, tmp_path):
    """⌃1 shows the explorer with focus in it; ↓ selects, → expands, ← collapses then goes to the
    parent, Enter opens a file; Esc goes back to the pane; ⇧⌘E hides it again; ⇧⌘> hides dotfiles."""
    repo = make_repo(tmp_path)
    term = open_repo(inst, win, repo)
    inst.cli("sidebar", "tabs")
    inst.cli("pane", "focus", term["pane"])
    ui.activate()
    press(ui, "1", "ctrl")
    wait_until(lambda: inst.json("sidebar", "status")["mode"] == "files", 5, message="⌃1 shows the explorer")
    wait_until(lambda: files(inst, win)["focused"], 5, message="the tree has keyboard focus")
    wait_until(lambda: os.path.realpath(files(inst, win)["root"] or "/") == repo, 10, message="the repository")

    press(ui, "down")
    assert os.path.realpath(files(inst, win)["selected"]) == repo, "↓ selects the first row"
    press(ui, "down")
    press(ui, "down")
    src = os.path.join(repo, "src")
    assert os.path.realpath(files(inst, win)["selected"]) == src
    press(ui, "right")
    assert row(files(inst, win), src)["expanded"], "→ expands"
    assert row(files(inst, win), os.path.join(src, "main.rs")) is not None
    press(ui, "down")
    press(ui, "down")
    main = os.path.join(src, "main.rs")
    assert os.path.realpath(files(inst, win)["selected"]) == main
    press(ui, "left")
    assert os.path.realpath(files(inst, win)["selected"]) == src, "← on a file goes to its folder"
    press(ui, "left")
    assert not row(files(inst, win), src)["expanded"], "← collapses"
    press(ui, "right")
    press(ui, "down")
    press(ui, "down")
    press(ui, "return")
    wait_until(lambda: os.path.realpath(main) in editor_paths(inst, term["tab"]), 10, message="Enter opens the file")

    # Dotfiles: ⇧⌘> hides and shows them.
    assert row(files(inst, win), os.path.join(repo, ".gitignore")) is not None
    press(ui, ".", "cmd", "shift")
    wait_until(lambda: row(files(inst, win), os.path.join(repo, ".gitignore")) is None, 5, message="⇧⌘> hides dotfiles")
    press(ui, ".", "cmd", "shift")
    wait_until(lambda: row(files(inst, win), os.path.join(repo, ".gitignore")) is not None, 5, message="⇧⌘> shows them")

    # ⇧⌘E from the tree: back to Tabs, and the keys go to the pane again.
    inst.cli("sidebar", "files")
    rpc(inst, "debug.ui.files", window=win["window"])
    press(ui, "e", "cmd", "shift")
    wait_until(lambda: inst.json("sidebar", "status")["mode"] == "tabs", 5, message="⇧⌘E hides it")
    press(ui, "e", "cmd", "shift")
    wait_until(lambda: files(inst, win)["focused"], 5, message="⇧⌘E puts focus in the tree")
    press(ui, "esc")
    wait_until(lambda: not files(inst, win)["focused"], 5, message="Esc leaves the tree")
    inst.cli("sidebar", "tabs")


@pytest.mark.req("S-2")
def test_explorer_new_file_and_rename_inline(inst, win, ui, tmp_path):
    """New File and Rename edit the name in the row; Enter commits, an empty name cancels."""
    repo = make_repo(tmp_path)
    term = open_repo(inst, win, repo)
    show_files(inst, win, repo)
    ui.activate()
    src = os.path.join(repo, "src")
    perform(inst, win, src, "New File")
    wait_until(lambda: (files(inst, win).get("edit") or {}).get("kind") == "new_file", 5, message="a name field")
    assert any(r["new_file"] for r in files(inst, win)["rows"])
    time.sleep(0.4)
    ui.type_text("added.rs")
    press(ui, "return")
    made = os.path.join(src, "added.rs")
    wait_until(lambda: os.path.exists(made), 5, message="New File made the file")
    wait_until(lambda: os.path.realpath(made) in editor_paths(inst, term["tab"]), 10, message="and opened it")

    readme = os.path.join(repo, "notes.txt")
    perform(inst, win, readme, "Rename")
    wait_until(lambda: (files(inst, win).get("edit") or {}).get("kind") == "rename", 5, message="a rename field")
    time.sleep(0.4)
    ui.type_text("renamed.txt")   # the whole name is selected, so this replaces it
    press(ui, "return")
    wait_until(lambda: os.path.exists(os.path.join(repo, "renamed.txt")), 5, message="renamed on disk")
    assert not os.path.exists(readme)
    wait_until(lambda: row(files(inst, win, update=False), os.path.join(repo, "renamed.txt")) is not None, 5,
               message="the row has the new name")

    # Esc cancels.
    perform(inst, win, os.path.join(repo, "renamed.txt"), "Rename")
    time.sleep(0.4)
    ui.type_text("nope.txt")
    press(ui, "esc")
    wait_until(lambda: files(inst, win).get("edit") is None, 5, message="Esc ends the edit")
    assert os.path.exists(os.path.join(repo, "renamed.txt")) and not os.path.exists(os.path.join(repo, "nope.txt"))
    inst.cli("sidebar", "tabs")


# ---- global search ------------------------------------------------------------------------------

@pytest.mark.req("S-2", "L-9", "L-10")
def test_global_search(inst, win, ui, tmp_path):
    """⇧⌘F opens global search with the query focused; typing searches the repository (not what
    git ignores), results are grouped by file; ↓ goes into the results, ←/→ fold a file, Enter opens
    the file at the line; the case and regex toggles; ⌃3 hides it."""
    repo = make_repo(tmp_path)
    term = open_repo(inst, win, repo)
    inst.cli("sidebar", "tabs")
    inst.cli("pane", "focus", term["pane"])
    ui.activate()
    press(ui, "f", "cmd", "shift")
    wait_until(lambda: inst.json("sidebar", "status")["mode"] == "search", 5, message="⇧⌘F shows search")
    wait_until(lambda: search(inst, win)["focus"] == "query", 5, message="the query has focus")
    ui.type_text("needle")
    wait_until(lambda: search(inst, win)["query"] == "needle" and not search(inst, win)["searching"]
               and search(inst, win)["files"], 10, message="results")
    state = search(inst, win)
    assert os.path.realpath(state["root"]) == repo
    paths = sorted(f["path"] for f in state["files"])
    assert paths == ["README.md", "notes.txt", "src/lib/util.py", "src/main.rs"], paths
    total = sum(len(f["matches"]) for f in state["files"])
    assert state["message"] == f"{total} results in 4 files", state["message"]
    assert [r["kind"] for r in state["rows"]][:1] == ["file"]

    # ↓ into the results; ← folds the file, → unfolds it.
    press(ui, "down")
    state = search(inst, win)
    assert state["focus"] == "results" and state["selected"]["kind"] == "file"
    first = state["selected"]["path"]
    count = state["selected"]["count"]
    press(ui, "left")
    state = search(inst, win)
    assert state["selected"]["collapsed"] and not any(r["kind"] == "match" and r["path"] == first for r in state["rows"])
    press(ui, "right")
    assert sum(1 for r in search(inst, win)["rows"] if r["kind"] == "match" and r["path"] == first) == count
    press(ui, "down")
    state = search(inst, win)
    assert state["selected"]["kind"] == "match"
    line = state["selected"]["line"]
    press(ui, "return")
    target = os.path.realpath(os.path.join(repo, first))
    wait_until(lambda: target in editor_paths(inst, term["tab"]), 10, message="Enter opens the file")
    assert line >= 1

    # The case toggle: "Needle" only matches the capitalized line.
    press(ui, "f", "cmd", "shift")
    wait_until(lambda: search(inst, win)["focus"] == "query", 5, message="⇧⌘F focuses the query again")
    ui.type_text("Needle")   # the query is selected, so this replaces it
    toggle = ui.find(lambda e: ui.label(e) == "Toggle Case Sensitivity")
    assert toggle is not None, "the case toggle"
    ui.press(toggle)
    wait_until(lambda: search(inst, win)["case_sensitive"] and not search(inst, win)["searching"]
               and search(inst, win)["query"] == "Needle", 10, message="case-sensitive search")
    wait_until(lambda: [f["path"] for f in search(inst, win)["files"]] == ["notes.txt"], 10,
               message="only the capitalized match")
    ui.press(toggle)

    # The regex toggle: ne+dle also matches "neeedle".
    regex = ui.find(lambda e: ui.label(e) == "Toggle Regex")
    assert regex is not None
    press(ui, "f", "cmd", "shift")
    ui.type_text("ne+dle\\(")
    ui.press(regex)
    wait_until(lambda: search(inst, win)["regex"] and not search(inst, win)["searching"], 10, message="regex search")
    wait_until(lambda: [f["path"] for f in search(inst, win)["files"]] == ["src/lib/util.py"], 10,
               message="the regex matches neeedle(")
    ui.press(regex)

    # ⌃3 hides it (focus was in it) and shows it again.
    press(ui, "3", "ctrl")
    wait_until(lambda: inst.json("sidebar", "status")["mode"] == "tabs", 5, message="⌃3 hides search")
    press(ui, "3", "ctrl")
    wait_until(lambda: inst.json("sidebar", "status")["mode"] == "search", 5, message="⌃3 shows search")
    press(ui, "esc")
    inst.cli("sidebar", "tabs")


@pytest.mark.req("S-2", "L-9")
def test_files_and_search_shortcuts_are_menu_items(inst, win):
    """The new keys are Umi menu items (so they work whatever has focus); ⇧⌘F no longer ends a
    terminal search."""
    items = rpc(inst, "debug.menu")["items"]

    def key_of(title):
        item = next((i for i in items if i["title"] == title), None)
        assert item is not None, f"no menu item {title!r}"
        return item["key"], sorted(item["modifiers"])

    assert key_of("Show Project Explorer") == ("e", ["cmd", "shift"])
    assert key_of("Left Panel: Project Explorer") == ("1", ["ctrl"])
    assert key_of("Toggle Hidden Files in Project Explorer") == (".", ["cmd", "shift"])
    assert key_of("Global Search") == ("f", ["cmd", "shift"])
    assert key_of("Left Panel: Global Search") == ("3", ["ctrl"])
    others = [i for i in items if i["key"] == "f" and sorted(i["modifiers"]) == ["cmd", "shift"]]
    assert [i["title"] for i in others] == ["Global Search"], others
    assert inst.json("sidebar", "search")["mode"] == "search"
    inst.cli("sidebar", "tabs")
