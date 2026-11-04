# Comments in the editor, and pane sizes (BRIEF-comments-and-pane-sizes.md)

Released as **[0.7.0](https://github.com/alejoacelas/umi/releases/tag/v0.7.0)**. The feed serves it, signed, and the tag is at `c8c6a90a9`. Auto-update installs it at a quiet moment; this Mac still runs 0.6.3 until then. Spec: E-11 (comments) and L-19 (panes). Your words are in
`acceptance/REQUESTS.md`.

## 1. Comments

**What you get.** Select text in a Markdown preview. A **Comment ⌥⌘M** button appears by the
selection (also Edit ▸ Add Comment, ⌥⌘M). The comment shows in a margin beside its words, level with
them, and the words are highlighted. Each thread can be replied to, edited, resolved, reopened and
deleted (deleting asks first). Resolved threads hide until "Show resolved". In a panel narrower than
500 px, the selected thread floats under its words instead. In the source view, ⌥⌘M asks for the
comment in a sheet. Screenshots: `reference/comments-margin.png`, `-compose.png`, `-narrow.png`,
`-done.png`.

**Storage: in the file, in Roughdraft's format.** Roughdraft (github.com/Lex-Inc/roughdraft) keeps
review state in the `.md` file itself, as CriticMarkup plus YAML endmatter. Umi writes the same
format:

```
We will ship the **{==new parser==}{>>Why Friday?<<}{#c1}** on Friday.

---
comments:
  c1:
    by: user
    at: "2026-11-04T13:10:44.378Z"
    umi-quote: new parser
    umi-body: "Why Friday?"
  c2:
    body: They pass as of this morning.
    by: AI
    at: "2026-11-04T13:11:02.000Z"
    re: c1
```

Why this format:
- An agent given only the path sees every comment and its words by reading the file. No sidecar to
  find, and no app needed.
- The anchor sits in the text, so it moves with its words through agents' edits and git merges. A
  test merges a pull that edits another part of the file; the comment stays anchored.
- Roughdraft and Umi can read each other's files.

Umi adds one thing: a copy of each root comment's words and text (`umi-quote`, `umi-body`, keys
other readers ignore).

**When the anchored text is deleted:**
- **The words go but the markup stays** (`{====}{>>…<<}`): the comment stays at that spot, marked
  "the words were deleted".
- **An edit removes the markup itself:** the comment is *detached*. It still shows, at the top of
  the margin and in `umi comments`, with the words it was on (from the copy), until it's resolved
  or deleted.

Deleting a thread removes its markup and its endmatter entries. Adding and then deleting gives back
the original file byte for byte.

**How an agent reads and answers.** `umi comments` works on the file directly, with or without Umi
running:
- `umi comments FILE`: open comments with id, line, the words each is on, and replies (`--json`,
  `--all`).
- `umi comments reply | edit | resolve | reopen | delete FILE ID …`, and `add FILE --on TEXT …`.
- `umi comments wait FILE`: blocks until you press **Done** in the margin, then prints your
  comments. While an agent waits, the margin shows "Agent waiting".

The loop is: the agent runs `umi edit FILE` and then `umi comments wait FILE`. You comment and press
Done. The agent replies, edits and resolves, and you see its replies in the margin. The Claude Code
and Codex plugins (version 1.0.2) carry an `umi-comments` skill that teaches agents this.

## 2. Pane sizes

With your clarification: **a dragged divider stays where you drop it, and that divider now sizes
its panes by hand.** A pane between such dividers (or one of them and the end of the row) keeps its
size later. Only panes you never sized grow or shrink. They share equally the stretch between the
dragged divider and the nearest placed divider (or the row's end) on each side. In a row of four,
drag the first divider to 40% and the last to 90%: you get 40/25/25/10.

How it reads for nested splits:
- **A pane split the other way counts as one member of the row.** For example, a column inside a
  row. Its inside keeps its proportions, and its own dividers follow the same rule within the
  column.
- **The editor panel is the last member of the tab's top row.** Until you drag its divider, it
  shares space like any unsized pane. Once you drag it, it keeps its size.
- **Splits and closes** share space as before: the new pane gets 1/N, the rest keep their
  proportions. The dividers you placed stay placed, except those right next to the new or closed
  pane.
- **Double-click a divider, ⌃⌘= or `tab equalize`** to even things out. This also forgets the
  dividers you placed.
- **Keyboard resizes and `pane resize`** still move only the two neighbouring panes, and count as
  placing that divider.
- **Limit:** a divider can't be dragged past a divider you placed. The pane between them shrinks
  to a minimum instead.

The placed flags are saved with the layout. Layouts saved before 0.7.0 load with none placed.

## Tested

- **Swift unit tests (full suite):** succeeded, with 273 test cases passing and none failing. New: `UmiCommentsTests` (14 tests) and 8 tests in `SplitTreeTests`.
- **Acceptance, quick loop (`-m "not slow"`) on the published 0.7.0 build:** 368 passed, 1 failed, 22 skipped. The failure was `test_live.py::test_undo_and_redo_of_a_move_leave_a_tab_made_since_in_its_place[moved]` (tab undo, S-7). It passed in the previous loop on the same tab code and 3 times out of 3 alone, so it's an order-dependent flake I didn't chase. New:
  - `tests/test_comments.py`, 10 tests: the margin, the narrow layout, every card action, placement
    rules, a comment written while an agent edits the file, the CLI with no app running, git pull
    and detach, and the full review loop.
  - 5 pane tests in `test_umi_panes_ui.py`.
- **Dev copy:** both features driven live. Pane shares were measured in a real window. Every comment
  action was clicked through the margin's own script. The screenshots above are from it.
- **Found and fixed on the way:**
  - the margin crowded the text out of a narrow panel;
  - selection ends were mapped after closing `**`;
  - `/private/tmp` vs `/tmp` path names broke `comments wait`;
  - CRLF files got an extra blank line;
  - the CLI's build depended on a file outside its folder.

## Not done, or not checked

- **The UI tests didn't run.** The process running pytest has no Accessibility permission, so 9
  were skipped, including the ⌥⌘M menu-key check. Selections and clicks were driven through the
  page's script, not a real mouse.
- **The source view's comment sheet** wasn't exercised by a test. It uses the same `addComment` as
  the margin, which is tested.
- **Comments are on Markdown only.** JSON and CSV previews have none. The source view shows the raw
  markup, with no margin.
- **Root comments are stored on one line** (line breaks become spaces), because they sit inline.
  Replies keep their line breaks.
- **Some selections are refused:** overlapping another comment (reply instead) and code blocks.
  This is unlike Google Docs.
- **Two blocks tests started failing** because of `d29e2c90b`, which another session pushed during
  this run. It switched Umi to Warp's palette. The product was right and the tests' pixel
  thresholds were wrong; fixed and recorded in `TEST_CHANGES.md`.
- **Where the tests ran:** this Mac is "Alejo's MacBook Air (2)", the test Mac. AGENTS.md started
  asking (mid-run, from the other Mac) for tests in a worktree, not the shared checkout. My runs
  used the checkout.
- **Friction fixed on the way:**
  - right after any release, the Zig build aborted at a commit tagged with an Umi version;
  - `dev.sh` failed to sign after the dev copy set its custom icon.
