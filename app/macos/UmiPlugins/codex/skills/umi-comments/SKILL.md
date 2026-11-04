---
name: umi-comments
description: Read and answer the comments the user leaves on a Markdown file in Umi's editor. Use when you show the user a document with `umi edit`, when the user says they commented on or reviewed a file, or when a .md file contains `{==…==}{>>…<<}` markup.
---

# Comments on documents in Umi

The user can select text in Umi's editor and comment on it, as in Google Docs. Comments live in the
file itself (Roughdraft Flavored Markdown): `{==the words==}{>>the comment<<}{#c1}` in the text,
and who, when, replies and resolved state in a YAML block at the end of the file (`comments:`).

- **Show and wait.** `umi edit FILE` opens it beside the user's terminals; then
  `umi comments wait FILE --timeout 1800` blocks until the user presses Done in the editor and
  prints their open comments. Tell the user you're waiting for their comments.
- **Read.** `umi comments FILE` lists the open comments: id, line, the words each is on, replies
  (`--all` adds resolved ones, `--json` gives JSON). It works without Umi running.
- **Answer.** `umi comments reply FILE c1 "…"`, then act on it. Edit the text freely, but keep a
  comment's `{==…==}{>>…<<}{#cN}` markup around the words it's on (move it with them); when the
  point is addressed, `umi comments resolve FILE c1 --note "what you did"` instead of deleting the
  markup. A comment whose markup is removed shows as "detached".
- You can comment too: `umi comments add FILE --on "exact words" "question"`.
- Never put `<<}` in a comment. Markup in code blocks is literal text, not a comment.
