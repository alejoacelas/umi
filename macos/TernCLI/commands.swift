// The CLI's commands, described once. `tern help` prints them for people; `tern help --json`
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

    var json: [String: Any] {
        var out: [String: Any] = ["name": name, "prompt": prompt, "optional": optional, "kind": kind]
        if let option { out["option"] = option }
        if !choices.isEmpty { out["choices"] = choices }
        if words { out["words"] = true }
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

let colorNames = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "graphite", "none"]

let commandTable: [CommandHelp] = [
    // Layout
    CommandHelp(section: "Layout", usage: "ls", summary: "windows, tabs and panes",
                actions: [PaletteAction(title: "List Windows, Tabs and Panes", argv: ["ls"])]),
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
    CommandHelp(section: "Layout", usage: "tab back", summary: "the tab visited before (again: the one before that)",
                actions: [PaletteAction(title: "Back to Previous Tab", argv: ["tab", "back"])]),
    CommandHelp(section: "Layout", usage: "tab next|prev", summary: "the next or previous tab in sidebar order",
                actions: [PaletteAction(title: "Show Next Tab", argv: ["tab", "next"]),
                          PaletteAction(title: "Show Previous Tab", argv: ["tab", "prev"])]),
    CommandHelp(section: "Layout", usage: "tab rename [TAB] NAME", summary: "(\"\" clears the name)",
                actions: [PaletteAction(title: "Rename Tab…", argv: ["tab", "rename"],
                                        ask: [Ask(name: "NAME", prompt: "Tab name (empty: name it after its folder)")])]),
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
    CommandHelp(section: "Layout", usage: "jump [back]",
                summary: "the next session that needs you | back to where you were",
                actions: [PaletteAction(title: "Jump to Next Session Needing You", argv: ["jump"]),
                          PaletteAction(title: "Jump Back", argv: ["jump", "back"])]),
    CommandHelp(section: "Layout", usage: "worktree ls",
                actions: [PaletteAction(title: "List Git Worktrees", argv: ["worktree", "ls"])]),

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
    CommandHelp(section: "Input and output", usage: "wait [--pane P] (--pattern RE | --idle SECS) [--timeout T]",
                summary: "exits 124 on timeout"),
    CommandHelp(section: "Input and output", usage: "events [--filter PREFIX]… [--pane P]",
                summary: "JSON lines (pane.created, tab.renamed, …)"),
    CommandHelp(section: "Input and output", usage: "notify [--pane P] TITLE [BODY]",
                actions: [PaletteAction(title: "Notify…", argv: ["notify"], ask: [Ask(name: "TITLE", prompt: "Notification title")])]),
    CommandHelp(section: "Input and output", usage: "sidebar [on|off|toggle|status|tabs|files]",
                actions: [PaletteAction(title: "Toggle Sidebar", argv: ["sidebar", "toggle"]),
                          PaletteAction(title: "Show Sidebar Files", argv: ["sidebar", "files"]),
                          PaletteAction(title: "Show Sidebar Tabs", argv: ["sidebar", "tabs"])]),
    CommandHelp(section: "Input and output", usage: "screenshot [--window W] OUT.png",
                actions: [PaletteAction(title: "Screenshot Window…", argv: ["screenshot"],
                                        ask: [Ask(name: "OUT", prompt: "Save as (.png)", kind: "file")])]),

    // Editor
    CommandHelp(section: "Editor", usage: "edit FILE… [--source|--preview] [--tab T | --pane P]",
                actions: [PaletteAction(title: "Edit File…", argv: ["edit"], ask: [Ask(name: "FILE", prompt: "File", kind: "file")])]),
    CommandHelp(section: "Editor", usage: "editor ls [--tab T | --pane P]",
                actions: [PaletteAction(title: "List Open Files", argv: ["editor", "ls"])]),
    CommandHelp(section: "Editor", usage: "editor close [FILE] [--force]",
                actions: [PaletteAction(title: "Close File", argv: ["editor", "close"])]),
    CommandHelp(section: "Editor", usage: "editor mode [preview|source]",
                actions: [PaletteAction(title: "Toggle Preview and Source", argv: ["editor", "mode"])]),
    CommandHelp(section: "Editor", usage: "editor default [--dry-run]", summary: "make \(productName) the default app for Markdown",
                actions: [PaletteAction(title: "Make \(productName) the Default for Markdown", argv: ["editor", "default"])]),

    // Managed agents
    CommandHelp(section: "Managed agents (see `\(cliName) agent --help`)", usage: "agent start claude|codex [PROMPT…] …",
                summary: "start a session in the background; prints its id",
                actions: [PaletteAction(title: "Start Claude Session…", argv: ["agent", "start", "claude"],
                                        ask: [Ask(name: "PROMPT", prompt: "Prompt", optional: true)]),
                          PaletteAction(title: "Start Codex Session…", argv: ["agent", "start", "codex"],
                                        ask: [Ask(name: "PROMPT", prompt: "Prompt", optional: true)])]),
    CommandHelp(section: "Managed agents (see `\(cliName) agent --help`)", usage: "agent send SESSION TEXT…",
                summary: "a follow-up; prints the message id"),
    CommandHelp(section: "Managed agents (see `\(cliName) agent --help`)", usage: "agent wait SESSION [--report]",
                summary: "wait for the turn (or the worker's report)"),
    CommandHelp(section: "Managed agents (see `\(cliName) agent --help`)", usage: "agent open SESSION",
                summary: "show a session in a pane (a new tab by default)",
                actions: [PaletteAction(title: "Open Agent Session…", argv: ["agent", "open"],
                                        ask: [Ask(name: "SESSION", prompt: "Session (id or name)")])]),
    CommandHelp(section: "Managed agents (see `\(cliName) agent --help`)", usage: """
        agent read | ls | info | interrupt | stop | resume | approve | deny | answer | watch
              | rename | rm | report
        """,
                actions: [PaletteAction(title: "List Agent Sessions", argv: ["agent", "ls"])]),

    // Agents typed into a terminal
    CommandHelp(section: "Agents typed into a terminal", usage: "claude [ARGS…] / codex [ARGS…]",
                summary: "a new tab running `claude ARGS…` as if typed",
                actions: [PaletteAction(title: "Claude in New Tab", argv: ["claude"]),
                          PaletteAction(title: "Codex in New Tab", argv: ["codex"])]),
    CommandHelp(section: "Agents typed into a terminal", usage: """
        claude [--tab | --split [DIR] | --window] [--cwd D] [--worktree W] [--name N] [--pane P]
               [--no-focus] -- [ARGS…]
        """),

    // Other
    CommandHelp(section: "Other", usage: "shortcuts [ls | set ID KEYS | clear ID | reset [ID]]",
                summary: "keyboard shortcuts (also in Settings, ⌘,)",
                actions: [PaletteAction(title: "List Keyboard Shortcuts", argv: ["shortcuts"])]),
    CommandHelp(section: "Other", usage: "update", summary: "download the newest version (it installs when \(productName) quits)",
                actions: [PaletteAction(title: "Check for Updates", argv: ["update", "--check"])]),
    CommandHelp(section: "Other", usage: "update --check | --status",
                summary: "look for a newer version | say what's known, without looking"),
    CommandHelp(section: "Other", usage: "update --now [--force]", summary: """
        download and install now, then relaunch (--force: even while
        agent turns run; they continue after the relaunch)
        """),
    CommandHelp(section: "Other", usage: "update --later | --skip", summary: """
        answer \(productName)'s update question: ask again tomorrow |
        don't ask about this version again
        """),
    CommandHelp(section: "Other", usage: "doctor", summary: "check this machine for what \(productName) needs",
                actions: [PaletteAction(title: "Check This Mac for What \(productName) Needs", argv: ["doctor"])]),
    CommandHelp(section: "Other", usage: "help", summary: "this help (--json: for programs)"),
]

/// `tern help`.
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
        "Selectors: an id or unique id prefix, a name, `.` (the focused one) or #N (tabs, windows).",
        "Inside \(productName)'s terminals, commands default to the calling pane, its tab and window.",
        "Add --json (before any --) for JSON output.",
    ]
    return lines.joined(separator: "\n")
}

/// `tern help --json`: the same commands for programs (the command palette).
func helpJSON() -> [String: Any] {
    ["cli": cliName, "product": productName, "version": 1, "commands": commandTable.map(\.json)]
}
