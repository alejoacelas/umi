// The comment margin of the Markdown preview (SPEC E-11): Umi's UmiCommentsScript.swift, run from
// the parent page on the preview's iframe (whose own scripts never run). views/file.js calls
// attach() after every render of the page, with the threads and what to keep (the selected
// thread, the reply being written, the scroll); the margin sends what the user does to `post`:
//   {type: 'add', start, end, body} · {type: 'reply'|'edit', id, body} · {type: 'resolve', id, resolved}
//   · {type: 'delete', id} · {type: 'select', id} · {type: 'composing', on} · {type: 'show_resolved', on}
//   · {type: 'done'} · {type: 'scroll', y} · {type: 'replyDraft', draft}
// Offsets are the file's: text runs carry `data-s` (markdown.js).
'use strict';
window.Umi = window.Umi || {};
Umi.views = Umi.views || {};

Umi.views.comments = { attach: umiCommentsAttach };

function umiCommentsAttach(document, window, data, post) {
  if (document.__umiCommentsOff) document.__umiCommentsOff();
  const offs = [];
  const on = (target, type, fn, opts) => { target.addEventListener(type, fn, opts); offs.push(() => target.removeEventListener(type, fn, opts)); };
  document.__umiCommentsOff = () => { offs.splice(0).forEach((f) => f()); ['umi-ui', 'umi-bar', 'umi-toast'].forEach((id) => document.getElementById(id)?.remove()); };
  const threads = data.threads || [];
  const state = {
    selected: data.focus || null, showResolved: !!data.showResolved, waiting: data.waiting || 0,
    compose: null, menu: null, editing: null, confirming: null, busy: false, replyDraft: data.replyDraft || null,
  };

  // ---- Elements --------------------------------------------------------------------------
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const ui = el('div'); ui.id = 'umi-ui';
  const margin = el('div'); margin.id = 'umi-margin';
  const add = el('button'); add.id = 'umi-add'; add.type = 'button';
  add.append('Comment'); add.append(el('span', 'umi-key', '⌥⌘M')); add.title = 'Comment on the selected text (⌥⌘M)';
  const bar = el('div'); bar.id = 'umi-bar';
  const toast = el('div'); toast.id = 'umi-toast';
  ui.append(margin, add);
  document.body.append(ui, bar, toast);

  const content = () => document.getElementById('umi-doc');
  const isUI = (node) => { const e = node && (node.nodeType === 1 ? node : node.parentElement); return !!(e && e.closest('#umi-ui, #umi-bar, #umi-toast')); };
  const label = (by) => by === 'user' ? 'You' : by === 'AI' ? 'Agent' : (by || 'Someone');
  const when = (at) => {
    const t = Date.parse(at); if (!t) return '';
    const s = (Date.now() - t) / 1000;
    if (s < 60) return 'just now'; if (s < 3600) return Math.floor(s / 60) + 'm'; if (s < 86400) return Math.floor(s / 3600) + 'h';
    return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  };
  const anchorOf = (id) => document.querySelector('[data-ids~="' + id.replace(/["\\]/g, '\\$&') + '"]');
  const visible = () => threads.filter(t => t.status === 'open' || state.showResolved);
  /// Too narrow for a margin beside the text: only the selected thread shows, under its words.
  const narrow = () => window.innerWidth < 500;

  // ---- From the page to the file ---------------------------------------------------------
  function textNodes(filter) {
    const walker = document.createTreeWalker(content(), NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => isUI(n) ? NodeFilter.FILTER_REJECT : (filter && !filter(n) ? NodeFilter.FILTER_SKIP : NodeFilter.FILTER_ACCEPT) });
    const out = []; let n; while ((n = walker.nextNode())) out.push(n); return out;
  }
  const traced = (n) => !!(n.parentElement && n.parentElement.closest('[data-s]'));
  function fileOffset(node, offset) {
    const span = node.parentElement.closest('[data-s]');
    const r = document.createRange(); r.setStart(span, 0); r.setEnd(node, offset);
    return parseInt(span.dataset.s, 10) + r.toString().length;
  }
  /// A selection's ends as offsets in the file, or null: from the first and last text the
  /// selection really covers (an end at the very start of the next run belongs to the run
  /// before, not after the markup between them).
  function rangeToFile(range) {
    let first = null, last = null;
    for (const n of textNodes(traced)) {
      if (!range.intersectsNode(n)) continue;
      const s = n === range.startContainer ? range.startOffset : 0;
      const e = n === range.endContainer ? range.endOffset : n.length;
      if (e <= s) continue;
      if (!first) first = [n, s];
      last = [n, e];
    }
    if (!first) return null;
    const start = fileOffset(first[0], first[1]), end = fileOffset(last[0], last[1]);
    return end >= start ? { start, end } : null;
  }

  // ---- Layout ----------------------------------------------------------------------------
  function marginWidth() {
    if (narrow()) return Math.max(160, Math.min(360, window.innerWidth - 56));
    return Math.max(180, Math.min(280, Math.round(window.innerWidth * 0.32)));
  }
  function showsMargin() { return !narrow() && (visible().length > 0 || !!state.compose); }
  function bodyTop() { return document.body.getBoundingClientRect().top + window.scrollY; }
  function marginLeft() {
    const b = document.body.getBoundingClientRect();
    const style = window.getComputedStyle(document.body);
    return b.right - parseFloat(style.paddingRight) + 24;
  }
  function layout() {
    const on = showsMargin();
    document.body.classList.toggle('umi-commenting', on);
    document.documentElement.style.setProperty('--umi-mw', marginWidth() + 'px');
    const origin = document.body.getBoundingClientRect();
    margin.style.left = (on ? marginLeft() - origin.left : 0) + 'px';
    ui.style.left = '0px'; ui.style.right = 'auto';
    const top0 = bodyTop();
    const cards = [...margin.querySelectorAll('.umi-card')];
    if (narrow()) {
      // One card, under the words it's about (or at the top when they're gone).
      margin.style.left = parseFloat(window.getComputedStyle(document.body).paddingLeft) + 'px';
      for (const card of cards) {
        let below = 0;
        if (card.classList.contains('umi-compose') && state.compose) below = state.compose.bottom;
        else { const a = card.dataset.id && anchorOf(card.dataset.id); if (a) below = a.getBoundingClientRect().bottom + window.scrollY - top0; }
        card.style.top = (below + 6) + 'px';
      }
      markActive();
      renderBar();
      return;
    }
    const items = cards.map(card => {
      let anchorTop = 0, pinned = card.classList.contains('umi-compose');
      if (pinned && state.compose) anchorTop = state.compose.top;
      else {
        const a = card.dataset.id && anchorOf(card.dataset.id);
        anchorTop = a ? a.getBoundingClientRect().top + window.scrollY - top0 : -1;
      }
      return { card, want: anchorTop, h: card.offsetHeight, detached: anchorTop < 0 };
    });
    // Detached threads first, at the top; then the rest by their anchors.
    let y = 0;
    for (const it of items.filter(i => i.detached)) { it.top = y; y += it.h + 8; }
    const anchored = items.filter(i => !i.detached).sort((a, b) => a.want - b.want);
    anchored.forEach(i => { i.want = Math.max(i.want, y); });
    const focus = anchored.findIndex(i => i.card.classList.contains('umi-compose') || i.card.dataset.id === state.selected);
    const pivot = focus >= 0 ? focus : 0;
    if (anchored.length) {
      anchored[pivot].top = anchored[pivot].want;
      for (let i = pivot + 1; i < anchored.length; i++) anchored[i].top = Math.max(anchored[i].want, anchored[i - 1].top + anchored[i - 1].h + 8);
      for (let i = pivot - 1; i >= 0; i--) anchored[i].top = Math.max(y, Math.min(anchored[i].want, anchored[i + 1].top - anchored[i].h - 8));
      // Pushed above the detached ones: lay everything out downwards again.
      for (let i = 1; i < anchored.length; i++) anchored[i].top = Math.max(anchored[i].top, anchored[i - 1].top + anchored[i - 1].h + 8);
    }
    for (const it of items) it.card.style.top = it.top + 'px';
    markActive();
    renderBar();
  }
  function markActive() {
    document.querySelectorAll('mark.umi-c, span.umi-pin').forEach(m => {
      const ids = (m.dataset.ids || '').split(' ');
      m.classList.toggle('umi-active', !!state.selected && ids.includes(state.selected));
    });
  }

  // ---- Cards -----------------------------------------------------------------------------
  function button(text, cls, onClick, title) {
    const b = el('button', cls, text); b.type = 'button'; if (title) b.title = title;
    b.addEventListener('mousedown', e => e.stopPropagation());
    b.addEventListener('click', e => { e.stopPropagation(); onClick(e); });
    return b;
  }
  function textarea(placeholder, value, onSubmit, onCancel, small) {
    const t = el('textarea', small ? 'umi-small' : ''); t.placeholder = placeholder; t.value = value || '';
    t.addEventListener('keydown', e => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); onSubmit(t.value); }
      else if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
    });
    // The box grows with its text up to the CSS max-height, then scrolls. An empty small box
    // (the reply box) keeps its one-line height from .umi-small.
    const fit = () => {
      if (small && !t.value) { t.style.height = ''; return; }
      t.style.height = 'auto';
      t.style.height = (t.scrollHeight + t.offsetHeight - t.clientHeight) + 'px';
    };
    t.addEventListener('input', () => { if (small) t.classList.toggle('umi-small', !t.value); fit(); layout(); });
    if (t.value) setTimeout(() => { fit(); layout(); }, 0);
    return t;
  }
  function comment(c, thread, isRoot) {
    const box = el('div', isRoot ? 'umi-root' : 'umi-reply');
    const head = el('div', 'umi-head');
    head.append(el('span', 'umi-who', label(c.by)), el('span', 'umi-when', when(c.at)), el('span', 'umi-spacer'));
    if (isRoot) {
      if (thread.status === 'open') head.append(button('✓', 'umi-icon umi-resolve', () => send({ type: 'resolve', id: thread.id, resolved: true }), 'Resolve'));
      else head.append(button('↺', 'umi-icon umi-reopen', () => send({ type: 'resolve', id: thread.id, resolved: false }), 'Reopen'));
    }
    head.append(button('⋯', 'umi-icon umi-more', () => { state.menu = state.menu === c.id ? null : c.id; render(); }, 'More'));
    box.append(head);
    if (state.menu === c.id) {
      const menu = el('div', 'umi-menu');
      menu.append(button('Edit', '', () => { state.menu = null; state.editing = c.id; state.selected = thread.id; render(); }));
      menu.append(button(isRoot ? 'Delete thread' : 'Delete', '', () => { state.menu = null; state.confirming = c.id; state.selected = thread.id; render(); }));
      box.append(menu);
    }
    if (isRoot && thread.detached) {
      box.append(el('div', 'umi-note', 'The text this was on was removed.'));
      if (thread.quote) box.append(el('div', 'umi-quote', thread.quote));
    }
    if (state.editing === c.id) {
      const t = textarea('Edit', c.body, v => send({ type: 'edit', id: c.id, body: v }), () => { state.editing = null; render(); });
      const actions = el('div', 'umi-actions');
      actions.append(button('Cancel', 'umi-btn', () => { state.editing = null; render(); }),
                     button('Save', 'umi-btn umi-primary', () => send({ type: 'edit', id: c.id, body: t.value })));
      box.append(t, actions);
      setTimeout(() => { t.focus(); t.setSelectionRange(t.value.length, t.value.length); }, 0);
    } else {
      box.append(el('div', 'umi-text', c.body));
    }
    if (state.confirming === c.id) {
      const actions = el('div', 'umi-actions');
      actions.append(el('span', 'umi-note', isRoot ? 'Delete this thread?' : 'Delete this reply?'),
                     button('Cancel', 'umi-btn', () => { state.confirming = null; render(); }),
                     button('Delete', 'umi-btn umi-danger', () => send({ type: 'delete', id: c.id })));
      box.append(actions);
    }
    if (isRoot && thread.status === 'resolved') box.append(el('div', 'umi-note', 'Resolved' + (thread.resolved_note ? ': ' + thread.resolved_note : '')));
    return box;
  }
  function card(thread) {
    const c = el('div', 'umi-card'); c.dataset.id = thread.id;
    if (thread.id === state.selected) c.classList.add('umi-selected');
    if (thread.status === 'resolved') c.classList.add('umi-resolved-card');
    if (thread.detached) c.classList.add('umi-detached');
    c.append(comment(thread, thread, true));
    for (const r of thread.replies || []) c.append(comment(r, thread, false));
    if (thread.id === state.selected && thread.status === 'open' && !state.editing) {
      const t = textarea('Reply…', state.replyDraft && state.replyDraft.id === thread.id ? state.replyDraft.text : '',
        v => send({ type: 'reply', id: thread.id, body: v }), () => { select(null); }, true);
      t.classList.add('umi-reply-box');
      t.addEventListener('input', () => { state.replyDraft = { id: thread.id, text: t.value }; post({ type: 'replyDraft', draft: state.replyDraft }); composing(!!t.value); actions.style.display = t.value ? 'flex' : 'none'; layout(); });
      const actions = el('div', 'umi-actions'); actions.style.display = t.value ? 'flex' : 'none';
      actions.append(button('Cancel', 'umi-btn', () => { state.replyDraft = null; composing(false); render(); }),
                     button('Reply', 'umi-btn umi-primary', () => send({ type: 'reply', id: thread.id, body: t.value })));
      c.append(t, actions);
    }
    if (state.error && state.error.id === thread.id) c.append(el('div', 'umi-error', state.error.text));
    c.addEventListener('mousedown', (e) => { if (state.selected !== thread.id) { e.preventDefault(); select(thread.id); } });
    return c;
  }
  function composeCard() {
    const c = el('div', 'umi-card umi-compose umi-selected');
    const head = el('div', 'umi-head'); head.append(el('span', 'umi-who', 'You'));
    const t = textarea('Comment…', state.compose.text, v => send({ type: 'add', start: state.compose.start, end: state.compose.end, body: v }), cancelCompose);
    t.addEventListener('input', () => { state.compose.text = t.value; });
    const actions = el('div', 'umi-actions');
    actions.append(button('Cancel', 'umi-btn', cancelCompose),
                   button('Comment', 'umi-btn umi-primary umi-submit', () => send({ type: 'add', start: state.compose.start, end: state.compose.end, body: t.value })));
    c.append(head, t, actions);
    if (state.error && state.error.id === '#compose') c.append(el('div', 'umi-error', state.error.text));
    setTimeout(() => t.focus(), 0);
    return c;
  }
  function render() {
    margin.textContent = '';
    for (const t of visible()) if (!narrow() || (t.id === state.selected && !state.compose)) margin.append(card(t));
    if (state.compose) margin.append(composeCard());
    layout();
    if (state.selected) {
      const t = margin.querySelector('.umi-card.umi-selected .umi-reply-box');
      if (t && document.activeElement !== t && !state.compose) setTimeout(() => t.focus({ preventScroll: true }), 0);
    }
  }
  function renderBar() {
    bar.textContent = '';
    const open = threads.filter(t => t.status === 'open').length;
    const resolved = threads.length - open;
    if (!threads.length && !state.waiting) { bar.style.display = 'none'; return; }
    bar.style.display = 'flex';
    if (state.waiting) { const w = el('span', 'umi-waiting'); w.append(el('span', 'umi-dot'), 'Agent waiting'); bar.append(w); }
    bar.append(el('span', 'umi-count', open === 1 ? '1 comment' : open + ' comments'));
    if (resolved) bar.append(button(state.showResolved ? 'Hide resolved' : 'Show resolved (' + resolved + ')', 'umi-link umi-toggle-resolved', () => {
      state.showResolved = !state.showResolved; post({ type: 'show_resolved', on: state.showResolved }); render(); }));
    bar.append(button('Done', 'umi-btn umi-primary umi-done', () => post({ type: 'done' }),
      state.waiting ? 'Tell the waiting agent you\'re done reviewing' : 'Done reviewing: tells an agent waiting with `umi comments wait`'));
  }

  // ---- Actions ---------------------------------------------------------------------------
  let composingNow = false;
  function composing(on) { if (on !== composingNow) { composingNow = on; post({ type: 'composing', on }); } }
  function send(message) {
    if (state.busy) return;
    if ((message.type === 'add' || message.type === 'reply' || message.type === 'edit') && !String(message.body || '').trim()) return;
    state.busy = true; state.error = null;
    margin.querySelectorAll('.umi-btn.umi-primary').forEach(b => b.disabled = true);
    post(message);
  }
  function select(id) {
    state.selected = id; state.menu = null; state.confirming = null; state.editing = null;
    post({ type: 'select', id });
    render();
  }
  function cancelCompose() {
    state.compose = null; state.error = null;
    if (window.CSS && window.CSS.highlights) window.CSS.highlights.delete('umi-pending');
    composing(false); render();
  }
  function startCompose() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed || isUI(sel.anchorNode)) { notice('Select the text to comment on first.'); return false; }
    const range = sel.getRangeAt(0);
    const at = rangeToFile(range);
    if (!at) { notice('Umi can\'t place a comment on that text.'); return false; }
    const rect = range.getBoundingClientRect();
    state.compose = { start: at.start, end: at.end, text: '', top: rect.top + window.scrollY - bodyTop(),
                      bottom: rect.bottom + window.scrollY - bodyTop() };
    state.selected = null;
    if (window.CSS && window.CSS.highlights && window.Highlight) window.CSS.highlights.set('umi-pending', new window.Highlight(range.cloneRange()));
    sel.removeAllRanges();
    add.style.display = 'none';
    composing(true);
    render();
    return true;
  }
  function notice(text) {
    toast.textContent = text; toast.style.display = 'block';
    clearTimeout(notice.timer); notice.timer = setTimeout(() => { toast.style.display = 'none'; }, 4000);
  }
  function showAdd() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed || isUI(sel.anchorNode) || state.compose) { add.style.display = 'none'; return; }
    const rect = sel.getRangeAt(0).getBoundingClientRect();
    if (!rect || (!rect.width && !rect.height)) { add.style.display = 'none'; return; }
    const origin = document.body.getBoundingClientRect();
    add.style.display = 'block';
    const left = showsMargin() ? marginLeft() - origin.left : Math.min(rect.right - origin.left + 8, window.innerWidth - origin.left - add.offsetWidth - 10);
    add.style.left = left + 'px';
    add.style.top = (rect.top + window.scrollY - bodyTop() - 2) + 'px';
  }

  // ---- Events ----------------------------------------------------------------------------
  add.addEventListener('mousedown', e => e.preventDefault());
  add.addEventListener('click', e => { e.preventDefault(); startCompose(); });
  on(document, 'mouseup', () => setTimeout(showAdd, 0));
  on(document, 'keyup', e => { if (e.shiftKey || e.key === 'Shift') setTimeout(showAdd, 0); });
  on(document, 'selectionchange', () => { if (window.getSelection().isCollapsed) add.style.display = 'none'; });
  on(document, 'mousedown', e => {
    if (isUI(e.target)) return;
    const mark = e.target.closest && e.target.closest('mark.umi-c:not(.umi-resolved), span.umi-pin:not(.umi-resolved)');
    if (mark) { const id = mark.dataset.ids.split(' ').find(i => threads.some(t => t.id === i)); if (id) { select(id); return; } }
    if (state.selected && !composingNow) select(null);
  });
  let scrollTimer = null;
  on(window, 'scroll', () => { clearTimeout(scrollTimer); scrollTimer = setTimeout(() => post({ type: 'scroll', y: window.scrollY }), 120); });
  let wasNarrow = narrow();
  on(window, 'resize', () => { if (narrow() !== wasNarrow) { wasNarrow = narrow(); render(); } else layout(); });
  // Images change the layout as they load.
  document.querySelectorAll('img').forEach(img => img.addEventListener('load', () => layout()));

  // ---- What Umi calls --------------------------------------------------------------------
  const api = {
    startCompose,
    failed(text) {
      state.busy = false;
      state.error = { id: state.compose ? '#compose' : (state.selected || ''), text };
      render();
    },
    setWaiting(n) { state.waiting = n; renderBar(); },
    // Whether the card of a new comment is open (the page isn't drawn again under it).
    composingNew: () => !!state.compose,
    // The file took the change but the page isn't drawn again yet: the buttons work again.
    idle() { state.busy = false; margin.querySelectorAll('.umi-btn.umi-primary').forEach(b => b.disabled = false); },
    notice,
    // For tests: select text by its words (the nth occurrence in the page's text).
    selectText(needle, nth) {
      const nodes = textNodes(null);
      let all = '', starts = [];
      for (const n of nodes) { starts.push(all.length); all += n.data; }
      let at = -1; for (let i = 0; i <= (nth || 0); i++) { at = all.indexOf(needle, at + 1); if (at < 0) return false; }
      const locate = (pos) => { for (let i = nodes.length - 1; i >= 0; i--) if (starts[i] <= pos) return [nodes[i], pos - starts[i]]; return null; };
      const [sn, so] = locate(at), [en, eo] = locate(at + needle.length);
      const r = document.createRange(); r.setStart(sn, so); r.setEnd(en, eo);
      const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
      showAdd();
      return add.style.display === 'block';
    },
    clickAdd() { add.click(); return !!state.compose; },
    type(text) {
      const t = margin.querySelector('.umi-card.umi-selected textarea');
      if (!t) return false;
      t.focus(); t.value = text; t.dispatchEvent(new Event('input', { bubbles: true })); return true;
    },
    submit() {
      const t = margin.querySelector('.umi-card.umi-selected textarea');
      if (!t) return false;
      t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true })); return true;
    },
    select(id) { select(id); return true; },
    click(selector) { const b = document.querySelector(selector); if (!b) return false; b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); b.click(); return true; },
    clickMark(id) { const m = anchorOf(id); if (!m) return false; m.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); return true; },
    state() {
      const top0 = bodyTop();
      return {
        margin: showsMargin(), narrow: narrow(), width: window.innerWidth, selected: state.selected, composing: !!state.compose, add_visible: add.style.display === 'block',
        bar: bar.style.display !== 'none' ? bar.textContent : '', toast: toast.style.display === 'block' ? toast.textContent : '',
        error: state.error ? state.error.text : '', scroll: window.scrollY,
        cards: [...margin.querySelectorAll('.umi-card')].map(c => {
          const a = c.dataset.id && anchorOf(c.dataset.id);
          const cr = c.getBoundingClientRect();
          return { id: c.dataset.id || '', text: c.textContent, top: cr.top + window.scrollY - top0, height: cr.height, left: cr.left,
                   anchor_top: a ? a.getBoundingClientRect().top + window.scrollY - top0 : null,
                   anchor_text: a ? a.textContent : null, selected: c.classList.contains('umi-selected') };
        }),
        marks: [...document.querySelectorAll('mark.umi-c')].map(m => ({ ids: m.dataset.ids, text: m.textContent, resolved: m.classList.contains('umi-resolved'), right: m.getBoundingClientRect().right })),
      };
    },
  };

  render();
  // A reply draft brought back counts as writing, as it did in the margin before this one.
  if (margin.querySelector('.umi-card.umi-selected .umi-reply-box')?.value) composing(true);
  if (data.scroll != null) window.scrollTo(0, data.scroll);
  if (state.selected) layout();
  return api;
}
