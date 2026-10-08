"""Write the judged verdicts into results/checks/REPORT.md (Tern, phase 1).

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
           "1 px and low contrast (S-1-S-3-S-6-window.png).",
    "S-3": "PASS for everything the screenshot can show: the pinned tab is first (pin icon, hairline below); line 1 "
           "is the name or else the folder, then the branch (⑂ feature-branch); the linked worktree shows a "
           "different icon, the accent color and '· worktree'; the split tab shows a pane count (3); line 2 is the "
           "last command (`ls -la | head -5`, `echo hi`, `true`), and an exited interactive agent shows "
           "'claude · exited' (IA-1-claude.png). The managed-agent line is phase 2. Close and pin controls on hover: "
           "NOT JUDGED (the screen was locked; hover a row and check a pin and an ✕ appear).",
    "S-4": "NOT JUDGED: needs a person (the screen was locked). Steps: click a row (selects), double-click (inline "
           "rename field), right-click (Rename, Pin/Unpin, Tab Color, Move Tab to New Window / to Window N, Close "
           "Tab), drag a row up or down (reorders) and onto another window's sidebar (moves the tab).",
    "S-5": "PASS: with `background = #fafafa` the chrome ink turns dark and stays readable (S-5-light.png); with "
           "`#101014` it is light (S-5-dark.png); in both the configured background replaced Tern's default theme.",
    "S-6": "PASS: the tab where `true` ran shows `true` on line 2, and the one where `echo hi` ran shows `echo hi` "
           "(S-1-S-3-S-6-window.png).",
    "S-2": "PASS: the sidebar runs the full height; Files mode is a project explorer rooted at the focused pane's "
           "repository (S-2-files-mode.png; the check's repository has no files, so extra-S-2-files-nested.png shows "
           "a repository with nested folders); there is no agents section and no new-agent button.",
    "P-2": "PASS (judged on the installed release): `tern update --check` and the menu use only "
           "github.com/alejoacelas/tern's feed; up to date reports 'installed 0.1.0, latest 0.1.0: up to date'. "
           "Sparkle and Ghostty's feed and key are not in the app (test_never_offers_another_products_updates). The "
           "'ready' prompt (installs on quit, offers Install and Relaunch) was checked in code and through "
           "test_an_older_build_updates_itself; seeing the dialog itself: NOT JUDGED (locked screen).",
    "I-5": "PASS: the release repository's README gives one command, `curl -fsSL "
           "https://github.com/alejoacelas/tern/releases/latest/download/install.sh | bash`, and explains in a few "
           "lines what it does. It was run on this Mac in a fresh shell and installed /Applications/Tern.app "
           "without anything else installed first; curl sets no quarantine and the installer clears it anyway, "
           "so there is no Gatekeeper prompt. Seeing the app open on screen: NOT JUDGED (locked screen).",
    "L-9": "PASS for the menu side, checked without the accessibility tree: every shortcut is exactly one menu item "
           "with that key equivalent, and choosing ⌘B, ⇧⌘M, Undo/Redo and ⌘S does what it says "
           "(app/macos/TernTests/verify_ui_paths.py, 43/43). The command palette lists the same actions "
           "(TernShortcuts.paletteOptions). Pressing the keys on a real keyboard: NOT JUDGED (locked screen). Steps: "
           "on a window with two tabs, one split, press each shortcut in CHECKS.md L-9. ⌃⌘J is phase 2.",
    "M-4": "NOT JUDGED: needs a person (drag). Steps: drag a pane by its grab handle onto another pane's edge, also in "
           "another window (it moves there, program running); drag a tab row up/down (reorders) and onto another "
           "window's sidebar (moves the tab).",
    "E-1": "PASS: headings, emphasis, inline code, links, nested list, task list with checkboxes, table and code "
           "block render (E-1-preview.png); the local image, the remote badge in a link, and the raw-HTML image "
           "render (extra-E-1-E-7-images.png); the editor sits beside the tab's terminal with two files as editor "
           "tabs.",
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
    "I-3": "NOT JUDGED: needs a person after the install (the installer made Tern the default Markdown app). Steps: "
           "`open README.md` in Terminal; it opens in Tern's editor.",
    "IA-1": "PASS: `tern claude --tab -- --version` opened a tab whose shell shows `claude --version` typed at the "
            "prompt and Claude Code's own output, exactly as in a plain terminal (IA-1-claude.png).",
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
