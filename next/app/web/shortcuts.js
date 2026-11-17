// The global shortcuts: the one table native intercepts keys by (Sources/UmiNext/Shortcuts.swift)
// and the shortcuts page renders from. Edit it and save: the page reloads and sends the new table,
// no rebuild. A key that matches no entry reaches the focused terminal or page as usual.
//
// Entry: {id, keys, label, group, action, arg?, native?, when?, display?}
//   keys    'cmd+shift+d': modifiers cmd shift opt ctrl (or hyper = all four), then a key as typed
//           without modifiers ('d', '[', '1') or a name (left right up down enter escape tab space
//           backspace delete home end pageup pagedown f1–f12). null: shown on the page only.
//   action  a Umi.actions name, or a function (arg) run like an action (Umi.app.update around it).
//   native  'reload' | 'quit': native does it itself, so it works while the page is broken.
//   when    'terminal': native takes the key only while a terminal has the keys; while the page
//           has them the key goes to the page first (an editor can use it) and runs here only if
//           nothing called preventDefault. Default: always taken.
//   display what the shortcuts page shows instead of format(keys) (e.g. the lone Hyper tap).
//
//   Umi.shortcuts.table               the entries
//   Umi.shortcuts.format(keys)        '⇧⌘D'
//   Umi.shortcuts.run(id)             runs an entry's action
//   Umi.shortcuts.send()              sends the table to native (app.js does on load)
'use strict';
window.Umi = window.Umi || {};

Umi.shortcuts = (() => {
  const table = [
    { id: 'newTab', keys: 'cmd+t', label: 'New tab', group: 'Tabs', action: 'newTab' },
    { id: 'prevTab', keys: 'cmd+shift+[', label: 'Previous tab', group: 'Tabs', action: 'prevTab' },
    { id: 'nextTab', keys: 'cmd+shift+]', label: 'Next tab', group: 'Tabs', action: 'nextTab' },
    ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => ({
      id: 'selectTab' + n, keys: 'cmd+' + n, label: n === 9 ? 'Last tab' : 'Tab ' + n, group: 'Tabs',
      action: 'selectTab', arg: { index: n },
    })),
    { id: 'nextTabCtrl', keys: 'ctrl+tab', label: 'Next tab', group: 'Tabs', action: 'nextTab' },
    { id: 'prevTabCtrl', keys: 'ctrl+shift+tab', label: 'Previous tab', group: 'Tabs', action: 'prevTab' },
    { id: 'closeTab', keys: 'cmd+opt+w', label: 'Hide the tab (sessions keep running)', group: 'Tabs', action: 'closeTab' },
    { id: 'renameTab', keys: 'ctrl+cmd+r', label: 'Rename the tab', group: 'Tabs', action: 'renameTab' },
    { id: 'moveTabUp', keys: 'ctrl+shift+up', label: 'Move the tab up', group: 'Tabs', action: 'moveTabUp' },
    { id: 'moveTabDown', keys: 'ctrl+shift+down', label: 'Move the tab down', group: 'Tabs', action: 'moveTabDown' },
    { id: 'togglePin', keys: 'ctrl+cmd+p', label: 'Pin or unpin the tab', group: 'Tabs', action: 'togglePin' },
    { id: 'toggleArchive', keys: 'ctrl+cmd+a', label: 'Archive the tab, or bring it back', group: 'Tabs', action: 'toggleArchive' },
    { id: 'showArchived', keys: null, label: 'Show archived tabs', group: 'Tabs', action: 'showArchived' },
    { id: 'reopen', keys: 'cmd+shift+t', label: 'Reopen the last closed pane or tab', group: 'Tabs', action: 'reopen' },
    { id: 'splitRight', keys: 'cmd+d', label: 'Split right (picker)', group: 'Panes', action: 'splitRight' },
    { id: 'splitDown', keys: 'cmd+shift+d', label: 'Split down (picker)', group: 'Panes', action: 'splitDown' },
    { id: 'closePane', keys: 'cmd+w', label: 'Hide pane (session keeps running)', group: 'Panes', action: 'closePane' },
    { id: 'focusLeft', keys: 'cmd+opt+left', label: 'Focus pane left', group: 'Panes', action: 'focusDir', arg: { dir: 'left' } },
    { id: 'focusRight', keys: 'cmd+opt+right', label: 'Focus pane right', group: 'Panes', action: 'focusDir', arg: { dir: 'right' } },
    { id: 'focusUp', keys: 'cmd+opt+up', label: 'Focus pane up', group: 'Panes', action: 'focusDir', arg: { dir: 'up' } },
    { id: 'focusDown', keys: 'cmd+opt+down', label: 'Focus pane down', group: 'Panes', action: 'focusDir', arg: { dir: 'down' } },
    { id: 'prevPane', keys: 'cmd+[', label: 'Previous pane', group: 'Panes', action: 'stepPane', arg: { d: -1 } },
    { id: 'nextPane', keys: 'cmd+]', label: 'Next pane', group: 'Panes', action: 'stepPane', arg: { d: 1 } },
    { id: 'equalize', keys: 'ctrl+cmd+=', label: 'Equalize splits', group: 'Panes', action: 'equalize' },
    { id: 'docketSession', keys: 'hyper+d', label: 'Send the session to the docket', group: 'Panes', action: 'docketSession' },
    { id: 'renameSession', keys: 'ctrl+shift+cmd+r', label: 'Rename the session', group: 'Panes', action: 'renameSession' },
    { id: 'toggleZoom', keys: 'cmd+shift+enter', label: 'Zoom the pane, or unzoom', group: 'Panes', action: 'toggleZoom' },
    { id: 'moveToNewTab', keys: 'ctrl+cmd+t', label: 'Move the pane to a new tab', group: 'Panes', action: 'moveToNewTab' },
    { id: 'swapPaneLeft', keys: 'ctrl+cmd+left', label: 'Move the pane left', group: 'Panes', action: 'swapPaneLeft' },
    { id: 'swapPaneRight', keys: 'ctrl+cmd+right', label: 'Move the pane right', group: 'Panes', action: 'swapPaneRight' },
    { id: 'paneToTabUp', keys: 'ctrl+cmd+up', label: 'Move the pane to the tab above', group: 'Panes', action: 'paneToTabUp' },
    { id: 'paneToTabDown', keys: 'ctrl+cmd+down', label: 'Move the pane to the tab below', group: 'Panes', action: 'paneToTabDown' },
    { id: 'nextWaiting', keys: 'ctrl+cmd+j', label: 'Next session waiting for you', group: 'Panes', action: 'nextWaiting' },
    { id: 'goBack', keys: 'ctrl+cmd+k', label: 'Back to where the walk started', group: 'Panes', action: 'goBack' },
    { id: 'find', keys: 'cmd+f', label: 'Find in the terminal', group: 'Terminal', action: 'find', when: 'terminal' },
    { id: 'findNext', keys: 'cmd+g', label: 'Next match', group: 'Terminal', action: 'findNext', when: 'terminal' },
    { id: 'findPrev', keys: 'cmd+shift+g', label: 'Previous match', group: 'Terminal', action: 'findPrev', when: 'terminal' },
    { id: 'toggleSyncTab', keys: 'cmd+opt+i', label: 'Synchronize input in this tab, or stop', group: 'Terminal', action: 'toggleSyncTab' },
    { id: 'toggleSyncAll', keys: null, label: 'Synchronize input in all tabs, or stop', group: 'Terminal', action: 'toggleSyncAll' },
    { id: 'stopSync', keys: 'cmd+opt+shift+i', label: 'Stop synchronizing input', group: 'Terminal', action: 'stopSync' },
    { id: 'fontUp', keys: 'opt+shift+.', display: '⌥⇧>', label: 'Increase font size', group: 'Terminal', action: 'fontUp' },
    { id: 'fontDown', keys: 'opt+shift+,', display: '⌥⇧<', label: 'Decrease font size', group: 'Terminal', action: 'fontDown' },
    { id: 'fontReset', keys: null, label: 'Reset font size', group: 'Terminal', action: 'fontReset' },
    { id: 'palette', keys: 'hyper+space', label: 'Palette', group: 'Window', action: 'togglePalette' },
    { id: 'paletteTap', keys: null, display: 'Hyper (tap)', label: 'Palette', group: 'Window' },
    { id: 'toggleSidebar', keys: 'cmd+b', label: 'Show or hide the sidebar', group: 'Window', action: 'toggleSidebar' },
    { id: 'shortcutsPage', keys: 'cmd+/', label: 'Keyboard shortcuts', group: 'Window', action: 'toggleShortcuts', when: 'terminal' },
    { id: 'zoomIn', keys: 'cmd+=', label: 'Zoom in', group: 'Window', action: 'zoomIn' },
    { id: 'zoomOut', keys: 'cmd+-', label: 'Zoom out', group: 'Window', action: 'zoomOut' },
    { id: 'zoomReset', keys: 'cmd+0', label: 'Actual size', group: 'Window', action: 'zoomReset' },
    { id: 'reloadWeb', keys: 'cmd+shift+r', label: 'Reload the web layer', group: 'Window', native: 'reload' },
    { id: 'quit', keys: 'cmd+q', label: 'Quit (sessions keep running)', group: 'Window', native: 'quit' },
  ];

  const GLYPH = { cmd: '⌘', shift: '⇧', opt: '⌥', ctrl: '⌃' };
  const NAMES = { left: '←', right: '→', up: '↑', down: '↓', enter: '↩', escape: '⎋', tab: '⇥', space: 'Space',
    backspace: '⌫', delete: '⌦', home: '↖', end: '↘', pageup: '⇞', pagedown: '⇟' };
  const ORDER = ['ctrl', 'opt', 'shift', 'cmd'];

  function parse(keys) {
    const parts = keys.toLowerCase().split('+');
    if (keys.endsWith('++')) parts.splice(-2, 2, '+');
    const key = parts.pop();
    const mods = new Set(parts.flatMap((m) => (m === 'hyper' ? ORDER : [{ command: 'cmd', option: 'opt', alt: 'opt', control: 'ctrl' }[m] || m])));
    return { mods, key };
  }

  function format(keys) {
    if (!keys) return '';
    const { mods, key } = parse(keys);
    const m = mods.size === 4 ? 'Hyper+' : ORDER.filter((x) => mods.has(x)).map((x) => GLYPH[x]).join('');
    return m + (NAMES[key] || (/^f\d+$/.test(key) ? key.toUpperCase() : key.toUpperCase()));
  }

  // The key a KeyboardEvent is, as table keys name it (by physical key, so ⇧[ is '[').
  const CODE = { BracketLeft: '[', BracketRight: ']', Minus: '-', Equal: '=', Semicolon: ';', Quote: "'", Comma: ',',
    Period: '.', Slash: '/', Backslash: '\\', Backquote: '`', Space: 'space', Enter: 'enter', Escape: 'escape', Tab: 'tab',
    Backspace: 'backspace', Delete: 'delete', ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down',
    Home: 'home', End: 'end', PageUp: 'pageup', PageDown: 'pagedown' };
  function keyOf(e) {
    if (/^Key[A-Z]$/.test(e.code)) return e.code.slice(3).toLowerCase();
    if (/^(Digit|Numpad)\d$/.test(e.code)) return e.code.slice(-1);
    if (/^F\d+$/.test(e.code)) return e.code.toLowerCase();
    return CODE[e.code] || e.key.toLowerCase();
  }
  function matches(entry, e) {
    if (!entry.keys) return false;
    const { mods, key } = parse(entry.keys);
    return key === keyOf(e) && mods.has('cmd') === e.metaKey && mods.has('shift') === e.shiftKey &&
      mods.has('opt') === e.altKey && mods.has('ctrl') === e.ctrlKey;
  }

  function run(id) {
    const entry = table.find((x) => x.id === id);
    if (!entry) return Umi.bridge.post({ type: 'log', message: 'unknown shortcut ' + id });
    if (entry.native) return Umi.bridge.post({ type: entry.native === 'reload' ? 'reload' : 'log', message: id });
    if (typeof entry.action === 'function') return Umi.app.update(() => entry.action(entry.arg || {}));
    Umi.app.run(entry.action, entry.arg || {});
  }

  function send() {
    Umi.bridge.post({
      type: 'shortcuts',
      table: table.filter((x) => x.keys).map(({ id, keys, native, when }) => ({ id, keys, ...(native ? { native } : {}), ...(when ? { when } : {}) })),
    });
  }

  // Entries with when: 'terminal' while the page has the keys: native let the key through.
  window.addEventListener('keydown', (e) => {
    if (e.defaultPrevented) return;
    const entry = table.find((x) => x.when === 'terminal' && matches(x, e));
    if (entry) { e.preventDefault(); run(entry.id); }
  });

  return { table, format, run, send, matches };
})();

Umi.bridge.on('shortcut', (msg) => Umi.shortcuts.run(msg.id));
