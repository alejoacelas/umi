# Brief: comments in the editor, and even pane sizes after a resize

Alejo asked for two Umi features. Build both in this repository, following AGENTS.md (build, dev copy, tests, release). Work autonomously to the end; Alejo approved everything listed under "Approved" below.

## 1. Comments on documents in Umi's editor

Alejo's words (Slack, 2 Nov): "when I select text in Umi I want it to offer me the option of leaving a comment on the doc, on a manner similar to google docs. see how roughdraft handles comments for inspiration and make sure comments are visible to you. main use case is reacting to the documents you present here."

- Selecting text in the Markdown editor offers "Comment" (a button near the selection, plus a shortcut). The comment shows in a margin beside the text it is anchored to, like Google Docs. Comments can be replied to, edited, resolved and deleted.
- Agents must see the comments. An agent given only the file path, with no Umi running, must be able to read every open comment and the exact text it is anchored to, and reply. Also expose them through the `umi` CLI (`umi comments` or similar, listed in `acceptance/CLI.md`).
- Look at how roughdraft stores and shows comments (search GitHub/the web for it) and pick a storage format on that basis. Comments must survive the file being edited by agents and by git pulls; say what happens to a comment whose anchored text was deleted.
- The main use: an agent shows Alejo a document, Alejo comments on it, the agent reads and acts on the comments. Make that loop work end to end and test it.

## 2. Even pane sizes after a resize

Alejo's words (4 Nov): "when I resize a panel, the remaining panels split the remaining screen equally."

- When Alejo drags a divider to resize one pane, the panes in the same row or column that he did not drag share the remaining space equally. Work out the natural reading for nested splits and state it in the report.
- Clarification from Alejo (4 Nov): "only the panes that have not been manually resized shrink/grow in response to other pane resizing." A pane Alejo has resized by hand keeps its size when he later resizes another pane; only the panes he never resized share what is left equally.

## Approved

1. Add both requirements to `acceptance/SPEC.md` and `acceptance/REQUESTS.md` (Alejo's words above), with acceptance tests.
2. Build and verify each feature in the dev copy (`app/dist/dev.sh`), including screenshots of the comment UI.
3. Commit each logical change and push to `origin/main` as you go.
4. Once the quick test loop and the new tests pass, publish a release with `app/dist/release.sh` (next patch or minor version). Umi's auto-update installs it at a quiet moment on both Macs.
5. If a step is blocked (signing, a test you can't make pass), finish everything else, push, and write what blocked you in the report instead of releasing a broken build.

## Report

Write `REPORT-comments-and-pane-sizes.md` at the root: what was built, the comment storage format and why, how an agent reads and answers comments, what was tested and verified in the dev copy, the release version, and anything not done. Keep it short. Do not add anything to README.md or AGENTS.md beyond a short README section for each user-visible feature.
