// The pane indicator (SPEC PI-1..PI-3, Umi's quiet palette): a small round mark at each pane's
// bottom right and before its strip chip. working: a turn runs; needs you: waiting for Alejo
// (Review's "needs"); finished: the turn ended (reply says done) since the pane was last looked
// at. The focused pane's mark is larger and at full strength; the others' working and finished
// marks are dimmer, "needs you" always full. The marks over terminals are page chrome: native cuts
// them out of the terminal (`holes`), in its padding below the prompt.
//
// Also the Dock badge: how many Review items the current project has.
'use strict';
Umi.views = Umi.views || {};

Umi.views.marks = (() => {
  const S = Umi.state, M = Umi.model;
  const COLORS = { working: '#6F7F76', needs: '#E0A93E', finished: '#BDBDBD', idleFocus: '#6A6A6A' };
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
    const focused = tab.focused === paneId, split = M.paneIds(tab.root).length > 1 && !tab.zoomed;
    if (!st) return focused && split ? { color: COLORS.idleFocus, size: 9, opacity: 1 } : null;
    return { color: COLORS[st], size: focused ? 9 : 7, opacity: focused || st === 'needs' ? 1 : 0.7, state: st };
  }

  function dot(l) {
    const d = document.createElement('span');
    d.className = 'pane-mark';
    d.style.cssText = `width:${l.size}px;height:${l.size}px;background:${l.color};opacity:${l.opacity}`;
    if (l.state) d.dataset.state = l.state;
    return d;
  }

  let badge = null;
  // Draws the marks on the current tab's slots and chips.
  function render() {
    if (!S.layout) return;
    const tab = M.activeTab();
    const sid = M.sessionOf(tab.focused);
    if (sid && document.hasFocus()) seen[sid] = Date.now();
    document.querySelectorAll('#panes .pane-mark, #strip .pane-mark').forEach((m) => m.remove());
    for (const slot of document.querySelectorAll('#panes .slot')) {
      const l = look(slot.dataset.pane, tab);
      if (l) slot.append(dot(l));
    }
    for (const chip of document.querySelectorAll('#strip .chip[data-pane]')) {
      const l = look(chip.dataset.pane, tab);
      if (l && l.state) chip.prepend(dot({ ...l, size: 7 }));
    }
    for (const chip of document.querySelectorAll('#strip .chip.hidden')) {
      const st = stateOf(chip.dataset.session);
      if (st) chip.prepend(dot({ color: COLORS[st], size: 7, opacity: st === 'needs' ? 1 : 0.7, state: st }));
    }
    const cur = M.review().find((g) => g.current);
    const n = cur ? cur.items.length : 0;
    if (n !== badge) { badge = n; Umi.bridge.post({ type: 'badge', count: n }); }
  }

  // The marks over terminals, in CSS px: native cuts them out.
  function holeRects() {
    return [...document.querySelectorAll('#panes .slot[data-view="terminal"] .pane-mark')].map((m) => {
      const r = m.getBoundingClientRect();
      return { x: r.left - 1, y: r.top - 1, w: r.width + 2, h: r.height + 2 };
    });
  }

  return { render, holeRects, stateOf };
})();
