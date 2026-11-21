// The bottom panel host and the palette (DESIGN "The palette at the bottom"). The panel lies over
// the bottom of the panes, which keep their size; native clips the terminals it covers. While it's
// open the web view has the keys.
//
// Palette: columns of commands, one letter each, the frequent ones under the left hand; `/`
// searches every command by name; Esc closes. Rename and Snooze ask for one line first.
'use strict';
Umi.views = Umi.views || {};

Umi.views.panel = (() => {
  const S = Umi.state, M = Umi.model;

  const COLUMNS = [
    { title: 'Sessions', cmds: [
      ['n', 'New session', () => Umi.actions.splitRight()],
      ['s', 'Switch session', () => Umi.actions.switchSession()],
      ['p', 'Open past', () => { Umi.actions.switchSession(); Umi.model.focusedPane().picker.jump = 'past'; }],
      ['o', 'Reopen the last closed pane or tab', () => Umi.actions.reopen()],
      ['a', 'Show archived tabs', () => Umi.actions.showArchived()],
    ] },
    { title: 'This session', cmds: [
      ['r', 'Rename', () => ask('rename')],
      ['z', 'Snooze', () => ask('snooze')],
      ['d', 'Send to docket', () => Umi.actions.docketSession()],
      ['t', 'Restart', () => Umi.actions.restartSession()],
      ['h', 'Hide (keeps running)', () => Umi.actions.hidePane()],
      ['x', 'Exit', () => Umi.actions.exitSession()],
      ['m', 'Move to new tab', () => Umi.actions.moveToNewTab()],
    ] },
    { title: 'Review', cmds: [
      ['c', 'Clear finished snoozes', () => {
        for (const m of Object.values(S.layout.meta?.sessions || {})) if (m.snooze?.done) delete m.snooze;
      }],
    ] },
    { title: 'Options', cmds: [
      ['b', 'Sidebar', () => Umi.actions.toggleSidebar()],
      ['l', 'Reload web layer', () => Umi.actions.reloadWeb()],
      ['u', 'Update and restart', () => Umi.actions.updateApp()],
      ['k', 'Keyboard shortcuts', () => Umi.actions.toggleShortcuts()],
    ] },
  ];
  const ALL = COLUMNS.flatMap((c) => c.cmds.map(([key, name, fn]) => ({ key, name, fn, column: c.title })));

  const renderers = { palette: renderPalette };

  // Runs a command: closes the palette first; a command that asks (rename, snooze) reopens it.
  function runCommand(cmd) {
    Umi.app.update(() => {
      M.closePanel();
      cmd.fn();
    });
  }

  function ask(mode) {
    const sid = M.sessionOf(M.activeTab().focused);
    if (!sid) return;
    M.openPanel('palette', { mode, sid });
  }

  const SNOOZE_UNITS = { s: 1, m: 60, h: 3600, d: 86400 };
  function parseDuration(text) {
    const m = /^\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*$/i.exec(text);
    if (!m) return null;
    return parseFloat(m[1]) * SNOOZE_UNITS[(m[2] || 'm').toLowerCase()];
  }

  function renderPalette(el, p) {
    el.classList.add('palette');
    if (p.mode === 'rename' || p.mode === 'snooze') {
      const name = M.sessionName(p.sid);
      el.innerHTML = `<div class="palette-ask"><span></span><input spellcheck="false"><span class="dim"></span></div>`;
      el.querySelector('span').textContent = p.mode === 'rename' ? `Rename “${name}”` : `Snooze “${name}”`;
      el.querySelector('.dim').textContent = p.mode === 'rename' ? 'Enter keeps it; empty: the daemon’s name' : 'for how long (2h, 30m)? Empty: until its turn ends';
      const input = el.querySelector('input');
      if (p.mode === 'rename') input.value = S.layout.meta?.sessions?.[p.sid]?.name || '';
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.preventDefault(); Umi.app.update(() => M.openPanel('palette', { mode: 'commands', query: '' })); }
        if (e.key !== 'Enter') return;
        e.preventDefault();
        const v = input.value.trim();
        if (p.mode === 'snooze' && v && parseDuration(v) == null) { input.classList.add('bad'); return; }
        Umi.app.update(() => {
          M.closePanel();
          if (p.mode === 'rename') M.rename(p.sid, v);
          else M.snooze(p.sid, v ? parseDuration(v) : null);
        });
      });
      return;
    }
    const searching = p.mode === 'search';
    const q = (p.query || '').toLowerCase();
    // The search also finds every action of the shortcut table, with its keys.
    const fromTable = Umi.shortcuts.table.filter((e) => e.action && e.label && !ALL.some((c) => c.name === e.label))
      .map((e) => ({ key: e.display || Umi.shortcuts.format(e.keys), name: e.label, fn: () => (typeof e.action === 'function' ? e.action(e.arg || {}) : Umi.actions[e.action]?.(e.arg || {})), table: true }));
    const matches = searching ? [...ALL, ...fromTable].filter((c) => c.name.toLowerCase().includes(q)) : [];
    el.innerHTML = `
      <div class="palette-cols"></div>
      <div class="palette-search"><span>/</span><input spellcheck="false" placeholder="search commands"></div>`;
    const cols = el.querySelector('.palette-cols');
    if (searching) {
      matches.forEach((c, i) => cols.append(cmdRow(c, i === 0)));
      if (!matches.length) cols.textContent = 'No command matches.';
    } else {
      for (const col of COLUMNS) {
        const div = document.createElement('div');
        div.className = 'palette-col';
        const h = document.createElement('h4');
        h.textContent = col.title;
        div.append(h);
        col.cmds.forEach(([key, name, fn]) => div.append(cmdRow({ key, name, fn })));
        cols.append(div);
      }
    }
    const input = el.querySelector('.palette-search input');
    input.value = p.query || '';
    input.addEventListener('input', () => { p.query = input.value; p.mode = 'search'; render(); focus(); });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); Umi.app.update(() => M.closePanel()); }
      if (e.key === 'Enter' && matches[0]) { e.preventDefault(); runCommand(matches[0]); }
    });
  }

  function cmdRow(c, first) {
    const row = document.createElement('div');
    row.className = 'palette-cmd' + (first ? ' first' : '');
    row.innerHTML = '<kbd></kbd><span></span>';
    row.querySelector('kbd').textContent = c.key;
    row.querySelector('span').textContent = c.name;
    row.addEventListener('mousedown', (e) => { e.preventDefault(); runCommand(c); });
    return row;
  }

  // Letters run commands while the palette shows its columns (the search field is empty).
  window.addEventListener('keydown', (e) => {
    const p = S.ui.panel;
    if (!p || p.name !== 'palette' || p.mode !== 'commands' || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'Escape') { e.preventDefault(); return Umi.app.update(() => M.closePanel()); }
    if (e.key === '/') { e.preventDefault(); p.mode = 'search'; p.query = ''; render(); return focus(); }
    const cmd = ALL.find((c) => c.key === e.key.toLowerCase());
    if (cmd) { e.preventDefault(); runCommand(cmd); }
  }, true);

  function render() {
    const el = document.querySelector('#panel');
    const p = S.ui.panel;
    el.textContent = '';
    el.className = '';
    el.hidden = !p;
    if (!p) return;
    const r = renderers[p.name];
    if (r) r(el, p);
    else el.textContent = p.name;
  }

  // Keys go to the panel's text field when it shows one (search, rename, snooze).
  function focus() {
    const p = S.ui.panel;
    if (!p) return;
    const input = document.querySelector('#panel input');
    if (input && (p.mode !== 'commands')) { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }
    else if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  }

  // The panel's rect while it shows, in CSS px (native clips terminals out of it).
  function coverRect() {
    const el = document.querySelector('#panel');
    if (el.hidden) return null;
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  }

  return { render, renderers, focus, coverRect, COLUMNS };
})();
