"""The Markdown preview as Warp shows a Markdown file (SPEC MD-1 to MD-5, E-2; Warp parity, 2026-11-05).

The page is read and driven through Umi's internal `debug.ui.markdown` method, which runs the
preview's own script: computed styles, the code blocks' buttons, diagrams, find. Keys are pressed as
real key events with the preview focused, and the right-click menu is opened through the
accessibility tree.
"""

import os
import re
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
# greet someone
def greet(name):
    return "hi " + name * 2
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
    wait_until(lambda: style(inst, doc, "body")["roboto_loaded"], 5, message="the bundled Roboto loaded")
    body = style(inst, doc, "body", "font-family", "font-size", "line-height", "max-width")
    assert "Umi Roboto" in body["font-family"] and body["roboto_faces"] == 4, body
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


def window_of(inst):
    """A new window in another instance, as the win fixture gives one."""
    pane = inst.json("window", "new", "--name", "t-markdown")["pane"]
    wait_until(lambda: inst.cli("read", "--pane", pane, check=False).stdout.strip() != "", 20,
               message="the shell prompt")
    found = inst.find_pane(pane)
    return {"pane": found[2]["id"], "tab": found[1]["id"], "window": found[0]["id"]}


@pytest.mark.req("MD-1")
def test_on_a_light_background_the_preview_uses_warps_light_theme(fresh, doc):
    other = fresh(prefix="acc-md1-light-", args=["--background=#fafafa", "--foreground=#202020"])
    shown(other, window_of(other), doc)
    assert style(other, doc, "body", "color")["color"] == "rgba(17, 17, 17, 0.9)", "Warp Light's text"
    checked = style(other, doc, "li.task input:checked", "background-color")
    assert checked["background-color"] == "rgb(0, 194, 255)", "a done task's box is filled with Warp Light's accent"
    assert style(other, doc, "a", "color")["color"] == "rgb(0, 194, 255)", "links in Warp Light's accent"


@pytest.mark.req("MD-1")
def test_the_text_follows_the_terminals_font_size(fresh, doc):
    """Warp's Markdown text is its terminal's font size by default."""
    other = fresh(prefix="acc-md1-size-", args=["--font-size=15"])
    shown(other, window_of(other), doc)
    body = style(other, doc, "body", "font-size", "line-height")
    assert (body["font-size"], body["line-height"]) == ("15px", "22.5px"), body
    assert style(other, doc, "h1", "font-size")["font-size"] == "33.75px", "2.25 times the body"
    assert style(other, doc, ".umi-code pre code", "font-size")["font-size"] == "15px", "code too"


@pytest.mark.req("MD-2")
def test_code_blocks_are_highlighted_and_copy_or_run(inst, win, doc):
    pane = shown(inst, win, doc)
    state = md(inst, doc)
    assert state["labels"] == ["Python", "Shell", "Mermaid"], state
    assert state["highlighted"] == 2, "Python and shell are highlighted"
    color = lambda selector: style(inst, doc, ".umi-code " + selector, "color")["color"]
    assert color(".hljs-keyword") == "rgb(255, 143, 253)", "keywords in magenta"
    assert color(".hljs-title.function_") == "rgb(165, 213, 254)", "function names in blue"
    assert color(".hljs-string") == "rgb(180, 250, 114)", "strings in green"
    text = "rgba(255, 255, 255, 0.9)"
    assert (color(".hljs-comment"), color(".hljs-number"), color(".hljs-params")) == (text,) * 3, \
        "comments, numbers and parameters in the text color, as Warp's base16 highlighting leaves them"
    assert state["copy_buttons"] == 3 and state["run_buttons"] == 1, "Copy on each block, Run in terminal on shell"

    assert md(inst, doc, "click", selector=".umi-code .umi-copy", nth=0)["result"]
    wait_until(lambda: copied(inst, doc) == '# greet someone\ndef greet(name):\n    return "hi " + name * 2', 5, message="the block copied")

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
    # Warp's footer: the label, Raw / Rendered and Open full screen on the left; Copy on the right.
    footer = style(inst, doc, ".umi-mermaid .umi-code-footer", "display")["rect"]
    mode = style(inst, doc, ".umi-mermaid .umi-mode", "display")["rect"]
    full = style(inst, doc, ".umi-mermaid .umi-full", "display")
    copy = style(inst, doc, ".umi-mermaid .umi-copy", "display")["rect"]
    assert mode["x"] - footer["x"] < 120 and mode["x"] < full["rect"]["x"] < copy["x"], (footer, mode, full, copy)
    assert footer["x"] + footer["width"] - (copy["x"] + copy["width"]) < 12, "Copy at the right"
    assert copy["x"] - (full["rect"]["x"] + full["rect"]["width"]) > 40, "a gap between the two groups"

    assert md(inst, doc, "click", selector=".umi-mermaid .umi-raw")["result"]
    assert md(inst, doc)["mermaid"]["diagrams"] == 0, "Raw shows the source"
    assert style(inst, doc, ".umi-mermaid .umi-full", "display")["display"] == "none", "no full screen in Raw"
    md(inst, doc, "click", selector=".umi-mermaid .umi-full")
    assert not md(inst, doc)["lightbox"]["open"]
    assert md(inst, doc, "click", selector=".umi-mermaid .umi-rendered")["result"]
    assert md(inst, doc)["mermaid"]["diagrams"] == 1
    assert full["display"] != "none"

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
    """⌘E is Edit ▸ Find ▸ Use Selection for Find: in a file pane it toggles Preview / Source."""
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
def test_preview_and_source_toggle_with_cmd_e(inst, win, doc, ui):
    pane = shown(inst, win, doc)
    assert ui.button("Preview") is not None and ui.button("Source") is not None, "the control says Preview / Source"
    focus_preview(inst, ui, pane)
    ui.key(KEY_E, ui.CMD)
    wait_until(lambda: doc_mode(inst, win, doc) == "source", 5, message="⌘E shows the source")
    focus_preview(inst, ui, pane)
    ui.key(KEY_E, ui.CMD)
    wait_until(lambda: doc_mode(inst, win, doc) == "preview", 5, message="⌘E shows the preview again")

    # In a terminal ⌘E stays Ghostty's Use Selection for Find: it searches for the selected text.
    term = win["pane"]
    assert inst.rpc("debug.terminal.action", pane=term, action="select_all")["ok"]
    wait_until(lambda: inst.rpc("debug.selection", pane=term).get("text"), 5, message="a selection in the terminal")
    focus_preview(inst, ui, term)
    ui.key(KEY_E, ui.CMD)
    wait_until(lambda: inst.rpc("debug.ui.search", window=win["window"])["terminal_search"], 5,
               message="⌘E in a terminal searches for its selection")
    assert doc_mode(inst, win, doc) == "preview", "⌘E in a terminal leaves the file alone"


@pytest.mark.req("E-2")
def test_cmd_e_in_a_source_only_file_uses_the_selection_for_find(inst, win, ui, tmp_path):
    """A file with only a source view has no Preview / Source: ⌘E puts the selection in the find query."""
    path = tmp_path / "sample.py"
    path.write_text("def f():\n    return 1\n")
    pane = inst.json("edit", str(path), "--pane", win["pane"])["documents"][0]["pane"]
    editor = lambda: inst.rpc("debug.ui.editor", pane=pane)
    inst.cli("pane", "focus", pane)
    ui.activate()
    wait_until(lambda: editor()["editor_focused"], 5, message="the editor has keyboard focus")
    ui.key(126, ui.CMD)   # ⌘↑
    wait_until(lambda: editor()["selection"] == [0, 0], 5, message="the caret at the start")
    ui.key(124, ui.CMD | ui.SHIFT)   # ⇧⌘→: select the first line
    wait_until(lambda: editor()["selection"] == [0, 8], 5, message="the first line selected")
    ui.key(KEY_E, ui.CMD)
    wait_until(lambda: editor()["find"]["query"] == "def f():", 5, message="⌘E uses the selection for find")
    assert doc_mode(inst, win, str(path)) == "source"


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
    # The items drawn, each in its own row: the accessibility tree also lists an untitled, disabled
    # element at the first item's place that the menu doesn't draw (not one of the menu's items).
    rows, titles = set(), []
    for item in (ui.attr(menu, "AXChildren") or []) if menu is not None else []:
        place = tuple(re.findall(r"[xy]:(-?[\d.]+)", str(ui.attr(item, "AXPosition"))))
        if place in rows:
            continue
        rows.add(place)
        titles.append(ui.label(item))
    ui.key(ui.ESCAPE)
    assert titles == expected, titles
