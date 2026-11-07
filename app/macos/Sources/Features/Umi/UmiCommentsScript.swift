import Foundation

/// The comment margin of the Markdown preview (E-11): JavaScript and CSS that Umi injects into the
/// preview in a content world of its own. The document's own scripts still never run (E-7): the
/// page allows no scripts, and this code isn't part of the page.
///
/// The page carries its data in `<meta name="umi-comment-data" content="JSON">`:
/// the threads, the thread to show selected, where to scroll, how many agents wait for a review.
/// Text runs carry the file offset they came from (`data-s`), so a selection maps to the file.
enum UmiCommentsScript {
    static let css = """
    :root { --umi-mw: 260px; }
    body.umi-commenting { max-width: calc(860px + var(--umi-mw) + 24px); padding-right: calc(28px + var(--umi-mw) + 24px); }
    body { position: relative; }
    mark { background: none; color: inherit; }
    mark.umi-hl { background: rgba(255, 214, 10, 0.22); border-radius: 2px; }
    mark.umi-c { background: var(--umi-mark); border-bottom: 2px solid var(--umi-mark-line); border-radius: 2px; cursor: pointer; }
    mark.umi-c.umi-resolved { background: none; border-bottom: none; cursor: auto; }
    mark.umi-c.umi-active { background: var(--umi-mark-active); }
    span.umi-pin::after { content: "\\201D"; display: inline-block; font-size: 0.75em; line-height: 1; padding: 1px 4px;
      margin: 0 2px; border-radius: 4px; background: var(--umi-mark); color: var(--umi-fg2); cursor: pointer; vertical-align: 0.1em; }
    span.umi-pin.umi-resolved::after { display: none; }
    ins { background: rgba(46, 160, 67, 0.18); text-decoration: none; border-bottom: 1px solid rgba(46,160,67,0.6); }
    del { background: rgba(248, 81, 73, 0.14); color: var(--umi-fg2); }
    ::highlight(umi-pending) { background-color: var(--umi-mark-active); }
    #umi-ui { position: absolute; top: 0; right: 0; width: 0; height: 0; z-index: 10;
      font: 12.5px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    #umi-margin { position: absolute; top: 0; width: var(--umi-mw); }
    .umi-card { position: absolute; left: 0; width: var(--umi-mw); box-sizing: border-box; padding: 9px 11px 10px;
      background: var(--umi-card); border: 1px solid var(--umi-line); border-radius: 9px; color: var(--umi-fg);
      transition: top 0.12s ease, box-shadow 0.12s ease; cursor: default; }
    .umi-card.umi-selected { box-shadow: 0 3px 14px var(--umi-shadow); border-color: var(--umi-line-strong); z-index: 2; }
    .umi-card.umi-resolved-card { opacity: 0.62; }
    .umi-card.umi-detached { border-style: dashed; }
    .umi-head { display: flex; align-items: center; gap: 6px; min-height: 20px; }
    .umi-who { font-weight: 600; } .umi-when { color: var(--umi-fg3); font-size: 11.5px; }
    .umi-head .umi-spacer { flex: 1; }
    .umi-icon { border: none; background: none; color: var(--umi-fg2); width: 22px; height: 22px; border-radius: 5px;
      font-size: 13px; line-height: 22px; padding: 0; cursor: pointer; text-align: center; }
    .umi-icon:hover { background: var(--umi-hover); color: var(--umi-fg); }
    .umi-text { white-space: pre-wrap; word-wrap: break-word; margin-top: 3px; }
    .umi-quote { color: var(--umi-fg2); font-size: 11.5px; margin-top: 4px; border-left: 2px solid var(--umi-mark-line);
      padding-left: 6px; white-space: pre-wrap; word-wrap: break-word; }
    .umi-note { color: var(--umi-fg3); font-size: 11.5px; margin-top: 4px; }
    .umi-reply { margin-top: 9px; padding-top: 8px; border-top: 1px solid var(--umi-line); }
    .umi-card textarea { display: block; width: 100%; box-sizing: border-box; margin-top: 7px; min-height: 52px; max-height: 240px; resize: none; overflow-y: auto;
      font: inherit; color: var(--umi-fg); background: var(--umi-input); border: 1px solid var(--umi-line-strong);
      border-radius: 6px; padding: 6px 7px; outline: none; }
    .umi-card textarea:focus { border-color: var(--umi-accent); }
    .umi-card textarea.umi-small { min-height: 30px; height: 30px; }
    .umi-actions { display: flex; justify-content: flex-end; gap: 6px; margin-top: 7px; }
    .umi-btn { font: inherit; font-size: 12px; border-radius: 6px; padding: 3px 10px; cursor: pointer; border: 1px solid var(--umi-line-strong);
      background: none; color: var(--umi-fg); }
    .umi-btn.umi-primary { background: var(--umi-accent); border-color: var(--umi-accent); color: #fff; }
    .umi-btn.umi-danger { color: #e5534b; border-color: rgba(229,83,75,0.5); }
    .umi-btn:disabled { opacity: 0.5; cursor: default; }
    .umi-error { color: #e5534b; font-size: 11.5px; margin-top: 6px; }
    .umi-menu { position: absolute; right: 8px; top: 30px; background: var(--umi-card); border: 1px solid var(--umi-line-strong);
      border-radius: 7px; box-shadow: 0 4px 16px var(--umi-shadow); padding: 3px; z-index: 5; }
    .umi-menu button { display: block; width: 100%; text-align: left; border: none; background: none; color: var(--umi-fg);
      font: inherit; padding: 4px 12px; border-radius: 4px; cursor: pointer; }
    .umi-menu button:hover { background: var(--umi-hover); }
    #umi-add { position: absolute; display: none; white-space: nowrap; font: 600 12px/1 -apple-system, sans-serif;
      padding: 6px 10px; border-radius: 7px; border: 1px solid var(--umi-line-strong); background: var(--umi-card);
      color: var(--umi-fg); box-shadow: 0 2px 10px var(--umi-shadow); cursor: pointer; z-index: 6; }
    #umi-add:hover { border-color: var(--umi-accent); }
    #umi-add .umi-key { color: var(--umi-fg3); font-weight: 400; margin-left: 6px; }
    #umi-bar { position: fixed; bottom: 12px; right: 14px; display: none; align-items: center; gap: 8px; z-index: 20;
      font: 12px/1 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--umi-fg2); background: var(--umi-card);
      border: 1px solid var(--umi-line); border-radius: 8px; padding: 4px 4px 4px 10px; box-shadow: 0 2px 10px var(--umi-shadow); }
    #umi-bar .umi-link { border: none; background: none; color: var(--umi-fg2); font: inherit; cursor: pointer; padding: 3px 4px; }
    #umi-bar .umi-link:hover { color: var(--umi-fg); }
    #umi-bar .umi-waiting { display: inline-flex; align-items: center; gap: 5px; color: var(--umi-accent); }
    #umi-bar .umi-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--umi-accent); }
    #umi-toast { position: fixed; bottom: 54px; right: 14px; max-width: 320px; display: none; z-index: 30;
      font: 12px/1.4 -apple-system, sans-serif; color: var(--umi-fg); background: var(--umi-card);
      border: 1px solid var(--umi-line-strong); border-radius: 8px; padding: 8px 11px; box-shadow: 0 4px 16px var(--umi-shadow); }
    """

    static func palette(light: Bool) -> String {
        light
            ? """
            :root { --umi-card: #ffffff; --umi-input: #ffffff; --umi-fg: #1f2328; --umi-fg2: #57606a; --umi-fg3: #8b949e;
              --umi-line: rgba(0,0,0,0.10); --umi-line-strong: rgba(0,0,0,0.18); --umi-hover: rgba(0,0,0,0.06);
              --umi-shadow: rgba(0,0,0,0.12); --umi-accent: #0a84ff; --umi-mark: rgba(255, 196, 0, 0.26);
              --umi-mark-line: rgba(220, 160, 0, 0.85); --umi-mark-active: rgba(255, 176, 0, 0.45); }
            """
            : """
            :root { --umi-card: #26272b; --umi-input: #1d1e21; --umi-fg: #e6e6e6; --umi-fg2: #a8a8a8; --umi-fg3: #7c7c80;
              --umi-line: rgba(255,255,255,0.09); --umi-line-strong: rgba(255,255,255,0.16); --umi-hover: rgba(255,255,255,0.07);
              --umi-shadow: rgba(0,0,0,0.45); --umi-accent: #0a84ff; --umi-mark: rgba(255, 196, 0, 0.16);
              --umi-mark-line: rgba(255, 196, 0, 0.6); --umi-mark-active: rgba(255, 196, 0, 0.32); }
            """
    }

    /// The page's `<head>` additions: the styles and the data.
    static func head(data: [String: Any], light: Bool) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: data, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // In an attribute: a page without scripts drops `<script>` elements, data blocks too.
        return "<style>\(palette(light: light))\n\(css)</style>"
            + "<meta name=\"umi-comment-data\" content=\"\(UmiComments.escapeHTML(json))\">"
    }

    static let source = #"""
    (() => {
      if (window.umiComments) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.umi;
      const post = (message) => { if (handler) handler.postMessage(message); };
      const dataNode = document.querySelector('meta[name="umi-comment-data"]');
      if (!dataNode) return;
      let data = {};
      try { data = JSON.parse(dataNode.getAttribute('content') || '{}'); } catch (e) { data = {}; }
      const threads = data.threads || [];
      const state = {
        selected: data.focus || null, showResolved: !!data.showResolved, waiting: data.waiting || 0,
        compose: null, menu: null, editing: null, confirming: null, busy: false,
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
      const content = () => document.body;
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
        const style = getComputedStyle(document.body);
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
          margin.style.left = parseFloat(getComputedStyle(document.body).paddingLeft) + 'px';
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
          t.addEventListener('input', () => { state.replyDraft = { id: thread.id, text: t.value }; composing(!!t.value); actions.style.display = t.value ? 'flex' : 'none'; layout(); });
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
        if (window.CSS && CSS.highlights) CSS.highlights.delete('umi-pending');
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
        if (window.CSS && CSS.highlights && window.Highlight) CSS.highlights.set('umi-pending', new Highlight(range.cloneRange()));
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
      document.addEventListener('mouseup', () => setTimeout(showAdd, 0));
      document.addEventListener('keyup', e => { if (e.shiftKey || e.key === 'Shift') setTimeout(showAdd, 0); });
      document.addEventListener('selectionchange', () => { if (window.getSelection().isCollapsed) add.style.display = 'none'; });
      document.addEventListener('mousedown', e => {
        if (isUI(e.target)) return;
        const mark = e.target.closest && e.target.closest('mark.umi-c:not(.umi-resolved), span.umi-pin:not(.umi-resolved)');
        if (mark) { const id = mark.dataset.ids.split(' ').find(i => threads.some(t => t.id === i)); if (id) { select(id); return; } }
        if (state.selected && !composingNow) select(null);
      });
      let scrollTimer = null;
      window.addEventListener('scroll', () => { clearTimeout(scrollTimer); scrollTimer = setTimeout(() => post({ type: 'scroll', y: window.scrollY }), 120); });
      let wasNarrow = narrow();
      window.addEventListener('resize', () => { if (narrow() !== wasNarrow) { wasNarrow = narrow(); render(); } else layout(); });
      // Images change the layout as they load.
      document.querySelectorAll('img').forEach(img => img.addEventListener('load', () => layout()));

      // ---- What Umi calls --------------------------------------------------------------------
      window.umiComments = {
        startCompose,
        failed(text) {
          state.busy = false;
          state.error = { id: state.compose ? '#compose' : (state.selected || ''), text };
          render();
        },
        setWaiting(n) { state.waiting = n; renderBar(); },
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
      if (data.scroll) window.scrollTo(0, data.scroll);
      if (state.selected) {
        const a = anchorOf(state.selected);
        if (a && data.reveal) { const r = a.getBoundingClientRect(); if (r.top < 0 || r.bottom > window.innerHeight) a.scrollIntoView({ block: 'center' }); }
        layout();
      }
    })();
    """#
}
