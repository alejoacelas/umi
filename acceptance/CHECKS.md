# Written checks

These are the requirements tagged **[W]** or **[A+W]** in `SPEC.md`: outcomes a script can set up but
only a person, or a model looking at screenshots, can judge. This is the "approval testing" part of
the suite.

`uv run python checks/run_checks.py --target targets/<name>.json` launches an isolated instance and
prepares each check below. It saves the evidence (screenshots, plus text where useful) to
`results/checks/`. It also writes `results/checks/REPORT.md`, which lists each check with its
criteria and evidence and leaves a verdict line to fill in.

**Judging:**
- A check passes only if every criterion holds in the evidence.
- When the evidence can't show a criterion (for example a drag, or a notification click), the check
  says **(by hand)**. Do it on the running instance and write what happened.
- Record each verdict as `PASS`, `FAIL: <what's wrong>` or `NOT JUDGED: <why>`.

---------------------------------------------------------------------------------------------------

## Look

**S-1: no containers.** Setup: one window, sidebar on, two tabs, the second split in three, a command
run in each pane.
- No visible borders, boxes or cards around the terminal content or the sidebar. The chrome blends
  into the terminal background.
- No native tab bar. No titlebar icons or buttons on the upper right.
- Split dividers are subtle (thin, low contrast).

**S-3: tab rows.** Setup: tabs named and unnamed; a git repo on a branch; a linked worktree; a split
tab; a pinned tab; an agent session working, one finished while another tab was in front, one that
needs the user.
- Pinned tabs are first.
- Line 1 has the folder (or the tab's name), then the branch; the worktree looks different. Split
  tabs show a pane count.
- Line 2 has the session's title for agent tabs; otherwise the running or last command.
- Agent tabs show a small monochrome Claude or Codex mark. The finished-unseen and needs-you marks
  have a quiet color; nothing is loud. Selecting the tab clears the color.
- Close and pin controls appear on hover (by hand).

**S-4: row interactions (by hand).** Click selects; double-click renames; right-click shows Warp's
items (see S-4); dragging reorders with an insertion line.

**S-8: sidebar width (by hand).** Drag the sidebar's edge: the cursor is a resize cursor; it stops
at the limits; another window keeps its width; quitting and relaunching keeps both.

**S-5: readable chrome.** Setup: the same window under a light theme and then a dark theme, set
through the user's Ghostty config in the isolated instance.
- Sidebar text is readable on both.
- The configured theme wins over the product's default theme.

**S-6: instant commands.** Setup: run `true` and `echo hi` in a pane.
- Line 2 of that tab's row shows the last command, even though it finished instantly.

**S-2: sidebar modes.** Setup: Tabs mode, then Files mode on a folder with nested directories.
- The sidebar is full height.
- Files mode is a project explorer for the focused pane's folder.
- There's no "agents" section and no "new agent" button.

**P-2: updates.** Setup: choose the app's "Check for Updates…" item on an installed copy.
- It checks the product's own feed and never offers an upstream Ghostty update.
- When it's up to date, it says so. When an update is ready, it says it installs on quit and offers
  to install now.

**I-5: one-line install.** Setup: the release repository's README, and running its install command
in a fresh shell with the install destination pointed at a temporary folder.
- One command, pasted into Terminal, installs the latest release.
- Nothing else needs installing first, and the installed app opens without a Gatekeeper prompt.
- The command and what it does are explained in a few lines.

## Moving things

**L-9: shortcuts do what they say (by hand).** On a window with three tabs, one of them split, an
agent session in one, and focus in turn in a terminal, the editor and the sidebar's file tree,
press each shortcut and confirm what it does:
- ⌘B toggles the sidebar; ⇧⌘E shows Files; ⌘O opens the quick file search; ⇧⌘M toggles the editor
  preview; ⌘P the command palette; ⇧⌘P the pane list; ⌘, Settings;
- ⇧⌘[ goes back to the tab visited before (again: further back); ⇧⌘] and ⌃Tab the next tab in
  sidebar order; ⌘1–9 a tab by number; ⌃⇧←/→ move the tab;
- ⌃⌘T and ⌃⌘N move the pane to a new tab or window; ⌃⌘← and ⌃⌘→ move it into the previous or
  next tab; ⌃⇧⌘N moves the tab to a new window; ⇧⌘T reopens what was closed;
- ⌃⌘P pins; ⌃⌘R and ⌃⇧⌘R rename; ⌃⌘J goes to the session that needs you and ⌃⌘K back; ⌃⌘O takes
  over the focused pane's session and ⌃⌘W removes it from the pane.

Also: the command palette lists these actions, and Settings shows and changes them.

**M-4: dragging (by hand).** Add: drag a pane's grab handle onto another tab's row (it moves into
that tab) and between two rows (a new tab there, with an insertion line); drag a tab row out of
the window and let go over the desktop (a new window there).

## Editor

**E-1: rendering.** Setup: open a Markdown file with headings, nested lists, task lists, a table, a
fenced code block, links, a local image, a remote badge image, and inline HTML with an image.
- Everything renders as formatted text, not as Markdown source. Images show.
- The editor sits beside the tab's terminals, and several files show as editor tabs.

**E-2: the toggle control.** The editor shows a visible control that switches between preview and
source.

**E-3: closing with unsaved edits (by hand).**
- Closing a file with unsaved edits asks first.
- Closing its tab, or quitting the app, never silently loses edits.

**E-4: disk changes.** Setup: modify a document in the editor without saving, then change the file
on disk.
- The editor shows that the disk changed and offers to reload.

**E-5: encodings.** Setup: edit and save a Latin-1 file, then a file in an encoding the editor can't
save.
- The file stays in its encoding, or the save is refused with a message. It's never silently
  converted.

**E-7: preview links and images (by hand, plus a screenshot).**
- A relative link opens that file.
- An `#anchor` link scrolls to the heading.
- Repeated headings get distinct anchors.
- A `<script>` in the document does nothing.

**E-8: Caps Lock (by hand).** With Caps Lock on, ⌘S, ⇧⌘M and ⌘W still work in the editor.

**I-3: default app (by hand, after a real install).** `open README.md` opens it in the app's editor.

## Agent sessions

**AG-5: the read-only view.** Setup: a headless session shown in a pane with `agent open`. It has
run a tool, replied with Markdown, and now has a pending approval; then a second screenshot after it
was answered and the session finished.
- What both sides said is visible, and so is the tool activity (a tool line expands to its output),
  the status, and the pending approval as a card with buttons.
- There's nothing to type into: the view is read-only, with a **Take Over** button and one quiet line
  saying what it does.
- Markdown in replies is rendered, code set apart; nothing is boxed or bordered beyond the cards
  (S-1).
- Pressing Take Over shows the agent's own interface in that pane at once (by hand).
