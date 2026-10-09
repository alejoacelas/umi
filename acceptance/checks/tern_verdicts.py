"""Write the judged verdicts into results/checks/REPORT.md (Tern, phases 1 and 2).

    uv run python checks/tern_verdicts.py

Each verdict was judged by looking at the evidence listed with it. Extra evidence (screenshots
taken with `tern screenshot` where the setup couldn't show a criterion) lives next to the report
as results/checks/extra-*.png.
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "..", "results", "checks", "REPORT.md")

VERDICTS = {
    "S-1": "PASS: no borders, boxes or cards around the terminals or the sidebar (the selected row has a faint "
           "tint, nothing outlined); no native tab bar; nothing in the titlebar's upper right; split dividers are "
           "1 px and low contrast (S-1-S-3-S-6-window.png). After phase 2's answers: the update question and the staged-update notice sit at the bottom of the sidebar as a faintly tinted block with plain text buttons, no border or outline (extra-I-4-update-question.png, extra-I-4-update-ready.png); the window screenshot is unchanged.",
    "S-3": "PASS for everything the screenshot can show: the pinned tab is first (pin icon, hairline below); line 1 is the name or else the folder, then the branch (⑂ feature-branch); the linked worktree shows a different icon, the accent color and '· worktree'; the split tab shows a pane count (3); line 2 is the last command (`true`, `echo hi`, `ls -la | head -5`), the managed agent's tab shows its status and activity ('claude · working · running Bash: sl…', with a speech-bubble icon and the session's name on line 1), and an exited interactive agent shows 'claude · exited' (IA-1-claude.png). Close and pin controls on hover: NOT JUDGED (the screen was locked; hover a row and check a pin and an ✕ appear).",
    "S-4": "NOT JUDGED: needs a person (the screen was locked). Steps: click a row (selects), double-click (inline "
           "rename field), right-click (Rename, Pin/Unpin, Tab Color, Move Tab to New Window / to Window N, Close "
           "Tab), drag a row up or down (reorders) and onto another window's sidebar (moves the tab).",
    "S-5": "PASS: with `background = #fafafa` the chrome ink turns dark and stays readable (S-5-light.png); with "
           "`#101014` it is light (S-5-dark.png); in both the configured background replaced Tern's default theme.",
    "S-6": "PASS: the tab where `true` ran shows `true` on line 2, and the one where `echo hi` ran shows `echo hi` "
           "(S-1-S-3-S-6-window.png).",
    "S-2": "PASS: the sidebar runs the full height; Files mode is a project explorer rooted at the focused pane's "
           "repository (S-2-files-mode.png; the check's repository has no files, so extra-S-2-files-nested.png shows "
           "a repository with nested folders); there is no agents section and no new-agent button. After phase 2's answers: the sidebar still has no agents section (sessions without a pane are listed in Window > Agent Sessions, not the sidebar); the update notice is the only addition (extra-I-4-update-question.png).",
    "P-2": "PASS (after phase 2's answers, on a release-stamped 0.0.1 build installed from a local release and pointed at a local feed; the screen was unlocked): choosing Tern > Check for Updates… when 999.0.0 was out is a yes: its dialog said 'Downloading Tern 999.0.0' (it installs when you quit; the sidebar shows when it's ready) and the download started; the sidebar's notice then said 'Tern 999.0.0 is ready. It installs when you quit.' with 'Install Now…', which opens the existing Install and Relaunch / Install on Quit dialog (test_the_update_question_in_the_sidebar, read through the accessibility tree; extra-I-4-update-ready.png). Before that, the background check's question was the sidebar notice, not a dialog (extra-I-4-update-question.png). The feed is Tern's own (TERN_FEED_URL in tests, github.com/alejoacelas/tern otherwise); Sparkle and Ghostty's feed and key are not in the app (test_never_offers_another_products_updates). Phase 2 judged the installed copy's CLI path (0.1.0 → 0.2.0). Seeing the dialogs with one's own eyes and the 'up to date' dialog: NOT JUDGED (by hand: Tern > Check for Updates… on the installed copy, which is up to date after the release).",
    "I-5": "PASS: the release repository's README gives one command, `curl -fsSL https://github.com/alejoacelas/tern/releases/latest/download/install.sh | bash`, and explains in a few lines what it does; `install.sh` is attached to v0.2.0 as well, so the command now installs 0.2.0. It installed 0.1.0 on this Mac in phase 1 with nothing installed first and no Gatekeeper prompt (no quarantine; the updated 0.2.0 bundle has none either and its signature verifies). Seeing the window on screen: NOT JUDGED (locked screen).",
    "L-9": "PASS for the menu side, checked without the accessibility tree: every shortcut is exactly one menu item with that key equivalent, ⌃⌘J included, and choosing ⌘B, ⇧⌘M, Undo/Redo, ⌘S and ⌃⌘J does what it says (⌃⌘J shows and focuses the session that needs the user) (app/macos/TernTests/verify_ui_paths.py 43/43, verify_agent_panes.py 36/36). The command palette lists the same actions, and every managed session ('Show Agent: …'). Pressing the keys on a real keyboard: NOT JUDGED (locked screen). Steps: on a window with two tabs, one split, press each shortcut in CHECKS.md L-9.",
    "M-4": "NOT JUDGED: needs a person (drag). Steps: drag a pane by its grab handle onto another pane's edge, also in "
           "another window (it moves there, program running); drag a tab row up/down (reorders) and onto another "
           "window's sidebar (moves the tab).",
    "E-1": "PASS: headings, emphasis, inline code, links, nested list, task list with checkboxes, table and code block render (E-1-preview.png); the local image, the remote badge in a link and the raw-HTML image render (extra-E-1-E-7-images.png); the editor sits beside the tab's terminals with two files as editor tabs, both readable: in a narrow panel the Preview/Source control moves to a row of its own (phase 1's flaw, the active tab hidden behind the control, is fixed).",
    "E-2": "PASS: a visible Preview | Source control in the editor header (E-1-preview.png, E-2-source.png).",
    "E-3": "PASS through scripted checks (closing a dirty file from the CLI is refused; ⌘S through the menu saves; "
           "--force discards), plus closing a tab or quitting saves or keeps a recovery copy (code: "
           "TernDocument.preserveEdits). The 'Save changes?' dialog when closing with ⌘W: NOT JUDGED (locked screen).",
    "E-4": "PASS: with unsaved edits, a disk change shows 'This file changed on disk.' with Reload and Keep Mine "
           "(extra-E-4-disk-changed.png). An unmodified document reloading and a deleted-then-recreated file being "
           "picked up were checked by script (verify_ui_paths.py).",
    "E-5": "PASS through scripted checks: a Latin-1 file edited and saved stays Latin-1; text Latin-1 can't hold is "
           "refused with a message and the file is left intact (verify_ui_paths.py).",
    "E-7": "PASS for the screenshot criteria: repeated headings render as separate headings (their anchors are "
           "`tables` and `tables-1`), and the document's `<script>` did nothing (the page would otherwise read "
           "'SCRIPT RAN') (extra-E-1-E-7-images.png). Clicking a relative link and an #anchor: NOT JUDGED (locked "
           "screen).",
    "E-8": "NOT JUDGED: needs a person. Steps: turn Caps Lock on, focus the editor, press ⌘S, ⇧⌘M and ⌘W. (The "
           "editor compares key equivalents case-insensitively and ignores Caps Lock: TernEditorContainerView.)",
    "I-3": "PASS: on the installed copy (updated to 0.2.0), `open README.md` opened the file in Tern's editor, rendered (extra-I-3-open-readme.png; `tern editor ls` listed it).",
    "IA-1": "PASS: `tern claude --tab -- --version` opened a tab whose shell shows `claude --version` typed at the "
            "prompt and Claude Code's own output, exactly as in a plain terminal (IA-1-claude.png).",
    "AP-1": "PASS for what the screenshots show: both sides of the conversation ('You' and the replies), tool activity (✓ Bash lines, ◌ for running ones), the status line ('Claude · needs_input · waiting: Run a command'), and the pending approval and the two questions as cards in the pane (AP-1-approval.png, AP-1-question.png). Typing a follow-up and Enter, Esc interrupting, and answering the approval and the questions from the cards were checked through the pane's own controls without the accessibility tree (verify_agent_panes.py 36/36: the text reaches the agent once, the reply shows, Esc ends the turn INTERRUPTED, Allow and Answer work). With a real keyboard and mouse: NOT JUDGED (locked screen). Steps: `tern agent start claude --split 'ASK_QUESTIONS'` on a fake or any real session; click into the pane, type, press Enter; send a long command and press Esc; click an option and Answer.",
    "AP-5": 'PASS: after the pane was closed and the session had three more turns, the reopened pane shows every turn, in order, each message and reply once, starting at the latest one (AP-5-reopened.png; the CLI transcript in the evidence agrees).',
    "AP-6": "NOT JUDGED by hand (locked screen). Checked by script: a draft survives showing the pane's terminal and back, and moving the pane to a new tab (verify_agent_panes.py); a send that fails keeps the text and shows 'Not sent: …' (TernAgentPaneView.sendComposer). Steps: type in an agent pane without sending; use Window → Toggle Agent Pane's Terminal twice; move the pane (⌃⌘T); the text is still there.",
    "AP-7": "NOT JUDGED: needs a person (and notifications are off in the isolated test instances). Steps: in an installed Tern, start a session that asks something (`tern agent start claude 'Use AskUserQuestion to ask me red or blue'`; it runs in the background, so nothing in Tern shows it); a notification '… needs you' appears and the Dock badge shows 1; clicking the notification shows the session in a new tab. Also when a turn finishes out of sight ('… finished').",
    "AP-8": 'NOT JUDGED: needs a person. There is no separate copy button: the transcript is one selectable text view, and assistant replies are stored and shown in full (only tool output is clipped in storage, to its first 12 KB and last 4 KB). Steps: select a long reply in an agent pane (or ⌘A in the transcript) and ⌘C; paste it elsewhere and compare with `tern agent read SESSION`.',
    "AP-10": "PASS for what the screenshots show: assistant Markdown is rendered (a heading, a bullet with bold text) and the code block is set apart in a monospaced, shaded block (AP-1-approval.png); tool calls are lines that expand to their output (▸, by hand: click one); the approval and the questions are cards with buttons (Allow / Always allow / Deny; option buttons, answer fields, Answer / Decline). Shift+Enter adding a line and the queued-messages line: NOT JUDGED (by hand: type in the composer with Shift+Enter; send two messages while a turn runs and see 'Queued (1): …' above the composer).",
}


def main():
    text = open(REPORT).read()
    for check, verdict in VERDICTS.items():
        pattern = re.compile(r"(## " + re.escape(check) + r"\n.*?\*\*Verdict:\*\*) ?[^\n]*", re.S)
        text, n = pattern.subn(lambda m: m.group(1) + " " + verdict, text, count=1)
        if n == 0:
            text += f"\n## {check}\n\n**Verdict:** {verdict}\n"
    open(REPORT, "w").write(text)
    print(REPORT)


if __name__ == "__main__":
    main()
