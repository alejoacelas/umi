// The active tab's split layout. Each pane gets a slot; what fills it depends on the pane's view:
// 'terminal' slots stay empty (a native Ghostty view sits there and their rects go to native);
// other views (later: 'picker') are drawn here by a renderer in `renderers`.
'use strict';
Umi.views = Umi.views || {};

Umi.views.panes = (() => {
  const S = Umi.state, M = Umi.model;

  // view name -> (slot element, pane node) => void. A view without a renderer shows its name.
  const renderers = {
    terminal() {},
  };

  function renderNode(node) {
    if (node.type === 'pane') {
      const el = document.createElement('div');
      el.className = 'slot';
      el.dataset.pane = node.id;
      el.dataset.view = node.view || 'terminal';
      const r = renderers[el.dataset.view];
      if (r) r(el, node);
      else el.textContent = el.dataset.view;
      if (el.dataset.view !== 'terminal') {
        el.addEventListener('mousedown', () => Umi.app.update(() => M.focusPane(node.id), { focus: false }));
      }
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

  function render() {
    const main = document.querySelector('#panes');
    main.textContent = '';
    const tab = M.activeTab();
    main.classList.toggle('multi', M.paneIds(tab.root).length > 1);
    main.append(renderNode(tab.root));
    main.querySelectorAll('.slot').forEach((s) => s.classList.toggle('focused', s.dataset.pane === tab.focused));
  }

  function dragDivider(e, node, el) {
    e.preventDefault();
    const box = el.getBoundingClientRect();
    const move = (ev) => {
      const r = node.dir === 'row' ? (ev.clientX - box.left) / box.width : (ev.clientY - box.top) / box.height;
      node.ratio = Math.min(0.9, Math.max(0.1, r));
      render();
      Umi.app.report(false);
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      Umi.app.update(() => {});
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  // Rects of every slot (all views), in CSS px.
  function slotRects() {
    const out = {};
    document.querySelectorAll('#panes .slot').forEach((s) => {
      const r = s.getBoundingClientRect();
      out[s.dataset.pane] = { x: r.left, y: r.top, w: r.width, h: r.height };
    });
    return out;
  }

  // Rects native places terminals in: terminal slots only.
  function terminalRects() {
    const out = {};
    document.querySelectorAll('#panes .slot[data-view="terminal"]').forEach((s) => {
      const r = s.getBoundingClientRect();
      out[s.dataset.pane] = { x: r.left, y: r.top, w: r.width, h: r.height };
    });
    return out;
  }

  return { render, renderers, slotRects, terminalRects };
})();
