// The status mark (SPEC PI-1..PI-2, Umi's quiet palette): a small round mark in each pane's header
// and before each tab's chip in the top bar. working: a turn runs; needs you: waiting for Alejo
// (Review's "needs"); finished: the turn ended (reply says done) since the pane was last looked
// at. A tab's chip shows its most pressing pane's mark (needs you, then working, then finished).
// The focused pane's and current tab's marks are at full strength; the others' working and
// finished marks are dimmer, "needs you" always full.
//
// Also the Dock badge: how many Review items the current project has.
'use strict';
Umi.views = Umi.views || {};

Umi.views.marks = (() => {
  const S = Umi.state, M = Umi.model;
  const COLORS = { working: '#6F7F76', needs: '#E0A93E', finished: '#BDBDBD' };
  const seen = {}; // session -> when its pane last had focus (ms); "finished" means after that

  function stateOf(sid) {
    const s = sid && S.live[sid];
    if (!s || !s.agent) return null;
    const st = M.standing(s);
    if (st === 'busy') return 'working';
    if (st === 'needs') return 'needs';
    if (st === 'finished' && (s.agent.ts || 0) * 1000 > (seen[sid] || 0)) return 'finished';
    return null;
  }

  // {color, size, opacity} for a pane, or null.
  function look(paneId, tab) {
    const sid = M.sessionOf(paneId), st = stateOf(sid);
    if (!st) return null;
    const focused = tab.focused === paneId && tab.id === S.layout.activeTab;
    return { color: COLORS[st], size: 7, opacity: focused || st === 'needs' ? 1 : 0.7, state: st };
  }
  const RANK = { needs: 3, working: 2, finished: 1 };
  // A tab's mark: its most pressing pane's.
  function tabLook(tab) {
    let best = null;
    for (const id of M.paneIds(tab.root)) {
      const st = stateOf(M.sessionOf(id));
      if (st && (!best || RANK[st] > RANK[best])) best = st;
    }
    if (!best) return null;
    return { color: COLORS[best], size: 7, opacity: tab.id === S.layout.activeTab || best === 'needs' ? 1 : 0.7, state: best };
  }

  function dot(l) {
    const d = document.createElement('span');
    d.className = 'pane-mark';
    d.style.cssText = `width:${l.size}px;height:${l.size}px;background:${l.color};opacity:${l.opacity}`;
    if (l.state) d.dataset.state = l.state;
    return d;
  }

  let badge = null;
  // Draws the marks on the pane headers and the top bar's chips.
  function render() {
    if (!S.layout) return;
    const tab = M.activeTab();
    const sid = M.sessionOf(tab.focused);
    if (sid && document.hasFocus()) seen[sid] = Date.now();
    document.querySelectorAll('#panes .pane-mark, #strip .pane-mark').forEach((m) => m.remove());
    for (const head of document.querySelectorAll('#panes .pane-head')) {
      const l = look(head.dataset.pane, tab);
      if (l) head.prepend(dot(l));
    }
    for (const chip of document.querySelectorAll('#strip .chip[data-tab]')) {
      const t = S.layout.tabs.find((x) => x.id === chip.dataset.tab);
      const l = t && tabLook(t);
      if (l) chip.prepend(dot(l));
    }
    for (const chip of document.querySelectorAll('#strip .chip.hidden')) {
      const st = stateOf(chip.dataset.session);
      if (st) chip.prepend(dot({ color: COLORS[st], size: 7, opacity: st === 'needs' ? 1 : 0.7, state: st }));
    }
    const cur = M.review().find((g) => g.current);
    const n = cur ? cur.items.length : 0;
    if (n !== badge) { badge = n; Umi.bridge.post({ type: 'badge', count: n }); }
  }

  return { render, stateOf };
})();
