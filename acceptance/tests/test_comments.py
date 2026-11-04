"""Comments on documents in the editor (SPEC E-11).

The margin is driven through Umi's internal `debug.ui.comments` method, which runs the margin's own
script in the preview the way a click does: select words in the rendered page, press Comment, type,
submit, click the card's controls. What agents see is checked through the file itself and
`<cli> comments`, also with no app running.
"""

import json
import os
import re
import subprocess
import time

import pytest

from harness import wait_until

pytestmark = pytest.mark.editor

DOC = """# Release plan

We will ship the **new parser** on Friday, after the [benchmarks](https://example.com/bench) pass.

## Risks

- The cache may grow without bound under load.
- Nobody owns the migration script yet.

| Area | Owner |
|---|---|
| Parser | Ana |

```
{==not a comment==}{>>literal<<}
```
"""


@pytest.fixture
def doc(tmp_path):
    path = tmp_path / "plan.md"
    path.write_text(DOC)
    return str(path)


def margin(inst, path, action="state", **params):
    return inst.rpc("debug.ui.comments", path=path, action=action, **params)


def shown(inst, win, path, fraction=0.75):
    """Open the file in the preview, with the editor panel at `fraction` of the tab (and no
    sidebar, whose width other tests change, taking the window's width)."""
    inst.cli("sidebar", "off", "--window", win["window"])
    inst.cli("edit", path, "--pane", win["pane"])
    inst.rpc("debug.ui.editor.divider", tab=win["tab"], fraction=fraction)
    wait_until(lambda: _ready(inst, path), 10, message="the preview's comment margin")


def _ready(inst, path):
    try:
        return "cards" in margin(inst, path)
    except AssertionError:
        return False


def comment_on(inst, path, words, text, nth=0):
    """What the user does: select the words in the preview, press Comment, type, submit."""
    assert margin(inst, path, "select", text=words, nth=nth)["result"], f"the Comment button shows for {words!r}"
    assert margin(inst, path, "add")["result"], "the comment box opens"
    assert margin(inst, path, "type", text=text)["result"]
    before = open(path).read()
    assert margin(inst, path, "submit")["result"]
    wait_until(lambda: open(path).read() != before or margin(inst, path)["error"], 5, message="the comment saved")
    if open(path).read() != before:
        # The page reloads with the new comment (no comment box open any more).
        wait_until(lambda: _ready(inst, path) and not margin(inst, path)["composing"], 5, message="the page reloaded")


def listed(inst, path, *extra):
    return inst.json("comments", path, *extra)["comments"]


def card(inst, path, cid):
    return next((c for c in margin(inst, path)["cards"] if c["id"] == cid), None)


@pytest.mark.req("E-11")
def test_a_comment_in_the_margin_is_in_the_file_beside_its_words(inst, win, doc):
    shown(inst, win, doc)
    comment_on(inst, doc, "new parser", "Why Friday? The benchmarks still fail.")
    text = open(doc).read()
    # The comment sits right after its words, inside the bold, in Roughdraft's format.
    assert "**{==new parser==}{>>Why Friday? The benchmarks still fail.<<}{#c1}** on Friday" in text
    assert re.search(r"\n---\ncomments:\n  c1:\n    by: user\n    at: \"20\d\d-", text)
    # The margin shows it level with its words, which are highlighted.
    wait_until(lambda: card(inst, doc, "c1"), 5, message="the card")
    c = card(inst, doc, "c1")
    assert "Why Friday?" in c["text"] and c["anchor_text"] == "new parser"
    assert abs(c["top"] - c["anchor_top"]) < 2
    state = margin(inst, doc)
    assert not state["narrow"], f"the window is too small for this test: {state['width']}"
    assert state["margin"] and [m["text"] for m in state["marks"]] == ["new parser"]
    assert all(m["right"] < c["left"] for m in state["marks"]), f"the margin is beside the text, not over it: {state}"
    # A second comment lower down gets its own card, below the first.
    comment_on(inst, doc, "Nobody owns the migration script", "I can take this.")
    cards = {c["id"]: c for c in margin(inst, doc)["cards"]}
    assert cards["c2"]["top"] >= cards["c1"]["top"] + cards["c1"]["height"]
    assert abs(cards["c2"]["top"] - cards["c2"]["anchor_top"]) < 2
    # An agent reads both, with the words each is on.
    got = listed(inst, doc)
    assert [(t["id"], t["quote"], t["by"], t["line"]) for t in got] == [
        ("c1", "new parser", "user", 3), ("c2", "Nobody owns the migration script", "user", 8)]


@pytest.mark.req("E-11")
def test_a_narrow_editor_shows_the_selected_thread_under_its_words(inst, win, doc):
    shown(inst, win, doc, fraction=0.2)
    wait_until(lambda: margin(inst, doc)["narrow"], 5, message="a narrow panel")
    comment_on(inst, doc, "new parser", "Why Friday?")
    comment_on(inst, doc, "migration script", "Who?")
    state = margin(inst, doc)
    assert not state["margin"], "no column is kept for comments; the text keeps the width"
    # Only the selected thread shows, just under its words.
    assert [c["id"] for c in state["cards"]] == ["c2"]
    c = state["cards"][0]
    assert c["top"] > c["anchor_top"] and c["top"] - c["anchor_top"] < 60
    margin(inst, doc, "mark", id="c1")
    wait_until(lambda: [c["id"] for c in margin(inst, doc)["cards"]] == ["c1"], 5, message="c1 shown when its words are clicked")
    # Wider again: the margin comes back with both.
    inst.rpc("debug.ui.editor.divider", tab=win["tab"], fraction=0.75)
    wait_until(lambda: margin(inst, doc)["margin"] and len(margin(inst, doc)["cards"]) == 2, 5, message="the margin")


@pytest.mark.req("E-11")
def test_reply_edit_resolve_and_delete_in_the_margin(inst, win, doc):
    shown(inst, win, doc)
    comment_on(inst, doc, "cache may grow", "How fast?")
    margin(inst, doc, "thread", id="c1")
    assert margin(inst, doc, "type", text="Measured: 2 MB a minute.")["result"]
    margin(inst, doc, "submit")
    wait_until(lambda: listed(inst, doc)[0]["replies"], 5, message="the reply")
    assert listed(inst, doc)[0]["replies"][0]["body"] == "Measured: 2 MB a minute."
    # Edit the comment from its menu.
    margin(inst, doc, "thread", id="c1")
    margin(inst, doc, "click", selector='.umi-card[data-id="c1"] .umi-root .umi-more')
    margin(inst, doc, "click", selector='.umi-card[data-id="c1"] .umi-root .umi-menu button')
    margin(inst, doc, "type", text="How fast does it grow?")
    margin(inst, doc, "submit")
    wait_until(lambda: listed(inst, doc)[0]["body"] == "How fast does it grow?", 5, message="the edit")
    # Resolve: the card goes, the words lose their highlight; Show resolved brings it back.
    margin(inst, doc, "click", selector='.umi-card[data-id="c1"] .umi-resolve')
    wait_until(lambda: not listed(inst, doc), 5, message="resolved")
    assert listed(inst, doc, "--all")[0]["status"] == "resolved"
    wait_until(lambda: not margin(inst, doc)["cards"], 5, message="the resolved card hidden")
    assert margin(inst, doc)["marks"][0]["resolved"]
    margin(inst, doc, "click", selector="#umi-bar .umi-toggle-resolved")
    assert [c["id"] for c in margin(inst, doc)["cards"]] == ["c1"]
    margin(inst, doc, "click", selector='.umi-card[data-id="c1"] .umi-reopen')
    wait_until(lambda: listed(inst, doc), 5, message="reopened")
    # Delete the thread (asks first): the file is as it was.
    margin(inst, doc, "thread", id="c1")
    margin(inst, doc, "click", selector='.umi-card[data-id="c1"] .umi-root .umi-more')
    margin(inst, doc, "click", selector='.umi-card[data-id="c1"] .umi-root .umi-menu button:last-child')
    assert open(doc).read() != DOC, "nothing is deleted before the confirmation"
    margin(inst, doc, "click", selector='.umi-card[data-id="c1"] .umi-danger')
    wait_until(lambda: open(doc).read() == DOC, 5, message="the thread and its markup gone")


@pytest.mark.req("E-11")
def test_comments_stay_in_one_block_and_off_code_and_other_comments(inst, win, doc):
    shown(inst, win, doc)
    comment_on(inst, doc, "after the bench", "The link counts too.")
    # A link only partly selected is taken whole, so it still works.
    assert "{==after the [benchmarks](https://example.com/bench)==}" in open(doc).read()
    comment_on(inst, doc, "Ana", "Out next week.")
    assert "| {==Ana==}{>>Out next week.<<}{#c2} |" in open(doc).read()
    # Overlapping another comment: refused, with a reason, and nothing written.
    before = open(doc).read()
    comment_on(inst, doc, "Friday, after", "overlap")
    assert "overlaps another comment" in margin(inst, doc)["error"]
    margin(inst, doc, "click", selector=".umi-compose .umi-btn:not(.umi-primary)")
    # In a code block, review markup is literal text: no comment, and none can be added there.
    comment_on(inst, doc, "not a comment", "code")
    assert "code blocks" in margin(inst, doc)["error"]
    assert open(doc).read() == before
    assert [t["id"] for t in listed(inst, doc)] == ["c1", "c2"]


@pytest.mark.req("E-11")
def test_the_shortcut_comments_on_the_selection(inst, win, doc, ui):
    shown(inst, win, doc)
    assert ui.shortcut("cmd+option+m") is not None, "⌥⌘M is Edit ▸ Add Comment"


@pytest.mark.req("E-11")
def test_add_comment_starts_a_comment_on_the_selection(inst, win, doc):
    """Edit ▸ Add Comment (⌥⌘M) runs the same action as the Comment button."""
    shown(inst, win, doc)
    margin(inst, doc, "shortcut")
    wait_until(lambda: "Select the text" in margin(inst, doc)["toast"], 5, message="asks for a selection")
    margin(inst, doc, "select", text="without bound")
    margin(inst, doc, "shortcut")
    wait_until(lambda: margin(inst, doc)["composing"], 5, message="the comment box")
    margin(inst, doc, "type", text="Bound it.")
    margin(inst, doc, "submit")
    wait_until(lambda: listed(inst, doc), 5, message="saved")
    assert listed(inst, doc)[0]["quote"] == "without bound"


@pytest.mark.req("E-11")
def test_writing_a_comment_survives_an_agent_editing_the_file(inst, win, doc):
    shown(inst, win, doc)
    assert margin(inst, doc, "select", text="cache may grow")["result"]
    margin(inst, doc, "add")
    margin(inst, doc, "type", text="How fast?")
    # An agent changes the file while the comment is being written.
    with open(doc, "w") as f:
        f.write(DOC.replace("# Release plan\n", "# Release plan\n\nA line the agent added.\n"))
    time.sleep(1.0)
    assert margin(inst, doc)["composing"], "the page wasn't reloaded under the comment box"
    margin(inst, doc, "submit")
    wait_until(lambda: listed(inst, doc), 5, message="saved")
    text = open(doc).read()
    assert "A line the agent added." in text and "- The {==cache may grow==}{>>How fast?<<}{#c1}" in text
    # And the page shows the agent's line now.
    wait_until(lambda: margin(inst, doc, "select", text="A line the agent added.")["result"], 5, message="reloaded")


def run_cli(target, *args, stdin=None, state=None):
    """The CLI with no app behind it (its own empty state directory)."""
    env = dict(os.environ)
    env["UMI_STATE_DIR"] = state
    return subprocess.run([target.cli_path, *args], capture_output=True, text=True, env=env, input=stdin, timeout=60)


@pytest.mark.req("E-11")
def test_agents_read_and_answer_comments_with_no_app_running(target, tmp_path, doc):
    state = str(tmp_path / "no-app")
    def cli(*args, stdin=None):
        proc = run_cli(target, *args, stdin=stdin, state=state)
        assert proc.returncode == 0, proc.stderr
        return proc.stdout
    cli("comments", "add", doc, "--on", "new parser", "--by", "user", "Why Friday?")
    out = cli("comments", doc)
    assert "c1" in out and 'on: "new parser"' in out and "Why Friday?" in out and "line 3" in out
    cli("comments", "reply", doc, "c1", "-", stdin="The release train leaves Friday.\nIt's fixed.")
    cli("comments", "resolve", doc, "c1", "--note", "explained")
    assert "no open comments" in cli("comments", doc)
    got = json.loads(cli("--json", "comments", doc, "--all"))["comments"][0]
    assert got["status"] == "resolved" and got["resolved_note"] == "explained"
    assert got["replies"][0] == {"id": "c2", "body": "The release train leaves Friday.\nIt's fixed.", "by": "AI",
                                 "at": got["replies"][0]["at"]}
    cli("comments", "delete", doc, "c1")
    assert open(doc).read() == DOC
    # Errors say what's wrong.
    bad = run_cli(target, "comments", "reply", doc, "c9", "x", state=state)
    assert bad.returncode != 0 and "no comment c9" in bad.stderr
    bad = run_cli(target, "comments", "add", doc, "--on", "not in the text", "x", state=state)
    assert bad.returncode != 0 and "isn't in the text" in bad.stderr
    assert "comments" in cli("help")


@pytest.mark.req("E-11")
def test_comments_survive_git_pulls_and_edits_and_detach_when_their_words_go(inst, win, tmp_path, target):
    def git(cwd, *args):
        subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True,
                       env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                            "GIT_COMMITTER_EMAIL": "t@t"})
    remote, mine, theirs = tmp_path / "remote.git", tmp_path / "mine", tmp_path / "theirs"
    git(tmp_path, "init", "-q", "--bare", str(remote))
    git(tmp_path, "clone", "-q", str(remote), str(mine))
    (mine / "plan.md").write_text(DOC)
    git(mine, "add", "plan.md"); git(mine, "commit", "-qm", "plan"); git(mine, "push", "-q", "origin", "HEAD")
    git(tmp_path, "clone", "-q", str(remote), str(theirs))
    path = str(mine / "plan.md")
    shown(inst, win, path)
    comment_on(inst, path, "cache may grow", "How fast?")
    git(mine, "commit", "-qam", "comment")
    # Someone else edits another part of the file and pushes; this copy pulls (a merge).
    other = (theirs / "plan.md").read_text().replace("# Release plan\n", "# Release plan (v2)\n")
    (theirs / "plan.md").write_text(other)
    git(theirs, "commit", "-qam", "title"); git(theirs, "push", "-q", "origin", "HEAD")
    git(mine, "pull", "-q", "--no-rebase", "--no-edit")
    text = open(path).read()
    assert text.startswith("# Release plan (v2)\n") and "{==cache may grow==}{>>How fast?<<}{#c1}" in text
    wait_until(lambda: (card(inst, path, "c1") or {}).get("anchor_text") == "cache may grow", 5, message="still anchored")
    # An agent rewrites the sentence and drops the markup: the comment is detached, not lost.
    with open(path, "w") as f:
        f.write(re.sub(r"The \{==cache may grow==\}\{>>How fast\?<<\}\{#c1\}", "Memory use is capped at 2 GB", text))
    got = listed(inst, path)
    assert got[0]["detached"] and got[0]["body"] == "How fast?" and got[0]["quote"] == "cache may grow"
    wait_until(lambda: "The text this was on was removed." in ((card(inst, path, "c1") or {}).get("text") or ""), 5,
               message="the detached card")


@pytest.mark.req("E-11")
def test_the_review_loop_an_agent_shows_waits_reads_and_answers(inst, win, doc):
    """The main use: an agent shows a document, the user comments and presses Done, the agent
    gets the comments, answers and changes the text, and the user sees it in the margin."""
    inst.cli("sidebar", "off", "--window", win["window"])
    inst.cli("edit", doc, "--pane", win["pane"])
    inst.rpc("debug.ui.editor.divider", tab=win["tab"], fraction=0.75)
    waiter = subprocess.Popen([inst.target.cli_path, "comments", "wait", doc, "--timeout", "60"], env=inst.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_until(lambda: _ready(inst, doc) and "Agent waiting" in margin(inst, doc)["bar"], 10, message="Agent waiting")
        comment_on(inst, doc, "on Friday", "Can it be Thursday?")
        comment_on(inst, doc, "Nobody owns the migration script", "Ask Ben.")
        assert waiter.poll() is None, "comments alone don't end the wait"
        margin(inst, doc, "click", selector="#umi-bar .umi-done")
        out, err = waiter.communicate(timeout=10)
        assert waiter.returncode == 0, err
        assert "Can it be Thursday?" in out and 'on: "on Friday"' in out and "Ask Ben." in out
        wait_until(lambda: "has your comments" in margin(inst, doc)["toast"], 5, message="the Sent notice")
    finally:
        if waiter.poll() is None:
            waiter.kill()
    # The agent answers one, makes the change and resolves the other.
    inst.cli("comments", "reply", doc, "c1", "Thursday works; changed.")
    text = open(doc).read().replace("{==on Friday==}", "{==on Thursday==}")
    open(doc, "w").write(text)
    inst.cli("comments", "resolve", doc, "c2", "--note", "Ben owns it now")
    wait_until(lambda: [c["id"] for c in margin(inst, doc)["cards"]] == ["c1"], 5, message="c2 resolved in the margin")
    c1 = card(inst, doc, "c1")
    assert "Thursday works; changed." in c1["text"] and c1["anchor_text"] == "on Thursday"
    # Done with nobody waiting says so.
    margin(inst, doc, "click", selector="#umi-bar .umi-done")
    wait_until(lambda: "No agent is waiting" in margin(inst, doc)["toast"], 5, message="the notice")
