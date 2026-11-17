// The shortcuts page (⌘/, SPEC L-17 as Warp's keybindings panel): 361 px at the window's right,
// read-only, drawn from Umi.shortcuts.table grouped by `group`, so it follows the table as it is
// edited. Searchable by name or by keys as Warp's: modifier words or symbols in any order and at
// most one key ("cmd shift p", "shift cmd p", "⇧⌘P") match the shortcuts holding those modifiers
// and exactly that key. Esc closes it. It takes space from the panes (they reflow), so no
// terminal hides under it.
//
// State: layout.shortcutsPage (open; persisted, so it stays open across web reloads) and
// ui.shortcuts {query, focus} (focus: its search field has the keys).
'use strict';
Umi.views = Umi.views || {};

Umi.views.shortcutsPage = (() => {
  const S = Umi.state;
  const MODS = { cmd: 'cmd', command: 'cmd', '⌘': 'cmd', shift: 'shift', '⇧': 'shift', opt: 'opt', option: 'opt', alt: 'opt',
    '⌥': 'opt', ctrl: 'ctrl', control: 'ctrl', '⌃': 'ctrl', hyper: 'hyper' };
  const KEY_NAMES = { '←': 'left', '→': 'right', '↑': 'up', '↓': 'down', '↩': 'enter', return: 'enter', '⎋': 'escape', esc: 'escape',
    '⇥': 'tab', '⌫': 'backspace', '⌦': 'delete', '⇞': 'pageup', '⇟': 'pagedown' };

  // A query as keys: {mods: Set, key|null}, or null when it isn't one (then it's a name search).
  function parseKeys(q) {
    const mods = new Set();
    let key = null;
    const tokens = [];
    for (const word of q.toLowerCase().split(/[\s+]+/).filter(Boolean)) {
      // "⇧⌘p" is three tokens: peel the modifier symbols off the front.
      let w = word;
      while (w.length > 1 && '⌘⇧⌥⌃'.includes(w[0])) { tokens.push(w[0]); w = w.slice(1); }
      tokens.push(w);
    }
    for (const t of tokens) {
      if (MODS[t]) {
        if (MODS[t] === 'hyper') ['cmd', 'shift', 'opt', 'ctrl'].forEach((m) => mods.add(m));
        else mods.add(MODS[t]);
      } else if (key === null) key = KEY_NAMES[t] || t;
      else return null;
    }
    if (!mods.size) return null;
    return { mods, key };
  }

  function entryKeys(e) {
    if (!e.keys) return null;
    const parts = e.keys.toLowerCase().split('+');
    if (e.keys.endsWith('++')) parts.splice(-2, 2, '+');
    const key = parts.pop();
    const mods = new Set(parts.flatMap((m) => (m === 'hyper' ? ['cmd', 'shift', 'opt', 'ctrl'] : [MODS[m] || m])));
    return { mods, key };
  }

  function matches(e, q) {
    if (!q) return true;
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (words.every((w) => e.label.toLowerCase().includes(w) || (e.group || '').toLowerCase().includes(w))) return true;
    const want = parseKeys(q), have = entryKeys(e);
    if (!want || !have) return false;
    for (const m of want.mods) if (!have.mods.has(m)) return false;
    return want.key === null || want.key === have.key;
  }

  function el(tag, cls, text) {
    const x = document.createElement(tag);
    if (cls) x.className = cls;
    if (text != null) x.textContent = text;
    return x;
  }

  // One keycap per modifier and one for the key, as Umi's (UmiKeycaps).
  function caps(e) {
    if (e.display) return [...e.display.matchAll(/[⌘⇧⌥⌃]|[^⌘⇧⌥⌃]+/g)].map((m) => m[0]);
    const f = Umi.shortcuts.format(e.keys);
    if (f.startsWith('Hyper+')) return ['Hyper', f.slice(6)];
    return [...f.matchAll(/[⌘⇧⌥⌃]|[^⌘⇧⌥⌃]+/g)].map((m) => m[0]);
  }
  function keycaps(symbols) {
    const k = el('span', 'sc-caps');
    for (const sym of symbols) k.append(el('kbd', null, sym));
    return k;
  }

  // Warp's panel (Umi's UmiShortcutsPanel): the toggle key, how to change shortcuts, the search,
  // then a section per group with a row per action, its keys stacked when it has several.
  function render() {
    const box = document.querySelector('#shortcuts');
    const open = !!S.layout.shortcutsPage;
    box.hidden = !open;
    if (!open) return;
    const ui = (S.ui.shortcuts = S.ui.shortcuts || { query: '', focus: true });
    let input = box.querySelector('input');
    if (!input) {
      box.textContent = '';
      const head = el('div', 'sc-head');
      const toggle = Umi.shortcuts.table.find((e) => e.id === 'shortcutsPage');
      const line = el('div', 'sc-toggle');
      if (toggle?.keys) line.append(keycaps(caps(toggle)));
      line.append(el('span', null, 'To toggle this panel'));
      const x = el('button', 'sc-close', '×');
      x.title = 'Close (Esc)';
      x.addEventListener('click', () => Umi.app.run('toggleShortcuts'));
      line.append(x);
      head.append(line, el('div', 'sc-how', 'Change shortcuts by editing web/shortcuts.js; the page reloads with them.'));
      const search = el('label', 'sc-search');
      search.innerHTML = '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14" stroke-linecap="round"/></svg>';
      input = el('input');
      input.spellcheck = false;
      input.placeholder = 'Search by name or by keys (ex. "cmd d")';
      search.append(input);
      // S.ui.shortcuts, not `ui`: the field outlives a close and reopen, which make a new one.
      input.addEventListener('input', () => { if (S.ui.shortcuts) S.ui.shortcuts.query = input.value; renderList(); });
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.preventDefault(); Umi.app.run('toggleShortcuts'); }
      });
      box.addEventListener('mousedown', () => { if (S.ui.shortcuts) S.ui.shortcuts.focus = true; });
      box.append(head, search, el('div', 'sc-list'));
    }
    if (input.value !== ui.query) input.value = ui.query;
    renderList();
  }

  function renderList() {
    const box = document.querySelector('#shortcuts');
    const list = box.querySelector('.sc-list');
    if (!list) return;
    const q = S.ui.shortcuts?.query?.trim() || '';
    list.textContent = '';
    // group -> label -> entries (an action on two keys, such as Next tab, is one row).
    const groups = new Map();
    for (const e of Umi.shortcuts.table) {
      if (!e.label || !matches(e, q)) continue;
      const g = e.group || 'Other';
      if (!groups.has(g)) groups.set(g, new Map());
      const rows = groups.get(g);
      if (!rows.has(e.label)) rows.set(e.label, []);
      rows.get(e.label).push(e);
    }
    if (!groups.size) { list.append(el('div', 'sc-empty', 'No shortcuts match.')); return; }
    for (const [g, rows] of groups) {
      list.append(el('div', 'sc-group', g));
      for (const [label, entries] of rows) {
        const row = el('div', 'sc-row');
        row.dataset.id = entries[0].id;
        row.dataset.ids = entries.map((e) => e.id).join(' ');
        row.append(el('span', 'sc-label', label));
        const keys = el('span', 'sc-keys');
        for (const e of entries) if (e.keys || e.display) keys.append(keycaps(caps(e)));
        row.append(keys);
        list.append(row);
      }
    }
  }

  function focus() {
    const input = document.querySelector('#shortcuts input');
    if (input && document.activeElement !== input) input.focus();
  }

  const wantsKeys = () => !!(S.layout?.shortcutsPage && S.ui.shortcuts?.focus !== false);

  return { render, focus, wantsKeys, parseKeys, matches };
})();

// ⌘/ opens the page with its search field focused; pressed again (or Esc in the page) closes it.
Umi.actions.toggleShortcuts = () => {
  const S = Umi.state;
  if (S.layout.shortcutsPage) { delete S.layout.shortcutsPage; S.ui.shortcuts = null; return; }
  S.layout.shortcutsPage = true;
  S.ui.shortcuts = { query: '', focus: true };
};
