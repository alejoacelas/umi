"""The Markdown preview as Warp shows a Markdown file (SPEC MD-1 to MD-5, E-2; Warp parity, 2026-11-05).

The page is read and driven through Umi's internal `debug.ui.markdown` method, which runs the
preview's own script: computed styles, the code blocks' buttons, diagrams, find. Keys are pressed as
real key events with the preview focused, and the right-click menu is opened through the
accessibility tree.
"""

import os
import time

import pytest

from harness import wait_until

pytestmark = pytest.mark.editor

DOC = """# Title one

## Second

### Third

#### Fourth

##### Fifth

###### Sixth

Plain paragraph with `inline code` and a bare link https://example.com/path.

- [x] done
- [ ] todo

| Name | Value |
|---|---|
| alpha | 1 |

---

```python
def greet(name):
    return "hi " + name
```

```bash
echo umi-run-marker
```

```mermaid
graph TD
  A[Start] --> B[Finish]
```

needle one, needle two, Needle three.
"""

KEY_F, KEY_G, KEY_E = 3, 5, 14


@pytest.fixture
def doc(tmp_path):
    path = tmp_path / "warp.md"
    path.write_text(DOC)
    return str(path)


def md(inst, path, action="state", **params):
    return inst.rpc("debug.ui.markdown", path=path, action=action, **params)


def file_pane(inst, win, path):
    return next(d["pane"] for d in inst.json("editor", "ls", "--tab", win["tab"])["documents"]
                if os.path.realpath(d["path"]) == os.path.realpath(path))


def shown(inst, win, path):
    """Open the file in the preview beside win's terminal; wait for the preview's script."""
    inst.cli("sidebar", "off", "--window", win["window"])
    inst.cli("edit", path, "--pane", win["pane"])
    wait_until(lambda: ready(inst, path), 15, message="the preview's script")
    return file_pane(inst, win, path)


def ready(inst, path):
    """The preview's script has run (every test document has three code blocks)."""
    try:
        return md(inst, path).get("code_blocks") == 3
    except AssertionError:
        return False


def style(inst, path, selector, *props):
    return md(inst, path, "style", selector=selector, props=",".join(props))


def focus_preview(inst, ui, pane):
    ui.activate()
    inst.cli("pane", "focus", pane)
    time.sleep(0.4)



def copied(inst, path):
    """What Copy put on the pasteboard (a private one: tests never touch the user's clipboard)."""
    return md(inst, path, "pasteboard")["text"]


def doc_mode(inst, win, path):
    return next(d["mode"] for d in inst.json("editor", "ls", "--tab", win["tab"])["documents"]
                if os.path.realpath(d["path"]) == os.path.realpath(path))


def panes_of(inst, tab):
    return next(t for w in inst.tree()["windows"] for t in w["tabs"] if t["id"] == tab)["panes"]


@pytest.mark.req("MD-1")
def test_the_preview_looks_like_warps_markdown_view(inst, win, doc):
    shown(inst, win, doc)
    body = style(inst, doc, "body", "font-family", "font-size", "line-height", "max-width")
    assert "Umi Roboto" in body["font-family"] and body["roboto_loaded"], body
    assert body["font-size"] == "13px" and body["line-height"] == "19.5px", body
    assert body["max-width"] == "none" and abs(body["rect"]["width"] - body["page_width"]) < 1, "the full width of the pane"

    sizes = {"h1": 29.25, "h2": 23.4, "h3": 19.5, "h4": 13.0, "h5": 10.79, "h6": 8.71}
    weights = {"h1": "600", "h2": "600", "h3": "600", "h4": "600", "h5": "400", "h6": "400"}
    for tag, size in sizes.items():
        h = style(inst, doc, tag, "font-size", "font-weight")
        assert abs(float(h["font-size"].removesuffix("px")) - size) < 0.05, (tag, h)
        assert h["font-weight"] == weights[tag], (tag, h)

    code = style(inst, doc, "p code", "color", "background-color")
    assert code["color"] == "rgb(255, 130, 114)", "inline code in the terminal's red"
    assert code["background-color"] == "rgba(255, 255, 255, 0.15)", "on surface_3"

    block = style(inst, doc, ".umi-code", "border-top-width", "border-top-style", "border-top-color")
    assert (block["border-top-width"], block["border-top-style"]) == ("1px", "solid")
    assert block["border-top-color"] == "rgba(255, 255, 255, 0.15)"

    cell = style(inst, doc, ".umi-table td", "padding-left", "padding-top", "color")
    assert cell["padding-left"] == cell["padding-top"] == "12px"
    assert cell["color"] == "rgba(255, 255, 255, 0.6)", "table text in the secondary color"
    assert style(inst, doc, ".umi-table", "overflow-x")["overflow-x"] == "auto", "wide tables scroll sideways"

    assert style(inst, doc, "hr", "height")["height"] == "3px"
    checked = style(inst, doc, "li.task input:checked", "background-color")
    assert checked["background-color"] == "rgb(25, 170, 216)", "a done task's box is filled with the accent"

    links = md(inst, doc)["links"]
    assert {"text": "https://example.com/path", "href": "https://example.com/path"} in links, links


@pytest.mark.req("MD-2")
def test_code_blocks_are_highlighted_and_copy_or_run(inst, win, doc):
    pane = shown(inst, win, doc)
    state = md(inst, doc)
    assert state["labels"] == ["Python", "Shell", "Mermaid"], state
    assert state["highlighted"] == 2, "Python and shell are highlighted"
    assert style(inst, doc, ".umi-code .hljs-keyword", "color")["color"] == "rgb(255, 143, 253)", "keywords in magenta"
    assert state["copy_buttons"] == 3 and state["run_buttons"] == 1, "Copy on each block, Run in terminal on shell"

    assert md(inst, doc, "click", selector=".umi-code .umi-copy", nth=0)["result"]
    wait_until(lambda: copied(inst, doc) == 'def greet(name):\n    return "hi " + name', 5, message="the block copied")

    assert md(inst, doc, "click", selector=".umi-code .umi-run", nth=0)["result"]
    wait_until(lambda: "echo umi-run-marker" in inst.screen(win["pane"]), 5,
               message="the command in the tab's terminal")
    time.sleep(0.5)
    lines = [line.strip() for line in inst.screen(win["pane"]).splitlines()]
    assert "umi-run-marker" not in lines, "put in the terminal's input, not run"
    focused = [p["id"] for p in panes_of(inst, win["tab"]) if p.get("focused")]
    assert focused == [win["pane"]], "the terminal takes focus"
    inst.cli("keys", "--pane", win["pane"], "ctrl+u", check=False)


@pytest.mark.req("MD-3")
def test_mermaid_diagrams_render_and_open_larger(inst, win, doc):
    shown(inst, win, doc)
    wait_until(lambda: md(inst, doc)["mermaid"]["diagrams"] == 1, 20, message="the diagram drawn")
    assert md(inst, doc)["mermaid"]["errors"] == []
    assert md(inst, doc, "click", selector=".umi-mermaid .umi-raw")["result"]
    assert md(inst, doc)["mermaid"]["diagrams"] == 0, "Raw shows the source"
    assert md(inst, doc, "click", selector=".umi-mermaid .umi-rendered")["result"]
    assert md(inst, doc)["mermaid"]["diagrams"] == 1

    assert md(inst, doc, "click", selector=".umi-mermaid .umi-full")["result"]
    assert md(inst, doc)["lightbox"] == {"open": True, "svg": True}
    md(inst, doc, "key", name="Escape")
    assert not md(inst, doc)["lightbox"]["open"], "Esc closes the larger view"


@pytest.mark.req("MD-3")
def test_a_broken_diagram_shows_its_source_and_error(inst, win, tmp_path):
    path = tmp_path / "broken.md"
    path.write_text("```mermaid\ngraph TD\n  A -->\n```\n\n```py\nx = 1\n```\n\n```sh\nls\n```\n")
    shown(inst, win, str(path))
    wait_until(lambda: md(inst, str(path))["mermaid"]["errors"], 20, message="the parse error shown")
    assert md(inst, str(path))["mermaid"]["diagrams"] == 0
    assert style(inst, str(path), ".umi-mermaid pre", "display")["display"] != "none", "the source stays on show"
    error = style(inst, str(path), ".umi-mermaid-error", "padding-top")
    assert error["padding-top"] == "8px" and error["rect"]["height"] > 8 + 12, ("the error's text is drawn", error)


@pytest.mark.req("MD-4")
def test_find_through_edit_find_items(inst, win, doc):
    """Edit ▸ Find's items (⌘F, ⌘G, ⇧⌘G) as they reach the preview: through the responder chain."""
    pane = shown(inst, win, doc)
    assert md(inst, doc, "perform", selector="find")["performed"]
    find = md(inst, doc)["find"]
    assert find["open"] and find["focused"], find
    md(inst, doc, "find_type", text="needle")
    find = md(inst, doc)["find"]
    assert (find["count"], find["label"], find["highlighted"]) == (3, "1/3", 3), find

    md(inst, doc, "perform", selector="findNext")
    assert md(inst, doc)["find"]["label"] == "2/3"
    md(inst, doc, "key", name="Enter")
    assert md(inst, doc)["find"]["label"] == "3/3"
    md(inst, doc, "perform", selector="findNext")
    assert md(inst, doc)["find"]["label"] == "1/3", "wraps around"
    md(inst, doc, "perform", selector="findPrevious")
    assert md(inst, doc)["find"]["label"] == "3/3"
    md(inst, doc, "key", name="Enter", shift=True)
    assert md(inst, doc)["find"]["label"] == "2/3"
    assert md(inst, doc)["find"]["current_text"] == "needle"

    assert md(inst, doc, "click", selector="#umi-find .umi-case")["result"]
    assert md(inst, doc)["find"]["count"] == 2, "Aa matches case"
    md(inst, doc, "click", selector="#umi-find .umi-case")
    assert md(inst, doc, "click", selector="#umi-find .umi-regex")["result"]
    md(inst, doc, "find_type", text="s? (one|two)")
    assert md(inst, doc)["find"]["count"] == 2, "a regular expression"
    md(inst, doc, "click", selector="#umi-find .umi-regex")
    find = md(inst, doc)["find"]
    assert (find["count"], find["label"]) == (0, "No matches"), find

    md(inst, doc, "key", name="Escape")
    find = md(inst, doc)["find"]
    assert not find["open"] and find["highlighted"] == 0, find
    assert pane


@pytest.mark.req("E-2")
def test_cmd_e_menu_action_toggles_a_file_pane_but_not_a_terminal(inst, win, doc):
    """⌘E is Edit ▸ Find ▸ Use Selection for Find: in a file pane it toggles Rendered / Raw."""
    shown(inst, win, doc)
    assert md(inst, doc, "perform", selector="selectionForFind")["performed"]
    wait_until(lambda: doc_mode(inst, win, doc) == "source", 5, message="raw")
    inst.cli("editor", "mode", "preview", doc, "--pane", win["pane"], check=False)
    wait_until(lambda: doc_mode(inst, win, doc) == "preview", 5, message="rendered again")
    wait_until(lambda: ready(inst, doc), 10, message="the preview back")
    md(inst, doc, "perform", selector="selectionForFind", pane=win["pane"])
    time.sleep(0.3)
    assert doc_mode(inst, win, doc) == "preview", "in a terminal it is the terminal's"


@pytest.mark.req("MD-5")
def test_right_click_menu_has_warps_items_and_they_work(inst, win, doc):
    pane = shown(inst, win, doc)
    expected = ["Copy file path", "-", "Split pane right", "Split pane left", "Split pane down", "Split pane up",
                "Maximize pane", "Close pane"]
    assert md(inst, doc, "menu")["items"] == expected
    assert md(inst, doc, "menu", selection=True)["items"] == ["Copy", "-"] + expected

    md(inst, doc, "menu", choose="Copy file path")
    assert os.path.realpath(copied(inst, doc)) == os.path.realpath(doc)

    md(inst, doc, "menu", choose="Maximize pane")
    zoomed = lambda: next(p for p in panes_of(inst, win["tab"]) if p["id"] == pane)["zoomed"]
    wait_until(zoomed, 5, message="Maximize pane zooms it")
    assert "Minimize pane" in md(inst, doc, "menu")["items"]
    md(inst, doc, "menu", choose="Minimize pane")
    wait_until(lambda: not zoomed(), 5, message="Minimize pane unzooms it")

    before = len(panes_of(inst, win["tab"]))
    md(inst, doc, "menu", choose="Split pane down")
    wait_until(lambda: len(panes_of(inst, win["tab"])) == before + 1, 5, message="Split pane down adds a pane")

    md(inst, doc, "menu", choose="Close pane")
    wait_until(lambda: all(p["id"] != pane for p in panes_of(inst, win["tab"])), 5,
               message="Close pane closes the file's pane")


# ---- With the keyboard and the mouse (UI tests: an unlocked screen and Accessibility) ----------

@pytest.mark.req("MD-4")
def test_find_keys(inst, win, doc, ui):
    pane = shown(inst, win, doc)
    focus_preview(inst, ui, pane)
    ui.key(KEY_F, ui.CMD)
    wait_until(lambda: md(inst, doc)["find"]["focused"], 5, message="⌘F opens find with its field focused")
    ui.type_text("needle")
    wait_until(lambda: md(inst, doc)["find"]["label"] == "1/3", 5, message="three matches, any case")
    ui.key(KEY_G, ui.CMD)
    wait_until(lambda: md(inst, doc)["find"]["label"] == "2/3", 5, message="⌘G goes to the next match")
    ui.key(ui.RETURN)
    wait_until(lambda: md(inst, doc)["find"]["label"] == "3/3", 5, message="Return goes to the next match")
    ui.key(KEY_G, ui.CMD | ui.SHIFT)
    wait_until(lambda: md(inst, doc)["find"]["label"] == "2/3", 5, message="⇧⌘G goes back")
    ui.key(ui.ESCAPE)
    wait_until(lambda: not md(inst, doc)["find"]["open"], 5, message="Esc closes find")


@pytest.mark.req("MD-3")
def test_esc_key_closes_the_larger_diagram(inst, win, doc, ui):
    pane = shown(inst, win, doc)
    wait_until(lambda: md(inst, doc)["mermaid"]["diagrams"] == 1, 20, message="the diagram drawn")
    md(inst, doc, "click", selector=".umi-mermaid .umi-full")
    focus_preview(inst, ui, pane)
    ui.key(ui.ESCAPE)
    wait_until(lambda: not md(inst, doc)["lightbox"]["open"], 5, message="Esc closes the larger view")


@pytest.mark.req("E-2")
def test_rendered_and_raw_toggle_with_cmd_e(inst, win, doc, ui):
    pane = shown(inst, win, doc)
    assert ui.button("Rendered") is not None and ui.button("Raw") is not None, "the control says Rendered / Raw"
    focus_preview(inst, ui, pane)
    ui.key(KEY_E, ui.CMD)
    wait_until(lambda: doc_mode(inst, win, doc) == "source", 5, message="⌘E shows the raw file")
    focus_preview(inst, ui, pane)
    ui.key(KEY_E, ui.CMD)
    wait_until(lambda: doc_mode(inst, win, doc) == "preview", 5, message="⌘E shows it rendered again")

    item = ui.shortcut("cmd+e")
    assert item is not None and ui.label(item).startswith("Use Selection for Find"), "⌘E stays Ghostty's menu item"
    focus_preview(inst, ui, win["pane"])
    ui.key(KEY_E, ui.CMD)
    time.sleep(0.5)
    assert doc_mode(inst, win, doc) == "preview", "⌘E in a terminal leaves the file alone"


@pytest.mark.req("MD-5")
def test_right_click_opens_warps_menu(inst, win, doc, ui):
    pane = shown(inst, win, doc)
    expected = ["Copy file path", "", "Split pane right", "Split pane left", "Split pane down", "Split pane up",
                "Maximize pane", "Close pane"]
    focus_preview(inst, ui, pane)
    web = ui.find(lambda e: ui.role(e) == "AXWebArea")
    assert web is not None, "the preview's web area"
    ui.AX.AXUIElementPerformAction(web, "AXShowMenu")
    time.sleep(0.6)
    menu = ui.find(lambda e: ui.role(e) == "AXMenu", root=ui.app)
    titles = [ui.label(i) for i in (ui.attr(menu, "AXChildren") or [])] if menu is not None else []
    ui.key(ui.ESCAPE)
    assert titles == expected, titles
