// umi-next help: the commands, for people and (`--json`) for programs.

import Foundation

let commandTable: [(section: String, usage: String, summary: String)] = [
    ("Layout", "ls", "tabs, their panes and each pane's session; sessions no pane shows"),
    ("Layout", "tab new [NAME] [--cwd D] [--cmd C] [--name N] [--no-focus]", "a tab with a new session (a shell without --cmd); prints its pane"),
    ("Layout", "tab focus|close [TAB]", "select a tab; close stops showing its panes (sessions keep running)"),
    ("Layout", "tab rename [TAB] NAME", "\"\" clears"),
    ("Layout", "tab next|prev", "the next or previous tab, wrapping"),
    ("Layout", "tab move [TAB] --up|--down", "one place up or down the sidebar"),
    ("Layout", "split [right|down|left|up] [--pane P] [--cwd D] [--cmd C] [--name N] [--ratio R] [--no-focus]",
     "split a pane: a new session running C, or the session picker without --cmd; prints the new pane"),
    ("Panes", "pane focus [PANE]", "focus a pane; a session no pane shows opens beside the focused pane"),
    ("Panes", "pane close [PANE]", "close the pane and end its session (⌘W)"),
    ("Panes", "pane exit [PANE]", "end the pane's session (the palette's Exit)"),
    ("Panes", "pane info [PANE]", "the pane, its session and tab"),
    ("Panes", "pane rename [PANE] NAME", "rename the pane's session"),
    ("Panes", "pane swap [PANE] TARGET", "exchange two panes"),
    ("Panes", "pane resize [PANE] up|down|left|right [AMOUNT]", "move the divider by AMOUNT cells (default 5)"),
    ("Panes", "pane move [PANE] --new-tab [--no-focus]", "move the pane into a tab of its own"),
    ("Panes", "pane hide [PANE]", "stop showing the pane (⌥⌘H): the session keeps running, the tab's strip lists it"),
    ("Panes", "pane show SESSION [--focus]", "show a session no pane shows, at the right end of the tab"),
    ("Panes", "pane zoom [PANE]", "show only this pane in its tab, or all of them again"),
    ("Sessions", "send [--pane P] [--enter|-e] TEXT…", "type text into the session (stdin when piped)"),
    ("Sessions", "keys [--pane P] KEY…", "enter esc tab backspace up down left right ctrl+c shift+tab …"),
    ("Sessions", "read [--pane P] [--scrollback] [--lines N]", "the session's screen as text; --scrollback: with the history above it"),
    ("Sessions", "wait [--pane P] (--pattern RE | --idle SECS) [--timeout T]", "until the screen matches or stays still; 124 on timeout"),
    ("Window", "sidebar [on|off|toggle|status|tabs|files|search]", "show, hide or switch the sidebar"),
    ("Window", "notify [--pane P] TITLE [BODY]", "a desktop notification; none from a snoozed or docketed session"),
    ("Window", "go --next jump | go --back", "the next session waiting for you; back to where the walk began"),
    ("Window", "shortcuts [ls]", "every shortcut (change them in next/app/web/shortcuts.js)"),
    ("Editor", "edit FILE… [--source|--preview] [--pane P|--tab T]", "open files in panes to the right; focus stays put (open is the same)"),
    ("Editor", "editor ls [--pane P|--tab T]", "the files open in a tab"),
    ("Editor", "editor close [FILE] [--force]", "close a file pane (refuses unsaved changes without --force)"),
    ("Editor", "editor mode [preview|source] [FILE]", "switch a file between preview and source"),
    ("Comments", "comments [ls] FILE [--all]", "a Markdown file's open comments (works without the app)"),
    ("Comments", "comments add FILE --on TEXT [--nth N] TEXT… [--by NAME]", "comment on TEXT"),
    ("Comments", "comments reply FILE ID TEXT… [--by NAME]", "reply to a thread"),
    ("Comments", "comments edit|resolve|reopen|delete FILE ID …", "change, resolve (--note), reopen or delete a comment"),
    ("Comments", "comments wait FILE [--timeout SECS]", "until the user presses Done on FILE's comments; 124 on timeout"),
    ("Logs", "focus-log [--since T] [--until T] [--pane P] [--by session|folder|pane]", "stretches of keyboard focus in Umi next"),
    ("Other", "help [--json]", "this list"),
]

func printHelp() {
    print("""
    umi-next: drive Umi next from the command line (the `umi` commands, for Umi next).

    Inside a Umi next session, PANE and TAB default to the session's own pane and tab; elsewhere to
    the focused ones. A PANE is a pane id, a session id or name, or `.` (the focused pane); a TAB is
    an id, a name, #N or `.`. --json prints JSON. Errors exit 1, timeouts 124.
    State: \(abbreviateHome(stateDir))
    """)
    var section = ""
    for c in commandTable {
        if c.section != section { section = c.section; print("\n" + bold(section)) }
        print("  \(c.usage)")
        print(dim("      \(c.summary)"))
    }
}

func printHelpJSON() {
    printJSON([
        "cli": cliName, "product": "Umi next", "version": 1,
        "commands": commandTable.map { ["section": $0.section, "usage": $0.usage, "summary": $0.summary, "actions": [] as [Any]] },
    ])
}
