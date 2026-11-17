// A list of fixed-height rows that draws only the rows in view, so the explorer's big folders and
// global search's 20,000 lines stay quick. The container scrolls; rows are absolutely placed.
//
//   const list = Umi.views.vlist(container, {rowHeight, row: (i) => element})
//   list.set(count)        new data: redraws what's in view
//   list.redraw()          same count, rows changed (selection, text)
//   list.reveal(i)         scrolls row i into view
'use strict';
Umi.views = Umi.views || {};

Umi.views.vlist = (container, { rowHeight, row, overscan = 8 }) => {
  container.classList.add('vlist');
  const inner = document.createElement('div');
  inner.className = 'vlist-inner';
  container.append(inner);
  let count = 0;
  let frame = 0;

  function draw() {
    frame = 0;
    inner.style.height = count * rowHeight + 'px';
    const top = container.scrollTop, h = container.clientHeight || 600;
    const first = Math.max(0, Math.floor(top / rowHeight) - overscan);
    const last = Math.min(count, Math.ceil((top + h) / rowHeight) + overscan);
    const els = [];
    for (let i = first; i < last; i++) {
      const el = row(i);
      el.style.position = 'absolute';
      el.style.top = i * rowHeight + 'px';
      el.style.left = '0';
      el.style.right = '0';
      el.style.height = rowHeight + 'px';
      el.dataset.index = i;
      els.push(el);
    }
    // Rows given back as the same element (an inline name field) stay in place, keeping focus.
    const keep = new Set(els);
    for (const c of [...inner.children]) if (!keep.has(c)) c.remove();
    for (const el of els) if (el.parentNode !== inner) inner.append(el);
  }

  container.addEventListener('scroll', () => { if (!frame) frame = requestAnimationFrame(draw); });
  new ResizeObserver(() => draw()).observe(container);

  return {
    set(n) { count = n; draw(); },
    redraw: draw,
    reveal(i) {
      if (i < 0 || i >= count) return;
      const top = i * rowHeight, h = container.clientHeight;
      if (top < container.scrollTop) container.scrollTop = top;
      else if (top + rowHeight > container.scrollTop + h) container.scrollTop = top + rowHeight - h;
      draw();
    },
    get count() { return count; },
  };
};
