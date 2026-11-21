// Wiring: native messages → model → views → native. Loaded last.
'use strict';

Umi.app = (() => {
  const S = Umi.state, M = Umi.model, post = Umi.bridge.post;

  function render() {
    Umi.views.sidebar.render();
    Umi.views.panes.render();
    Umi.views.marks.render();
    Umi.views.panel.render();
    Umi.views.shortcutsPage.render();
    Umi.views.find.render();
  }

  // Who should have the keys: the web layer while a panel is open, a tab name is being edited,
  // the find bar or the shortcuts page's search has them, a part of the sidebar has them
  // (explorer, search), or the focused pane is drawn here (the picker); else the focused pane's
  // terminal.
  function webWantsKeys() {
    const pane = M.focusedPane();
    return !!(S.ui.panel || S.ui.editingTab || Umi.views.find.wantsKeys() || Umi.views.shortcutsPage.wantsKeys()
      || Umi.views.modes.hasKeys() || (pane && pane.view !== 'terminal'));
  }

  function focusWeb() {
    if (S.ui.editingTab) Umi.views.sidebar.focus();
    else if (S.ui.panel) Umi.views.panel.focus();
    else if (Umi.views.find.wantsKeys()) Umi.views.find.focus();
    else if (Umi.views.shortcutsPage.wantsKeys()) Umi.views.shortcutsPage.focus();
    else if (Umi.views.modes.hasKeys()) Umi.views.modes.focus();
    else if (M.focusedPane()?.view === 'file') Umi.views.file.focus(M.focusedPane().id);
    else Umi.views.picker.focus();
  }

  let lastTab = null;
  // Sends the slots of the terminals now on screen. With `focus`, the keys go where they should.
  function report(focus) {
    const msg = {
      type: 'rects',
      rects: Umi.views.panes.terminalRects(),
      passThrough: Umi.views.panes.passThroughRects(),
      // Web chrome lying over a terminal (the find bar): native cuts it out of the terminal's view.
      holes: [Umi.views.find.holeRect()].filter(Boolean),
      // A tab switch fades the terminals in from the window's background (L-11).
      fade: lastTab !== null && lastTab !== S.layout.activeTab,
      chrome: Umi.views.panes.chromeRects(),
      cover: Umi.views.panel.coverRect(),
      // The terminal native brightens (SPEC PI-3): the focused one, when the tab shows several.
      tint: M.paneIds(M.activeTab().root).length > 1 && !M.activeTab().zoomed ? M.activeTab().focused : null,
      viewport: { w: window.innerWidth, h: window.innerHeight },
    };
    lastTab = S.layout.activeTab;
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
    // An action gives the keys back to the pane unless it says otherwise (the sidebar's own keys).
    update(() => { if (!action.keepsFocus) S.ui.sidebarFocus = null; action(arg); });
  }

  return { render, report, update, run, save, webWantsKeys };
})();

Umi.bridge.on('state', (msg) => Umi.app.update(() => Umi.model.load(msg)));
// Terminal titles change many times a second while a program runs: the model takes each at once,
// the drawing once per frame. WebKit stops frames in a window that doesn't show, so a timer draws
// there instead.
let paneDraw = null;
function drawPanes() {
  if (!paneDraw) return;
  cancelAnimationFrame(paneDraw.frame);
  clearTimeout(paneDraw.timer);
  paneDraw = null;
  Umi.views.sidebar.render();
  Umi.views.panes.refreshChrome();
  Umi.app.report(false);
  if (Umi.state.ui.editingTab) Umi.views.sidebar.focus();
}
Umi.bridge.on('pane', (msg) => {
  Umi.model.paneInfo(msg.id, msg.info);
  if (!paneDraw) paneDraw = { frame: requestAnimationFrame(drawPanes), timer: setTimeout(drawPanes, 100) };
});
Umi.bridge.on('focused', (msg) => {
  const found = Umi.model.findPane(msg.pane);
  if (!found) return;
  if (found.tab.focused !== msg.pane || Umi.state.ui.panel || Umi.state.ui.editingTab || found.tab.id !== Umi.state.layout.activeTab
    || Umi.state.ui.sidebarFocus) {
    // A click in a terminal: it has the keys now, so close what was asking for them.
    Umi.app.update(() => {
      found.tab.focused = msg.pane;
      Umi.state.ui.panel = null;
      Umi.state.ui.editingTab = null;
      if (Umi.state.ui.find) Umi.state.ui.find.focus = false;
      if (Umi.state.ui.shortcuts) Umi.state.ui.shortcuts.focus = false;
      Umi.state.ui.sidebarFocus = null;
    }, { focus: false });
  } else if (Umi.views.find.wantsKeys() || Umi.views.shortcutsPage.wantsKeys()) {
    // A click in the terminal that was focused: it has the keys again; the bar and page stay open.
    if (Umi.state.ui.find) Umi.state.ui.find.focus = false;
    if (Umi.state.ui.shortcuts) Umi.state.ui.shortcuts.focus = false;
    Umi.app.report(false);
  }
});
Umi.bridge.on('sessions', (msg) => {
  if (!Umi.state.layout) return;
  if (Umi.model.sessions(msg.list)) Umi.app.save();
  Umi.views.sidebar.render();
  Umi.views.panes.refreshChrome();
  Umi.app.report(false);
  if (Umi.state.ui.editingTab) Umi.views.sidebar.focus();
  Umi.views.panes.refreshPickers();
});
Umi.bridge.on('pastSessions', (msg) => {
  Umi.state.past[msg.project] = msg.list;
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
Umi.shortcuts.send();

