// Wiring: native messages → model → views → native. Loaded last.
'use strict';

Umi.app = (() => {
  const S = Umi.state, M = Umi.model, post = Umi.bridge.post;

  function render() {
    Umi.views.sidebar.render();
    Umi.views.panes.render();
    Umi.views.panel.render();
  }

  // Who should have the keys: the web layer while a panel is open, a tab name is being edited
  // or the focused pane is drawn here (the picker); else the focused pane's terminal.
  function webWantsKeys() {
    const pane = M.focusedPane();
    return !!(S.ui.panel || S.ui.editingTab || (pane && pane.view !== 'terminal'));
  }

  function focusWeb() {
    if (S.ui.editingTab) Umi.views.sidebar.focus();
    else if (S.ui.panel) Umi.views.panel.focus();
    else Umi.views.picker.focus();
  }

  // Sends the slots of the terminals now on screen. With `focus`, the keys go where they should.
  function report(focus) {
    const msg = {
      type: 'rects',
      rects: Umi.views.panes.terminalRects(),
      viewport: { w: window.innerWidth, h: window.innerHeight },
    };
    const web = webWantsKeys();
    S.ui.keys = web ? 'web' : 'terminal';
    if (focus && !web) msg.focus = M.focusedPane().id;
    post(msg);
    if (focus && web) { post({ type: 'focusWeb' }); focusWeb(); }
  }

  function save() {
    post({ type: 'layout', layout: S.layout, closed: S.closed });
    S.closed = {};
  }

  // Applies a change to the state, then saves, draws and moves the terminals to match.
  function update(fn, { focus = true } = {}) {
    fn();
    save();
    render();
    report(focus);
  }

  function run(name, arg = {}) {
    const action = Umi.actions[name];
    if (!action) return post({ type: 'log', message: 'unknown action ' + name });
    update(() => action(arg));
  }

  return { render, report, update, run, save, webWantsKeys };
})();

Umi.bridge.on('state', (msg) => Umi.app.update(() => Umi.model.load(msg)));
Umi.bridge.on('pane', (msg) => { Umi.model.paneInfo(msg.id, msg.info); Umi.views.sidebar.render(); if (Umi.state.ui.editingTab) Umi.views.sidebar.focus(); });
Umi.bridge.on('focused', (msg) => {
  const found = Umi.model.findPane(msg.pane);
  if (!found) return;
  if (found.tab.focused !== msg.pane || Umi.state.ui.panel || Umi.state.ui.editingTab) {
    // A click in a terminal: it has the keys now, so close what was asking for them.
    Umi.app.update(() => {
      found.tab.focused = msg.pane;
      Umi.state.ui.panel = null;
      Umi.state.ui.editingTab = null;
    }, { focus: false });
  }
});
Umi.bridge.on('sessions', (msg) => {
  if (!Umi.state.layout) return;
  if (Umi.model.sessions(msg.list)) Umi.app.save();
  Umi.views.sidebar.render();
  if (Umi.state.ui.editingTab) Umi.views.sidebar.focus();
  Umi.views.panes.refreshPickers();
});
Umi.bridge.on('pastSessions', (msg) => {
  Umi.state.past = { project: msg.project, list: msg.list };
  Umi.views.panes.refreshPickers();
});
Umi.bridge.on('paneExited', (msg) => Umi.app.update(() => Umi.model.removePane(msg.pane)));
Umi.bridge.on('action', (msg) => Umi.app.run(msg.name, msg));

new ResizeObserver(() => { if (Umi.state.layout) Umi.app.report(false); }).observe(document.documentElement);

// A click in the chrome gives the keys back to whatever should have them.
window.addEventListener('mouseup', (e) => {
  if (!Umi.state.layout || e.target.closest('input, textarea, [contenteditable]')) return;
  Umi.app.report(true);
});

// ⌘-number hints while ⌘ is held (seen only when the web view has the keys).
let cmdTimer = null;
window.addEventListener('keydown', (e) => {
  if (e.key === 'Meta' && !cmdTimer) cmdTimer = setTimeout(() => document.body.classList.add('cmd-held'), 750);
});
window.addEventListener('keyup', (e) => {
  if (e.key === 'Meta') { clearTimeout(cmdTimer); cmdTimer = null; document.body.classList.remove('cmd-held'); }
});

Umi.bridge.post({ type: 'hello' });
