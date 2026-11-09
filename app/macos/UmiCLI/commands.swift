// The CLI's commands, described once. `umi help` prints them for people; `umi help --json`
// prints them for programs, notably the app's command palette (⌘P), which builds its entries
// from this description at runtime. Change a command here and both follow.

import Foundation

/// A value the palette asks for before running an action, appended to its words in order:
/// `option VALUE` when `option` is set, else VALUE as a positional argument.
struct Ask {
    let name: String
    let prompt: String
    var option: String? = nil
    var choices: [String] = []
    /// May be left empty, and is then left out.
    var optional = false
    /// What the value names, so the palette can offer them: pane, tab, window, folder, file,
    /// number or text.
    var kind = "text"
    /// The answer is several words, each its own argument (`keys ctrl+c esc`).
    var words = false
    /// An empty answer is passed on as an empty argument (`tab rename ""` clears the name).
    var keepEmpty = false

    var json: [String: Any] {
        var out: [String: Any] = ["name": name, "prompt": prompt, "optional": optional, "kind": kind]
        if let option { out["option"] = option }
        if !choices.isEmpty { out["choices"] = choices }
        if words { out["words"] = true }
        if keepEmpty { out["empty"] = true }
        return out
    }
}

/// Something the palette can run: fixed words, then the asked values.
struct PaletteAction {
    let title: String
    let argv: [String]
    var ask: [Ask] = []

    var json: [String: Any] { ["title": title, "argv": argv, "ask": ask.map(\.json)] }
}

/// One line of the help.
struct CommandHelp {
    let section: String
    /// The syntax after the CLI name; continuation lines start with spaces.
    let usage: String
    var summary: String = ""
    var actions: [PaletteAction] = []

    var json: [String: Any] {
        func oneLine(_ text: String) -> String {
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        return ["section": section, "usage": oneLine(usage), "summary": oneLine(summary), "actions": actions.map(\.json)]
    }
}

let colorNames = ["red", "green", "yellow", "blue", "magenta", "cyan", "purple", "pink", "orange", "teal", "graphite", "none"]

let commandTable: [CommandHelp] = [
    // Layout
    CommandHelp(section: "Layout", usage: "ls [--where QUERY]", summary: "windows, tabs and panes (--where: the panes a query picks)",
                actions: [PaletteAction(title: "List Windows, Tabs and Panes", argv: ["ls"]),
                          PaletteAction(title: "List Panes Matching…", argv: ["ls", "--where"],
                                        ask: [Ask(name: "QUERY", prompt: "Query (e.g. agent.status=idle and not hidden)")])]),
    CommandHelp(section: "Layout", usage: "window new [--cwd D] [--cmd C] [--name N] [--worktree W [--base REF]] [--no-focus]",
                actions: [PaletteAction(title: "New Window", argv: ["window", "new"]),
                          PaletteAction(title: "New Window in Folder…", argv: ["window", "new"],
                                        ask: [Ask(name: "D", prompt: "Folder", option: "--cwd", kind: "folder")])]),
    CommandHelp(section: "Layout", usage: "window focus|close [WINDOW]",
                actions: [PaletteAction(title: "Close Window", argv: ["window", "close"]),
                          PaletteAction(title: "Focus Window…", argv: ["window", "focus"],
                                        ask: [Ask(name: "WINDOW", prompt: "Window", kind: "window")])]),
    CommandHelp(section: "Layout", usage: """
        tab new [NAME] [--window W] [--pane P] [--cwd D] [--cmd C] [--name N] [--color C]
                [--index I] [--worktree W [--base REF]] [--no-focus]
        """,
                actions: [PaletteAction(title: "New Tab", argv: ["tab", "new"]),
                          PaletteAction(title: "New Tab Named…", argv: ["tab", "new"],
                                        ask: [Ask(name: "NAME", prompt: "Tab name")]),
                          PaletteAction(title: "New Tab Running Command…", argv: ["tab", "new"],
                                        ask: [Ask(name: "C", prompt: "Command", option: "--cmd")]),
                          PaletteAction(title: "New Tab in Folder…", argv: ["tab", "new"],
                                        ask: [Ask(name: "D", prompt: "Folder", option: "--cwd", kind: "folder")]),
                          PaletteAction(title: "New Tab in Git Worktree…", argv: ["tab", "new"],
                                        ask: [Ask(name: "W", prompt: "Worktree (an existing one, a branch, or a new branch name)",
                                                  option: "--worktree")])]),
    CommandHelp(section: "Layout", usage: "tab focus|close|equalize [TAB]",
                actions: [PaletteAction(title: "Close Tab", argv: ["tab", "close"]),
                          PaletteAction(title: "Equalize Panes", argv: ["tab", "equalize"]),
                          PaletteAction(title: "Focus Tab…", argv: ["tab", "focus"],
                                        ask: [Ask(name: "TAB", prompt: "Tab", kind: "tab")])]),
    CommandHelp(section: "Layout", usage: "tab next|prev", summary: "the next or previous tab in sidebar order, wrapping (⇧⌘] / ⇧⌘[)",
                actions: [PaletteAction(title: "Show Next Tab", argv: ["tab", "next"]),
                          PaletteAction(title: "Show Previous Tab", argv: ["tab", "prev"])]),
    CommandHelp(section: "Layout", usage: "tab rename [TAB] NAME", summary: "(\"\" clears the name)",
                actions: [PaletteAction(title: "Rename Tab…", argv: ["tab", "rename"],
                                        ask: [Ask(name: "NAME", prompt: "Tab name (empty: name it after its folder)", keepEmpty: true)])]),
    CommandHelp(section: "Layout", usage: "tab color [TAB] COLOR", summary: colorNames.joined(separator: " "),
                actions: [PaletteAction(title: "Set Tab Color…", argv: ["tab", "color"],
                                        ask: [Ask(name: "COLOR", prompt: "Color", choices: colorNames)])]),
    CommandHelp(section: "Layout", usage: "tab pin|unpin [TAB]",
                actions: [PaletteAction(title: "Pin Tab", argv: ["tab", "pin"]),
                          PaletteAction(title: "Unpin Tab", argv: ["tab", "unpin"])]),
    CommandHelp(section: "Layout", usage: "tab move [TAB] (--window W [--index I] | --index I | --up | --down | --new-window) [--no-focus]",
                actions: [PaletteAction(title: "Move Tab Up", argv: ["tab", "move", "--up"]),
                          PaletteAction(title: "Move Tab Down", argv: ["tab", "move", "--down"]),
                          PaletteAction(title: "Move Tab to New Window", argv: ["tab", "move", "--new-window"]),
                          PaletteAction(title: "Move Tab to Position…", argv: ["tab", "move"],
                                        ask: [Ask(name: "I", prompt: "Position (1 is the top)", option: "--index", kind: "number")]),
                          PaletteAction(title: "Move Tab to Window…", argv: ["tab", "move"],
                                        ask: [Ask(name: "W", prompt: "Window", option: "--window", kind: "window")])]),
    CommandHelp(section: "Layout", usage: """
        split [right|down|left|up] [--pane P] [--cwd D] [--cmd C] [--name N] [--ratio R]
              [--worktree W] [--no-focus]
        """,
                actions: [PaletteAction(title: "Split Right", argv: ["split", "right"]),
                          PaletteAction(title: "Split Down", argv: ["split", "down"]),
                          PaletteAction(title: "Split Left", argv: ["split", "left"]),
                          PaletteAction(title: "Split Up", argv: ["split", "up"]),
                          PaletteAction(title: "Split Right Running Command…", argv: ["split", "right"],
                                        ask: [Ask(name: "C", prompt: "Command", option: "--cmd")])]),
    CommandHelp(section: "Layout", usage: "pane focus|close|info|zoom [PANE]",
                actions: [PaletteAction(title: "Close Pane", argv: ["pane", "close"]),
                          PaletteAction(title: "Zoom or Unzoom Pane", argv: ["pane", "zoom"]),
                          PaletteAction(title: "Pane Info", argv: ["pane", "info"]),
                          PaletteAction(title: "Focus Pane…", argv: ["pane", "focus"],
                                        ask: [Ask(name: "PANE", prompt: "Pane", kind: "pane")])]),
    CommandHelp(section: "Layout", usage: "pane rename [PANE] NAME",
                actions: [PaletteAction(title: "Rename Pane…", argv: ["pane", "rename"],
                                        ask: [Ask(name: "NAME", prompt: "Pane name (a CLI selector)")])]),
    CommandHelp(section: "Layout", usage: """
        pane move [PANE] (--to PANE [--dir D] | --tab T [--dir D] | --window W [--dir D]
                          | --new-tab [--window W] | --new-window) [--no-focus]
        """,
                actions: [PaletteAction(title: "Move Pane to New Tab", argv: ["pane", "move", "--new-tab"]),
                          PaletteAction(title: "Move Pane to New Window", argv: ["pane", "move", "--new-window"]),
                          PaletteAction(title: "Move Pane to Tab…", argv: ["pane", "move"],
                                        ask: [Ask(name: "T", prompt: "Tab", option: "--tab", kind: "tab")]),
                          PaletteAction(title: "Move Pane Next to Pane…", argv: ["pane", "move"],
                                        ask: [Ask(name: "PANE", prompt: "Pane", option: "--to", kind: "pane")])]),
    CommandHelp(section: "Layout", usage: "pane swap [PANE] TARGET",
                actions: [PaletteAction(title: "Swap Pane With…", argv: ["pane", "swap"],
                                        ask: [Ask(name: "TARGET", prompt: "Pane to swap with", kind: "pane")])]),
    CommandHelp(section: "Layout", usage: "pane resize [PANE] up|down|left|right [AMOUNT]",
                actions: [PaletteAction(title: "Resize Pane…", argv: ["pane", "resize"],
                                        ask: [Ask(name: "DIRECTION", prompt: "Direction", choices: ["up", "down", "left", "right"]),
                                              Ask(name: "AMOUNT", prompt: "Cells (empty: 10)", optional: true, kind: "number")])]),
    // Hidden panes
    CommandHelp(section: "Hidden panes", usage: "pane hide [PANE] [--until CONDITION]…",
                summary: "out of the tab's layout, still running; --until a query about the pane or a duration (2h) brings it back",
                actions: [PaletteAction(title: "Hide Pane", argv: ["pane", "hide"]),
                          PaletteAction(title: "Hide Pane Until…", argv: ["pane", "hide"],
                                        ask: [Ask(name: "CONDITION", prompt: "Until (a query, e.g. agent.status=needs_input, or a duration, e.g. 30m)",
                                                  option: "--until")])]),
    CommandHelp(section: "Hidden panes", usage: "pane show [PANE] [--focus]",
                summary: "back into its tab, at the right end (strip.make-room hides one if the tab is full)",
                actions: [PaletteAction(title: "Show Hidden Pane…", argv: ["pane", "show", "--focus"],
                                        ask: [Ask(name: "PANE", prompt: "Pane", kind: "pane")])]),
    CommandHelp(section: "Hidden panes", usage: "pane until [PANE]", summary: "the pane's pending --until conditions"),
    // The drawer
    CommandHelp(section: "Drawer", usage: "drawer show [PANE] [--window W]",
                summary: "move the pane into the window's drawer (it leaves its tab) and open it there, focused; no PANE: open it as it was",
                actions: [PaletteAction(title: "Show Pane in Drawer…", argv: ["drawer", "show"],
                                        ask: [Ask(name: "PANE", prompt: "Pane", kind: "pane")])]),
    CommandHelp(section: "Drawer", usage: "drawer hide [--window W]",
                summary: "close the drawer; its panes keep running and focus goes back where it was",
                actions: [PaletteAction(title: "Put Drawer Away", argv: ["drawer", "hide"])]),
    CommandHelp(section: "Drawer", usage: "drawer toggle [PANE] [--window W]",
                summary: "show when closed or showing another pane, else hide (⌃⌘M: drawer toggle @manager)"),
    CommandHelp(section: "Drawer", usage: "drawer next|prev [--window W]", summary: "the next or previous pane in the drawer"),
    CommandHelp(section: "Drawer", usage: "drawer dock [PANE]",
                summary: "from the drawer into the current tab, right of its focused pane (strip.make-room applies)"),
    CommandHelp(section: "Drawer", usage: "drawer ls [--window W]", summary: "whether the drawer is open, and its panes",
                actions: [PaletteAction(title: "List Drawer Panes", argv: ["drawer", "ls"])]),
    CommandHelp(section: "Layout", usage: "worktree ls",
                actions: [PaletteAction(title: "List Git Worktrees", argv: ["worktree", "ls"])]),
    CommandHelp(section: "Layout", usage: "layout ls|save NAME [--replace]|open NAME [--no-focus]",
                summary: "launch configurations in ~/.config/umi/launch_configurations: list, save every window, open",
                actions: [PaletteAction(title: "List Launch Configurations", argv: ["layout", "ls"]),
                          PaletteAction(title: "Save New Launch Configuration…", argv: ["layout", "save"],
                                        ask: [Ask(name: "NAME", prompt: "File name (e.g. work, saved as work.yaml)")])]),

    // Pane data
    CommandHelp(section: "Pane data", usage: "pane set [PANE] KEY=VALUE…",
                summary: "set attributes (role has one holder; Umi's own keys, like cwd or seen_at, can't be set)",
                actions: [PaletteAction(title: "Set Pane Attribute…", argv: ["pane", "set"],
                                        ask: [Ask(name: "KEY=VALUE", prompt: "Attribute (key=value, e.g. priority=high)")]),
                          PaletteAction(title: "Pin Pane (Never Hidden to Make Room)", argv: ["pane", "set", "pinned=true"]),
                          PaletteAction(title: "Unpin Pane", argv: ["pane", "unset", "pinned"])]),
    CommandHelp(section: "Pane data", usage: "pane unset [PANE] KEY…",
                actions: [PaletteAction(title: "Remove Pane Attribute…", argv: ["pane", "unset"],
                                        ask: [Ask(name: "KEY", prompt: "Attribute name")])]),
    CommandHelp(section: "Pane data", usage: "pane get [PANE] [KEY…]", summary: "the values (every attribute without KEY)",
                actions: [PaletteAction(title: "Show Pane Attributes", argv: ["pane", "get"])]),
    CommandHelp(section: "Pane data", usage: "tab set|unset|get [TAB] …", summary: "the same for tabs (role=docs: the Docs tab)",
                actions: [PaletteAction(title: "Set Tab Attribute…", argv: ["tab", "set"],
                                        ask: [Ask(name: "KEY=VALUE", prompt: "Attribute (key=value)")]),
                          PaletteAction(title: "Show Tab Attributes", argv: ["tab", "get"])]),
    CommandHelp(section: "Pane data", usage: "window set|unset|get [WINDOW] …", summary: "the same for windows"),
    CommandHelp(section: "Pane data", usage: "log [--since T] [--until T] [--filter PREFIX]… [--pane P]",
                summary: "the activity log: every event with its cause, oldest first (kept 30 days)",
                actions: [PaletteAction(title: "Show Activity Log (Last Hour)", argv: ["log", "--since", "1h"])]),
    CommandHelp(section: "Pane data", usage: "focus-log [--since T] [--until T] [--pane P] [--by session|folder|pane]",
                summary: "stretches of keyboard focus on each pane, with what it showed (kept 30 days); --by: time summed per agent session (else file, page or folder), folder or pane, with total, first and last focus, and breaks of 30 min or more",
                actions: [PaletteAction(title: "Show Focus Log (Today)", argv: ["focus-log", "--since", "00:00"]),
                          PaletteAction(title: "Show Focus Time by Session (Today)", argv: ["focus-log", "--since", "00:00", "--by", "session"])]),

    // Lists and go
    CommandHelp(section: "Lists and go", usage: "list ls", summary: "named lists (list.NAME = QUERY in the config) and how many panes each holds",
                actions: [PaletteAction(title: "List Named Lists", argv: ["list", "ls"])]),
    CommandHelp(section: "Lists and go", usage: "list show NAME", summary: "a list's panes, in order",
                actions: [PaletteAction(title: "Show List…", argv: ["list", "show"], ask: [Ask(name: "NAME", prompt: "List name (e.g. jump)")])]),
    CommandHelp(section: "Lists and go", usage: "go LIST|QUERY", summary: "put the first pane in front of you",
                actions: [PaletteAction(title: "Go to First Pane of List…", argv: ["go"],
                                        ask: [Ask(name: "LIST", prompt: "List name or query")])]),
    CommandHelp(section: "Lists and go", usage: "go --next LIST|QUERY", summary: "the next pane of the walk (⌃⌘J: go --next jump)",
                actions: [PaletteAction(title: "Jump to Next Pane Needing You", argv: ["go", "--next", "jump"])]),
    CommandHelp(section: "Lists and go", usage: "go --back", summary: "back to where the walk started (⌃⌘K)",
                actions: [PaletteAction(title: "Jump Back", argv: ["go", "--back"])]),
    CommandHelp(section: "Lists and go", usage: "slot ls", summary: "the slots (slot.NAME = VALUE in the config): each one's value",
                actions: [PaletteAction(title: "List Slots", argv: ["slot", "ls"])]),
    CommandHelp(section: "Lists and go", usage: "command ls", summary: "palette commands from the config and its commands/ folder",
                actions: [PaletteAction(title: "List Palette Commands", argv: ["command", "ls"])]),
    CommandHelp(section: "Lists and go", usage: "command run TITLE [--pane P]", summary: "run one as the palette would"),

    // Input and output
    CommandHelp(section: "Input and output", usage: "send [--pane P] [--enter|-e] TEXT…",
                summary: "type text (no TEXT: read piped stdin; - reads stdin)",
                actions: [PaletteAction(title: "Type Text into Pane…", argv: ["send", "--"],
                                        ask: [Ask(name: "TEXT", prompt: "Text to type")]),
                          PaletteAction(title: "Run Command in Pane…", argv: ["send", "--enter", "--"],
                                        ask: [Ask(name: "TEXT", prompt: "Command to run")])]),
    CommandHelp(section: "Input and output", usage: "keys [--pane P] KEY…",
                summary: "enter esc tab backspace up down left right ctrl+c …",
                actions: [PaletteAction(title: "Send Keys to Pane…", argv: ["keys"],
                                        ask: [Ask(name: "KEY", prompt: "Keys (e.g. ctrl+c, esc, enter)", words: true)])]),
    CommandHelp(section: "Input and output", usage: "read [--pane P] [--scrollback] [--lines N]",
                actions: [PaletteAction(title: "Read Pane's Screen", argv: ["read"])]),
    CommandHelp(section: "Input and output", usage: "wait [--pane P] (--pattern RE | --idle SECS | --attr QUERY) [--timeout T]",
                summary: "exits 124 on timeout; --attr: until the pane matches the query"),
    CommandHelp(section: "Input and output", usage: "events [--filter PREFIX]… [--pane P] [--since T]",
                summary: "JSON lines (pane.created, pane.changed, …), each with its cause; --since replays the log first"),
    CommandHelp(section: "Input and output", usage: "notify [--pane P] TITLE [BODY]",
                actions: [PaletteAction(title: "Notify…", argv: ["notify"], ask: [Ask(name: "TITLE", prompt: "Notification title")])]),
    CommandHelp(section: "Input and output", usage: "sidebar [on|off|toggle|status|tabs|files|search] [--window W]",
                actions: [PaletteAction(title: "Toggle Sidebar", argv: ["sidebar", "toggle"]),
                          PaletteAction(title: "Show Sidebar Files", argv: ["sidebar", "files"]),
                          PaletteAction(title: "Show Sidebar Tabs", argv: ["sidebar", "tabs"]),
                          PaletteAction(title: "Show Sidebar Search", argv: ["sidebar", "search"])]),
    CommandHelp(section: "Input and output", usage: "sidebar width [N] [--window W]",
                summary: "the window's sidebar width (points); N sets it",
                actions: [PaletteAction(title: "Set Sidebar Width…", argv: ["sidebar", "width"],
                                        ask: [Ask(name: "N", prompt: "Width in points (180–600)", kind: "number")])]),
    CommandHelp(section: "Input and output", usage: "reopen [--list]",
                summary: "reopen the last closed pane, tab or window (for 60 s)",
                actions: [PaletteAction(title: "Reopen Closed Pane, Tab or Window", argv: ["reopen"]),
                          PaletteAction(title: "List What Can Be Reopened", argv: ["reopen", "--list"])]),
    CommandHelp(section: "Input and output", usage: "screenshot [--window W] OUT.png",
                actions: [PaletteAction(title: "Screenshot Window…", argv: ["screenshot"],
                                        ask: [Ask(name: "OUT", prompt: "Save as (.png)", kind: "file")])]),

    // Editor
    CommandHelp(section: "Editor", usage: "edit FILE|URL… [--source|--preview] [--tab T | --pane P]",
                summary: "a URL from an umi-web-origin opens in a web pane",
                actions: [PaletteAction(title: "Edit File…", argv: ["edit"], ask: [Ask(name: "FILE", prompt: "File", kind: "file")])]),
    CommandHelp(section: "Editor", usage: "editor ls [--tab T | --pane P]",
                actions: [PaletteAction(title: "List Open Files", argv: ["editor", "ls"])]),
    CommandHelp(section: "Editor", usage: "editor close [FILE] [--force]",
                actions: [PaletteAction(title: "Close File", argv: ["editor", "close"])]),
    CommandHelp(section: "Editor", usage: "editor mode [preview|source]",
                actions: [PaletteAction(title: "Toggle Preview and Source", argv: ["editor", "mode"])]),
    CommandHelp(section: "Editor", usage: "editor default [--dry-run]", summary: "make \(productName) the default app for Markdown, text, JSON, CSV, TSV and YAML",
                actions: [PaletteAction(title: "Make \(productName) the Default for Text Files", argv: ["editor", "default"])]),
    CommandHelp(section: "Editor", usage: "comments [ls] FILE [--all]",
                summary: "a Markdown file's comments: the text each is on, replies (works without \(productName) running)"),
    CommandHelp(section: "Editor", usage: "comments reply|edit FILE ID TEXT… [--by NAME]", summary: "answer a comment, or change one"),
    CommandHelp(section: "Editor", usage: "comments resolve|reopen|delete FILE ID", summary: "resolve (--note TEXT), reopen or delete a thread"),
    CommandHelp(section: "Editor", usage: "comments add FILE --on TEXT [--nth N] TEXT…", summary: "comment on some words of the file"),
    CommandHelp(section: "Editor", usage: "comments wait FILE [--timeout SECS]",
                summary: "until the user presses Done on the file in the editor; then its open comments"),

    // Agents in panes
    CommandHelp(section: "Agents (Claude Code and Codex run in panes; Umi's plugin reports them)",
                usage: "plugins [status | install [--force] | remove]",
                summary: "Umi's hook plugins in Claude Code and Codex: they write agent.* on the agent's pane",
                actions: [PaletteAction(title: "Agent Plugins: Status", argv: ["plugins"]),
                          PaletteAction(title: "Agent Plugins: Install or Update", argv: ["plugins", "install"])]),
    CommandHelp(section: "Agents (Claude Code and Codex run in panes; Umi's plugin reports them)",
                usage: "hook EVENT --agent claude|codex [--pid PID]",
                summary: "run by the plugins: the hook's input on stdin; prints nothing"),

    // Other
    CommandHelp(section: "Other", usage: "shortcuts [ls | set ID KEYS | clear ID | reset [ID]]",
                summary: "keyboard shortcuts",
                actions: [PaletteAction(title: "List Keyboard Shortcuts", argv: ["shortcuts"])]),
    CommandHelp(section: "Other", usage: "update", summary: """
        check now and download the newest version (it installs at the next
        quiet moment, or when \(productName) quits with auto-update = check)
        """,
                actions: [PaletteAction(title: "Check for Updates", argv: ["update", "--check"])]),
    CommandHelp(section: "Other", usage: "update --check | --status",
                summary: "look for a newer version | say what's pending and what a quiet moment waits for"),
    CommandHelp(section: "Other", usage: "update --now [--force]", summary: """
        download and install now, then relaunch (--force: even while
        agents in panes work; they come back on their conversations)
        """),
    CommandHelp(section: "Other", usage: "update --rollback [--force]", summary: """
        go back to the version installed before this one (it won't
        install by itself again)
        """),
    CommandHelp(section: "Other", usage: "update --later | --skip", summary: """
        answer \(productName)'s update question: ask again tomorrow |
        don't ask about this version again
        """),
    CommandHelp(section: "Other", usage: "doctor", summary: "is \(cliName) on PATH, are the agent plugins installed and current",
                actions: [PaletteAction(title: "Check This Mac for What \(productName) Needs", argv: ["doctor"])]),
    CommandHelp(section: "Other", usage: "help", summary: "this help (--json: for programs)"),
]

/// `umi help`.
func renderHelp() -> String {
    var lines = ["\(cliName): control \(productName) from the command line."]
    var section = ""
    let column = 41
    for command in commandTable {
        if command.section != section {
            section = command.section
            lines.append("")
            lines.append(section)
        }
        let usage = command.usage.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let summary = command.summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var first = "  " + usage[0]
        if let note = summary.first, !note.isEmpty {
            first = first.count < column - 1 ? first.padding(toLength: column, withPad: " ", startingAt: 0) + note : first + "  " + note
        }
        lines.append(first)
        for more in usage.dropFirst() { lines.append("  " + more) }
        for more in summary.dropFirst() { lines.append(String(repeating: " ", count: column) + more) }
    }
    lines += [
        "",
        "Selectors: an id or unique id prefix, a name, `.` (the focused one) or #N (tabs, windows),",
        "or a query: agent.status=idle and not hidden | sort -status_since (@NAME is a named list).",
        "Commands that change panes act on every match; the others on the first.",
        "Inside \(productName)'s terminals (UMI_PANE), commands default to the calling pane, its tab and window.",
        "Times (T): ISO 8601, a clock time today (9am, 14:30), or a duration back from now (2h).",
        "Add --json (before any --) for JSON output.",
    ]
    return lines.joined(separator: "\n")
}

/// `umi help --json`: the same commands for programs (the command palette).
func helpJSON() -> [String: Any] {
    ["cli": cliName, "product": productName, "version": 1, "commands": commandTable.map(\.json)]
}
