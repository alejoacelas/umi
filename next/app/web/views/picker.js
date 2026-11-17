// The pane picker (DESIGN "⌘D: the pane picker"), drawn inside a new pane:
//   1. a name field, focused: Enter starts a Claude session with that name; Tab cycles
//      Claude, Codex, shell;
//   2. live sessions of the focused pane's project waiting for input, most recent first;
//   3. live sessions of that project that are busy;
//   4. past sessions of that project that can be resumed (Claude's and Codex's transcripts).
// ↑↓ choose, Enter opens, Esc closes the pane.
'use strict';
Umi.views = Umi.views || {};

Umi.views.picker = (() => {
  const S = Umi.state, M = Umi.model;
  const KINDS = ['claude', 'codex', 'shell'];
  const LABEL = { claude: 'Claude', codex: 'Codex', shell: 'Shell' };
  const base = (p) => (p || '').split('/').filter(Boolean).pop() || '~';
  const ago = (t) => {
    const s = Date.now() / 1000 - t;
    return s < 90 ? 'just now' : s < 5400 ? `${Math.round(s / 60)} min ago` : s < 129600 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} d ago`;
  };

  function items(node) {
    const pk = node.picker;
    const all = Object.values(S.live).filter((s) => M.userStarted(s) && s.project === pk.project);
    const docketed = all.filter((s) => s.docket);
    const live = all.filter((s) => s.alive && !s.docket);
    const recent = (a, b) => (b.agent?.ts || b.created || 0) - (a.agent?.ts || a.created || 0);
    const by = (st) => live.filter((s) => M.standing(s) === st).sort(recent);
    const past = S.past.project === pk.project ? S.past.list : [];
    return [
      { type: 'new' },
      ...[...by('needs'), ...by('idle')].map((s) => ({ type: 'live', section: 'Waiting for you', s })),
      ...by('busy').map((s) => ({ type: 'live', section: 'Busy', s })),
      ...by('finished').map((s) => ({ type: 'live', section: 'Finished', s })),
      ...docketed.sort(recent).map((s) => ({ type: 'live', section: 'On the docket', s })),
      ...past.map((p) => ({ type: 'past', section: 'Past sessions', p })),
    ];
  }

  function act(node, item) {
    const pk = node.picker;
    const cmds = S.commands || {};
    Umi.app.update(() => {
      if (item.type === 'new') {
        const cmd = pk.kind === 'shell' ? null : (cmds[pk.kind] || pk.kind);
        M.startSession(node.id, { cmd, name: pk.name.trim() });
      } else if (item.type === 'live') {
        M.openSession(item.s.id, node.id);
      } else {
        const p = item.p;
        const cmd = p.kind === 'claude' ? `${cmds.claude || 'claude'} --resume ${p.id}` : `${cmds.codex || 'codex'} resume ${p.id}`;
        M.startSession(node.id, { cmd, name: p.title.slice(0, 40), cwd: p.cwd });
      }
    });
  }

  function render(el, node) {
    const pk = node.picker;
    el.classList.add('picker');
    el.innerHTML = `
      <div class="picker-head">
        <input class="picker-name" spellcheck="false" placeholder="Name (empty: ${base(node.cwd)} and a number)">
        <div class="picker-kinds">${KINDS.map((k) => `<span data-kind="${k}">${LABEL[k]}</span>`).join('')}</div>
      </div>
      <div class="picker-project">${base(pk.project)} <span>${pk.project}</span></div>
      <div class="picker-list"></div>`;
    const input = el.querySelector('.picker-name');
    input.value = pk.name;
    input.addEventListener('input', () => { pk.name = input.value; pk.sel = 0; refresh(el, node); });
    input.addEventListener('keydown', (e) => {
      const list = items(node);
      if (e.key === 'Tab') {
        e.preventDefault();
        pk.kind = KINDS[(KINDS.indexOf(pk.kind) + (e.shiftKey ? 2 : 1)) % 3];
        refresh(el, node);
      } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        pk.sel = Math.max(0, Math.min(list.length - 1, pk.sel + (e.key === 'ArrowDown' ? 1 : -1)));
        refresh(el, node);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        act(node, list[pk.sel] || list[0]);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        const all = S.layout.tabs.flatMap((t) => M.paneIds(t.root));
        if (all.length > 1) Umi.app.update(() => M.removePane(node.id));
      }
    });
    el.addEventListener('mousedown', (e) => {
      const k = e.target.closest('[data-kind]');
      if (k) { pk.kind = k.dataset.kind; refresh(el, node); }
    });
    refresh(el, node);
    if (S.past.project !== pk.project && !pk.askedPast) {
      pk.askedPast = true;
      Umi.bridge.post({ type: 'pastSessions', project: pk.project });
    }
  }

  // Focuses the name field of the focused picker (after a render, when the web view has the keys).
  function focus() {
    const tab = M.activeTab();
    const el = document.querySelector(`#panes .slot[data-pane="${tab.focused}"] .picker-name`);
    if (el && document.activeElement !== el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
  }

  function refresh(el, node) {
    const pk = node.picker;
    el.querySelectorAll('[data-kind]').forEach((k) => k.classList.toggle('on', k.dataset.kind === pk.kind));
    const list = el.querySelector('.picker-list');
    list.textContent = '';
    if (pk.jump === 'past') {
      const i = items(node).findIndex((it) => it.type === 'past');
      if (i > 0) { pk.sel = i; delete pk.jump; }
    }
    let section = null;
    items(node).forEach((item, i) => {
      if (item.section && item.section !== section) {
        section = item.section;
        const h = document.createElement('div');
        h.className = 'picker-section';
        h.textContent = section;
        list.append(h);
      }
      const row = document.createElement('div');
      row.className = 'picker-row' + (i === pk.sel ? ' sel' : '');
      if (item.type === 'new') {
        row.innerHTML = `<b>New ${LABEL[pk.kind]} session</b><span class="dim"></span>`;
        row.querySelector('.dim').textContent = pk.name.trim() || M.defaultName(node.cwd);
      } else if (item.type === 'live') {
        const s = item.s;
        const shown = M.paneOfSession(s.id);
        row.innerHTML = `<span class="kind"></span><b></b><span class="dim"></span>`;
        row.querySelector('.kind').textContent = s.kind;
        row.querySelector('b').textContent = M.sessionName(s.id);
        const st = s.agent && Umi.status.parseStatus(s.agent.reply);
        const said = st ? (st.kind === 'other' ? st.detail : `${st.kind === 'pending' ? 'done, pending' : st.kind}${st.detail ? ': ' + st.detail : ''}`) : '';
        const dk = s.docket && ({ pending: 'docketed, turn running', on: 'on the docket', failed: 'docket hook failed' }[s.docket.state]);
        row.querySelector('.dim').textContent = [dk, M.isSnoozed(s.id) ? 'snoozed' : '', shown ? 'on screen' : '', said || s.foreground, base(s.folder)].filter(Boolean).join(' · ');
      } else {
        const p = item.p;
        row.innerHTML = `<span class="kind"></span><b></b><span class="dim"></span>`;
        row.querySelector('.kind').textContent = p.kind;
        row.querySelector('b').textContent = p.title;
        row.querySelector('.dim').textContent = ago(p.mtime);
      }
      row.addEventListener('mousedown', (e) => { e.preventDefault(); pk.sel = i; act(node, item); });
      list.append(row);
    });
    const sel = list.querySelector('.sel');
    if (sel) sel.scrollIntoView({ block: 'nearest' });
  }

  return { render, refresh, focus };
})();
