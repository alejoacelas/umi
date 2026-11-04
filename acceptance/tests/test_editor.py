"""The editor: files in panes of their own (SPEC E). The CLI says what is open; the accessibility tree
shows the text."""

import os
import time

import pytest

from harness import wait_until
from test_umi_panes_ui import rpc

pytestmark = pytest.mark.editor


def docs(inst, pane):
    return inst.json("editor", "ls", "--pane", pane)["documents"]


def doc(inst, pane, path):
    for d in docs(inst, pane):
        if os.path.realpath(d["path"]) == os.path.realpath(path):
            return d
    return None


@pytest.fixture
def files(tmp_path):
    md = tmp_path / "README.md"
    md.write_text("# Title\n\n- [x] done\n- [ ] todo\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```py\nprint(1)\n```\n")
    txt = tmp_path / "notes.txt"
    txt.write_text("plain notes\n")
    return tmp_path, str(md), str(txt)


@pytest.mark.req("E-1", "E-2", "E-9")
def test_open_modes_and_several_documents(inst, win, files):
    _, md, txt = files
    inst.cli("edit", md, txt, "--pane", win["pane"])
    assert doc(inst, win["pane"], md)["mode"] == "preview"
    assert doc(inst, win["pane"], txt)["mode"] == "source"
    assert not doc(inst, win["pane"], md)["dirty"]
    inst.cli("edit", md, "--source", "--pane", win["pane"])
    assert doc(inst, win["pane"], md)["mode"] == "source"
    inst.cli("pane", "focus", win["pane"])
    inst.cli("edit", md, "--pane", win["pane"])
    inst.cli("editor", "mode")
    wait_until(lambda: doc(inst, win["pane"], md)["mode"] == "preview", 5, message="toggled to preview")
    inst.cli("editor", "close", md, "--pane", win["pane"])
    assert doc(inst, win["pane"], md) is None and doc(inst, win["pane"], txt) is not None


@pytest.mark.req("E-2")
def test_toggle_shows_the_source(inst, win, files, ui):
    _, md, _ = files
    inst.cli("edit", md, "--pane", win["pane"])
    assert ui.shortcut("cmd+shift+m") is not None, "⇧⌘M is a menu item"
    inst.cli("editor", "mode", "source", "--pane", win["pane"])
    wait_until(lambda: doc(inst, win["pane"], md)["mode"] == "source", 5, message="source mode")
    wait_until(lambda: ui.text_area("# Title"), 5, message="the source text is shown")
    inst.cli("editor", "mode", "--pane", win["pane"])
    wait_until(lambda: doc(inst, win["pane"], md)["mode"] == "preview", 5, message="toggled back to the preview")


@pytest.mark.req("E-3")
def test_dirty_documents_are_not_closed_silently_and_save_works(inst, win, files, ui):
    _, _, txt = files
    inst.cli("edit", txt, "--pane", win["pane"])
    area = wait_until(lambda: ui.text_area("plain notes"), 10, message="the editor text")
    inst.cli("pane", "focus", win["pane"])
    ui.activate()
    ui.enter_text("edited text", element=area, replace=True)
    wait_until(lambda: doc(inst, win["pane"], txt)["dirty"], 5, message="dirty")
    proc = inst.cli("editor", "close", txt, "--pane", win["pane"], check=False)
    assert proc.returncode != 0 and proc.stderr.strip()
    assert doc(inst, win["pane"], txt) is not None
    ui.press_keys("cmd+s")
    wait_until(lambda: open(txt).read().startswith("edited text"), 5, message="⌘S saved the file")
    wait_until(lambda: not doc(inst, win["pane"], txt)["dirty"], 5, message="clean after saving")
    ui.enter_text(" more", element=area)
    wait_until(lambda: doc(inst, win["pane"], txt)["dirty"], 5, message="dirty again")
    inst.cli("editor", "close", txt, "--force", "--pane", win["pane"])
    assert doc(inst, win["pane"], txt) is None
    assert open(txt).read().startswith("edited text") and " more" not in open(txt).read()


@pytest.mark.req("E-4")
def test_follows_changes_on_disk(inst, win, files, ui):
    _, _, txt = files
    inst.cli("edit", txt, "--pane", win["pane"])
    wait_until(lambda: ui.text_area("plain notes"), 10, message="the editor text")
    with open(txt, "w") as f:
        f.write("changed on disk\n")
    wait_until(lambda: ui.text_area("changed on disk"), 10, message="an unmodified document reloads")
    os.remove(txt)
    time.sleep(1)
    with open(txt, "w") as f:
        f.write("recreated\n")
    wait_until(lambda: ui.text_area("recreated"), 10, message="a deleted and recreated file is picked up")


@pytest.mark.req("E-5")
def test_non_utf8_files_keep_their_encoding(inst, win, tmp_path, ui):
    path = tmp_path / "latin1.txt"
    path.write_bytes("café crème\n".encode("latin-1"))
    inst.cli("edit", str(path), "--pane", win["pane"])
    area = wait_until(lambda: ui.text_area("caf"), 10, message="the editor text")
    inst.cli("pane", "focus", win["pane"])
    ui.activate()
    ui.enter_text("déjà vu\n", element=area, replace=True)
    wait_until(lambda: doc(inst, win["pane"], str(path))["dirty"], 5, message="dirty")
    ui.press_keys("cmd+s")
    time.sleep(1.5)
    data = path.read_bytes()
    if data == "café crème\n".encode("latin-1"):
        # Refusing to save is allowed, with a message; the file must be intact.
        assert doc(inst, win["pane"], str(path))["dirty"]
    else:
        assert data.startswith("déjà vu".encode("latin-1")), f"silently converted: {data[:20]!r}"
    inst.cli("editor", "close", str(path), "--force", "--pane", win["pane"])


@pytest.mark.req("E-6")
def test_refuses_what_it_cannot_edit(inst, win, tmp_path):
    fifo = tmp_path / "pipe"
    os.mkfifo(fifo)
    binary = tmp_path / "blob.bin"
    binary.write_bytes(bytes(range(256)) * 64)
    huge = tmp_path / "huge.txt"
    with open(huge, "wb") as f:
        f.truncate(512 * 1024 * 1024)   # sparse
    for bad in (tmp_path, fifo, "/dev/zero", binary, huge):
        t0 = time.time()
        proc = inst.cli("edit", str(bad), "--pane", win["pane"], check=False, timeout=30)
        assert proc.returncode != 0, bad
        assert proc.stderr.strip(), f"{bad}: refused with a message"
        assert time.time() - t0 < 15, f"{bad}: never hangs"
    assert inst.cli("ls", timeout=10).returncode == 0
    # UTF-8 text whose first bytes cut a character at a sampling boundary still opens.
    for cut in (1023, 4095, 8191):
        path = tmp_path / f"NOTES-{cut}"
        path.write_bytes(b"a" * cut + "é".encode("utf-8") + b"\n")
        inst.cli("edit", str(path), "--pane", win["pane"])
        assert doc(inst, win["pane"], str(path)) is not None


@pytest.mark.req("E-9", "P-4")
def test_edit_targets_the_calling_pane_and_never_falls_back(inst, win, files):
    _, md, _ = files
    other = inst.cli("tab", "new", "--window", win["window"]).stdout.strip()
    inst.cli("send", "--pane", other, "-e", f"{inst.target.cli_name} edit '{md}' && echo EDIT-OK")
    inst.cli("wait", "--pane", other, "--pattern", "^EDIT-OK$", "--timeout", "15")
    assert doc(inst, other, md) is not None
    assert doc(inst, win["pane"], md) is None, "opened in the caller's tab, not the focused one"
    before = docs(inst, win["pane"])
    for args in (["--pane", "no-such-pane"], ["--tab", "no-such-tab"]):
        proc = inst.cli("edit", md, *args, check=False)
        assert proc.returncode != 0 and proc.stderr.strip()
    assert docs(inst, win["pane"]) == before


@pytest.mark.req("E-1")
def test_editor_default_dry_run_names_this_app(inst):
    out = inst.cli("editor", "default", "--dry-run").stdout.strip()
    assert os.path.realpath(out) == os.path.realpath(inst.target.app)


def panes_of(inst, tab_id):
    for w in inst.tree()["windows"]:
        for t in w["tabs"]:
            if t["id"] == tab_id:
                return t["panes"]
    return None


def tab_ids(inst, window_id):
    return [t["id"] for w in inst.tree()["windows"] if w["id"] == window_id for t in w["tabs"]]


@pytest.mark.req("E-1", "E-9")
def test_files_open_in_panes_beside_the_caller_three_to_a_tab(inst, win, tmp_path):
    names = ["one.md", "two.json", "three.csv", "four.txt"]
    paths = []
    for name in names:
        (tmp_path / name).write_text({"md": "# One\n", "json": '{"a": [1, 2]}\n', "csv": "a,b\n1,2\n",
                                      "txt": "four\n"}[name.split(".")[1]])
        paths.append(str(tmp_path / name))
    inst.cli("edit", *paths[:3], "--pane", win["pane"])
    panes = panes_of(inst, win["tab"])
    # The caller, then each file to the right of the one before; three panes fill the tab.
    assert panes[0]["id"] == win["pane"] and "file" not in panes[0]
    assert [os.path.basename(p.get("file", "")) for p in panes[1:]] == ["one.md", "two.json"]
    assert [p["frame"]["x"] for p in panes] == sorted(p["frame"]["x"] for p in panes)
    # The third goes to a new tab right after the caller's.
    ids = tab_ids(inst, win["window"])
    third_tab = ids[ids.index(win["tab"]) + 1]
    assert [os.path.basename(p.get("file", "")) for p in panes_of(inst, third_tab)] == ["three.csv"]
    # A fourth goes beside the third, in that tab.
    inst.cli("edit", paths[3], "--tab", third_tab)
    assert [os.path.basename(p.get("file", "")) for p in panes_of(inst, third_tab)] == ["three.csv", "four.txt"]
    # Opening an open file again shows it where it is: no second pane.
    before = sum(len(panes_of(inst, t)) for t in tab_ids(inst, win["window"]))
    inst.cli("edit", paths[0], "--pane", win["pane"])
    assert sum(len(panes_of(inst, t)) for t in tab_ids(inst, win["window"])) == before
    # Keyboard focus stayed in the caller.
    assert inst.tree().get("current_pane") == win["pane"]
    # Modes: Markdown, JSON and CSV open as previews, other text as source; each document names its pane.
    modes = {os.path.basename(d["path"]): d["mode"] for d in docs(inst, win["pane"]) + docs(inst, panes_of(inst, third_tab)[0]["id"])}
    assert modes == {"one.md": "preview", "two.json": "preview", "three.csv": "preview", "four.txt": "source"}
    assert all(d.get("pane") for d in docs(inst, win["pane"]))
    proc = inst.cli("editor", "mode", "preview", paths[3], "--tab", third_tab, check=False)
    assert proc.returncode != 0 and "source" in proc.stderr


@pytest.mark.req("E-9")
def test_a_file_opened_from_a_pane_goes_beside_that_pane(inst, win, tmp_path):
    md = tmp_path / "beside.md"
    md.write_text("# Beside\n")
    left = win["pane"]
    right = inst.cli("split", "right", "--pane", left).stdout.strip()
    wait_until(lambda: inst.cli("read", "--pane", left, check=False).stdout.strip() != "", 20, message="prompt")
    inst.cli("send", "--pane", left, "-e", f"{inst.target.cli_name} edit '{md}' && echo EDIT-OK")
    inst.cli("wait", "--pane", left, "--pattern", "^EDIT-OK$", "--timeout", "15")
    order = [p["id"] for p in panes_of(inst, win["tab"])]
    file_pane = next(p["id"] for p in panes_of(inst, win["tab"]) if p.get("file"))
    assert order == [left, file_pane, right], "right of the calling pane, before its neighbour"


@pytest.mark.req("E-3")
def test_closing_a_file_pane_never_loses_edits(inst, win, tmp_path):
    txt = tmp_path / "keep.txt"
    txt.write_text("original\n")
    inst.cli("edit", str(txt), "--pane", win["pane"])
    pane = next(p["id"] for p in panes_of(inst, win["tab"]) if p.get("file"))
    assert inst.json("editor", "ls", "--pane", pane)["documents"][0]["pane"] == pane
    rpc(inst, "debug.editor.type", tab=win["tab"], path=str(txt), text="edited\n", replace=True)
    assert doc(inst, win["pane"], str(txt))["dirty"]
    inst.cli("pane", "close", pane)
    wait_until(lambda: txt.read_text() == "edited\n", 5, message="saved (the file was unchanged on disk)")
