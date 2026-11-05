"""Launch configurations, as in Warp (SPEC L-21): saved windows, tabs and panes as YAML files in
`$XDG_CONFIG_HOME/umi/launch_configurations`, in Warp's format; ⌃⌘L lists them and Return opens
one; File ▸ Save New Launch Configuration… and a sidebar row's "Save as New Config" save them;
`umi layout ls|save|open`.

Every test runs against one instance of its own whose config folder is a temporary one, so the
user's own launch configurations are never read or written.
"""

import json
import os
import shutil
import socket
import time

import pytest

from harness import UI, Instance, wait_until

pytestmark = pytest.mark.layout


# ---- helpers ------------------------------------------------------------------------------------

@pytest.fixture(scope="module")
def lc(target, tmp_path_factory):
    home = os.path.realpath(tmp_path_factory.mktemp("xdg-config"))
    instance = Instance(target, prefix="acc-layouts-", env={"XDG_CONFIG_HOME": home})
    instance.start_app()
    instance.configs = os.path.join(home, "umi", "launch_configurations")
    yield instance
    instance.cleanup()


@pytest.fixture
def clean(lc, tmp_path):
    """No launch configurations and no windows before the test; the test's windows closed after."""
    shutil.rmtree(lc.configs, ignore_errors=True)
    for w in lc.tree()["windows"]:
        lc.cli("window", "close", w["id"], check=False)
    wait_until(lambda: lc.tree()["windows"] == [], 10, message="no windows left")
    yield lc
    for w in lc.tree()["windows"]:
        lc.cli("window", "close", w["id"], check=False)
    time.sleep(0.2)


def rpc(inst, method, timeout=60, **params):
    with open(os.path.join(inst.dir, "instance.json")) as f:
        path = json.load(f)["socket"]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
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
    if "error" in reply:
        raise AssertionError(f"{method}: {reply['error']['message']}")
    return reply["result"]


def folders(tmp_path, *names):
    out = []
    for name in names:
        path = tmp_path / name
        path.mkdir(parents=True, exist_ok=True)
        out.append(os.path.realpath(path))
    return out


def wait_prompt(inst, pane):
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20,
               message="the shell prompt")


def wait_cwd(inst, pane, folder):
    wait_until(lambda: os.path.realpath(inst.find_pane(pane)[2]["cwd"] or "/") == folder, 20,
               message=f"pane in {folder}")


def write_config(inst, file, text):
    os.makedirs(inst.configs, exist_ok=True)
    path = os.path.join(inst.configs, file)
    with open(path, "w") as f:
        f.write(text)
    return path


def windows_except(inst, before):
    return [w for w in inst.tree()["windows"] if w["id"] not in before]


def open_documents(inst):
    """Every file open in an editor, over all tabs."""
    paths = []
    for window in inst.tree()["windows"]:
        for tab in window["tabs"]:
            docs = inst.json("editor", "ls", "--pane", tab["panes"][0]["id"])["documents"]
            paths += [os.path.realpath(d["path"]) for d in docs]
    return paths


def saved_cwds(text):
    """The folders a saved file names, in order (as real paths: the shell may report /var for /private/var)."""
    return [os.path.realpath(line.split("cwd:", 1)[1].strip()) for line in text.splitlines()
            if line.strip().lstrip("- ").startswith("cwd:")]


def real(path):
    return os.path.realpath(path) if path else path


# ---- saving and opening through the CLI ------------------------------------------------------------

@pytest.mark.req("L-21")
def test_save_writes_warp_format_and_open_brings_the_layout_back(clean, tmp_path):
    inst = clean
    a, b, c = folders(tmp_path, "api", "web", "docs")
    first = inst.json("window", "new", "--cwd", a)
    wait_prompt(inst, first["pane"])
    inst.cli("tab", "rename", first["tab"], "api")
    inst.cli("tab", "color", first["tab"], "blue")
    right = inst.cli("split", "right", "--pane", first["pane"], "--cwd", b).stdout.strip()
    second = inst.cli("tab", "new", "--window", first["window"], "--cwd", c, "--no-focus").stdout.strip()
    for pane, folder in ((first["pane"], a), (right, b), (second, c)):
        wait_cwd(inst, pane, folder)
    inst.cli("pane", "focus", right)

    saved = inst.json("layout", "save", "work")
    path = os.path.join(inst.configs, "work.yaml")
    assert real(saved["path"]) == real(path) and os.path.exists(path), saved
    text = open(path).read()
    # Warp's format: name, windows, tabs, layout with split_direction and panes, cwd, title, color.
    for line in ("name: Work", "windows:", "tabs:", "title: api", "color: blue", "split_direction: horizontal",
                 "panes:", "is_focused: true"):
        assert line in text, f"{line!r} missing from:\n{text}"
    assert saved_cwds(text) == [a, b, c], text

    listed = inst.json("layout", "ls")["configs"]
    assert [(x["name"], x["windows"], x["tabs"]) for x in listed] == [("Work", 1, 2)], listed
    assert "Work" in inst.cli("layout", "ls").stdout

    # Saving again under the same name fails, unless asked to replace it.
    again = inst.cli("layout", "save", "work", check=False)
    assert again.returncode != 0 and "already exists" in again.stderr, again
    inst.json("layout", "save", "work", "--replace")

    inst.cli("window", "close", first["window"])
    wait_until(lambda: inst.tree()["windows"] == [], 10, message="the window closed")
    opened = inst.json("layout", "open", "work")
    assert len(opened["windows"]) == 1, opened
    window = inst.tree()["windows"][0]
    assert window["id"] == opened["windows"][0]
    tabs = window["tabs"]
    assert len(tabs) == 2 and tabs[0].get("name") == "api" and tabs[0].get("color") == "blue", tabs
    left, rightp = tabs[0]["panes"]
    wait_cwd(inst, left["id"], a)
    wait_cwd(inst, rightp["id"], b)
    wait_cwd(inst, tabs[1]["panes"][0]["id"], c)
    left, rightp = inst.tree()["windows"][0]["tabs"][0]["panes"]
    assert rightp["frame"]["x"] > left["frame"]["x"], "side by side, as saved"
    assert rightp["focused"], "the pane that had focus has it again"
    # Opening by file name works too.
    assert len(inst.json("layout", "open", "work.yaml")["windows"]) == 1
    missing = inst.cli("layout", "open", "nope", check=False)
    assert missing.returncode != 0 and "no launch configuration" in missing.stderr


@pytest.mark.req("L-21")
def test_saved_colors_use_warps_names_where_warp_has_them(clean, tmp_path):
    """Warp reads only its eight terminal colors: purple, teal and graphite are saved as magenta,
    cyan and white, and read back as Umi's colors."""
    inst = clean
    (folder,) = folders(tmp_path, "colors")
    win = inst.json("window", "new", "--cwd", folder)
    tabs = [win["tab"]]
    for _ in range(3):
        pane = inst.cli("tab", "new", "--window", win["window"], "--cwd", folder, "--no-focus").stdout.strip()
        tabs.append(inst.find_pane(pane)[1]["id"])
    for tab, color in zip(tabs, ("purple", "teal", "graphite", "pink")):
        inst.cli("tab", "color", tab, color)
    inst.json("layout", "save", "colors")
    text = open(os.path.join(inst.configs, "colors.yaml")).read()
    written = [line.split("color:", 1)[1].strip() for line in text.splitlines() if line.strip().startswith("color:")]
    assert written == ["magenta", "cyan", "white", "pink"], text
    inst.cli("window", "close", win["window"])
    opened = inst.json("layout", "open", "colors")
    window = next(w for w in inst.tree()["windows"] if w["id"] == opened["windows"][0])
    assert [t.get("color") for t in window["tabs"]] == ["purple", "teal", "graphite", "pink"], window["tabs"]


@pytest.mark.req("L-21")
def test_hand_written_config_opens_windows_splits_and_runs_commands(clean, tmp_path):
    inst = clean
    one, two, three = folders(tmp_path, "one", "two", "three")
    write_config(inst, "team.yml", f"""\
# hand-written, the way Warp's docs show it
name: Team Setup
active_window_index: 1
windows:
  - tabs:
      - title: solo
        layout:
          cwd: {one}
  - active_tab_index: 1
    tabs:
      - layout:
          cwd: {one}
      - title: stacked
        color: cyan
        layout:
          split_direction: vertical
          panes:
            - cwd: {one}
              commands:
                - exec: echo LC_MARK_$((6*7))
            - cwd: "{two}"
              is_focused: true
            - cwd: {three}
        commands:
          - exec: echo TAB_LEVEL_$((5*5))
""")
    before = set()
    opened = inst.json("layout", "open", "team setup")
    assert len(opened["windows"]) == 2, opened
    made = windows_except(inst, before)
    by_id = {w["id"]: w for w in made}
    solo, team = by_id[opened["windows"][0]], by_id[opened["windows"][1]]
    assert [t.get("name") for t in solo["tabs"]] == ["solo"]
    assert len(team["tabs"]) == 2
    stacked = team["tabs"][1]
    assert team["selected_tab"] == stacked["id"], "active_tab_index picks the selected tab"
    assert stacked.get("name") == "stacked" and stacked.get("color") == "teal", "Warp's cyan is Umi's teal"
    panes = stacked["panes"]
    assert len(panes) == 3
    for pane, folder in zip(panes, (one, two, three)):
        wait_cwd(inst, pane["id"], folder)
    frames = [p["frame"] for p in next(w for w in inst.tree()["windows"] if w["id"] == team["id"])["tabs"][1]["panes"]]
    assert len({f["x"] for f in frames}) == 1, f"one above the other: {frames}"
    heights = [f["height"] for f in frames]
    assert max(heights) - min(heights) < 40, f"equal shares: {heights}"
    # Commands are typed into the pane's shell as it starts; the tab's own commands go to its
    # focused pane.
    wait_until(lambda: "LC_MARK_42" in inst.cli("read", "--pane", panes[0]["id"]).stdout, 20,
               message="the pane's command ran")
    wait_until(lambda: "TAB_LEVEL_25" in inst.cli("read", "--pane", panes[1]["id"]).stdout, 20,
               message="the tab's command ran in its focused pane")
    assert "TAB_LEVEL_25" not in inst.cli("read", "--pane", panes[2]["id"]).stdout
    # The active window is the current one.
    assert inst.tree()["current_pane"] in [p["id"] for p in panes], "the active window is in front"


@pytest.mark.req("L-21")
def test_a_broken_file_is_reported_with_its_line(clean):
    inst = clean
    write_config(inst, "broken.yaml", "name: Broken\nwindows:\n  - tabs:\n      - layout:\n          cwd: /tmp\n     oops: 1\n")
    write_config(inst, "badcolor.yaml", "name: Bad Color\nwindows:\n  - tabs:\n      - color: chartreuse\n        layout:\n          cwd: /tmp\n")
    listed = {x["file"]: x for x in inst.json("layout", "ls")["configs"]}
    assert "line 6" in listed["broken.yaml"]["error"], listed
    assert "chartreuse" in listed["badcolor.yaml"]["error"], listed
    failed = inst.cli("layout", "open", "broken", check=False)
    assert failed.returncode != 0 and "line 6" in failed.stderr, failed
    assert inst.tree()["windows"] == [], "nothing opened"


@pytest.mark.req("L-21")
def test_a_file_with_several_documents_holds_several_configurations(clean, tmp_path):
    """As in Warp, each YAML document (separated by `---`) is a configuration of its own."""
    inst = clean
    a, b = folders(tmp_path, "doc-a", "doc-b")
    write_config(inst, "both.yaml", f"""\
---
name: First Doc
windows:
  - tabs:
      - title: tab-of-first
        layout:
          cwd: {a}
---
# the second one
name: Second Doc
windows:
  - tabs:
      - title: tab-of-second
        layout:
          cwd: {b}
""")
    listed = inst.json("layout", "ls")["configs"]
    assert [(x["name"], x["file"], x["document"]) for x in listed] == \
        [("First Doc", "both.yaml", 0), ("Second Doc", "both.yaml", 1)], listed
    opened = inst.json("layout", "open", "second doc")
    tabs = [t for w in inst.tree()["windows"] if w["id"] in opened["windows"] for t in w["tabs"]]
    assert [t.get("name") for t in tabs] == ["tab-of-second"], tabs
    wait_cwd(inst, tabs[0]["panes"][0]["id"], b)
    # The file's name is ambiguous then: it says which names to use.
    ambiguous = inst.cli("layout", "open", "both", check=False)
    assert ambiguous.returncode != 0 and "First Doc, Second Doc" in ambiguous.stderr, ambiguous
    # A broken second document is reported with its line, counted in the whole file.
    write_config(inst, "both.yaml", "name: One\nwindows: []\n---\nname: Two\nwindows:\n  - tabs: 3\n    oops\n")
    listed = {x["file"]: x for x in inst.json("layout", "ls")["configs"]}
    assert "line 7" in listed["both.yaml"]["error"], listed


# ---- the palette, the menus and the sidebar row's menu ------------------------------------------------

@pytest.mark.req("L-21", "L-9")
def test_launch_configuration_items_are_in_the_file_menu(clean):
    inst = clean
    items = rpc(inst, "debug.menu")["items"]
    palette = [i for i in items if i["title"] == "Open Launch Configuration…"]
    assert len(palette) == 1 and palette[0]["key"].lower() == "l" and palette[0]["modifiers"] == ["ctrl", "cmd"], palette
    assert [i["title"] for i in items if i["key"].lower() == "l" and i["modifiers"] == ["ctrl", "cmd"]] == \
        ["Open Launch Configuration…"], "⌃⌘L is on one item only"
    assert any(i["title"] == "Save New Launch Configuration…" for i in items)
    shortcuts = {s["id"]: s for s in inst.json("shortcuts")["shortcuts"]}
    assert shortcuts["file.launch_configs"]["keys"] == ["ctrl+cmd+l"], shortcuts["file.launch_configs"]


@pytest.mark.req("L-21")
def test_palette_lists_configurations_and_opens_the_chosen_one(clean, tmp_path):
    inst = clean
    (folder,) = folders(tmp_path, "pal")
    write_config(inst, "alpha.yaml", f"name: Alpha\nwindows:\n  - tabs:\n      - title: from-alpha\n        layout:\n          cwd: {folder}\n")
    write_config(inst, "beta_two.yaml", f"windows:\n  - tabs:\n      - layout:\n          cwd: {folder}\n")
    win = inst.json("window", "new")
    entries = rpc(inst, "debug.palette", window=win["window"], mode="launch_configs")["entries"]
    assert [e["title"] for e in entries] == ["Alpha", "Beta Two"], "named after the file when it has no name"
    assert "1 window · 1 tab" in entries[0]["subtitle"], entries[0]
    rpc(inst, "debug.palette", window=win["window"], mode="launch_configs", query="alp")
    rpc(inst, "debug.palette.perform", window=win["window"], title="Alpha")
    wait_until(lambda: any(t.get("name") == "from-alpha" for w in inst.tree()["windows"] for t in w["tabs"]), 10,
               message="the configuration opened")
    assert len(inst.tree()["windows"]) == 2, "in a new window"
    # The command palette offers the File menu items and the CLI's actions.
    titles = [e["title"] for e in rpc(inst, "debug.palette", window=win["window"], mode="commands")["entries"]]
    assert "Open Launch Configuration…" in titles and "Save New Launch Configuration…" in titles
    assert "List Launch Configurations" in titles
    rpc(inst, "debug.palette.close", window=win["window"])


@pytest.mark.req("L-21", "S-4")
def test_tab_menu_save_as_new_config_saves_the_tab_and_opens_the_file(clean, tmp_path):
    inst = clean
    a, b = folders(tmp_path, "m1", "m2")
    win = inst.json("window", "new", "--cwd", a)
    wait_prompt(inst, win["pane"])
    inst.cli("tab", "rename", win["tab"], "menu-tab")
    split = inst.cli("split", "down", "--pane", win["pane"], "--cwd", b).stdout.strip()
    wait_cwd(inst, win["pane"], a)
    wait_cwd(inst, split, b)
    titles = [i["title"] for i in rpc(inst, "debug.ui.menu", tab=win["tab"])["items"]]
    # Where Warp has it: after the close items, before the colors.
    index = titles.index("Save as New Config")
    assert titles[index - 1] == "Close Tabs Below" and titles[index + 1] == "Tab Color", titles

    rpc(inst, "debug.ui.menu.perform", tab=win["tab"], title="Save as New Config")
    path = os.path.join(inst.configs, "my_tab_config.yaml")
    wait_until(lambda: os.path.exists(path), 5, message="the file written")
    text = open(path).read()
    for line in ("name: menu-tab", "title: menu-tab", "split_direction: vertical"):
        assert line in text, f"{line!r} missing from:\n{text}"
    assert saved_cwds(text) == [a, b], text
    wait_until(lambda: real(path) in open_documents(inst), 10,
               message="the file open in the editor")
    rpc(inst, "debug.ui.menu.perform", tab=win["tab"], title="Save as New Config")
    wait_until(lambda: os.path.exists(os.path.join(inst.configs, "my_tab_config_1.yaml")), 5,
               message="a second save takes the next free name")


@pytest.mark.req("L-21", "L-10")
@pytest.mark.parametrize("focus", ["terminal", "editor", "palette"])
def test_ctrl_cmd_l_reaches_the_launch_palette_whatever_has_focus(clean, tmp_path, focus):
    """The key press as the app's key monitor sees it (the real-key UI test below needs an unlocked
    screen): ⌃⌘L opens the launch configuration list from a terminal, the editor or another palette."""
    inst = clean
    win = inst.json("window", "new")
    wait_prompt(inst, win["pane"])
    if focus == "editor":
        doc = tmp_path / "lc.md"
        doc.write_text("# lc\n")
        inst.cli("edit", str(doc), "--tab", win["tab"])
    result = rpc(inst, "debug.key", window=win["window"], keys="ctrl+cmd+l", focus=focus)
    assert result["handled"], result
    state = rpc(inst, "debug.palette.state", window=win["window"])
    assert state["presented"] and state["mode"] == "launch_configs", state
    rpc(inst, "debug.palette.close", window=win["window"])


# ---- real key presses ----------------------------------------------------------------------------------

@pytest.mark.req("L-21")
def test_ctrl_cmd_l_opens_the_palette_and_return_opens_the_configuration(clean, ui, tmp_path):
    inst = clean
    (folder,) = folders(tmp_path, "keys")
    write_config(inst, "keyed.yaml", f"name: Keyed Layout\nwindows:\n  - tabs:\n      - title: keyed-tab\n        layout:\n          cwd: {folder}\n")
    win = inst.json("window", "new")
    wait_prompt(inst, win["pane"])
    view = UI(inst.app_pid)
    view.activate()
    view.key(37, view.CTRL | view.CMD)   # ⌃⌘L
    time.sleep(0.4)
    field = view.focused_input(5)
    assert field is not None, "the palette opened with its field focused"
    state = rpc(inst, "debug.palette.state", window=win["window"])
    assert state.get("mode") == "launch_configs", state
    view.enter_text("keyed", field)
    view.key(36)   # Return
    wait_until(lambda: any(t.get("name") == "keyed-tab" for w in inst.tree()["windows"] for t in w["tabs"]), 10,
               message="⌃⌘L, then Return, opened the configuration")


@pytest.mark.req("L-21")
def test_save_new_launch_configuration_from_the_file_menu(clean, ui, tmp_path):
    inst = clean
    (folder,) = folders(tmp_path, "menu-save")
    win = inst.json("window", "new", "--cwd", folder)
    wait_cwd(inst, win["pane"], folder)
    view = UI(inst.app_pid)
    view.activate()
    view.choose(view.menu_item("Save New Launch Configuration"))
    field = view.focused_input(5)
    assert field is not None, "the dialog's name field has focus"
    view.enter_text("from_menu", field)
    view.key(36)   # Return: Save Configuration
    path = os.path.join(inst.configs, "from_menu.yaml")
    wait_until(lambda: os.path.exists(path), 5, message="saved")
    assert "name: From Menu" in open(path).read()
    assert saved_cwds(open(path).read()) == [folder]
    time.sleep(0.5)
    view.key(36)   # Return: Done
    time.sleep(0.5)
    # A second save under the same name says so and keeps the file.
    view.choose(view.menu_item("Save New Launch Configuration"))
    field = view.focused_input(5)
    view.enter_text("from_menu", field)
    view.key(36)
    wait_until(lambda: "already exists" in view.all_text(), 5, message="the dialog says the name is taken")
    view.key(53)   # Esc: Cancel
