# New-pane project ranking and agent icons

Projects with Claude Code or Codex transcript history rank before unused fuzzy matches. Exact path browsing keeps its existing ordering. History scanning runs separately from session monitoring and caches results for one minute, keeping repeated searches responsive.

The picker uses branded icons for Claude Code, Codex and Antigravity in session rows, creation buttons and the new-session row. Antigravity launches through `agy --dangerously-skip-permissions`; its exact executable identifies the session because it has no Umi hooks. The selector wraps in narrow panes and cycles all four choices in either direction with Tab.

Verified on mac-air-2 in an isolated native app: real Claude/Codex transcript fixtures affect rendered ordering, nonmatches stay excluded, path browsing and Enter selection work, icons load, every selector button works, Tab/Shift-Tab cycle correctly, and Enter routes the chosen command. The combined build's initial history scan took 1.93 seconds; a cached response took 0.11 seconds. Screenshot inspection found no clipping. Updated the signed installed Umi Next; all six existing live sessions survived its UI restart.
