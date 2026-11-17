// umi-next web layer. Draws everything around the terminals and owns the layout; the native
// shell owns the terminals and puts each one in the slot this page reports.
//
// Bridge (see Sources/UmiNext/MainWindow.swift):
//   to native   post({type:'hello'}) · {type:'layout', layout} · {type:'rects', rects, viewport, focus?}
//               · {type:'focus', pane} · {type:'error', message} · {type:'log', message}
//   from native umiNative.receive({type:'state'|'pane'|'focused'|'action'|'paneExited', ...})
'use strict';

const post = (msg) => window.webkit.messageHandlers.umi.postMessage(msg);
const $ = (sel) => document.querySelector(sel);
const uid = (p) => p + Math.random().toString(36).slice(2, 10);

let layout = null;        // {version, tabs:[{id, name?, root, focused}], activeTab, sidebar}
let panes = {};           // paneId -> {session, title, pwd, exitCode}
let home = '';

// ---------- layout tree ----------

const newPane = (cwd) => ({ type: 'pane', id: uid('p'), ...(cwd ? { cwd } : {}) });
const newTab = (cwd) => { const p = newPane(cwd); return { id: uid('t'), root: p, focused: p.id }; };

function paneIds(node) {
  if (!node) return [];
  return node.type === 'pane' ? [node.id] : [...paneIds(node.a), ...paneIds(node.b)];
}

function activeTab() { return layout.tabs.find((t) => t.id === layout.activeTab) || layout.tabs[0]; }
function tabOfPane(id) { return layout.tabs.find((t) => paneIds(t.root).includes(id)); }

// Replace the node with pane `id` by fn(node); returns the new tree.
function mapPane(node, id, fn) {
  if (node.type === 'pane') return node.id === id ? fn(node) : node;
  return { ...node, a: mapPane(node.a, id, fn), b: mapPane(node.b, id, fn) };
}

// The tree without pane `id` (its sibling takes the split's place), or null if it was the only pane.
function removePane(node, id) {
  if (node.type === 'pane') return node.id === id ? null : node;
  const a = removePane(node.a, id), b = removePane(node.b, id);
  if (!a) return b;
  if (!b) return a;
  return { ...node, a, b };
}

function cwdOf(paneId) { return panes[paneId]?.pwd; }

// ---------- actions ----------

const actions = {
  newTab() {
    const cur = activeTab();
    const t = newTab(cur && cwdOf(cur.focused));
    const i = layout.tabs.indexOf(cur);
    layout.tabs.splice(i + 1, 0, t);
    layout.activeTab = t.id;
  },
  splitRight() { split('row'); },
  splitDown() { split('column'); },
  closePane() { closePane(activeTab().focused); },
  selectTab({ index }) {
    const t = index === 9 ? layout.tabs[layout.tabs.length - 1] : layout.tabs[index - 1];
    if (t) layout.activeTab = t.id;
  },
  nextTab() { stepTab(1); },
  prevTab() { stepTab(-1); },
  toggleSidebar() { layout.sidebar = layout.sidebar === false; },
  focusDir({ dir }) {
    const tab = activeTab();
    const rects = slotRects();
    const from = rects[tab.focused];
    if (!from) return;
    const cx = from.x + from.w / 2, cy = from.y + from.h / 2;
    let best = null, bestD = Infinity;
    for (const [id, r] of Object.entries(rects)) {
      if (id === tab.focused) continue;
      const x = r.x + r.w / 2, y = r.y + r.h / 2;
      const ok = { left: x < cx - 1, right: x > cx + 1, up: y < cy - 1, down: y > cy + 1 }[dir];
      const d = Math.hypot(x - cx, y - cy);
      if (ok && d < bestD) { best = id; bestD = d; }
    }
    if (best) tab.focused = best;
  },
};

function split(dir) {
  const tab = activeTab();
  const p = newPane(cwdOf(tab.focused));
  tab.root = mapPane(tab.root, tab.focused, (old) => ({ type: 'split', dir, ratio: 0.5, a: old, b: p }));
  tab.focused = p.id;
}

function closePane(id) {
  const tab = tabOfPane(id);
  if (!tab) return;
  const root = removePane(tab.root, id);
  if (root) {
    tab.root = root;
    if (tab.focused === id) tab.focused = paneIds(root)[0];
    return;
  }
  const i = layout.tabs.indexOf(tab);
  layout.tabs.splice(i, 1);
  if (layout.tabs.length === 0) layout.tabs.push(newTab());
  if (layout.activeTab === tab.id) layout.activeTab = layout.tabs[Math.min(i, layout.tabs.length - 1)].id;
}

function stepTab(d) {
  const i = layout.tabs.indexOf(activeTab());
  const n = layout.tabs.length;
  layout.activeTab = layout.tabs[(i + d + n) % n].id;
}

// Run an action, then save, draw, and move the terminals (and keyboard focus) to match.
function run(name, arg = {}) {
  if (!actions[name]) return post({ type: 'log', message: 'unknown action ' + name });
  actions[name](arg);
  commit({ focus: true });
}

function commit({ focus = false } = {}) {
  post({ type: 'layout', layout });
  render();
  report(focus);
}

// ---------- drawing ----------

function shortPath(p) {
  if (!p) return '';
  return home && p.startsWith(home) ? '~' + p.slice(home.length) : p;
}
const base = (p) => (p ? (shortPath(p).split('/').filter(Boolean).pop() || '/') : '');

function renderSidebar() {
  document.body.classList.toggle('no-sidebar', layout.sidebar === false);
  const list = $('#tabs');
  list.textContent = '';
  layout.tabs.forEach((tab, i) => {
    const info = panes[tab.focused] || {};
    const count = paneIds(tab.root).length;
    const row = document.createElement('div');
    row.className = 'tab' + (tab.id === layout.activeTab ? ' active' : '');
    row.innerHTML = `
      <div class="icon">&gt;_</div>
      <div class="text">
        <div class="line1"></div>
        <div class="line2"></div>
      </div>
      <div class="key"></div>
      <button class="close" title="Close tab">×</button>`;
    const line1 = row.querySelector('.line1');
    line1.textContent = tab.name || base(info.pwd) || 'Terminal';
    if (count > 1) {
      const c = document.createElement('span');
      c.className = 'count';
      c.textContent = `· ${count}`;
      line1.append(c);
    }
    const line2 = row.querySelector('.line2');
    const failed = info.exitCode != null && ![0, 130, 141, -1].includes(info.exitCode);
    if (failed) {
      const f = document.createElement('span');
      f.className = 'failed';
      f.textContent = '▲';
      line2.append(f);
    }
    line2.append(document.createTextNode(info.title || shortPath(info.pwd) || ''));
    row.querySelector('.key').textContent = i < 8 ? `⌘${i + 1}` : (i === layout.tabs.length - 1 ? '⌘9' : '');
    row.addEventListener('mousedown', (e) => {
      if (e.target.closest('.close')) return;
      layout.activeTab = tab.id;
      commit({ focus: true });
    });
    row.querySelector('.close').addEventListener('click', () => {
      paneIds(tab.root).forEach((id) => closePane(id));
      commit({ focus: true });
    });
    list.append(row);
  });
}

function renderNode(node) {
  if (node.type === 'pane') {
    const el = document.createElement('div');
    el.className = 'slot';
    el.dataset.pane = node.id;
    return el;
  }
  const el = document.createElement('div');
  el.className = `split ${node.dir}`;
  const a = document.createElement('div'), b = document.createElement('div');
  a.className = b.className = 'child';
  a.style.flex = `${node.ratio} 1 0`;
  b.style.flex = `${1 - node.ratio} 1 0`;
  a.append(renderNode(node.a));
  b.append(renderNode(node.b));
  const div = document.createElement('div');
  div.className = 'divider';
  div.addEventListener('mousedown', (e) => dragDivider(e, node, el));
  el.append(a, div, b);
  return el;
}

function renderPanes() {
  const main = $('#panes');
  main.textContent = '';
  const tab = activeTab();
  main.classList.toggle('multi', paneIds(tab.root).length > 1);
  main.append(renderNode(tab.root));
  main.querySelectorAll('.slot').forEach((s) => s.classList.toggle('focused', s.dataset.pane === tab.focused));
}

function render() {
  renderSidebar();
  renderPanes();
}

function dragDivider(e, node, el) {
  e.preventDefault();
  const box = el.getBoundingClientRect();
  const move = (ev) => {
    const r = node.dir === 'row' ? (ev.clientX - box.left) / box.width : (ev.clientY - box.top) / box.height;
    node.ratio = Math.min(0.9, Math.max(0.1, r));
    renderPanes();
    report(false);
  };
  const up = () => {
    window.removeEventListener('mousemove', move);
    window.removeEventListener('mouseup', up);
    commit({ focus: true });
  };
  window.addEventListener('mousemove', move);
  window.addEventListener('mouseup', up);
}

// ---------- rects ----------

function slotRects() {
  const out = {};
  document.querySelectorAll('#panes .slot').forEach((s) => {
    const r = s.getBoundingClientRect();
    out[s.dataset.pane] = { x: r.left, y: r.top, w: r.width, h: r.height };
  });
  return out;
}

function report(focus) {
  const msg = { type: 'rects', rects: slotRects(), viewport: { w: window.innerWidth, h: window.innerHeight } };
  if (focus) msg.focus = activeTab().focused;
  post(msg);
}

new ResizeObserver(() => { if (layout) report(false); }).observe(document.documentElement);

// ---------- from native ----------

window.umiNative = {
  receive(msg) {
    switch (msg.type) {
      case 'state':
        home = msg.home || '';
        panes = msg.panes || {};
        layout = msg.layout && msg.layout.tabs && msg.layout.tabs.length
          ? msg.layout
          : { version: 1, tabs: [newTab()], sidebar: true };
        if (!layout.tabs.some((t) => t.id === layout.activeTab)) layout.activeTab = layout.tabs[0].id;
        commit({ focus: true });
        break;
      case 'pane':
        panes[msg.id] = msg.info;
        if (layout) renderSidebar();
        break;
      case 'focused': {
        const tab = tabOfPane(msg.pane);
        if (tab && tab.focused !== msg.pane) {
          tab.focused = msg.pane;
          post({ type: 'layout', layout });
          render();
        }
        break;
      }
      case 'paneExited':
        closePane(msg.pane);
        commit({ focus: true });
        break;
      case 'action':
        run(msg.name, msg);
        break;
    }
  },
};

$('#new-tab').addEventListener('click', () => run('newTab'));

// A click anywhere in the chrome hands the keys back to the focused terminal (text fields keep them).
window.addEventListener('mouseup', (e) => {
  if (!layout || e.target.closest('input, textarea, [contenteditable]')) return;
  post({ type: 'focus', pane: activeTab().focused });
});

// Show the ⌘-number hints while ⌘ is held (only seen when the web view has the keys).
let cmdTimer = null;
window.addEventListener('keydown', (e) => {
  if (e.key === 'Meta' && !cmdTimer) cmdTimer = setTimeout(() => document.body.classList.add('cmd-held'), 750);
});
window.addEventListener('keyup', (e) => {
  if (e.key === 'Meta') { clearTimeout(cmdTimer); cmdTimer = null; document.body.classList.remove('cmd-held'); }
});

post({ type: 'hello' });
