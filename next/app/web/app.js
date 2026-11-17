// Wiring: native messages → model → views → native. Loaded last.
'use strict';

Umi.app = (() => {
  const S = Umi.state, M = Umi.model, post = Umi.bridge.post;

  function render() {
    Umi.views.sidebar.render();
    Umi.views.panes.render();
    Umi.views.panel.render();
  }

  // Sends the slots of the terminals now on screen. With `focus`, keyboard focus goes to the
  // focused pane if it's a terminal, else (a web-drawn view or an open panel) to the web view.
  function report(focus) {
    const msg = {
      type: 'rects',
      rects: Umi.views.panes.terminalRects(),
      viewport: { w: window.innerWidth, h: window.innerHeight },
    };
    const pane = M.focusedPane();
    const webKeys = S.ui.panel || (pane && pane.view !== 'terminal');
    S.ui.keys = webKeys ? 'web' : 'terminal';
    if (focus && !webKeys) msg.focus = pane.id;
    post(msg);
    if (focus && webKeys) post({ type: 'focusWeb' });
  }

  // Applies a change to the state, then saves, draws and moves the terminals to match.
  function update(fn, { focus = true } = {}) {
    fn();
    post({ type: 'layout', layout: S.layout, closed: S.closed });
    S.closed = {};
    render();
    report(focus);
  }

  function run(name, arg = {}) {
    const action = Umi.actions[name];
    if (!action) return post({ type: 'log', message: 'unknown action ' + name });
    update(() => action(arg));
  }

  return { render, report, update, run };
})();

Umi.bridge.on('state', (msg) => Umi.app.update(() => Umi.model.load(msg)));
Umi.bridge.on('pane', (msg) => { Umi.model.paneInfo(msg.id, msg.info); Umi.views.sidebar.render(); });
Umi.bridge.on('focused', (msg) => {
  const found = Umi.model.findPane(msg.pane);
  if (found && found.tab.focused !== msg.pane) Umi.app.update(() => { found.tab.focused = msg.pane; }, { focus: false });
});
Umi.bridge.on('paneExited', (msg) => Umi.app.update(() => Umi.model.removePane(msg.pane)));
Umi.bridge.on('action', (msg) => Umi.app.run(msg.name, msg));

new ResizeObserver(() => { if (Umi.state.layout) Umi.app.report(false); }).observe(document.documentElement);

// A click in the chrome gives the keys back to the focused terminal, unless the web layer wants
// them (an open panel, a web-drawn pane, a text field).
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
